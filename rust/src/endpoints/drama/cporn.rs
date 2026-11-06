//! CartoonPorno（KVS 类站，site=cporn）。
//!
//! 与 jar 的 ZakaKvsAmns（site=cporn）一一对应：分类（最新更新＋
//! 34 个标签分类＋搜索热榜）、目录（/videos 与 /categories/{值}，
//! hl=zh）、详情（<title>、og:image、og:description、详情页
//! <source> 多清晰度直取 mp4，空则扫全页 mp4，再空则回退 embed 页）、
//! 搜索（/search?q=，第 1 页）、取流（直链透传）。
//! 注意：jar 的 ZakaGate 在此 jar 里是空实现，直接请求即可；
//! mp4 是几百兆大文件，jar 注明走本机流式中转，核心只回直链。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://www.cartoonporno.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("447/hentai", "成人动漫"),
    ("231/anime", "动漫"),
    ("217/3d", "3D"),
    ("218/3d-cartoon", "3D卡通"),
    ("197/manga", "漫画"),
    ("33/disney", "迪士尼"),
    ("576/parody", "恶搞"),
    ("338/creampie", "内射"),
    ("294/bukkake", "颜射"),
    ("276/blowjob", "口交"),
    ("381/facial", "颜射"),
    ("407/futanari", "扶他那利"),
    ("494/lesbian", "女同"),
    ("410/gangbang", "群交"),
    ("254/bdsm", "调教"),
    ("280/bondage", "束缚"),
    ("386/femdom", "女支配"),
    ("393/fisting", "拳交"),
    ("708/tits", "巨乳"),
    ("268/big-tits", "大胸"),
    ("234/ass", "美臀"),
    ("532/monster-cock", "巨根"),
    ("519/milf", "熟女"),
    ("514/mature", "成熟"),
    ("13/stepmom", "继母"),
    ("595/pregnant", "孕妇"),
    ("692/taboo", "禁忌"),
    ("730/uniform", "制服"),
    ("559/office", "办公室"),
    ("510/massage", "按摩"),
    ("474/japanese", "日本"),
    ("725/uncensored", "无码"),
    ("180/demons", "魔物"),
    ("376/erotic", "情色"),
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
        return Err(ApiError::Internal(format!(
            "CartoonPorno 请求 HTTP {status}"
        )));
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

/// 与 Java 的 isPreview 一致：预告/样片/缩略图。
fn is_preview(url: &str) -> bool {
    let lower = url.to_lowercase();
    lower.contains("preview") || lower.contains("_sample") || lower.contains("thumbs")
}

/// 与 Java 的 qualityLabel 一致。
fn quality_label(url: &str) -> String {
    let lower = url.to_lowercase();
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

/// 与 Java 的 qNum 一致：标签里的清晰度数字，用于排序。
fn q_num(label: &str) -> i64 {
    let upper = label.to_uppercase();
    if upper.contains("4K") && !upper.contains("2160") {
        return 2160;
    }
    for q in [1080_i64, 720, 480, 360] {
        if upper.contains(&q.to_string()) {
            return q;
        }
    }
    0
}

/// 与 Java 的 pickLink 一致（site=cporn 分支）。
fn pick_link(segment: &str) -> String {
    let re_href = Regex::new("href=\"([^\"]+)\"").unwrap();
    let re_v = Regex::new(".*?/v/[a-z0-9]{4,10}/?$").unwrap();
    let re_vnum = Regex::new(".*?/v/[0-9]{3,9}/[^\"']*").unwrap();
    for cap in re_href.captures_iter(segment) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if href.contains("embed") {
            continue;
        }
        let ok = (href.contains("/video/") && re_v.is_match(href))
            || re_vnum.is_match(href)
            || href.contains("/videos");
        if ok {
            return abs_url(href);
        }
    }
    String::new()
}

/// 与 Java 的 cardTitle 一致：a title → img alt → div.title → 链接 slug。
fn card_title(segment: &str, link: &str) -> String {
    let re_a_title = Regex::new("title=\"([^\"]*)\"").unwrap();
    let t = unesc(&first(&re_a_title, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let re_alt = Regex::new("<img[^>]*alt=\"([^\"]*)\"").unwrap();
    let t = unesc(&first(&re_alt, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let re_div = Regex::new("<div class=\"title\"[^>]*>([^<]{2,200})</div>").unwrap();
    let t = unesc(&first(&re_div, segment));
    if t.chars().count() > 1 {
        return t;
    }
    let after_q = link.split('?').next().unwrap_or(link);
    let slug = after_q.trim_end_matches('/');
    let slug = slug.rsplit('/').next().unwrap_or("").replace('-', " ");
    let slug = slug.trim().to_string();
    if slug.chars().count() > 1 {
        slug
    } else {
        "CartoonPorno".to_string()
    }
}

/// 与 Java 的 picOf 一致：data-src 等懒加载图优先，再取 img src。
fn pic_of(segment: &str) -> String {
    let re_lazy = Regex::new("data-(?:src|original|webp)=\"([^\"]+)\"").unwrap();
    let re_img = Regex::new("<img[^>]*src=\"([^\"]+)\"").unwrap();
    for re in [&re_lazy, &re_img] {
        for cap in re.captures_iter(segment) {
            let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            if raw.starts_with("data:image") || raw.contains("placeholder") {
                continue;
            }
            let url = abs_url(raw);
            if url.starts_with("http") {
                return url;
            }
        }
    }
    String::new()
}

/// 与 Java 的 durOf 一致。
fn dur_of(segment: &str) -> String {
    let re_dur = Regex::new("class=\"duracion\"[^>]*>\\s*([0-9:]{3,10})\\s*<").unwrap();
    let d = first(&re_dur, segment);
    if !d.is_empty() {
        return d;
    }
    let re_dur2 = Regex::new("class=\"duration\"[^>]*>\\s*([0-9:]{3,10})\\s*<").unwrap();
    first(&re_dur2, segment)
}

/// 与 Java 的 appendCards 一致（cardPattern 取 cporn 的 fdx 卡片）。
/// Rust 的 regex 不支持 look-ahead，改用开标签定位 + 切片，不用 (?=...)。
fn append_cards(html: &str, limit: usize) -> Vec<Value> {
    if html.len() < 200 {
        return Vec::new();
    }
    let re_open = Regex::new("<div class=\"item\"><a class=\"fdx\"").unwrap();
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
            for marker in ["<div class=\"pagination", "<section>", "<footer", "</body>"] {
                if let Some(p) = tail.find(marker) {
                    end = end.min(p);
                }
            }
            open_end + end
        };
        let segment = &html[open_end..seg_end];
        let link = pick_link(segment);
        if link.len() < 8 || !seen.insert(link.clone()) {
            continue;
        }
        let title = card_title(segment, &link);
        let cover = pic_of(segment);
        let dur = dur_of(segment);
        let remark = if dur.is_empty() {
            "cporn".to_string()
        } else {
            dur
        };
        items.push(item_json(&link, &title, &cover, &remark));
    }
    if items.is_empty() {
        items = fallback_cards(html, limit);
    }
    items
}

/// 与 Java 的 fallbackCards 等价：无卡片时直接扫页面链接。
fn fallback_cards(html: &str, limit: usize) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let re_href = Regex::new("href=\"([^\"]+)\"").unwrap();
    for cap in re_href.captures_iter(html) {
        if items.len() >= limit {
            break;
        }
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let link = abs_url(href);
        if link.len() < 8 || !seen.insert(link.clone()) {
            continue;
        }
        if !(link.contains("/v/") || link.contains("/videos")) {
            continue;
        }
        items.push(item_json(&link, "CartoonPorno", "", "cporn"));
    }
    items
}

/// 与 Java 的 scanAnyMp4 一致：扫全页 mp4（绝对地址与站内相对地址）。
fn scan_any_mp4(html: &str, seen: &mut HashSet<String>) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let re_any = Regex::new(
        "https?://[^\"'\\s<>\\\\]+?(?:get_file|jmpres|/videos?/)[^\"'\\s<>\\\\]*?\\.mp4/?[^\"'\\s<>\\\\]*",
    )
    .unwrap();
    for m in re_any.find_iter(html) {
        let url = unesc(m.as_str()).trim().to_string();
        if is_preview(&url) || !seen.insert(url.clone()) {
            continue;
        }
        let label = quality_label(&url);
        out.push((label, url));
    }
    let re_rel =
        Regex::new("/(?:get_file|jmpres)/[^\"'\\s<>\\\\]+?\\.mp4/?[^\"'\\s<>\\\\]*").unwrap();
    for m in re_rel.find_iter(html) {
        let url = format!("{HOST}{}", unesc(m.as_str()).trim());
        if is_preview(&url) || !seen.insert(url.clone()) {
            continue;
        }
        let label = quality_label(&url);
        out.push((label, url));
    }
    out
}

/// 与 Java 的 streams 一致：m3u8（最多 4 条）→ <source> → 全页 mp4 → embed 页。
async fn streams(html: &str) -> ApiResult<Vec<(String, String)>> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut list: Vec<(String, String)> = Vec::new();
    let re_m3u8 = Regex::new("https?://[^\"'\\s<>\\\\]+?\\.m3u8[^\"'\\s<>\\\\]*").unwrap();
    for m in re_m3u8.find_iter(html) {
        if list.len() >= 4 {
            break;
        }
        let url = unesc(m.as_str()).trim().to_string();
        let lower = url.to_lowercase();
        if lower.contains(".jpg") || lower.contains(".png") || lower.contains(".webp") {
            continue;
        }
        if !seen.insert(url.clone()) {
            continue;
        }
        list.push(("HLS".to_string(), url));
    }
    let re_source = Regex::new("<source[^>]*src=\"([^\"]+)\"[^>]*>").unwrap();
    let re_title = Regex::new("title=\"([^\"]*)\"").unwrap();
    let re_label = Regex::new("label=\"([^\"]*)\"").unwrap();
    let re_size = Regex::new("size=\"([0-9]{3,4})\"").unwrap();
    for cap in re_source.captures_iter(html) {
        let whole = cap.get(0).map(|m| m.as_str()).unwrap_or("");
        if whole.len() < 12 {
            continue;
        }
        let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let url = abs_url(raw);
        if url.len() < 12 || is_preview(&url) || !url.starts_with("http") {
            continue;
        }
        if !seen.insert(url.clone()) {
            continue;
        }
        let mut label = first(&re_title, whole);
        if label.is_empty() {
            label = first(&re_label, whole);
        }
        if label.is_empty() {
            let size = first(&re_size, whole);
            if !size.is_empty() {
                label = format!("{size}P");
            }
        }
        if label.is_empty() {
            label = quality_label(&url);
        }
        list.push((label, url));
    }
    if list.is_empty() {
        list.extend(scan_any_mp4(html, &mut seen));
    }
    if list.is_empty() {
        let re_embed = Regex::new("(?:https?://[^\"'\\s]+)?/embed/(\\d+)").unwrap();
        if let Some(cap) = re_embed.captures(html) {
            let id = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            if let Ok(embed_html) = fetch_text(&format!("{HOST}/embed/{id}")).await {
                list.extend(scan_any_mp4(&embed_html, &mut seen));
            }
        }
    }
    // 与 Java 的 streams 末尾一致：带清晰度数字的在前、按数字降序，
    // 其余按原顺序在后。
    let (mut with_q, mut without_q): (Vec<(String, String)>, Vec<(String, String)>) =
        list.into_iter().partition(|(label, _)| q_num(label) > 0);
    with_q.sort_by(|a, b| q_num(&b.0).cmp(&q_num(&a.0)));
    with_q.append(&mut without_q);
    Ok(with_q)
}

fn category_url(category_id: &str, page: i64) -> String {
    if category_id == "new" {
        format!("{HOST}/videos?hl=zh&p={page}")
    } else if category_id == "hot" {
        format!("{HOST}/search?q=anal&hl=zh&p={page}")
    } else if let Some(rest) = category_id.strip_prefix("c:") {
        format!("{HOST}/categories/{rest}?hl=zh&p={page}")
    } else {
        format!("{HOST}/videos?hl=zh&p={page}")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = vec![category_json("new", "最新更新")];
    for (value, name) in CATS {
        list.push(category_json(&format!("c:{value}"), name));
    }
    list.push(category_json("hot", "搜索热榜"));
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = category_url(category_id, page);
    let html = fetch_text(&url).await?;
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
    let re_title = Regex::new("<title>(.*?)</title>").unwrap();
    let mut title = unesc(&first(&re_title, &html));
    if let Some(pos) = title.rfind(" - ") {
        if pos > 4 {
            title.truncate(pos);
        }
    }
    let title = title.trim().to_string();
    let title = if title.is_empty() {
        "CartoonPorno 影片".to_string()
    } else {
        title
    };
    let re_og_img = Regex::new("property=\"og:image\" content=\"([^\"]*)\"").unwrap();
    let cover = abs_url(&first(&re_og_img, &html));
    let re_og_desc = Regex::new("property=\"og:description\" content=\"([^\"]*)\"").unwrap();
    let synopsis = unesc(&first(&re_og_desc, &html));
    let list = streams(&html).await?;
    if list.is_empty() {
        return Err(ApiError::Internal("CartoonPorno 未返回可播放分集".into()));
    }
    let episodes: Vec<Value> = list
        .iter()
        .map(|(label, url)| episode_json(url, &format!("CartoonPorno·{label}"), series_id))
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
        Err(ApiError::Internal("CartoonPorno 该集没有播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{HOST}/search"),
        &[("q", query), ("hl", "zh"), ("p", "1")],
    );
    let html = fetch_text(&url).await?;
    let items = append_cards(&html, 40);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_labels_and_qnum() {
        assert_eq!(quality_label("https://x/a_1080.mp4"), "1080P");
        assert_eq!(quality_label("https://x/a.mp4"), "Auto");
        assert_eq!(q_num("1080P"), 1080);
        assert_eq!(q_num("Auto"), 0);
    }

    #[test]
    fn is_preview_rules() {
        assert!(is_preview("https://x/preview.mp4"));
        assert!(is_preview("https://x/a_sample.mp4"));
        assert!(!is_preview("https://x/video01.mp4"));
    }

    #[test]
    fn category_url_forms() {
        assert_eq!(
            category_url("c:447/hentai", 2),
            "https://www.cartoonporno.cc/categories/447/hentai?hl=zh&p=2"
        );
        assert_eq!(
            category_url("new", 1),
            "https://www.cartoonporno.cc/videos?hl=zh&p=1"
        );
    }
}
