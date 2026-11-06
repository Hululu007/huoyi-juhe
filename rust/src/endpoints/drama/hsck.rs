//! 👑帝皇影视┃黄色仓库②：hsck123.com 的 HTML 站。
//!
//! 与 jar 的 ZakaHsckAmns 一一对应：仅 1 分类（最新）、目录
//! （首页 /?p=<N> 翻页，totalPages 取总页数）、详情（/view/?id=
//! 取标题、封面与首个 m3u8）、搜索（/?p=&search2=ndafeoafa&
//! search=）、取流（直链直接回，无头）。
//! 验门（2026-11-05 请求复现）：首页 40 卡、翻页 40 卡（总页
//! 数 86）、详情（标题 + m3u8）、流首分片 200（930KB）、搜索
//! 40 条全过。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json};

const HOST: &str = "https://hsck123.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";
const SEARCH_SALT: &str = "ndafeoafa";

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Accept-Language", "zh-CN")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄色仓库②请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
}

fn pick(page: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(page) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 与 Java 的 parseList 一致：正则取 /view/?id= 链接、标题与
/// 封面，vod_id 为 id 参数值。
fn parse_list(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let Ok(re) = Regex::new(
        "(?s)href=\"(/view/\\?id=([a-z0-9]+))\"[^>]*?title=\"([^\"]*)\"[^>]*?data-original=\"([^\"]*)\"",
    ) else {
        return items;
    };
    let mut seen: Vec<String> = Vec::new();
    for cap in re.captures_iter(page) {
        let id = cap[2].to_string();
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let title = cap[3].trim().to_string();
        let title = if title.is_empty() { id.clone() } else { title };
        let pic = cap[4].trim().to_string();
        let pic = if pic.starts_with("http") {
            pic
        } else if pic.starts_with("//") {
            format!("https:{pic}")
        } else if pic.starts_with('/') {
            format!("{HOST}{pic}")
        } else {
            String::new()
        };
        items.push(item_json(&id, &title, &pic, ""));
    }
    items
}

fn total_pages(page: &str) -> i64 {
    let Ok(re) = Regex::new("totalPages:\\s*(\\d+)") else {
        return 0;
    };
    match re.captures(page) {
        Some(cap) => cap[1].parse().unwrap_or(0),
        None => 0,
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [category_json("new", "最新")]}))
}

pub(crate) async fn catalog(_category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page > 1 {
        format!("{HOST}/?p={page}")
    } else {
        format!("{HOST}/")
    };
    let html = get_text(&url).await?;
    let items = parse_list(&html);
    let total = total_pages(&html);
    let has_more = if total > 0 {
        page < total
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim();
    let url = format!("{HOST}/view/?id={id}");
    let page = get_text(&url).await?;
    let raw_title = pick(&page, "(?s)<title[^>]*>(.*?)</title>");
    let mut title = String::new();
    for seg in raw_title.split(" - ") {
        let seg = seg.trim();
        if seg.is_empty() || seg == "黄色仓库" {
            continue;
        }
        title = seg.to_string();
        break;
    }
    if title.is_empty() {
        title = format!("黄色仓库 {id}");
    } else if !title.starts_with("黄色仓库") {
        title = format!("黄色仓库 {title}");
    }
    let mut cover = pick(&page, "(?i)<img[^>]*id=\"video_img\"[^>]*src=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = pick(&page, "(?i)<img[^>]*src=\"([^\"]+)\"[^>]*id=\"video_img\"");
    }
    let cover = if cover.starts_with("http") {
        cover
    } else if cover.starts_with("//") {
        format!("https:{cover}")
    } else if cover.starts_with('/') {
        format!("{HOST}{cover}")
    } else {
        String::new()
    };
    let stream = {
        let re = Regex::new("(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)").unwrap();
        re.captures(&page)
            .map(|cap| cap[1].to_string())
            .unwrap_or_default()
    };
    let remark = if stream.is_empty() {
        "无源"
    } else {
        "直连"
    };
    let mut extra = serde_json::Map::new();
    extra.insert("remark".to_string(), Value::String(remark.to_string()));
    let mut episodes: Vec<Value> = Vec::new();
    if !stream.is_empty() {
        episodes.push(episode_json(&stream, "正片", &url));
    } else {
        episodes.push(episode_json(&url, "正片", &url));
    }
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let url = format!("{HOST}/?p=1&search2={SEARCH_SALT}&search={encoded}");
    let html = get_text(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items}))
}

/// 取流：直链直接回（parse 0，无头）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    let det = detail(video_id).await?;
    let eps = match get(&det, "episodes").and_then(|v| v.as_array()) {
        Some(rows) => rows,
        None => return Err(ApiError::Internal("黄色仓库②未返回可播放分集".into())),
    };
    let first = match eps.first() {
        Some(v) => v,
        None => return Err(ApiError::Internal("黄色仓库②未返回可播放分集".into())),
    };
    let url = match first.get("video_id") {
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    };
    if url.is_empty() {
        return Err(ApiError::Internal("黄色仓库②该集没有播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_parses_view_links() {
        let page = "<a href=\"/view/?id=abc123\" title=\"标题\" data-original=\"https://img.example.com/1.jpg\">";
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "abc123");
        assert_eq!(items[0]["title"], "标题");
    }

    #[test]
    fn total_pages_reads() {
        assert_eq!(total_pages("var totalPages: 86;"), 86);
    }
}
