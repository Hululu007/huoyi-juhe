//! TinyAV：核心里的影视区站点。
//!
//! Drupal 站（https://tinyavideo.com，免費高清AV線上看）：分组
//! ×排序的导航，分类取分组一级（每组进最近更新）＋中文字幕＋
//! 女优总览/发行商两个索引；列表 12 条一页、Drupal ?page=N
//! 翻页（0 起）；详情页 window.m3u8List 里第一条即为 m3u8
//! （t0.97img.com，清单 200、首分片 200，已验）；搜索走
//! /search?fulltext=。站内无萝莉分类，标签含萝莉/幼女/未成
//! 年词的单片在列表、搜索与详情三处过滤。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://tinyavideo.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态表：与站导航一致，实测于 2026-11-05。分组进最近
/// 更新页；女优/发行商为索引页，目录返回 folder 卡。
const CATS: &[(&str, &str)] = &[
    ("asian/new", "國產AV"),
    ("japanese/new", "日本AV"),
    ("uncensored-leak/new", "JAV無碼"),
    ("fc2/new", "FC2素人"),
    ("ai/new", "AI短劇"),
    ("hentai/new", "裏番"),
    ("western/new", "歐美"),
    ("korean/new", "韓國"),
    ("chinese-subtitles", "中文字幕"),
    ("actresses/asian", "女優總覽·國產"),
    ("actresses/japanese", "女優總覽·日本AV"),
    ("maker/asian", "發行商·國產"),
    ("maker/japanese", "發行商·日本AV"),
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
        return Err(ApiError::Internal(format!("TinyAV 请求 HTTP {status}")));
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

fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

fn blocked(text: &str) -> bool {
    text.contains("萝莉") || text.contains("幼女") || text.contains("未成年")
}

/// 视频卡片：.cf 块里的 /video/<slug> 链接，封面与标题取
/// img 的 src/alt，备注取 🔥 观看数。
fn parse_video_cards(html: &str) -> Vec<Value> {
    let link_re = match Regex::new(r#"href="(/video/[^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)""#).ok();
    let title_re = Regex::new(r#"videotitle"><a[^>]*>([^<]+)</a>"#).ok();
    let count_re = Regex::new(r#"count-number">([^<]+)<"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in link_re.captures_iter(html) {
        let vid = cap[1].to_string();
        if !seen.insert(vid.clone()) {
            continue;
        }
        let start = match cap.get(0) {
            Some(m) => m.start(),
            None => continue,
        };
        let end = (start + 2500).min(html.len());
        let window = &html[start..end];
        let mut cover = String::new();
        let mut title = String::new();
        if let Some(re) = &img_re {
            if let Some(m) = re.captures(window) {
                cover = fix_url(&m[1]);
                title = unescape(m[2].trim());
            }
        }
        if title.is_empty() {
            if let Some(re) = &title_re {
                if let Some(m) = re.captures(window) {
                    title = unescape(m[1].trim());
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        if blocked(&title) {
            continue;
        }
        let remark = match &count_re {
            Some(re) => re
                .captures(window)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

/// 索引卡片：.tiop 块里的女优/发行商，返回 folder 卡。
fn parse_person_cards(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"(?s)<div class="tiop[^"]*">.*?<a href="(/actress/[^"]+|/maker/[^"]+)"[^>]*>([^<]+)</a>.*?<span>([\d,]+) 部影片</span>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in re.captures_iter(html) {
        let href = cap[1].to_string();
        if !seen.insert(href.clone()) {
            continue;
        }
        if href == "/maker/asian" || href == "/maker/japanese" {
            continue;
        }
        let name = unescape(cap[2].trim());
        if name.is_empty() || blocked(&name) {
            continue;
        }
        let remark = format!("{} 部影片", &cap[3]);
        let mut item = item_json(&format!("folder@{href}"), &name, "", &remark);
        if let Some(obj) = item.as_object_mut() {
            obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
        }
        items.push(item);
    }
    items
}

fn extract_m3u8(html: &str) -> String {
    let list_re = match Regex::new(r"(?s)window\.m3u8List\s*=\s*\[(.*?)\]") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let cap = match list_re.captures(html) {
        Some(c) => c,
        None => return String::new(),
    };
    let url_re = match Regex::new(r#"(https?://[^"']+\.m3u8[^"']*)"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match url_re.captures(&cap[1]) {
        Some(m) => m[1].to_string(),
        None => String::new(),
    }
}

/// 详情页标签：field-video-tags 区域内的 #标签。
fn extract_tags(html: &str) -> Vec<String> {
    let start = match html.find("field-video-tags") {
        Some(i) => i,
        None => return Vec::new(),
    };
    let end = (start + 2000).min(html.len());
    let region = &html[start..end];
    let re = match Regex::new(r"#([^<\s]{1,30})") {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut tags = Vec::new();
    for cap in re.captures_iter(region) {
        let tag = cap[1].trim().to_string();
        if !tag.is_empty() && seen.insert(tag.clone()) {
            tags.push(tag);
        }
    }
    tags
}

fn video_url(series_id: &str) -> String {
    let id = series_id.trim();
    if id.starts_with("http") {
        id.to_string()
    } else if let Some(rest) = id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{id}")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = with_query(
        &format!("{BASE}/{category_id}"),
        &[("page", &(page - 1).to_string())],
    );
    let html = get_text(&url).await?;
    let is_index = category_id.starts_with("actresses/") || category_id.starts_with("maker/");
    let items = if is_index {
        parse_person_cards(&html)
    } else {
        parse_video_cards(&html)
    };
    let has_more = html.contains(&format!("?page={page}\""));
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim();
    if let Some(folder) = id.strip_prefix("folder@") {
        let html = get_text(&video_url(folder)).await?;
        let cards = parse_video_cards(&html);
        let title = match Regex::new(r"<title[^>]*>(.*?)</title>") {
            Ok(re) => re
                .captures(&html)
                .map(|m| unescape(m[1].trim().split(" | ").next().unwrap_or("")))
                .unwrap_or_default(),
            Err(_) => String::new(),
        };
        let episodes: Vec<Value> = cards
            .iter()
            .filter_map(|entry| {
                let vid = entry.get("id")?.as_str()?.to_string();
                let name = entry.get("title")?.as_str()?.to_string();
                Some(episode_json(&vid, &name, id))
            })
            .collect();
        if episodes.is_empty() {
            return Err(ApiError::Internal("TinyAV 该索引下没有视频".into()));
        }
        return Ok(json!({
            "id": id,
            "title": title,
            "cover": "",
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let url = video_url(id);
    let html = get_text(&url).await?;
    let title = match Regex::new(r#"(?s)<h1[^>]*class="[^"]*vdtitle[^"]*"[^>]*>(.*?)</h1>"#) {
        Ok(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        Err(_) => String::new(),
    };
    let tags = extract_tags(&html);
    if tags.iter().any(|t| blocked(t)) {
        return Err(ApiError::Internal("TinyAV 该片已过滤".into()));
    }
    let cover = match Regex::new(r#"<video[^>]*poster="([^"]+)""#) {
        Ok(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        Err(_) => String::new(),
    };
    let mut synopsis = String::new();
    for (label, pat) in [
        ("發行日期", r"發行日期\s*</div>\s*<div[^>]*>\s*([\d-]+)"),
        (
            "影片類型",
            r"影片類型\s*</div>\s*<div[^>]*>\s*([^<]+?)\s*</div>",
        ),
        ("頻道", r"頻道\s*</div>\s*<div[^>]*>\s*([^<]+?)\s*</div>"),
    ] {
        if let Ok(re) = Regex::new(pat) {
            if let Some(cap) = re.captures(&html) {
                let v = unescape(cap[1].trim());
                if !v.is_empty() {
                    if !synopsis.is_empty() {
                        synopsis.push_str(" / ");
                    }
                    synopsis.push_str(&format!("{label}：{v}"));
                }
            }
        }
    }
    if !tags.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push_str(" / ");
        }
        synopsis.push_str(&format!("標籤：{}", tags.join("、")));
    }
    let m3u8 = extract_m3u8(&html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("TinyAV 未返回可播放地址".into()));
    }
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&m3u8, "播放", id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("fulltext", query)]);
    let html = get_text(&url).await?;
    let items = parse_video_cards(&html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        let html = get_text(&video_url(video_id)).await?;
        let found = extract_m3u8(&html);
        if found.is_empty() {
            return Err(ApiError::Internal("TinyAV 未取到播放地址".into()));
        }
        found
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_video_cards_reads_cover_title_count() {
        let html = r#"<div class="cf col-6"><div class="video-thumbnail-container"><a href="/video/75709"><img loading="lazy" src="/sites/default/files/styles/jav_large/public/video/b1000465.jpg.webp?itok=YsvllT1S" alt="巨乳玩物一看就知道是個性慾旺盛的公共廁所" /></a><div class="video-badge"><span class="count-number">🔥 17</span></div></div><div class="videotitle"><a href="/video/75709">巨乳玩物一看就知道是個性慾旺盛的公共廁所</a></div></div><div class="cf col-6"><div class="video-thumbnail-container"><a href="/video/99999"><img src="/sites/default/files/video/x.jpg" alt="萝莉标题测试片" /></a></div></div>"#;
        let items = parse_video_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/video/75709");
        assert_eq!(
            items[0]["title"],
            "巨乳玩物一看就知道是個性慾旺盛的公共廁所"
        );
        assert_eq!(
            items[0]["cover"],
            "https://tinyavideo.com/sites/default/files/styles/jav_large/public/video/b1000465.jpg.webp?itok=YsvllT1S"
        );
        assert_eq!(items[0]["remark"], "🔥 17");
    }

    #[test]
    fn parse_person_cards_folder_ids() {
        let html = r#"<div class="tiop col-12"><div class="views-field views-field-name"><span class="field-content"><a href="/actress/%E5%AD%9F%E8%8B%A5%E7%BE%BD" hreflang="zh-hant">孟若羽</a></span></div><div><span>245 部影片</span></div></div>"#;
        let items = parse_person_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "folder@/actress/%E5%AD%9F%E8%8B%A5%E7%BE%BD"
        );
        assert_eq!(items[0]["title"], "孟若羽");
        assert_eq!(items[0]["remark"], "245 部影片");
        assert_eq!(items[0]["vod_tag"], "folder");
    }

    #[test]
    fn extract_m3u8_first_source() {
        let html =
            "window.m3u8List = [\n          \"https://t0.97img.com/b1000465/a.m3u8\"      ];";
        assert_eq!(extract_m3u8(html), "https://t0.97img.com/b1000465/a.m3u8");
        assert_eq!(extract_m3u8("window.m3u8List = [];"), "");
    }

    #[test]
    fn categories_has_13() {
        assert_eq!(CATS.len(), 13);
        assert_eq!(CATS[0], ("asian/new", "國產AV"));
        assert_eq!(CATS[8], ("chinese-subtitles", "中文字幕"));
        assert_eq!(CATS[12], ("maker/japanese", "發行商·日本AV"));
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/sites/default/files/video/a.jpg"),
            "https://tinyavideo.com/sites/default/files/video/a.jpg"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }
}
