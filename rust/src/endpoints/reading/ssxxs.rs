//! ssxxs：成人小说站（ssxxs 镜像）。
//!
//! 照搬 py 原文：分类 11 个，未知分类回落都市激情（20）；列表
//! 取 artdetail 链接的 title 属性，备注取随后 200 字内的 r
//! span；首页列表取都市激情；目录 /arttype/id.html 与
//! /arttype/id-页.html，30 条一页算下一页；详情标题取
//! article-title 内 『 』、正文取 artcontent；搜索走 artsearch
//! 的横线占位格式。核心里详情分集用文章数字 id，取流时现取
//! 全文拼 novel://（py 取流只透传 novel://，短 id 分集配合同
//! 样能播）。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://e5f6g7h8.ssxxs014.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 11] = [
    ("20", "都市激情"),
    ("21", "校园之恋"),
    ("22", "真实体验"),
    ("23", "武侠虚幻"),
    ("24", "家庭乱伦"),
    ("25", "职场丽人"),
    ("26", "经验故事"),
    ("27", "暴力虐待"),
    ("28", "科学幻想"),
    ("29", "明星偶像"),
    ("30", "人妻熟女"),
];

static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static BR_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)<br[^>]*>").unwrap());
static ROW_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"/artdetail-(\d+)\.html" title="([^"]+)""#).unwrap());
static DATE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<span class="r">([^<]+)</span>"#).unwrap());
static TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div class="article-title">\s*『(.*?)』\s*</div>"#).unwrap());
static BODY_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div class="artcontent">(.*?)</div>"#).unwrap());
static DIGITS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\d+)").unwrap());

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

/// py _clean：去标签、解实体、去首尾空白。
fn clean(raw: &str) -> String {
    let text = TAG_RE.replace_all(raw, "");
    unescape(&text).trim().to_string()
}

/// py _clean_text：br 换行、去标签、解实体、逐行整理。
fn clean_text(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let text = BR_RE.replace_all(raw, "\n");
    let text = TAG_RE.replace_all(&text, "");
    let text = unescape(&text).replace('\u{a0}', " ");
    text.lines()
        .map(str::trim)
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
        let tail_start = cap.get(0).map(|m| m.end()).unwrap_or(0);
        let tail: String = page[tail_start..].chars().take(200).collect();
        let remark = DATE_RE
            .captures(&tail)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        items.push(item_json(&vid, &clean(&cap[2]), "", &remark));
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

async fn article(vid: &str) -> Option<(String, String)> {
    let page = fetch(&format!("{BASE_URL}/artdetail-{vid}.html")).await;
    if page.is_empty() {
        return None;
    }
    let title = TITLE_RE
        .captures(&page)
        .and_then(|cap| cap.get(1))
        .map(|m| clean(m.as_str()))
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| vid.to_string());
    let text = BODY_RE
        .captures(&page)
        .and_then(|cap| cap.get(1))
        .map(|m| clean_text(m.as_str()))
        .unwrap_or_default();
    Some((title, text))
}

fn norm_id(value: &str) -> String {
    let mut s = value.to_string();
    if let Some((_, tail)) = s.split_once('$') {
        if !tail.is_empty() {
            s = tail.to_string();
        }
    }
    if let Some((head, _)) = s.split_once(',') {
        s = head.to_string();
    }
    let s = s.trim().to_string();
    DIGITS_RE
        .captures(&s)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or(s)
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
    let tid = if category_id.is_empty() || !is_known_category(category_id) {
        "20"
    } else {
        category_id
    };
    let url = if page <= 1 {
        format!("{BASE_URL}/arttype/{tid}.html")
    } else {
        format!("{BASE_URL}/arttype/{tid}-{page}.html")
    };
    let items = parse_list(&fetch(&url).await);
    let has_more = items.len() >= 30;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = norm_id(series_id);
    let Some((title, text)) = article(&vid).await else {
        return Err(ApiError::Internal("ssxxs 未返回详情".into()));
    };
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&text, 300),
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
    let vid = norm_id(url);
    let Some((title, text)) = article(&vid).await else {
        return Err(ApiError::Internal("ssxxs 该篇没有正文".into()));
    };
    if text.is_empty() {
        return Err(ApiError::Internal("ssxxs 该篇没有正文".into()));
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
    fn list_parses_title_and_date_tail() {
        let page = concat!(
            "<a href=\"/artdetail-11.html\" title=\"标题\">",
            "<span class=\"r\">2024-03-01</span>"
        );
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "11");
        assert_eq!(items[0]["remark"], "2024-03-01");
    }

    #[test]
    fn norm_id_strips_prefix_and_digits() {
        assert_eq!(norm_id("阅读$artdetail-42"), "42");
        assert_eq!(norm_id("77"), "77");
    }
}
