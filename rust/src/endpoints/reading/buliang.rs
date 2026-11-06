//! buliang：成人小说站（不良小说网镜像）。
//!
//! 照搬 py 原文：分类 20 个；列表按 art-item 块取 article id 与
//! foot 备注；目录 /arttype/id/ 与 /arttype/id-页/；详情取
//! <article> 全文，标题取 <title> 首段；搜索走 artsearch 的横线
//! 占位格式。核心里详情分集用文章 id，取流时现取全文拼
//! novel://（py 详情直嵌全文、取流只透传 novel://，最终阅读效果
//! 一致）。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://bass-23023-bug.buliangxiaoshuowang2.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 20] = [
    ("5036", "都市激情"),
    ("5037", "校园情事"),
    ("5038", "人妻縱情"),
    ("5039", "風俗倫理"),
    ("5040", "另类小说"),
    ("5041", "武侠古典"),
    ("5042", "长篇连载"),
    ("5043", "成人笑话"),
    ("1000", "小说"),
    ("5035", "短篇小说"),
    ("1005", "仙侠武侠"),
    ("1003", "淫乱乱伦"),
    ("1001", "人妻熟女"),
    ("1002", "故事"),
    ("1004", "学生"),
    ("5003", "其它"),
    ("5004", "暴力"),
    ("5005", "现代"),
    ("5033", "年度最佳"),
    ("5034", "世界着名"),
];

static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static SCRIPT_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<script[^>]*>.*?</script>").unwrap());
static STYLE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<style[^>]*>.*?</style>").unwrap());
static BR_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());
static SPACE_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"[ \t]+").unwrap());
static WS_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static LINK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"href="/article/(\d+)/"[^>]*>([^<]+)</a>"#).unwrap());
static FOOT_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<div class="art-item-foot">.*?<span>([^<]+)</span>"#).unwrap());
static TITLE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<title>(.*?)</title>").unwrap());
static ARTICLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<article class="article">(.*?)</article>"#).unwrap());

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

/// py _clean：去标签、5 个命名实体、空白折叠。
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

/// py _clean_text：去 script/style、段落换行、去标签、实体、逐行整理。
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
    for block in page.split("<div class=\"art-item\">").skip(1) {
        let Some(cap) = LINK_RE.captures(block) else {
            continue;
        };
        let vid = cap[1].to_string();
        if !seen.insert(vid.clone()) {
            continue;
        }
        let title = clean(&cap[2]);
        let remark = FOOT_RE
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| clean(m.as_str()))
            .unwrap_or_default();
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

/// py _detail：返回（标题，正文）。
async fn detail_text(vid: &str) -> (String, String) {
    let page = fetch(&format!("{BASE_URL}/article/{vid}/")).await;
    let title = TITLE_RE
        .captures(&page)
        .and_then(|cap| cap.get(1))
        .map(|m| clean(m.as_str()))
        .and_then(|t| t.split(" | ").next().map(str::trim).map(str::to_string))
        .unwrap_or_default();
    let text = ARTICLE_RE
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
        format!("{BASE_URL}/artis")
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
    let vid = url.strip_prefix("buliang:").unwrap_or(url);
    let (title, text) = detail_text(vid).await;
    if text.is_empty() {
        return Err(ApiError::Internal("buliang 该篇没有正文".into()));
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
    fn list_parses_blocks() {
        let page = concat!(
            "<div class=\"art-item\"><a href=\"/article/7/\">标题</a>",
            "<div class=\"art-item-foot\"><span>备注</span></div>",
            "<div class=\"art-item\"><a href=\"/article/7/\">标题</a></div>"
        );
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "7");
        assert_eq!(items[0]["remark"], "备注");
    }

    #[test]
    fn clean_text_strips_script_and_breaks() {
        let raw = "<script>x</script><p>甲<br/>乙</p>";
        assert_eq!(clean_text(raw), "甲\n乙");
    }
}
