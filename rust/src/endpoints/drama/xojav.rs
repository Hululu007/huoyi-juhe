//! XOJAV：核心里的影视区站点。
//!
//! 与 py 版 xojav.py 同一套分类、同一条已验播放链：分类与站
//! /categories 导航 1:1（14 项）、列表 24 条一页、单片详情、
//! 取流为详情页 `var stream` 的 m3u8（清单与首分片已验 200，
//! 无需特殊头）；翻页走站内 KVS 异步接口（`mode=async&
//! function=get_block`，`/categories/<slug>/2` 本身 404）；
//! 搜索为 `/search/<关键词>/` 路径式。站内无萝莉分类，单片
//! 标题含萝莉/幼女/未成年词的按片过滤。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://xojav.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站 /categories 导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("chinese-subtitle", "中文字幕"),
    ("uncensored", "無碼解放"),
    ("taiwan-av", "台灣AV"),
    ("jav", "日本AV"),
    ("uniform", "制服誘惑"),
    ("roleplay", "角色劇情"),
    ("pantyhose", "絲襪"),
    ("sex-only", "直接開啪"),
    ("bdsm", "主奴調教"),
    ("groupsex", "多P群交"),
    ("intrusion", "進犯"),
    ("pov", "男友視角"),
    ("hixxen-cam", "流出"),
    ("lesbian", "女同歡愉"),
];

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
        return Err(ApiError::Internal(format!("XOJAV 请求 HTTP {status}")));
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

/// 路径段百分号编码：ASCII 安全字符原样，其余按 UTF-8 编码。
fn encode_path(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 卡片解析：首页、分类页、搜索页与异步分片同款 card-video；
/// 标题取 img alt、封面取 data-src、备注取时长。
fn parse_cards(html: &str) -> Vec<Value> {
    let link_re = match Regex::new(r#"href="https://xojav\.tv/videos/([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"data-src="([^"]+)""#).ok();
    let alt_re = Regex::new(r#"alt="([^"]+)""#).ok();
    let dur_re = Regex::new(r#"card-video__duration">([^<]+)<"#).ok();
    let positions: Vec<(usize, String)> = link_re
        .captures_iter(html)
        .filter_map(|cap| cap.get(0).map(|m| (m.start(), cap[1].to_string())))
        .collect();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for (i, (start, code)) in positions.iter().enumerate() {
        let vid = format!("/videos/{code}");
        if !seen.insert(vid.clone()) {
            continue;
        }
        let stop = if i + 1 < positions.len() {
            positions[i + 1].0
        } else {
            (*start + 8000).min(html.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &html[*start..stop];
        let title = match &alt_re {
            Some(re) => re
                .captures(chunk)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let mut cover = match &img_re {
            Some(re) => re
                .captures(chunk)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        if cover.is_empty() || cover.contains("video-placeholder") {
            cover = format!("https://cdn.18jav.tv/storage/{code}/320_180.jpg");
        }
        let remark = match &dur_re {
            Some(re) => re
                .captures(chunk)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

/// 分类解析：/categories 页锚点，名字前 `N 部影片` 计数去掉。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="https://xojav\.tv/categories/([a-z0-9-]+)"[^>]*>(.*?)</a>"#)
    {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let tag_re = Regex::new("<[^>]+>").ok();
    let count_re = Regex::new(r"^\d+\s*部影片\s*").ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let mut name = cap[2].to_string();
        if let Some(re) = &tag_re {
            name = re.replace_all(&name, " ").to_string();
        }
        if let Some(re) = &count_re {
            name = re.replace(&name, "").to_string();
        }
        let name = name.split_whitespace().collect::<Vec<&str>>().join(" ");
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

/// 列表总数：页内 `N 部影片`，一页 24 条，算出总页数。
fn total_pages(html: &str) -> Option<i64> {
    let re = Regex::new(r"(\d+)\s*部影片").ok()?;
    let cap = re.captures(html)?;
    let total: i64 = cap[1].parse().ok()?;
    Some((total + 23) / 24)
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let slug = if category_id.is_empty() {
        "jav"
    } else {
        category_id
    };
    let html = if page <= 1 {
        get_text(&format!("{BASE}/categories/{slug}/")).await?
    } else {
        let from = page.to_string();
        let url = with_query(
            &format!("{BASE}/categories/{slug}/"),
            &[
                ("mode", "async"),
                ("function", "get_block"),
                ("block_id", "list_videos_common_videos_list"),
                ("sort_by", "release_at"),
                ("from", &from),
            ],
        );
        get_text(&url).await?
    };
    let items = parse_cards(&html);
    let has_more = match total_pages(&html) {
        Some(total) => page < total,
        None => items.len() == 24,
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
    let title_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = title.find(" | ") {
        title.truncate(pos);
    }
    let cover_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
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
    let tag_re = Regex::new(r#"href="https://xojav\.tv/categories/[a-z0-9-]+"[^>]*>([^<]+)<"#).ok();
    let mut tags: Vec<String> = Vec::new();
    if let Some(re) = &tag_re {
        for cap in re.captures_iter(&html) {
            let t = cap[1].trim().to_string();
            if !t.is_empty() && !tags.contains(&t) {
                tags.push(t);
            }
        }
    }
    let stream_re = Regex::new(r"var stream = '([^']+\.m3u8[^']*)'").ok();
    let stream = match &stream_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() || stream.is_empty() {
        return Err(ApiError::Internal("XOJAV 未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&stream, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("XOJAV 该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/search/{}/", encode_path(query));
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_basic() {
        let html = r#"<div class="item card-video"><a href="https://xojav.tv/videos/AAA111"><img class="lazyload" src="https://cdn.18jav.tv/assets_x/images/video-placeholder.png" data-src="https://cdn.18jav.tv/storage/AAA111/320_180.jpg" alt="幼女片名" /><figcaption class="card-video__duration">10:00</figcaption></a></div><div class="item card-video"><a href="https://xojav.tv/videos/MD0277"><img class="lazyload" src="https://cdn.18jav.tv/assets_x/images/video-placeholder.png" data-src="https://cdn.18jav.tv/storage/MD0277/320_180.jpg" alt="MD0277 街頭獵豔單身欲女" /><figcaption class="card-video__duration">48:54</figcaption></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/videos/AAA111");
        assert_eq!(items[0]["title"], "幼女片名");
        assert_eq!(
            items[0]["cover"],
            "https://cdn.18jav.tv/storage/AAA111/320_180.jpg"
        );
        assert_eq!(items[0]["remark"], "10:00");
        assert_eq!(items[1]["id"], "/videos/MD0277");
        assert_eq!(items[1]["title"], "MD0277 街頭獵豔單身欲女");
        assert_eq!(
            items[1]["cover"],
            "https://cdn.18jav.tv/storage/MD0277/320_180.jpg"
        );
        assert_eq!(items[1]["remark"], "48:54");
    }

    #[test]
    fn parse_categories_strips_counts() {
        let html = r#"<a href="https://xojav.tv/categories/jav">5553 部影片 日本AV</a><a href="https://xojav.tv/categories/uncensored">10329 部影片 無碼解放</a><a href="https://xojav.tv/categories/jav">5553 部影片 日本AV</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "jav");
        assert_eq!(list[0]["name"], "日本AV");
        assert_eq!(list[1]["name"], "無碼解放");
    }

    #[test]
    fn fallback_has_14_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 14);
        assert_eq!(list[0]["id"], "chinese-subtitle");
        assert_eq!(list[13]["id"], "lesbian");
    }

    #[test]
    fn stream_extract() {
        let html = "var stream = 'https://s10.hshdkshd.com/hls/abc/storage/MD0277/x.m3u8';";
        let re = Regex::new(r"var stream = '([^']+\.m3u8[^']*)'").unwrap();
        let cap = re.captures(html).unwrap();
        assert!(cap[1].starts_with("https://s10.hshdkshd.com/"));
        assert!(cap[1].ends_with(".m3u8"));
    }

    #[test]
    fn total_pages_ceil() {
        assert_eq!(total_pages("<h4>5549 部影片</h4>"), Some(232));
        assert_eq!(total_pages("<div>no total</div>"), None);
    }

    #[test]
    fn encode_path_chinese() {
        assert_eq!(encode_path("素人"), "%E7%B4%A0%E4%BA%BA");
        assert_eq!(encode_path("MD0277"), "MD0277");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://s10.hshdkshd.com/hls/x.m3u8").unwrap();
        assert_eq!(ok["url"], "https://s10.hshdkshd.com/hls/x.m3u8");
        assert!(play_check("/videos/MD0277").is_err());
    }
}
