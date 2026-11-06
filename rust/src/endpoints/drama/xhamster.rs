//! xHamster：静态 HTML 站，列表按 video-thumb 卡片切块。
//!
//! 与 Dart 的 ZakaXhamsterAmns 一一对应。分类与站内导航 1:1（21 项，
//! 含文件夹分类：全部主题 /categories、女优库 /pornstars、片商频道
//! /channels）。分页：路径后补 `/` + 页码，如 /newest/2。
//! 详情页取 og:title / og:image 与 preload 的 m3u8；分集 video_id
//! 用详情页路径（/videos/...），play() 重取详情页拿新鲜签名清单。
//! 清单播放须带头：Referer 为页面所在 host + "/"，UA 为 Chrome 131。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: &[&str] = &[
    "https://zh.xhamster1.art",
    "https://zh.xhamster1.one",
    "https://zh.xhamster1.net",
    "https://zh.xhamster1.vip",
    "https://zh.xhamster1.nl",
    "https://zh.xhamster1.icu",
    "https://zh.xv123.xyz",
    "https://zh.xv123.top",
    "https://zh.xv123.icu",
    "https://zh.xhamster.ist",
    "https://zh.xhamster1.top",
    "https://zh.xhamster1.cc",
    "https://zh.xhamster1.pw",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[路径, 名]，与站内导航 1:1；folder@ 为文件夹分类。
const CATEGORIES: &[(&str, &str)] = &[
    ("/newest", "最新上传"),
    ("/best/weekly", "本周最佳"),
    ("/best/monthly", "本月最佳"),
    ("/categories/caption", "中文字幕"),
    ("/categories/jav", "日本AV"),
    ("/categories/asian", "亚洲"),
    ("/categories/uncensored", "无码"),
    ("/categories/amateur", "素人自拍"),
    ("/categories/homemade", "家庭自制"),
    ("/categories/lesbian", "女同"),
    ("/categories/anal", "肛交"),
    ("/categories/creampie", "内射"),
    ("/categories/hentai", "成人动漫"),
    ("/categories/3d", "3D动画"),
    ("/categories/retro", "怀旧经典"),
    ("/categories/webcam", "在线直播"),
    ("/4k/newest", "4K专区"),
    ("/hd/newest", "高清HD"),
    ("folder@/categories", "全部主题"),
    ("folder@/pornstars", "女优库"),
    ("folder@/channels", "片商频道"),
];

/// 是否像 Cloudflare 拦截页。
fn is_challenge(body: &str) -> bool {
    let lower = body.to_lowercase();
    lower.contains("just a moment")
        || lower.contains("cf_chl")
        || lower.contains("challenge-form")
        || lower.contains("attention required")
        || body.contains("继续访问")
}

/// 正文可用：够长且无 CF 挑战标记。
fn looks_ok(body: &str) -> bool {
    body.len() >= 3000 && !is_challenge(body)
}

/// 按顺序试各 host，首个返回可用正文的即用；返回（所用 host，正文）。
async fn fetch(path: &str) -> ApiResult<(String, String)> {
    let mut last_err = ApiError::Internal("xHamster 请求失败".into());
    for host in HOSTS {
        let url = if path.starts_with("http") {
            path.to_string()
        } else {
            format!("{host}{path}")
        };
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .header("Upgrade-Insecure-Requests", "1")
            .header("Referer", format!("{host}/"))
            .send()
            .await;
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if resp.status().as_u16() != 200 {
            last_err = ApiError::Internal(format!("xHamster HTTP {}", resp.status().as_u16()));
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if !looks_ok(&text) {
            last_err = ApiError::Internal("xHamster 返回内容不可用".into());
            continue;
        }
        return Ok((host.to_string(), text));
    }
    Err(last_err)
}

/// 解常见 HTML 实体。
fn unesc(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 路径转编码：空格成 +，中文成 %XX（与 Java 的 URLEncoder 一致）。
fn enc_segment(raw: &str) -> String {
    url::form_urlencoded::byte_serialize(raw.as_bytes()).collect()
}

/// 分页：页<=1 原样，否则路径后补 / + 页码。
fn page_url(path: &str, page: i64) -> String {
    if page <= 1 {
        return path.to_string();
    }
    let base = path.trim_end_matches('/');
    format!("{base}/{page}")
}

/// 视频卡片：按 video-thumb__image-container 切块取字段。
fn parse_cards(html: &str) -> Vec<Value> {
    let href_re = Regex::new(r#"href="([^"]*?(/videos/[^"?#]+))""#).unwrap();
    let label_re = Regex::new(r#"aria-label="([^"]+)""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+(?:data-src|src)="([^"]+)""#).unwrap();
    let dur_re = Regex::new(r"(?s)video-duration.*?>\s*([^<]{1,12}?)\s*<").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("video-thumb__image-container").skip(1) {
        let href = match href_re.captures(block) {
            Some(c) => c.get(2).map(|m| m.as_str().to_string()).unwrap_or_default(),
            None => continue,
        };
        if href.is_empty() || seen.contains(&href) {
            continue;
        }
        seen.push(href.clone());
        let title = label_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(m.as_str()))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let cover = img_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        out.push(item_json(&href, &title, &cover, &remark));
    }
    out
}

/// 文件夹条目：取 /channels、/categories、/pornstars 下的链接作文件夹卡。
fn parse_folders(html: &str, prefix: &str) -> Vec<Value> {
    let pattern = format!(r#"href="({}[^"?#]+)"[^>]*>\s*([^<]{{1,60}}?)\s*<"#, prefix);
    let re = Regex::new(&pattern).unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for cap in re.captures_iter(html) {
        let path = cap
            .get(1)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let name = cap.get(2).map(|m| unesc(m.as_str())).unwrap_or_default();
        if path.is_empty() || name.is_empty() || seen.contains(&path) {
            continue;
        }
        seen.push(path.clone());
        let id = format!("folder@{path}");
        out.push(item_json(&id, &name, "", "文件夹"));
    }
    out
}

/// 详情页取新鲜 m3u8：先找 preload，再全页扫 m3u8 直链。
fn extract_hls(html: &str) -> Option<String> {
    let preload = Regex::new(r#"<link[^>]+rel="preload"[^>]+href="([^"]+\.m3u8[^"]*)""#).unwrap();
    if let Some(c) = preload.captures(html) {
        return c.get(1).map(|m| m.as_str().to_string());
    }
    let any = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#).unwrap();
    any.find(html).map(|m| m.as_str().to_string())
}

/// 详情页取 og:title，三级回退：双引号 og:title、单引号、<title>。
fn extract_title(html: &str) -> String {
    let og = Regex::new(r#"<meta[^>]+property="og:title"[^>]+content="([^"]+)""#).unwrap();
    if let Some(c) = og.captures(html) {
        return unesc(c.get(1).map(|m| m.as_str()).unwrap_or(""));
    }
    let og_sq = Regex::new(r#"<meta[^>]+property='og:title'[^>]+content='([^']+)'"#).unwrap();
    if let Some(c) = og_sq.captures(html) {
        return unesc(c.get(1).map(|m| m.as_str()).unwrap_or(""));
    }
    let title = Regex::new(r"(?s)<title>\s*(.*?)\s*</title>").unwrap();
    title
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

fn extract_og_image(html: &str) -> String {
    let og = Regex::new(r#"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#).unwrap();
    og.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

/// 取 /pornstars/<名> 与 /channels/<名> 链接的显示名。
fn extract_names(html: &str, prefix: &str) -> Vec<String> {
    let pattern = format!(r#"href="{}([^"/\?#]+)"[^>]*>([^<]{{1,60}}?)<"#, prefix);
    let re = Regex::new(&pattern).unwrap();
    let mut out: Vec<String> = Vec::new();
    for cap in re.captures_iter(html) {
        let name = cap.get(2).map(|m| unesc(m.as_str())).unwrap_or_default();
        if !name.is_empty() && !out.contains(&name) {
            out.push(name);
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(path, name)| category_json(path, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let mut tid = category_id.trim().to_string();
    if let Some(rest) = tid.strip_prefix("folder@") {
        tid = rest.to_string();
    }
    if tid.is_empty() {
        tid = "/newest".to_string();
    }
    let is_folder_root = matches!(tid.as_str(), "/categories" | "/pornstars" | "/channels");
    let url = page_url(&tid, page);
    let (_host, html) = fetch(&url).await?;
    let mut cards: Vec<Value> = Vec::new();
    let mut is_folder = false;
    if is_folder_root && page <= 1 {
        let prefix = match tid.as_str() {
            "/channels" => "/channels/",
            "/pornstars" => "/pornstars/",
            _ => "/categories/",
        };
        cards = parse_folders(&html, prefix);
        is_folder = true;
    } else {
        cards = parse_cards(&html);
        if cards.is_empty() {
            let prefix = match tid.as_str() {
                "/channels" => "/channels/",
                "/pornstars" => "/pornstars/",
                _ => "/categories/",
            };
            let folders = parse_folders(&html, prefix);
            if !folders.is_empty() {
                cards = folders;
                is_folder = true;
            }
        }
    }
    let has_more = if is_folder { false } else { cards.len() >= 20 };
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = series_id.trim();
    let (_host, html) = fetch(path).await?;
    let title = extract_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("xHamster 未返回影片标题".into()));
    }
    let cover = extract_og_image(&html);
    let dur_re = Regex::new(r#""duration"\s*:\s*(\d+)"#).unwrap();
    let mut synopsis = String::new();
    if let Some(c) = dur_re.captures(&html) {
        if let Some(secs) = c.get(1).and_then(|m| m.as_str().parse::<u64>().ok()) {
            let h = secs / 3600;
            let m = (secs % 3600) / 60;
            let s = secs % 60;
            if h > 0 {
                synopsis.push_str(&format!("时长：{h:02}:{m:02}:{s:02}\n"));
            } else {
                synopsis.push_str(&format!("时长：{m:02}:{s:02}\n"));
            }
        }
    }
    let actors = extract_names(&html, "/pornstars/");
    if !actors.is_empty() {
        synopsis.push_str(&format!("女优：{}\n", actors.join(" / ")));
    }
    let studios = extract_names(&html, "/channels/");
    if !studios.is_empty() {
        synopsis.push_str(&format!("片商：{}\n", studios.join(" / ")));
    }
    let id = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let episodes = vec![episode_json(&id, "正片", &id)];
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!("/search/{}", enc_segment(query.trim()));
    let (_host, html) = fetch(&path).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.contains(".m3u8") && vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let (_host, html) = fetch(vid).await?;
    match extract_hls(&html) {
        Some(hls) => Ok(json!({"url": hls})),
        None => Err(ApiError::Internal("xHamster 未取到播放清单".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_21() {
        assert_eq!(CATEGORIES.len(), 21);
        assert_eq!(CATEGORIES[0], ("/newest", "最新上传"));
        // 片商频道是 folder@ 文件夹分类，id 带 folder@ 前缀。
        assert_eq!(CATEGORIES[20], ("folder@/channels", "片商频道"));
    }

    #[test]
    fn page_url_appends_page() {
        assert_eq!(page_url("/newest", 1), "/newest");
        assert_eq!(page_url("/newest", 2), "/newest/2");
        assert_eq!(page_url("/categories/caption", 3), "/categories/caption/3");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r#"<div class="video-thumb__image-container"><a href="https://zh.xhamster1.art/videos/abc-xyz" aria-label="Sample Title"><img src="https://pic/x.jpg"><div class="video-duration">12:34</div></a></div>"#;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/videos/abc-xyz");
        assert_eq!(cards[0]["title"], "Sample Title");
        assert_eq!(cards[0]["remark"], "12:34");
    }

    #[test]
    fn hls_prefers_preload() {
        let html = r#"<link rel="preload" href="https://cdn/x/master.m3u8?sig=1" as="image">"#;
        assert_eq!(
            extract_hls(html).unwrap(),
            "https://cdn/x/master.m3u8?sig=1"
        );
    }
}
