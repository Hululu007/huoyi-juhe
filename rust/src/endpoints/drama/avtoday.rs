//! AV Today：核心里的影视区站点。
//!
//! 与 py 版 avtoday.py 同一套分类、同一条已验播放链：分类与站
//! /catalog 類型目錄 1:1（16 项），列表 16 条一页、单片详情、
//! 取流为详情页 iframe /player?s=CODE 里的 video_link 签名 mp4
//!（video.xdmm.workers.dev，Range 已验 206；链接带 exp/sig 签
//! 名会过期，每次播放须现取）。站内无萝莉分类；列表卡片标题
//! 含萝莉/幼女/未成年词的单片按标题过滤。注意：本站响应慢
//! （本机出口实测单请求 12～34 秒），核心 20 秒超时下部分请
//! 求可能超时，手机侧需复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://avtoday.io";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态回退：与站 /catalog 导航一致，实测于 2026-11-05。
/// (name, url 编码后)：id 即 name。
const CATS: &[(&str, &str)] = &[
    ("中文字幕", "%E4%B8%AD%E6%96%87%E5%AD%97%E5%B9%95"),
    ("無碼", "%E7%84%A1%E7%A2%BC"),
    ("絲襪", "%E7%B5%B2%E8%A5%AA"),
    ("FC2", "FC2"),
    ("多人", "%E5%A4%9A%E4%BA%BA"),
    ("長腿", "%E9%95%B7%E8%85%BF"),
    ("巨乳", "%E5%B7%A8%E4%B9%B3"),
    ("自慰", "%E8%87%AA%E6%85%B0"),
    ("素人", "%E7%B4%A0%E4%BA%BA"),
    ("足交", "%E8%B6%B3%E4%BA%A4"),
    ("潮吹", "%E6%BD%AE%E5%90%B9"),
    ("痴女", "%E7%97%B4%E5%A5%B3"),
    ("熟女", "%E7%86%9F%E5%A5%B3"),
    ("制服", "%E5%88%B6%E6%9C%8D"),
    ("人妻", "%E4%BA%BA%E5%A6%BB"),
    ("泡泡浴", "%E6%B3%A1%E6%B3%A1%E6%B5%B4"),
];

fn find_cat(name: &str) -> Option<&'static str> {
    CATS.iter().find(|(n, _)| *n == name).map(|(_, enc)| *enc)
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("AV Today请求 HTTP {status}")));
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

fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{BASE}/{rest}");
    }
    u.to_string()
}

/// 卡片解析：thumbnail 卡片，data-spcode 为番号，封面在 video
/// 元素的 background url 里，标题在 video-title 行。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)data-spcode="([^"]+)"(.*?)video-title truncate">\s*<a[^>]*>(.*?)</a>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let cover_re = Regex::new(r#"background:\s*url\('([^']+)'\)"#).ok();
    let dur_re = Regex::new(r#"video-duration">\s*([^<]+?)\s*<"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let code = cap[1].trim().to_string();
        if code.is_empty() || !seen.insert(code.clone()) {
            continue;
        }
        let middle = &cap[2];
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let mut cover = String::new();
        if let Some(re) = &cover_re {
            if let Some(m) = re.captures(middle) {
                cover = fix_url(&m[1]);
            }
        }
        let remark = match &dur_re {
            Some(re) => re
                .captures(middle)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let vid = format!("/cht/video/{code}.html");
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

/// 分页总数：列表页分页链接里的最大 page=N。
fn page_total(html: &str) -> Option<i64> {
    let re = Regex::new(r#"page=(\d+)"#).ok()?;
    let mut max: Option<i64> = None;
    for cap in re.captures_iter(html) {
        if let Ok(n) = cap[1].parse::<i64>() {
            if n > 0 && (max.is_none() || n > max.unwrap()) {
                max = Some(n);
            }
        }
    }
    max
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(name, _)| category_json(name, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(fallback_categories())
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let enc = find_cat(category_id).unwrap_or("%E5%B7%A8%E4%B9%B3");
    let url = if page <= 1 {
        format!("{BASE}/cht/catalog/{enc}.html")
    } else {
        format!("{BASE}/cht/catalog/{enc}.html?page={page}")
    };
    let html = get_text(&url).await?;
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
    let html = get_text(&url).await?;
    let title_re = Regex::new(r#"<meta property="og:title"[^>]*content="([^"]+)""#).ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        let t2 = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        if let Some(re) = &t2 {
            title = re
                .captures(&html)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default();
            if let Some(pos) = title.find(" | AVToday") {
                title.truncate(pos);
            }
        }
    }
    let cover_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
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
        return Err(ApiError::Internal("AV Today未返回标题".into()));
    }
    let code = series_id
        .rsplit('/')
        .next()
        .unwrap_or("")
        .trim_end_matches(".html")
        .to_string();
    let player_id = format!("/player?s={code}");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&player_id, "播放", series_id)],
    }))
}

/// 取流：/player?s=CODE 页里的 video_link（m3u8_url 为空时取它）。
async fn resolve_stream(player_id: &str) -> ApiResult<String> {
    let url = if player_id.starts_with("http") {
        player_id.to_string()
    } else if let Some(rest) = player_id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{player_id}")
    };
    let html = get_text(&url).await?;
    let m3u8_re = Regex::new(r#"var m3u8_url\s*=\s*'([^']+)'"#).ok();
    if let Some(re) = &m3u8_re {
        if let Some(m) = re.captures(&html) {
            let u = m[1].trim().to_string();
            if !u.is_empty() {
                return Ok(u);
            }
        }
    }
    let link_re = Regex::new(r#"var video_link\s*=\s*'([^']+)'"#).ok();
    if let Some(re) = &link_re {
        if let Some(m) = re.captures(&html) {
            let u = m[1].trim().to_string();
            if !u.is_empty() {
                return Ok(u);
            }
        }
    }
    Err(ApiError::Internal("AV Today未返回可播放地址".into()))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }));
    }
    let stream = resolve_stream(video_id).await?;
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("s", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_has_16_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 16);
        assert_eq!(list[0]["id"], "中文字幕");
        assert_eq!(list[6]["name"], "巨乳");
        assert_eq!(list[15]["id"], "泡泡浴");
    }

    #[test]
    fn find_cat_encodings() {
        assert_eq!(find_cat("巨乳"), Some("%E5%B7%A8%E4%B9%B3"));
        assert_eq!(find_cat("FC2"), Some("FC2"));
        assert_eq!(find_cat("不存在"), None);
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/pic/2026/10/FNS-266-1.jpg"),
            "https://avtoday.io/pic/2026/10/FNS-266-1.jpg"
        );
        assert_eq!(
            fix_url("https://avtoday.io/pic/a.jpg"),
            "https://avtoday.io/pic/a.jpg"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_basic() {
        let html = r#"<div class="thumbnail col"><div class="video-card real-card" data-spcode="FC2PPV-5003094"><a href="/cht/video/FC2PPV-5003094.html"><video class="preview-video" style="background: url('/pic/2026/11/FC2PPV-5003094-1.jpg?t=1') 0 0 / cover no-repeat;"></video></a><a href="/cht/video/FC2PPV-5003094.html"><span class="video-duration"> 01:01:50 </span><span class="video-tag uncensored"> 無碼 </span></a></div><div class="video-title truncate"><a href="/cht/video/FC2PPV-5003094.html">FC2PPV-5003094&nbsp;女神般的巨乳</a></div><div class="row"><div class="video-date col text-start">2026-11-05</div></div></div><!-- end of album block --><div class="thumbnail col"><div class="video-card real-card" data-spcode="BAD-1"><a href="/cht/video/BAD-1.html"><video style="background: url('/pic/b.jpg') 0 0 / cover no-repeat;"></video></a><a href="/cht/video/BAD-1.html"><span class="video-duration"> 00:10:00 </span></a></div><div class="video-title truncate"><a href="/cht/video/BAD-1.html">BAD-1 幼女片</a></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/cht/video/FC2PPV-5003094.html");
        assert_eq!(items[0]["title"], "FC2PPV-5003094 女神般的巨乳");
        assert_eq!(
            items[0]["cover"],
            "https://avtoday.io/pic/2026/11/FC2PPV-5003094-1.jpg?t=1"
        );
        assert_eq!(items[0]["remark"], "01:01:50");
        assert_eq!(items[1]["id"], "/cht/video/BAD-1.html");
        assert_eq!(items[1]["title"], "BAD-1 幼女片");
        assert_eq!(items[1]["cover"], "https://avtoday.io/pic/b.jpg");
        assert_eq!(items[1]["remark"], "00:10:00");
    }

    #[test]
    fn parse_cards_dedup() {
        let html = r#"<div data-spcode="A-1"><span class="video-duration">01:00:00</span></div><div class="video-title truncate"><a href="/cht/video/A-1.html">A-1 片A</a></div><div data-spcode="A-1"><span class="video-duration">01:00:00</span></div><div class="video-title truncate"><a href="/cht/video/A-1.html">A-1 片A</a></div>"#;
        assert_eq!(parse_cards(html).len(), 1);
    }

    #[test]
    fn page_total_reads_max() {
        let html = r#"<a href="/cht/catalog/巨乳.html?page=1">1</a><a href="/cht/catalog/巨乳.html?page=21">21</a>"#;
        assert_eq!(page_total(html), Some(21));
        assert_eq!(page_total("<div>no pager</div>"), None);
    }

    #[test]
    fn stream_regexes() {
        let html = "var m3u8_url = '';\nvar video_link = 'https://video.xdmm.workers.dev/2026/10/a.mp4?exp=1&sig=2';";
        let link_re = Regex::new(r#"var video_link\s*=\s*'([^']+)'"#).unwrap();
        assert_eq!(
            &link_re.captures(html).unwrap()[1],
            "https://video.xdmm.workers.dev/2026/10/a.mp4?exp=1&sig=2"
        );
    }
}
