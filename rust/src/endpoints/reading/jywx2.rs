//! jywx2：成人小说站（jywx2 镜像，注意是 http）。
//!
//! 照搬 py 原文：分类 11 个编码 id（与 hwg4 同套）；取数先过
//! FU1 包；列表行取 col-name/author/time；正文取 read-content，
//! 清洗时空白全折叠成单行空格且 # 与 $ 换成全角；未知分类返回
//! 空；目录与搜索按 20 条一页算下一页；详情分集是全文链接，取
//! 流从 artdetail 链接或 $ 后段取 token 现取全文拼 novel://。

use base64::{engine::general_purpose::STANDARD, Engine as _};
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "http://1mx8i3.www.jywx2.quest";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

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
static WS_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static FU_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"FU1\("([^"]+)"\)"#).unwrap());
static ROW_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<a href="/artdetail-([^"]+)/" class="art-item-row">(.*?)</a>"#).unwrap()
});
static COL_NAME_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"col-name">([^<]*)"#).unwrap());
static COL_TIME_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"col-time">([^<]*)"#).unwrap());
static HOME_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<a href="/artdetail-([^"]+)/">([^<]+)</a>"#).unwrap());
static TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<h1 class="read-title">(.*?)</h1>"#).unwrap());
static BODY_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div id="read-content">(.*?)</div>\s*<div"#).unwrap());
static BODY_FALLBACK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div id="read-content">(.*)"#).unwrap());
static TOKEN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"artdetail-([^/]+)/?").unwrap());

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
        _ => text,
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

/// py _clean_text：去标签、解实体、空白折叠单行、# 与 $ 换全角。
fn clean_text(raw: &str) -> String {
    let text = TAG_RE.replace_all(raw, "");
    let text = unescape(&text).replace('\u{a0}', " ");
    let text = WS_RUN_RE.replace_all(&text, " ").trim().to_string();
    text.replace('#', "＃").replace('$', "＄")
}

fn unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0usize;
    let mut last = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'&' {
            i += 1;
            continue;
        }
        let rest = &s[i..];
        let decoded = rest.find(';').and_then(|semi| {
            if semi > 32 {
                return None;
            }
            let entity = &rest[1..semi];
            let text = match entity {
                "nbsp" => Some('\u{a0}'.to_string()),
                "amp" => Some("&".to_string()),
                "lt" => Some("<".to_string()),
                "gt" => Some(">".to_string()),
                "quot" => Some('"'.to_string()),
                "apos" => Some("'".to_string()),
                _ => {
                    if let Some(num) = entity
                        .strip_prefix("#x")
                        .or_else(|| entity.strip_prefix("#X"))
                    {
                        u32::from_str_radix(num, 16)
                            .ok()
                            .and_then(char::from_u32)
                            .map(|c| c.to_string())
                    } else if let Some(num) = entity.strip_prefix('#') {
                        num.parse::<u32>()
                            .ok()
                            .and_then(char::from_u32)
                            .map(|c| c.to_string())
                    } else {
                        None
                    }
                }
            };
            text.map(|t| (semi + 1, t))
        });
        match decoded {
            Some((consumed, text)) => {
                out.push_str(&s[last..i]);
                out.push_str(&text);
                i += consumed;
                last = i;
            }
            None => i += 1,
        }
    }
    out.push_str(&s[last..]);
    out
}

fn parse_rows(page: &str) -> Vec<Value> {
    let mut rows = Vec::new();
    for cap in ROW_RE.captures_iter(page) {
        let inner = cap[2].to_string();
        let name = COL_NAME_RE
            .captures(&inner)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let time = COL_TIME_RE
            .captures(&inner)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        rows.push(item_json(&cap[1], &name, "", &time));
    }
    rows
}

fn home_items(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in HOME_RE.captures_iter(page) {
        let token = cap[1].to_string();
        if !seen.insert(token.clone()) {
            continue;
        }
        items.push(item_json(&token, cap[2].trim(), "", ""));
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

/// py _detail：返回（标题，正文）。
async fn detail_text(token: &str) -> (String, String) {
    let page = fetch(&format!("{BASE_URL}/artdetail-{token}/")).await;
    if page.is_empty() {
        return (String::new(), String::new());
    }
    let title = TITLE_RE
        .captures(&page)
        .map(|cap| clean_text(&cap[1]))
        .unwrap_or_default();
    let body = BODY_RE
        .captures(&page)
        .or_else(|| BODY_FALLBACK_RE.captures(&page))
        .and_then(|cap| cap.get(1))
        .map(|m| clean_text(m.as_str()))
        .unwrap_or_default();
    (title, body)
}

fn is_known_category(tid: &str) -> bool {
    CATEGORIES.iter().any(|(id, _)| *id == tid)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATEGORIES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if category_id.is_empty() {
        let items = home_items(&fetch(&format!("{BASE_URL}/")).await);
        return Ok(json!({"items": items, "has_more": false}));
    }
    if !is_known_category(category_id) {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let url = if page <= 1 {
        format!("{BASE_URL}/arttype/{category_id}/")
    } else {
        format!("{BASE_URL}/arttype/{category_id}-{page}/")
    };
    let rows = parse_rows(&fetch(&url).await);
    let has_more = rows.len() >= 20;
    Ok(json!({"items": rows, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let token = series_id.split('$').last().unwrap_or("").trim().to_string();
    if token.is_empty() {
        return Err(ApiError::BadRequest("missing id parameter".into()));
    }
    let (title, text) = detail_text(&token).await;
    if title.is_empty() {
        return Err(ApiError::Internal("jywx2 未返回标题".into()));
    }
    Ok(json!({
        "id": token,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&text, 150),
        "extra": {},
        "episodes": [episode_json(
            &format!("{BASE_URL}/artdetail-{token}/"),
            "全文",
            &token,
        )],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let q = percent_encode_segment(query);
    let url = format!("{BASE_URL}/artsearch/-------/?wd={q}");
    let rows = parse_rows(&fetch(&url).await);
    Ok(json!({"items": rows}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let raw = video_id.trim();
    let token = match TOKEN_RE.captures(raw) {
        Some(cap) => cap[1].to_string(),
        None => raw.split('$').last().unwrap_or("").trim().to_string(),
    };
    if token.is_empty() {
        return Err(ApiError::Internal("jywx2 没有可播标识".into()));
    }
    let (title, text) = detail_text(&token).await;
    if text.is_empty() {
        return Err(ApiError::Internal("jywx2 该篇没有正文".into()));
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
    fn rows_parse_columns() {
        let page = r#"<a href="/artdetail-T1/" class="art-item-row"><span class="col-name">标题</span><span class="col-author">作者</span><span class="col-time">2024-01-01</span></a>"#;
        let rows = parse_rows(page);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["id"], "T1");
        assert_eq!(rows[0]["remark"], "2024-01-01");
    }

    #[test]
    fn clean_text_folds_and_fullwidths() {
        assert_eq!(clean_text("甲<br/>乙 # $"), "甲乙 ＃ ＄");
    }

    #[test]
    fn unknown_category_is_empty() {
        assert!(!is_known_category("nope"));
        assert!(is_known_category("DCCCCD"));
    }
}
