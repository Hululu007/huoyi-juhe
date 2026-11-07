//! csmanhua：与火蚁TV 的 csmanhua.py 一一对应。
//!
//! 成色漫画：分类为固定 20 项（含显式成人分类“成人AI短剧”）；目录与
//! 搜索共用同一套列表解析；详情分两支——页内有 video 标签时出视频
//! 分集（直链透传），否则按漫画出全集一集，取流时抓 runtime-image
//! 图片拼成 pics:// 交给图片浏览链路（parse=0 原样透传）。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://csmanhua.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MIN_LEN: usize = 10000;

const CATEGORIES: [(&str, &str); 20] = [
    ("5", "成人AI短剧"),
    ("8", "单行本"),
    ("21", "单行本-汉化"),
    ("22", "单行本-日语"),
    ("23", "单行本-外语"),
    ("7", "同人志"),
    ("13", "同人志-汉化"),
    ("14", "同人志-日语"),
    ("15", "同人志-外语"),
    ("16", "CG画集"),
    ("17", "3D漫画"),
    ("18", "AI图集"),
    ("24", "Cosplay"),
    ("6", "杂志&短篇"),
    ("10", "杂志&短篇-汉化"),
    ("11", "杂志&短篇-日语"),
    ("12", "杂志&短篇-外语"),
    ("9", "韩漫"),
    ("19", "韩漫-汉化"),
    ("20", "韩漫-其他"),
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
    .ok_or_else(|| ApiError::Internal("csmanhua client unavailable".into()))
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
        r#"(?s)<a href="/cs-(\d+)/"[^>]*>.*?<img[^>]*data-src="([^"]+)"[^>]*alt="([^"]*)""#,
    );
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for caps in re.captures_iter(page) {
        let wid = &caps[1];
        if !seen.insert(wid.to_string()) {
            continue;
        }
        let name = clean_text(&caps[3]);
        if name.is_empty() {
            continue;
        }
        items.push(item_json(wid, &name, &caps[2], ""));
    }
    items
}

fn first_digits(id: &str) -> String {
    match must_re(r"(\d+)").captures(id) {
        Some(caps) => caps[1].to_string(),
        None => id.to_string(),
    }
}

/// 与 py 的 _detail_images 一致：取 runtime-image 图片（去重）。
/// py 会把详情页再抓一次，本模块直接复用详情已抓到的页，结果相同。
fn detail_images(page: &str) -> Vec<String> {
    let re = must_re(r#"<img[^>]*class="runtime-image"[^>]*src="([^"]+)""#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut imgs = Vec::new();
    for caps in re.captures_iter(page) {
        let img = caps[1].to_string();
        if seen.insert(img.clone()) {
            imgs.push(img);
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
        "8"
    } else {
        category_id
    };
    let path = if page > 1 {
        format!("/cstype/{tid}-{page}/")
    } else {
        format!("/cstype/{tid}/")
    };
    let items = parse_list(&fetch(&format!("{BASE_URL}{path}")).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let wid = first_digits(series_id);
    let page = fetch(&format!("{BASE_URL}/cs-{wid}/")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("csmanhua未返回详情".into()));
    }
    let name = match must_re(r"(?s)<title>(.*?)</title>").captures(&page) {
        Some(caps) => clean_text(&caps[1])
            .split(" - 成色漫画")
            .next()
            .unwrap_or("")
            .trim()
            .to_string(),
        None => String::new(),
    };
    let name = if name.is_empty() { wid.clone() } else { name };
    let mut videos: Vec<(String, String)> =
        must_re(r#"<video[^>]*data-hls-src="([^"]+)"[^>]*data-fallback-src="([^"]*)"[^>]*>"#)
            .captures_iter(&page)
            .map(|caps| (caps[1].to_string(), caps[2].to_string()))
            .collect();
    if videos.is_empty() {
        videos =
            must_re(r#"<video[^>]*data-fallback-src="([^"]+)"[^>]*data-hls-src="([^"]*)"[^>]*>"#)
                .captures_iter(&page)
                .map(|caps| (caps[2].to_string(), caps[1].to_string()))
                .collect();
    }
    if !videos.is_empty() {
        let poster = match must_re(r#"<video[^>]*poster="([^"]+)""#).captures(&page) {
            Some(caps) => caps[1].to_string(),
            None => String::new(),
        };
        let mut episodes = Vec::new();
        for (i, (hls, mp4)) in videos.iter().enumerate() {
            let media = if !hls.is_empty() { hls } else { mp4 };
            if media.is_empty() {
                continue;
            }
            episodes.push(episode_json(
                &format!("csmanhua:video:{media}"),
                &format!("第{}集", i + 1),
                &wid,
            ));
        }
        return Ok(json!({
            "id": wid,
            "title": name,
            "cover": poster,
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let imgs = detail_images(&page);
    let cover = imgs.first().cloned().unwrap_or_default();
    Ok(json!({
        "id": wid,
        "title": name,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": [episode_json(&format!("csmanhua:{wid}"), "全集", &wid)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!("/cssearch/-------/?wd={}", pct_encode_query(query));
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
    if let Some(media) = url.strip_prefix("csmanhua:video:") {
        return Ok(json!({"url": media}));
    }
    if let Some(wid) = url.strip_prefix("csmanhua:") {
        if wid.is_empty() || !wid.chars().all(|c| c.is_ascii_digit()) {
            return Err(ApiError::Internal("csmanhua编号无效".into()));
        }
        let page = fetch(&format!("{BASE_URL}/cs-{wid}/")).await;
        let imgs = detail_images(&page);
        if imgs.is_empty() {
            return Err(ApiError::Internal("csmanhua未返回图片".into()));
        }
        return Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_dedups() {
        let page = r#"<a href="/cs-7/"><img data-src="c1" alt="本A">
            <a href="/cs-7/"><img data-src="c1" alt="本A">
            <a href="/cs-8/"><img data-src="c2" alt="">"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "7");
        assert_eq!(items[0]["title"], "本A");
    }

    #[test]
    fn video_branch_prefers_hls() {
        let page = r#"<title>作品 - 成色漫画</title><video data-hls-src="h.m3u8" data-fallback-src="f.mp4" poster="p.jpg">"#;
        let poster = must_re(r#"<video[^>]*poster="([^"]+)""#)
            .captures(page)
            .unwrap()[1]
            .to_string();
        assert_eq!(poster, "p.jpg");
        let videos: Vec<(String, String)> =
            must_re(r#"<video[^>]*data-hls-src="([^"]+)"[^>]*data-fallback-src="([^"]*)"[^>]*>"#)
                .captures_iter(page)
                .map(|c| (c[1].to_string(), c[2].to_string()))
                .collect();
        assert_eq!(videos[0], ("h.m3u8".to_string(), "f.mp4".to_string()));
    }

    #[test]
    fn strip_label_and_video_prefix() {
        assert_eq!(strip_label("全集$csmanhua:9"), "csmanhua:9");
        assert_eq!(
            "csmanhua:video:https://x/1.m3u8".strip_prefix("csmanhua:video:"),
            Some("https://x/1.m3u8")
        );
    }
    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert!(!list.is_empty(), "csmanhua categories empty");
        eprintln!(
            "LIVE csmanhua cats={} first={}",
            list.len(),
            list[0]["id"].as_str().unwrap_or("")
        );
        let start = std::time::Instant::now();
        let r = catalog("5", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE csmanhua cat=5 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "csmanhua catalog 5 empty");
    }
}
