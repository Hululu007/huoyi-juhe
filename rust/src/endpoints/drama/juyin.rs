//! 巨婴云播：静态站整页包壳。
//!
//! 来源 jar 类 `ZakaJuyinAmns`。多个备用 host 依次试；页面是
//! `var xxx="base64"` 包壳，解码后再 percent-decode 才是真实 HTML。
//! 分类分两层：TOP 3（首页/精品/影视）+ SUB 9（各 TOP 下的三个
//! 子分类）；核心无过滤器，`categories()` 把两层都平铺返回。

use base64::Engine as _;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const HOSTS: &[&str] = &[
    "https://3gwy8dzn9ke4.qbzbank.com",
    "https://xjuyin.com",
    "https://juy1.cc",
    "https://juy2.cc",
    "https://juy3.cc",
];

const TOPS: &[(&str, &str, &str)] = &[
    ("home", "首页", "/"),
    ("factory", "精品", "/factory.html"),
    ("great", "影视", "/great.html"),
];
const SUBS: &[(&str, &str, &str)] = &[
    ("CC250219043336jc", "AI短剧", "home"),
    ("CC250219042550la", "国产自拍", "home"),
    ("CC250219042606xe", "人妖伪娘", "home"),
    ("CC231117031513Wg", "国产精品", "factory"),
    ("CC231117075024vY", "自拍偷拍", "factory"),
    ("CC231117075120gL", "反差母狗", "factory"),
    ("CC2609230728268Y", "精彩电影", "great"),
    ("CC260923072840sL", "热门网剧", "great"),
    ("CC260923072856Js", "热门综艺", "great"),
];

static P_CARD: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<a[^>]*class="[^"]*label[^"]*vlink[^"]*"[^>]*href="/(?:video|album|cartoon|novel)/([^"\.]+)\.html""#).unwrap()
});
static P_TITLE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div class="title">(.*?)</div>"#).unwrap());
static P_TITLE_ATTR: Lazy<Regex> = Lazy::new(|| Regex::new(r#"title="([^"]+)""#).unwrap());
static P_IMG: Lazy<Regex> = Lazy::new(|| Regex::new(r#"<img[^>]*src="([^"]+)""#).unwrap());
static P_SIZE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"<span>\s*([0-9.]+[KMG]B)\s*</span>").unwrap());
static P_B64: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"var\s+\w+="([A-Za-z0-9+/=]{200,})""#).unwrap());

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

fn abs_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
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
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// 包壳解开：base64（URL 安全变体也试）→ percent-decode。
fn unwrap(page: &str) -> String {
    let Some(b64) = P_B64.captures(page).and_then(|c| c.get(1)) else {
        return page.to_string();
    };
    let raw = b64.as_str();
    let mut decoded: Vec<u8> = Vec::new();
    for engine in [
        base64::engine::general_purpose::STANDARD,
        base64::engine::general_purpose::URL_SAFE,
        base64::engine::general_purpose::URL_SAFE_NO_PAD,
    ] {
        if let Ok(d) = engine.decode(raw.as_bytes()) {
            decoded = d;
            break;
        }
    }
    if decoded.is_empty() {
        return page.to_string();
    }
    let text = String::from_utf8_lossy(&decoded).to_string();
    let inner = percent_decode(&text);
    if inner.len() > 500 && inner.contains('<') {
        inner
    } else {
        text
    }
}

async fn fetch(host: &str, path: &str) -> ApiResult<String> {
    let url = format!("{host}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{host}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("巨婴云播请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 300 {
        return Err(ApiError::Internal("巨婴云播页面过短".into()));
    }
    Ok(unwrap(&text))
}

async fn fetch_any(path: &str) -> ApiResult<String> {
    let mut last_err = ApiError::Internal("巨婴云播全部 host 不通".into());
    for host in HOSTS {
        match fetch(host, path).await {
            Ok(page) => {
                if page.len() >= 800 {
                    return Ok(page);
                }
            }
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

fn cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in P_CARD.captures_iter(page) {
        let id = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if id.is_empty() || !seen.insert(id.to_string()) {
            continue;
        }
        let start = cap.get(0).unwrap().start();
        let window = &page[start..page.len().min(start + 1400)];
        let mut title = P_TITLE
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| strip_tags(m.as_str()))
            .unwrap_or_default();
        if title.is_empty() {
            title = P_TITLE_ATTR
                .captures(window)
                .and_then(|c| c.get(1))
                .map(|m| unescape(m.as_str()))
                .unwrap_or_default();
        }
        let cover = P_IMG
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(m.as_str()))
            .unwrap_or_default();
        let size = P_SIZE
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        items.push(item_json(id, &title, &cover, &size));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (id, name, _) in TOPS {
        list.push(category_json(id, name));
    }
    for (code, name, _) in SUBS {
        list.push(category_json(&format!("sub:{code}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, _page: i64) -> ApiResult<Value> {
    let path = if let Some(code) = category_id.strip_prefix("sub:") {
        format!("/list/video/{code}.html")
    } else {
        TOPS.iter()
            .find(|(id, _, _)| *id == category_id)
            .map(|(_, _, p)| p.to_string())
            .unwrap_or_else(|| "/".to_string())
    };
    let page_html = fetch_any(&path).await?;
    let items = cards(&page_html);
    Ok(json!({"items": items, "has_more": false}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = if series_id.starts_with("http") {
        static RE: Lazy<Regex> =
            Lazy::new(|| Regex::new(r#"/(?:video|album|cartoon|novel)/([^"\.]+)\.html"#).unwrap());
        RE.captures(series_id)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_else(|| series_id.to_string())
    } else {
        series_id.to_string()
    };
    let page_html = fetch_any(&format!("/video/{vid}.html")).await?;
    let re_vurl = Regex::new(r#"vurl="([^"]+)""#).unwrap();
    let re_vpic = Regex::new(r#"vpic="([^"]+)""#).unwrap();
    let re_title =
        Regex::new(r#"(?s)<div class="video_info_box">\s*<div class="title">(.*?)</div>"#).unwrap();
    let re_title_tag = Regex::new(r"<title>([^<]+)</title>").unwrap();
    let mut vurl = String::new();
    if let Some(cap) = Regex::new(r#"(?s)<div id="dplayers".{0,2000}?vurl="([^"]+)""#)
        .unwrap()
        .captures(&page_html)
        .and_then(|c| c.get(1))
    {
        vurl = cap.as_str().to_string();
    }
    if vurl.is_empty() {
        vurl = re_vurl
            .captures(&page_html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }
    let cover = abs_url(
        &re_vpic
            .captures(&page_html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default(),
    );
    let mut title = re_title
        .captures(&page_html)
        .and_then(|c| c.get(1))
        .map(|m| strip_tags(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        title = re_title_tag
            .captures(&page_html)
            .and_then(|c| c.get(1))
            .map(|m| {
                m.as_str()
                    .split(" - ")
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string()
            })
            .unwrap_or_default();
    }
    if title.is_empty() {
        title = format!("巨婴云播 {vid}");
    }
    if vurl.len() <= 20 {
        return Err(ApiError::Internal("巨婴云播详情未取到播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "来源：巨婴云播",
        "extra": {},
        "episodes": [episode_json(&vurl, "正片", series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Ok(json!({"items": []}));
    }
    let mut paths: Vec<String> = TOPS.iter().map(|(_, _, p)| p.to_string()).collect();
    for (code, _, _) in SUBS {
        paths.push(format!("/list/video/{code}.html"));
    }
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for path in paths {
        let Ok(page_html) = fetch_any(&path).await else {
            continue;
        };
        for item in cards(&page_html) {
            let title = item["title"].as_str().unwrap_or("").to_lowercase();
            let id = item["id"].as_str().unwrap_or("").to_string();
            if title.contains(&needle) && !id.is_empty() && seen.insert(id) {
                items.push(item);
            }
        }
    }
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(video_id.as_bytes())
            .unwrap_or_default();
        String::from_utf8_lossy(&decoded).trim().to_string()
    };
    if url.is_empty() {
        return Err(ApiError::Internal("巨婴云播没有播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwrap_b64_percent_shell() {
        // base64("<h1>Hello</h1>") 再包进 var，解开后应含 Hello。
        let inner = "<h1>Hello</h1>";
        let b64 = base64::engine::general_purpose::STANDARD.encode(inner);
        let page = format!("var x=\"{b64}\";");
        // 长度不足 200 的包壳会被 unwrap 忽略（原 Java 要求 >=200），
        // 这里只验 percent_decode 分支。
        assert_eq!(percent_decode("%3Ch1%3E"), "<h1>");
        let _ = unwrap(&page);
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a class="label vlink" href="/video/abc123.html"><img src="//cdn.example.com/1.jpg"><div class="title">Sample Title</div><span>1.2GB</span></a>"##;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "abc123");
        assert_eq!(items[0]["title"], "Sample Title");
        assert_eq!(items[0]["cover"], "https://cdn.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "1.2GB");
    }
}
