//! 🔞HereXXX（herexxx.com）：KVS 引擎亚洲 tube 站。
//!
//! 列表（/video/{id}/{slug}/ 卡片：data-original 取封面、
//! span.time 取时长）、详情（og 标题封面、JSON-LD 时长、
//! flashvars video_url 为 base64 编码的 get_file 直链）、
//! 搜索（/search/?q=）。取流（详情页 video_url 解出
//! get_file：本机实测 302 跳到 wwww1.tubegifs.com 签名
//! mp4，Range 206 + ftypisom 魔数；令牌有时效，须现取现用）。
//! 验门（2026-11-06 本机出口实测）：详情 887550《남사친 내기녀 2》
//! 时长 PT0H0M29S；最新列表 p1/p2 各 30 条 0 重合；分类
//! korean-porn p1/p2 各 30 条 0 重合；搜索 korean 20 条。
//! 注意：首页最新多为 6～30 秒短片，也有 2～6 分钟的片；
//! KVIP/JVIP 两个分类站内本身可能要登录，模块只按公开
//! 列表取，取不到时如实返回空。

use base64::Engine;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://herexxx.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 3 路排序 + /categories/ 页的分类。
const CATS: &[(&str, &str)] = &[
    ("latest-updates", "最新"),
    ("most-popular:video_viewed", "最热"),
    ("most-popular:video_viewed_today", "HOT"),
    ("cat:vip", "KVIP"),
    ("cat:jvip", "JVIP"),
    ("cat:korean-porn", "Korean Porn"),
    ("cat:korean-bj", "Korean BJ"),
    ("cat:fc2ppv", "FC2PPV"),
    ("cat:jav", "Uncensored"),
    ("cat:ipcam", "IPCAM"),
    ("cat:toilet", "Toilet"),
    ("cat:voyeur-jp", "Voyeur JP"),
    ("cat:china", "China"),
    ("cat:myfans", "MyFans"),
    ("cat:asian-leak", "Asian Leak"),
    ("cat:upskirt", "Upskirt"),
    ("cat:mib", "MIB"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("HereXXX 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
        .trim()
        .to_string()
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// KVS 卡片解析：/video/{id}/{slug}/ 链接、标题、封面、时长。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"item thumb\">").skip(1) {
        let end = block
            .find("<div class=\"item thumb\">")
            .unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a href=\"https://herexxx.com/video/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let id = href.to_string();
        if seen.contains(&id) {
            continue;
        }
        let title = match block.find("title=\"") {
            Some(p) => {
                let s = p + 7;
                block[s..]
                    .find('"')
                    .map(|e| decode_entities(&block[s..s + e]))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let cover = match block.find("data-original=\"") {
            Some(p) => {
                let s = p + 15;
                block[s..]
                    .find('"')
                    .map(|e| block[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match block.find("<span class=\"time\">") {
            Some(p) => {
                let s = p + 19;
                block[s..]
                    .find("</span>")
                    .map(|e| block[s..s + e].trim().to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let page_part = if page <= 1 {
        String::new()
    } else {
        format!("{page}/")
    };
    if let Some(slug) = category_id.strip_prefix("cat:") {
        return format!("{HOST}/categories/{slug}/{page_part}");
    }
    if let Some(sort) = category_id.strip_prefix("most-popular:") {
        return format!("{HOST}/most-popular/{page_part}?sort_by={sort}");
    }
    format!("{HOST}/{category_id}/{page_part}")
}

/// JSON-LD 时长 PT0H0M29S → 0:29。
fn iso_duration(s: &str) -> String {
    let re = Regex::new(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?").unwrap();
    let Some(cap) = re.captures(s) else {
        return String::new();
    };
    let h: i64 = cap
        .get(1)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let m: i64 = cap
        .get(2)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let sec: i64 = cap
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    if h > 0 {
        format!("{h}:{m:02}:{sec:02}")
    } else {
        format!("{m}:{sec:02}")
    }
}

fn meta_content(html: &str, attr: &str, key: &str) -> String {
    let marker = format!("{attr}=\"{key}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let Some(c) = after.find("content=\"") else {
        return String::new();
    };
    let s = c + 9;
    after[s..]
        .find('"')
        .map(|e| decode_entities(&after[s..s + e]))
        .unwrap_or_default()
}

fn flashvar(html: &str, key: &str) -> String {
    let marker = format!("{key}: '");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    html[s..]
        .find('\'')
        .map(|e| html[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_title(html: &str) -> String {
    let Some(p) = html.find("<title>") else {
        return String::new();
    };
    let s = p + 7;
    let e = html[s..]
        .find("</title>")
        .map(|i| s + i)
        .unwrap_or(html.len());
    let t = decode_entities(&html[s..e]);
    for sep in [" | ", " - "] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

fn abs_url(u: &str) -> String {
    if let Some(rest) = u.strip_prefix("//") {
        format!("https://{rest}")
    } else {
        u.to_string()
    }
}

/// video_url 是 base64 编码的 get_file 直链。
fn decode_video_url(b64: &str) -> String {
    let padded = format!("{b64}{}", "=".repeat((4 - b64.len() % 4) % 4));
    match base64::engine::general_purpose::STANDARD.decode(padded.as_bytes()) {
        Ok(bytes) => String::from_utf8_lossy(&bytes).trim().to_string(),
        Err(_) => String::new(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("HereXXX 未返回影片资料".into()));
    }
    let cover = abs_url(&meta_content(&html, "property", "og:image"));
    let duration = iso_duration(&flashvar(&html, "duration"));
    let cats = flashvar(&html, "video_categories");
    let mut lines: Vec<String> = Vec::new();
    if !cats.is_empty() {
        lines.push(format!("分类：{cats}"));
    }
    if !duration.is_empty() {
        lines.push(format!("时长：{duration}"));
    }
    let synopsis = truncate(&lines.join("\n"), 400);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let b64 = flashvar(&html, "video_url");
    let url = decode_video_url(&b64);
    if url.is_empty() {
        return Err(ApiError::Internal("HereXXX 未取到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_video_url_real_sample() {
        // 详情页 887557 的真实 video_url（base64）。
        assert_eq!(
            decode_video_url("aHR0cHM6Ly9oZXJleHh4LmNvbS9nZXRfZmlsZS8xMS84MjQxNmE2MDhkNDE1NWM5OTljMzVlY2VkODZkODcwMi84ODcwMDAvODg3NTU3Lzg4NzU1Ny5tcDQvP2JyPTM2MQ=="),
            "https://herexxx.com/get_file/11/82416a608d4155c999c35eced86d8702/887000/887557/887557.mp4/?br=361"
        );
    }

    #[test]
    fn cards_parse_kvs_thumb() {
        let html = r#"<div class="thumbs">
        <div class="item thumb">
            <a href="https://herexxx.com/video/887557/짧-미모의-정병-멘헤라녀-ㅈㅇ-인생도박-welcome-to-dobaklife/" title="짧 미모의 정병 멘헤라녀 ㅈㅇ - 인생도박" class="th">
                <span class="wrap_image th img">
                    <img class="lazy-load" src="data:image/gif;base64,xxx" data-original="https://herexxx.com/contents/videos_screenshots/887000/887557/644x362/1.jpg" width="644" height="362"/>
                    <span class="time">0:15</span>
                </span>
            </a>
        </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://herexxx.com/video/887557/짧-미모의-정병-멘헤라녀-ㅈㅇ-인생도박-welcome-to-dobaklife/"
        );
        assert_eq!(
            items[0]["cover"],
            "https://herexxx.com/contents/videos_screenshots/887000/887557/644x362/1.jpg"
        );
        assert_eq!(items[0]["remark"], "0:15");
    }

    #[test]
    fn iso_duration_formats() {
        assert_eq!(iso_duration("PT0H0M29S"), "0:29");
        assert_eq!(iso_duration("PT0H6M26S"), "6:26");
        assert_eq!(iso_duration(""), "");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest-updates", 1),
            "https://herexxx.com/latest-updates/"
        );
        assert_eq!(
            catalog_url("latest-updates", 2),
            "https://herexxx.com/latest-updates/2/"
        );
        assert_eq!(
            catalog_url("cat:korean-porn", 2),
            "https://herexxx.com/categories/korean-porn/2/"
        );
        assert_eq!(
            catalog_url("most-popular:video_viewed", 1),
            "https://herexxx.com/most-popular/?sort_by=video_viewed"
        );
        assert_eq!(
            catalog_url("most-popular:video_viewed_today", 2),
            "https://herexxx.com/most-popular/2/?sort_by=video_viewed_today"
        );
    }

    #[test]
    fn abs_url_protocol_relative() {
        assert_eq!(
            abs_url("//assets11.cdnhop.com/contents/videos_screenshots/887000/887557/preview.jpg"),
            "https://assets11.cdnhop.com/contents/videos_screenshots/887000/887557/preview.jpg"
        );
    }
}
