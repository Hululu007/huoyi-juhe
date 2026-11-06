//! rouAV：MacCMS 风格站，详情嵌 player_aaaa，取流走站内 /api/v。
//!
//! 与 Dart 的 ZakaRouavAmns 一一对应。分类与站内导航 1:1（7 项）。
//! 分页：`/vodtype/<n>.html` 第 2 页起走 `/vod/show/id/<n>/page/<页>.html`，
//! 其他 .html 去后缀补 `-<页>.html`（如 /enter-2.html）。详情：
//! player_aaaa JSON 的 url 字段经 vidOf 解码（URL 解码后再 base64 解，
//! ss 数组取首项的 /api/v/<vid> 路径）得 vid；分集 video_id 即 vid，
//! play() 现取 `/api/v/<vid>` 的 video.videoUrl（跟随 302 落 CDN 清单），
//! 取不到时回退 `/api/hls/<vid>`。搜索：`/vod/search.html?wd=<词>&page=1`。

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of, with_query};

const HOSTS: &[&str] = &[
    "https://rou123.ws",
    "https://rou123.icu",
    "https://rou123.cc",
    "https://rou123.cfd",
    "https://rou123.sbs",
    "https://rou123.org",
    "https://rou123.vip",
    "https://rou123.one",
    "https://rou123.top",
    "https://rou666.net",
    "https://rou666.cc",
    "https://rou666.com",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[路径, 名]，与站内导航 1:1。
const CATEGORIES: &[(&str, &str)] = &[
    ("/enter", "最新更新"),
    ("/vodtype/7.html", "国产AV"),
    ("/vodtype/3.html", "日本"),
    ("/vodtype/6.html", "自拍流出"),
    ("/vodtype/5.html", "探花"),
    ("/vodtype/4.html", "OnlyFans"),
    ("/vodtype/1.html", "其他"),
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
    let mut last_err = ApiError::Internal("rouAV 请求失败".into());
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
            .header("Accept-Language", "zh-CN,zh;q=0.9,zh-TW;q=0.8,en;q=0.7")
            .header("Referer", format!("{host}/enter"))
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
            last_err = ApiError::Internal(format!("rouAV HTTP {}", resp.status().as_u16()));
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
            last_err = ApiError::Internal("rouAV 返回内容不可用".into());
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

/// 分页：页<=1 原样；/vodtype/<n>.html 走 /vod/show/id/<n>/page/<页>.html；
/// 其他 .html 去后缀补 `-<页>.html`。
fn page_url(path: &str, page: i64) -> String {
    if page <= 1 {
        return path.to_string();
    }
    let re = Regex::new(r"^/vodtype/(\d+)\.html$").unwrap();
    if let Some(c) = re.captures(path) {
        let n = c.get(1).map(|m| m.as_str()).unwrap_or("");
        return format!("/vod/show/id/{n}/page/{page}.html");
    }
    if let Some(base) = path.strip_suffix(".html") {
        format!("{base}-{page}.html")
    } else {
        format!("{path}-{page}.html")
    }
}

/// 视频卡片：按 /vodplay 链接切块，块内取 data-src 封面、alt 片名、时长徽章。
fn parse_cards(html: &str) -> Vec<Value> {
    let img_re = Regex::new(r#"data-src="([^"]+)"[^>]*?alt="([^"]*)""#).unwrap();
    let dur_re = Regex::new(r#"bg-gray-800 bg-opacity-75">([^<]{2,12})<"#).unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a href=\"/vodplay/").skip(1) {
        let end = block.find('"').unwrap_or(block.len());
        let head = &block[..end];
        let digits: String = head.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() || seen.contains(&digits) {
            continue;
        }
        let (cover, title) = match img_re.captures(block) {
            Some(c) => (
                c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
                c.get(2).map(|m| unesc(m.as_str())).unwrap_or_default(),
            ),
            None => continue,
        };
        if title.is_empty() {
            continue;
        }
        seen.push(digits.clone());
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let id = format!("/vodplay/{digits}-1-1.html");
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 从 start（指向 `{`）按括号平衡截取，处理字符串与转义。
fn slice_balanced(text: &str, start: usize) -> Option<&str> {
    let bytes = text.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else if b == b'"' {
            in_str = true;
        } else if b == b'{' {
            depth += 1;
        } else if b == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some(&text[start..i + 1]);
            }
        }
        i += 1;
    }
    None
}

/// 取 player_aaaa JSON：找 `player_aaaa = {` 后按括号平衡截取。
fn player_json(html: &str) -> Option<Value> {
    let pos = html.find("player_aaaa")?;
    let rest = &html[pos..];
    let eq = rest.find('{')?;
    let frag = slice_balanced(rest, eq)?;
    serde_json::from_str(frag).ok()
}

/// 百分号解码（%XX 还原字节）。
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
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// vidOf：url 字段含 % 先 URL 解码，再 base64 解；若为 JSON 取 ss 首项的
/// /api/v/<vid> 路径（取 /api/ 后段），否则取末段。
fn vid_of(raw: &str) -> Option<String> {
    let mut s = raw.trim().to_string();
    if s.contains('%') {
        s = percent_decode(&s);
    }
    let mut padded = s.clone();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let decoded = B64.decode(padded.as_bytes()).ok()?;
    let text = String::from_utf8(decoded).ok()?;
    let text = text.trim().to_string();
    if text.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            if let Some(ss) = get(&v, "ss").and_then(|x| x.as_array()) {
                if let Some(first) = ss.first() {
                    if let Some(str_v) = first.as_str() {
                        return Some(vid_from_path(str_v));
                    }
                    if let Some(arr) = first.as_array() {
                        for item in arr.iter().rev() {
                            if let Some(str_v) = item.as_str() {
                                if !str_v.is_empty() {
                                    return Some(vid_from_path(str_v));
                                }
                            }
                        }
                    }
                }
            }
        }
        return None;
    }
    Some(vid_from_path(&text))
}

/// 从路径/地址取 vid：`/api/v/<vid>` 取后段，否则取末段，去 `?`/`#` 后缀。
fn vid_from_path(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if let Some(idx) = s.find(['?', '#']) {
        s.truncate(idx);
    }
    if let Some(idx) = s.find("/api/v/") {
        return s[idx + 7..].trim_matches('/').to_string();
    }
    if let Some(idx) = s.find("/api/") {
        return s[idx + 5..].trim_matches('/').to_string();
    }
    s.trim_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

/// 取 og:image。
fn og_image(html: &str) -> String {
    let re = Regex::new(r#"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

/// 取 og:description。
fn og_description(html: &str) -> String {
    let re = Regex::new(r#"<meta[^>]+property="og:description"[^>]+content="([^"]+)""#).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

/// 取 <h1> 文本。
fn h1_text(html: &str) -> String {
    let re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| {
            let t = m.as_str();
            let tag = Regex::new(r"<[^>]+>").unwrap();
            unesc(tag.replace_all(t, "").as_ref())
        })
        .unwrap_or_default()
}

/// 由详情页取 vid：抓 player_aaaa 的 url 字段再 vidOf。
async fn vid_from_detail_page(path: &str) -> ApiResult<String> {
    let (_host, html) = fetch(path).await?;
    let player =
        player_json(&html).ok_or_else(|| ApiError::Internal("rouAV 详情未取到播放信息".into()))?;
    let url = text_of(&player, &["url"]);
    vid_of(&url).ok_or_else(|| ApiError::Internal("rouAV 播放地址解码失败".into()))
}

/// 跟随跳转取最终地址：GET 地址，若最终地址含 .m3u8 或正文为清单则回最终地址。
async fn resolve_redirect(url: &str) -> ApiResult<String> {
    let mut last_err = ApiError::Internal("rouAV 取流失败".into());
    for host in HOSTS {
        let resp = client()?
            .get(url)
            .header("User-Agent", UA)
            .header("Accept", "*/*")
            .header("Referer", format!("{host}/enter"))
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
            last_err = ApiError::Internal(format!("rouAV 取流 HTTP {}", resp.status().as_u16()));
            continue;
        }
        if final_url.contains(".m3u8") {
            return Ok(final_url);
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if text.trim_start().starts_with("#EXTM3U") {
            return Ok(final_url);
        }
        return Ok(url.to_string());
    }
    Err(last_err)
}

/// 取流：GET /api/v/<vid> 取 video.videoUrl，取不到回退 /api/hls/<vid>。
async fn source_url(vid: &str) -> ApiResult<String> {
    let mut last_err = ApiError::Internal("rouAV 取流失败".into());
    for path in [format!("/api/v/{vid}"), format!("/api/hls/{vid}")] {
        for host in HOSTS {
            let url = format!("{host}{path}");
            let resp = client()?
                .get(&url)
                .header("User-Agent", UA)
                .header("Accept", "application/json, text/plain, */*")
                .header("Referer", format!("{host}/enter"))
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
                last_err =
                    ApiError::Internal(format!("rouAV 取流 HTTP {}", resp.status().as_u16()));
                continue;
            }
            let text = match resp.text().await {
                Ok(t) => t,
                Err(e) => {
                    last_err = ApiError::Internal(e.to_string());
                    continue;
                }
            };
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                let video_url = get(&v, "video")
                    .map(|x| text_of(x, &["videoUrl", "url"]))
                    .unwrap_or_default();
                if video_url.starts_with("http") {
                    return resolve_redirect(&video_url).await;
                }
            }
            if text.contains(".m3u8") {
                if let Some(m) = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#)
                    .unwrap()
                    .find(&text)
                {
                    return Ok(m.as_str().to_string());
                }
            }
            last_err = ApiError::Internal("rouAV 取流未返回地址".into());
        }
    }
    Err(last_err)
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
    let tid = if tid.is_empty() { "/enter" } else { tid };
    let url = page_url(tid, page);
    let (_host, html) = fetch(&url).await?;
    let cards = parse_cards(&html);
    let has_more = cards.len() >= 20;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let digits: String = sid.chars().filter(|c| c.is_ascii_digit()).collect();
    let path = format!("/vodplay/{digits}-1-1.html");
    let (_host, html) = fetch(&path).await?;
    if html.len() < 500 {
        let (_h2, list_html) = fetch("/enter").await?;
        let works = parse_cards(&list_html);
        let mut episodes: Vec<Value> = Vec::new();
        for work in works.iter().take(60) {
            let vid = work.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let title = work.get("title").and_then(|v| v.as_str()).unwrap_or("");
            if vid.is_empty() || title.is_empty() {
                continue;
            }
            episodes.push(episode_json(vid, title, sid));
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("rouAV 未返回影片资料".into()));
        }
        return Ok(json!({
            "id": sid,
            "title": "rouAV",
            "cover": "",
            "synopsis": "详情页未返回正文，列出首页作品",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let player = player_json(&html);
    let vid = player
        .as_ref()
        .map(|p| text_of(p, &["url"]))
        .and_then(|u| vid_of(&u));
    let title = player
        .as_ref()
        .and_then(|p| get(p, "vod_data"))
        .map(|d| text_of(d, &["name", "title", "vod_name"]))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| h1_text(&html));
    if title.is_empty() {
        return Err(ApiError::Internal("rouAV 未返回影片资料".into()));
    }
    let cover = player
        .as_ref()
        .and_then(|p| get(p, "vod_data"))
        .map(|d| text_of(d, &["pic", "cover", "vod_pic"]))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| og_image(&html));
    let mut synopsis = String::new();
    if let Some(p) = player.as_ref() {
        let actor = text_of(p, &["vod_actor"]);
        if !actor.is_empty() {
            synopsis.push_str(&format!("演员：{actor}\n"));
        }
        let class = text_of(p, &["vod_class"]);
        if !class.is_empty() {
            synopsis.push_str(&format!("分类：{class}\n"));
        }
    }
    let desc = og_description(&html);
    if !desc.is_empty() {
        synopsis.push_str(&desc);
    }
    let vid = match vid {
        Some(v) => v,
        None => return Err(ApiError::Internal("rouAV 未取到播放地址".into())),
    };
    let episodes = vec![episode_json(&vid, "正片", sid)];
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
    let url = with_query("/vod/search.html", &[("wd", query.trim()), ("page", "1")]);
    let (_host, html) = fetch(&url).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") && vid.contains(".m3u8") {
        return Ok(json!({"url": vid}));
    }
    let vid_owned: String =
        if vid.starts_with("/vodplay/") || vid.chars().all(|c| c.is_ascii_digit()) {
            vid_from_detail_page(vid).await?
        } else {
            vid.to_string()
        };
    let url = source_url(&vid_owned).await?;
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_7() {
        assert_eq!(CATEGORIES.len(), 7);
        assert_eq!(CATEGORIES[1], ("/vodtype/7.html", "国产AV"));
    }

    #[test]
    fn page_url_rules() {
        assert_eq!(page_url("/enter", 1), "/enter");
        assert_eq!(page_url("/enter", 2), "/enter-2.html");
        assert_eq!(page_url("/vodtype/7.html", 2), "/vod/show/id/7/page/2.html");
    }

    #[test]
    fn vid_of_api_path() {
        let inner = r#"{"ss":[[3,"/api/v/cmw0czih90000vn5obea24gy"]]}"#;
        let b64 = B64.encode(inner.as_bytes());
        assert_eq!(vid_of(&b64).unwrap(), "cmw0czih90000vn5obea24gy");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a href="/vodplay/6590-1-1.html"><img data-src="https://pic/c.jpg" alt="Sample Title"><span class="bg-gray-800 bg-opacity-75">12:34</span></a>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/vodplay/6590-1-1.html");
        assert_eq!(cards[0]["remark"], "12:34");
    }
}
