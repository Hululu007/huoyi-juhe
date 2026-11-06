//! 黄.短剧（黄短剧）：核心里的影视区站点。
//!
//! 入口 https://hpkspnbsk.xyz/xamir/duqel.html 301 到实站
//! https://hpkspvynq.buzz（canonical 另有 hpkspwusz.buzz）。
//! 首页导航 /video/type/<id>.html 共 213 项（title 属性为分类名，
//! 首页另有“最新视频”区走 /video/show/recent.html）；每页 18 条，
//! 翻页 /video/type/<id>/<页>.html、/video/show/recent/<页>.html。
//! 卡片 `<a href='/video/info/<id>.html' title="…">` + img src 封面
//! + h2 标题。详情 /video/info/<id>.html（h1 标题、封面、分类、
//! 简介、评分、更新时间、播放数据），4 个播放地址按钮都指向同一
//! 播放页 /video/play/<id>.html，内有 `var playUrl = '…m3u8'`
//!（另有 JSON-LD contentUrl 兜底）；主清单 200，变体清单
//! /2000kb/hls/index.m3u8。搜索走关键词页
//! /video/lookup/<编码词>.html。写源照站原样写，不按站名/分类名/
//! 标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://hpkspvynq.buzz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页首屏的 4 个分区 + 导航前几项，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("recent", "最新视频"),
    ("228", "国产传媒"),
    ("223", "国产视频"),
    ("583", "国产自拍"),
    ("295", "无码专区"),
    ("297", "制服师生"),
    ("298", "伦理系列"),
    ("299", "换脸AI"),
    ("300", "中文伦理"),
    ("301", "卡通动漫"),
    ("302", "欧美系列"),
    ("303", "美女主播"),
    ("304", "国产自拍"),
    ("305", "人妻热门"),
];

/// 带重试的 GET：站经出口代理较慢，最多试 3 次，每次间隔 2 秒。
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
        return Err(ApiError::Internal(format!("黄.短剧请求 HTTP {status}")));
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
        .replace("&nbsp;", " ")
}

/// 分类解析：导航锚点 `href='/video/type/<id>.html' … title="<名>"`，
// 按站内顺序、id 去重；首位补“最新视频”区。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"(?s)href='/video/type/(\d+)\.html'[^>]*?title="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = vec![category_json("recent", "最新视频")];
    seen.insert("recent".to_string());
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
            if list.len() <= 1 {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

/// 卡片解析：`<a href='/video/info/<id>.html' title="…">` 内 img
/// src 为封面；标题取 title 属性（与 h2 一致）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href='/video/info/(\d+)\.html'[^>]*title="([^"]+)"[^>]*>.*?<img[^>]*src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
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
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if category_id == "recent" {
        if page <= 1 {
            format!("{BASE}/video/show/recent.html")
        } else {
            format!("{BASE}/video/show/recent/{page}.html")
        }
    } else if page <= 1 {
        format!("{BASE}/video/type/{category_id}.html")
    } else {
        format!("{BASE}/video/type/{category_id}/{page}.html")
    }
}

fn next_page_url(category_id: &str, page: i64) -> String {
    if category_id == "recent" {
        format!("{BASE}/video/show/recent/{}.html", page + 1)
    } else {
        format!("{BASE}/video/type/{category_id}/{}.html", page + 1)
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty() && html.contains(&next_page_url(category_id, page));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 `var playUrl = '…m3u8'`，兜底 JSON-LD contentUrl。
fn parse_play_url(html: &str) -> String {
    let re = Regex::new(r"var playUrl\s*=\s*'([^']+)'").ok();
    if let Some(re) = re {
        if let Some(cap) = re.captures(html) {
            return cap[1].trim().to_string();
        }
    }
    let ld_re = Regex::new(r#""contentUrl":\s*"([^"]+)""#).ok();
    if let Some(re) = ld_re {
        if let Some(cap) = re.captures(html) {
            return cap[1].trim().to_string();
        }
    }
    String::new()
}

fn detail_id(series_id: &str) -> String {
    let s = series_id.trim().trim_start_matches('/');
    let s = s.strip_prefix("video/info/").unwrap_or(s);
    s.trim_end_matches(".html").to_string()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = detail_id(series_id);
    let url = format!("{BASE}/video/info/{id}.html");
    let html = get_text(&url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"(?s)class="info-cover-img"[^>]*src="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].trim().to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let cat_re = Regex::new(r#"href='/video/type/(\d+)\.html'[^>]*>([^<]+)<"#).ok();
    let genre = match &cat_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[2].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(
        r#"(?s)<span class="meta-label">简\s*介</span>\s*<span class="meta-value">(.*?)</span>"#,
    )
    .ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("黄.短剧详情未返回标题".into()));
    }
    let play_url = format!("{BASE}/video/play/{id}.html");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&play_url, "播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.ends_with(".m3u8") || video_id.ends_with(".mp4") {
        return Ok(json!({"url": video_id}));
    }
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{BASE}/video/play/{}.html", detail_id(video_id))
    };
    let html = get_text(&url).await?;
    let m3u8 = parse_play_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("黄.短剧未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let url = format!("{BASE}/video/lookup/{enc}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<a href='/video/type/295.html' target="_blank"  class="cn-tag enable-nav-random"
					title="无码专区">无码专区</a>
			<a href='/video/type/297.html' target="_blank"  class="cn-tag enable-nav-random"
					title="制服师生">制服师生</a>
			<a href='/video/type/295.html' target="_blank"  class="cn-tag enable-nav-random"
					title="无码专区">无码专区</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "recent");
        assert_eq!(list[1]["id"], "295");
        assert_eq!(list[1]["name"], "无码专区");
        assert_eq!(list[2]["id"], "297");
    }

    #[test]
    fn fallback_has_sections() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list[0]["id"], "recent");
        assert_eq!(list[1]["id"], "228");
        assert_eq!(list[1]["name"], "国产传媒");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<article class="card">
							<a href='/video/info/2840894.html' title="[フェアリーダスト] くりいむレモン PART 30 亜麻木硅ベストヒット チェリーなゆううつ" target="_blank" class="enable-home-random">
								<div class="card-thumb ">
									<img src="https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg"
										referrerpolicy="no-referrer" alt="[フェアリーダスト] くりいむレモン PART 30 亜麻木硅ベストヒット チェリーなゆううつ" class="card-thumb-img"
										loading="lazy">
								</div>
								<div class="card-body">
									<h2 class="card-title" title="[フェアリーダスト] くりいむレモン PART 30 亜麻木硅ベストヒット チェリーなゆううつ">[フェアリーダスト] くりいむレモン PART 30 亜麻木硅ベストヒット チェリーなゆううつ</h2>
								</div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2840894");
        assert_eq!(
            items[0]["title"],
            "[フェアリーダスト] くりいむレモン PART 30 亜麻木硅ベストヒット チェリーなゆううつ"
        );
        assert_eq!(
            items[0]["cover"],
            "https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg"
        );
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#""thumbnailUrl": "https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg",                   "contentUrl": "https://v.heicdn.com/20261031/2xlwcW2I/index.m3u8",                   "description": "x"</script> <script> var playUrl = 'https://v.heicdn.com/20261031/2xlwcW2I/index.m3u8'; var player = new Aliplayer({"#;
        assert_eq!(
            parse_play_url(html),
            "https://v.heicdn.com/20261031/2xlwcW2I/index.m3u8"
        );
        let ld_only = r#""contentUrl": "https://v.heicdn.com/20261031/2xlwcW2I/index.m3u8""#;
        assert_eq!(
            parse_play_url(ld_only),
            "https://v.heicdn.com/20261031/2xlwcW2I/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn catalog_urls() {
        assert_eq!(
            catalog_url("228", 1),
            "https://hpkspvynq.buzz/video/type/228.html"
        );
        assert_eq!(
            catalog_url("228", 2),
            "https://hpkspvynq.buzz/video/type/228/2.html"
        );
        assert_eq!(
            catalog_url("recent", 1),
            "https://hpkspvynq.buzz/video/show/recent.html"
        );
        assert_eq!(
            catalog_url("recent", 2),
            "https://hpkspvynq.buzz/video/show/recent/2.html"
        );
    }

    #[test]
    fn detail_id_forms() {
        assert_eq!(detail_id("2840894"), "2840894");
        assert_eq!(detail_id("2840894.html"), "2840894");
        assert_eq!(detail_id("/video/info/2840894.html"), "2840894");
    }
}
