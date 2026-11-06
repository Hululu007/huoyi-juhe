//! JavHD：HTML 站（javhd.today），列表走 /cn/*（ajax 分类取 JSON
//! 的 html 字段再解析），详情走影片页，取流走 data-embeds 的
//! base64 嵌套地址，并发探首个含 var FIRST 的页，按
//! turbovid_mp4 → playlist 取 mp4/hls。
//!
//! 分类 = 15 个 CATS + 20 个题材（a:<slug>）+ 16 个片商（s:<名>）
//! + 34 位女优（s:<名>，正式分类，作品卡片形式）；题材/片商/
//! 女优在 jar 里是 filter，核心无 filter 通道，故一并做成分类。

use futures::stream::{FuturesUnordered, StreamExt};
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::Duration;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://javhd.today";
const EDGE: &str = "https://tv506.ystv.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// CATS：id、名、路径、是否 ajax。
const CATS: &[(&str, &str, &str, bool)] = &[
    ("recent", "最新更新", "/cn/recent/", false),
    ("popular_today", "今日最多", "/cn/popular/today/", false),
    ("popular_week", "本周最多", "/cn/popular/week/", false),
    ("releaseday", "发布日期", "/cn/releaseday/", false),
    ("rated", "最受喜欢", "/cn/rated/", false),
    ("watched", "最多观看", "/cn/watched/", false),
    ("javsub", "Jav字幕", "/cn/jav-sub/", true),
    ("chinesesub", "中文字幕", "/cn/chinese-subtitle/", true),
    ("uncensored", "无码专区", "/cn/uncensored-jav/", true),
    ("amateur", "素人自拍", "/cn/amateur/", true),
    ("married", "人妻", "/cn/married-woman/", true),
    ("bigtits", "大奶", "/cn/big-tits/", true),
    ("creampie", "中出", "/cn/creampie/", true),
    ("beautiful", "美少女", "/cn/beautiful-girl/", true),
    ("solowork", "单体作品", "/cn/solowork/", true),
];

/// 题材：slug|名。
const THEMES: &[(&str, &str)] = &[
    ("beautiful-girl", "美丽的女孩"),
    ("big-tits", "大奶"),
    ("breasts", "乳房"),
    ("bukkake", "群交"),
    ("bbw", "BBW"),
    ("busty-fetish", "爆乳癖"),
    ("cosplay", "Cosplay"),
    ("cowgirl", "骑乘位"),
    ("cuckold", "NTR绿帽"),
    ("debut-production", "出道作品"),
    ("deep-throating", "深喉"),
    ("shaved", "白虎"),
    ("massage", "按摩"),
    ("squirting", "潮吹"),
    ("sister", "姐妹"),
    ("documentary", "纪录片"),
    ("solowork", "单体作品"),
    ("titty-fuck", "乳交"),
    ("married-woman", "人妻"),
    ("young-wife", "年轻妻子"),
];

const STUDIOS: &[&str] = &[
    "S1 NO.1 STYLE",
    "MOODYZ",
    "SOD Create",
    "Prestige",
    "Madonna",
    "IDEA POCKET",
    "Attackers",
    "K.M.Produce",
    "Premium",
    "Hunter",
    "Honnaka",
    "Tameike Goro-",
    "WANZ FACTORY",
    "Fitch",
    "Nagae Style",
    "FC2PPV",
];

const ACTORS: &[&str] = &[
    "Kanade Miyu",
    "Hana Arisu",
    "Kanamatsu Toho",
    "Yu Sasamoto",
    "Hanazato Akari",
    "Yui Mita",
    "Riria Hido",
    "Marina Sina",
    "Rin Chibana",
    "Yui Tsubaki",
    "Yurina Shoji",
    "Nao Hayakawa",
    "Hikari Mizusumi",
    "Saki no Kanna",
    "Yurina Momosaki",
    "Hasmi Claire",
    "Yui Higa",
    "Yumi Kazama",
    "Yui Hatano",
    "Hana Haruna",
    "Eimi Fukada",
    "Reiko Kobayakawa",
    "Asahi Mizuno",
    "Hitomi Tanaka",
    "Maria Nagai",
    "Ai Sayama",
    "Mako Oda",
    "Aimi Yoshikawa",
    "Mina Kitano",
    "Ai Uehara",
    "Anri Okita",
    "Kaho Shibuya",
    "Yua Mikami",
    "Yu Shinoda",
];

fn embeds_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"data-embeds="([^"]+)""#).unwrap())
}

fn item_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<li id="video-(\d+)">(.*?)</li>"#).unwrap())
}

fn href_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"href="([^"]+)""#).unwrap())
}

fn img_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<img[^>]+src="([^"]+)""#).unwrap())
}

fn title_attr_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"title="([^"]+)""#).unwrap())
}

async fn fetch(url: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/cn/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JavHD 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn fetch_with_edge(url: &str) -> ApiResult<String> {
    match fetch(url).await {
        Ok(t) if !t.trim().is_empty() => Ok(t),
        _ => {
            let proxy = format!(
                "{EDGE}/api/v1/proxy?url={}",
                url::form_urlencoded::byte_serialize(url.as_bytes()).collect::<String>()
            );
            let req = client()?
                .get(&proxy)
                .header("User-Agent", UA)
                .header("Accept", "*/*")
                .header("Referer", format!("{EDGE}/"));
            let resp = req
                .send()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))?;
            let status = resp.status().as_u16();
            if status != 200 {
                return Err(ApiError::Internal(format!("JavHD 中继 HTTP {status}")));
            }
            resp.text()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))
        }
    }
}

/// 响应若为 JSON 取 html 字段再解析。
fn pick_html(text: &str) -> String {
    let t = text.trim();
    if t.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(t) {
            return text_of(&v, &["html"]);
        }
    }
    t.to_string()
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
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn abs_url(path: &str) -> String {
    if path.starts_with("http") {
        path.to_string()
    } else if path.starts_with("//") {
        format!("https:{path}")
    } else if path.starts_with('/') {
        format!("{HOST}{path}")
    } else {
        format!("{HOST}/{path}")
    }
}

fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for cap in item_re().captures_iter(html) {
        let block = &cap[2];
        let href = href_re()
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str())
            .unwrap_or("");
        if !href.starts_with("/cn/") {
            continue;
        }
        let mut title = title_attr_re()
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        if title.is_empty() {
            if let Some(p) = block.find("video-title") {
                let after = &block[p..];
                let s = after.find('>').map(|i| i + 1).unwrap_or(0);
                let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
                title = strip_tags(&after[s..e]);
            }
        }
        if title.is_empty() {
            continue;
        }
        let cover = img_re()
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str())
            .unwrap_or("");
        let mut remark = String::new();
        for key in ["overlay", "duration", "video-overlay"] {
            if let Some(p) = block.find(key) {
                let after = &block[p..];
                let s = after.find('>').map(|i| i + 1).unwrap_or(0);
                let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
                let t = strip_tags(&after[s..e]);
                if !t.is_empty() {
                    if !remark.is_empty() {
                        remark.push_str(" · ");
                    }
                    remark.push_str(&t);
                }
            }
        }
        items.push(item_json(href, &title, &abs_url(cover), &remark));
    }
    items
}

fn build_url(category_id: &str, page: i64) -> String {
    if let Some(kw) = category_id.strip_prefix("s:") {
        let base = format!(
            "{HOST}/cn/search/video/?s={}&ajax=1",
            url::form_urlencoded::byte_serialize(kw.as_bytes()).collect::<String>()
        );
        return if page > 1 {
            format!("{base}&page={page}")
        } else {
            base
        };
    }
    if let Some(slug) = category_id.strip_prefix("a:") {
        let path = format!("/cn/{slug}/");
        return if page <= 1 {
            format!("{HOST}{path}?ajax=1")
        } else {
            format!("{HOST}{path}recent/{page}/?ajax=1")
        };
    }
    let id = category_id.strip_prefix("c:").unwrap_or(category_id);
    let cat = CATS.iter().find(|c| c.0 == id);
    let Some((_, _, path, ajax)) = cat else {
        return if page <= 1 {
            format!("{HOST}/cn/recent/")
        } else {
            format!("{HOST}/cn/recent/{page}/")
        };
    };
    if *ajax {
        if page <= 1 {
            format!("{HOST}{path}?ajax=1")
        } else {
            format!("{HOST}{path}recent/{page}/?ajax=1")
        }
    } else if page <= 1 {
        format!("{HOST}{path}")
    } else {
        format!("{HOST}{path}{page}/")
    }
}

fn og(html: &str, prop: &str) -> String {
    let marker = format!("property=\"{prop}\"");
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
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(html: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = html.find(&open) else {
        return String::new();
    };
    let after = &html[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

fn secs_to_hms(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// 并发探 embed 页，取首个含 var FIRST 的页，解析出播放地址。
async fn probe_embeds(embeds: &[String]) -> Option<String> {
    let mut futs = FuturesUnordered::new();
    for url in embeds.iter().take(28) {
        let url = url.clone();
        futs.push(async move {
            let fut = fetch_with_edge(&url);
            match tokio::time::timeout(Duration::from_secs(6), fut).await {
                Ok(Ok(html)) => Some((url, html)),
                _ => None,
            }
        });
    }
    while let Some(res) = futs.next().await {
        let Some((url, html)) = res else { continue };
        if let Some(found) = first_play_url(&html, &url) {
            return Some(found);
        }
    }
    None
}

/// 从含 var FIRST 的页解析 type/src/playlist（py 对照：src 优先，
/// 无则 playlist，一律按 embed 页补全相对地址；f4scdn 型即 src
/// 为相对路径的清单地址，旧版只认 turbovid_mp4 的 src 与 playlist
/// 字段，会漏掉它）。
fn first_play_url(html: &str, page_url: &str) -> Option<String> {
    let p = html.find("var FIRST")?;
    let after = &html[p..];
    let s = after.find('{')?;
    let e = after[s..].find("};").map(|i| s + i + 1)?;
    let v: Value = serde_json::from_str(&after[s..e]).ok()?;
    let src = text_of(&v, &["src"]);
    let src = if src.is_empty() {
        text_of(&v, &["playlist"])
    } else {
        src
    };
    if src.is_empty() {
        return None;
    }
    Some(resolve_url(page_url, &src))
}

fn resolve_url(base: &str, rel: &str) -> String {
    if rel.starts_with("http") {
        return rel.to_string();
    }
    if rel.starts_with("//") {
        return format!("https:{rel}");
    }
    if rel.starts_with('/') {
        let parts: Vec<&str> = base.split('/').collect();
        if parts.len() >= 3 {
            return format!("{}//{}{}", parts[0], parts[2], rel);
        }
        return rel.to_string();
    }
    match base.rfind('/') {
        Some(i) => format!("{}{}", &base[..i + 1], rel),
        None => rel.to_string(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (id, name, _, _) in CATS {
        list.push(category_json(&format!("c:{id}"), name));
    }
    for (slug, name) in THEMES {
        list.push(category_json(&format!("a:{slug}"), name));
    }
    for name in STUDIOS {
        list.push(category_json(&format!("s:{name}"), name));
    }
    for name in ACTORS {
        list.push(category_json(&format!("s:{name}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = build_url(category_id, page);
    let text = fetch_with_edge(&url).await?;
    let items = parse_list(&pick_html(&text));
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = abs_url(series_id);
    let html = fetch_with_edge(&url).await?;
    let mut title = tag_text(&html, "h1");
    if title.is_empty() {
        title = tag_text(&html, "title");
    }
    if title.is_empty() {
        return Err(ApiError::Internal("JavHD 未返回影片资料".into()));
    }
    let cover = og(&html, "og:image");
    let desc = og(&html, "og:description");
    let dur = og(&html, "og:video:duration").parse::<i64>().unwrap_or(0);
    let year = og(&html, "og:video:release_date");
    let year = year.get(..4).unwrap_or("").to_string();
    let mut tags = Vec::new();
    let mut rest = html.as_str();
    while let Some(p) = rest.find("video:tag") {
        let after = &rest[p..];
        if let Some(c) = after.find("content=\"") {
            let s = c + 9;
            if let Some(e) = after[s..].find('"') {
                tags.push(after[s..s + e].to_string());
            }
        }
        rest = &rest[p + 9..];
    }
    let mut extra = serde_json::Map::new();
    if !tags.is_empty() {
        extra.insert("tag".to_string(), json!(tags.join(" / ")));
    }
    if !year.is_empty() {
        extra.insert("year".to_string(), json!(year));
    }
    let remark = secs_to_hms(dur);
    if !remark.is_empty() {
        extra.insert("duration".to_string(), json!(remark));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": abs_url(&cover),
        "synopsis": desc,
        "extra": extra,
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/cn/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let detail_url = abs_url(&page_url);
    let html = fetch_with_edge(&detail_url).await?;
    let b64 = embeds_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str())
        .unwrap_or("");
    if b64.is_empty() {
        return Err(ApiError::Internal("JavHD 详情页未找到 data-embeds".into()));
    }
    let decoded = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, b64)
        .map_err(|_| ApiError::Internal("JavHD data-embeds 解码失败".into()))?;
    let decoded = String::from_utf8(decoded)
        .map_err(|_| ApiError::Internal("JavHD data-embeds 不是文本".into()))?;
    let embeds: Vec<String> = serde_json::from_str::<Vec<Value>>(&decoded)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let s = super::str_of(v);
                    if s.starts_with("http") {
                        Some(s)
                    } else {
                        None
                    }
                })
                .collect()
        })
        .unwrap_or_else(|_| {
            decoded
                .split('"')
                .filter(|s| s.starts_with("http"))
                .map(|s| s.to_string())
                .collect()
        });
    if embeds.is_empty() {
        return Err(ApiError::Internal(
            "JavHD data-embeds 里没有嵌套地址".into(),
        ));
    }
    let url = probe_embeds(&embeds)
        .await
        .ok_or_else(|| ApiError::Internal("JavHD 嵌套地址均未返回可播流".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/cn/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = build_url(&format!("s:{query}"), 1);
    let text = fetch_with_edge(&url).await?;
    let items = parse_list(&pick_html(&text));
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_url_rules() {
        assert!(build_url("c:recent", 1).ends_with("/cn/recent/"));
        assert!(build_url("c:recent", 2).ends_with("/cn/recent/2/"));
        assert!(build_url("c:javsub", 2).contains("recent/2/?ajax=1"));
        assert!(build_url("a:big-tits", 1).contains("/cn/big-tits/?ajax=1"));
        assert!(build_url("s:Yua Mikami", 1).contains("search/video/?s=Yua+Mikami"));
    }

    #[test]
    fn first_play_turbovid() {
        let html = r#"var FIRST = {"type":"turbovid_mp4","src":"https://cdn/x.mp4"};"#;
        assert_eq!(
            first_play_url(html, "https://e/x/").unwrap(),
            "https://cdn/x.mp4"
        );
    }

    #[test]
    fn first_play_playlist() {
        let html = r#"var FIRST = {"type":"x","playlist":"https://cdn/x.m3u8"};"#;
        assert_eq!(
            first_play_url(html, "https://e/x/").unwrap(),
            "https://cdn/x.m3u8"
        );
    }

    #[test]
    fn category_counts() {
        assert_eq!(CATS.len(), 15);
        assert_eq!(THEMES.len(), 20);
        assert_eq!(STUDIOS.len(), 16);
        assert_eq!(ACTORS.len(), 34);
    }
}
