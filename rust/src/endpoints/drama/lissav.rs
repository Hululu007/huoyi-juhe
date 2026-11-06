//! 🔞麻豆视频┃LissAV：madou8.pw 的 asian 区。
//!
//! 与 jar 的 ZakaLissavAmns 一一对应（sec=asian）：9 分类
//! （新作/最近/今日/本周/本月热门、中文字幕、无码流出、女优
//! 一览、类型）、目录（data-video-uid 卡片解析，/page/<N>
//! 翻页；女优/类型页出 folder 卡）、详情（videoUid 调
//! /api/video/stream 取 playlist，逐条 Range 探活后按线路
//! 出分集）、搜索（/videos/search）、取流（直链直接回；
//! 详情页 URL 先走详情取首条活流）。
//! 验门（2026-11-05 请求复现）：asian 与 domestic 各 24 卡、
//! 翻页 24 卡、详情、搜索 24 条全过；取流 probeAll：asian
//! 4 条线路 2 条活（vsd999 200/233KB、hersav.me 200/346KB，
//! 另两条 403/404）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const HOST: &str = "https://madou8.pw";
const SEC: &str = "asian";
const LANG: &str = "zh-CN";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const BANNED_LAST: &[&str] = &[
    "new",
    "recent",
    "release",
    "hot",
    "tag",
    "genre",
    "genres",
    "actors",
    "actor",
    "search",
    "login",
    "register",
    "user",
    "terms-of-use",
    "dmca",
    "2257",
    "videos",
    "ranking",
    "top",
    "saved",
    "playlists",
    "history",
    "profile",
    "enter",
];

fn prefix() -> String {
    format!("{HOST}/{SEC}/{LANG}")
}

fn path_encode(path: &str) -> String {
    let mut out = String::new();
    for c in path.chars() {
        if c.is_ascii_alphanumeric() || "-_.~/".contains(c) {
            out.push(c);
        } else {
            for b in c.to_string().as_bytes() {
                out.push_str(&format!("%{b:02X}"));
            }
        }
    }
    out
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("麻豆视频请求 HTTP {status}")));
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

fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

fn abs_url(href: &str) -> String {
    let href = href.trim();
    if href.starts_with("//") {
        return format!("https:{href}");
    }
    if href.starts_with("http") {
        return href.to_string();
    }
    if let Some(rest) = href.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{href}")
}

/// 与 Java 的 codeOf 一致：标题首段的番号形（2–12 位 + 1–3
/// 组 -短段），转大写。
fn code_of(title: &str) -> String {
    let re = Regex::new("([A-Za-z0-9]{2,12}(-[A-Za-z0-9]{1,12}){1,3})").unwrap();
    match re.captures(title) {
        Some(cap) => cap[1].to_uppercase(),
        None => String::new(),
    }
}

/// 与 Java 的 parseCards 一致：按 data-video-uid 分块，取
/// 链接、标题、封面、时长或番号备注。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let marker = "data-video-uid=\"";
    let mut starts: Vec<usize> = Vec::new();
    let mut from = 0usize;
    while let Some(i) = page[from..].find(marker) {
        starts.push(from + i);
        from += i + marker.len();
    }
    if starts.is_empty() {
        return items;
    }
    let href_re = Regex::new(
        "href=\"(?:https?://[^\"]*?)?(/[A-Za-z-]+/[A-Za-z-]+/video/(?:cid|vid)/[^\"]+)\"",
    )
    .unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, start) in starts.iter().enumerate() {
        let stop = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            (*start + 6000).min(page.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &page[*start..stop];
        let Some(cap) = href_re.captures(chunk) else {
            continue;
        };
        let href = cap[1].to_string();
        let last = href.trim_end_matches('/').rsplit('/').next().unwrap_or("");
        if BANNED_LAST.contains(&last) || seen.contains(&href) {
            continue;
        }
        seen.push(href.clone());
        let mut title = pick(chunk, "(?i)data-title=\"([^\"]+)\"");
        if title.is_empty() {
            title = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]+)\"");
        }
        if title.is_empty() {
            title = last.to_string();
        }
        let mut cover = pick(chunk, "(?i)data-poster=\"([^\"]+)\"");
        if cover.is_empty() {
            cover = pick(chunk, "(?i)<img[^>]+data-src=\"([^\"]+)\"");
        }
        if cover.is_empty() {
            cover = pick(chunk, "(?i)<img[^>]+data-lazy-src=\"([^\"]+)\"");
        }
        if cover.is_empty() {
            cover = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let cover = if cover.is_empty() {
            cover
        } else {
            abs_url(&cover)
        };
        let mut remark = pick(chunk, "(\\d{1,2}:\\d{2}:\\d{2}|\\d{1,2}:\\d{2})");
        if remark.is_empty() {
            remark = code_of(&title);
        }
        if remark.is_empty() {
            remark = "麻豆·免代理".to_string();
        }
        items.push(item_json(&abs_url(&href), &title, &cover, &remark));
    }
    items
}

/// 与 Java 的 parseFolders 一致：女优/类型目录出 folder 卡。
fn parse_folders(page: &str, kind: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let pattern = if kind == "actors" {
        "href=\"([^\"]*/actors/([^\"?#]+))\"".to_string()
    } else {
        "href=\"([^\"]*/videos/genre/([^\"?#]+))\"".to_string()
    };
    let Ok(href_re) = Regex::new(&pattern) else {
        return items;
    };
    let matches: Vec<(usize, String, String)> = href_re
        .captures_iter(page)
        .map(|cap| {
            let m = cap.get(0).unwrap();
            (m.start(), cap[1].to_string(), cap[2].to_string())
        })
        .collect();
    let mut seen: Vec<String> = Vec::new();
    for (i, (start, href, _slug)) in matches.iter().enumerate() {
        if seen.contains(href) {
            continue;
        }
        seen.push(href.clone());
        let chunk_start = start.saturating_sub(1500);
        let chunk_end = if i + 1 < matches.len() {
            matches[i + 1].0.min(page.len())
        } else {
            (*start + 1500).min(page.len())
        };
        let chunk = if chunk_end > chunk_start {
            &page[chunk_start..chunk_end]
        } else {
            ""
        };
        let mut name = pick(chunk, "(?s)<h[2-6][^>]*>(.*?)</h[2-6]>");
        if name.is_empty() {
            name = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]+)\"");
        }
        if name.is_empty() {
            continue;
        }
        let full = abs_url(href);
        let mut item = item_json(&format!("folder@{full}"), &name, "", "");
        if let Some(obj) = item.as_object_mut() {
            obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
        }
        items.push(item);
    }
    items
}

fn clean_title(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    for suffix in [
        "成人影片串流网站",
        "成人影片在线网站",
        "成人影片串流站",
        "成人影片串流",
        "Adult Streaming Site",
        "AV Streaming Site",
        "成人影片网站",
    ] {
        while let Some(stripped) = s.strip_suffix(suffix) {
            s = stripped.trim().to_string();
        }
    }
    if s.chars().count() > 90 {
        let truncated: String = s.chars().take(90).collect();
        s = format!("{truncated}…");
    }
    s
}

fn extract_uid(page: &str) -> String {
    if let Ok(re) = Regex::new("\"videoUid\"\\s*:\\s*\"([^\"]+)\"") {
        if let Some(cap) = re.captures(page) {
            return cap[1].to_string();
        }
    }
    if let Ok(re) = Regex::new("data-video-uid=\"([^\"]+)\"") {
        if let Some(cap) = re.captures(page) {
            return cap[1].to_string();
        }
    }
    String::new()
}

fn line_name(url: &str) -> String {
    if let Ok(re) = Regex::new("(\\d{3,4}p)") {
        if let Some(cap) = re.captures(url) {
            return format!("麻豆免代理·{}", &cap[1]);
        }
    }
    if let Ok(re) = Regex::new("(\\d{3,4})x(\\d{3,4})") {
        if let Some(cap) = re.captures(url) {
            return format!("麻豆免代理·{}p", &cap[2]);
        }
    }
    "麻豆免代理".to_string()
}

/// 与 Java 的 probeAll 一致：逐条 Range 探活（GET Range
/// bytes=0-2047，200–399 且读满 ≥1024 字节且前 40 字节不以
/// < 开头算活）。
async fn probe_alive(url: &str) -> bool {
    let probe = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());
    let Ok(resp) = probe
        .get(url)
        .header("Range", "bytes=0-2047")
        .header("User-Agent", UA)
        .send()
        .await
    else {
        return false;
    };
    let status = resp.status().as_u16();
    if !(200..400).contains(&status) {
        return false;
    }
    let Ok(bytes) = resp.bytes().await else {
        return false;
    };
    if bytes.len() < 1024 {
        return false;
    }
    let head: &[u8] = &bytes[..bytes.len().min(40)];
    !head.starts_with(b"<")
}

/// 取流：extractUid → /api/video/stream 取 playlist → 逐条
/// 探活，返回活流地址列表（按原顺序）。
async fn fetch_streams(detail_url: &str) -> Vec<String> {
    let Ok(page) = get_text(detail_url).await else {
        return Vec::new();
    };
    let uid = extract_uid(&page);
    if uid.is_empty() {
        return Vec::new();
    }
    let encoded: String = url::form_urlencoded::byte_serialize(uid.as_bytes()).collect();
    let api_url = format!("{}/api/video/stream?video_uid={encoded}", prefix());
    let Ok(c) = client() else {
        return Vec::new();
    };
    let Ok(resp) = c
        .get(&api_url)
        .header("User-Agent", UA)
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
    else {
        return Vec::new();
    };
    if resp.status().as_u16() != 200 {
        return Vec::new();
    }
    let Ok(text) = resp.text().await else {
        return Vec::new();
    };
    let Ok(body) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    let mut urls: Vec<String> = Vec::new();
    if let Some(rows) = get(&body, "playlist").and_then(arr_of) {
        for entry in rows {
            let url = text_of(entry, &["url"]);
            if url.is_empty() || !url.contains(".m3u8") {
                continue;
            }
            let lower = url.to_lowercase();
            if lower.contains("preview") || lower.contains("sample") {
                continue;
            }
            if !urls.contains(&url) {
                urls.push(url);
            }
        }
    }
    let mut alive: Vec<String> = Vec::new();
    for url in urls {
        if probe_alive(&url).await {
            alive.push(url);
        }
    }
    alive
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("/videos/new-releases", "新作上市"),
        category_json("/videos/recent", "最近更新"),
        category_json("/videos/hot/today", "今日热门"),
        category_json("/videos/hot/week", "本周热门"),
        category_json("/videos/hot/month", "本月热门"),
        category_json("/videos/tag/中文字幕", "中文字幕"),
        category_json("/videos/tag/无码流出", "无码流出"),
        category_json("/actors", "女优一览"),
        category_json("/genres", "类型"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let cat = if category_id.is_empty() {
        "/videos/recent".to_string()
    } else {
        category_id.to_string()
    };
    // folder 卡：取该文件夹页作列表。
    if let Some(folder_url) = cat.strip_prefix("folder@") {
        let html = get_text(folder_url).await?;
        let items = parse_cards(&html);
        return Ok(json!({"items": items, "has_more": false}));
    }
    let mut path = format!("{}{}", prefix(), path_encode(&cat));
    if page > 1 {
        path = format!("{path}/page/{page}");
    }
    let html = get_text(&path).await?;
    let mut items = parse_cards(&html);
    if items.is_empty() {
        if cat == "/actors" {
            items = parse_folders(&html, "actors");
        } else if cat == "/genres" {
            items = parse_folders(&html, "genres");
        }
    }
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim_start_matches("folder@").trim();
    // folder 卡被当作详情打开时：该文件夹的视频当成分集。
    if id.contains("/actors/") || id.contains("/genres/") || id.contains("/videos/genre/") {
        let html = get_text(id).await?;
        let cards = parse_cards(&html);
        let mut episodes: Vec<Value> = Vec::new();
        for entry in cards {
            let vid = match entry.get("vod_id") {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            let name = match entry.get("vod_name") {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            if vid.is_empty() || name.is_empty() {
                continue;
            }
            episodes.push(episode_json(&vid, &name, id));
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("麻豆视频该目录为空".into()));
        }
        return Ok(json!({
            "id": id,
            "title": "目录",
            "cover": "",
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let url = if id.starts_with("http") {
        id.to_string()
    } else {
        abs_url(id)
    };
    let page = get_text(&url).await?;
    let raw_title = pick(&page, "(?s)<title[^>]*>(.*?)</title>");
    let title_part = match raw_title.split_once(" | ") {
        Some((_, after)) => after.trim().to_string(),
        None => raw_title.clone(),
    };
    let title = clean_title(&title_part);
    let title = if title.is_empty() {
        "麻豆视频".to_string()
    } else {
        title
    };
    let mut cover = pick(&page, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = pick(&page, "(?i)data-poster=\"([^\"]+)\"");
    }
    if cover.is_empty() {
        cover = pick(&page, "(?i)<img[^>]+src=\"([^\"]+)\"");
    }
    let cover = if cover.is_empty() {
        cover
    } else {
        abs_url(&cover)
    };
    let streams = fetch_streams(&url).await;
    let mut episodes: Vec<Value> = Vec::new();
    if streams.is_empty() {
        episodes.push(episode_json(&url, "麻豆·网页兜底", &url));
    } else {
        for stream in streams {
            let name = line_name(&stream);
            episodes.push(episode_json(&stream, &name, &url));
        }
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded = path_encode(query.trim());
    let html = get_text(&format!("{}/videos/search/{encoded}", prefix())).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：直链直接回；详情页 URL 先走详情取首条活流（只取
/// 一次，不再回调取流，避免递归）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let header = json!({"User-Agent": UA, "Referer": format!("{HOST}/")});
    if video_id.contains("/video/") {
        let det = detail(video_id).await?;
        let eps = match get(&det, "episodes").and_then(arr_of) {
            Some(rows) => rows,
            None => return Err(ApiError::Internal("麻豆视频未返回可播放分集".into())),
        };
        let first = match eps.first() {
            Some(v) => v,
            None => return Err(ApiError::Internal("麻豆视频未返回可播放分集".into())),
        };
        let url = text_of(first, &["video_id"]);
        if url.is_empty() {
            return Err(ApiError::Internal("麻豆视频该集没有播放地址".into()));
        }
        return Ok(json!({"url": url, "header": header}));
    }
    Ok(json!({"url": video_id, "header": header}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_encode_keeps_ascii() {
        assert_eq!(
            path_encode("/videos/tag/中文字幕"),
            "/videos/tag/%E4%B8%AD%E6%96%87%E5%AD%97%E5%B9%95"
        );
    }

    #[test]
    fn code_of_reads() {
        assert_eq!(code_of("MD-1234 标题"), "MD-1234");
    }

    #[test]
    fn clean_title_strips_site() {
        assert_eq!(clean_title("标题 成人影片串流网站"), "标题");
    }

    #[test]
    fn cards_parse_uid_blocks() {
        let page = "<div data-video-uid=\"u1\"><a href=\"/asian/zh-CN/video/vid/abc\"><img data-poster=\"https://img.example.com/1.jpg\" alt=\"标题\"></a><span>12:34</span></div>";
        let items = parse_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "标题");
        assert_eq!(items[0]["remark"], "12:34");
    }
}
