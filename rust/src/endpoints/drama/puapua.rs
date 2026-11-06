//! PUA独家爆料：MacCMS 多域直取。
//!
//! 来源 jar 类 `ZakaPuapuaAmns`。两个备用域名依次探活（`GET /topic/`
//! 200 且含 `/voddetail/` 或 `vodst` 才算活，30 分钟缓存）；
//! 目录走 `/vodtype/{id}.html`；详情取 `player_aaaa` 后的 JSON 块
//! 里的 `url` 字段做取流。
//! 注意：Java 经本地代理改写 m3u8（相对分片/密钥地址转绝对并带
//! Referer 取回），Rust 核心 `play()` 只回原始 m3u8 直链，
//! 分片/密钥是否需带 Referer 待手机侧实测。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const POOL: &[&str] = &["https://puapua8.cc", "https://puapua7.cc"];
const PAGE_SIZE: i64 = 24;

const CATS: &[(&str, i64)] = &[
    ("麻豆视频", 6),
    ("91制片厂", 7),
    ("天美传媒", 8),
    ("蜜桃传媒", 9),
    ("皇家华人", 10),
    ("星空传媒", 11),
    ("精东影业", 12),
    ("乐播传媒", 20),
    ("兔子先生", 57),
    ("杏吧原创", 21),
    ("糖心Vlog", 22),
    ("玩偶姐姐", 24),
    ("mini传媒", 25),
    ("大象传媒", 26),
    ("乌鸦传媒", 31),
    ("成人头条", 30),
    ("国产精品", 60),
    ("华语AV", 61),
    ("国产自拍", 37),
    ("女优明星", 33),
    ("日本无码", 66),
    ("日韩无码", 71),
    ("中文字幕", 76),
    ("三级伦理", 29),
    ("欧美激情", 34),
    ("剧情动漫", 35),
    ("SM调教", 15),
    ("女同性恋", 70),
    ("乱伦精品", 64),
    ("强奸乱伦", 32),
    ("重口激情", 28),
    ("黑料吃瓜", 62),
    ("网曝吃瓜", 72),
    ("主播网红", 67),
    ("主播诱惑", 77),
    ("偷拍偷窥", 74),
    ("日韩主播", 75),
    ("传媒剧情", 79),
    ("抖阴短片", 80),
    ("AV解说", 81),
    ("换脸明星", 82),
    ("VR视角", 83),
    ("探花约炮", 65),
    ("学生合集", 63),
    ("自拍偷拍", 73),
];

static BASE_CACHE: Lazy<Mutex<Option<(String, std::time::Instant)>>> =
    Lazy::new(|| Mutex::new(None));

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn strip_tags(s: &str) -> String {
    let tag = Regex::new(r"<[^>]*>").unwrap();
    let collapsed = Regex::new(r"\s+").unwrap();
    collapsed
        .replace_all(tag.replace_all(s, " ").as_ref(), " ")
        .trim()
        .to_string()
}

fn abs_url(base: &str, u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{base}{u}")
    } else {
        u.to_string()
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                if let Ok(n) = u8::from_str_radix(hex, 16) {
                    out.push(n);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// Java `ZakaDrama.urldec`：`+` 先换成 `%2B` 再 URL 解码两次，
// `/` 还原。
fn urldec(s: &str) -> String {
    let once = percent_decode(&s.replace('+', "%2B")).replace("\\/", "/");
    percent_decode(&once).replace("\\/", "/")
}

async fn base() -> ApiResult<String> {
    {
        let guard = BASE_CACHE.lock().unwrap();
        if let Some((b, t)) = guard.as_ref() {
            if t.elapsed().as_secs() < 1800 {
                return Ok(b.clone());
            }
        }
    }
    let mut last_err = ApiError::Internal("PUA独家爆料全部域名不通".into());
    for host in POOL {
        let url = format!("{host}/topic/");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "text/html,*/*")
            .header("Referer", format!("{host}/"))
            .send()
            .await;
        match resp {
            Ok(r) => {
                if r.status().as_u16() != 200 {
                    continue;
                }
                let Ok(text) = r.text().await else {
                    continue;
                };
                if text.len() >= 2000 && (text.contains("/voddetail/") || text.contains("vodst")) {
                    let mut guard = BASE_CACHE.lock().unwrap();
                    *guard = Some((host.to_string(), std::time::Instant::now()));
                    return Ok(host.to_string());
                }
            }
            Err(e) => last_err = ApiError::Internal(e.to_string()),
        }
    }
    Err(last_err)
}

async fn fetch(path: &str) -> ApiResult<(String, String)> {
    let host = base().await?;
    let url = format!("{host}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{host}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("PUA独家爆料请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok((host, text))
}

fn cards(base: &str, page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    static RE_A: Lazy<Regex> =
        Lazy::new(|| Regex::new(r#"(?s)<a[^>]*href="([^"]*?/voddetail/[^"]*)"[^>]*>"#).unwrap());
    static RE_TITLE_ATTR: Lazy<Regex> = Lazy::new(|| Regex::new(r#"title="([^"]+)""#).unwrap());
    static RE_TITLE_POST: Lazy<Regex> =
        Lazy::new(|| Regex::new(r#"(?s)class="[^"]*title-post[^"]*"[^>]*>(.*?)</"#).unwrap());
    static RE_IMG: Lazy<Regex> = Lazy::new(|| Regex::new(r#"data-original="([^"]+)""#).unwrap());
    for cap in RE_A.captures_iter(page) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if href.is_empty() || !seen.insert(href.to_string()) {
            continue;
        }
        let start = cap.get(0).unwrap().start();
        let window = &page[start..page.len().min(start + 2000)];
        let mut title = RE_TITLE_ATTR
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| unescape(m.as_str()))
            .unwrap_or_default();
        if title.is_empty() {
            title = RE_TITLE_POST
                .captures(window)
                .and_then(|c| c.get(1))
                .map(|m| strip_tags(m.as_str()))
                .unwrap_or_default();
        }
        let cover = RE_IMG
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(base, m.as_str()))
            .unwrap_or_default();
        items.push(item_json(href, &title, &cover, "HD"));
    }
    items
}

/// 找 marker 之后最近的 `{...}` 括号匹配块并解析为 JSON。
fn blob(page: &str, marker: &str) -> Option<Value> {
    let pos = page.find(marker)?;
    let rest = &page[pos + marker.len()..];
    let start = rest.find('{')?;
    let bytes = rest[start..].as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    for (i, &b) in bytes.iter().enumerate() {
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else {
            match b {
                b'"' => in_str = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        let s = std::str::from_utf8(&bytes[..=i]).ok()?;
                        return serde_json::from_str::<Value>(s).ok();
                    }
                }
                _ => {}
            }
        }
    }
    None
}

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (name, id) in CATS {
        list.push(category_json(&id.to_string(), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let id = if category_id.is_empty() {
        "6"
    } else {
        category_id
    };
    let path = if page > 1 {
        format!("/vodtype/{id}-{page}.html")
    } else {
        format!("/vodtype/{id}.html")
    };
    let (host, page_html) = fetch(&path).await?;
    let items = cards(&host, &page_html);
    let has_more = items.len() as i64 >= PAGE_SIZE;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = if series_id.starts_with('/') {
        series_id.to_string()
    } else {
        format!("/{series_id}")
    };
    let (host, page_html) = fetch(&path).await?;
    let re_h1 = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let re_title = Regex::new(r"<title>([^<]+)</title>").unwrap();
    let re_og_img = Regex::new(r#"og:image"\s+content="([^"]+)""#).unwrap();
    let re_desc =
        Regex::new(r#"(?:name="description"|og:description)"\s+content="([^"]*)""#).unwrap();
    let re_cat = Regex::new(r"/vodtype/(\d+)\.html").unwrap();
    let re_play = Regex::new(r"/vodplay/(\d+)-(\d+)-(\d+)\.html").unwrap();
    let mut title = re_h1
        .captures(&page_html)
        .and_then(|c| c.get(1))
        .map(|m| strip_tags(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        title = cap1(&re_title, &page_html)
            .replace("详情介绍", "")
            .trim()
            .to_string();
    }
    let mut cover = cap1(&re_og_img, &page_html);
    if cover.is_empty() {
        static RE_IMG: Lazy<Regex> =
            Lazy::new(|| Regex::new(r#"data-original="([^"]+)""#).unwrap());
        cover = cap1(&RE_IMG, &page_html);
    }
    let cover = abs_url(&host, &cover);
    let desc = unescape(&cap1(&re_desc, &page_html));
    let cat_id = cap1(&re_cat, &page_html);
    let cat_name = CATS
        .iter()
        .find(|(_, id)| id.to_string() == cat_id)
        .map(|(name, _)| *name)
        .unwrap_or("");
    let mut seen = std::collections::HashSet::new();
    let mut episodes = Vec::new();
    for cap in re_play.captures_iter(&page_html) {
        let (line, ep) = (cap.get(2).unwrap().as_str(), cap.get(3).unwrap().as_str());
        let key = (line.to_string(), ep.to_string());
        if !seen.insert(key) {
            continue;
        }
        let name = if line == "1" {
            format!("第 {ep} 集")
        } else {
            format!("线路 {line} · 第 {ep} 集")
        };
        let url = format!(
            "{host}/vodplay/{}/{}/{}.html",
            cap.get(1).unwrap().as_str(),
            line,
            ep
        );
        episodes.push(episode_json(&url, &name, series_id));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("{host}{path}"), "播放", series_id));
    }
    let synopsis = format!(
        "{}{}来源：PUA独家爆料",
        if cat_name.is_empty() {
            String::new()
        } else {
            format!("分类：{cat_name}\n")
        },
        desc,
    );
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { "PUA独家爆料".to_string() } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"category": cat_name},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let path = format!("/vodsearch/-------------.html?wd={enc}");
    let (host, page_html) = fetch(&path).await?;
    let items = cards(&host, &page_html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({"url": video_id}));
    }
    let host = base().await?;
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{host}{video_id}")
    };
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,*/*")
        .header("Referer", format!("{host}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let mut stream = String::new();
    if let Some(b) = blob(&text, "player_aaaa") {
        if let Some(u) = b.get("url").and_then(|v| v.as_str()) {
            stream = urldec(u);
        }
    }
    if stream.is_empty() {
        static RE_URL: Lazy<Regex> =
            Lazy::new(|| Regex::new(r#""url"\s*:\s*"(https?:[^"]+\.m3u8[^"]*)""#).unwrap());
        stream = cap1(&RE_URL, &text).replace("\\/", "/");
    }
    if stream.is_empty() {
        // Java 回播放页本身（壳再解析）；这里如实回原地址。
        return Ok(json!({"url": url}));
    }
    Ok(json!({"url": stream}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_extracts_json_after_marker() {
        let page = "xxx player_aaaa = {\"url\":\"https://a/b.m3u8\",\"from\":\"x\"}; yyy";
        let b = blob(page, "player_aaaa").expect("blob");
        assert_eq!(b["url"], "https://a/b.m3u8");
    }

    #[test]
    fn urldec_double_decodes() {
        let raw = "https%253A%252F%252Fa%252Fb.m3u8";
        assert_eq!(urldec(raw), "https://a/b.m3u8");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a href="/voddetail/123.html" title="Sample"><img data-original="//img.example.com/1.jpg"></a>"##;
        let items = cards("https://puapua8.cc", html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/voddetail/123.html");
        assert_eq!(items[0]["title"], "Sample");
        assert_eq!(items[0]["cover"], "https://img.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "HD");
    }
}
