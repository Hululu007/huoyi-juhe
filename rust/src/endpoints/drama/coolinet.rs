//! 酷愛成人網：WP 全站直取。
//!
//! 来源 jar 类 `ZakaCoolinetAmns`。多个备用 host 依次试；列表走
//! WP 分类页；详情优先走 WP REST `/wp-json/wp/v2/posts/{id}?_embed=1`，
//! 失败回退取 `/?p={id}`；取流走 iframe 里的 `player_coolinet`
//! 播放器页，取 `loadSource('....m3u8...')`。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of};

const UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const PLAYER_REF: &str = "https://www.coolinet.net/";
const HOSTS: &[&str] = &["https://www.230304.xyz", "https://www.coolinet.net"];

const CATS: &[(&str, &str, i64)] = &[
    ("chinese-subtitle", "中文字幕", 60),
    ("asia-video", "亞洲AV", 50),
    ("eu-us-movie", "歐美AV", 4),
    ("%e7%9b%b4%e6%92%ad", "直播", 64),
    (
        "%e4%ba%9e%e6%b4%b2%e8%87%aa%e6%8b%8d%e5%81%b7%e6%8b%8d",
        "亞洲自拍偷拍",
        56,
    ),
    ("eu-us-self", "歐美自拍偷拍", 49),
    ("%e6%80%a7%e6%84%9f%e7%be%8e%e5%9c%96", "性感美圖", 65),
];

static RE_CARD: Lazy<Regex> = Lazy::new(|| Regex::new(r#"<div class="videoPost"#).unwrap());
static RE_ID: Lazy<Regex> = Lazy::new(|| Regex::new(r#"id="post-(\d+)""#).unwrap());
static RE_TITLE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"class="videoLink"[^>]*title="([^"]+)""#).unwrap());
static RE_TITLE_ANY: Lazy<Regex> = Lazy::new(|| Regex::new(r#"title="([^"]+)""#).unwrap());
static RE_IMG: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<img[^>]*(?:data-src|src)="([^"]+)""#).unwrap());
static RE_VIEWS: Lazy<Regex> = Lazy::new(|| Regex::new(r#"thumbViews">([^<]*)</"#).unwrap());
static RE_END: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"class="end"[^>]*href="[^"]*?/page/(\d+)/""#).unwrap());

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn strip_tags(s: &str) -> String {
    let tag = Regex::new(r"<[^>]*>").unwrap();
    let collapsed = Regex::new(r"\s+").unwrap();
    collapsed
        .replace_all(tag.replace_all(s, " ").as_ref(), " ")
        .trim()
        .to_string()
}

fn abs_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("https://www.coolinet.net{u}")
    } else {
        u.to_string()
    }
}

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

async fn fetch_host(host: &str, path: &str) -> ApiResult<String> {
    let url = format!("{host}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,en;q=0.8")
        .header("Referer", PLAYER_REF)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("酷愛成人網请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 2000 {
        return Err(ApiError::Internal("酷愛成人網页面过短".into()));
    }
    Ok(text)
}

async fn fetch_any(path: &str) -> ApiResult<String> {
    let mut last_err = ApiError::Internal("酷愛成人網全部 host 不通".into());
    for host in HOSTS {
        match fetch_host(host, path).await {
            Ok(page) => return Ok(page),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

async fn fetch_json_any(path: &str) -> ApiResult<Value> {
    let mut last_err = ApiError::Internal("酷愛成人網 REST 全部 host 不通".into());
    for host in HOSTS {
        let url = format!("{host}{path}");
        let resp = match client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json")
            .header("Accept-Language", "zh-TW,zh;q=0.9,en;q=0.8")
            .header("Referer", PLAYER_REF)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if resp.status().as_u16() != 200 {
            last_err = ApiError::Internal(format!("REST HTTP {}", resp.status()));
            continue;
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        match serde_json::from_str::<Value>(&text) {
            Ok(v) => return Ok(v),
            Err(e) => last_err = ApiError::Internal(e.to_string()),
        }
    }
    Err(last_err)
}

fn cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for block in RE_CARD.split(page).skip(1) {
        let block = &block[..block.len().min(3000)];
        let Some(id) = RE_ID
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str())
        else {
            continue;
        };
        if !seen.insert(id.to_string()) {
            continue;
        }
        let mut title = cap1(&RE_TITLE, block);
        if title.is_empty() {
            title = cap1(&RE_TITLE_ANY, block);
        }
        let cover = RE_IMG
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(m.as_str()))
            .unwrap_or_default();
        let views = cap1(&RE_VIEWS, block)
            .replace(" 觀看", "")
            .replace("觀看", "")
            .trim()
            .to_string();
        let remark = if views.is_empty() {
            String::new()
        } else {
            format!("{views}次")
        };
        items.push(item_json(id, &unescape(&title), &cover, &remark));
    }
    items
}

/// 播放器页取 m3u8；含“想看A片”且无 m3u8 时返回空。
async fn resolve_player(player_url: &str) -> String {
    let Ok(resp) = client()
        .ok()?
        .get(player_url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,*/*")
        .header("Accept-Language", "zh-TW,zh;q=0.9,en;q=0.8")
        .header("Referer", PLAYER_REF)
        .send()
        .await
    else {
        return player_url.to_string();
    };
    let Ok(text) = resp.text().await else {
        return player_url.to_string();
    };
    if text.contains("想看A片") && !text.contains(".m3u8") {
        return String::new();
    }
    let re_load = Regex::new(r"loadSource\('([^']+\.m3u8[^']*)'\)").unwrap();
    let re_any = Regex::new(r#"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#).unwrap();
    let url = cap1(&re_load, &text);
    let url = if url.is_empty() {
        cap1(&re_any, &text)
    } else {
        url
    };
    if url.is_empty() {
        player_url.to_string()
    } else {
        url.replace("\\/", "/")
    }
}

/// iframe URL 里的 `player=N` 换成指定线路。
fn with_player(iframe: &str, n: i64) -> String {
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"player=\d+").unwrap());
    if RE.is_match(iframe) {
        RE.replace(iframe, format!("player={n}")).to_string()
    } else if iframe.contains('?') {
        format!("{iframe}&player={n}")
    } else {
        format!("{iframe}?player={n}")
    }
}

fn iframe_of(page: &str) -> String {
    let re1 = Regex::new(r#"src="(//video[^"]*player_coolinet[^"]*)""#).unwrap();
    let re2 = Regex::new(r#"(https?://[^"'\s<>]*player_coolinet[^"'\s<>]*)"#).unwrap();
    let re3 =
        Regex::new(r#"(https?://[^"'\s<>]*yocoolnet\.in[^"'\s<>]*player[^"'\s<>]*)"#).unwrap();
    let url = cap1(&re1, page);
    let url = if url.is_empty() {
        cap1(&re2, page)
    } else {
        url
    };
    let url = if url.is_empty() {
        cap1(&re3, page)
    } else {
        url
    };
    abs_url(&url)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![category_json("home", "最新發表")];
    for (slug, name, _) in CATS {
        list.push(category_json(slug, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let path = if category_id.is_empty() || category_id == "home" {
        if page > 1 {
            format!("/page/{page}/")
        } else {
            "/".to_string()
        }
    } else if page > 1 {
        format!("/category/{category_id}/page/{page}/")
    } else {
        format!("/category/{category_id}/")
    };
    let page_html = fetch_any(&path).await?;
    let mut items = cards(&page_html);
    if items.is_empty() {
        // 兜底：以 post- 为标记重切。
        let mut seen = std::collections::HashSet::new();
        for block in page_html.split("post-").skip(1) {
            let id = block.split('"').next().unwrap_or("");
            if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            if !seen.insert(id.to_string()) {
                continue;
            }
            let block = &block[..block.len().min(3000)];
            let title = cap1(&RE_TITLE_ANY, block);
            let cover = RE_IMG
                .captures(block)
                .and_then(|c| c.get(1))
                .map(|m| abs_url(m.as_str()))
                .unwrap_or_default();
            items.push(item_json(id, &unescape(&title), &cover, ""));
        }
    }
    let max_page = RE_END
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
    let rest = fetch_json_any(&format!("/wp-json/wp/v2/posts/{vid}?_embed=1")).await;
    let (mut title, mut cover, mut synopsis, mut iframe, mut cat_name) = (
        String::new(),
        String::new(),
        String::new(),
        String::new(),
        String::new(),
    );
    if let Ok(body) = rest {
        title = unescape(&text_of(&body, &["title", "rendered"]));
        let date = text_of(&body, &["date"]);
        let content = text_of(&body, &["content", "rendered"]);
        let excerpt = text_of(&body, &["excerpt", "rendered"]);
        synopsis = strip_tags(if content.is_empty() {
            &excerpt
        } else {
            &content
        });
        if !date.is_empty() {
            synopsis = format!(
                "日期：{}\n{synopsis}",
                date.chars().take(10).collect::<String>()
            );
        }
        if let Some(media) = get(&body, "_embedded")
            .and_then(|e| get(e, "wp:featuredmedia"))
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
        {
            cover = text_of(media, &["source_url"]);
            if cover.is_empty() {
                if let Some(sizes) = get(media, "media_details").and_then(|m| get(m, "sizes")) {
                    for key in ["medium_large", "large", "full"] {
                        cover = text_of(sizes, &[key, "source_url"]);
                        if !cover.is_empty() {
                            break;
                        }
                    }
                }
            }
        }
        if cover.is_empty() {
            if let Some(fm) = get(&body, "featured_media").and_then(|v| v.as_i64()) {
                if fm > 0 {
                    if let Ok(media) = fetch_json_any(&format!("/wp-json/wp/v2/media/{fm}")).await {
                        cover = text_of(&media, &["source_url"]);
                    }
                }
            }
        }
        if let Some(cats) = get(&body, "categories").and_then(|v| v.as_array()) {
            for c in cats {
                if let Some(id) = c.as_i64() {
                    if let Some((_, name, _)) = CATS.iter().find(|(_, _, cid)| *cid == id) {
                        cat_name = name.to_string();
                        break;
                    }
                }
            }
        }
        iframe = iframe_of(&content);
        if iframe.is_empty() {
            iframe = iframe_of(&excerpt);
        }
    }
    if title.is_empty() || iframe.is_empty() {
        // 回退：取文章页。
        let page_html = fetch_any(&format!("/?p={vid}")).await?;
        if title.is_empty() {
            let re_h2 = Regex::new(r"(?s)<h2[^>]*>(.*?)</h2>").unwrap();
            let re_title = Regex::new(r"<title>([^<]+)</title>").unwrap();
            title = re_h2
                .captures(&page_html)
                .and_then(|c| c.get(1))
                .map(|m| strip_tags(m.as_str()))
                .unwrap_or_default();
            if title.is_empty() {
                title = cap1(&re_title, &page_html)
                    .replace("酷愛成人網", "")
                    .replace("–coolinet.net", "")
                    .replace("coolinet.net", "")
                    .trim()
                    .to_string();
            }
        }
        if iframe.is_empty() {
            iframe = iframe_of(&page_html);
        }
        if synopsis.is_empty() {
            let re_content = Regex::new(r#"(?s)id="videoPostContent"[^>]*>(.*?)</"#).unwrap();
            synopsis = re_content
                .captures(&page_html)
                .and_then(|c| c.get(1))
                .map(|m| strip_tags(m.as_str()))
                .unwrap_or_default();
        }
        if cat_name.is_empty() {
            let re_class = Regex::new(r#"class="[^"]*hentry[^"]*""#).unwrap();
            if let Some(class) = re_class.find(&page_html) {
                let class = class.as_str();
                for slug in [
                    "chinese-subtitle",
                    "asia-video",
                    "eu-us-movie",
                    "eu-us-self",
                ] {
                    if class.contains(&format!("category-{slug}")) {
                        cat_name = CATS
                            .iter()
                            .find(|(s, _, _)| *s == slug)
                            .map(|(_, n, _)| n.to_string())
                            .unwrap_or_default();
                        break;
                    }
                }
            }
        }
    }
    if iframe.is_empty() {
        return Err(ApiError::Internal("酷愛成人網详情未取到播放器".into()));
    }
    if title.is_empty() {
        title = format!("酷愛成人網 {vid}");
    }
    let synopsis = format!(
        "{}{}来源：酷愛成人網",
        if cat_name.is_empty() {
            String::new()
        } else {
            format!("分類：{cat_name}\n")
        },
        synopsis,
    );
    let episodes = vec![
        episode_json(&with_player(&iframe, 1), "酷愛①", series_id),
        episode_json(&with_player(&iframe, 2), "酷愛②", series_id),
        episode_json(&with_player(&iframe, 3), "酷愛③", series_id),
    ];
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"category": cat_name},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let page_html = fetch_any(&format!("/?s={enc}")).await?;
    let mut items = cards(&page_html);
    if items.is_empty() {
        let page_html = fetch_any(&format!("/page/1/?s={enc}")).await?;
        items = cards(&page_html);
    }
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.is_empty() {
        return Err(ApiError::Internal("酷愛成人網没有播放地址".into()));
    }
    let url = resolve_player(video_id).await;
    if url.is_empty() {
        return Err(ApiError::Internal("酷愛成人網播放器未取到 m3u8".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_player_rewrites() {
        assert_eq!(
            with_player("https://x/player.php?player=1&v=2", 3),
            "https://x/player.php?player=3&v=2"
        );
        assert_eq!(
            with_player("https://x/player.php?v=2", 2),
            "https://x/player.php?v=2&player=2"
        );
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<div class="videoPost" id="post-123"><a class="videoLink" title="Sample Title" href="/?p=123"><img src="//cdn.example.com/1.jpg"></a><span class="thumbViews">1234 觀看</span></div>"##;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "123");
        assert_eq!(items[0]["title"], "Sample Title");
        assert_eq!(items[0]["cover"], "https://cdn.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "1234次");
    }
}
