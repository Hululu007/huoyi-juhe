//! kmh001：与火蚁TV 的 kmh001.py 一一对应。
//!
//! 韩漫站：目录走 JSON 接口 /api/comic（按连载状态分最新/连载中/
//! 已完结）；详情从 SSR 页内嵌的转义 JSON 里取标题/简介/封面与章
//! 节（章节按 ordinal 排序）；搜索只查第 1 页（py 对第 2 页起返回
//! 空）；取流时按 sourceID 分组取图片源，取图片最多的那组、按
//! sortIndex 排序，拼成 pics:// 交给图片浏览链路。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://kmh001.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MIN_LEN: usize = 1000;

const CATEGORIES: [(&str, &str); 3] = [("", "最新"), ("ongoing", "连载中"), ("complete", "已完结")];

static HTTP: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn client() -> ApiResult<&'static reqwest::Client> {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .ok()
    })
    .as_ref()
    .ok_or_else(|| ApiError::Internal("kmh001 client unavailable".into()))
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

fn str_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

fn get<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object().and_then(|m| m.get(key))
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

fn parse_api_list(text: &str) -> Vec<Value> {
    let obj: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let records = match get(&obj, "records").and_then(|v| v.as_array()) {
        Some(r) => r,
        None => return Vec::new(),
    };
    let mut items = Vec::new();
    for rec in records {
        let cid = str_of(get(rec, "_id").unwrap_or(&Value::Null));
        let name = str_of(get(rec, "name").unwrap_or(&Value::Null));
        let mut cover = str_of(get(rec, "cover").unwrap_or(&Value::Null));
        if !cover.starts_with("http") {
            cover = String::new();
        }
        let remarks = match get(rec, "lastChapter") {
            Some(last) => str_of(get(last, "subtitle").unwrap_or(&Value::Null)),
            None => String::new(),
        };
        if !cid.is_empty() && !name.is_empty() {
            items.push(item_json(&cid, &name, &cover, &remarks));
        }
    }
    items
}

fn parse_ssr_cards(page: &str) -> Vec<Value> {
    let re = must_re(
        r#"\\"href\\":\\"/comic/([0-9a-f]{24})\\".{0,800}?\\"src\\":\\"(https://[^\\"]+)\\".{0,800}?\\"h3\\"[^}]*?\\"children\\":\\"([^\\"]+)\\""#,
    );
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for caps in re.captures_iter(page) {
        let cid = &caps[1];
        if !seen.insert(cid.to_string()) {
            continue;
        }
        let name = clean_text(&caps[3]);
        if name.is_empty() {
            continue;
        }
        items.push(item_json(cid, &name, &caps[2], ""));
    }
    items
}

fn first_hex24(id: &str) -> String {
    match must_re(r"([0-9a-f]{24})").captures(id) {
        Some(caps) => caps[1].to_string(),
        None => id.to_string(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = format!("{BASE_URL}/api/comic?tag=&status={category_id}&current={page}");
    let items = parse_api_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let cid = first_hex24(series_id);
    let page = fetch(&format!("{BASE_URL}/comic/{cid}")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("kmh001未返回详情".into()));
    }
    let name = match must_re(r#"og:title\\"[^}]*?content\\":\\"([^\\"]+)"#).captures(&page) {
        Some(caps) => clean_text(&caps[1])
            .split(" | ")
            .next()
            .unwrap_or("")
            .to_string(),
        None => String::new(),
    };
    let name = if name.is_empty() { cid.clone() } else { name };
    let desc = match must_re(r#"og:description\\"[^}]*?content\\":\\"([^\\"]+)"#).captures(&page) {
        Some(caps) => clean_text(&caps[1]),
        None => String::new(),
    };
    let cover = match must_re(r#"og:image\\"[^}]*?content\\":\\"([^\\"]+)"#).captures(&page) {
        Some(caps) => caps[1].to_string(),
        None => String::new(),
    };
    let author = match must_re(r#"作者：([^\\"]+)"#).captures(&page) {
        Some(caps) => clean_text(&caps[1]),
        None => String::new(),
    };
    let block_re = must_re(r#"\{\\"_id\\":\\"([0-9a-f]{24})\\"(.*?)\}"#);
    let sub_re = must_re(r#"\\"subtitle\\":\\"([^\\"]+)\\""#);
    let ord_re = must_re(r#"\\"ordinal\\":(\d+)"#);
    let mut eps: Vec<(i64, String, String)> = Vec::new();
    for block in block_re.captures_iter(&page) {
        let body = &block[2];
        let sub = match sub_re.captures(body) {
            Some(caps) => caps[1].to_string(),
            None => String::new(),
        };
        if sub.is_empty() {
            continue;
        }
        let ordinal = match ord_re.captures(body) {
            Some(caps) => caps[1].parse::<i64>().unwrap_or(9999),
            None => 9999,
        };
        eps.push((ordinal, sub, block[1].to_string()));
    }
    eps.sort_by_key(|(ordinal, _, _)| *ordinal);
    let episodes: Vec<Value> = eps
        .iter()
        .map(|(_, sub, chapter_id)| episode_json(&format!("kmh001:{cid}:{chapter_id}"), sub, &cid))
        .collect();
    let extra = if author.is_empty() {
        json!({})
    } else {
        json!({"author": author})
    };
    Ok(json!({
        "id": cid,
        "title": name,
        "cover": cover,
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE_URL}/search?key={}", pct_encode_query(query));
    let items = parse_ssr_cards(&fetch(&url).await);
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
    if parts.len() < 3 || parts[0] != "kmh001" {
        return Ok(json!({"url": url}));
    }
    let chapter_id = parts[2];
    let page = fetch(&format!("{BASE_URL}/chapter/{chapter_id}")).await;
    let re = must_re(
        r#"\\"sourceID\\":\\"([0-9a-f]{24})\\",\\"sourceName\\":\\"[^\\"]+\\",\\"url\\":\\"([^\\"]+)\\",\\"sortIndex\\":(\d+)"#,
    );
    let mut groups: Vec<(String, Vec<(i64, String)>)> = Vec::new();
    for caps in re.captures_iter(&page) {
        let sid = caps[1].to_string();
        let sort_idx = caps[3].parse::<i64>().unwrap_or(0);
        let img = caps[2].to_string();
        match groups.iter_mut().find(|(id, _)| *id == sid) {
            Some((_, list)) => list.push((sort_idx, img)),
            None => groups.push((sid, vec![(sort_idx, img)])),
        }
    }
    let mut best: Vec<(i64, String)> = Vec::new();
    for (_, list) in &groups {
        if best.is_empty() || list.len() > best.len() {
            best = list.clone();
        }
    }
    best.sort_by_key(|(sort_idx, _)| *sort_idx);
    let imgs: Vec<String> = best.into_iter().map(|(_, u)| u).collect();
    if imgs.is_empty() {
        return Err(ApiError::Internal("kmh001未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_list_filters_and_cover_rule() {
        let text = r#"{"records":[
            {"_id":"aaaaaaaaaaaaaaaaaaaaaaaa","name":"漫A","cover":"https://x/c.jpg","lastChapter":{"subtitle":"第3话"}},
            {"_id":"bbbbbbbbbbbbbbbbbbbbbbbb","name":"漫B","cover":"/rel/c.jpg","lastChapter":{}},
            {"_id":"","name":"无id"},
            {"_id":"cccccccccccccccccccccccc","name":""}
        ]}"#;
        let items = parse_api_list(text);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["remark"], "第3话");
        assert_eq!(items[1]["cover"], "");
    }

    #[test]
    fn first_hex24_extracts() {
        assert_eq!(
            first_hex24("xxaaaaaaaaaaaaaaaaaaaaaaaaYY"),
            "aaaaaaaaaaaaaaaaaaaaaaaa"
        );
        assert_eq!(first_hex24("short"), "short");
    }

    #[test]
    fn ssr_cards_parse() {
        let page = r#"{\"href\":\"/comic/aaaaaaaaaaaaaaaaaaaaaaaa\",\"src\":\"https://x/c.jpg\",\"h3\":{\"children\":\"漫A\"}}"#;
        let items = parse_ssr_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "aaaaaaaaaaaaaaaaaaaaaaaa");
    }
}
