//! 🔞Korean Porn Movie（koreanpornmovie.com）：WordPress 韩国长片站。
//!
//! 列表走 WP REST API（/wp-json/wp/v2/posts，_embed=1 取封面；
//! 标签分类按标签 id 过滤），详情抓 HTML 页解 player-x.php 的
//! q 参数（标准 base64 → URL 解码 → <video><source src> 直链）。
//! 取流（详情页 source 直链 koreanporn.stream mp4，本机实测
//! Range 206 + ftypmp42 魔数）。
//! 验门（2026-11-06 本机出口实测）：详情《365 Days of Solo
//! Pleasure 6 Live Masturbation Sex (2025)》时长 06:03:02；
//! wp-json 全站 2801 篇，列表 p1/p2 0 重合；搜索 masturbation
//! 主区 15 条；标签 id 经 /wp-json/wp/v2/tags 实查。
//! 注意：HTML 首页 /page/2/ 与首页内容相同（主题不分页），
//! 列表一律走 wp-json 分页。

use base64::Engine;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://koreanpornmovie.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：最新 + 按发文量排前列的标签（id 经 wp-json 实查）。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新"),
    ("tag:46", "Korean Sex"),
    ("tag:1361", "Celebrity Porn Movies"),
    ("tag:1366", "Korean Adult Movies"),
    ("tag:1370", "Cat3Movie"),
    ("tag:1369", "Cat 3 Movies"),
    ("tag:1363", "Erotic Movies Online"),
    ("tag:1386", "Soft Porn Movies"),
    ("tag:1362", "Asian Erotic"),
    ("tag:1271", "Korean Erotic"),
    ("tag:1392", "Nude Boobs"),
    ("tag:1413", "18+ Movies"),
    ("tag:15", "Korean"),
    ("tag:49", "Asian"),
    ("tag:84", "Korea"),
    ("tag:1364", "Free Erotic Movies"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/json,*/*",
        )
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("KoreanPorn 请求 HTTP {status}")));
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

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    decode_entities(&out)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// wp-json posts 列表解析：link 作 id、title.rendered 作标题、
/// _embedded.wp:featuredmedia[0].source_url 作封面。
fn parse_posts(json_text: &str) -> Vec<Value> {
    let Ok(v) = serde_json::from_str::<Value>(json_text) else {
        return Vec::new();
    };
    let Some(arr) = v.as_array() else {
        return Vec::new();
    };
    let mut items = Vec::new();
    for post in arr {
        let link = text_of(post, &["link"]);
        if link.is_empty() {
            continue;
        }
        let title = post
            .get("title")
            .and_then(|t| t.get("rendered"))
            .and_then(|t| t.as_str())
            .map(|t| decode_entities(t))
            .unwrap_or_default();
        let title = truncate(&title, 90);
        if title.is_empty() {
            continue;
        }
        let cover = post
            .get("_embedded")
            .and_then(|e| e.get("wp:featuredmedia"))
            .and_then(|m| m.as_array())
            .and_then(|a| a.first())
            .and_then(|m| m.get("source_url"))
            .and_then(|u| u.as_str())
            .unwrap_or("")
            .to_string();
        items.push(item_json(&link, &title, &cover, ""));
    }
    items
}

fn posts_url(category_id: &str, page: i64) -> String {
    let base = format!("{HOST}/wp-json/wp/v2/posts?per_page=20&page={page}&_embed=1");
    if let Some(tag) = category_id.strip_prefix("tag:") {
        format!("{base}&tags={tag}")
    } else {
        base
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

/// 详情页 player-x.php?q=<base64> 解码：
/// q 是标准 base64（可能含 URL 安全字符），解出
/// `post_id=..&type=video&tag=<URL 编码的 <video> 标签>`，
/// 再从 tag 里取 <source src>。
fn extract_stream(html: &str) -> String {
    let re = Regex::new(r"player-x\.php\?q=([A-Za-z0-9+/=_-]+)").unwrap();
    let Some(cap) = re.captures(html) else {
        return String::new();
    };
    let q = cap[1].replace('-', "+").replace('_', "/");
    let padded = format!("{q}{}", "=".repeat((4 - q.len() % 4) % 4));
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(padded.as_bytes()) else {
        return String::new();
    };
    let decoded = String::from_utf8_lossy(&bytes).to_string();
    let tag = match decoded.find("tag=") {
        Some(p) => &decoded[p + 4..],
        None => return String::new(),
    };
    let tag = percent_decode(tag);
    let src_re = Regex::new(r#"<source[^>]+src="([^"]+\.mp4[^"]*)"#).unwrap();
    match src_re.captures(&tag) {
        Some(c) => c[1].to_string(),
        None => String::new(),
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(n) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(n);
                i += 3;
                continue;
            }
        }
        if bytes[i] == b'+' {
            out.push(b' ');
            i += 1;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn detail_duration(html: &str) -> String {
    let re = Regex::new(r#"duration" content="([0-9:]+)"#).unwrap();
    match re.captures(html) {
        Some(c) => c[1].to_string(),
        None => String::new(),
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
    let url = posts_url(category_id, page);
    let text = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_posts(&text);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("KoreanPorn 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let duration = detail_duration(&html);
    let synopsis = if duration.is_empty() {
        String::new()
    } else {
        format!("时长：{duration}")
    };
    let stream = extract_stream(&html);
    let episodes = if stream.is_empty() {
        vec![episode_json(series_id, "正片", series_id)]
    } else {
        vec![episode_json(&stream, "正片", series_id)]
    };
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
    if video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let html = fetch(video_id, &format!("{HOST}/")).await?;
    let url = extract_stream(&html);
    if url.is_empty() {
        return Err(ApiError::Internal("KoreanPorn 未取到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": video_id},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/wp-json/wp/v2/posts?search={}&per_page=20&page=1&_embed=1",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let text = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_posts(&text);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posts_parse_with_embedded_cover() {
        let text = r#"[{"id":10385,"slug":"natural-breasted-adulterous-woman-2026","link":"https://koreanpornmovie.com/natural-breasted-adulterous-woman-2026/","title":{"rendered":"Natural Breasted Adulterous Woman (2026)"},"_embedded":{"wp:featuredmedia":[{"source_url":"https://koreanpornmovie.com/wp-content/uploads/2026/10/Natural-Breasted-Adulterous-Woman-2026.jpg"}]}}]"#;
        let items = parse_posts(text);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://koreanpornmovie.com/natural-breasted-adulterous-woman-2026/"
        );
        assert_eq!(
            items[0]["title"],
            "Natural Breasted Adulterous Woman (2026)"
        );
        assert_eq!(
            items[0]["cover"],
            "https://koreanpornmovie.com/wp-content/uploads/2026/10/Natural-Breasted-Adulterous-Woman-2026.jpg"
        );
    }

    #[test]
    fn posts_url_rules() {
        assert_eq!(
            posts_url("latest", 2),
            "https://koreanpornmovie.com/wp-json/wp/v2/posts?per_page=20&page=2&_embed=1"
        );
        assert_eq!(
            posts_url("tag:46", 1),
            "https://koreanpornmovie.com/wp-json/wp/v2/posts?per_page=20&page=1&_embed=1&tags=46"
        );
    }

    #[test]
    fn extract_stream_from_player_q() {
        // 真实结构：q 解出 tag=<video ...><source src="...mp4">。
        let tag = "%3Cvideo%20controls%3E%3Csource%20src%3D%22https%3A%2F%2Fkoreanporn.stream%2F365%2520Days%2520Test.mp4%22%20type%3D%22video%2Fmp4%22%20%2F%3E%3C%2Fvideo%3E";
        let raw = format!("post_id=10280&type=video&tag={tag}");
        let q = base64::engine::general_purpose::STANDARD.encode(raw.as_bytes());
        let html = format!("<iframe src=\"https://koreanpornmovie.com/wp-content/plugins/clean-tube-player/public/player-x.php?q={q}\"></iframe>");
        assert_eq!(
            extract_stream(&html),
            "https://koreanporn.stream/365%20Days%20Test.mp4"
        );
    }

    #[test]
    fn percent_decode_roundtrip() {
        assert_eq!(
            percent_decode("https%3A%2F%2Fkoreanporn.stream%2F365%2520Days.mp4"),
            "https://koreanporn.stream/365%20Days.mp4"
        );
    }

    #[test]
    fn detail_duration_reads() {
        let html = r#"<meta itemprop="duration" content="06:03:02+00:00" />"#;
        assert_eq!(detail_duration(html), "06:03:02");
    }

    #[test]
    fn tag_title_strips_site_name() {
        let html =
            "<title>365 Days of Solo Pleasure 6 Live Masturbation Sex (2025) | Korean Porn</title>";
        assert_eq!(
            tag_title(html),
            "365 Days of Solo Pleasure 6 Live Masturbation Sex (2025)"
        );
    }
}
