//! hwg4：成人小说站（hwg4 镜像，注意是 http）。
//!
//! 照搬 py 原文：分类 11 个编码 id；取数先过 FU1 包：正文里有
//! FU1("base64") 就 base64 解码再 JSON 解析出内层串；列表取
//! art-item 的 artdetail 字母数字 id 与 title 属性；目录
//! /arttype/id/ 与 /arttype/id-页/；详情标题取 <title> 首段、正
//! 文取 novel-content；搜索走 artsearch 的横线占位格式。核心里
//! 详情分集用文章 id，取流时现取全文拼 novel://。

use base64::{engine::general_purpose::STANDARD, Engine as _};
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "http://zffrbqg6y.www.hwg4.club";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 11] = [
    ("DCCCCD", "恋情"),
    ("LCCCCD", "武侠"),
    ("RCCCCD", "淫想"),
    ("XCCCCD", "伦理"),
    ("bCCCCD", "人妻"),
    ("mCCCCD", "校园"),
    ("uCCCCD", "都市"),
    ("VCCCCD", "经验"),
    ("TCCCCD", "真实"),
    ("vCCCCD", "另类"),
    ("0CCCCD", "笑话"),
];

static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static SCRIPT_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<script[^>]*>.*?</script>").unwrap());
static STYLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<style[^>]*>.*?</style>").unwrap());
static BR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());
static SPACE_RUN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[ \t]+").unwrap());
static WS_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static FU_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"FU1\("([^"]+)"\)"#).unwrap());
static ROW_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<div class="art-item">\s*<a href="/artdetail-([A-Za-z0-9]+)/" title="([^"]+)">"#).unwrap()
});
static TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<title>(.*?)</title>").unwrap());
static BODY_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<div class="novel-content"[^>]*>(.*?)</div>"#).unwrap()
});

/// py _fetch 的 FU1 解包：有 FU1 包就 base64 解码再 JSON 解析，
/// 解析出字符串才替换，否则保留原文；任一步失败保留原文。
fn fu_unpack(raw: &str) -> String {
    let Some(cap) = FU_RE.captures(raw) else {
        return raw.to_string();
    };
    let Ok(decoded) = STANDARD.decode(cap[1].as_bytes()) else {
        return raw.to_string();
    };
    let text = String::from_utf8_lossy(&decoded).into_owned();
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::String(inner)) => inner,
        _ => raw.to_string(),
    }
}

async fn fetch(url: &str) -> String {
    let resp = match client() {
        Ok(c) => {
            c.get(url)
                .header("User-Agent", UA)
                .header("Referer", format!("{BASE_URL}/"))
                .send()
                .await
        }
        Err(_) => return String::new(),
    };
    let resp = match resp {
        Ok(r) => r,
        Err(_) => return String::new(),
    };
    if resp.status().as_u16() != 200 {
        return String::new();
    }
    let text = resp.text().await.unwrap_or_default();
    fu_unpack(&text)
}

fn clean(raw: &str) -> String {
    let text = TAG_RE.replace_all(raw, "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"");
    WS_RUN_RE.replace_all(&text, " ").trim().to_string()
}

fn clean_text(raw: &str) -> String {
    let text = SCRIPT_RE.replace_all(raw, "");
    let text = STYLE_RE.replace_all(&text, "");
    let text = CLOSE_P_RE.replace_all(&text, "\n");
    let text = BR_RE.replace_all(&text, "\n");
    let text = TAG_RE.replace_all(&text, "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"");
    text.lines()
        .map(|ln| SPACE_RUN_RE.replace_all(ln, " ").trim().to_string())
        .filter(|ln| !ln.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn parse_list(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in ROW_RE.captures_iter(page) {
        let vid = cap[1].to_string();
        if !seen.insert(vid.clone()) {
            continue;
        }
        items.push(item_json(&vid, &clean(&cap[2]), "", ""));
    }
    items
}

fn take_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn novel_url(title: &str, content: &str) -> String {
    let payload = json!({"title": title, "content": content}).to_string();
    format!("novel://{payload}")
}

async fn detail_text(vid: &str) -> (String, String) {
    let page = fetch(&format!("{BASE_URL}/artdetail-{vid}/")).await;
    let title = TITLE_RE
        .captures(&page)
        .and_then(|cap| cap.get(1))
        .map(|m| clean(m.as_str()))
        .and_then(|t| t.split(" - ").next().map(str::trim).map(str::to_string))
        .unwrap_or_default();
    let text = BODY_RE
        .captures(&page)
        .and_then(|cap| cap.get(1))
        .map(|m| clean_text(m.as_str()))
        .unwrap_or_default();
    (title, text)
}

fn norm_id(value: &str) -> String {
    value.split(',').next().unwrap_or("").trim().to_string()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATEGORIES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if category_id.is_empty() {
        format!("{BASE_URL}/")
    } else if page <= 1 {
        format!("{BASE_URL}/arttype/{category_id}/")
    } else {
        format!("{BASE_URL}/arttype/{category_id}-{page}/")
    };
    let items = parse_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = norm_id(series_id);
    let (mut title, text) = detail_text(&vid).await;
    if title.is_empty() {
        title = vid.clone();
    }
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&text, 200),
        "extra": {},
        "episodes": [episode_json(&vid, "阅读", &vid)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = percent_encode_segment(query);
    let url = format!("{BASE_URL}/artsearch/-------/?wd={q}");
    let items = parse_list(&fetch(&url).await);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = match video_id.split_once('$') {
        Some((_, after)) => after,
        None => video_id,
    };
    if url.starts_with("novel://") {
        return Ok(json!({"url": url}));
    }
    let vid = url.strip_prefix("hwg4:").unwrap_or(url);
    let (title, text) = detail_text(vid).await;
    if text.is_empty() {
        return Err(ApiError::Internal("hwg4 该篇没有正文".into()));
    }
    Ok(json!({"url": novel_url(&title, &text)}))
}

fn percent_encode_segment(s: &str) -> String {
    use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
    const SEGMENT: &AsciiSet = &NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'~');
    utf8_percent_encode(s, SEGMENT).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fu_unpack_decodes_json_string() {
        let inner = "<p>正文</p>";
        let wrapped = serde_json::to_string(inner).unwrap();
        let encoded = STANDARD.encode(wrapped.as_bytes());
        let page = format!("xx FU1(\"{encoded}\") yy");
        assert_eq!(fu_unpack(&page), inner);
        assert_eq!(fu_unpack("plain page"), "plain page");
        assert_eq!(fu_unpack("FU1(\"!!!\")"), "FU1(\"!!!\")");
    }

    #[test]
    fn list_parses_alnum_ids() {
        let page = r#"<div class="art-item"><a href="/artdetail-Ab12/" title="标题">"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "Ab12");
    }
}
