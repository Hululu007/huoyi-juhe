//! 中国X站：核心里的影视区站点。
//!
//! 与站导航 1:1（4 项）：国产传媒、日本AV、无码视频、中文字幕，
//! 每页 36 条；详情页 /vodplay/<slug>，取流为 MacCMS player_aaaa
//! 的 m3u8（主清单 200、变体清单 200 METHOD=NONE、首分片 200 且
//! TS 同步头，无需特殊头）；搜索 /vodsearch/?wd=。站内无女优/标
//! 签索引，只有 4 个导航分类。站有时回 JS 校验页（Checking your
//! browser…）或空响应，属间歇性，重试即通，get_text 内重试 3 次。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://chinaxmovie.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("domestic-media", "国产传媒"),
    ("japanese-av", "日本AV"),
    ("uncensored-video", "无码视频"),
    ("chinese-subtitles", "中文字幕"),
];

/// 带重试的 GET：站间歇回校验页或空响应，最多试 3 次，每次间隔 1 秒。
async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
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
        return Err(ApiError::Internal(format!("中国X站请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.contains("Checking your browser") {
        return Err(ApiError::Internal("中国X站返回校验页".into()));
    }
    Ok(text)
}

/// 地址归一：协议相对补 https，站内相对路径补基址。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：`<a href="/vodplay/<slug>">` + img alt（标题，去
/// “ 高清在线观看”后缀）+ img src（封面，站内相对路径）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/vodplay/([^"]+)">.*?<img alt="([^"]+?)"[^>]* src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let slug = cap[1].trim().to_string();
        if slug.is_empty() || !seen.insert(slug.clone()) {
            continue;
        }
        let mut title = unescape(cap[2].trim());
        if let Some(stripped) = title.strip_suffix(" 高清在线观看") {
            title = stripped.to_string();
        }
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[3]);
        items.push(item_json(&slug, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页导航 /vodtype/<slug>/ 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/vodtype/([a-z-]+)/"[^>]*>([^<]+)<"#) {
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
        format!("{BASE}/vodtype/{category_id}/")
    } else {
        format!("{BASE}/vodtype/{category_id}-{page}/")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html, category_id) {
        page < total
    } else {
        html.contains(&format!("/vodtype/{category_id}-{}", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 分页总数：列表页分页链接 /vodtype/<slug>-<n>/ 里最大的 n。
fn page_total(html: &str, slug: &str) -> Option<i64> {
    let re = Regex::new(&format!(r#"/vodtype/{}-(\d+)/"#, regex::escape(slug))).ok()?;
    let mut max: Option<i64> = None;
    for cap in re.captures_iter(html) {
        if let Ok(n) = cap[1].parse::<i64>() {
            max = Some(max.map_or(n, |m: i64| m.max(n)));
        }
    }
    max
}

/// 播放地址：详情页 player_aaaa JSON 的 url 字段（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let slug = series_id.trim_start_matches('/');
    let slug = slug.strip_prefix("vodplay/").unwrap_or(slug);
    let url = format!("{BASE}/vodplay/{slug}");
    let html = get_text(&url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = title.strip_suffix(" 高清在线播放") {
        title = stripped.to_string();
    }
    if title.is_empty() {
        let name_re = Regex::new(r#""name":\s*"([^"]+)""#).ok();
        if let Some(re) = name_re {
            if let Some(cap) = re.captures(&html) {
                title = unescape(&cap[1]);
            }
        }
    }
    let cover_re = Regex::new(r#""thumbnailUrl":\s*"([^"]+)""#).ok();
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
    let genre_re = Regex::new(r#""genre":\s*"([^"]+)""#).ok();
    let genre = match &genre_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let m3u8 = parse_player_url(&html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("中国X站未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("中国X站该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/vodsearch/"), &[("wd", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/upload/vod/20261105-1/a16cef2bc57284c859198ee7a2ce392e.jpg"),
            "https://chinaxmovie.com/upload/vod/20261105-1/a16cef2bc57284c859198ee7a2ce392e.jpg"
        );
        assert_eq!(
            fix_url("https://2609.v155p.com/20261102/qDRwfU4o/index.m3u8"),
            "https://2609.v155p.com/20261102/qDRwfU4o/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="thumbnail group"><div class="relative aspect-w-16 aspect-h-9 rounded overflow-hidden shadow-lg"><a href="/vodplay/pmtc033"><video class="preview hidden" data-src="" id="preview-1" loop=""></video><img alt="金宝娜PMTC033同城女医师的深入性治疗 高清在线观看" class="w-full" data-loaded="true" data-src="/upload/vod/20261105-1/a16cef2bc57284c859198ee7a2ce392e.jpg" src="/upload/vod/20261105-1/a16cef2bc57284c859198ee7a2ce392e.jpg" loading="lazy" decoding="async"></a></div></div><div class="thumbnail group"><a href="/vodplay/pmtc033"><img alt="重复卡片 高清在线观看" src="/upload/vod/x.jpg"></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "pmtc033");
        assert_eq!(items[0]["title"], "金宝娜PMTC033同城女医师的深入性治疗");
        assert_eq!(
            items[0]["cover"],
            "https://chinaxmovie.com/upload/vod/20261105-1/a16cef2bc57284c859198ee7a2ce392e.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/vodtype/domestic-media/">国产传媒</a><a href="/vodtype/japanese-av/">日本AV</a><a href="/vodtype/domestic-media/">国产传媒</a><a href="/vodtype/uncensored-video/">无码视频</a><a href="/vodtype/chinese-subtitles/">中文字幕</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "domestic-media");
        assert_eq!(list[3]["name"], "中文字幕");
    }

    #[test]
    fn fallback_has_4_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "domestic-media");
        assert_eq!(list[2]["name"], "无码视频");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/id\/pmtc033\/sid\/1\/nid\/1\/","link_next":"","link_pre":"","vod_data":{"vod_name":"金宝娜PMTC033","vod_actor":"","vod_director":"","vod_class":"国产传媒"},"url":"https:\/\/2609.v155p.com\/20261102\/qDRwfU4o\/index.m3u8","url_next":"","from":"155m3u8","server":"no","note":"","id":"pmtc033","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://2609.v155p.com/20261102/qDRwfU4o/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn page_total_reads_max_pager() {
        let html = r#"<a href="/vodtype/domestic-media-2/">下一页</a><a href="/vodtype/domestic-media-63/">63</a><a href="/vodtype/domestic-media-64/">64</a>"#;
        assert_eq!(page_total(html, "domestic-media"), Some(64));
        assert_eq!(page_total("<div>no pager</div>", "domestic-media"), None);
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://2609.v155p.com/20261102/qDRwfU4o/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://2609.v155p.com/20261102/qDRwfU4o/index.m3u8"
        );
        assert!(play_check("pmtc033").is_err());
    }
}
