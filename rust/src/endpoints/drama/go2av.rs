//! GO2AV。
//!
//! 与 jar 的 ZakaGo2avAmns 一一对应：分类（最新/中文字幕/
//! 有碼AV/無碼AV）、目录（/index.php 与 /a/{类}/list_{n}_%d.html）、
//! 详情（标题、og:image、两层 iframe：详情页 iframe →
//! av99 播放器页 → xvideos embedframe 的 setVideoHLS/High/Low）、
//! 搜索（/plus/search.php?mobile=1， 第 1 页）、取流（直链透传）。
//!
//! 两处按 2026-11-05 实测修过（jar 原文的解析已跟不上现站模板）：
//! ① 卡片标题：现站列表无 h3.am-list-item-hd，标题在
//! `<span class="title">` 与 img alt 里，改取这两处；
//! ② 详情标题：现站详情页无 h3.am-article-title，标题在
//! `<title>` 里，去掉末尾“_夠惡AV~免費A片”后缀。
//! 注意：页面是 UTF-8 但未声明 charset；搜索 /plus/search.php
//! 本机出口回 plain 403（Apache 直接拒绝），实现按 jar 原文
//! 保留，搜索须手机侧复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://go2av.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

const CATS: &[(&str, &str, &str)] = &[
    ("new", "最新", "/index.php"),
    ("ch", "中文字幕", "/a/ch/list_5_%d.html"),
    ("censored", "有碼AV", "/a/censored/list_6_%d.html"),
    ("uncensored", "無碼AV", "/a/uncensored/list_7_%d.html"),
];

/// 与 Java 的 head 一致。
fn headers(referer: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,*/*;q=0.8".to_string(),
        ),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
        ("Referer".to_string(), referer.to_string()),
    ]
}

async fn fetch_text(url: &str, referer: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers(referer) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("GO2AV 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 unesc 一致（jar 的 unesc 只做 \/ → /）。
fn unesc(raw: &str) -> String {
    raw.replace("\\/", "/")
}

fn abs_url(raw: &str) -> String {
    let s = unesc(raw).trim().to_string();
    if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = s.strip_prefix("./") {
        format!("{HOST}/{rest}")
    } else if let Some(rest) = s.strip_prefix('/') {
        format!("{HOST}{rest}")
    } else if s.starts_with("/m/") {
        format!("{HOST}{s}")
    } else {
        s
    }
}

fn first(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

fn strip_tags(raw: &str) -> String {
    let re = Regex::new("<[^>]+>").unwrap();
    re.replace_all(raw, "").trim().to_string()
}

/// 卡片标题（已修）：span.title → img alt → 链接 slug → GO2AV 影片。
fn card_title(segment: &str, link: &str) -> String {
    let re_span = Regex::new("<span class=\"title\">([^<]{1,200})</span>").unwrap();
    let t = unesc(&first(&re_span, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let re_alt = Regex::new("<img[^>]*alt=['\"]([^'\"]{1,200})['\"]").unwrap();
    let t = unesc(&first(&re_alt, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let slug = link
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .replace('-', " ");
    let slug = slug.trim().to_string();
    if slug.chars().count() > 1 {
        slug
    } else {
        "GO2AV 影片".to_string()
    }
}

/// 与 Java 的 pic 一致：首个非 favicon/logo 的 http 图。
fn pic(segment: &str) -> String {
    let re_img = Regex::new("<img[^>]*src=['\"]([^'\"]+)['\"]").unwrap();
    for cap in re_img.captures_iter(segment) {
        let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let url = abs_url(raw);
        if url.starts_with("http")
            && !url.contains("favicon")
            && !url.contains("logo")
        {
            return url;
        }
    }
    String::new()
}

/// 与 Java 的 appendCards 一致。
fn append_cards(html: &str, limit: usize) -> Vec<Value> {
    if html.len() < 200 {
        return Vec::new();
    }
    let re_link = Regex::new(
        "href=\"([^\"]*?(?:/a/|\\./a/)[a-z]+/\\d{8}/\\d+\\.html|/m/view\\.php\\?aid=\\d+)\"",
    )
    .unwrap();
    let re_date = Regex::new("日期：</b>\\s*(\\d{4}-\\d{2}-\\d{2})").unwrap();
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re_link.captures_iter(html) {
        if items.len() >= limit {
            break;
        }
        let m = cap.get(0).unwrap();
        let link = abs_url(cap.get(1).map(|g| g.as_str()).unwrap_or(""));
        if link.len() < 10 || !seen.insert(link.clone()) {
            continue;
        }
        let end = (m.end() + 1500).min(html.len());
        let segment = &html[m.start()..end];
        let title = card_title(segment, &link);
        let cover = pic(segment);
        let date = first(&re_date, segment);
        let remark = if date.is_empty() { "GO2AV".to_string() } else { date };
        items.push(item_json(&link, &title, &cover, &remark));
    }
    items
}

/// 与 Java 的 frame2 一致：取播放器页里的第二层 iframe，
/// 跳过 ad.php 广告框（命中 ad.php 且不含 ads 的才跳过）。
async fn frame2(first_frame_url: &str, referer: &str) -> ApiResult<String> {
    let html = fetch_text(first_frame_url, referer).await?;
    if html.len() < 100 {
        return Err(ApiError::Internal("GO2AV 播放器页为空".into()));
    }
    let re_iframe = Regex::new("<iframe[^>]*src=\"([^\"]+)\"").unwrap();
    for cap in re_iframe.captures_iter(&html) {
        let src = cap.get(1).map(|m| m.as_str()).unwrap_or("").trim();
        if src.contains("ad.php") && !src.contains("ads") {
            continue;
        }
        let url = abs_url(src);
        if url.starts_with("http") {
            return Ok(url);
        }
    }
    Err(ApiError::Internal("GO2AV 未找到第二层播放框".into()))
}

/// 与 Java 的 streamsOf 一致：取 setVideoHLS/High/Low，空则扫页内地址。
fn streams_of(html: &str) -> (String, String, String) {
    let re_hls = Regex::new("setVideoHLS\\('([^']+)'\\)").unwrap();
    let re_high = Regex::new("setVideoUrlHigh\\('([^']+)'\\)").unwrap();
    let re_low = Regex::new("setVideoUrlLow\\('([^']+)'\\)").unwrap();
    let mut hls = unesc(&first(&re_hls, html));
    let mut high = unesc(&first(&re_high, html));
    let mut low = unesc(&first(&re_low, html));
    if hls.is_empty() {
        let re_m3u8 = Regex::new("https?://[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*").unwrap();
        for m in re_m3u8.find_iter(html) {
            let url = unesc(m.as_str());
            if !url.to_lowercase().contains("preview") {
                hls = url;
                break;
            }
        }
    }
    if high.is_empty() && low.is_empty() {
        let re_mp4 = Regex::new("https?://[^\"'\\s<>]+?\\.mp4[^\"'\\s<>]*").unwrap();
        let mut found: Vec<String> = Vec::new();
        for m in re_mp4.find_iter(html) {
            let url = unesc(m.as_str());
            if !url.to_lowercase().contains("preview") && !found.contains(&url) {
                found.push(url);
            }
        }
        if !found.is_empty() {
            high = found[0].clone();
        }
        if found.len() > 1 {
            low = found[1].clone();
        }
    }
    (hls, high, low)
}

fn category_template(category_id: &str) -> &str {
    for (id, _, tpl) in CATS {
        if *id == category_id {
            return tpl;
        }
    }
    "/index.php"
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
    let tpl = category_template(category_id);
    let path = tpl.replace("%d", &page.to_string());
    let url = format!("{HOST}{path}");
    let html = fetch_text(&url, &format!("{HOST}/")).await?;
    let items = append_cards(&html, 60);
    let has_more = items.len() >= 12;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{HOST}/{rest}")
    } else {
        format!("{HOST}/{series_id}")
    };
    let html = fetch_text(&url, &format!("{HOST}/")).await?;
    // 详情标题（已修）：<title> 去“_夠惡AV~免費A片”后缀。
    let re_title_tag = Regex::new("<title>(.*?)</title>").unwrap();
    let mut title = unesc(&first(&re_title_tag, &html));
    if let Some(pos) = title.rfind("_夠惡AV") {
        title.truncate(pos);
    }
    let title = title.trim().to_string();
    let title = if title.is_empty() {
        "GO2AV 影片".to_string()
    } else {
        title
    };
    let re_og = Regex::new("<meta[^>]*property=\"og:image\"[^>]*content=\"([^\"]+)\"").unwrap();
    let cover = abs_url(&first(&re_og, &html));
    let re_iframe = Regex::new("<iframe[^>]*src=\"([^\"]+)\"").unwrap();
    let first_frame = first(&re_iframe, &html);
    if first_frame.is_empty() {
        return Err(ApiError::Internal("GO2AV 未找到播放框".into()));
    }
    let player_url = frame2(&abs_url(&first_frame), &url).await?;
    let player_html = fetch_text(&player_url, &url).await?;
    let (hls, high, low) = streams_of(&player_html);
    let mut episodes: Vec<Value> = Vec::new();
    if !hls.is_empty() {
        episodes.push(episode_json(&hls, "GO2AV·HLS·正片", series_id));
    }
    if !high.is_empty() {
        episodes.push(episode_json(&high, "GO2AV·MP4·高清MP4", series_id));
    }
    if !low.is_empty() {
        episodes.push(episode_json(&low, "GO2AV·MP4·低清MP4", series_id));
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("GO2AV 未返回可播放分集".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("GO2AV 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{HOST}/plus/search.php"),
        &[("mobile", "1"), ("kwtype", "0"), ("q", query), ("page", "1")],
    );
    let html = fetch_text(&url, &format!("{HOST}/")).await?;
    let items = append_cards(&html, 40);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streams_of_reads_setters() {
        let html = "setVideoHLS('https://x/hls.m3u8');setVideoUrlHigh('https://x/360.mp4');setVideoUrlLow('https://x/240.mp4');";
        let (hls, high, low) = streams_of(html);
        assert_eq!(hls, "https://x/hls.m3u8");
        assert_eq!(high, "https://x/360.mp4");
        assert_eq!(low, "https://x/240.mp4");
    }

    #[test]
    fn card_title_span_first() {
        let seg = "<a href=\"/a/ch/20261025/1.html\"><img src=\"https://x/p.jpg\" alt=\"ALT\"><span class=\"title\">SPAN TITLE</span></a>";
        assert_eq!(
            card_title(seg, "https://go2av.com/a/ch/20261025/1.html"),
            "SPAN TITLE"
        );
    }

    #[test]
    fn category_template_lookup() {
        assert_eq!(
            category_template("ch"),
            "/a/ch/list_5_%d.html"
        );
        assert_eq!(category_template("nope"), "/index.php");
    }
}
