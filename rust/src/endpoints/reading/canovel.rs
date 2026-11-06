//! canovel：成人小说站（canovel.com）。
//!
//! 照搬 py 原文：分类是 9 个中文名（id 即名）；列表取 post-title
//! article 链接；详情正文用 div 深度遍历取 entry-inner 内的 <p>
//! 段；标题与正文里的 # 换成全角 ＃；搜索走 WP 的 ?s= 格式。
//! 核心里详情分集用文章数字 id，取流时现取正文拼 novel://。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://canovel.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATEGORIES: [&str; 9] = [
    "亂倫小說",
    "人妻熟女",
    "強暴虐待",
    "校園師生",
    "同志小說",
    "古典武俠",
    "都市小品",
    "名人明星",
    "外國翻譯",
];

static LIST_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<h2 class="post-title entry-title">\s*<a href="https://canovel\.com/article/(\d+)"[^>]*>(.*?)</a>"#).unwrap()
});
static TITLE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<h1[^>]*class="post-title entry-title"[^>]*>(.*?)</h1>"#)
        .unwrap()
});
static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static BR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());
static DIGITS_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(\d+)").unwrap());

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
                    "canovel 请求 HTTP {}",
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

/// py _extract_paras：entry-inner 起按 div 深度遍历取 <p> 段。
fn extract_paras(page: &str) -> String {
    let Some(start) = page.find("<div class=\"entry-inner\"") else {
        return String::new();
    };
    let region = &page[start..];
    let Some(tag_end) = region.find('>') else {
        return String::new();
    };
    let region = &region[tag_end + 1..];
    let mut depth = 1i32;
    let mut paras = Vec::new();
    for m in TAG_RE.find_iter(region) {
        let tag = m.as_str();
        let inner = tag.trim_start_matches('<').trim_start_matches('/');
        let name: String = inner
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        let name = name.to_ascii_lowercase();
        let closing = tag.starts_with("</");
        let selfclose = tag.ends_with("/>");
        if name == "div" && !closing && !selfclose {
            depth += 1;
        } else if name == "div" && closing {
            depth -= 1;
            if depth <= 0 {
                break;
            }
        }
        if name == "p" && !closing && depth >= 1 {
            if let Some(end) = region[m.end()..].find("</p>") {
                let txt = clean_text(&region[m.end()..m.end() + end]);
                if !txt.is_empty() {
                    paras.push(txt);
                }
            }
        }
    }
    paras.join("\n")
}

fn parse_list(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in LIST_RE.captures_iter(page) {
        let pid = cap[1].to_string();
        if !seen.insert(pid.clone()) {
            continue;
        }
        let title = clean_text(&cap[2]);
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&pid, &title, "", ""));
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

/// py detailContent 的取文章逻辑：返回（标题，正文），# 已换全角。
async fn article(vid: &str) -> (String, String) {
    let vid = DIGITS_RE
        .captures(vid)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| vid.to_string());
    let page = fetch(&format!("{BASE_URL}/article/{vid}")).await;
    if page.is_empty() {
        return (vid, String::new());
    }
    let mut title = TITLE_RE
        .captures(&page)
        .map(|cap| clean_text(&cap[1]))
        .filter(|t| !t.is_empty())
        .unwrap_or(vid);
    let mut text = extract_paras(&page);
    title = title.replace('#', "＃");
    text = text.replace('#', "＃");
    (title, text)
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
            "/article/category/{}",
            percent_encode_segment(category_id)
        );
        if page > 1 {
            format!("{BASE_URL}{path}/page/{page}")
        } else {
            format!("{BASE_URL}{path}")
        }
    };
    let items = parse_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = DIGITS_RE
        .captures(series_id)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| series_id.to_string());
    let (title, text) = article(&vid).await;
    if text.is_empty() {
        return Err(ApiError::Internal("canovel 未返回正文".into()));
    }
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&text, 300),
        "extra": {},
        "episodes": [episode_json(&vid, "阅读", &vid)],
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
        return Err(ApiError::Internal("canovel 该篇没有正文".into()));
    }
    Ok(json!({"url": novel_url(&title, &text)}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = percent_encode_segment(query);
    let url = format!("{BASE_URL}/?s={q}");
    let items = parse_list(&fetch(&url).await);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_paras_respects_div_depth() {
        let page = concat!(
            "<div class=\"entry-inner\">",
            "<p>第一段</p>",
            "<div><p>嵌套段</p></div>",
            "</div><p>外部段</p>"
        );
        assert_eq!(extract_paras(page), "第一段\n嵌套段");
    }

    #[test]
    fn list_parses_article_ids() {
        let page = r#"<h2 class="post-title entry-title"><a href="https://canovel.com/article/42">标题</a></h2>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "42");
    }
}
