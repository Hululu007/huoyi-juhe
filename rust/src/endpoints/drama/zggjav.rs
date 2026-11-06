//! GGJAV。
//!
//! 与 jar 的 ZakaGgjavAmns 一一对应：分类（最新＋有碼/無碼/
//! 中文字幕/素人自拍/歐美/H漫畫）、目录（/main/{类}?order=
//! recommended&page=）、详情（<title>、meta description、
//! large_ 海报；取流：详情页 var l 混淆线路表 base64 解码后
//! 每字节减 88 得 JSON，主线路 ggjav 的 embed 页取 videoSrc
//! 直给 m3u8；其余线路走 mv 页解包取 hls）、搜索
//! （/main/search?string=，第 1 页）、取流（直链透传；
//! embed 标识的集在 play 里再走一次 fromEmbed 解析）。
//! 注意：线路 URL 里可能含空格，返回前把空格编成 %20。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://ggjav.com";
const CDN_LARGE: &str = "https://cdn-1.ggjav.com/media/video/large_";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

const CATS: &[(&str, &str, &str)] = &[
    ("new", "最新", "/"),
    (
        "censored",
        "有碼AV",
        "/main/censored?order=recommended&page=%d",
    ),
    (
        "uncensored",
        "無碼AV",
        "/main/uncensored?order=recommended&page=%d",
    ),
    (
        "chinese",
        "中文字幕",
        "/main/chinese?order=recommended&page=%d",
    ),
    (
        "amateur",
        "素人自拍",
        "/main/amateur?order=recommended&page=%d",
    ),
    ("europe", "歐美", "/main/europe?order=recommended&page=%d"),
    (
        "cartoon",
        "H漫畫",
        "/main/cartoon?order=recommended&page=%d",
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
        (
            "Accept-Language".to_string(),
            "zh-TW,zh;q=0.9,en;q=0.8".to_string(),
        ),
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
        return Err(ApiError::Internal(format!("GGJAV 请求 HTTP {status}")));
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

/// 与 Java 的 u/abs 一致：// 补 https:，/ 开头补站址。
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

/// 流地址里的空格编成 %20（站方地址本身含空格，裸空格进不了 URL）。
fn encode_stream_url(url: &str) -> String {
    url.replace(' ', "%20")
}

fn first(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

/// 与 Java 的 decodeLines 一致：base64 解码，每字节减 88。
fn decode_lines(raw: &str) -> String {
    use base64::Engine;
    if raw.len() < 20 {
        return String::new();
    }
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(raw) else {
        return String::new();
    };
    if bytes.is_empty() {
        return String::new();
    }
    let shifted: Vec<u8> = bytes.iter().map(|b| b.wrapping_sub(88)).collect();
    String::from_utf8_lossy(&shifted).to_string()
}

/// 与 Java 的 cardTitle 一致：item_title → img alt → GGJAV。
fn card_title(segment: &str) -> String {
    let re_title =
        Regex::new("<div[^>]*class=[\"']item_title[\"'][^>]*>\\s*<a[^>]*>([^<]{1,300})</a>")
            .unwrap();
    let t = unesc(&first(&re_title, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let re_alt = Regex::new("alt=[\"']([^\"']{2,200})[\"']").unwrap();
    let t = unesc(&first(&re_alt, segment));
    if t.chars().count() > 1 {
        t
    } else {
        "GGJAV".to_string()
    }
}

/// 与 Java 的 pic 一致：item_image 图优先，再取通用 img src。
fn pic(segment: &str) -> String {
    let re_img = Regex::new(
        "<img[^>]*?\\sclass=[\"'][^\"']*item_image[^\"']*[\"'][^>]*?\\ssrc=[\"']([^\"']+)[\"']",
    )
    .unwrap();
    let mut url = first(&re_img, segment);
    if url.is_empty() {
        let re_img2 = Regex::new("<img[^>]*?\\ssrc=[\"']([^\"']+)[\"']").unwrap();
        url = first(&re_img2, segment);
    }
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
    let re_link = Regex::new("href=[\"'](/main/video\\?id=\\d+)[\"']").unwrap();
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re_link.captures_iter(html) {
        if items.len() >= limit {
            break;
        }
        let m = cap.get(0).unwrap();
        let link = format!("{HOST}{}", cap.get(1).map(|g| g.as_str()).unwrap_or(""));
        if !seen.insert(link.clone()) {
            continue;
        }
        let end = (m.end() + 1500).min(html.len());
        let segment = &html[m.start()..end];
        let title = card_title(segment);
        let cover = pic(segment);
        items.push(item_json(&link, &title, &cover, "GGJAV"));
    }
    items
}

/// 与 Java 的 arrFirst 一致：取 JSON 对象某键数组的首个元素。
fn arr_first(obj: &Value, key: &str) -> String {
    obj.get(key)
        .and_then(|v| v.as_array())
        .and_then(|a| a.first())
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

/// 与 Java 的 fromEmbed 一致：取 embed 页的 videoSrc，空则扫页内 m3u8。
async fn from_embed(embed_url: &str) -> String {
    let Ok(html) = fetch_text(embed_url, embed_url).await else {
        return String::new();
    };
    if html.len() <= 200 {
        return String::new();
    }
    let re_vsrc = Regex::new("var\\s+videoSrc\\s*=\\s*\"([^\"]+)\"").unwrap();
    let url = first(&re_vsrc, &html);
    if url.len() > 10 {
        return url;
    }
    let re_m3u8 = Regex::new("https?://[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*").unwrap();
    re_m3u8
        .find(&html)
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

/// Dean Edwards 打包 JS 解包（与 jar 的 Zaka7mmAmns.unpackJs 同款算法）。
fn unpack_js(html: &str) -> String {
    let re = Regex::new(
        "\\}\\(('(?:[^'\\\\]|\\\\.)*'|\"(?:[^\"\\\\]|\\\\.)*\"),(\\d+),(\\d+),('(?:[^'\\\\]|\\\\.)*'|\"(?:[^\"\\\\]|\\\\.)*\")\\.split\\('\\|'\\)",
    )
    .unwrap();
    let Some(cap) = re.captures(html) else {
        return html.to_string();
    };
    let payload = unquote_js_string(cap.get(1).map(|m| m.as_str()).unwrap_or(""));
    let radix: u32 = cap
        .get(2)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(36);
    let count: usize = cap
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let words_raw = unquote_js_string(cap.get(4).map(|m| m.as_str()).unwrap_or(""));
    let words: Vec<&str> = words_raw.split('|').collect();
    let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let encode_base = |mut n: usize| -> String {
        if n == 0 {
            return "0".to_string();
        }
        let mut out = Vec::new();
        let base = radix as usize;
        while n > 0 {
            out.push(alphabet[n % base] as char);
            n /= base;
        }
        out.iter().rev().collect()
    };
    let mut dict: Vec<(String, String)> = Vec::new();
    for i in (0..count).rev() {
        if i < words.len() && !words[i].is_empty() {
            dict.push((encode_base(i), words[i].to_string()));
        }
    }
    let re_word = Regex::new("\\b\\w+\\b").unwrap();
    re_word
        .replace_all(&payload, |c: &regex::Captures| {
            let w = &c[0];
            dict.iter()
                .find(|(k, _)| k == w)
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| w.to_string())
        })
        .to_string()
}

fn unquote_js_string(raw: &str) -> String {
    let s = raw.trim();
    let s = s
        .strip_prefix('\'')
        .or_else(|| s.strip_prefix('"'))
        .unwrap_or(s);
    let s = s
        .strip_suffix('\'')
        .or_else(|| s.strip_suffix('"'))
        .unwrap_or(s);
    s.replace("\\'", "'")
        .replace("\\\"", "\"")
        .replace("\\\\", "\\")
}

/// 与 Java 的 fromMv 一致：取 mv 页，解包后取 hls2/3/4，空则扫 m3u8。
async fn from_mv(url: &str) -> String {
    let Ok(html) = fetch_text(url, url).await else {
        return String::new();
    };
    if html.len() <= 300 {
        return String::new();
    }
    let unpacked = unpack_js(&html);
    let text = if unpacked.len() > 100 { unpacked } else { html };
    let re_hls = Regex::new("\"hls[234]?\":\"([^\"]+)\"").unwrap();
    let url = unesc(&first(&re_hls, &text));
    if !url.is_empty() {
        return url;
    }
    let re_m3u8 = Regex::new("https?://[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*").unwrap();
    re_m3u8
        .find(&text)
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

/// 与 Java 的 streams 一致：返回 7 个槽位里的可用地址（按槽位顺序）。
async fn streams(html: &str) -> Vec<String> {
    let re_l = Regex::new("var\\s+l\\s*=\\s*\"([A-Za-z0-9+/=]{40,})\"").unwrap();
    let decoded = decode_lines(&first(&re_l, html));
    let obj: Value = if decoded.len() > 10 {
        serde_json::from_str(&decoded).unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    let ggjav_first = arr_first(&obj, "ggjav");
    let mut main_list: Vec<String> = Vec::new();
    let mut mm_list: Vec<String> = Vec::new();
    if let Some(map) = obj.as_object() {
        for (key, _) in map {
            if key == "ggjav" {
                continue;
            }
            let v = arr_first(&obj, key);
            if v.len() < 12 || v.starts_with("http") {
                continue;
            }
            if key.starts_with("mm") {
                if !mm_list.contains(&v) {
                    mm_list.push(v);
                }
            } else if !main_list.contains(&v) {
                main_list.push(v);
            }
        }
    }
    // 槽位：0 主线路、1 回退、2 原 embed 地址、3 主列表首条、
    // 4/5 解包后的其余线路、6 备用空位（与 jar 的 7 槽一致）。
    let mut slots: Vec<String> = vec![String::new(); 7];
    slots[2] = ggjav_first.clone();
    slots[3] = main_list.first().cloned().unwrap_or_default();
    if ggjav_first.len() > 10 {
        slots[0] = from_embed(&ggjav_first).await;
    }
    let mut slot_idx = 4_usize;
    for item in main_list.iter().take(2).chain(mm_list.iter()) {
        if slot_idx >= 6 {
            break;
        }
        let resolved = from_mv(item).await;
        if resolved.len() > 10 && resolved != slots[0] && !slots.contains(&resolved) {
            slots[slot_idx] = resolved;
            slot_idx += 1;
        }
    }
    if slots[1].len() < 10 {
        slots[1] = slots[4].clone();
    }
    if slots[0].len() < 10 && slots[1].len() > 10 {
        slots[0] = slots[1].clone();
        slots[1] = String::new();
    }
    let mut out: Vec<String> = Vec::new();
    for url in slots {
        if url.len() > 10 && url.starts_with("http") && !out.contains(&url) {
            out.push(encode_stream_url(&url));
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
    } else if series_id.chars().all(|c| c.is_ascii_digit()) {
        format!("{HOST}/main/video?id={series_id}")
    } else {
        format!("{HOST}/{series_id}")
    };
    let html = fetch_text(&url, &format!("{HOST}/")).await?;
    let re_h1 = Regex::new("<h1[^>]*>([\\s\\S]{1,300}?)</h1>").unwrap();
    let mut title = unesc(&first(&re_h1, &html));
    if title.is_empty() {
        let re_title = Regex::new("<title>([^<]{1,200})</title>").unwrap();
        title = unesc(&first(&re_title, &html));
    }
    let title = {
        let collapsed = Regex::new("\\s+")
            .unwrap()
            .replace_all(&title, " ")
            .trim()
            .to_string();
        if collapsed.is_empty() {
            "GGJAV 影片".to_string()
        } else {
            collapsed
        }
    };
    let re_large = Regex::new("large_(\\d+)\\.jpg").unwrap();
    let mut cover = first(&re_large, &html);
    if !cover.is_empty() {
        cover = format!("{CDN_LARGE}{cover}.jpg");
    } else {
        let re_poster = Regex::new("poster=([^&\"']+large[^&\"']*\\.jpg)").unwrap();
        cover = abs_url(&first(&re_poster, &html));
        if cover.is_empty() {
            cover = pic(&html);
        }
    }
    let re_desc =
        Regex::new("<meta[^>]*name=[\"']description[\"'][^>]*content=[\"']([^\"']{0,2000})[\"']")
            .unwrap();
    let synopsis = unesc(&first(&re_desc, &html));
    let list = streams(&html).await;
    if list.is_empty() {
        return Err(ApiError::Internal("GGJAV 未返回可播放分集".into()));
    }
    let episodes: Vec<Value> = list
        .iter()
        .enumerate()
        .map(|(i, url)| {
            let name = if i == 0 {
                "GGJAV·HLS主·正片".to_string()
            } else {
                format!("GGJAV·HLS备{i}·備用{i}")
            };
            episode_json(url, &name, series_id)
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
    if video_id.contains("/main/embed?") {
        let resolved = from_embed(video_id).await;
        if resolved.len() > 10 {
            return Ok(json!({"url": encode_stream_url(&resolved)}));
        }
        return Err(ApiError::Internal("GGJAV 未取到播放地址".into()));
    }
    if video_id.contains("/main/video?id=") {
        let html = fetch_text(video_id, &format!("{HOST}/")).await?;
        let list = streams(&html).await;
        if let Some(first) = list.first() {
            return Ok(json!({"url": first}));
        }
        return Err(ApiError::Internal("GGJAV 未取到播放地址".into()));
    }
    if video_id.starts_with("http") {
        Ok(json!({"url": encode_stream_url(video_id)}))
    } else {
        Err(ApiError::Internal("GGJAV 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{HOST}/main/search"),
        &[("string", query), ("page", "1")],
    );
    let html = fetch_text(&url, &format!("{HOST}/")).await?;
    let items = append_cards(&html, 60);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_lines_subtracts_88() {
        use base64::Engine;
        let plain = "{\"ggjav\": [\"https://x/e\"]}";
        let encoded: Vec<u8> = plain.bytes().map(|b| b.wrapping_add(88)).collect();
        let b64 = base64::engine::general_purpose::STANDARD.encode(encoded);
        assert_eq!(decode_lines(&b64), plain);
        assert_eq!(decode_lines("short"), "");
    }

    #[test]
    fn encode_stream_url_spaces() {
        assert_eq!(
            encode_stream_url("https://x/a b.mp4/index.m3u8"),
            "https://x/a%20b.mp4/index.m3u8"
        );
    }

    #[test]
    fn category_template_lookup() {
        assert_eq!(
            category_template("censored"),
            "/main/censored?order=recommended&page=%d"
        );
        assert_eq!(category_template("nope"), "/");
    }
}
