//! 黄果AI短剧：核心里的影视区站点。
//!
//! 与已注册的黄果（huangguo.rs）不是同站：黄果是 API 型短剧站
//!（/api/videos，/video/<id>，分集制），本站是 tube 模板站
//!（/info/id/<n>，/play/id/<n>，单片制），域名与引擎全不同。
//! 入口 hgaidj.xyz/hhxx 跳转到实站 hgaidjzun.lol。站无导航分类，
//! 浏览靠首页热搜词 /hunt/<词>.html（首页共 65 个，实测于
//! 2026-11-05）；每页 30 条，翻页 /hunt/<词>/h/<n>.html。视频
//! /info/id/<n>，播放页 /play/id/<n> 里 playUrl 为 m3u8（主清单
//! 200、变体清单 200 METHOD=NONE、首分片 200）。搜索与分类同路
//! /hunt/<词>。站详情页响应极慢（约 40 秒），get_text 内重试 3 次、
//! 间隔 2 秒。写源照站原样写，不按站名/分类名/标题删任何内容
//!（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://hgaidjzun.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页热搜词里最常用的几项，实测于 2026-11-05。
const CATS: &[&str] = &[
    "国产视频",
    "每日最新",
    "国产自拍",
    "国产偷拍",
    "国产传媒",
    "日本无码",
    "日本有码",
    "中文字幕",
    "人妻熟女",
    "AV解说",
    "主播大秀",
    "网曝黑料",
];

/// 带重试的 GET：站间歇限流超时、详情页响应极慢，最多试 3 次，每次间隔 2 秒。
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
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄果AI短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 卡片解析：`<a href="/info/id/<n>">` + img src（封面）+
/// `<p class="video-title">` 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/info/id/(\d+)"[^>]*>\s*<img src="([^"]+)"[^>]*>\s*<p class="video-title">(.*?)</p>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[2].trim().to_string();
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页热搜词 /hunt/<词>.html 锚点，按站内顺序、词去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/hunt/([^"/]+)\.html"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || !seen.insert(id.clone()) {
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
            .map(|name| category_json(name, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(BASE).await {
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
    let url = if page <= 1 {
        format!("{BASE}/hunt/{category_id}.html")
    } else {
        format!("{BASE}/hunt/{category_id}/h/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more =
        !items.is_empty() && html.contains(&format!("/hunt/{category_id}/h/{}.html", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 `playUrl = '...m3u8'`。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"playUrl\s*=\s*'([^']+)'"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => cap[1].trim().to_string(),
        None => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id.strip_prefix("info/id/").unwrap_or(id);
    let id = id.strip_suffix(".html").unwrap_or(id);
    let url = format!("{BASE}/info/id/{id}");
    let html = get_text(&url).await?;
    let title_re = Regex::new(r"<title>(.*?)</title>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = title.find("-黄果AI短剧") {
        title = title[..pos].to_string();
    }
    let cover_re = Regex::new(r#"<img[^>]*src="(https?://[^"]+/upload/vod/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
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
    let play_url = format!("{BASE}/play/id/{id}");
    let play_html = get_text(&play_url).await?;
    let m3u8 = parse_play_url(&play_html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("黄果AI短剧未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("黄果AI短剧该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/hunt/{query}");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="video-item"><a href="/info/id/2840894" target="_blank" title="[フェアリーダスト] くりいむレモン PART 30"><img src="https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg" alt="[フェアリーダスト] くりいむレモン PART 30" loading="lazy"><p class="video-title">[フェアリーダスト] くりいむレモン PART 30</p></a></div><div class="video-item"><a href="/info/id/2840894" target="_blank" title="重复"><img src="https://pic.heiimg.com/x.jpg" loading="lazy"><p class="video-title">重复卡片</p></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2840894");
        assert_eq!(
            items[0]["title"],
            "[フェアリーダスト] くりいむレモン PART 30"
        );
        assert_eq!(
            items[0]["cover"],
            "https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/hunt/国产视频.html">国产视频</a><a href="/hunt/每日最新.html">每日最新</a><a href="/hunt/国产视频.html">国产视频</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "国产视频");
        assert_eq!(list[1]["name"], "每日最新");
    }

    #[test]
    fn fallback_has_12_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 12);
        assert_eq!(list[0]["id"], "国产视频");
        assert_eq!(list[11]["name"], "网曝黑料");
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#"var playUrl = 'https://ckbhm3u8.com/20250930/Pw8bcXFF/index.m3u8';var playUrl = 'https://ckbhm3u8.com/20250930/Pw8bcXFF/index.m3u8';"#;
        assert_eq!(
            parse_play_url(html),
            "https://ckbhm3u8.com/20250930/Pw8bcXFF/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn title_suffix_strip() {
        let mut title =
            "内射传媒大学吴嘉宜，情侣性爱视4频-黄果AI短剧-加入时间:2025-12-06 17:55:30-详情页"
                .to_string();
        if let Some(pos) = title.find("-黄果AI短剧") {
            title = title[..pos].to_string();
        }
        assert_eq!(title, "内射传媒大学吴嘉宜，情侣性爱视4频");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://ckbhm3u8.com/20250930/Pw8bcXFF/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://ckbhm3u8.com/20250930/Pw8bcXFF/index.m3u8"
        );
        assert!(play_check("2582975").is_err());
    }

    #[test]
    fn unescape_entities() {
        assert_eq!(unescape("a &amp; b &#39;c&#39;"), "a & b 'c'");
    }
}
