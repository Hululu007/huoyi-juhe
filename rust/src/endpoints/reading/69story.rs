//! 69story：成人小说站（69story.com）。
//!
//! 照搬 py 原文：分类是 5 个 slug；列表取 <main> 区 article 链接，
//! 标题按“ / ”切首段；详情直接把全文拼进阅读 play 地址；搜索未
//! 实现（py 恒返回空）。核心里详情分集用文章 id（短 id），取流
//! 时现取文章再拼 novel://，与 py 详情直嵌全文的最终阅读效果一致。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://69story.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 5] = [
    ("wife", "人妻熟女"),
    ("school", "學生校園"),
    ("family", "家庭亂倫"),
    ("bdsm-abuse", "強暴虐待"),
    ("sex-in-the-city", "都市生活"),
];

static MAIN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<main[^>]*>(.*?)</main>").unwrap());
static LIST_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"href=https://69story\.com/(article/\d+-[^\s>]+)[^>]*>(.*?)</a>")
        .unwrap()
});
static TITLE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<h1[^>]*class="entry-title"[^>]*>(.*?)</h1>"#).unwrap()
});
static BODY_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?s)<div class=entry-content>(.*?)</div>\s*<div").unwrap()
});
static BODY_FALLBACK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<div class=entry-content>(.*)").unwrap());
static NUM_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"article/(\d+)-").unwrap());
static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static BR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());

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

fn clean_text(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let text = BR_RE.replace_all(raw, "\n");
    let text = CLOSE_P_RE.replace_all(&text, "\n");
    let text = TAG_RE.replace_all(&text, "");
    let text = unescape(&text).replace('\u{a0}', " ");
    text.lines()
        .map(str::trim)
        .filter(|ln| !ln.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// py _fetch：最多 3 次、间隔 1 秒，正文满 10000 字提前返回。
async fn fetch(url: &str) -> String {
    for attempt in 0..3 {
        let tried = async {
            let resp = client()?
                .get(url)
                .header("User-Agent", UA)
                .header("Referer", format!("{BASE_URL}/"))
                .send()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))?;
            if resp.status().as_u16() != 200 {
                return Err(ApiError::Internal(format!(
                    "69story 请求 HTTP {}",
                    resp.status().as_u16()
                )));
            }
            resp.text()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))
        }
        .await;
        match tried {
            Ok(data) => {
                if data.len() >= 10000 || attempt == 2 {
                    return data;
                }
            }
            Err(_) => {
                if attempt == 2 {
                    return String::new();
                }
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    String::new()
}

fn parse_list(page: &str) -> Vec<Value> {
    let area = MAIN_RE
        .captures(page)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str())
        .unwrap_or(page);
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in LIST_RE.captures_iter(area) {
        let path = cap[1].to_string();
        if !seen.insert(path.clone()) {
            continue;
        }
        let name = clean_text(&cap[2])
            .split(" / ")
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        if name.is_empty() {
            continue;
        }
        items.push(item_json(&path, &name, "", ""));
    }
    items
}

/// py detailContent 的取文章逻辑：返回（标题，正文）。
async fn article(vid: &str) -> (String, String) {
    let (url, num) = if vid.starts_with("article/") {
        let num = NUM_RE
            .captures(vid)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_else(|| vid.to_string());
        (format!("{BASE_URL}/{vid}"), num)
    } else {
        (format!("{BASE_URL}/article/{vid}"), vid.to_string())
    };
    let page = fetch(&url).await;
    if page.is_empty() {
        return (num, String::new());
    }
    let title = TITLE_RE
        .captures(&page)
        .map(|cap| clean_text(&cap[1]))
        .filter(|t| !t.is_empty())
        .unwrap_or(num);
    let body = BODY_RE
        .captures(&page)
        .or_else(|| BODY_FALLBACK_RE.captures(&page))
        .and_then(|cap| cap.get(1))
        .map(|m| clean_text(m.as_str()))
        .unwrap_or_default();
    (title, body)
}

fn take_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn novel_url(title: &str, content: &str) -> String {
    let payload = json!({"title": title, "content": content}).to_string();
    format!("novel://{payload}")
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
    } else if page > 1 {
        format!("{BASE_URL}/{category_id}/page/{page}")
    } else {
        format!("{BASE_URL}/{category_id}")
    };
    let items = parse_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let (title, text) = article(series_id).await;
    if text.is_empty() {
        return Err(ApiError::Internal("69story 未返回正文".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&text, 300),
        "extra": {},
        "episodes": [episode_json(series_id, "阅读", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = match video_id.split_once('$') {
        Some((_, after)) => after,
        None => video_id,
    };
    if url.starts_with("novel://") {
        return Ok(json!({"url": url}));
    }
    let (title, text) = article(url).await;
    if text.is_empty() {
        return Err(ApiError::Internal("69story 该篇没有正文".into()));
    }
    Ok(json!({"url": novel_url(&title, &text)}))
}

/// py searchContent 恒返回空：本站无搜索接口。
pub(crate) async fn search(_query: &str) -> ApiResult<Value> {
    Ok(json!({"items": []}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_uses_main_area_and_first_title_part() {
        let page = r#"<main><a href=https://69story.com/article/123-abc>标题 / 副标题</a><a href=https://69story.com/article/123-abc>标题 / 副标题</a></main><a href=https://69story.com/article/999-x>站外</a>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "article/123-abc");
        assert_eq!(items[0]["title"], "标题");
    }

    #[test]
    fn clean_text_breaks_and_unescapes() {
        assert_eq!(
            clean_text("<p>甲<br/>乙</p><p>&nbsp;丙</p>"),
            "甲\n乙\n丙"
        );
    }
}
