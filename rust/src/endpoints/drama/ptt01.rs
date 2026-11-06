//! PTT01：三级稀缺影视站。
//!
//! 与 jar 的 ZakaPttAmns 一一对应：分类（电影/电视剧/短剧/动漫/
//! 综艺/体育＋大陆/香港/台湾/日本/韩国）、目录（/p/{n}?page=%d
//! 或 /?category_id={n}&page=%d，卡片取 match 后 700 字符的
//! 片段解析）、详情（标题取 <title> 去尾缀、og 图或页内首图、
//! og 简介，<source> 多档 HLS，空则扫全页 m3u8）、搜索
//! （/node/search?title=，第 1 页）、取流（直链透传）。
//! 注意：jar 的 ZakaGate 在此 jar 里是空实现，直接请求即可；
//! 搜索端在本机出口实测回 503（疑似限流），实现按 jar 原文
//! 保留，手机侧需复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://ptt01.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATS: &[(&str, &str, &str)] = &[
    ("p1", "电影", "/p/1?page=%d"),
    ("p3", "电视剧", "/p/3?page=%d"),
    ("p66", "短剧", "/p/66?page=%d"),
    ("p4", "动漫", "/p/4?page=%d"),
    ("p2", "综艺", "/p/2?page=%d"),
    ("p53", "体育", "/p/53?page=%d"),
    ("r19", "大陆", "/?category_id=19&page=%d"),
    ("r20", "香港", "/?category_id=20&page=%d"),
    ("r81", "台湾", "/?category_id=81&page=%d"),
    ("r83", "日本", "/?category_id=83&page=%d"),
    ("r82", "韩国", "/?category_id=82&page=%d"),
];

/// 与 Java 的 head 一致。
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
            "zh-CN,zh;q=0.9,zh-Hant;q=0.8".to_string(),
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
        return Err(ApiError::Internal(format!("PTT01 请求 HTTP {status}")));
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

fn first(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

/// 与 Java 的 pic 一致：首个非 data:image、非 logo 的 http 图。
fn pic_of(segment: &str) -> String {
    let re = Regex::new("<img[^>]*src=\"([^\"]+)\"").unwrap();
    for cap in re.captures_iter(segment) {
        let url = abs_url(cap.get(1).map(|m| m.as_str()).unwrap_or(""));
        if url.contains("data:image") || url.contains("logo") || !url.starts_with("http") {
            continue;
        }
        return url;
    }
    String::new()
}

/// 与 Java 的 appendCards 一致：href="/{5-7 位数字}"，片段取 match 后 700 字符。
fn append_cards(html: &str, limit: usize) -> Vec<Value> {
    let re_link = Regex::new("href=\"/(\\d{5,7})\"").unwrap();
    let re_alt = Regex::new("<img[^>]*alt=\"([^\"]*)\"").unwrap();
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re_link.captures_iter(html) {
        if items.len() >= limit {
            break;
        }
        let id = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if id.is_empty() || !seen.insert(id.to_string()) {
            continue;
        }
        let start = cap.get(0).map(|m| m.start()).unwrap_or(0);
        let end = (cap.get(0).map(|m| m.end()).unwrap_or(0) + 700).min(html.len());
        let segment = &html[start..end];
        let title = unesc(&first(&re_alt, segment));
        let cover = pic_of(segment);
        items.push(item_json(&format!("{HOST}/{id}"), &title, &cover, "PTT01"));
    }
    items
}

/// 与 Java 的 streams 一致：先 <source>，空则扫全页 m3u8。
fn streams(html: &str) -> Vec<String> {
    let re_source = Regex::new("<source[^>]*src=\"([^\"]+)\"[^>]*>").unwrap();
    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re_source.captures_iter(html) {
        let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let url = unesc(raw).trim().to_string();
        if url.len() < 12 {
            continue;
        }
        let url = if let Some(rest) = url.strip_prefix("//") {
            format!("https://{rest}")
        } else if let Some(rest) = url.strip_prefix('/') {
            format!("{HOST}{rest}")
        } else {
            url
        };
        if !url.starts_with("http") || !seen.insert(url.clone()) {
            continue;
        }
        out.push(url);
    }
    if out.is_empty() {
        let re_m3u8 = Regex::new("https?://[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*").unwrap();
        for m in re_m3u8.find_iter(html) {
            let url = unesc(m.as_str()).trim().to_string();
            if seen.insert(url.clone()) {
                out.push(url);
            }
        }
    }
    out
}

fn cat_path(category_id: &str) -> &str {
    for (id, _, path) in CATS {
        if *id == category_id {
            return path;
        }
    }
    "/p/1?page=%d"
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
    let has_more = items.len() >= 12;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with('/') {
        format!("{HOST}{series_id}")
    } else if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{HOST}/{series_id}")
    };
    if url.len() < 6 {
        return Err(ApiError::Internal("PTT01 未返回视频资料".into()));
    }
    let html = fetch_text(&url).await?;
    let re_title = Regex::new("<title>([\\s\\S]*?)</title>").unwrap();
    let mut title = unesc(&first(&re_title, &html));
    if let Some(pos) = title.rfind(" - ") {
        if pos > 2 {
            title = title[..pos].trim().to_string();
        }
    }
    if title.is_empty() {
        title = "PTT01 影视".to_string();
    }
    let re_og_img = Regex::new("property=\"og:image\"[^>]*content=\"([^\"]*)\"").unwrap();
    let mut cover = first(&re_og_img, &html);
    if cover.is_empty() {
        // 与 Java 的 picPage 一致：页内首图，排除广告域名 71352.men。
        let re_img = Regex::new("<img[^>]*src=\"([^\"]+)\"").unwrap();
        for cap in re_img.captures_iter(&html) {
            let url = abs_url(cap.get(1).map(|m| m.as_str()).unwrap_or(""));
            if url.contains("71352.men") {
                continue;
            }
            cover = url;
            break;
        }
    }
    let re_og_desc = Regex::new("property=\"og:description\"[^>]*content=\"([^\"]*)\"").unwrap();
    let synopsis = unesc(&first(&re_og_desc, &html));
    let list = streams(&html);
    if list.is_empty() {
        return Err(ApiError::Internal("PTT01 未返回可播放分集".into()));
    }
    let episodes: Vec<Value> = list
        .iter()
        .map(|u| episode_json(u, "PTT01·HLS", series_id))
        .collect();
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
        Err(ApiError::Internal("PTT01 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{HOST}/node/search"),
        &[("title", query), ("page", "1")],
    );
    let html = fetch_text(&url).await?;
    let items = append_cards(&html, 48);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streams_prefers_source() {
        let html = "<video><source src=\"https://cdn/x/index.m3u8\" type=\"application/x-mpegURL\"></video> https://cdn/y/other.m3u8";
        let list = streams(html);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0], "https://cdn/x/index.m3u8");
    }

    #[test]
    fn streams_falls_back_to_scan() {
        let html = "watch https://cdn/y/other.m3u8 now";
        let list = streams(html);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0], "https://cdn/y/other.m3u8");
    }

    #[test]
    fn pic_skips_logo_and_data() {
        let seg = "<img src=\"https://x/logo.png\"><img src=\"https://x/a.avif\">";
        assert_eq!(pic_of(seg), "https://x/a.avif");
    }

    #[test]
    fn cat_path_default() {
        assert_eq!(cat_path("p66"), "/p/66?page=%d");
        assert_eq!(cat_path("r83"), "/?category_id=83&page=%d");
        assert_eq!(cat_path("nope"), "/p/1?page=%d");
    }
}
