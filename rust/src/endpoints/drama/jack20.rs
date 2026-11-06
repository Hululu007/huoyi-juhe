//! 後宮電影院：WP 站 + xvideos 聚合。
//!
//! 来源 jar 类 `ZakaJack20Amns`（`https://20jack.com`）。
//! 列表走 `/?filter=latest` 与 `/?cat={id}`；详情走 `/?p={id}`，
//! 取 `player-x.php?q=...` 嵌码（base64 + URL 编码的 iframe），
//! 再从 xvideos 嵌页取 `setVideoHLS` / `setVideoUrlHigh` /
//! `setVideoUrlLow` 的真实地址。

use base64::Engine as _;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://20jack.com";
const UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("6364", "日本無碼"),
    ("788", "歐美短片"),
    ("3419", "國語長片"),
    ("6365", "日本有碼"),
    ("4071", "卡通短片"),
    ("6404", "其它短片"),
    ("819", "其他長片"),
    ("5346", "卡通長片"),
    ("5422", "歐美長片"),
];

static RE_POST_ID: Lazy<Regex> = Lazy::new(|| Regex::new(r#"id="post-(\d+)""#).unwrap());
static RE_POST_CLASS: Lazy<Regex> = Lazy::new(|| Regex::new(r"post-(\d+)").unwrap());
static RE_LINK: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<a[^>]*href="[^"]*\?p=(\d+)"[^>]*>"#).unwrap());
static RE_TITLE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"<a[^>]*title="([^"]+)""#).unwrap());
static RE_THUMB: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r#"class="[^"]*video-main-thumb[^"]*"[^>]*>(?:(?s).{0,1200}?)(?:data-src|src)="([^"]+)""#,
    )
    .unwrap()
});
static RE_THUMB_ATTR: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"data-main-thumb="([^"]+)""#).unwrap());
static RE_THUMBS: Lazy<Regex> = Lazy::new(|| Regex::new(r#"data-thumbs="([^"]+)""#).unwrap());
static RE_VIEWS: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<span class="views">(?:<[^>]*>)*\s*([^<]*)</span>"#).unwrap());
static RE_DUR: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<span class="duration">(?:<[^>]*>)*\s*([^<]*)</span>"#).unwrap());
static RE_PAGED: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"paged=(\d+)"[^>]*>(?:\d+|Next|»)"#).unwrap());

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn abs_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{BASE}{u}")
    } else {
        u.to_string()
    }
}

async fn html(path: &str) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("後宮電影院请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 2000 {
        return Err(ApiError::Internal("後宮電影院页面过短".into()));
    }
    Ok(text)
}

fn cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for block in page.split("<article") {
        if block.len() < 200 {
            continue;
        }
        let block = &block[..block.len().min(4000)];
        let Some(id) = RE_POST_ID
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .or_else(|| {
                RE_POST_CLASS
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
        else {
            continue;
        };
        let link_id = RE_LINK
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string());
        if link_id.is_none() {
            continue;
        }
        if !seen.insert(id.clone()) {
            continue;
        }
        let title = RE_TITLE
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unescape(m.as_str()))
            .unwrap_or_default();
        let mut cover = RE_THUMB
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .or_else(|| {
                RE_THUMB_ATTR
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
            .or_else(|| {
                RE_THUMBS
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().split(',').next().unwrap_or("").to_string())
            })
            .unwrap_or_default();
        if cover.is_empty() {
            static RE_IMG: Lazy<Regex> =
                Lazy::new(|| Regex::new(r#"<img[^>]*(?:data-src|src)="([^"]+)""#).unwrap());
            cover = RE_IMG
                .captures_iter(block)
                .filter_map(|c| c.get(1))
                .last()
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
        }
        let cover = abs_url(&cover);
        let views = RE_VIEWS
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| {
                m.as_str()
                    .replace("views", "")
                    .replace('次', "")
                    .trim()
                    .to_string()
            })
            .unwrap_or_default();
        let dur = RE_DUR
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let remark = match (views.is_empty(), dur.is_empty()) {
            (false, false) => format!("{dur} · {views}次"),
            (false, true) => format!("{views}次"),
            (true, false) => dur,
            (true, true) => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

/// 百分号解码（`%XX` 还原字节，`+` 还原为空格），与 Java
/// `URLDecoder.decode` 同义。
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                if let Ok(n) = u8::from_str_radix(hex, 16) {
                    out.push(n);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// base64（标准与 URL 安全双试，取较长者）再 URL 解码，取 iframe src。
fn embed_url(q: &str) -> String {
    let mut best = String::new();
    for engine in [
        base64::engine::general_purpose::STANDARD,
        base64::engine::general_purpose::URL_SAFE,
    ] {
        let decoded = engine.decode(q.as_bytes()).unwrap_or_default();
        let text = String::from_utf8_lossy(&decoded).to_string();
        if text.len() > best.len() {
            best = text;
        }
    }
    let unescaped = percent_decode(&best);
    static RE_SRC: Lazy<Regex> = Lazy::new(|| Regex::new(r#"src="([^"]+)""#).unwrap());
    static RE_URL: Lazy<Regex> = Lazy::new(|| Regex::new(r#"https?://[^\s"'<>]+"#).unwrap());
    if let Some(m) = RE_SRC.captures(&unescaped).and_then(|c| c.get(1)) {
        return m.as_str().to_string();
    }
    if let Some(m) = RE_URL.find(&unescaped) {
        return m.as_str().to_string();
    }
    unescaped
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![category_json("home", "最新影片")];
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let base = if category_id.is_empty() || category_id == "home" {
        "/?filter=latest".to_string()
    } else {
        format!("/?cat={category_id}")
    };
    let path = if page > 1 {
        format!("{base}&paged={page}")
    } else {
        base
    };
    let page_html = html(&path).await?;
    let items = cards(&page_html);
    let max_page = RE_PAGED
        .captures_iter(&page_html)
        .filter_map(|c| c.get(1)?.as_str().parse::<i64>().ok())
        .max()
        .unwrap_or(0);
    let has_more = if max_page > 0 {
        page < max_page
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    static RE_NUM: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\d+)").unwrap());
    let vid = RE_NUM
        .captures(series_id)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| series_id.to_string());
    let page_html = html(&format!("/?p={vid}")).await?;
    let re_og_title = Regex::new(r#"og:title"\s+content="([^"]+)""#).unwrap();
    let re_h1 = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let re_og_img = Regex::new(r#"og:image"\s+content="([^"]+)""#).unwrap();
    let re_desc = Regex::new(r#"name="description"\s+content="([^"]*)""#).unwrap();
    let re_date = Regex::new(r#"uploadDate"\s+content="([^"]+)""#).unwrap();
    let re_q = Regex::new(r"player-x\.php\?q=([A-Za-z0-9+/=]+)").unwrap();
    let re_q2 = Regex::new(r#"clean-tube-player[^"']*?q=([A-Za-z0-9+/=]+)"#).unwrap();
    let mut title = unescape(&cap1(&re_og_title, &page_html));
    if title.is_empty() {
        title = re_h1
            .captures(&page_html)
            .and_then(|c| c.get(1))
            .map(|m| unescape(m.as_str()))
            .unwrap_or_default();
    }
    let cover = abs_url(&cap1(&re_og_img, &page_html));
    let desc = unescape(&cap1(&re_desc, &page_html));
    let date = cap1(&re_date, &page_html);
    let q = cap1(&re_q, &page_html);
    let q = if q.is_empty() {
        cap1(&re_q2, &page_html)
    } else {
        q
    };
    if q.is_empty() {
        return Err(ApiError::Internal("後宮電影院详情未取到播放嵌码".into()));
    }
    let embed = embed_url(&q);
    if embed.is_empty() {
        return Err(ApiError::Internal("後宮電影院嵌码解析失败".into()));
    }
    let synopsis = format!(
        "{}{}来源：後宮電影院",
        if desc.is_empty() {
            String::new()
        } else {
            format!("{desc}\n")
        },
        if date.is_empty() {
            String::new()
        } else {
            format!("日期：{date}\n")
        },
    );
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"date": date},
        "episodes": [
            episode_json(&format!("hls:{embed}"), "線路①HLS", series_id),
            episode_json(&format!("mp4:{embed}"), "線路②MP4", series_id),
        ],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let page_html = html(&format!("/?s={enc}")).await?;
    Ok(json!({"items": cards(&page_html)}))
}

/// 从嵌页取真实流地址；`prefer_hls` 为 false 时 MP4 优先。
async fn resolve(embed: &str, prefer_hls: bool) -> String {
    let host = url::Url::parse(embed)
        .map(|u| format!("{}://{}/", u.scheme(), u.host_str().unwrap_or("")))
        .unwrap_or_default();
    let Some(c) = client().ok() else {
        return embed.to_string();
    };
    let Ok(resp) = c
        .get(embed)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,en;q=0.8")
        .header("Referer", host)
        .send()
        .await
    else {
        return embed.to_string();
    };
    let Ok(text) = resp.text().await else {
        return embed.to_string();
    };
    if text.len() < 200 {
        return embed.to_string();
    }
    let re_hls = Regex::new(r"setVideoHLS\('([^']+)'\)").unwrap();
    let re_high = Regex::new(r"setVideoUrlHigh\('([^']+)'\)").unwrap();
    let re_low = Regex::new(r"setVideoUrlLow\('([^']+)'\)").unwrap();
    let re_any_m3u8 = Regex::new(r#"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#).unwrap();
    let re_any_mp4 = Regex::new(r#"(https?://[^\s"'<>]+\.mp4[^\s"'<>]*)"#).unwrap();
    let fix = |u: &str| -> String {
        let u = u.replace("\\/", "/");
        if let Some(rest) = u.strip_prefix("//") {
            format!("https://{rest}")
        } else {
            u
        }
    };
    let hls = cap1(&re_hls, &text);
    let high = cap1(&re_high, &text);
    let low = cap1(&re_low, &text);
    let pick = if prefer_hls {
        if !hls.is_empty() {
            hls
        } else if !high.is_empty() {
            high
        } else {
            low
        }
    } else if !high.is_empty() {
        high
    } else if !low.is_empty() {
        low
    } else {
        hls
    };
    if !pick.is_empty() {
        return fix(&pick);
    }
    let any = if prefer_hls {
        cap1(&re_any_m3u8, &text)
    } else {
        cap1(&re_any_mp4, &text)
    };
    if !any.is_empty() {
        return fix(&any);
    }
    let any2 = if prefer_hls {
        cap1(&re_any_mp4, &text)
    } else {
        cap1(&re_any_m3u8, &text)
    };
    if !any2.is_empty() {
        return fix(&any2);
    }
    embed.to_string()
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (prefer_hls, embed) = if let Some(rest) = video_id.strip_prefix("hls:") {
        (true, rest.to_string())
    } else if let Some(rest) = video_id.strip_prefix("mp4:") {
        (false, rest.to_string())
    } else {
        (true, video_id.to_string())
    };
    if embed.is_empty() {
        return Err(ApiError::Internal("後宮電影院没有播放地址".into()));
    }
    let url = resolve(&embed, prefer_hls).await;
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embed_url_decodes_b64_iframe() {
        let iframe = "<iframe src=\"https://www.xvideos.com/embedframe/123\"></iframe>";
        let encoded = base64::engine::general_purpose::STANDARD.encode(iframe);
        assert_eq!(
            embed_url(&encoded),
            "https://www.xvideos.com/embedframe/123"
        );
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<article id="post-123" class="post-123"><a href="https://20jack.com/?p=123" title="Sample"><div class="video-main-thumb"><img src="//cdn.example.com/1.jpg"></div><span class="views">1234 views</span><span class="duration">05:06</span></a></article>"##;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "123");
        assert_eq!(items[0]["title"], "Sample");
        assert_eq!(items[0]["cover"], "https://cdn.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "05:06 · 1234次");
    }
}
