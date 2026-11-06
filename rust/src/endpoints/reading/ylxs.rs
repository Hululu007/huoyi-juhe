//! ylxs：通用小说站（ylxs.net），非成人。
//!
//! 照搬 py 原文：分类 4 个榜单型入口（最新作品、完整榜单、最新
//! 更新的系列、发现）；卡片取 novel-card 的 show/series 链接与
//! badge 或 stats 备注；榜单第 2 页起恒为空；系列详情下钻出
//! show 单本分集，单本详情取 novel-body 正文（标题优先 JSON-LD
//! 的 Book name）；搜索走 /search/novels。分类名中无成人标记。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://ylxs.net";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 4] = [
    ("new", "最新作品"),
    ("ranking", "完整榜单"),
    ("series", "最新更新的系列"),
    ("discovery", "发现"),
];

static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static BR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)<br\s*/?>").unwrap());
static CLOSE_P_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)</p\s*>").unwrap());
static SPACE_RUN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[ \t]+").unwrap());
static WS_RUN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static CARD_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<article class="novel-card[^"]*"[^>]*>(.*?)</article>"#).unwrap()
});
static CARD_TITLE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"novel-card-title">\s*<a href="/novel/(show|series)/(\d+)">\s*([^<]+)</a>"#).unwrap()
});
static BADGE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<span class="card-badge">([^<]+)</span>"#).unwrap()
});
static STATS_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"novel-card-stats">\s*<span>([^<]+)</span>"#).unwrap()
});
static TITLE_TAG_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<title>(.*?)</title>").unwrap());
static JSONLD_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#""@type":"Book","name":"([^"]+)""#).unwrap()
});
static BODY_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<div class="novel-body"[^>]*>(.*?)</div>\s*<div class="novel-action-panel""#).unwrap()
});
static BODY_FALLBACK_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<div class="novel-body"[^>]*>(.*)"#).unwrap()
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
    let text = CLOSE_P_RE.replace_all(raw, "\n");
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

fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in CARD_RE.captures_iter(page) {
        let block = cap[1].to_string();
        let Some(tcap) = CARD_TITLE_RE.captures(&block) else {
            continue;
        };
        let kind = tcap[1].to_string();
        let nid = tcap[2].to_string();
        let title = clean(&tcap[3]);
        let vid = format!("{kind}:{nid}");
        if !seen.insert(vid.clone()) || title.is_empty() {
            continue;
        }
        let remark = BADGE_RE
            .captures(&block)
            .and_then(|c| c.get(1))
            .map(|m| clean(m.as_str()))
            .or_else(|| {
                STATS_RE
                    .captures(&block)
                    .and_then(|c| c.get(1))
                    .map(|m| clean(m.as_str()))
            })
            .unwrap_or_default();
        items.push(item_json(&vid, &title, "", &remark));
    }
    items
}

fn list_url(tid: &str, page: i64) -> String {
    match tid {
        "new" => format!("{BASE_URL}/novel/new?p={page}"),
        "ranking" => format!("{BASE_URL}/novel/ranking?p={page}"),
        "series" => format!("{BASE_URL}/novel/series?p={page}"),
        "discovery" => format!("{BASE_URL}/discovery?p={page}"),
        _ => format!("{BASE_URL}/novel/new?p={page}"),
    }
}

fn take_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn novel_url(title: &str, content: &str) -> String {
    let payload = json!({"title": title, "content": content}).to_string();
    format!("novel://{payload}")
}

fn show_title(page: &str) -> String {
    if let Some(cap) = JSONLD_RE.captures(page) {
        return cap[1].to_string();
    }
    TITLE_TAG_RE
        .captures(page)
        .and_then(|cap| cap.get(1))
        .map(|m| clean(m.as_str()))
        .and_then(|t| t.split(" - ").next().map(str::trim).map(str::to_string))
        .unwrap_or_default()
}

fn show_text(page: &str) -> String {
    BODY_RE
        .captures(page)
        .or_else(|| BODY_FALLBACK_RE.captures(page))
        .and_then(|cap| cap.get(1))
        .map(|m| clean_text(m.as_str()))
        .unwrap_or_default()
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
    if category_id == "ranking" && page > 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let tid = if category_id.is_empty() {
        "new"
    } else {
        category_id
    };
    let items = parse_cards(&fetch(&list_url(tid, page)).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = norm_id(series_id);
    let (kind, nid) = match vid.split_once(':') {
        Some((k, n)) => (k.to_string(), n.to_string()),
        None => (String::new(), vid.clone()),
    };
    if kind == "series" {
        let page = fetch(&format!("{BASE_URL}/novel/series/{nid}?p=1")).await;
        let title = TITLE_TAG_RE
            .captures(&page)
            .and_then(|cap| cap.get(1))
            .map(|m| clean(m.as_str()))
            .and_then(|t| t.split(" - ").next().map(str::trim).map(str::to_string))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| vid.clone());
        let mut episodes = Vec::new();
        for item in parse_cards(&page) {
            let id = item["id"].as_str().unwrap_or("").to_string();
            let name = item["title"].as_str().unwrap_or("").to_string();
            if id.starts_with("show:") {
                episodes.push(episode_json(&id, &name, &vid));
            }
        }
        return Ok(json!({
            "id": vid,
            "title": title,
            "cover": "",
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let page = fetch(&format!("{BASE_URL}/novel/show/{nid}")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("ylxs 未返回详情".into()));
    }
    let title = show_title(&page);
    let title = if title.is_empty() {
        vid.clone()
    } else {
        title
    };
    let text = show_text(&page);
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": "",
        "synopsis": take_chars(&text, 200),
        "extra": {},
        "episodes": [episode_json(&format!("show:{nid}"), "阅读", &vid)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = percent_encode_segment(query);
    let url = format!("{BASE_URL}/search/novels?q={q}&p=1");
    let items = parse_cards(&fetch(&url).await);
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
    let (kind, nid) = match url.split_once(':') {
        Some((k, n)) => (k.to_string(), n.to_string()),
        None => ("show".to_string(), url.to_string()),
    };
    if kind != "show" {
        return Err(ApiError::Internal("ylxs 系列请先选单本".into()));
    }
    let page = fetch(&format!("{BASE_URL}/novel/show/{nid}")).await;
    let title = show_title(&page);
    let title = if title.is_empty() {
        nid.clone()
    } else {
        title
    };
    let text = show_text(&page);
    if text.is_empty() {
        return Err(ApiError::Internal("ylxs 该本没有正文".into()));
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
    fn cards_parse_show_and_series() {
        let page = concat!(
            "<article class=\"novel-card x\">",
            "<div class=\"novel-card-title\"><a href=\"/novel/show/12\">书一</a></div>",
            "<span class=\"card-badge\">连载</span></article>",
            "<article class=\"novel-card y\">",
            "<div class=\"novel-card-title\"><a href=\"/novel/series/34\">系列</a></div>",
            "</article>"
        );
        let items = parse_cards(page);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "show:12");
        assert_eq!(items[0]["remark"], "连载");
        assert_eq!(items[1]["id"], "series:34");
    }

    #[test]
    fn list_url_falls_back_to_new() {
        assert_eq!(list_url("nope", 2), "https://ylxs.net/novel/new?p=2");
        assert_eq!(list_url("discovery", 1), "https://ylxs.net/discovery?p=1");
    }
}
