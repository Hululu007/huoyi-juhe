//! 7MMTV。
//!
//! 与 jar 的 Zaka7mmAmns 一一对应：分类（最新/有碼/無碼/
//! 中文字幕/素人自拍/去馬賽克）、目录（/ 与
//! /{类}_list/all/%d.html）、详情（h1 标题、JSON-LD 的
//! name/image/description/embedUrl/actor/genre；取流：
//! 详情页 JSON-LD 的 embedUrl（或 mvarr 播放框）→ embed 页
//! 解包 Dean Edwards 打包 JS → hls2/hls3/hls4 与页内
//! m3u8/txt 地址）、搜索（/searchall_search/all/{词}/{页}.html，
//! 第 1 页）、取流（直链透传）。
//! 注意：jar 的 detailContent 会并行探活各线路再排序，
//! 核心只按 jar 的 hls2/hls3/hls4 顺序回候选地址，不做
//! 探活排序；本机出口实测 hls2 回 403、hls3 全链可播
//! （主清单 200 → 变体 200 → 首分片 200）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://7mmtv.sx";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

const CATS: &[(&str, &str, &str)] = &[
    ("new", "最新", "/"),
    ("censored", "有碼AV", "/censored_list/all/%d.html"),
    ("uncensored", "無碼AV", "/uncensored_list/all/%d.html"),
    ("chinese", "中文字幕", "/chinese_list/all/%d.html"),
    ("amateurjav", "素人自拍", "/amateurjav_list/all/%d.html"),
    (
        "reducing-mosaic",
        "去馬賽克",
        "/reducing-mosaic_list/all/%d.html",
    ),
];

/// 与 Java 的 head 一致。
fn headers(referer: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        ("Accept-Language".to_string(), "en-US,en;q=0.9,zh-CN;q=0.8".to_string()),
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
        return Err(ApiError::Internal(format!("7MMTV 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 ZakaKvsAmns.unesc 一致。
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

/// 与 Java 的 u 一致：// 补 https:，/ 开头补站址。
fn abs_url(raw: &str) -> String {
    let s = unesc(raw).trim().to_string();
    if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = s.strip_prefix('/') {
        format!("{HOST}{rest}")
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

/// 与 Java 的 cardTitle 一致。
fn card_title(segment: &str) -> String {
    let re = Regex::new("<h3[^>]*video-title[^>]*>\\s*<a[^>]*>([^<]{1,300})</a>").unwrap();
    let t = unesc(&first(&re, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let re_alt = Regex::new("alt='([^']{2,200})'").unwrap();
    let t = unesc(&first(&re_alt, segment));
    if t.chars().count() > 1 {
        t
    } else {
        "7MMTV".to_string()
    }
}

/// 与 Java 的 pic 一致。
fn pic(segment: &str) -> String {
    let re = Regex::new("<img[^>]*(?:data-src|src)=['\"]([^'\"]+)['\"]").unwrap();
    let url = first(&re, segment);
    if url.is_empty() {
        String::new()
    } else {
        abs_url(&url)
    }
}

/// 与 Java 的 appendCards 一致。
fn append_cards(html: &str, limit: usize) -> Vec<Value> {
    if html.len() < 200 {
        return Vec::new();
    }
    let re_link = Regex::new(
        "href=['\"](https?://7mmtv\\.sx/[a-z]{2}/[a-z\\-]+_content/\\d+/[^'\"]+?\\.html)['\"]",
    )
    .unwrap();
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re_link.captures_iter(html) {
        if items.len() >= limit {
            break;
        }
        let m = cap.get(0).unwrap();
        let link = cap.get(1).map(|g| g.as_str()).unwrap_or("").to_string();
        if !seen.insert(link.clone()) {
            continue;
        }
        let end = (m.end() + 1500).min(html.len());
        let segment = &html[m.start()..end];
        let title = card_title(segment);
        let cover = pic(segment);
        items.push(item_json(&link, &title, &cover, "7MMTV"));
    }
    items
}

/// 与 Java 的 baseN 一致（36 进制字母表）。
fn base_n(mut n: usize, radix: usize) -> String {
    const ALPHA: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    if n == 0 {
        return "0".to_string();
    }
    let mut out = Vec::new();
    while n > 0 {
        out.push(ALPHA[n % radix] as char);
        n /= radix;
    }
    out.iter().rev().collect()
}

/// Dean Edwards 打包 JS 解包（与 jar 的 Zaka7mmAmns.unpackJs 同款算法）。
fn unpack_js(html: &str) -> String {
    let re = Regex::new(
        "eval\\(function\\(p,a,c,k,e,d\\)\\{[\\s\\S]{0,200}?\\}\\('([\\s\\S]*?)',(\\d+),(\\d+),'([\\s\\S]*?)'\\.split\\('\\|'\\)",
    )
    .unwrap();
    let Some(cap) = re.captures(html) else {
        return html.to_string();
    };
    let payload = cap.get(1).map(|m| m.as_str()).unwrap_or("");
    let radix: usize = cap
        .get(2)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(36);
    let count: usize = cap
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let words: Vec<&str> = cap
        .get(4)
        .map(|m| m.as_str())
        .unwrap_or("")
        .split('|')
        .collect();
    let mut dict: Vec<(String, String)> = Vec::new();
    for i in (0..count).rev() {
        if i < words.len() && !words[i].is_empty() {
            dict.push((base_n(i, radix), words[i].to_string()));
        }
    }
    let re_word = Regex::new("\\b\\w+\\b").unwrap();
    let out = re_word
        .replace_all(payload, |c: &regex::Captures| {
            let w = &c[0];
            dict.iter()
                .find(|(k, _)| k == w)
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| w.to_string())
        })
        .to_string();
    out.replace("\\'", "'").replace("\\/", "/")
}

/// 与 Java 的 streams 一致：embed 页解包后取 hls2/3/4 与页内地址。
async fn streams(embed_url: &str, referer: &str) -> Vec<String> {
    let Ok(html) = fetch_text(embed_url, referer).await else {
        return Vec::new();
    };
    let text = unpack_js(&html);
    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for key in ["hls2", "hls3", "hls4"] {
        let re = Regex::new(&format!("\"{key}\":\"([^\"]+)\"")).unwrap();
        let url = unesc(&first(&re, &text));
        if url.len() > 10 && url.starts_with("http") && seen.insert(url.clone()) {
            out.push(url);
        }
    }
    let re_any = Regex::new("https?://[^\"'\\s<>]+?\\.(?:m3u8|txt)[^\"'\\s<>]*").unwrap();
    for m in re_any.find_iter(&text) {
        let url = unesc(m.as_str());
        if url.len() > 10 && seen.insert(url.clone()) {
            out.push(url);
        }
    }
    out
}

fn category_template(category_id: &str) -> &str {
    for (id, _, tpl) in CATS {
        if *id == category_id {
            return tpl;
        }
    }
    "/"
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
    let re_h1 = Regex::new("<h1[^>]*>([\\s\\S]{1,300}?)</h1>").unwrap();
    let mut title = unesc(&first(&re_h1, &html));
    if title.is_empty() {
        let re_name = Regex::new("\"name\":\\s*\"([^\"]{2,300})\"").unwrap();
        title = unesc(&first(&re_name, &html));
    }
    let title = {
        let collapsed = Regex::new("\\s+")
            .unwrap()
            .replace_all(&title, " ")
            .trim()
            .to_string();
        if collapsed.is_empty() {
            "7MMTV 影片".to_string()
        } else {
            collapsed
        }
    };
    let re_image = Regex::new("\"image\":\\s*\"([^\"]+)\"").unwrap();
    let mut cover = abs_url(&first(&re_image, &html));
    if cover.is_empty() {
        let re_thumb = Regex::new("\"thumbnailUrl\":\\s*\"([^\"]+)\"").unwrap();
        cover = abs_url(&first(&re_thumb, &html));
    }
    if cover.is_empty() {
        cover = pic(&html);
    }
    let re_desc = Regex::new("\"description\":\\s*\"([^\"]{0,3000})\"").unwrap();
    let synopsis = unesc(&first(&re_desc, &html));
    let re_embed = Regex::new("\"(?:embedUrl|contentUrl)\":\\s*\"([^\"]+)\"").unwrap();
    let mut embed_url = unesc(&first(&re_embed, &html));
    if embed_url.is_empty() {
        let re_mv = Regex::new("'((?:https?:)?//[^']{4,200})'").unwrap();
        for cap in re_mv.captures_iter(&html) {
            let cand = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            if cand.contains("/v/") {
                embed_url = abs_url(cand);
                break;
            }
        }
    }
    let mut list: Vec<String> = Vec::new();
    if !embed_url.is_empty() {
        list = streams(&embed_url, &url).await;
    }
    if list.is_empty() {
        // 详情页本身也可能含打包 JS 或直链（jar 的 streams 回退）。
        let text = unpack_js(&html);
        let re_any =
            Regex::new("https?://[^\"'\\s<>]+?\\.(?:m3u8|txt)[^\"'\\s<>]*").unwrap();
        for m in re_any.find_iter(&text) {
            let u = unesc(m.as_str());
            if u.len() > 10 && !list.contains(&u) {
                list.push(u);
            }
        }
    }
    if list.is_empty() {
        return Err(ApiError::Internal("7MMTV 未返回可播放分集".into()));
    }
    let episodes: Vec<Value> = list
        .iter()
        .enumerate()
        .map(|(i, stream_url)| {
            let name = if i == 0 {
                "7MMTV·线1·正片".to_string()
            } else {
                format!("7MMTV·线{}·備用{}", i + 1, i)
            };
            episode_json(stream_url, &name, series_id)
        })
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
        Err(ApiError::Internal("7MMTV 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc: String = url::form_urlencoded::byte_serialize(query.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let url = format!("{HOST}/searchall_search/all/{enc}/1.html");
    let html = fetch_text(&url, &format!("{HOST}/")).await?;
    let items = append_cards(&html, 40);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_n_radix36() {
        assert_eq!(base_n(0, 36), "0");
        assert_eq!(base_n(35, 36), "z");
        assert_eq!(base_n(36, 36), "10");
    }

    #[test]
    fn unpack_js_replaces_words() {
        let packed = "eval(function(p,a,c,k,e,d){}('0 1 2',36,3,'a|b|c'.split('|')))";
        let out = unpack_js(packed);
        assert!(out.contains('a'));
        assert!(out.contains('b'));
        assert!(out.contains('c'));
    }

    #[test]
    fn category_template_lookup() {
        assert_eq!(
            category_template("censored"),
            "/censored_list/all/%d.html"
        );
        assert_eq!(category_template("nope"), "/");
    }
}
