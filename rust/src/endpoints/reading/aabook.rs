//! aabook：通用小说站（aabook.net），非成人。
//!
//! 照搬 py 原文：移动端域名取数；分类 18 个；列表取 category.html
//! （extend 过滤默认 -1）；详情取 book 页并翻 chapter.php 至多 40
//! 页取章节（无新章节即停）；取流取 read 页 token 再调
//! _getcontent.php（带 Referer 与 X-Requested-With），首 200 字含
//! aabook_readfile 才算取到，拼 novel://。py 用 CookieJar 会话与
//! gzip 嗅探，核心里用静态饼干串与首字节嗅探复现；py 的
//! isVideoFormat 只把 pics:// 当非视频格式提及、本站实际只出小说
//! 章节，取流仍原样透传 pics://，以便混合条目进图片浏览。

use std::sync::Mutex;

use flate2::read::GzDecoder;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use std::io::Read as _;

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://aabook.net";
const MOBILE_URL: &str = "https://aabook.net/m/";
const UA: &str = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36";

const CATEGORIES: [(&str, &str); 18] = [
    ("chuanyue", "穿越"),
    ("danmei", "耽美"),
    ("danpian", "单篇"),
    ("dushi", "都市"),
    ("guanchang", "官场"),
    ("gudian", "古典"),
    ("jingsong", "惊悚"),
    ("lishi", "历史"),
    ("nvzun", "女尊"),
    ("tongren", "同人"),
    ("wangyou", "网游"),
    ("wuxia", "武侠"),
    ("xiangtu", "乡土"),
    ("xianxia", "仙侠"),
    ("xiaoyuan", "校园"),
    ("xuanhuan", "玄幻"),
    ("yanqing", "言情"),
    ("yineng", "异能"),
];

/// py CookieJar 的最小复现：累积 name=value，取数时整串带上。
static COOKIES: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

fn cookie_header() -> String {
    let Ok(guard) = COOKIES.lock() else {
        return String::new();
    };
    guard
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

fn store_cookies(resp: &reqwest::Response) {
    let mut pairs = Vec::new();
    for value in resp.headers().get_all(reqwest::header::SET_COOKIE).iter() {
        if let Ok(text) = value.to_str() {
            if let Some(first) = text.split(';').next() {
                if let Some((k, v)) = first.split_once('=') {
                    pairs.push((k.trim().to_string(), v.trim().to_string()));
                }
            }
        }
    }
    if pairs.is_empty() {
        return;
    }
    if let Ok(mut guard) = COOKIES.lock() {
        for (k, v) in pairs {
            if let Some(slot) = guard.iter_mut().find(|(ek, _)| *ek == k) {
                slot.1 = v;
            } else {
                guard.push((k, v));
            }
        }
    }
}

/// py _fetch：失败空串；gzip 魔数开头即解压；其余按 utf-8 宽容解码。
async fn fetch(url: &str, extra: &[(&str, &str)]) -> String {
    let mut req = match client() {
        Ok(c) => c.get(url).header("User-Agent", UA),
        Err(_) => return String::new(),
    };
    let cookies = cookie_header();
    if !cookies.is_empty() {
        req = req.header("Cookie", cookies);
    }
    for (k, v) in extra {
        req = req.header(*k, *v);
    }
    let resp = match req.send().await {
        Ok(r) => r,
        Err(_) => return String::new(),
    };
    store_cookies(&resp);
    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(_) => return String::new(),
    };
    if bytes.len() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b {
        let mut decoder = GzDecoder::new(&bytes[..]);
        let mut out = Vec::new();
        if decoder.read_to_end(&mut out).is_ok() {
            return String::from_utf8_lossy(&out).into_owned();
        }
        return String::new();
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

/// py _clean：去标签、5 个命名实体、去首尾空白。
fn clean(raw: &str) -> String {
    static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
    let text = TAG_RE.replace_all(raw, "");
    text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
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

fn take_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn novel_url(title: &str, content: &str) -> String {
    let payload = json!({"title": title, "content": content}).to_string();
    format!("novel://{payload}")
}

static BOOK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"href="book-(\d+)\.html""#).unwrap());
static NAME_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<a class="name" href="book-\d+\.html">([^<]+)</a>"#).unwrap()
});
static CHAPTER_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"class="chapter">([^<]+)</a>"#).unwrap());
static WORDS_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"字数：(\d+)").unwrap());
static AUTHOR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"作者：([^<\s]+)").unwrap());
static PAGE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"page=(\d+)").unwrap());
static DIGITS_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(\d+)").unwrap());

/// py _list_from_category：返回（条目，是否有下一页）。
async fn list_from_category(tid: &str, page: i64) -> (Vec<Value>, bool) {
    let url = format!(
        "{MOBILE_URL}category.html?pageNum={page}&pageSize=30&catId={tid}&size=-1&isFinish=-1&updT=-1&orderBy=-1"
    );
    let html = fetch(&url, &[]).await;
    let mut items = Vec::new();
    for block in html.split("<li class=\"column-2").skip(1) {
        let Some(bid) = BOOK_RE
            .captures(block)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().to_string())
        else {
            continue;
        };
        let Some(name) = NAME_RE
            .captures(block)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().trim().to_string())
        else {
            continue;
        };
        let remark = CHAPTER_RE
            .captures(block)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().trim().to_string())
            .or_else(|| {
                WORDS_RE
                    .captures(block)
                    .and_then(|cap| cap.get(1))
                    .map(|m| format!("{}字", m.as_str()))
            })
            .unwrap_or_default();
        let cover = format!("{BASE_URL}/img-{bid}.jpg");
        items.push(item_json(&bid, &name, &cover, &remark));
    }
    let mut pagecount = page;
    let mut max_page = 0i64;
    for cap in PAGE_RE.captures_iter(&html) {
        if let Ok(n) = cap[1].parse::<i64>() {
            if n > max_page {
                max_page = n;
            }
        }
    }
    if max_page > 0 {
        pagecount = max_page;
    } else if items.len() >= 30 {
        pagecount = page + 1;
    }
    (items, pagecount > page)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATEGORIES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = if category_id.is_empty() {
        "-1"
    } else {
        category_id
    };
    let (items, has_more) = list_from_category(tid, page).await;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let bid = DIGITS_RE
        .captures(series_id)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| series_id.to_string());
    let book = fetch(&format!("{MOBILE_URL}book-{bid}.html"), &[]).await;
    if book.is_empty() {
        return Err(ApiError::Internal("aabook 未返回详情".into()));
    }
    static TITLE_RE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"<h2>([^<]+)</h2>").unwrap());
    static STATUS_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"<span class="status[^>]*>([^<]+)"#).unwrap()
    });
    static LINK_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"href="(read-\d+\.html)"[^>]*>([^<]+)</a>"#).unwrap()
    });
    let title = TITLE_RE
        .captures(&book)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_else(|| bid.clone());
    let author = AUTHOR_RE
        .captures(&book)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();
    let words = WORDS_RE
        .captures(&book)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().to_string());
    let status = STATUS_RE
        .captures(&book)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();
    let mut remarks = status;
    if let Some(w) = words {
        if !remarks.is_empty() {
            remarks.push(' ');
        }
        remarks.push_str(&format!("{w}字"));
    }
    let mut episodes = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for p in 1..=40 {
        let page = fetch(
            &format!("{MOBILE_URL}chapter.php?p={p}&id={bid}&ob=asc"),
            &[],
        )
        .await;
        let mut fresh = 0;
        for cap in LINK_RE.captures_iter(&page) {
            let href = cap[1].to_string();
            let rid = DIGITS_RE
                .captures(&href)
                .and_then(|cap| cap.get(1))
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
            if rid.is_empty() || !seen.insert(rid.clone()) {
                continue;
            }
            fresh += 1;
            let name = cap[2].trim().replace('#', " ").replace('$', " ");
            episodes.push(episode_json(&rid, &name, &bid));
        }
        if fresh == 0 {
            break;
        }
    }
    let mut extra = serde_json::Map::new();
    if !author.is_empty() {
        extra.insert("author".to_string(), Value::String(author));
    }
    if !remarks.is_empty() {
        extra.insert("remarks".to_string(), Value::String(remarks));
    }
    Ok(json!({
        "id": bid,
        "title": title,
        "cover": format!("{BASE_URL}/img-{bid}.jpg"),
        "synopsis": "",
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{MOBILE_URL}search.html?page=1&searchword={}&ob=0",
        percent_encode_segment(query)
    );
    let html = fetch(&url, &[]).await;
    static MID_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"href="book-(\d+)\.html" class="name""#).unwrap()
    });
    static SNAME_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"class="name"[^>]*>([^<]+)</a>"#).unwrap()
    });
    static SSTATUS_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"<span class="status[^>]*>([^<]+)</span>"#).unwrap()
    });
    let mut items = Vec::new();
    for block in html.split("<li>").skip(1) {
        let Some(bid) = MID_RE
            .captures(block)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().to_string())
        else {
            continue;
        };
        let name = SNAME_RE
            .captures(block)
            .and_then(|cap| cap.get(1))
            .map(|m| clean(m.as_str()))
            .unwrap_or_else(|| bid.clone());
        let remark = SSTATUS_RE
            .captures(block)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        items.push(item_json(
            &bid,
            &name,
            &format!("{BASE_URL}/img-{bid}.jpg"),
            &remark,
        ));
    }
    Ok(json!({"items": items}))
}

/// py _chapter_text：read 页取 token，再调 _getcontent.php，首 200
/// 字含 aabook_readfile 才算取到；最多 2 轮。
async fn chapter_text(rid: &str) -> (String, String) {
    static TOKEN_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"_getcontent\.php\?id="\+chapid\+"&v=([A-Za-z0-9_\-]+)"#).unwrap()
    });
    static PARA_RE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"(?s)<p>(.*?)</p>").unwrap());
    static TITLE_RE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"<title>([^<]*)</title>").unwrap());
    let read_url = format!("{MOBILE_URL}read-{rid}.html");
    for _ in 0..2 {
        let page = fetch(&read_url, &[]).await;
        let Some(token) = TOKEN_RE
            .captures(&page)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().to_string())
        else {
            return (String::new(), String::new());
        };
        let gc = fetch(
            &format!("{BASE_URL}/_getcontent.php?id={rid}&v={token}"),
            &[
                ("Referer", read_url.as_str()),
                ("X-Requested-With", "XMLHttpRequest"),
            ],
        )
        .await;
        if !gc.chars().take(200).collect::<String>().contains("aabook_readfile") {
            continue;
        }
        let lines: Vec<String> = PARA_RE
            .captures_iter(&gc)
            .map(|cap| clean(&cap[1]))
            .filter(|ln| !ln.is_empty())
            .collect();
        let mut name = TITLE_RE
            .captures(&page)
            .and_then(|cap| cap.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        if name.contains("在线全文阅读") {
            name = name
                .split("在线全文阅读")
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
        }
        return (name, lines.join("\n"));
    }
    (String::new(), String::new())
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = match video_id.split_once('$') {
        Some((_, after)) => after,
        None => video_id,
    };
    if url.starts_with("novel://") || url.starts_with("pics://") {
        return Ok(json!({"url": url}));
    }
    let rid = DIGITS_RE
        .captures(url)
        .and_then(|cap| cap.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| url.to_string());
    let (name, text) = chapter_text(&rid).await;
    if text.is_empty() {
        return Err(ApiError::Internal("aabook 该章没有正文".into()));
    }
    Ok(json!({"url": novel_url(&name, &text)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_strips_tags_and_entities() {
        assert_eq!(
            clean("<b>甲&nbsp;&amp;乙</b> "),
            "甲 &乙"
        );
    }

    #[test]
    fn cookie_header_accumulates() {
        if let Ok(mut guard) = COOKIES.lock() {
            guard.clear();
            guard.push(("a".to_string(), "1".to_string()));
            guard.push(("b".to_string(), "2".to_string()));
        }
        assert_eq!(cookie_header(), "a=1; b=2");
        if let Ok(mut guard) = COOKIES.lock() {
            guard.clear();
        }
    }

    #[test]
    fn list_splits_blocks() {
        let html = concat!(
            "<li class=\"column-2\"><a href=\"book-12.html\"></a>",
            "<a class=\"name\" href=\"book-12.html\">书名</a>",
            "<a class=\"chapter\">最新章</a>",
            "<li class=\"column-2\"><a href=\"book-13.html\"></a>",
            "<a class=\"name\" href=\"book-13.html\">书二</a>",
            "字数：1234"
        );
        let mut items = Vec::new();
        for block in html.split("<li class=\"column-2").skip(1) {
            let bid = BOOK_RE.captures(block).unwrap()[1].to_string();
            let name = NAME_RE.captures(block).unwrap()[1].to_string();
            items.push((bid, name));
        }
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].0, "12");
    }
}
