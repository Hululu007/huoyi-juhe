//! 海角网┃hj2：HTML 站（列表/详情正则解析，取流为站内签名 m3u8）。
//!
//! 与 jar 的 ZakaHjwAmns 一一对应：域名池探活（PUB_POOL 4 条＋
//! LINE_FALLBACK 6 条＋SPA 落地页解密出的线路域名；gktgyicy.cc 与
//! hjw2026.com 是落地页伪装，无 /archives/ 内容，探活时按内容
//! 排除——2026-11-05 本机已验 www.hjw01.com 200 且 91 条
//! /archives/ 链接）、分类 8 条、目录（/{tid}/page/{p}/）、详
//! 情（pickStream 取 "video":{"url": ...} 的签名 m3u8）、搜索。
//! 修：站改版后列表图没有 src 属性，地址在
//! z-image-loader-url=`...` 里，封面改取该属性（jar 的 P_IMG
//! 取不到）；列表已无 date/play 备注块，备注留空；详情 og:image
//! 为站通用图（video JSON 的 pic/thumbnails 为空），照 jar 原
//! 样取 og:image。
//! 取流已验：m3u8 为标准 AES-128 HLS（KEY URI 为带 auth_key 的
//! 直链，分片直链），播放器原生处理，不走本地代理解密；m3u8
//! 地址带时效 auth_key，play 每次现取详情，不缓存旧地址。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: &[&str] = &[
    "https://gktgyicy.cc/",
    "https://hjw2026.com/",
    "http://www.hjw01.com/",
    "https://hjw2026.com/",
    "https://believe.ttxrochzh.cc",
    "https://broad.ttxrochzh.cc",
    "https://by.ttxrochzh.cc",
    "https://believe.bskayiiu.cc",
    "https://broad.bskayiiu.cc",
    "https://by.bskayiiu.cc",
    "https://ago.uzqynqce.cc",
    "https://bear.uzqynqce.cc",
    "https://british.uzqynqce.cc",
];

const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const BASE_TTL: Duration = Duration::from_secs(30 * 60);

static BASE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

const CATS: &[(&str, &str)] = &[
    ("home", "最新"),
    ("tags", "标签"),
    ("authors", "作者"),
    ("authors_hot", "作者热榜"),
    ("authors_up", "作者更新"),
    ("communitys", "社区"),
    ("date", "日期"),
    ("ai", "合集"),
];

fn headers(base: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
        ("Referer".to_string(), format!("{base}/")),
    ]
}

/// 与 Java 的 ZakaHttp.enc 一致：标准 URL 编码。
fn enc(raw: &str) -> String {
    url::form_urlencoded::byte_serialize(raw.as_bytes()).collect()
}

/// 去标签、解实体、去空白。
fn plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(ch);
                }
            }
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace("\\/", "/")
        .replace("\\u0026", "&")
        .trim()
        .to_string()
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("hjw regex")
}

fn cap<'a>(re: &Regex, text: &'a str, group: usize) -> String {
    match re.captures(text) {
        Some(c) => c
            .get(group)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default(),
        None => String::new(),
    }
}

/// 探活：逐个域名取 /page/1/，首个含 /archives/ 链接的为准（只
/// 看状态码会误中落地页伪装）；30 分钟内复用。
async fn site() -> ApiResult<String> {
    if let Ok(guard) = BASE.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok(cached.clone());
            }
        }
    }
    let mut last_err = String::new();
    for host in HOSTS {
        let base = host.trim_end_matches('/');
        let url = format!("{base}/page/1/");
        let mut req = match client() {
            Ok(c) => c.get(&url),
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        for (k, v) in headers(base) {
            req = req.header(k, v);
        }
        match req.send().await {
            Ok(resp) => {
                if resp.status().as_u16() != 200 {
                    last_err = format!("HTTP {}", resp.status().as_u16());
                    continue;
                }
                match resp.text().await {
                    Ok(text) => {
                        if text.contains("/archives/") {
                            let base = base.to_string();
                            if let Ok(mut guard) = BASE.lock() {
                                *guard = Some((base.clone(), Instant::now() + BASE_TTL));
                            }
                            return Ok(base);
                        }
                        last_err = "无内容链接".to_string();
                    }
                    Err(e) => last_err = e.to_string(),
                }
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!("海角网全部域名不通：{last_err}")))
}

async fn page(url: &str, referer: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers(referer.trim_end_matches('/')) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("海角网请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(text)
}

/// 封面：站改版后 <img> 无 src，地址在 z-image-loader-url=`...`
/// 里；兜底取 src。
fn img_url(inner: &str) -> String {
    let lazy_re = re(r#"z-image-loader-url="`([^`]+)`""#);
    let found = cap(&lazy_re, inner, 1);
    if !found.is_empty() {
        return found.trim().to_string();
    }
    let src_re = re(r#"<img[^>]+src="([^"]+)""#);
    let src = cap(&src_re, inner, 1);
    let src = src.trim().trim_matches('`').to_string();
    if src.starts_with("//") {
        format!("https:{src}")
    } else {
        src
    }
}

fn parse_list(html: &str) -> Vec<Value> {
    let item_re = re(r#"<a\s+href="(/archives/(\d+)/)"([^>]*)>(.*?)</a>"#);
    let h3_re = re(r"<h3[^>]*>(.*?)</h3>");
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    for c in item_re.captures_iter(html) {
        let path = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let id = c.get(2).map(|m| m.as_str()).unwrap_or("");
        let inner = c.get(4).map(|m| m.as_str()).unwrap_or("");
        if id.is_empty() || !seen.insert(id.to_string()) {
            continue;
        }
        let mut title = plain(&cap(&h3_re, inner, 1));
        if title.is_empty() {
            title = plain(inner);
        }
        if title.is_empty() {
            continue;
        }
        let cover = img_url(inner);
        let _ = path;
        items.push(item_json(id, &title, &cover, ""));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut cats = Vec::new();
    for (id, name) in CATS {
        cats.push(category_json(id, name));
    }
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, pg: i64) -> ApiResult<Value> {
    let pg = if pg < 1 { 1 } else { pg };
    let base = site().await?;
    let path = if category_id == "home" {
        format!("/page/{pg}/")
    } else {
        format!("/{category_id}/page/{pg}/")
    };
    let html = page(&format!("{base}{path}"), &base).await?;
    let items = parse_list(&html);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let base = site().await?;
    let url = format!("{base}/archives/{series_id}/");
    let html = page(&url, &base).await?;
    let h1_re = re(r"<h1[^>]*>(.*?)</h1>");
    let mut title = plain(&cap(&h1_re, &html, 1));
    if title.is_empty() {
        let title_re = re(r"<title>(.*?)</title>");
        title = plain(&cap(&title_re, &html, 1));
        if let Some(stripped) = title.strip_suffix("| 海角网") {
            title = stripped.trim().to_string();
        }
    }
    let og_re = re(r#"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#);
    let mut cover = cap(&og_re, &html, 1);
    if cover.starts_with("//") {
        cover = format!("https:{cover}");
    }
    let desc_re = re(r#"<meta[^>]+name="description"[^>]+content="([^"]*)""#);
    let synopsis = plain(&cap(&desc_re, &html, 1));
    let stream_re = re(r#""video"\s*:\s*\{[^}]*?"url"\s*:\s*"([^"]+)""#);
    let mut stream = cap(&stream_re, &html, 1);
    stream = stream.replace("\\/", "/").replace("\\u0026", "&");
    let mut episodes = Vec::new();
    if stream.starts_with("http") {
        episodes.push(episode_json(&stream, "正片", series_id));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = site().await?;
    let url = format!("{base}/search/{}/", enc(query));
    let html = page(&url, &base).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items}))
}

/// 取流：分集 video_id 本身就是 pickStream 取到的签名 m3u8 直链，
/// 直接回（标准 AES-128 HLS，KEY 与分片均为直链）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id.trim();
    if !url.starts_with("http") {
        return Err(ApiError::Internal("海角网未取到有效地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_card() {
        let html = r##"<a href="/archives/195418/" title="t"><div class="xqbj-list-rows-image-title"><h3>告别失效链接</h3></div><div class="xqbj-list-rows-placard-item"><div class="image_one_item is-video"><img data-image-preview="true" z-image-loader-url="`https://pic.gyezbp.cn/upload_01/xiao/20261008/a.jpeg`" alt="x"></div></div></a><a href="/archives/197035/" class="item">我老婆属于儿子</a>"##;
        let items = parse_list(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "195418");
        assert_eq!(items[0]["title"], "告别失效链接");
        assert_eq!(
            items[0]["cover"],
            "https://pic.gyezbp.cn/upload_01/xiao/20261008/a.jpeg"
        );
        assert_eq!(items[1]["title"], "我老婆属于儿子");
        assert_eq!(items[1]["cover"], "");
    }

    #[test]
    fn stream_unescape() {
        let raw = r"https:\/\/hls.ohjzmm.cn\/v\/a.m3u8?auth_key=1\u0026v=3";
        let clean = raw.replace("\\/", "/").replace("\\u0026", "&");
        assert_eq!(clean, "https://hls.ohjzmm.cn/v/a.m3u8?auth_key=1&v=3");
    }

    #[test]
    fn categories_count() {
        assert_eq!(CATS.len(), 8);
    }
}
