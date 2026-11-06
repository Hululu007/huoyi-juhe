//! 伊人AV：核心里的影视区站点。
//!
//! 入口 yiren10.life/yiren 会跳转到实站 yiren234.cc（站内自称
//! YiRen. · Video library）。无登录、无付费墙。
//! - 分类 14 个子分类，与 /categories 页 1:1（站内名字为机翻
//!   英文，原样照写）：AI Shortplay、Wanderer.、I don't know.、
//!   AV explains.、JAV Blacks Temptation、Chinese subtitle for
//!   JAV、Cavalry crack.、Comics.、America and America、
//!   Domestic video、Japanese Codeless、Subtitles in Chinese、
//!   Japan has codes.、Chinese subtitles.。
//! - 目录：/latest?category=<id>，翻页加 &page=<n>，每页 15 条；
//!   卡片为 a.card，标题在 title 属性、封面在 img src、
//!   时长在 span.card-status。
//! - 详情：/video/<id>，页内 JSON-LD VideoObject 给标题、
//!   简介、封面 thumbnailUrl 与直链 contentUrl（m3u8，实测
//!   302556：lbpl26.com 主清单 200、变体清单 200、
//!   METHOD=NONE）；单集。
//! - 搜索：/search?q=<词>，实测“美女”15 条；搜索接口曾一
//!   次回 503“正在准备”，属间歇性，重试即通。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://yiren234.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：/categories 页子分类，站内顺序，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("14", "AI Shortplay"),
    ("13", "Wanderer."),
    ("12", "I don't know."),
    ("11", "AV explains."),
    ("10", "JAV Blacks Temptation"),
    ("9", "Chinese subtitle for JAV"),
    ("8", "Cavalry crack."),
    ("7", "Comics."),
    ("6", "America and America"),
    ("5", "Domestic video"),
    ("4", "Japanese Codeless"),
    ("3", "Subtitles in Chinese"),
    ("2", "Japan has codes."),
    ("1", "Chinese subtitles."),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("伊人AV请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("伊人AV返回空响应".into()));
    }
    Ok(text)
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 卡片解析：a.card 的 title 属性（标题）+ img src（封面）+
/// card-status（时长作备注）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="card" href="/video/(\d+)" title="([^"]+)">.*?<img src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let dur_re = Regex::new(r#"<span class="card-status">([^<]+)</span>"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[2].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[3].trim().to_string();
        let tail = &html[cap.get(0).map(|m| m.end()).unwrap_or(0)..];
        let window = tail.get(..2000).unwrap_or(tail);
        let remark = match &dur_re {
            Some(re) => re
                .captures(window)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 分类解析：/categories 页 /latest?category=<id> 锚点。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/latest\?category=(\d+)"[^>]*>([^<]{1,40})<"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = unescape(cap[2].trim());
        if name.is_empty() || name.starts_with("All videos") || !seen.insert(id.clone()) {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

/// 详情页 JSON-LD VideoObject：name/description/thumbnailUrl/contentUrl。
fn parse_video_object(html: &str) -> Option<Value> {
    let re = Regex::new(r#"(?s)<script type="application/ld\+json">(.*?)</script>"#).ok()?;
    for cap in re.captures_iter(html) {
        if let Ok(v) = serde_json::from_str::<Value>(&cap[1]) {
            if v.get("@type").and_then(|t| t.as_str()) == Some("VideoObject") {
                return Some(v);
            }
        }
    }
    None
}

fn text_of_value(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Array(a)) => a
            .first()
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .to_string(),
        _ => String::new(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/categories")).await {
        Ok(html) => {
            let list = parse_categories(&html);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = with_query(
        &format!("{BASE}/latest"),
        &[("category", category_id), ("page", &page.to_string())],
    );
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("category={}&amp;page={}", category_id, page + 1))
            || html.contains(&format!("category={}&page={}", category_id, page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/video/")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{BASE}/video/{id}")).await?;
    let Some(vo) = parse_video_object(&html) else {
        return Err(ApiError::Internal("伊人AV详情未返回视频信息".into()));
    };
    let title = text_of_value(&vo, "name");
    let cover = text_of_value(&vo, "thumbnailUrl");
    let stream = text_of_value(&vo, "contentUrl");
    if title.is_empty() || stream.is_empty() {
        return Err(ApiError::Internal("伊人AV未返回可播放地址".into()));
    }
    let synopsis = text_of_value(&vo, "description");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"keywords": text_of_value(&vo, "keywords")},
        "episodes": [episode_json(&stream, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("伊人AV该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("q", query)]);
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="card" href="/video/305270" title="ABF-382 Sexually controlled, perverted couples living together in a sex recorder of Sing village love."> <div class="art"> <img src="https://23.225.11.173:8443/video/m3u8/2026/10/27/8b63a2eb/vod.jpg" loading="lazy" decoding="async" referrerpolicy="no-referrer" alt="" width="480" height="300"> <span class="card-status">1:40:03</span> <span class="play" aria-hidden="true">"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "305270");
        assert!(items[0]["title"].as_str().unwrap().starts_with("ABF-382"));
        assert_eq!(
            items[0]["cover"],
            "https://23.225.11.173:8443/video/m3u8/2026/10/27/8b63a2eb/vod.jpg"
        );
        assert_eq!(items[0]["remark"], "1:40:03");
    }

    #[test]
    fn parse_categories_sample() {
        let html = r#"<a href="/latest?category=14">AI Shortplay</a><a href="/latest?category=13">Wanderer.</a><a href="/latest?category=1">All videos →</a><a href="/latest?category=14">AI Shortplay</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "14");
        assert_eq!(list[1]["name"], "Wanderer.");
    }

    #[test]
    fn fallback_has_14_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 14);
        assert_eq!(list[0]["name"], "AI Shortplay");
        assert_eq!(list[13]["id"], "1");
    }

    #[test]
    fn parse_video_object_real_sample() {
        let html = r#"<script type="application/ld+json"> { "@context": "https://schema.org", "@type": "VideoObject", "name": "Hiimetsu-Hairflower Comfort", "description": "Hiimetsu-Hairflower Comfort · Hiimetsu-Hairflower Comfort", "thumbnailUrl": [ "https://1028.lbp261028.top/20241211/yYhx20wc/1.jpg" ], "contentUrl": "https://lbpl26.com/20241211/yYhx20wc/index.m3u8", "embedUrl": "https://yiren234.cc/video/302556", "uploadDate": "2026-11-02T03:00:44+08:00", "keywords": "Hiimetsu, Dutch, The edge, Fun lingerie" } </script>"#;
        let vo = parse_video_object(html).unwrap();
        assert_eq!(text_of_value(&vo, "name"), "Hiimetsu-Hairflower Comfort");
        assert_eq!(
            text_of_value(&vo, "contentUrl"),
            "https://lbpl26.com/20241211/yYhx20wc/index.m3u8"
        );
        assert_eq!(
            text_of_value(&vo, "thumbnailUrl"),
            "https://1028.lbp261028.top/20241211/yYhx20wc/1.jpg"
        );
        assert!(text_of_value(&vo, "keywords").contains("Hiimetsu"));
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://lbpl26.com/20241211/yYhx20wc/index.m3u8").unwrap();
        assert_eq!(ok["url"], "https://lbpl26.com/20241211/yYhx20wc/index.m3u8");
        assert!(play_check("302556").is_err());
    }
}
