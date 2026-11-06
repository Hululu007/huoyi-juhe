//! 大奶Ai短剧：核心里的影视区站点。
//!
//! 与大奶Ai短剧同一套 Nuxt 模板（buildId ac81435c）：入口
//! https://hgai8.cc/?from=yng 是 JS 跳转页，生成 6 位随机子域
//! 名跳到 https://<随机6位>.danai88.cyou/?from=yng；数据走同源
//! /api，响应 {cipher} 用同一套 AES-128-CBC（密钥
//! a9yX32LpQvUt7wBc，IV N7cPk2Bv38hWqFzM）解密。
//! 与站导航 1:1（视频型 30 个，site_id 48；另 3 个 website
//! 型是站内导航链接，不列入）。每分类仅 12 条（count 12，
//! p2 与 p1 相同），无多页。目录
//! /api/categories/videos?ids=<分类id>&page=1；详情
//! /api/movie?id=<id>；搜索 /api/videos?kw=<词>&page=1。
//! 本站 play_url 的 $ 后是直链 m3u8（与大奶Ai短剧的播放
//! 页地址不同），形如
//! `http://localhost:8080/第01集$https://c10.hs100.top/.../index.m3u8`，
//! play() 遇直链直接返回；若 $ 后是播放页地址则走萝莉AI
//! 短剧同款播放页解析（player_data + huangguo.php）。
//! 已验：目录 AI短剧 12 条有真封面；搜索“短剧”15 条；
//! 详情《母子禁忌》；取流 m3u8 清单 200（5076 字节、
//! AES-128），首分片回 200、Content-Length 约 1.6MB，本机
//! 出口断连两次只收到 441KB/523KB，未能下全，手机侧复验。
//! 已验视频 vip 均为 0，未触付费墙。
//! 注意：本站与已在核心的 🔞黄瓜视频（cucumber，App 接口
//! api66.capcom.work 等）不是同站：域名、接口、分类全不同。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use aes::Aes128;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
use cbc::Decryptor;
use once_cell::sync::Lazy;
use rand::Rng;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, str_of, text_of,
    with_query,
};

const ENTRY: &str = "https://danai88.cc/?from=yng";
const SUFFIX_FALLBACK: &str = "danai88.cyou";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const AES_KEY: &[u8] = b"a9yX32LpQvUt7wBc";
const AES_IV: &[u8] = b"N7cPk2Bv38hWqFzM";

/// 分类静态回退：与站导航一致，实测于 2026-11-05（site_id 50）。
const CATS: &[(&str, &str)] = &[
    ("2012", "AI成人漫剧"),
    ("2011", "Ai魔改"),
    ("2010", "AI成人短剧"),
    ("1908", "AI短剧"),
    ("1907", "野外露出"),
    ("1906", "女同性恋"),
    ("1905", "变性伪娘"),
    ("1904", "动漫卡通"),
    ("1903", "主奴调教"),
    ("1901", "人妻熟女"),
    ("1899", "欧美激情"),
    ("1897", "韩国三级"),
    ("1895", "强奸乱伦"),
    ("1893", "角色剧情"),
    ("1892", "凌辱快感"),
    ("1890", "多人群交"),
    ("1888", "无码流出"),
    ("1886", "中文字幕"),
    ("1884", "丝袜美腿"),
    ("1882", "制服诱惑"),
    ("1881", "重口性癖"),
    ("1878", "V R 视角"),
    ("1877", "A I 换脸"),
    ("1875", "反差母狗"),
    ("1873", "足浴撩妹"),
    ("1871", "港台辣妹"),
    ("1869", "淫妻作乐"),
    ("1867", "A V 解说"),
    ("1865", "清纯学生"),
    ("1864", "传媒探花"),
    ("1861", "网曝事件"),
    ("1860", "制服丝袜"),
    ("1858", "自拍偷拍"),
    ("1857", "国产乱伦"),
    ("1853", "国产主播"),
    ("1852", "精品推荐"),
];

/// 真站基址缓存 10 分钟：入口每次都要现取跳转页，随机子域名
/// 在缓存期内复用，过期再解析。
static BASE_CACHE: Lazy<Mutex<(String, Instant)>> =
    Lazy::new(|| Mutex::new((String::new(), Instant::now() - Duration::from_secs(3600))));

fn rand_sub() -> String {
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut rng = rand::thread_rng();
    (0..6)
        .map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char)
        .collect()
}

fn suffix_from_entry(html: &str) -> Option<String> {
    let re = Regex::new(r#"randomSub \+ "\.([A-Za-z0-9.\-]+\.cyou)/"#).ok()?;
    re.captures(html).map(|c| c[1].to_string())
}

async fn resolve_base() -> ApiResult<String> {
    {
        let cache = BASE_CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if !cache.0.is_empty() && cache.1.elapsed() < Duration::from_secs(600) {
            return Ok(cache.0.clone());
        }
    }
    let suffix = match client()?.get(ENTRY).header("User-Agent", UA).send().await {
        Ok(resp) if resp.status().as_u16() == 200 => match resp.text().await {
            Ok(html) => suffix_from_entry(&html).unwrap_or_else(|| SUFFIX_FALLBACK.to_string()),
            Err(_) => SUFFIX_FALLBACK.to_string(),
        },
        _ => SUFFIX_FALLBACK.to_string(),
    };
    let base = format!("https://{}.{}", rand_sub(), suffix);
    if let Ok(mut cache) = BASE_CACHE.lock() {
        *cache = (base.clone(), Instant::now());
    }
    Ok(base)
}

/// AES-128-CBC 解密 cipher 字段：base64 解码后 PKCS7 去垫。
fn aes_decrypt(ciphertext_b64: &str) -> ApiResult<String> {
    let raw = STANDARD
        .decode(ciphertext_b64.trim())
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧返回数据 base64 解码失败：{e}")))?;
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Err(ApiError::Internal("大奶Ai短剧返回数据长度异常".into()));
    }
    let plain = Decryptor::<Aes128>::new_from_slices(AES_KEY, AES_IV)
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧解密器初始化失败：{e}")))?
        .decrypt_padded_vec_mut::<Pkcs7>(&raw)
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧 AES 解密失败：{e}")))?;
    String::from_utf8(plain)
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧解密结果非 UTF-8：{e}")))
}

/// API GET：响应 {cipher} 解密成 JSON；{code,data} 校验 code。
async fn api_json(path: &str) -> ApiResult<Value> {
    let base = resolve_base().await?;
    let url = format!("{base}/api{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧请求失败：{e}")))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("大奶Ai短剧请求 HTTP {status}")));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧响应非 JSON：{e}")))?;
    let body = match get(&body, "cipher") {
        Some(c) => {
            let text = aes_decrypt(&str_of(c))?;
            serde_json::from_str(&text)
                .map_err(|e| ApiError::Internal(format!("大奶Ai短剧解密后非 JSON：{e}")))?
        }
        None => body,
    };
    let code = int_of(&body, &["code"]);
    if code != 0 {
        let msg = text_of(&body, &["msg"]);
        return Err(ApiError::Internal(format!(
            "大奶Ai短剧接口返回 {code}{}",
            if msg.is_empty() {
                String::new()
            } else {
                format!("：{msg}")
            }
        )));
    }
    Ok(body)
}

/// 封面归一：站内相对路径补基址；绝对地址里主机后的双斜杠压成一个。
fn fix_url(raw: &str, base: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{base}{u}");
    }
    if let Some((scheme, rest)) = u.split_once("://") {
        if let Some((host, path)) = rest.split_once('/') {
            let mut cleaned = String::new();
            let mut prev_slash = false;
            for ch in path.chars() {
                if ch == '/' {
                    if prev_slash {
                        continue;
                    }
                    prev_slash = true;
                } else {
                    prev_slash = false;
                }
                cleaned.push(ch);
            }
            let cleaned = cleaned.trim_start_matches('/');
            return format!("{scheme}://{host}/{cleaned}");
        }
    }
    u.to_string()
}

/// 分类解析：只留 module 为 video 的分类，按站内顺序。
fn parse_categories(body: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    let data = match get(body, "data") {
        Some(d) => d,
        None => return out,
    };
    if let Some(list) = get(data, "list").and_then(arr_of) {
        for item in list {
            if text_of(item, &["module"]) != "video" {
                continue;
            }
            let id = text_of(item, &["id"]);
            let name = text_of(item, &["name"]);
            if !id.is_empty() && !name.is_empty() {
                out.push(category_json(&id, &name));
            }
        }
    }
    out
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

/// 列表解析：data.list 里的 id/title/cover_url。
fn parse_items(body: &Value, base: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let data = match get(body, "data") {
        Some(d) => d,
        None => return items,
    };
    if let Some(list) = get(data, "list").and_then(arr_of) {
        for item in list {
            let id = text_of(item, &["id"]);
            let title = text_of(item, &["title"]);
            if id.is_empty() || title.is_empty() {
                continue;
            }
            let cover = fix_url(&text_of(item, &["cover_url"]), base);
            items.push(item_json(&id, &title, &cover, ""));
        }
    }
    items
}

fn list_count(body: &Value) -> i64 {
    match get(body, "data") {
        Some(d) => int_of(d, &["count", "total"]),
        None => 0,
    }
}

/// 集数解析：play_url 按 `#` 分集，每集 `第NN集$<播放页地址>`，
/// localhost 前缀是脏数据，只取 $ 后的播放页地址。
fn parse_episodes(play_url: &str, series_id: &str) -> Vec<Value> {
    let mut episodes = Vec::new();
    for part in play_url.split('#') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((name, url)) = part.split_once('$') {
            let url = url.trim();
            if url.starts_with("http") {
                let name = name.trim();
                let name = name.rsplit('/').next().unwrap_or(name);
                episodes.push(episode_json(url, name, series_id));
            }
        }
    }
    episodes
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match api_json("/categories").await {
        Ok(body) => {
            let list = parse_categories(&body);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = with_query(
        "/categories/videos",
        &[("ids", category_id), ("page", &page.to_string())],
    );
    let body = api_json(&path).await?;
    let base = resolve_base().await?;
    let items = parse_items(&body, &base);
    let count = list_count(&body);
    let has_more = count > 0 && page * (items.len() as i64) < count;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let body = api_json(&with_query("/movie", &[("id", series_id)])).await?;
    let base = resolve_base().await?;
    let data = get(&body, "data").cloned().unwrap_or(Value::Null);
    let info = get(&data, "info").cloned().unwrap_or(Value::Null);
    let title = text_of(&info, &["title"]);
    let cover = fix_url(&text_of(&info, &["cover_url"]), &base);
    let play_url = text_of(&info, &["play_url"]);
    if title.is_empty() || play_url.is_empty() {
        return Err(ApiError::Internal("大奶Ai短剧详情未返回播放地址".into()));
    }
    let episodes = parse_episodes(&play_url, series_id);
    if episodes.is_empty() {
        return Err(ApiError::Internal("大奶Ai短剧详情未解析出集数".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {
            "category": text_of(&info, &["category"]),
            "hits": int_of(&info, &["hits"]),
        },
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = with_query("/videos", &[("kw", query), ("page", "1")]);
    let body = api_json(&path).await?;
    let base = resolve_base().await?;
    let items = parse_items(&body, &base);
    Ok(json!({"items": items}))
}

/// 播放页里的 player_data：url 为 `725|1`，from 为 huangguo。
fn parse_player_data(html: &str) -> Option<(String, String)> {
    let re = Regex::new(r#"player_data=\{"[^}]*"url":"([^"]+)"[^}]*"from":"([^"]+)""#).ok()?;
    re.captures(html)
        .map(|c| (c[1].to_string(), c[2].to_string()))
}

/// 播放页里直接嵌的 m3u8 地址（91crdjai.com 那路），\u0026 还原成 &。
fn parse_direct_m3u8(html: &str) -> String {
    let re = match Regex::new(r#"https?://[^\s"']+\.m3u8[^\s"']*"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.find(html) {
        Some(m) => m.as_str().replace("\\u0026", "&").replace("\\/", "/"),
        None => String::new(),
    }
}

/// 播放页 origin：`https://<host>`。
fn page_origin(url: &str) -> String {
    if let Some((scheme, rest)) = url.split_once("://") {
        let host = rest.split('/').next().unwrap_or("");
        return format!("{scheme}://{host}");
    }
    url.to_string()
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({"url": video_id}));
    }
    if !video_id.starts_with("http") {
        return Err(ApiError::Internal("大奶Ai短剧该集没有播放页地址".into()));
    }
    let html = client()?
        .get(video_id)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧播放页请求失败：{e}")))?
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧播放页读取失败：{e}")))?;
    let direct = parse_direct_m3u8(&html);
    if !direct.is_empty() {
        return Ok(json!({"url": direct}));
    }
    let (code, from) = match parse_player_data(&html) {
        Some(v) => v,
        None => {
            return Err(ApiError::Internal("大奶Ai短剧播放页未返回播放地址".into()));
        }
    };
    if from != "huangguo" {
        return Err(ApiError::Internal(format!("大奶Ai短剧未知的播放源 {from}")));
    }
    let mut parts = code.split('|');
    let id = parts.next().unwrap_or("");
    let ep = parts.next().unwrap_or("");
    if id.is_empty() || ep.is_empty() {
        return Err(ApiError::Internal("大奶Ai短剧播放参数解析失败".into()));
    }
    let origin = page_origin(video_id);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let api = format!("{origin}/huangguo.php?ac=play&id={id}&ep={ep}&_={millis}");
    let resp = client()?
        .get(&api)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧取流请求失败：{e}")))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("大奶Ai短剧取流 HTTP {status}")));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("大奶Ai短剧取流响应非 JSON：{e}")))?;
    if int_of(&body, &["code"]) != 1 {
        return Err(ApiError::Internal("大奶Ai短剧取流解析失败".into()));
    }
    let proxy = text_of(&body, &["url"]);
    if !proxy.starts_with("/hgmedia.php?e=") {
        return Err(ApiError::Internal("大奶Ai短剧代理播放地址格式错误".into()));
    }
    Ok(json!({"url": format!("{origin}{proxy}")}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_from_entry_js() {
        let html =
            r#"var targetUrl = "https://" + randomSub + ".danai88.cyou/?from=" + finalFrom;"#;
        assert_eq!(suffix_from_entry(html).as_deref(), Some("danai88.cyou"));
        assert!(suffix_from_entry("<html>no redirect</html>").is_none());
    }

    #[test]
    fn parse_categories_real_sample() {
        let body: Value = serde_json::from_str(
            r#"{"code":0,"data":{"count":39,"list":[{"id":2081,"name":"乱伦天堂","module":"website","sort":0,"site_id":50,"parent_id":0},{"id":2012,"name":"AI成人漫剧","module":"video","sort":0,"site_id":50,"parent_id":0},{"id":2011,"name":"Ai魔改","module":"video","sort":0,"site_id":50,"parent_id":0},{"id":2010,"name":"AI成人短剧","module":"video","sort":0,"site_id":50,"parent_id":0},{"id":1910,"name":"视频分类","module":"website","sort":0,"site_id":50,"parent_id":0},{"id":1908,"name":"AI短剧","module":"video","sort":0,"site_id":50,"parent_id":0},{"id":1850,"name":"名站导航","module":"website","sort":0,"site_id":50,"parent_id":0}],"site_id":50},"msg":"ok"}"#,
        )
        .unwrap();
        let list = parse_categories(&body);
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "2012");
        assert_eq!(list[0]["name"], "AI成人漫剧");
        assert_eq!(list[3]["id"], "1908");
        assert_eq!(list[3]["name"], "AI短剧");
    }

    #[test]
    fn fallback_has_36_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 36);
        assert_eq!(list[0]["id"], "2012");
        assert_eq!(list[35]["name"], "精品推荐");
    }

    #[test]
    fn parse_items_real_sample() {
        let body: Value = serde_json::from_str(
            r#"{"code":0,"data":{"count":12,"list":[{"id":17396958,"title":"《健身美母》","cover_url":"https://98jpg1.vip/upload/vod/20261012-1/6318d29f4d459e44392ae271b7362b17.jpg","play_url":"http://localhost:8080/第01集$https://aim3u8.vip/20261013/202175bbbe44d977/index.m3u8#第02集$https://aim3u8.vip/20261016/8f19c821e8633914/index.m3u8#第03集$https://aim3u8.vip/20261021/42eb16f36171688a/index.m3u8","play_from":"m3u8","vip":0,"hits":27155,"status":1,"category_id":1908,"category":"AI短剧","site_id":50}]},"msg":"ok"}"#,
        )
        .unwrap();
        let items = parse_items(&body, "https://x.danai88.cyou");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "17396958");
        assert_eq!(items[0]["title"], "《健身美母》");
        assert_eq!(
            items[0]["cover"],
            "https://98jpg1.vip/upload/vod/20261012-1/6318d29f4d459e44392ae271b7362b17.jpg"
        );
        assert_eq!(
            items[0]["cover"],
            "https://98jpg1.vip/upload/vod/20261012-1/6318d29f4d459e44392ae271b7362b17.jpg"
        );
        assert_eq!(list_count(&body), 12);
    }

    #[test]
    fn parse_episodes_real_sample() {
        let play_url = "http://localhost:8080/第01集$https://aim3u8.vip/20261013/202175bbbe44d977/index.m3u8#第02集$https://aim3u8.vip/20261016/8f19c821e8633914/index.m3u8#第03集$https://aim3u8.vip/20261021/42eb16f36171688a/index.m3u8";
        let eps = parse_episodes(play_url, "17396958");
        assert_eq!(eps.len(), 3);
        assert_eq!(
            eps[0]["video_id"],
            "https://aim3u8.vip/20261013/202175bbbe44d977/index.m3u8"
        );
        assert_eq!(eps[0]["title"], "第01集");
        assert_eq!(eps[2]["title"], "第03集");
        assert!(parse_episodes("", "1").is_empty());
    }

    #[test]
    fn parse_player_data_real_sample() {
        let html = r#"var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/play\/2292-1-1\/","link_next":"","link_pre":"","url":"725|1","url_next":"","from":"huangguo","server":"no","note":""}</script>"#;
        assert_eq!(
            parse_player_data(html)
                .as_ref()
                .map(|(u, f)| (u.as_str(), f.as_str())),
            Some(("725|1", "huangguo"))
        );
        assert!(parse_player_data("<div>no player</div>").is_none());
    }

    #[test]
    fn parse_direct_m3u8_unescape() {
        let html = r#"src":"https://yd-zhqr-hls.hzjvlo.cn/videos5/9afb210f043b26d17dde629a363a0c4b/9afb210f043b26d17dde629a363a0c4b.m3u8?auth_key=1793893115-158.web.38646d3d-0-0a6065d4510974cd9c0c3172b78b2712\u0026v=3\u0026time=0\u0026via=91crdj\u0026via_bm=dx""#;
        let url = parse_direct_m3u8(html);
        assert!(url.starts_with("https://yd-zhqr-hls.hzjvlo.cn/videos5/"));
        assert!(url.ends_with("&via=91crdj&via_bm=dx"));
        assert!(!url.contains("\\u0026"));
        assert_eq!(parse_direct_m3u8("<div>no stream</div>"), "");
    }

    #[test]
    fn page_origin_cases() {
        assert_eq!(
            page_origin("https://2p7i6st1.aisee10w11.buzz/play/2292-1-1/"),
            "https://2p7i6st1.aisee10w11.buzz"
        );
        assert_eq!(
            page_origin("https://91crdjai.com/shipin/480-x/1/"),
            "https://91crdjai.com"
        );
    }

    #[test]
    fn aes_decrypt_roundtrip() {
        use cbc::cipher::{BlockEncryptMut, KeyIvInit};
        use cbc::Encryptor;
        let plain = br#"{"code":0,"data":{"count":1,"list":[]},"msg":"ok"}"#;
        let ct = Encryptor::<Aes128>::new_from_slices(AES_KEY, AES_IV)
            .unwrap()
            .encrypt_padded_vec_mut::<Pkcs7>(plain);
        let b64 = STANDARD.encode(&ct);
        let back = aes_decrypt(&b64).unwrap();
        assert_eq!(back, String::from_utf8_lossy(plain));
    }
}
