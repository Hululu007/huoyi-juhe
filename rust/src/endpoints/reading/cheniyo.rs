//! cheniyo：成人小说站（cheniyo.cfd）。
//!
//! 照搬 py 原文：分类 5 个；列表按 artdetail 行取首尾 li 作标题与
//! 备注；目录 /arttype/id.html 与 /arttype/id-页.html；详情标题取
//! other-title（去尾部“ -”）、正文取 other-content introduction；
//! 搜索走 artsearch 的横线占位格式。核心里详情分集用文章 id，
//! 取流时现取全文拼 novel://。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://cheniyo.cfd";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 5] = [
    ("1", "家庭乱伦"),
    ("2", "职场丽人"),
    ("3", "经验故事"),
    ("4", "都市激情"),
    ("5", "校园之恋"),
];

static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static IMG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<img[^>]*>").unwrap());
static SCRIPT_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<script[^>]*>.*?</script>").unwrap());
static BR_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());
static SPACE_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"[ \t]+").unwrap());
static WS_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static ROW_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)/artdetail-(\d+)\.html"\s+class="row">(.*?)</a>"#).unwrap());
static LI_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<li[^>]*>(.*?)</li>").unwrap());
static TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<p class="other-title">(.*?)</p>"#).unwrap());
static BODY_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<div class="other-content introduction">(.*?)</div>\s*</div>"#).unwrap()
});
static BODY_FALLBACK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div class="other-content introduction">(.*)"#).unwrap());

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

/// py _clean_title：去 img 与标签、实体（含 &#155; 转 >）、空白折叠。
fn clean_title(raw: &str) -> String {
    let text = IMG_RE.replace_all(raw, "");
    let text = TAG_RE.replace_all(&text, "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#155;", ">");
    WS_RUN_RE.replace_all(&text, " ").trim().to_string()
}

/// py _clean_text：去 script、段落换行、去标签、实体、逐行整理。
fn clean_text(raw: &str) -> String {
    let text = SCRIPT_RE.replace_all(raw, "");
    let text = CLOSE_P_RE.replace_all(&text, "\n");
    let text = BR_RE.replace_all(&text, "\n");
    let text = TAG_RE.replace_all(&text, "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#155;", ">");
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
        let parts: Vec<String> = LI_RE
            .captures_iter(&cap[2])
            .map(|c| c[1].to_string())
            .collect();
        let title = parts.first().map(|p| clean_title(p)).unwrap_or_default();
        let remark = if parts.len() >= 2 {
            clean_title(parts.last().unwrap())
        } else {
            String::new()
        };
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&vid, &title, "", &remark));
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
        .map(|m| clean_title(m.as_str()))
        .map(|t| {
            t.trim_end_matches(|c| c == ' ' || c == '-')
                .trim()
                .to_string()
        })
        .unwrap_or_default();
    let text = BODY_RE
        .captures(&page)
        .or_else(|| BODY_FALLBACK_RE.captures(&page))
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
    let vid = url.strip_prefix("cheniyo:").unwrap_or(url);
    let (title, text) = detail_text(vid).await;
    if text.is_empty() {
        return Err(ApiError::Internal("cheniyo 该篇没有正文".into()));
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
    fn list_takes_first_and_last_li() {
        let page = r#"<a href="/artdetail-5.html" class="row"><li>标题</li><li>作者</li><li>2024-01-01</li></a>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "5");
        assert_eq!(items[0]["title"], "标题");
        assert_eq!(items[0]["remark"], "2024-01-01");
    }

    #[test]
    fn clean_title_handles_155_entity() {
        assert_eq!(clean_title("甲&#155;乙"), "甲>乙");
    }
}
