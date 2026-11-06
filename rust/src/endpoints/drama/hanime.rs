//! Hanime1：列表为 /watch 卡片，详情取 <source> 三档 mp4 直链。
//!
//! 与 Dart 的 ZakaHmAmns 一一对应（与 AVJOY 同模板）。分类与站内导航
//! 1:1：10 个题材（g:），另加首页固定项 g:hot 热门更新（genre 实为
//! “裏番”）。分页：分类走 `/search?genre=<题材>&page=<页>`，首页走
//! `/enter?page=<页>`。详情：标题取 <title>（去 ` - ` 后缀），封面
//! og:image；streams() 只取 <source> 的 mp4 三档（480/720/1080），
//! 分集每档一集，video_id 即 mp4 直链，play() 原样回。请求须带
//! Cookie `x-index-auth=authed`。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: &[&str] = &[
    "https://www.hanime1.my",
    "https://hanime169.net",
    "https://hanime169.com",
    "https://hanime999.cc",
    "https://hanime999.net",
    "https://hanime999.com",
    "https://hanime666.net",
    "https://hanime163.com",
    "https://hanime163.net",
    "https://hanime888.net",
    "https://hanime123.org",
    "https://hanime123.one",
    "https://hanime123.sbs",
    "https://hanime123.cc",
    "https://hanime1.life",
    "https://hanime1.pw",
    "https://hanime1.art",
    "https://hanime2.cfd",
    "https://hanime2.one",
    "https://hanime2.org",
    "https://hanime2.icu",
    "https://hanime1-me.top",
    "https://hanime1-me.cc",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/// 分类：[genre, 名]，type_id 为 g:<genre>。
const CATS: &[(&str, &str)] = &[
    ("裏番", "裏番"),
    ("新番預告", "新番预告"),
    ("泡麵番", "泡麵番"),
    ("Motion Anime", "Motion Anime"),
    ("3DCG", "3DCG"),
    ("2.5D", "2.5D"),
    ("2D動畫", "2D動畫"),
    ("AI生成", "AI生成"),
    ("MMD", "MMD"),
    ("Cosplay", "Cosplay"),
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
    let mut last_err = ApiError::Internal("Hanime1 请求失败".into());
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
            last_err = ApiError::Internal(format!("Hanime1 HTTP {}", resp.status().as_u16()));
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
            last_err = ApiError::Internal("Hanime1 返回内容不可用".into());
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

/// 清晰度数值：按 URL 里的 1080/720/480 标。
fn quality_rank(url: &str) -> u32 {
    let lower = url.to_lowercase();
    for (pat, rank) in [("1080", 1080), ("720", 720), ("480", 480)] {
        if lower.contains(pat) {
            return rank;
        }
    }
    0
}

/// 清晰度档名。
fn quality_label(url: &str) -> String {
    match quality_rank(url) {
        1080 => "1080P".to_string(),
        720 => "720P".to_string(),
        480 => "480P".to_string(),
        _ => "Auto".to_string(),
    }
}

/// 视频卡片：按 /watch?v=<n> 链接切块，块内取标题与封面。
fn parse_cards(html: &str, host: &str) -> Vec<Value> {
    let title_re =
        Regex::new(r#"(?s)class="home-rows-videos-title"[^>]*>([\s\S]{0,200}?)</div>"#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+(?:data-src|data-original|src)="([^"]+)""#).unwrap();
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("watch?v=").skip(1) {
        let end = block
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(block.len());
        let digits = &block[..end];
        if digits.is_empty() || seen.contains(&digits.to_string()) {
            continue;
        }
        seen.push(digits.to_string());
        let title = title_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(tag_re.replace_all(m.as_str(), "").as_ref()))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let cover = img_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(host, m.as_str()))
            .unwrap_or_default();
        let id = format!("/watch?v={digits}");
        out.push(item_json(&id, &title, &cover, ""));
    }
    out
}

/// 取 <source> 的 mp4，按清晰度降序。
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
    urls.sort_by(|a, b| quality_rank(b).cmp(&quality_rank(a)));
    urls.into_iter()
        .map(|u| {
            let label = quality_label(&u);
            (label, u)
        })
        .collect()
}

/// 取 <title>，去 ` - ` 后缀。
fn extract_title(html: &str) -> String {
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
    let mut list: Vec<Value> = vec![category_json("g:hot", "热门更新")];
    for (genre, name) in CATS {
        list.push(category_json(&format!("g:{genre}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.trim();
    let page = if page < 1 { 1 } else { page };
    let genre = if tid == "g:hot" {
        "裏番"
    } else if let Some(g) = tid.strip_prefix("g:") {
        g
    } else {
        "裏番"
    };
    let q = url::form_urlencoded::byte_serialize(genre.as_bytes()).collect::<String>();
    let path = format!("/search?genre={q}&page={page}");
    let (host, html) = fetch(&path).await?;
    let cards = parse_cards(&html, &host);
    let has_more = cards.len() >= 24;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let digits: String = sid.chars().filter(|c| c.is_ascii_digit()).collect();
    let path = format!("/watch?v={digits}");
    let (host, html) = fetch(&path).await?;
    let title = extract_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("Hanime1 未返回影片标题".into()));
    }
    let cover = meta_content(&html, "og:image");
    let synopsis = meta_content(&html, "og:description");
    let streams = streams(&html, &host);
    if streams.is_empty() {
        return Err(ApiError::Internal("Hanime1 本条未取到播放地址".into()));
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
    let path = format!("/search?query={q}&page=1");
    let (host, html) = fetch(&path).await?;
    let cards = parse_cards(&html, &host);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        Ok(json!({"url": vid}))
    } else {
        Err(ApiError::Internal("Hanime1 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_10() {
        assert_eq!(CATS.len(), 10);
        assert_eq!(CATS[0], ("裏番", "裏番"));
        assert_eq!(CATS[9], ("Cosplay", "Cosplay"));
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a href="https://www.hanime1.my/watch?v=12345"><img data-src="https://pic/c.jpg"><div class="home-rows-videos-title">Sample Title</div></a>"##;
        let cards = parse_cards(html, HOSTS[0]);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/watch?v=12345");
        assert_eq!(cards[0]["title"], "Sample Title");
    }

    #[test]
    fn streams_sort_by_quality() {
        let html = r##"<video><source src="https://x/v_480p.mp4"><source src="https://x/v_1080p.mp4"></video>"##;
        let list = streams(html, HOSTS[0]);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].0, "1080P");
        assert_eq!(list[1].0, "480P");
    }
}
