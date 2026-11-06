//! Xanimu：里番动漫站。
//!
//! 与 jar 的 ZakaXanimuAmns 一一对应：分类（22 个标签分类＋热门）、
//! 目录（/zh-CN/{标签}/，翻页取页内“2”号链接再换页码）、详情
//! （h1 标题、海报、详情页播放器直给 mp4，_high/_low 两档，
//! 预告片剔除）、搜索（/zh-CN/?s=，第 1 页）、取流（直链透传）。
//! 注意：jar 的 ZakaGate 在此 jar 里是空实现，直接请求即可；
//! 站方 CDN 对机器请求有人机校验，本机出口实测 mp4 直链回 403，
//! 列表/详情/搜索已验，播放须手机侧复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://xanimu.one";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("5-3d-%E6%97%A0%E5%B0%BD/", "3D 无尽"),
    ("47441-hmv/", "HMV"),
    ("8-futanari-%E6%97%A0%E5%B0%BD/", "扶他"),
    ("9476-yaoi-%E6%97%A0%E5%B0%BD/", "Yaoi"),
    ("13-%E6%80%AA%E7%89%A9%E6%97%A0%E5%B0%BD/", "怪物"),
    ("7-%E8%A7%A6%E6%89%8B%E6%97%A0%E5%B0%BD/", "触手"),
    ("6-%E4%B9%B1%E4%BC%A6%E6%97%A0%E5%B0%BD/", "乱伦"),
    (
        "10-%E5%A5%B3%E5%B7%A8%E4%BA%BA%E6%97%A0%E5%B0%BD/",
        "女巨人",
    ),
    (
        "4-%E6%AF%9B%E8%8C%B8%E8%8C%B8%E7%9A%84%E6%97%A0%E5%B0%BD/",
        "毛茸茸",
    ),
    ("5519%E6%97%A0%E5%B0%BD%E7%9A%84/", "无尽合集"),
    ("22%E6%B8%B8%E6%88%8F/", "游戏"),
    ("23%E7%94%B5%E5%BD%B1/", "电影"),
    ("16884%E4%B8%AA%E7%81%B5%E9%AD%82/", "动漫灵魂"),
    ("47420%E6%AF%AB%E7%B1%B3/", "MMD 毫米"),
    ("40241%E5%8D%A1%E9%80%9A/", "卡通"),
    ("16704-%E9%AD%85%E9%AD%94/", "魅魔"),
    ("14975%E9%BE%99/", "龙"),
    ("47418%E5%A4%96%E6%98%9F%E4%BA%BA/", "外星人"),
    (
        "24-%E9%83%A8%E7%94%B5%E8%A7%86%E8%8A%82%E7%9B%AE/26-pokemon/",
        "Pokemon",
    ),
    ("614-naruto-2/", "Naruto"),
    ("9478-%E9%A9%AC-hentai/", "马 Hentai"),
    ("4875-%E8%A7%86%E9%A2%91%E6%BC%94%E5%91%98/", "视频演员"),
];

/// 与 Java 的 head 一致。
fn headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        (
            "Accept-Language".to_string(),
            "zh-CN,zh;q=0.9,en;q=0.8".to_string(),
        ),
        ("Cookie".to_string(), "x-index-auth=authed".to_string()),
        ("Referer".to_string(), format!("{HOST}/")),
    ]
}

async fn fetch_text(url: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Xanimu 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 ZakaAvjoyAmns.unesc 一致。
fn unesc(raw: &str) -> String {
    raw.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#x2F;", "/")
}

/// 与 Java 的 u 一致：// 补 https:，/ 开头补站址。
fn abs_url(raw: &str) -> String {
    let s = unesc(raw).trim().to_string();
    if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = s.strip_prefix('/') {
        format!("{HOST}{rest}")
    } else {
        s
    }
}

fn first(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

fn strip_tags(raw: &str) -> String {
    let re = Regex::new("<[^>]+>").unwrap();
    unesc(re.replace_all(raw, "").trim())
}

/// 与 Java 的 qualityLabel 一致（另加 _high/_low 两档）。
fn quality_label(url: &str) -> String {
    let lower = url.to_lowercase();
    if lower.contains("_high") {
        return "高清".to_string();
    }
    if lower.contains("_low") {
        return "标清".to_string();
    }
    if lower.contains("2160") || lower.contains("4k") {
        return "4K".to_string();
    }
    for q in ["1080", "720", "480", "360"] {
        if lower.contains(q) {
            return format!("{q}P");
        }
    }
    "Auto".to_string()
}

/// 与 Java 的 pickLink 一致：只认 /zh-CN/{数字}-{slug}/ 形链接。
fn pick_link(segment: &str) -> String {
    let re_href = Regex::new("href=\"([^\"]+)\"").unwrap();
    let re_ok = Regex::new(".*?/zh-CN/\\d+-[^/]+/?$").unwrap();
    for cap in re_href.captures_iter(segment) {
        let mut href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if let Some(pos) = href.find('?') {
            href = &href[..pos];
        }
        if re_ok.is_match(href) {
            return abs_url(href);
        }
    }
    String::new()
}

/// 与 Java 的 cardTitle 一致：img alt 优先，否则取链接 slug。
fn card_title(segment: &str) -> String {
    let re_alt = Regex::new("<img[^>]*alt=\"([^\"]*)\"").unwrap();
    let title = unesc(&first(&re_alt, segment));
    if title.chars().count() > 1 {
        return title;
    }
    let re_href = Regex::new("href=\"([^\"]+)\"").unwrap();
    let href = first(&re_href, segment);
    let slug = href.trim_end_matches('/');
    let slug = slug.rsplit('/').next().unwrap_or("").replace('-', " ");
    let slug = slug.trim().to_string();
    if slug.chars().count() > 1 {
        slug
    } else {
        "Xanimu".to_string()
    }
}

/// 与 Java 的 picOf 一致：首个非 data:image、非 placeholder 的 http 图。
fn pic_of(segment: &str) -> String {
    let re_img = Regex::new("<img[^>]*src=\"([^\"]+)\"").unwrap();
    for cap in re_img.captures_iter(segment) {
        let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if raw.contains("data:image") || raw.contains("placeholder") {
            continue;
        }
        let url = abs_url(raw);
        if url.starts_with("http") {
            return url;
        }
    }
    String::new()
}

/// 与 Java 的 appendCards 一致。
/// Rust 的 regex 不支持 look-ahead，改用开标签定位 + 切片，不用 (?=...)。
fn append_cards(html: &str, limit: usize) -> Vec<Value> {
    let re_open = Regex::new("<div class=\"video-block[^\"]*\">").unwrap();
    let opens: Vec<(usize, usize)> = re_open
        .find_iter(html)
        .map(|m| (m.start(), m.end()))
        .collect();
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for (idx, &(_, open_end)) in opens.iter().enumerate() {
        if items.len() >= limit {
            break;
        }
        let seg_end = if idx + 1 < opens.len() {
            opens[idx + 1].0
        } else {
            let tail = &html[open_end..];
            let mut end = tail.len();
            for marker in ["</main>", "<footer", "</body>"] {
                if let Some(p) = tail.find(marker) {
                    end = end.min(p);
                }
            }
            open_end + end
        };
        let segment = &html[open_end..seg_end];
        let link = pick_link(segment);
        if link.is_empty() || !seen.insert(link.clone()) {
            continue;
        }
        let title = card_title(segment);
        let cover = pic_of(segment);
        items.push(item_json(&link, &title, &cover, "Xanimu"));
    }
    items
}

/// 与 Java 的 pagedUrl 一致：取页内“2”号链接，把尾部 /2/ 换成目标页码。
fn paged_url(page1_html: &str, page: i64) -> Option<String> {
    let re = Regex::new("href=\"([^\"]+?/2/)\"[^>]*>\\s*2\\s*<").unwrap();
    let link = first(&re, page1_html);
    if link.is_empty() {
        return None;
    }
    let re_tail = Regex::new("/2/?$").unwrap();
    Some(re_tail.replace(&link, &format!("/{page}/")).to_string())
}

fn category_url(category_id: &str) -> String {
    if category_id == "hot" {
        format!("{HOST}/zh-CN/")
    } else if let Some(rest) = category_id.strip_prefix("c:") {
        format!("{HOST}/zh-CN/{rest}")
    } else {
        format!("{HOST}/zh-CN/")
    }
}

/// 与 Java 的 addLine 一致：只收 mp4，剔预告/海报图。
fn streams(html: &str) -> Vec<(String, String)> {
    let re_mp4 = Regex::new("https?://[^\"'\\s<>\\\\)]+?\\.mp4[^\"'\\s<>\\\\)]*").unwrap();
    let mut out: Vec<(String, String)> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for m in re_mp4.find_iter(html) {
        let url = unesc(m.as_str()).trim().to_string();
        if url.len() < 12 {
            continue;
        }
        let lower = url.to_lowercase();
        if lower.contains("trailer") || lower.contains("preview") || lower.contains("_poster") {
            continue;
        }
        if !lower.contains(".mp4") || !seen.insert(url.clone()) {
            continue;
        }
        let label = quality_label(&url);
        out.push((label, url));
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = CATS
        .iter()
        .map(|(value, name)| category_json(&format!("c:{value}"), name))
        .collect();
    list.push(category_json("hot", "热门"));
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let base = category_url(category_id);
    let html = if page == 1 {
        fetch_text(&base).await?
    } else {
        let first_page = fetch_text(&base).await?;
        match paged_url(&first_page, page) {
            Some(url) => fetch_text(&url).await?,
            None => {
                return Ok(json!({"items": [], "has_more": false}));
            }
        }
    };
    let items = append_cards(&html, 60);
    let has_more = items.len() >= 12;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{HOST}/{rest}")
    } else {
        format!("{HOST}/{series_id}")
    };
    let html = fetch_text(&url).await?;
    let re_h1 = Regex::new("<h1[^>]*>(.*?)</h1>").unwrap();
    let title = strip_tags(&first(&re_h1, &html));
    let title = if title.is_empty() {
        "Xanimu 影片".to_string()
    } else {
        title
    };
    let re_poster = Regex::new("<video[^>]+poster=\"([^\"]+)\"").unwrap();
    let cover = abs_url(&first(&re_poster, &html));
    let re_bread = Regex::new("<span class=\"[^\"]*bread[^\"]*\"[^>]*>(.*?)</span>").unwrap();
    let synopsis = strip_tags(&first(&re_bread, &html));
    let list = streams(&html);
    if list.is_empty() {
        return Err(ApiError::Internal("Xanimu 未返回可播放分集".into()));
    }
    let episodes: Vec<Value> = list
        .iter()
        .map(|(label, url)| episode_json(url, &format!("Xanimu·{label}"), series_id))
        .collect();
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("Xanimu 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{HOST}/zh-CN/"), &[("s", query)]);
    let html = fetch_text(&url).await?;
    let items = append_cards(&html, 48);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_labels() {
        assert_eq!(quality_label("https://x/a_high.mp4"), "高清");
        assert_eq!(quality_label("https://x/a_low.mp4"), "标清");
        assert_eq!(quality_label("https://x/a_1080.mp4"), "1080P");
        assert_eq!(quality_label("https://x/a.mp4"), "Auto");
    }

    #[test]
    fn paged_url_replaces_tail() {
        let html = "<a href=\"https://xanimu.one/zh-CN/abc/2/\">2</a>";
        assert_eq!(
            paged_url(html, 5).unwrap(),
            "https://xanimu.one/zh-CN/abc/5/"
        );
        assert!(paged_url("<a href=\"/x/\">3</a>", 2).is_none());
    }

    #[test]
    fn streams_filter_trailer() {
        let html =
            "a https://cdn/t/trailer.mp4 b https://cdn/v/a_high.mp4 c https://cdn/v/a_high.mp4";
        let list = streams(html);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].0, "高清");
    }

    #[test]
    fn category_url_forms() {
        assert_eq!(
            category_url("c:5-3d-%E6%97%A0%E5%B0%BD/"),
            "https://xanimu.one/zh-CN/5-3d-%E6%97%A0%E5%B0%BD/"
        );
        assert_eq!(category_url("hot"), "https://xanimu.one/zh-CN/");
    }
}
