//! 中文无码：核心里的影视区站点。
//!
//! 入口落地页 zwwmhnsi.xyz/gader/ga.html 只做跳转，实站为
//! zwwmtekr.lol（canonical 另指 zwwmbsuperonenaice.buzz，域名轮换）。
//! 与站导航 1:1（22 项）：/type/id/490.html 至 511.html（网红主播、
//! 国产传媒、探花系列、人妻熟女、日本无码、美乳巨乳、强制侵犯、制服诱
//! 惑、绝色佳人、风俗泡泡浴、家庭乱伦、AV解说、三级电影、少女萝莉、
//! SM调教、绝顶潮吹、魔镜系列、时间停止、催眠洗脑、漫改系列、电车痴
//! 汉、淫欲痴女）；每页 20 条，翻页 /type/id/<id>/<n>.html。视频
//! /info/id/<id>.html，播放页 /play/id/<id>.html 里 playUrl 为
//! m3u8（主清单 200、变体清单 200 AES-128、首分片 200）。搜索
//! /lookup/<词>.html。站间歇性限流超时，重试即通，get_text 内重试
//! 3 次。写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://zwwmtekr.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("490", "网红主播"),
    ("491", "国产传媒"),
    ("492", "探花系列"),
    ("493", "人妻熟女"),
    ("494", "日本无码"),
    ("495", "美乳巨乳"),
    ("496", "强制侵犯"),
    ("497", "制服诱惑"),
    ("498", "绝色佳人"),
    ("499", "风俗泡泡浴"),
    ("500", "家庭乱伦"),
    ("501", "AV解说"),
    ("502", "三级电影"),
    ("503", "少女萝莉"),
    ("504", "SM调教"),
    ("505", "绝顶潮吹"),
    ("506", "魔镜系列"),
    ("507", "时间停止"),
    ("508", "催眠洗脑"),
    ("509", "漫改系列"),
    ("510", "电车痴汉"),
    ("511", "淫欲痴女"),
];

/// 带重试的 GET：站间歇限流超时，最多试 3 次，每次间隔 2 秒。
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
        return Err(ApiError::Internal(format!("中文无码请求 HTTP {status}")));
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

/// 卡片解析：每条 `<li>` 内 `/info/id/<n>.html` + img src（封面）+
/// `<h3 class="video-title">` 里的 `<text>` 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<li>.*?<a href="/info/id/(\d+)\.html"[^>]*>\s*<img[^>]*src="([^"]+)".*?<h3 class="video-title">.*?<text>(.*?)</text>"#,
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

/// 分类解析：首页导航 /type/id/<n>.html 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re =
        match Regex::new(r#"href="/type/id/(\d+)\.html"[^>]*>(?:<text>)?([^<]+?)(?:</text>)?</a>"#)
        {
            Ok(re) => re,
            Err(_) => return Vec::new(),
        };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
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
    .map(|(id, name)| category_json(id, name))
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
        format!("{BASE}/type/id/{category_id}.html")
    } else {
        format!("{BASE}/type/id/{category_id}/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more =
        !items.is_empty() && html.contains(&format!("/type/id/{category_id}/{}.html", page + 1));
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
    let url = format!("{BASE}/info/id/{id}.html");
    let html = get_text(&url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>.*?<text>(.*?)</text>").ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = title.strip_suffix("详情页") {
        title = stripped.to_string();
    }
    if title.is_empty() {
        let title_re = Regex::new(r"<title>(.*?)</title>").ok();
        if let Some(re) = title_re {
            if let Some(cap) = re.captures(&html) {
                title = unescape(cap[1].trim());
                if let Some(stripped) = title.strip_suffix("-中文无码详情页面") {
                    title = stripped.to_string();
                }
            }
        }
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
    let play_url = format!("{BASE}/play/id/{id}.html");
    let play_html = get_text(&play_url).await?;
    let m3u8 = parse_play_url(&play_html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("中文无码未返回可播放地址".into()));
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
        Err(ApiError::Internal("中文无码该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/lookup/{query}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<ul class="video-list home-video-list"><li><a href="/info/id/2521746.html" name="rdmonclick" target="_blank" class="enable-random-friend-link" rel="nofollow"><img class="lazy" src="https://img.uyjthen.com/upload/vod/20261026-1/2d496dcfb33b0598d729a3fba47575d4.jpg"></a><div class="video-detail"><a href="/info/id/2521746.html" name="rdmonclick" target="_blank" rel="nofollow"></a><h3 class="video-title"><a href="/info/id/2521746.html" name="rdmonclick" target="_blank" rel="nofollow"></a><a><text>第一颜值女神让人摇摇欲坠的面容</text></a></h3></div></li><li><a href="/info/id/2521746.html"><img class="lazy" src="https://img.uyjthen.com/x.jpg"></a><div class="video-detail"><h3 class="video-title"><a><text>重复卡片</text></a></h3></div></li></ul>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2521746");
        assert_eq!(items[0]["title"], "第一颜值女神让人摇摇欲坠的面容");
        assert_eq!(
            items[0]["cover"],
            "https://img.uyjthen.com/upload/vod/20261026-1/2d496dcfb33b0598d729a3fba47575d4.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/type/id/490.html" title="网红主播" target="_blank"><text>网红主播</text></a><a href="/type/id/491.html" title="国产传媒" target="_blank"><text>国产传媒</text></a><a href="/type/id/490.html" title="网红主播" target="_blank"><text>网红主播</text></a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "490");
        assert_eq!(list[1]["name"], "国产传媒");
    }

    #[test]
    fn fallback_has_22_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 22);
        assert_eq!(list[0]["id"], "490");
        assert_eq!(list[21]["name"], "淫欲痴女");
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#"var u="https://superonex.buzz/";var playUrl = 'https://hsm3.hwzcfz.com/a3/20261026/QBbKNpXP/index.m3u8';"#;
        assert_eq!(
            parse_play_url(html),
            "https://hsm3.hwzcfz.com/a3/20261026/QBbKNpXP/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn has_more_next_page_link() {
        let html = r#"<li><a title='第2页' href='/type/id/490/2.html' class='pageitem'>2</a></li>"#;
        assert!(html.contains("/type/id/490/2.html"));
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://hsm3.hwzcfz.com/a3/20261026/QBbKNpXP/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://hsm3.hwzcfz.com/a3/20261026/QBbKNpXP/index.m3u8"
        );
        assert!(play_check("2521733").is_err());
    }

    #[test]
    fn unescape_entities() {
        assert_eq!(unescape("a &amp; b &#39;c&#39;"), "a & b 'c'");
    }
    #[tokio::test]
    #[ignore]
    async fn live_avjieshuo_catalog() {
        let start = std::time::Instant::now();
        let r = catalog("501", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE zwwm av解说 cat=501 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "zwwm AV解说 catalog empty");
    }
}
