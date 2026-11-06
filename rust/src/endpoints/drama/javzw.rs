//! Jav中文（Jav中文 / 醉梦春秋）：核心里的影视区站点。
//!
//! 与已有站 JavPlay（javplay，ja6play.com，Next.js + hid 取流）
//! 不同站：本站入口 https://www.javzw.cc/?from=yng 是 JS 跳转页，
//! 跳到 6 位随机子域 https://<随机>.javzw.cyou/（Nuxt SPA，
//! fanhaowu 系；通配子域，任意随机子域都可服务，本模块每次请求
//! 现取一个随机子域，与站方跳转行为一致；/api/public/domains
//! 另列 javzw.lat 等域名，裸域本机出口不通）。
//! 接口全部走相对路径 /api，响应为 AES-CBC 加密 JSON：
//! `{"cipher": "<Base64>"}`，密钥 `a9yX32LpQvUt7wBc`、
//! IV `N7cPk2Bv38hWqFzM`（站方 Nuxt 包内明文常量），解密后取
//! data。分类 /api/categories 共 33 项，其中 module=video 的
//! 25 项为视频分类（其余 website/novel/gallery/app 不进核心）。
//! 列表 /api/videos?category_id=<id>&page=<n>（每页 20 条，
//! kw=<词> 即搜索）；详情 /api/movie?id=<id>，play_url 形如
//! `http://localhost:8080/第01集$<m3u8>#第02集$<m3u8>…`，
//! `$` 后为真实 m3u8（`http://localhost:8080/` 只是站内占位
//! 前缀）；抽查样本 vip 均为 0、免费可播。取流：详情首集
//! https://c10.hs100.top/20261019/527d50d2a129a4f9/index.m3u8
//! 清单 200、AES-128 密钥 200/16B、首分片 Range 206。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use aes::Aes128;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::{
    cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit},
    Decryptor,
};
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const KEY: &[u8] = b"a9yX32LpQvUt7wBc";
const IV: &[u8] = b"N7cPk2Bv38hWqFzM";

/// 视频分类静态回退：/api/categories 里 module=video 的 25 项，实测于 2026-11-05。
const CATS: &[(i64, &str)] = &[
    (1997, "Ai短剧"),
    (1661, "SM重味"),
    (1660, "AV明星"),
    (1659, "强奸乱伦"),
    (1658, "制服诱惑"),
    (1657, "人妻系列"),
    (1656, "中文字幕"),
    (1655, "伦理影片"),
    (1654, "自拍偷拍"),
    (1653, "成人动漫"),
    (1652, "欧美劲爆"),
    (1651, "国产主播"),
    (1650, "日韩无码"),
    (1649, "香港伦理"),
    (1648, "韩国伦理"),
    (1647, "邻家人妻"),
    (1646, "长腿丝袜"),
    (1645, "国模私拍"),
    (1644, "欧美情色"),
    (1643, "成人动漫"),
    (1642, "网红主播"),
    (1641, "AV明星"),
    (1640, "日本无码"),
    (1639, "国产情色"),
    (1634, "中文字幕"),
];

/// 站方跳转行为：6 位随机字母数字子域，通配解析，每次请求现取一个。
fn api_host() -> String {
    use rand::distributions::{Alphanumeric, DistString};
    let sub: String = Alphanumeric.sample_string(&mut rand::thread_rng(), 6);
    format!("https://{sub}.javzw.cyou")
}

/// AES-CBC/PKCS7 解密站方 cipher 字段（Base64），还原文 JSON。
fn decrypt_cipher(cipher_b64: &str) -> ApiResult<Value> {
    let raw = STANDARD
        .decode(cipher_b64.trim())
        .map_err(|e| ApiError::Internal(format!("Jav中文密文解码失败：{e}")))?;
    let decryptor = Decryptor::<Aes128>::new_from_slices(KEY, IV)
        .map_err(|e| ApiError::Internal(format!("Jav中文解密器失败：{e}")))?;
    let mut buf = raw.clone();
    let plain = decryptor
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|e| ApiError::Internal(format!("Jav中文解密失败：{e}")))?;
    serde_json::from_slice(plain)
        .map_err(|e| ApiError::Internal(format!("Jav中文解密结果非 JSON：{e}")))
}

/// 调 /api：响应有 cipher 则解密，无则按 {code, data} 取 data。
async fn api_get(path: &str) -> ApiResult<Value> {
    let url = format!("{}{path}", api_host());
    let mut last_err = String::new();
    for _ in 0..3 {
        match api_once(&url).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn api_once(url: &str) -> ApiResult<Value> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Jav中文请求 HTTP {status}")));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if let Some(cipher) = get(&body, "cipher") {
        if let Some(s) = cipher.as_str() {
            let v = decrypt_cipher(s)?;
            return Ok(match get(&v, "data") {
                Some(d) => d.clone(),
                None => v,
            });
        }
    }
    if let Some(code) = get(&body, "code") {
        if code.as_i64().unwrap_or(-1) != 0 {
            return Err(ApiError::Internal(format!(
                "Jav中文接口报错：{}",
                text_of(&body, &["msg"])
            )));
        }
    }
    Ok(match get(&body, "data") {
        Some(d) => d.clone(),
        None => body,
    })
}

fn fallback_categories() -> Value {
    json!({
    "categories": CATS
    .iter()
    .map(|(id, name)| category_json(&id.to_string(), name))
    .collect::<Vec<Value>>(),
    })
}

/// 分类解析：/api/categories 的 list 里只留 module=video 的项。
fn parse_categories(data: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(list) = get(data, "list").and_then(arr_of) {
        for item in list {
            if text_of(item, &["module"]) != "video" {
                continue;
            }
            let id = match get(item, "id") {
                Some(v) => v.to_string(),
                None => continue,
            };
            let name = text_of(item, &["name"]);
            if name.is_empty() {
                continue;
            }
            out.push(category_json(&id, &name));
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match api_get("/api/categories").await {
        Ok(data) => {
            let list = parse_categories(&data);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

fn parse_videos(data: &Value) -> (Vec<Value>, bool, i64) {
    let mut items = Vec::new();
    if let Some(list) = get(data, "list").and_then(arr_of) {
        for v in list {
            let id = match get(v, "id") {
                Some(x) => x.to_string(),
                None => continue,
            };
            let title = text_of(v, &["title"]);
            if title.is_empty() {
                continue;
            }
            let cover = text_of(v, &["cover_url"]);
            let remark = text_of(v, &["category"]);
            items.push(item_json(&id, &title, &cover, &remark));
        }
    }
    let page = get(data, "page").and_then(|v| v.as_i64()).unwrap_or(1);
    let pages = get(data, "pages").and_then(|v| v.as_i64()).unwrap_or(1);
    (items, page < pages, pages)
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = format!("/api/videos?category_id={category_id}&page={page}");
    let data = api_get(&path).await?;
    let (items, has_more, _) = parse_videos(&data);
    Ok(json!({"items": items, "has_more": has_more}))
}

/// play_url 解析：`占位$<m3u8>#第02集$<m3u8>…` 拆成（集名，地址）。
fn parse_play_list(play_url: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for part in play_url.split('#') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        match part.split_once('$') {
            Some((label, url)) => {
                let url = url.trim().to_string();
                if url.starts_with("http") {
                    let label = label.rsplit('/').next().unwrap_or(label).trim().to_string();
                    out.push((label, url));
                }
            }
            None => {
                if part.starts_with("http") {
                    out.push((format!("第{:02}集", out.len() + 1), part.to_string()));
                }
            }
        }
    }
    out
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let data = api_get(&format!("/api/movie?id={id}")).await?;
    let info = match get(&data, "info") {
        Some(v) => v,
        None => &data,
    };
    let title = text_of(info, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("Jav中文详情未返回标题".into()));
    }
    let cover = text_of(info, &["cover_url"]);
    let genre = text_of(info, &["category"]);
    let play_url = text_of(info, &["play_url"]);
    let eps = parse_play_list(&play_url);
    if eps.is_empty() {
        return Err(ApiError::Internal("Jav中文该视频暂无可播放地址".into()));
    }
    let episodes: Vec<Value> = eps
        .iter()
        .map(|(label, url)| episode_json(url, label, series_id))
        .collect();
    Ok(json!({
    "id": series_id,
    "title": title,
    "cover": cover,
    "synopsis": "",
    "extra": {"genre": genre},
    "episodes": episodes,
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("Jav中文该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let data = api_get(&format!("/api/videos?kw={enc}&page=1")).await?;
    let (items, _, _) = parse_videos(&data);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypt_cipher_real_vector() {
        let v = decrypt_cipher(
"rhmq8V3PSZVdTn76Lk7Cca1g3ehlClI7Egojdfn5i+oTFcqn7z1L38GrCxjVuXIP6r9Y1wnAIS1uhdZZrt0sXd32i80Gk/oebjG1e1MYPpk=",
)
.unwrap();
        assert_eq!(v["code"], 0);
        assert_eq!(v["data"]["count"], 2);
        assert_eq!(v["data"]["list"][0]["id"], 17392685);
    }

    #[test]
    fn parse_categories_filters_video_module() {
        let data = json!({"count": 4, "list": [
        {"id": 1997, "name": "Ai短剧", "module": "video"},
        {"id": 2075, "name": "乱伦天堂", "module": "website"},
        {"id": 1637, "name": "b", "module": "novel"},
        {"id": 1644, "name": "欧美情色", "module": "video"},
        ]});
        let list = parse_categories(&data);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "1997");
        assert_eq!(list[1]["name"], "欧美情色");
    }

    #[test]
    fn fallback_has_25_video_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 25);
        assert_eq!(list[0]["id"], "1997");
        assert_eq!(list[0]["name"], "Ai短剧");
        assert_eq!(list[24]["id"], "1634");
    }

    #[test]
    fn parse_videos_real_fragment() {
        let data = json!({"page": 1, "ps": 20, "total": 317408, "pages": 15871, "list": [
        {"id": 17392685, "title": "刘涛嫌弃老公能力不行的妻子，当着你的面被其他男人内射", "cover_url": "https://98jpg1.vip/upload/vod/20261019-1/de09373e40b2b1e51b73f09505256a2d.jpg", "play_url": "", "vip": 0, "category_id": 1997, "category": "Ai短剧"},
        {"id": 17392684, "title": "《家庭教师》", "cover_url": "https://98jpg1.vip/upload/vod/20261019-1/8404a893f045b40c80d76c6573b1d207.jpg", "play_url": "", "vip": 0, "category_id": 1997, "category": "Ai短剧"},
        ]});
        let (items, has_more, pages) = parse_videos(&data);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "17392685");
        assert_eq!(items[0]["remark"], "Ai短剧");
        assert!(has_more);
        assert_eq!(pages, 15871);
    }

    #[test]
    fn parse_play_list_real_fragment() {
        let play_url = "http://localhost:8080/第01集$https://c10.hs100.top/20261019/527d50d2a129a4f9/index.m3u8#第02集$https://c10.hs100.top/20261019/ef965a6964e6f0a5/index.m3u8";
        let eps = parse_play_list(play_url);
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].0, "第01集");
        assert_eq!(
            eps[0].1,
            "https://c10.hs100.top/20261019/527d50d2a129a4f9/index.m3u8"
        );
        assert_eq!(eps[1].0, "第02集");
        assert!(parse_play_list("").is_empty());
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://c10.hs100.top/20261019/527d50d2a129a4f9/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://c10.hs100.top/20261019/527d50d2a129a4f9/index.m3u8"
        );
    }
}
