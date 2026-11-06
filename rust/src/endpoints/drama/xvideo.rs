//! XVIDEOS：欧美免代理站。
//!
//! 与 jar 的 ZakaXvAmns 一一对应：分类（最新/最佳/Gay/Trans）、
//! 目录（/new/%d 等，卡片取 match 后 1800 字符的片段解析）、详情
//! （标题/og 图/og 简介，m3u8 与 mp4 两组流）、搜索（/?k=，
//! 第 1 页）、取流（直链透传）。站地址为 xvideos163.top 镜像。
//! 注意：jar 的 ZakaGate 在此 jar 里是空实现（guard/detail 均
//! 返回 null），即无门禁，直接请求即可；封面在核心里回直链，
//! 不走 jar 的本机回环代理包装。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://www.xvideos163.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATS: &[(&str, &str, &str)] = &[
    ("new", "最新", "/new/%d"),
    ("best", "最佳", "/best/%d"),
    ("gay", "Gay", "/gay/%d?fmc=1"),
    ("trans", "Trans", "/trans/%d?fmc=1"),
];

/// 与 Java 的 head 一致（Cookie 门禁头＋UA＋Accept＋语言＋同域 Referer）。
fn headers() -> Vec<(String, String)> {
    vec![
        ("Cookie".to_string(), "x-index-auth=authed".to_string()),
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        (
            "Accept-Language".to_string(),
            "en-US,en;q=0.9,zh-CN;q=0.8".to_string(),
        ),
        ("Referer".to_string(), format!("{HOST}/")),
    ]
}

async fn fetch_text(url: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("XVIDEOS 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 ZakaAvjoyAmns.unesc 一致。
fn unesc(raw: &str) -> String {
    raw.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#x2F;", "/")
}

/// 与 Java 的 u 一致：// 补 https:。
fn abs_url(raw: &str) -> String {
    let s = unesc(raw).trim().to_string();
    if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else {
        s
    }
}

/// 与 Java 的 isPreview 一致：预告/缩略图地址剔除。
fn is_preview(url: &str) -> bool {
    let lower = url.to_lowercase();
    lower.contains("preview")
        || lower.contains("_t.jpg")
        || lower.contains("mozaique")
        || lower.contains("lightbox")
}

/// 与 Java 的 first 一致：取正则第 1 组，非空才算。
fn first(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

/// 与 Java 的 cardTitle 一致：title 属性优先，否则取链接 slug。
fn card_title(href: &str, segment: &str) -> String {
    let re = Regex::new("title=\"([^\"]{2,300})\"").unwrap();
    let title = first(&re, segment);
    if title.chars().count() > 1 {
        return unesc(&title);
    }
    let trimmed = href.trim_end_matches('/');
    let slug = trimmed.rsplit('/').next().unwrap_or("").replace('_', " ");
    let slug = slug.trim().to_string();
    // 末段只是 video.xxx 编号、没有标题段时，不算标题。
    if slug.chars().count() > 1 && !slug.starts_with("video.") {
        slug
    } else {
        "XVIDEOS".to_string()
    }
}

/// 与 Java 的 pic 一致：data-mzl → data-src → img src，取到 http 开头的才算。
fn pic_of(segment: &str) -> String {
    for pat in [
        "data-mzl=\"([^\"]+)\"",
        "data-src=\"([^\"]+)\"",
        "<img[^>]*src=\"([^\"]+)\"",
    ] {
        let re = Regex::new(pat).unwrap();
        if let Some(cap) = re.captures(segment).and_then(|c| c.get(1)) {
            let url = abs_url(cap.as_str());
            if url.starts_with("http") {
                return url;
            }
        }
    }
    String::new()
}

/// 与 Java 的 appendCards 一致：每条 href 取其后 1800 字符的片段解析。
fn append_cards(html: &str, limit: usize) -> Vec<Value> {
    let re_video = Regex::new("href=\"(/video\\.[a-z0-9]+/[^\"]+)\"").unwrap();
    let re_dur = Regex::new("<span class=\"duration\">([^<]{2,20})</span>").unwrap();
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if html.len() < 200 {
        return items;
    }
    for cap in re_video.captures_iter(html) {
        if items.len() >= limit {
            break;
        }
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if href.is_empty() || !seen.insert(href.to_string()) {
            continue;
        }
        let start = cap.get(0).map(|m| m.start()).unwrap_or(0);
        let end = (cap.get(0).map(|m| m.end()).unwrap_or(0) + 1800).min(html.len());
        let segment = &html[start..end];
        let title = card_title(href, segment);
        let cover = pic_of(segment);
        let remark = first(&re_dur, segment);
        let remark = if remark.is_empty() {
            "XVIDEOS".to_string()
        } else {
            remark
        };
        items.push(item_json(&format!("{HOST}{href}"), &title, &cover, &remark));
    }
    items
}

/// 与 Java 的 streams 一致：m3u8 一组在前，mp4 一组在后，均去重去预告。
fn streams(html: &str) -> (Vec<String>, Vec<String>) {
    let re_m3u8 = Regex::new("https?://[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*").unwrap();
    let re_mp4 = Regex::new("https?://[^\"'\\s<>]+?\\.mp4[^\"'\\s<>]*").unwrap();
    let mut hls: Vec<String> = Vec::new();
    let mut mp4: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for m in re_m3u8.find_iter(html) {
        let url = unesc(m.as_str()).trim().to_string();
        if is_preview(&url) || !seen.insert(url.clone()) {
            continue;
        }
        hls.push(url);
    }
    for m in re_mp4.find_iter(html) {
        let url = unesc(m.as_str()).trim().to_string();
        if is_preview(&url) || !seen.insert(url.clone()) {
            continue;
        }
        mp4.push(url);
    }
    (hls, mp4)
}

fn cat_path(category_id: &str) -> &str {
    for (id, _, path) in CATS {
        if *id == category_id {
            return path;
        }
    }
    "/new/%d"
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name, _)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let path = cat_path(category_id).replace("%d", &page.to_string());
    let html = fetch_text(&format!("{HOST}{path}")).await?;
    let items = append_cards(&html, 60);
    // 与 Java 一致：满 12 条即认为还有下一页。
    let has_more = items.len() >= 12;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with('/') {
        format!("{HOST}{series_id}")
    } else {
        series_id.to_string()
    };
    if url.len() < 8 {
        return Err(ApiError::Internal("XVIDEOS 未返回视频资料".into()));
    }
    let html = fetch_text(&url).await?;
    let re_title = Regex::new("<title>([\\s\\S]*?)</title>").unwrap();
    let mut title = first(&re_title, &html);
    if let Some(pos) = title.find(" - ") {
        title = title[..pos].trim().to_string();
    }
    let title = unesc(&title);
    let re_og_img = Regex::new("property=\"og:image\"[^>]*content=\"([^\"]*)\"").unwrap();
    let cover = first(&re_og_img, &html);
    let re_og_desc = Regex::new("property=\"og:description\"[^>]*content=\"([^\"]*)\"").unwrap();
    let synopsis = unesc(&first(&re_og_desc, &html));
    let (hls, mp4) = streams(&html);
    if hls.is_empty() && mp4.is_empty() {
        return Err(ApiError::Internal("XVIDEOS 未返回可播放分集".into()));
    }
    let mut episodes: Vec<Value> = Vec::new();
    for u in &hls {
        episodes.push(episode_json(u, "XVIDEOS·HLS", series_id));
    }
    for u in &mp4 {
        episodes.push(episode_json(u, "XVIDEOS·MP4", series_id));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("XVIDEOS 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{HOST}/"), &[("k", query)]);
    let html = fetch_text(&url).await?;
    let items = append_cards(&html, 48);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn card_title_prefers_attr() {
        let seg = "<a href=\"/video.abc/title\" title=\"Nice Title\">x</a>";
        assert_eq!(card_title("/video.abc/title", seg), "Nice Title");
    }

    #[test]
    fn card_title_falls_back_to_slug() {
        assert_eq!(
            card_title("/video.abc/some_title_here", ""),
            "some title here"
        );
        assert_eq!(card_title("/video.abc/", ""), "XVIDEOS");
    }

    #[test]
    fn preview_filtered() {
        assert!(is_preview("https://x/preview-abc.m3u8"));
        assert!(is_preview("https://x/a_t.jpg"));
        assert!(!is_preview("https://x/master.m3u8"));
    }

    #[test]
    fn streams_split_groups() {
        let html =
            "a https://cdn/x/master.m3u8 b https://cdn/x/720.mp4 c https://cdn/x/master.m3u8";
        let (hls, mp4) = streams(html);
        assert_eq!(hls.len(), 1);
        assert_eq!(mp4.len(), 1);
        assert_eq!(hls[0], "https://cdn/x/master.m3u8");
    }

    #[test]
    fn unesc_entities() {
        assert_eq!(unesc("a\\/b\\u0026c&amp;d"), "a/b&c&d");
    }

    #[test]
    fn cat_path_default() {
        assert_eq!(cat_path("best"), "/best/%d");
        assert_eq!(cat_path("nope"), "/new/%d");
    }
}
