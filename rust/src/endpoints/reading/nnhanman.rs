//! nnhanman：与火蚁TV 的 nnhanman.py 一一对应。
//!
//! 韩漫站：分类只按状态分（全部/已完结/连载中），目录路径为
//! /comics/all/ob/time/st/<状态>（多页加 /page/<n>）；详情取首
//! 个含 new.niaopic.com 的图做封面（无则退 niaopic.com），章节
//! 按页内顺序倒序（先新后旧翻成先旧后新）；取流时先抓
//! data-src 的 nnpic 图，无则退 src，拼成 pics://。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://nnhanman.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MIN_LEN: usize = 10000;

const CATEGORIES: [(&str, &str); 3] = [
    ("all", "全部"),
    ("completed", "已完结"),
    ("serialized", "连载中"),
];

static HTTP: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn client() -> ApiResult<&'static reqwest::Client> {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .ok()
    })
    .as_ref()
    .ok_or_else(|| ApiError::Internal("nnhanman client unavailable".into()))
}

fn must_re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|_| Regex::new("$^").unwrap())
}

fn category_json(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

fn item_json(id: &str, title: &str, cover: &str, remark: &str) -> Value {
    json!({"id": id, "title": title, "cover": cover, "remark": remark})
}

fn episode_json(video_id: &str, title: &str, series_id: &str) -> Value {
    json!({"video_id": video_id, "title": title, "series_id": series_id})
}

fn decode_entities(s: &str) -> String {
    let dec = must_re(r"&#(\d+);");
    let mut out = dec
        .replace_all(s, |caps: &regex::Captures| {
            caps[1]
                .parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    let hex = must_re(r"&#x([0-9a-fA-F]+);");
    out = hex
        .replace_all(&out, |caps: &regex::Captures| {
            u32::from_str_radix(&caps[1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    for (from, to) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&amp;", "&"),
    ] {
        out = out.replace(from, to);
    }
    out
}

fn clean_text(raw: &str) -> String {
    let no_tags = must_re(r"<[^>]+>").replace_all(raw, "");
    let decoded = decode_entities(&no_tags);
    decoded.replace('\u{a0}', " ").trim().to_string()
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 与 py 的 _fetch 一致：最多 3 次，页长不足阈值或请求失败时睡 1 秒
/// 再试；最后一次无论长短都返回（失败返回空串）。
async fn fetch(url: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    for attempt in 0..3 {
        let result = c
            .get(url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE_URL}/"))
            .send()
            .await;
        match result {
            Ok(resp) => {
                let text = resp.text().await.unwrap_or_default();
                if text.chars().count() >= MIN_LEN || attempt == 2 {
                    return text;
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
    let re = must_re(
        r#"(?s)<a class="ImgA" href="(/comic/[^"]+)"[^>]*title="([^"]*)"[^>]*><picture>.*?<img src="([^"]+)""#,
    );
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for caps in re.captures_iter(page) {
        let href = &caps[1];
        if !seen.insert(href.to_string()) {
            continue;
        }
        let name = clean_text(&caps[2]);
        if name.is_empty() {
            continue;
        }
        items.push(item_json(href.trim_matches('/'), &name, &caps[3], ""));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let tid = if category_id.is_empty() {
        "all"
    } else {
        category_id
    };
    let mut path = format!("/comics/all/ob/time/st/{tid}");
    if page > 1 {
        path.push_str(&format!("/page/{page}"));
    }
    let items = parse_list(&fetch(&format!("{BASE_URL}{path}")).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id;
    let slug = if vid.contains('/') {
        vid.split('/').last().unwrap_or("").replace(".html", "")
    } else {
        vid.to_string()
    };
    let path = if vid.starts_with("comic/") {
        vid.to_string()
    } else {
        format!("comic/{vid}.html")
    };
    let page = fetch(&format!("{BASE_URL}/{path}")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("nnhanman未返回详情".into()));
    }
    let name = match must_re(r"(?s)<h1[^>]*>(.*?)</h1>").captures(&page) {
        Some(caps) => clean_text(&caps[1])
            .trim_matches(|c| c == '《' || c == '》')
            .to_string(),
        None => String::new(),
    };
    let name = if name.is_empty() { slug.clone() } else { name };
    let img_re = must_re(r#"<img[^>]*src="(https://[^"]+)""#);
    let mut cover = String::new();
    for caps in img_re.captures_iter(&page) {
        if caps[1].contains("new.niaopic.com") {
            cover = caps[1].to_string();
            break;
        }
    }
    if cover.is_empty() {
        for caps in img_re.captures_iter(&page) {
            if caps[1].contains("niaopic.com") {
                cover = caps[1].to_string();
                break;
            }
        }
    }
    let ch_re = must_re(r#"(?s)<a[^>]*href="/comic/[^/]+/chapter-(\d+)\.html"[^>]*>(.*?)</a>"#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut eps: Vec<(String, String)> = Vec::new();
    for caps in ch_re.captures_iter(&page) {
        let cid = caps[1].to_string();
        let lab = clean_text(&caps[2]);
        if lab.is_empty() || lab == "开始阅读" {
            continue;
        }
        if !seen.insert(cid.clone()) {
            continue;
        }
        eps.push((cid, lab));
    }
    eps.reverse();
    let episodes: Vec<Value> = eps
        .iter()
        .map(|(cid, lab)| episode_json(&format!("nnhanman:{slug}:{cid}"), lab, vid))
        .collect();
    Ok(json!({
        "id": vid,
        "title": name,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!("/search/{}", pct_encode_query(query));
    let items = parse_list(&fetch(&format!("{BASE_URL}{path}")).await);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = strip_label(video_id);
    if url.starts_with("pics://") {
        return Ok(json!({"url": url}));
    }
    let parts: Vec<&str> = url.split(':').collect();
    if parts.len() < 3
        || parts[0] != "nnhanman"
        || parts[2].is_empty()
        || !parts[2].chars().all(|c| c.is_ascii_digit())
    {
        return Ok(json!({"url": url}));
    }
    let (slug, cid) = (parts[1], parts[2]);
    let page = fetch(&format!("{BASE_URL}/comic/{slug}/chapter-{cid}.html")).await;
    let mut seen: HashSet<String> = HashSet::new();
    let mut imgs = Vec::new();
    for caps in must_re(r#"data-src="(https://img\.nnpic\.xyz[^"]+)""#).captures_iter(&page) {
        let img = caps[1].to_string();
        if seen.insert(img.clone()) {
            imgs.push(img);
        }
    }
    if imgs.is_empty() {
        for caps in must_re(r#"<img[^>]*src="(https://img\.nnpic\.xyz[^"]+)""#).captures_iter(&page)
        {
            let img = caps[1].to_string();
            if seen.insert(img.clone()) {
                imgs.push(img);
            }
        }
    }
    if imgs.is_empty() {
        return Err(ApiError::Internal("nnhanman未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_trims_slashes() {
        let page = r#"<a class="ImgA" href="/comic/abc.html" title="漫A"><picture><img src="c1">"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "comic/abc.html");
    }

    #[test]
    fn slug_from_vid() {
        let vid = "comic/abc-def.html";
        let slug = if vid.contains('/') {
            vid.split('/').last().unwrap_or("").replace(".html", "")
        } else {
            vid.to_string()
        };
        assert_eq!(slug, "abc-def");
    }

    #[test]
    fn title_strips_book_marks() {
        let name = clean_text("《漫A》");
        assert_eq!(name.trim_matches(|c| c == '《' || c == '》'), "漫A");
    }
}
