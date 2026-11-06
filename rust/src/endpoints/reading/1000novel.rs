//! 1000novel：成人小说站（1000novel.com）。
//!
//! 照搬 py 原文：分类是 7 个中文名（id 即名）；列表取 entry-title；
//! 详情按正文内出现的“路径 + 数字 /”推算总页数，单页为全集、多页
//! 按第 n 页分集；取流按 1000novel:路径:页码现取该页正文，拼
//! novel://{title, content}。取流失败沿用范式：无地址报错。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://1000novel.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATEGORIES: [&str; 7] = [
    "亂倫小說",
    "暴力虐待",
    "人妻小說",
    "武俠色情",
    "教師學生",
    "都市生活",
    "名人明星",
];

static LIST_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<h2 class="entry-title"><a href="https://1000novel\.com/(\d{4}/\d{2}/\d{2}/[^"/]+/)"[^>]*>(.*?)</a></h2>"#).unwrap()
});
static TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap());
static PARA_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<p[^>]*>(.*?)</p>").unwrap());
static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static BR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());

/// 单次字符实体解码：与 Python html.unescape 一致（单遍、未知实体不动）。
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

/// py _clean_text：br 与 </p> 换行、去标签、解实体、去空行。
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
                    "1000novel 请求 HTTP {}",
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
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in LIST_RE.captures_iter(page) {
        let path = cap[1].to_string();
        if !seen.insert(path.clone()) {
            continue;
        }
        let title = clean_text(&cap[2]);
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&path, &title, "", ""));
    }
    items
}

/// py _entry_text：从 entry-content 起取全部 <p> 段。
fn entry_text(page: &str) -> String {
    let Some(pos) = page.find("entry-content") else {
        return String::new();
    };
    PARA_RE
        .captures_iter(&page[pos..])
        .filter_map(|cap| {
            let txt = clean_text(&cap[1]);
            if txt.is_empty() {
                None
            } else {
                Some(txt)
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// py _page_count：正文里“路径 + 数字 /”的最大数字，无则 1。
fn page_count(path: &str, page: &str) -> i64 {
    let pattern = format!("{}(\\d+)/", regex::escape(path));
    let Ok(re) = Regex::new(&pattern) else {
        return 1;
    };
    let mut max = 0i64;
    for cap in re.captures_iter(page) {
        if let Ok(n) = cap[1].parse::<i64>() {
            if n > max {
                max = n;
            }
        }
    }
    if max < 1 {
        1
    } else {
        max
    }
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
        .map(|name| category_json(name, name))
        .collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if category_id.is_empty() {
        format!("{BASE_URL}/")
    } else {
        let path = format!(
            "/category/{}/",
            percent_encode_segment(category_id)
        );
        if page > 1 {
            format!("{BASE_URL}{path}page/{page}/")
        } else {
            format!("{BASE_URL}{path}")
        }
    };
    let items = parse_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = series_id;
    let page = fetch(&format!("{BASE_URL}/{path}")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("1000novel 未返回详情".into()));
    }
    let title = TITLE_RE
        .captures(&page)
        .map(|cap| clean_text(&cap[1]))
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| path.to_string());
    let total = page_count(path, &page);
    let mut episodes = Vec::new();
    if total <= 1 {
        episodes.push(episode_json(
            &format!("1000novel:{path}:1"),
            "全集",
            path,
        ));
    } else {
        for n in 1..=total {
            episodes.push(episode_json(
                &format!("1000novel:{path}:{n}"),
                &format!("第{n}页"),
                path,
            ));
        }
    }
    let first_text = entry_text(&page);
    Ok(json!({
        "id": path,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&first_text, 300),
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let raw = video_id;
    let url = match raw.split_once('$') {
        Some((_, after)) => after,
        None => raw,
    };
    if url.starts_with("novel://") {
        return Ok(json!({"url": url}));
    }
    if let Some(rest) = url.strip_prefix("1000novel:") {
        if let Some((path, num)) = rest.rsplit_once(':') {
            if let Ok(n) = num.parse::<i64>() {
                let mut fetch_url = format!("{BASE_URL}/{path}");
                if n > 1 {
                    fetch_url.push_str(&format!("{n}/"));
                }
                let page = fetch(&fetch_url).await;
                let mut title = TITLE_RE
                    .captures(&page)
                    .map(|cap| clean_text(&cap[1]))
                    .unwrap_or_else(|| path.to_string());
                let mut text = entry_text(&page);
                title = title.replace('#', "＃");
                text = text.replace('#', "＃");
                return Ok(json!({"url": novel_url(&title, &text)}));
            }
        }
    }
    Ok(json!({"url": url}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = percent_encode_segment(query);
    let url = format!("{BASE_URL}/?s={q}");
    let items = parse_list(&fetch(&url).await);
    Ok(json!({"items": items}))
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
    fn list_parses_and_dedups() {
        let page = r#"<h2 class="entry-title"><a href="https://1000novel.com/2024/01/02/slug/">标题一</a></h2><h2 class="entry-title"><a href="https://1000novel.com/2024/01/02/slug/">标题一</a></h2>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2024/01/02/slug/");
    }

    #[test]
    fn page_count_takes_max() {
        let path = "2024/01/02/slug/";
        let page = "x2024/01/02/slug/2/y2024/01/02/slug/5/z";
        assert_eq!(page_count(path, page), 5);
        assert_eq!(page_count(path, "no pages"), 1);
    }

    #[test]
    fn clean_text_breaks_and_strips() {
        let raw = "<p>第一行<br/>第二行</p><p>&nbsp;第三行</p>";
        assert_eq!(clean_text(raw), "第一行\n第二行\n第三行");
    }

    #[test]
    fn unescape_numeric_and_named() {
        assert_eq!(unescape("a &amp; b &#20013; &#x4e2d;"), "a & b 中 中");
        assert_eq!(unescape("a &unknown; b"), "a &unknown; b");
    }
}
