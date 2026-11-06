//! 91短剧：核心里的影视区站点。
//!
//! SPA + 加密 JSON 接口站。入口 http://91dju.com/?from=yng 为跳转页，
//! JS 跳往随机子域 *.91dju.cyou（与 16 号乱伦AI短剧同一跳转目标，
//! 同站，已跳过 16 号）；接口基址用固定子域
//! https://app.91dju.cyou（任一子域均可，实测 app 子域全接口通；
//! 裸域 91dju.cyou 不提供 /api）。
//! 接口一律 GET `/api/<路径>`，响应为 `{"cipher": "<base64>"}`，
//! AES-128-CBC/PKCS7 解密（密钥与 IV 取自站内 JS 包，与 CryptoJS
//! 的 Utf8.parse 写法一致），内层为正常 JSON。
//! 分类：`/api/config` 取 home_rec_cat_id（5 个视频分类）与
//! core_category_ids（2 个导航分类），再
//! `/api/categories/batch/<id 列表>` 按 module=="video" 过滤，
//! 得 AI短剧 2041、AI漫剧 2042、国产原创 2034、吃瓜爆料 2035、
//! 91探花 2037；目录 `/api/videos?category_id=<id>&page=&ps=28`
//! （category_id 过滤实测有效，cat_id 无效）；
//! 详情 `/api/movie?id=<id>`，分集在 info.play_url 里，形如
//! `第01集$https://91crdjai.com/.../1/#第02集$...`（首集标题前
//! 带一段无用的 `http://localhost:8080/` 前缀，需去掉）；
//! 搜索 `/api/videos?kw=<词>&page=1&ps=13`（kw 参数实测有效，
//! keyword/wd/q 直传会被忽略）；
//! 取流 `/api/parse_video?url=<分集页地址>` 返回带时效签名的
//! m3u8（auth_key，须现取现用），实测清单 200、AES-128、
//! 首分片 Range 206。
//! VIP：最新 28 条 vip 全为 0，未见 VIP 墙；配置里有
//! vip_cat_id 2096，但列表接口不按该分类出独立内容，
//! 免费部分全通。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use aes::Aes128;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::{
    cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit},
    Decryptor,
};
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const BASE: &str = "https://app.91dju.cyou";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const AES_KEY: &str = "a9yX32LpQvUt7wBc";
const AES_IV: &str = "N7cPk2Bv38hWqFzM";
const PAGE_SIZE: i64 = 28;
const SEARCH_SIZE: i64 = 13;

/// 分类静态回退：与站内视频分类一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("2041", "AI短剧"),
    ("2042", "AI漫剧"),
    ("2034", "国产原创"),
    ("2035", "吃瓜爆料"),
    ("2037", "91探花"),
];

/// 解密接口响应里的 cipher 字段：base64 解码后 AES-128-CBC/PKCS7 解密。
fn decrypt_cipher(cipher_b64: &str) -> ApiResult<String> {
    let raw = STANDARD
        .decode(cipher_b64)
        .map_err(|e| ApiError::Internal(format!("91短剧密文解码失败：{e}")))?;
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Err(ApiError::Internal("91短剧密文长度异常".into()));
    }
    let plain = Decryptor::<Aes128>::new_from_slices(AES_KEY.as_bytes(), AES_IV.as_bytes())
        .map_err(|e| ApiError::Internal(format!("91短剧解密器初始化失败：{e}")))?
        .decrypt_padded_vec_mut::<Pkcs7>(&raw)
        .map_err(|e| ApiError::Internal(format!("91短剧解密失败：{e}")))?;
    String::from_utf8(plain).map_err(|e| ApiError::Internal(format!("91短剧解密结果非文本：{e}")))
}

/// 调接口：GET /api/<path>，解 cipher 后返回内层 JSON。
async fn api_get(path: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/api{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("91短剧请求 HTTP {status}")));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let cipher = text_of(&body, &["cipher"]);
    if cipher.is_empty() {
        return Ok(body);
    }
    let plain = decrypt_cipher(&cipher)?;
    serde_json::from_str(&plain)
        .map_err(|e| ApiError::Internal(format!("91短剧内层 JSON 解析失败：{e}")))
}

/// config 里的 id 列表字段：逗号分隔，如 "2041, 2042,2034"。
fn split_ids(s: &str) -> Vec<String> {
    s.split(',')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

/// 分类列表：config 的视频分类 id + 导航分类 id，批量取回后只留 module=="video" 的。
fn parse_video_categories(batch: &Value) -> Vec<Value> {
    let mut categories = Vec::new();
    let data = match get(batch, "data") {
        Some(d) => d,
        None => return categories,
    };
    let list = match arr_of(data) {
        Some(_) => None,
        None => get(data, "list").and_then(arr_of),
    };
    let list = match list {
        Some(l) => l,
        None => return categories,
    };
    for item in list {
        if text_of(item, &["module"]) != "video" {
            continue;
        }
        let id = text_of(item, &["id"]);
        let name = text_of(item, &["name"]);
        if id.is_empty() || name.is_empty() {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let config = match api_get("/config").await {
        Ok(v) => v,
        Err(_) => return Ok(fallback_categories()),
    };
    let data = match get(&config, "data") {
        Some(d) => d,
        None => return Ok(fallback_categories()),
    };
    let mut ids = split_ids(&text_of(data, &["home_rec_cat_id"]));
    ids.extend(split_ids(&text_of(data, &["core_category_ids"])));
    if ids.is_empty() {
        return Ok(fallback_categories());
    }
    let batch = match api_get(&format!("/categories/batch/{}", ids.join(","))).await {
        Ok(v) => v,
        Err(_) => return Ok(fallback_categories()),
    };
    let list = parse_video_categories(&batch);
    if list.is_empty() {
        Ok(fallback_categories())
    } else {
        Ok(json!({"categories": list}))
    }
}

/// 视频列表解析：data.list 的 id/title/cover_url。
fn parse_items(body: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let data = match get(body, "data") {
        Some(d) => d,
        None => return items,
    };
    let list = match get(data, "list").and_then(arr_of) {
        Some(l) => l,
        None => return items,
    };
    for item in list {
        let id = text_of(item, &["id"]);
        let title = text_of(item, &["title"]);
        let cover = text_of(item, &["cover_url"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

fn total_pages(body: &Value) -> i64 {
    match get(body, "data") {
        Some(d) => int_of(d, &["pages"]),
        None => 0,
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = with_query(
        "/videos",
        &[
            ("category_id", category_id),
            ("page", &page.to_string()),
            ("ps", &PAGE_SIZE.to_string()),
        ],
    );
    let body = api_get(&path).await?;
    let items = parse_items(&body);
    let pages = total_pages(&body);
    let has_more = !items.is_empty() && (pages <= 0 || page < pages);
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 分集解析：play_url 按 # 分集、按 $ 分标题与地址，去首集的 localhost 前缀。
fn parse_episodes(play_url: &str, series_id: &str) -> Vec<Value> {
    let mut episodes = Vec::new();
    for part in play_url.split('#') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let Some((title, url)) = part.split_once('$') else {
            continue;
        };
        let title = title
            .trim()
            .strip_prefix("http://localhost:8080/")
            .unwrap_or(title.trim());
        let url = url.trim();
        if title.is_empty() || url.is_empty() {
            continue;
        }
        episodes.push(episode_json(url, title, series_id));
    }
    episodes
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let body = api_get(&format!("/movie?id={series_id}")).await?;
    let info = match get(&body, "data").and_then(|d| get(d, "info")) {
        Some(v) => v,
        None => return Err(ApiError::Internal("91短剧详情缺少 info".into())),
    };
    let title = text_of(info, &["title"]);
    let cover = text_of(info, &["cover_url"]);
    let category = text_of(info, &["category"]);
    let hits = int_of(info, &["hits"]);
    let episodes = parse_episodes(&text_of(info, &["play_url"]), series_id);
    if title.is_empty() || episodes.is_empty() {
        return Err(ApiError::Internal("91短剧详情缺少标题或分集".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {"category": category, "hits": hits},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if !video_id.starts_with("http") {
        return Err(ApiError::Internal("91短剧该集没有播放页地址".into()));
    }
    let path = with_query("/parse_video", &[("url", video_id)]);
    let body = api_get(&path).await?;
    let url = match get(&body, "data") {
        Some(d) => text_of(d, &["m3u8_url"]),
        None => String::new(),
    };
    if url.is_empty() {
        return Err(ApiError::Internal("91短剧未解析出播放地址".into()));
    }
    Ok(json!({"url": url}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = with_query(
        "/videos",
        &[
            ("kw", query),
            ("page", "1"),
            ("ps", &SEARCH_SIZE.to_string()),
        ],
    );
    let body = api_get(&path).await?;
    let items = parse_items(&body);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypt_real_cipher() {
        // 真实接口样本：/api/menu/fetch 的响应密文。
        let cipher = "rhmq8V3PSZVdTn76Lk7CcaP2AKimYE7fkze/aByJVg15i5rMMIZEEVdmo+qYupnqq8eX62ePr1TrnTSDScdwQb/+TP1FtSNuHAAeE1rkWBN5XnCX1+wn0P8AHwvsUoTC";
        let plain = decrypt_cipher(cipher).unwrap();
        let v: Value = serde_json::from_str(&plain).unwrap();
        assert_eq!(v["code"], 0);
        assert_eq!(v["data"]["msg"], "未配置 Menu 分类 ID");
        assert_eq!(v["data"]["site_id"], 56);
    }

    #[test]
    fn split_ids_trims_spaces() {
        assert_eq!(
            split_ids("2041, 2042,2034,2035,2037"),
            vec!["2041", "2042", "2034", "2035", "2037"]
        );
        assert_eq!(split_ids(""), Vec::<String>::new());
    }

    #[test]
    fn parse_video_categories_filters_module() {
        let batch: Value = serde_json::from_str(
            r#"{"code":0,"data":{"count":7,"list":[
                {"id":2033,"name":"名站导航","module":"website"},
                {"id":2097,"name":"黄瓜","module":"website"},
                {"id":2041,"name":"AI短剧","module":"video"},
                {"id":2042,"name":"AI漫剧","module":"video"},
                {"id":2034,"name":"国产原创","module":"video"},
                {"id":2035,"name":"吃瓜爆料","module":"video"},
                {"id":2037,"name":"91探花","module":"video"}],"site_id":56},"msg":"ok"}"#,
        )
        .unwrap();
        let list = parse_video_categories(&batch);
        assert_eq!(list.len(), 5);
        assert_eq!(list[0]["id"], "2041");
        assert_eq!(list[4]["name"], "91探花");
    }

    #[test]
    fn fallback_has_5_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 5);
        assert_eq!(list[0]["name"], "AI短剧");
        assert_eq!(list[4]["id"], "2037");
    }

    #[test]
    fn parse_items_real_sample() {
        let body: Value = serde_json::from_str(
            r#"{"code":0,"data":{"page":1,"ps":3,"total":2,"pages":1,"list":[
                {"id":18083228,"title":"双生道侣","cover_url":"https://pic.drleao.cn/upload_01/xiao/20260903/2026090322224830743.jpeg?auth_key=1793696222-0-0-af80c8d3dee0cc314165d0acbef4342b","play_url":"","play_from":"","vip":0,"hits":32682,"status":1,"category_id":2042,"category":"AI漫剧"},
                {"id":17788455,"title":"双生地狱｜归笼","cover_url":"https://media.hgpicimg.cc//upload/huangguo/9833.jpg","play_url":"","play_from":"","vip":0,"hits":100,"status":1,"category_id":2042,"category":"AI漫剧"}]},"msg":"ok"}"#,
        )
        .unwrap();
        let items = parse_items(&body);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "18083228");
        assert_eq!(items[0]["title"], "双生道侣");
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://pic.drleao.cn/"));
        assert_eq!(total_pages(&body), 1);
    }

    #[test]
    fn parse_episodes_real_play_url() {
        let play_url = "http://localhost:8080/第01集$https://91crdjai.com/manju/767-shuangshengdaolv/1/#第02集$https://91crdjai.com/manju/767-shuangshengdaolv/2/#第03集$https://91crdjai.com/manju/767-shuangshengdaolv/3/";
        let eps = parse_episodes(play_url, "18083228");
        assert_eq!(eps.len(), 3);
        assert_eq!(eps[0]["title"], "第01集");
        assert_eq!(
            eps[0]["video_id"],
            "https://91crdjai.com/manju/767-shuangshengdaolv/1/"
        );
        assert_eq!(eps[2]["title"], "第03集");
        assert_eq!(eps[0]["series_id"], "18083228");
        assert!(parse_episodes("", "1").is_empty());
    }

    #[test]
    fn parse_m3u8_url_field() {
        let body: Value = serde_json::from_str(
            r#"{"code":0,"data":{"m3u8_url":"https://yd-zhqr-hls.hzjvlo.cn/videos5/cd34050d7bb1aebac62bc3f824c36024/cd34050d7bb1aebac62bc3f824c36024.m3u8?auth_key=1793890395-158.web.38646d3d-0-6a156895d19c326a49106bf3ab9cd9a6&v=3&time=0&via=91crdj&via_bm=dx"},"msg":"命中缓存"}"#,
        )
        .unwrap();
        let url = text_of(get(&body, "data").unwrap(), &["m3u8_url"]);
        assert!(url.starts_with("https://yd-zhqr-hls.hzjvlo.cn/videos5/"));
        assert!(url.ends_with("&via=91crdj&via_bm=dx"));
    }
}
