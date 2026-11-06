//! 4K.AI短剧：核心里的影视区站点。
//!
//! 入口 wyswspab.xyz/nsrsnh 跳转到实站 wyswspqjtr.click（站名
//! 4k超清自拍，清单名 4K.AI短剧）。与站主导航 1:1（23 项）：
//! /type/id/<n>.html（7 中文字幕、8 国产传媒、9 日本有码、10 日
//! 本无码、11 欧美无码、12 强奸乱伦、13 制服诱惑、14 国产主播、
//! 15 激情动漫、16 明星换脸、17 抖阴视频、18 女优明星、22 网曝黑
//! 料、26 伦理三级、28 AV解说、31 SM调教、33 萝莉少女、34 极品媚
//! 黑、37 女同性恋、39 网红头条、43 人妖系列、45 韩国主播、47 VR
//! 视角；页内另有分区/页脚导航不在主导航内，不采）；每页 20 条，
//! 翻页 /type/id/<n>/<页>.html。视频 /info/id/<n>.html，播放页
//! /play/id/<n>.html 里 playUrl 为 m3u8（主清单 200、变体清单
//! 200 METHOD=NONE、首分片 200）。搜索 /hunt/<词>.html。站间歇
//! 限流超时，get_text 内重试 3 次、间隔 2 秒。写源照站原样写，
//! 不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://wyswspqjtr.click";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站主导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("7", "中文字幕"),
    ("8", "国产传媒"),
    ("9", "日本有码"),
    ("10", "日本无码"),
    ("11", "欧美无码"),
    ("12", "强奸乱伦"),
    ("13", "制服诱惑"),
    ("14", "国产主播"),
    ("15", "激情动漫"),
    ("16", "明星换脸"),
    ("17", "抖阴视频"),
    ("18", "女优明星"),
    ("22", "网曝黑料"),
    ("26", "伦理三级"),
    ("28", "AV解说"),
    ("31", "SM调教"),
    ("33", "萝莉少女"),
    ("34", "极品媚黑"),
    ("37", "女同性恋"),
    ("39", "网红头条"),
    ("43", "人妖系列"),
    ("45", "韩国主播"),
    ("47", "VR视角"),
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
        return Err(ApiError::Internal(format!("4K.AI短剧请求 HTTP {status}")));
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

/// 卡片解析：`<article class="card">` 内 `/info/id/<n>.html` +
/// img src（封面）+ `<h2 class="card-title">` 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<article class="card">.*?<a[^>]*href="/info/id/(\d+)\.html"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<h2 class="card-title"[^>]*>(.*?)</h2>"#,
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

/// 分类解析：只取 `<nav class="site-nav">` 主导航内的
/// /type/id/<n>.html 锚点（页脚分区导航不在内），按站内顺序、
/// id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let nav = match html.find("<nav class=\"site-nav\"") {
        Some(start) => match html[start..].find("</nav>") {
            Some(end) => &html[start..start + end],
            None => html,
        },
        None => html,
    };
    let re = match Regex::new(r#"href="/type/id/(\d+)\.html"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(nav) {
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
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = title.strip_suffix(" - 详情页") {
        title = stripped.to_string();
    }
    let cover_re = Regex::new(r#"<img[^>]*src="(https?://[^"]+)""#).ok();
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
        return Err(ApiError::Internal("4K.AI短剧未返回可播放地址".into()));
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
        Err(ApiError::Internal("4K.AI短剧该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/hunt/{query}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<article class="card"><a id="content1" href="/info/id/3145640.html" title="PPPE-248-C 彼女が家族旅行で一週間留守にしたので彼女の巨乳女友達に中出ししまくりました。" target="_blank"><div class="cover"><img class="lazy" src="https://aoksazysz.com/20261104/9YHQ4Acn/1.jpg" referrerpolicy="no-referrer" loading="lazy" alt="PPPE-248-C" /><div class="meta"><span class="cat">中文字幕</span></div></div><h2 class="card-title" title="PPPE-248-C">PPPE-248-C 彼女が家族旅行で一週間留守にしたので彼女の巨乳女友達に中出ししまくりました。</h2></a></article><article class="card"><a href="/info/id/3145640.html"><img class="lazy" src="https://aoksazysz.com/x.jpg"><h2 class="card-title">重复卡片</h2></a></article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "3145640");
        assert_eq!(
            items[0]["title"],
            "PPPE-248-C 彼女が家族旅行で一週間留守にしたので彼女の巨乳女友達に中出ししまくりました。"
        );
        assert_eq!(
            items[0]["cover"],
            "https://aoksazysz.com/20261104/9YHQ4Acn/1.jpg"
        );
    }

    #[test]
    fn parse_categories_nav_only() {
        let html = r#"<nav class="site-nav"><div class="nav-grid"><a class="nav-item" href="/type/id/7.html">中文字幕</a><a class="nav-item" href="/type/id/8.html">国产传媒</a><a class="nav-item" href="/type/id/7.html">中文字幕</a></div></nav><footer><a href="/type/id/554.html">视频一区</a></footer>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "7");
        assert_eq!(list[1]["name"], "国产传媒");
    }

    #[test]
    fn fallback_has_23_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 23);
        assert_eq!(list[0]["id"], "7");
        assert_eq!(list[22]["name"], "VR视角");
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#"var playUrl = 'https://iuewgnbvk.com/20261104/9YHQ4Acn/index.m3u8';"#;
        assert_eq!(
            parse_play_url(html),
            "https://iuewgnbvk.com/20261104/9YHQ4Acn/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://iuewgnbvk.com/20261104/9YHQ4Acn/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://iuewgnbvk.com/20261104/9YHQ4Acn/index.m3u8"
        );
        assert!(play_check("3145640").is_err());
    }

    #[test]
    fn unescape_entities() {
        assert_eq!(unescape("a &amp; b &#39;c&#39;"), "a & b 'c'");
    }
}
