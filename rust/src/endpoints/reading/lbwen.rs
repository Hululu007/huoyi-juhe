//! lbwen：成人小说站（lbwen.com）。
//!
//! 照搬 py 原文：分类 11 个（与 cjg 同套）；列表取 dt 行的
//! artdetail id 与标题；首页列表取人妻分类（30）；目录
//! /arttype/id.html 与 /arttype/id-页.html；详情标题取 <title>
//! 首段、正文取 Readarea ReadAjax_content；搜索走 artsearch 的
//! 横线占位格式。核心里详情分集用文章 id，取流时现取全文拼
//! novel://。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://www.lbwen.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 11] = [
    ("30", "人妻"),
    ("20", "都市"),
    ("21", "校园"),
    ("22", "真实"),
    ("23", "武侠"),
    ("24", "乱伦"),
    ("25", "职场"),
    ("26", "经验"),
    ("27", "暴力"),
    ("28", "幻想"),
    ("29", "明星"),
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
static ROW_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<dt>\s*<span[^>]*>[^<]*</span>\s*<a href="/artdetail-(\d+)\.html">([^<]+)</a>"#).unwrap()
});
static TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<title>(.*?)</title>").unwrap());
static BODY_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<div class="Readarea ReadAjax_content"[^>]*>(.*?)</div>"#)
        .unwrap()
});

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
    resp.text().await.unwrap_or_default()
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
    let page = fetch(&format!("{BASE_URL}/artdetail-{vid}.html")).await;
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
        format!("{BASE_URL}/arttype/30.html")
    } else if page <= 1 {
        format!("{BASE_URL}/arttype/{category_id}.html")
    } else {
        format!("{BASE_URL}/arttype/{category_id}-{page}.html")
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
    let url = format!("{BASE_URL}/artsearch/-------.html?wd={q}");
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
    let vid = url.strip_prefix("lbwen:").unwrap_or(url);
    let (title, text) = detail_text(vid).await;
    if text.is_empty() {
        return Err(ApiError::Internal("lbwen 该篇没有正文".into()));
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
    fn list_parses_dt_rows() {
        let page = r#"<dt><span>1</span><a href="/artdetail-33.html">标题</a></dt>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "33");
    }
}
