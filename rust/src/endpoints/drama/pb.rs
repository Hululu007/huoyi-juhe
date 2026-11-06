//! 好色TV：列表为 thumbnail 卡片，详情嵌 iframe video_url。
//!
//! 与 Dart 的 ZakaPbAmns 一一对应。分类与站内导航 1:1（7 项，含
//! 热搜标签 folder@hotwords，28 个静态热搜词）。分页：list-<页>.htm
//!（如 /list-2.htm、/top7_list-2.htm）。详情：og:title / og:image /
//! video:duration / og:video:actor 等；取流取 `player.html?video_url=`
//! 的地址（URL 解码后含 .m3u8），play() 跟随 302 落 CDN 清单再回最终
//! 地址。广告位视频判断（tip.ts 分片比对）未移植：详情取到的清单直
//! 接出正片，若某条实为站方广告位，播放端会看到广告分片。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: &[&str] = &[
    "https://pb365.nl",
    "https://www.pb365.nl",
    "https://pb365.sbs",
    "https://pb365.top",
    "https://pb365.one",
    "https://hsex1.mom",
    "https://hsex1.sbs",
    "https://hsex1.cc",
    "https://hsex1.icu",
    "https://hsex1.top",
    "https://hsex1.vip",
    "https://hsex.nl",
    "https://hsex.cfd",
    "https://hsex.mom",
    "https://hsex.sbs",
    "https://hsex.one",
    "https://hsex.top",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[路径, 名]，与站内导航 1:1；folder@hotwords 为热搜标签。
const CATEGORIES: &[(&str, &str)] = &[
    ("/list-1.htm", "最新上传"),
    ("/list-1.htm?sort=hot", "最热优先"),
    ("/top7_list-1.htm", "周榜"),
    ("/top_list-1.htm", "月榜"),
    ("/5min_list-1.htm", "5分钟以上"),
    ("/long_list-1.htm", "10分钟以上"),
    ("folder@hotwords", "热搜标签"),
];

/// 热搜词静态表（与 Java 的 hotwords 数组一致）。
const HOTWORDS: &[&str] = &[
    "91自拍",
    "国产",
    "淫妻",
    "校服",
    "全程",
    "肉丝",
    "吞精",
    "媚黑",
    "熟女老板娘",
    "摄像头",
    "表妹",
    "护士",
    "射进",
    "强上",
    "电话",
    "绿奴",
    "大学生",
    "东北",
    "高冷",
    "白浆",
    "肛交",
    "极品颜值",
    "农村",
    "痉挛",
    "g奶",
    "双飞",
    "bbw",
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
    let mut last_err = ApiError::Internal("好色TV 请求失败".into());
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
            last_err = ApiError::Internal(format!("好色TV HTTP {}", resp.status().as_u16()));
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
            last_err = ApiError::Internal("好色TV 返回内容不可用".into());
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

/// 秒数转时长文本：>=1 小时为 h:mm:ss，否则为 m:ss。
fn fmt_dur(secs: u64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// 百分号解码（%XX 还原字节，+ 还原空格）。
fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(n) = u8::from_str_radix(&raw[i + 1..i + 3], 16) {
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

/// 分页：页<=1 原样；`...list-<n>.htm` 换页码，否则把 `-<n>.htm` 换页码。
fn page_url(path: &str, page: i64) -> String {
    if page <= 1 {
        return path.to_string();
    }
    let list_re = Regex::new(r"^(/[A-Za-z0-9_]*?)list-\d+\.htm(\?.*)?$").unwrap();
    if let Some(c) = list_re.captures(path) {
        let prefix = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let query = c.get(2).map(|m| m.as_str()).unwrap_or("");
        return format!("{prefix}list-{page}.htm{query}");
    }
    let num_re = Regex::new(r"-(\d+)\.htm").unwrap();
    num_re
        .replace(path, format!("-{page}.htm").as_str())
        .to_string()
}

/// 视频卡片：按 class="thumbnail" 切块，块内取链接、背景图封面、h5 标题、时长。
fn parse_cards(html: &str) -> Vec<Value> {
    let link_re = Regex::new(r#"href="(/?(?:video-(\d+)\.htm))""#).unwrap();
    let cover_re = Regex::new(r#"background-image:\s*url\('([^']+)'\)"#).unwrap();
    let title_re = Regex::new(r"(?s)<h5>\s*<a[^>]*>([\s\S]{2,300}?)</a>").unwrap();
    let dur_re = Regex::new(r#"<var class="duration">\s*([\d:]+)"#).unwrap();
    let author_re = Regex::new(r#"href="user\.htm\?author=([^"&]+)""#).unwrap();
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("class=\"thumbnail\"").skip(1) {
        let id = match link_re.captures(block) {
            Some(c) => c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
            None => continue,
        };
        if id.is_empty() || seen.contains(&id) {
            continue;
        }
        let title = match title_re.captures(block) {
            Some(c) => {
                let raw = c.get(1).map(|m| m.as_str()).unwrap_or("");
                unesc(tag_re.replace_all(raw, "").as_ref())
            }
            None => continue,
        };
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        let cover = cover_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .or_else(|| {
                author_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
            .unwrap_or_default();
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 取 og:xxx / video:xxx 等 meta 属性值。
fn meta_content(html: &str, property: &str) -> String {
    let pattern = format!(r#"<meta[^>]+property="{}"[^>]+content="([^"]+)""#, property);
    let re = Regex::new(&pattern).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

/// 详情页取清单：先找 player.html?video_url=，再全页扫 m3u8。
fn extract_hls(html: &str) -> Option<String> {
    let re = Regex::new(r#"player\.html\?video_url=([^&"'>\s]+)"#).unwrap();
    if let Some(c) = re.captures(html) {
        let raw = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let decoded = percent_decode(raw);
        if decoded.contains(".m3u8") {
            return Some(decoded);
        }
        if decoded.starts_with("http") {
            return Some(decoded);
        }
    }
    let any = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#).unwrap();
    any.find(html).map(|m| m.as_str().to_string())
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(path, name)| category_json(path, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.trim();
    if tid == "folder@hotwords" {
        let cards: Vec<Value> = HOTWORDS
            .iter()
            .map(|w| item_json(&format!("folder@kw@{w}"), w, "", "标签"))
            .collect();
        return Ok(json!({"items": cards, "has_more": false}));
    }
    if let Some(word) = tid.strip_prefix("kw@") {
        let q = url::form_urlencoded::byte_serialize(word.as_bytes()).collect::<String>();
        let path = format!("/search-1.htm?search={q}&sort=new");
        let (_host, html) = fetch(&path).await?;
        let cards = parse_cards(&html);
        return Ok(json!({"items": cards, "has_more": false}));
    }
    if let Some(word) = tid.strip_prefix("folder@kw@") {
        let q = url::form_urlencoded::byte_serialize(word.as_bytes()).collect::<String>();
        let path = format!("/search-1.htm?search={q}&sort=new");
        let (_host, html) = fetch(&path).await?;
        let cards = parse_cards(&html);
        return Ok(json!({"items": cards, "has_more": false}));
    }
    let tid = if tid.is_empty() { "/list-1.htm" } else { tid };
    let url = page_url(tid, page);
    let (_host, html) = fetch(&url).await?;
    let cards = parse_cards(&html);
    let has_more = cards.len() >= 12;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let digits: String = sid.chars().filter(|c| c.is_ascii_digit()).collect();
    let path = format!("/video-{digits}.htm");
    let (_host, html) = fetch(&path).await?;
    let title = meta_content(&html, "og:title");
    if title.is_empty() {
        return Err(ApiError::Internal("好色TV 未返回影片标题".into()));
    }
    let cover = meta_content(&html, "og:image");
    let mut synopsis = String::new();
    let dur = meta_content(&html, "video:duration");
    if let Ok(secs) = dur.parse::<u64>() {
        if secs > 0 {
            synopsis.push_str(&format!("时长：{}\n", fmt_dur(secs)));
        }
    }
    let actor = meta_content(&html, "og:video:actor");
    if !actor.is_empty() {
        synopsis.push_str(&format!("演员：{actor}\n"));
    }
    let class = meta_content(&html, "og:video:class");
    if !class.is_empty() {
        synopsis.push_str(&format!("分类：{class}\n"));
    }
    let area = meta_content(&html, "og:video:area");
    if !area.is_empty() {
        synopsis.push_str(&format!("地区：{area}\n"));
    }
    let desc = meta_content(&html, "og:description");
    if !desc.is_empty() {
        synopsis.push_str(&desc);
    }
    let hls = match extract_hls(&html) {
        Some(h) => h,
        None => return Err(ApiError::Internal("没取到播放地址，稍后重试".into())),
    };
    let id = format!("/video-{digits}.htm");
    let episodes = vec![episode_json(&hls, "正片", &id)];
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
    let q = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>();
    let path = format!("/search-1.htm?search={q}&sort=new");
    let (_host, html) = fetch(&path).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if !vid.starts_with("http") {
        return Err(ApiError::Internal("好色TV 该集没有播放地址".into()));
    }
    let mut last_err = ApiError::Internal("好色TV 取流失败".into());
    for host in HOSTS {
        let resp = client()?
            .get(vid)
            .header("User-Agent", UA)
            .header("Accept", "*/*")
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
        let final_url = resp.url().to_string();
        if resp.status().as_u16() != 200 {
            last_err = ApiError::Internal(format!("好色TV 取流 HTTP {}", resp.status().as_u16()));
            continue;
        }
        if final_url.contains(".m3u8") {
            return Ok(json!({"url": final_url}));
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if text.trim_start().starts_with("#EXTM3U") {
            return Ok(json!({"url": final_url}));
        }
        if let Some(m) = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#)
            .unwrap()
            .find(&text)
        {
            return Ok(json!({"url": m.as_str()}));
        }
        return Ok(json!({"url": vid}));
    }
    Err(last_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_7() {
        assert_eq!(CATEGORIES.len(), 7);
        assert_eq!(CATEGORIES[6], ("folder@hotwords", "热搜标签"));
        // 列表实为 27 词（逐条数过），28 是写测试时数错了。
        assert_eq!(HOTWORDS.len(), 27);
    }

    #[test]
    fn page_url_rules() {
        assert_eq!(page_url("/list-1.htm", 1), "/list-1.htm");
        assert_eq!(page_url("/list-1.htm", 2), "/list-2.htm");
        assert_eq!(page_url("/top7_list-1.htm", 3), "/top7_list-3.htm");
        assert_eq!(page_url("/list-1.htm?sort=hot", 2), "/list-2.htm?sort=hot");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<div class="thumbnail"><a href="/video-123.htm"><div style="background-image:url('https://pic/c.jpg')"></div><h5><a href="/video-123.htm">Sample Title</a></h5><var class="duration">12:34</var></a></div>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/video-123.htm");
        assert_eq!(cards[0]["title"], "Sample Title");
        assert_eq!(cards[0]["cover"], "https://pic/c.jpg");
        assert_eq!(cards[0]["remark"], "12:34");
    }

    #[test]
    fn hls_from_video_url() {
        let html = r#"player.html?video_url=https%3A%2F%2Fcdn.x%2Fv%2Findex.m3u8%3Ftoken%3D1"#;
        assert_eq!(
            extract_hls(html).unwrap(),
            "https://cdn.x/v/index.m3u8?token=1"
        );
    }
}
