//! AVJOY：列表为 /video 卡片，详情取 <source> 多档 mp4 直链。
//!
//! 与 Dart 的 ZakaAvjoyAmns 一一对应。分类与站内导航 1:1：4 个排序
//!（s: 最新/最热/评分/收藏）在前，25 个分类（c:）在后。分页：排序
//! 走 `/videos?o=<sort>&page=<页>`，分类走 `/categories/<slug>/<页>`，
//! 首页走 `/videos?page=<页>`。详情：标题取 content-title，封面
//! og:image；streams() 先取 <source> 的 mp4（跳过 preview 与短地址，
//! 按 2160/1080/720/480/360 清晰度排序），为空回退全页 mp4 正则
//!（跳过 71352.men 与 /tmb/）。分集每档一集，video_id 即 mp4 直链，
//! play() 原样回。请求须带 Cookie `x-index-auth=authed`。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: &[&str] = &[
    "https://cn.avjoy.ws",
    "https://cn.avjoy.nl",
    "https://cn.avjoy.top",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/// 排序：[slug, 名]，type_id 为 s:<slug>。
const SORTS: &[(&str, &str)] = &[
    ("mr", "最新"),
    ("mv", "最热"),
    ("tr", "评分"),
    ("tf", "收藏"),
];

/// 分类：[slug, 名]，type_id 为 c:<slug>。
const CATS: &[(&str, &str)] = &[
    ("4k-porn", "4K超清"),
    ("uncensored", "无码"),
    ("chinese-subtitle", "中文字幕"),
    ("jav", "日本AV"),
    ("japanese", "日本"),
    ("asian", "亚洲"),
    ("anal", "肛交"),
    ("big-tits", "巨乳"),
    ("big-ass", "丰臀"),
    ("milf", "熟女"),
    ("mature", "成熟"),
    ("amateur", "素人自拍"),
    ("creampie", "内射"),
    ("facial", "颜射"),
    ("deep-throat", "深喉"),
    ("threesome", "3P"),
    ("lesbian", "女同"),
    ("ebony", "黑人"),
    ("latina", "拉丁"),
    ("cosplay", "角色扮演"),
    ("office", "办公室"),
    ("massage", "按摩"),
    ("public", "公开场合"),
    ("cheating", "出轨"),
    ("hentai", "成人动漫"),
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
    let mut last_err = ApiError::Internal("AVJOY 请求失败".into());
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
            .header("Cookie", "x-index-auth=authed")
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
            last_err = ApiError::Internal(format!("AVJOY HTTP {}", resp.status().as_u16()));
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
            last_err = ApiError::Internal("AVJOY 返回内容不可用".into());
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

/// 相对地址补全：`//` 补 `https:`，站内相对补 host。
fn abs_url(host: &str, raw: &str) -> String {
    let s = raw.trim();
    if s.starts_with("http") {
        s.to_string()
    } else if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = s.strip_prefix('/') {
        format!("{host}/{rest}")
    } else {
        format!("{host}/{s}")
    }
}

/// 清晰度数值：按 URL 里的 2160/1080/720/480/360 或 4K 标。
fn quality_rank(url: &str) -> u32 {
    let lower = url.to_lowercase();
    for (pat, rank) in [
        ("2160", 2160),
        ("4k", 2160),
        ("1080", 1080),
        ("720", 720),
        ("480", 480),
        ("360", 360),
    ] {
        if lower.contains(pat) {
            return rank;
        }
    }
    0
}

/// 清晰度档名：2160→4K，1080→1080P，余类推，无档标为 Auto。
fn quality_label(url: &str) -> String {
    match quality_rank(url) {
        2160 => "4K".to_string(),
        1080 => "1080P".to_string(),
        720 => "720P".to_string(),
        480 => "480P".to_string(),
        360 => "360P".to_string(),
        _ => "Auto".to_string(),
    }
}

/// 视频卡片：按 /video/<n>/ 链接切块，块内取标题、封面、时长。
fn parse_cards(html: &str, host: &str) -> Vec<Value> {
    let title_re = Regex::new(r#"title="([^"]+)""#).unwrap();
    let alt_re = Regex::new(r#"alt="([^"]+)""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+(?:data-src|data-original|src)="([^"]+)""#).unwrap();
    let dur_re = Regex::new(r#"(?s)class="duration"[^>]*>([\s\S]{0,160}?)</div>"#).unwrap();
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("href=\"/video/").skip(1) {
        let end = block.find('"').unwrap_or(block.len());
        let head = &block[..end];
        let digits: String = head.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() {
            continue;
        }
        let id = format!("/video/{digits}/");
        let rest = &head[digits.len()..];
        let id = if rest.is_empty() {
            id
        } else {
            format!("/video/{digits}{rest}")
        };
        if seen.contains(&id) {
            continue;
        }
        let title = title_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(m.as_str()))
            .or_else(|| {
                alt_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| unesc(m.as_str()))
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        let cover = img_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(host, m.as_str()))
            .unwrap_or_default();
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(tag_re.replace_all(m.as_str(), "").as_ref()))
            .unwrap_or_default();
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 取 <source> 的 mp4，按清晰度降序；为空回退全页 mp4 正则。
fn streams(html: &str, host: &str) -> Vec<(String, String)> {
    let src_re = Regex::new(r#"<source[^>]+src="([^"]+)""#).unwrap();
    let mut urls: Vec<String> = Vec::new();
    for cap in src_re.captures_iter(html) {
        let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if raw.contains("preview") || raw.len() < 12 {
            continue;
        }
        let full = abs_url(host, raw);
        if !full.contains(".mp4") {
            continue;
        }
        if !urls.contains(&full) {
            urls.push(full);
        }
    }
    if urls.is_empty() {
        let any = Regex::new(r#"https?://[^"'\s<>]+\.mp4[^"'\s<>]*"#).unwrap();
        for m in any.find_iter(html) {
            let u = m.as_str();
            if u.contains("71352.men") || u.contains("/tmb/") {
                continue;
            }
            if !urls.contains(&u.to_string()) {
                urls.push(u.to_string());
            }
        }
    }
    urls.sort_by(|a, b| quality_rank(b).cmp(&quality_rank(a)));
    urls.into_iter()
        .map(|u| {
            let label = quality_label(&u);
            (label, u)
        })
        .collect()
}

/// 取 content-title 或 <title>，去 ` - ` 后缀。
fn extract_title(html: &str) -> String {
    let re = Regex::new(r#"(?s)class="content-title">\s*(.*?)\s*<"#).unwrap();
    if let Some(c) = re.captures(html) {
        let raw = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let tag = Regex::new(r"<[^>]+>").unwrap();
        let t = unesc(tag.replace_all(raw, "").as_ref());
        let t = t.split(" - ").next().unwrap_or("").trim().to_string();
        if !t.is_empty() {
            return t;
        }
    }
    let title = Regex::new(r"(?s)<title>\s*(.*?)\s*</title>").unwrap();
    title
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| {
            let t = unesc(m.as_str());
            t.split(" - ").next().unwrap_or("").trim().to_string()
        })
        .unwrap_or_default()
}

/// 取 og:image / og:description。
fn meta_content(html: &str, property: &str) -> String {
    let pattern = format!(r#"<meta[^>]+property="{}"[^>]+content="([^"]+)""#, property);
    let re = Regex::new(&pattern).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (slug, name) in SORTS {
        list.push(category_json(&format!("s:{slug}"), name));
    }
    for (slug, name) in CATS {
        list.push(category_json(&format!("c:{slug}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.trim();
    let page = if page < 1 { 1 } else { page };
    let (path, _host) = if let Some(sort) = tid.strip_prefix("s:") {
        (format!("/videos?o={sort}&page={page}"), HOSTS[0])
    } else if let Some(slug) = tid.strip_prefix("c:") {
        (format!("/categories/{slug}/{page}"), HOSTS[0])
    } else {
        (format!("/videos?page={page}"), HOSTS[0])
    };
    let (host, html) = fetch(&path).await?;
    let cards = parse_cards(&html, &host);
    let has_more = cards.len() >= 24;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let path = if sid.starts_with('/') {
        sid.to_string()
    } else {
        format!("/{sid}")
    };
    let (host, html) = fetch(&path).await?;
    let title = extract_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("AVJOY 未返回影片标题".into()));
    }
    let cover = meta_content(&html, "og:image");
    let synopsis = meta_content(&html, "og:description");
    let streams = streams(&html, &host);
    if streams.is_empty() {
        return Err(ApiError::Internal("AVJOY 本条未取到播放地址".into()));
    }
    let episodes: Vec<Value> = streams
        .iter()
        .map(|(label, url)| episode_json(url, label, sid))
        .collect();
    Ok(json!({
        "id": sid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>();
    let path = format!("/search/videos/{q}?page=1");
    let (host, html) = fetch(&path).await?;
    let cards = parse_cards(&html, &host);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        Ok(json!({"url": vid}))
    } else {
        Err(ApiError::Internal("AVJOY 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_29() {
        assert_eq!(SORTS.len(), 4);
        assert_eq!(CATS.len(), 25);
        assert_eq!(SORTS[0], ("mr", "最新"));
        assert_eq!(CATS[0], ("4k-porn", "4K超清"));
    }

    #[test]
    fn quality_labels() {
        assert_eq!(quality_label("https://x/v_1080p.mp4"), "1080P");
        assert_eq!(quality_label("https://x/v_720p.mp4"), "720P");
        assert_eq!(quality_label("https://x/v.mp4"), "Auto");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a href="/video/12345/sample-title" title="Sample Title"><img data-src="https://pic/c.jpg"><div class="duration">12:34</div></a>"##;
        let cards = parse_cards(html, HOSTS[0]);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/video/12345/sample-title");
        assert_eq!(cards[0]["title"], "Sample Title");
        assert_eq!(cards[0]["remark"], "12:34");
    }

    #[test]
    fn streams_sort_by_quality() {
        let html = r##"<video><source src="https://x/v_480p.mp4"><source src="https://x/v_1080p.mp4"><source src="https://x/preview.mp4"></video>"##;
        let list = streams(html, HOSTS[0]);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].0, "1080P");
        assert_eq!(list[1].0, "480P");
    }
}
