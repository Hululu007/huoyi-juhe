//! 55comics：与火蚁TV 的 55comics.py 一一对应。
//!
//! 漫画站：分类为固定四项（韩漫/日漫/单行本/美漫）；目录与搜索共用
//! 同一套列表解析；详情按章节出分集（单章为全集）；取流时按章节
//! 逐页抓图，拼成 pics:// 交给图片浏览链路（parse=0 原样透传）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://www.55comics.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MIN_LEN: usize = 10000;

const CATEGORIES: [(&str, &str); 4] = [
    ("hanman", "韩漫"),
    ("riman", "日漫"),
    ("danben", "单行本"),
    ("meiman", "美漫"),
];

static HTTP: crate::egress_proxy::ClientSlot = crate::egress_proxy::ClientSlot::new();

fn client() -> ApiResult<&'static reqwest::Client> {
    HTTP.get_or_build(|| {
        crate::egress_proxy::apply_to_builder(
            reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)),
        )
        .build()
        .ok()
    })
    .ok_or_else(|| ApiError::Internal("55comics client unavailable".into()))
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
        r#"<a href="/album/(\d+)\.html">\s*<img[^>]*data-original="([^"]+)"[^>]*title="([^"]*)""#,
    );
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for caps in re.captures_iter(page) {
        let aid = &caps[1];
        if !seen.insert(aid.to_string()) {
            continue;
        }
        let name = clean_text(&caps[3]);
        if name.is_empty() {
            continue;
        }
        items.push(item_json(aid, &name, &caps[2], ""));
    }
    items
}

fn first_digits(id: &str) -> String {
    match must_re(r"(\d+)").captures(id) {
        Some(caps) => caps[1].to_string(),
        None => id.to_string(),
    }
}

async fn chapter_images(cid: &str) -> Vec<String> {
    let first = fetch(&format!("{BASE_URL}/chapter/{cid}.html")).await;
    if first.is_empty() {
        return Vec::new();
    }
    let page_re = must_re(&format!(r"/chapter/{cid}\.html\?p=(\d+)"));
    let mut total = 1i64;
    for caps in page_re.captures_iter(&first) {
        if let Ok(n) = caps[1].parse::<i64>() {
            if n > total {
                total = n;
            }
        }
    }
    let img_re =
        must_re(r#"<img[^>]*data-original="([^"]+)"[^>]*class="[^"]*img-responsive-mw[^"]*""#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut imgs = Vec::new();
    for n in 1..=total {
        let page = if n == 1 {
            first.clone()
        } else {
            fetch(&format!("{BASE_URL}/chapter/{cid}.html?p={n}")).await
        };
        for caps in img_re.captures_iter(&page) {
            let img = caps[1].to_string();
            if seen.insert(img.clone()) {
                imgs.push(img);
            }
        }
    }
    imgs
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let tid = if category_id.is_empty() {
        "hanman"
    } else {
        category_id
    };
    let mut path = format!("/lists/{tid}.html");
    if page > 1 {
        path.push_str(&format!("?p={page}"));
    }
    let items = parse_list(&fetch(&format!("{BASE_URL}{path}")).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let aid = first_digits(series_id);
    let page = fetch(&format!("{BASE_URL}/album/{aid}.html")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("55comics未返回详情".into()));
    }
    let title = match must_re(r"(?s)<h1[^>]*>(.*?)</h1>").captures(&page) {
        Some(caps) => clean_text(&caps[1]),
        None => String::new(),
    };
    let title = if title.is_empty() { aid.clone() } else { title };
    let cover =
        match must_re(r#"<img[^>]*data-original="(https://img\.manhua18h\.com/comic/[^"]+)""#)
            .captures(&page)
        {
            Some(caps) => caps[1].to_string(),
            None => String::new(),
        };
    let ch_re = must_re(r#"<a[^>]*href="/chapter/(\d+)\.html"[^>]*>(.*?)</a>"#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut chs: Vec<(String, String)> = Vec::new();
    for caps in ch_re.captures_iter(&page) {
        let cid = caps[1].to_string();
        if !seen.insert(cid.clone()) {
            continue;
        }
        chs.push((cid, clean_text(&caps[2])));
    }
    let episodes: Vec<Value> = if chs.len() == 1 {
        vec![episode_json(
            &format!("55comics:{}", chs[0].0),
            "全集",
            &aid,
        )]
    } else {
        chs.iter()
            .enumerate()
            .map(|(i, (cid, lab))| {
                let t = if lab.is_empty() {
                    format!("第{}话", i + 1)
                } else {
                    lab.clone()
                };
                episode_json(&format!("55comics:{cid}"), &t, &aid)
            })
            .collect()
    };
    Ok(json!({
        "id": aid,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!("/search.html?keyword={}", pct_encode_query(query));
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
    if let Some(cid) = url.strip_prefix("55comics:") {
        if cid.is_empty() || !cid.chars().all(|c| c.is_ascii_digit()) {
            return Err(ApiError::Internal("55comics章节号无效".into()));
        }
        let imgs = chapter_images(cid).await;
        if imgs.is_empty() {
            return Err(ApiError::Internal("55comics未返回图片".into()));
        }
        return Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_dedups_and_cleans() {
        let page = r#"<a href="/album/123.html">  <img data-original="c1" title="  漫画A  ">
            <a href="/album/123.html">  <img data-original="c1" title="漫画A">
            <a href="/album/124.html">  <img data-original="c2" title="">"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "123");
        assert_eq!(items[0]["title"], "漫画A");
    }

    #[test]
    fn first_digits_falls_back() {
        assert_eq!(first_digits("abc123def"), "123");
        assert_eq!(first_digits("noid"), "noid");
    }

    #[test]
    fn strip_label_keeps_plain_id() {
        assert_eq!(strip_label("55comics:42"), "55comics:42");
        assert_eq!(strip_label("第1话$55comics:42"), "55comics:42");
        assert_eq!(strip_label("pics://a&&b"), "pics://a&&b");
    }

    #[test]
    fn query_encoding_keeps_unreserved_and_slash() {
        assert_eq!(pct_encode_query("海贼王"), "%E6%B5%B7%E8%B4%BC%E7%8E%8B");
        assert_eq!(pct_encode_query("a/b c"), "a/b%20c");
    }
    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert!(!list.is_empty(), "55comics categories empty");
        eprintln!(
            "LIVE 55comics cats={} first={}",
            list.len(),
            list[0]["id"].as_str().unwrap_or("")
        );
        let start = std::time::Instant::now();
        let r = catalog("hanman", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE 55comics cat=hanman items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "55comics catalog hanman empty");
    }
}
