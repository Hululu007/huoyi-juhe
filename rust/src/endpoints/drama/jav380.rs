//! JAV380：`https://www.jav380.com/`。
//!
//! 来源 jar 类 `ZakaJav380Amns`。WordPress 站：分类静态表 31 条，
//! 列表页按 `<div class="post-container">` 切块，标题/封面（srcset
//! 取最大档）/日期；详情另取 WP JSON
//! `/wp-json/wp/v2/posts?slug=<slug>&_fields=content` 作简介；分集
//! 为 iframe 地址（`m|` 前缀）；取流 `resolve`：抓第三方页取
//! `get3G.php?rand=<n>&id=<id>&key=<n>&mp4=` 参数再拼直链，优先
//! m3u8、其次 mp4。
//!
//! 注意：本站有 Cloudflare 盾，本机出口实测三次请求全部失败
//! （首页 ChunkedEncodingError；curl 得 403 “Just a moment...”
//! 挑战页；WP JSON 同样被拦）。jar 靠 `ZakaShield.fetch` 过盾，
//! 核心无 CF 求解器，故本文件按 jar 逻辑原样写，端点未在本机验通，
//! 须手机侧复验。封面与列表页不走本地代理（核心无 `pageRelay` /
//! `picWrap`），相对地址直接拼基址。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://www.jav380.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATEGORIES: &[(&str, &str)] = &[
    ("n|", "🔥最新上架"),
    ("c|uncensored", "🔥无修正"),
    ("c|censored", "🔥修正"),
    ("c|ea", "🔥海外・欧米系"),
    ("t|fc2ppv", "FC2PPV"),
    ("t|fc2-ppv", "FC2 PPV"),
    ("t|1pondo", "1pondo"),
    ("t|%e4%b8%80%e6%9c%ac%e9%81%93", "一本道"),
    ("t|10musume", "10musume"),
    ("t|caribbeancom", "Caribbeancom"),
    ("t|heyzo", "HEYZO"),
    ("t|h4610", "H4610"),
    ("t|c0930", "C0930"),
    ("t|h0930", "H0930"),
    ("t|pacopacomama", "パコパコママ"),
    ("t|mywife", "Mywife"),
    ("t|kin8tengoku", "金8天国"),
    (
        "t|%e5%a4%a9%e7%84%b6%e3%82%80%e3%81%99%e3%82%81",
        "天然むすめ",
    ),
    (
        "t|%e3%83%97%e3%83%ac%e3%82%b9%e3%83%86%e3%83%bc%e3%82%b8",
        "プレステージ",
    ),
    (
        "t|sod%e3%82%af%e3%83%aa%e3%82%a8%e3%82%a4%e3%83%88",
        "SODクリエイト",
    ),
    ("t|%e3%83%9e%e3%83%89%e3%83%b3%e3%83%8a", "マドンナ"),
    (
        "t|%e7%86%9f%e5%a5%b3%e5%80%b6%e6%a5%bd%e9%83%a8",
        "熟女倶楽部",
    ),
    ("t|%e4%ba%ba%e5%a6%bb%e6%96%ac%e3%82%8a", "人妻斬り"),
    ("t|%e5%b7%a8%e4%b9%b3", "巨乳"),
    ("t|julia", "JULIA"),
    ("t|juy", "JUY"),
    ("t|3p%e3%83%bb4p", "3P・4P"),
    (
        "t|4%e6%99%82%e9%96%93%e4%bb%a5%e4%b8%8a%e4%bd%9c%e5%93%81",
        "4時間以上",
    ),
    ("t|leaked", "Leaked 流出"),
    ("t|%e6%96%b0%e4%ba%ba", "新人"),
];

/// 分类 id 拼列表页地址（jar `catUrl` 原样）。
fn cat_url(tid: &str, page: i64) -> String {
    if tid == "n|" {
        return format!("{BASE}/page/{page}/");
    }
    if let Some(slug) = tid.strip_prefix("c|") {
        return format!("{BASE}/category/{slug}/page/{page}/");
    }
    if let Some(slug) = tid.strip_prefix("t|") {
        return format!("{BASE}/tag/{slug}/page/{page}/");
    }
    format!("{BASE}/page/{page}/")
}

/// 去 HTML 标签与空白（jar `clean` / `strip` 的等价实现）。
fn strip_tags(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let out = tag_re.replace_all(s, " ");
    let out = unescape(&out);
    ws_re.replace_all(out.trim(), " ").to_string()
}

/// 解常见 HTML 实体（jar `ZakaHttp.unescape` 的常用子集）。
fn unescape(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ");
    // 数字实体 &#123; / &#x7b;
    let dec_re = Regex::new(r"&#(\d+);").unwrap();
    out = dec_re
        .replace_all(&out, |c: &regex::Captures| {
            c[1].parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|ch| ch.to_string())
                .unwrap_or_default()
        })
        .to_string();
    let hex_re = Regex::new(r"&#x([0-9a-fA-F]+);").unwrap();
    out = hex_re
        .replace_all(&out, |c: &regex::Captures| {
            u32::from_str_radix(&c[1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(|ch| ch.to_string())
                .unwrap_or_default()
        })
        .to_string();
    out
}

/// 相对地址补基址。
fn abs_url(u: &str) -> String {
    let u = u.trim();
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https:{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    format!("{BASE}/{u}")
}

/// srcset 取最大档（jar `pickPic`）：`url 800w, url2 1200w` 取宽最大者。
fn pick_pic(srcset: &str) -> String {
    let mut best = String::new();
    let mut best_w = 0i64;
    for part in srcset.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let mut iter = part.split_whitespace();
        let url = iter.next().unwrap_or("").to_string();
        let mut width = 0i64;
        if let Some(w) = iter.next() {
            if let Some(num) = w.strip_suffix('w') {
                width = num.parse::<i64>().unwrap_or(0);
            }
        }
        if width >= best_w {
            best_w = width;
            best = url;
        }
    }
    abs_url(&best)
}

/// 从 img 标签取封面：优先 data-srcset/srcset，退 src/data-src。
fn img_pic(img_tag: &str) -> String {
    let srcset_re = Regex::new(r#"(?:data-srcset|srcset)\s*=\s*["']([^"']+)["']"#).unwrap();
    if let Some(c) = srcset_re.captures(img_tag) {
        let pic = pick_pic(&c[1]);
        if !pic.is_empty() {
            return pic;
        }
    }
    let src_re = Regex::new(r#"(?:data-src|src)\s*=\s*["']([^"']+)["']"#).unwrap();
    if let Some(c) = src_re.captures(img_tag) {
        return abs_url(&c[1]);
    }
    String::new()
}

async fn fetch_html(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAV380 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 列表页解析（jar `parseList`）：每页 20 条。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let block_re = Regex::new(r#"<div class="post-container">"#).unwrap();
    let parts: Vec<&str> = block_re.split(html).collect();
    let title_re =
        Regex::new(r#"<h2 class="post-title"><a\s+href="([^"]+)"[^>]*>(.*?)</a>"#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+class="[^"]*wp-post-image[^"]*"[^>]*>"#).unwrap();
    let date_re = Regex::new(r#"class="post-date"[^>]*>\s*([0-9\-]{4,12})"#).unwrap();
    for block in parts.iter().skip(1) {
        let Some(tc) = title_re.captures(block) else {
            continue;
        };
        let url = abs_url(&tc[1]);
        let title = strip_tags(&tc[2]);
        if title.is_empty() {
            continue;
        }
        let cover = img_re
            .captures(block)
            .map(|c| img_pic(&c[0]))
            .unwrap_or_default();
        let remark = date_re
            .captures(block)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        items.push(item_json(&url, &title, &cover, &remark));
    }
    items
}

async fn page_items(url: &str) -> ApiResult<Vec<Value>> {
    let html = fetch_html(url).await?;
    Ok(parse_list(&html))
}

/// 详情页 slug：取路径最后一段（去尾部 `/`）。
fn slug_of(url: &str) -> String {
    let trimmed = url.trim_end_matches('/');
    trimmed
        .rsplit('/')
        .next()
        .unwrap_or("")
        .split(['?', '#'])
        .next()
        .unwrap_or("")
        .to_string()
}

/// 详情解析：标题/封面/日期/标签/正文 + WP JSON 简介 + iframe 分集。
fn parse_detail(html: &str, url: &str, wp_content: &str) -> Value {
    let h1_re = Regex::new(r"<h1[^>]*>(.*?)</h1>").unwrap();
    let mut title = h1_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    if let Some(pos) = title.find(" –") {
        title = title[..pos].trim().to_string();
    }
    if title.is_empty() {
        let t_re = Regex::new(r"<title>(.*?)</title>").unwrap();
        title = t_re
            .captures(html)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
    }
    let og_re = Regex::new(r#"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#).unwrap();
    let mut cover = og_re
        .captures(html)
        .map(|c| abs_url(&c[1]))
        .unwrap_or_default();
    if cover.is_empty() {
        let img_re = Regex::new(r#"<img[^>]+class="[^"]*wp-post-image[^"]*"[^>]*>"#).unwrap();
        cover = img_re
            .captures(html)
            .map(|c| img_pic(&c[0]))
            .unwrap_or_default();
    }
    let date_re = Regex::new(r#"class="post-date"[^>]*>\s*([0-9\-]{4,12})"#).unwrap();
    let date = date_re
        .captures(html)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let tag_re = Regex::new(r#"rel="tag"[^>]*>([^<]+)</a>"#).unwrap();
    let mut tags: Vec<String> = Vec::new();
    for c in tag_re.captures_iter(html) {
        let t = strip_tags(&c[1]);
        if !t.is_empty() && !tags.contains(&t) {
            tags.push(t);
        }
    }
    let synopsis = strip_tags(wp_content);
    let iframe_re = Regex::new(r#"<iframe[^>]+src="([^"]+)""#).unwrap();
    let mut episodes = Vec::new();
    if let Some(c) = iframe_re.captures(html) {
        let src = abs_url(&c[1]);
        if !src.is_empty() {
            episodes.push(episode_json(&format!("m|{src}"), "線1", url));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(url, "原頁面", url));
    }
    let mut extra = serde_json::Map::new();
    if !date.is_empty() {
        extra.insert("date".to_string(), json!(date));
    }
    if !tags.is_empty() {
        extra.insert("tags".to_string(), json!(tags.join(" / ")));
    }
    json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    })
}

/// `third`：抓第三方页（Referer 为基址）。
async fn third(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// `decodeResp`：`\'`→`'`、`\"`→`"`，再百分号解码。
fn decode_resp(s: &str) -> String {
    let s = s.replace("\\'", "'").replace("\\\"", "\"");
    percent_encoding::percent_decode_str(&s)
        .decode_utf8_lossy()
        .to_string()
}

/// 取流解析（jar `resolve`）：第三方页取 get3G 参数拼直链，优先 m3u8。
async fn resolve(url: &str) -> ApiResult<String> {
    let page = third(url).await?;
    let g_re = Regex::new(r#"get3G\.php\?rand=(\d+)&id=([^&\"']+)&key=(\d+)&mp4="#).unwrap();
    let Some(c) = g_re.captures(&page) else {
        return Err(ApiError::Internal("JAV380 未找到播放参数".into()));
    };
    let (rand, id, key) = (c[1].to_string(), c[2].to_string(), c[3].to_string());
    let origin = url.split('/').take(3).collect::<Vec<&str>>().join("/");
    let mp4 = if url.contains("mp4") { "1" } else { "0" };
    let target = format!("{origin}/get3G.php?rand={rand}&id={id}&key={key}&mp4={mp4}");
    let body = decode_resp(&third(&target).await?);
    let link_re = Regex::new(r#"https?://[^\\"'<>\s]+\.(m3u8|mp4|txt)(\?|$)"#).unwrap();
    let mut mp4_link = String::new();
    for c in link_re.captures_iter(&body) {
        let link = c[0].trim_end_matches(['?', '&']).to_string();
        if c[1].eq_ignore_ascii_case("m3u8") {
            return Ok(link);
        }
        if mp4_link.is_empty() && c[1].eq_ignore_ascii_case("mp4") {
            mp4_link = link;
        }
    }
    if !mp4_link.is_empty() {
        return Ok(mp4_link);
    }
    Err(ApiError::Internal("JAV380 未解析出播放地址".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATEGORIES
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let items = page_items(&cat_url(category_id, page)).await?;
    let has_more = items.len() >= 20;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let url = abs_url(id);
    let html = fetch_html(&url).await?;
    // WP JSON 简介：失败则简介留空，不阻塞详情。
    let slug = slug_of(&url);
    let mut wp_content = String::new();
    if !slug.is_empty() {
        let api = format!("{BASE}/wp-json/wp/v2/posts?slug={slug}&_fields=content");
        if let Ok(resp) = client()?
            .get(&api)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", format!("{BASE}/"))
            .send()
            .await
        {
            if resp.status().is_success() {
                if let Ok(text) = resp.text().await {
                    if let Ok(body) = serde_json::from_str::<Value>(&text) {
                        if let Some(rows) = arr_of(&body) {
                            if let Some(first) = rows.first() {
                                wp_content = text_of(
                                    get(first, "content").unwrap_or(&Value::Null),
                                    &["rendered"],
                                );
                            }
                        }
                    }
                }
            }
        }
    }
    Ok(parse_detail(&html, &url, &wp_content))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{BASE}/?s={}&paged=1",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let items = page_items(&url).await?;
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let media_re = Regex::new(r#"https?://[^"'<>\s]+\.(m3u8|mp4)(\?|$)"#).unwrap();
    if let Some(rest) = video_id.strip_prefix("m|") {
        let direct = resolve(rest).await?;
        return Ok(json!({"url": direct}));
    }
    if media_re.is_match(video_id) {
        return Ok(json!({"url": video_id}));
    }
    if video_id.contains("jav380.com") {
        // 原頁面：重取详情，取第一集的 iframe 再解析。
        let detail_value = detail(video_id).await?;
        if let Some(eps) = get(&detail_value, "episodes").and_then(arr_of) {
            if let Some(first) = eps.first() {
                let vid = text_of(first, &["video_id"]);
                if let Some(rest) = vid.strip_prefix("m|") {
                    let direct = resolve(rest).await?;
                    return Ok(json!({"url": direct}));
                }
            }
        }
        return Err(ApiError::Internal("JAV380 该页没有可播放分集".into()));
    }
    let direct = resolve(video_id).await?;
    Ok(json!({"url": direct}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cat_url_forms() {
        assert_eq!(cat_url("n|", 2), "https://www.jav380.com/page/2/");
        assert_eq!(
            cat_url("c|uncensored", 1),
            "https://www.jav380.com/category/uncensored/page/1/"
        );
        assert_eq!(
            cat_url("t|fc2ppv", 3),
            "https://www.jav380.com/tag/fc2ppv/page/3/"
        );
    }

    #[test]
    fn pick_pic_takes_largest() {
        let srcset = "https://x/a.jpg 300w, https://x/b.jpg 1024w, https://x/c.jpg 800w";
        assert_eq!(pick_pic(srcset), "https://x/b.jpg");
    }

    #[test]
    fn parse_list_blocks() {
        let html = r#"<div class="post-container"><h2 class="post-title"><a href="/abc-123/">标题一</a></h2><img class="wp-post-image" srcset="https://x/a.jpg 300w, https://x/b.jpg 900w"><div class="post-date">2026-11-01</div></div><div class="post-container"><h2 class="post-title"><a href="https://www.jav380.com/def-456/">标题二</a></h2></div>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["title"], "标题一");
        assert_eq!(items[0]["cover"], "https://x/b.jpg");
        assert_eq!(items[0]["remark"], "2026-11-01");
        assert_eq!(items[1]["id"], "https://www.jav380.com/def-456/");
    }

    #[test]
    fn slug_of_paths() {
        assert_eq!(slug_of("https://www.jav380.com/abc-123/"), "abc-123");
        assert_eq!(slug_of("https://www.jav380.com/x/?a=1"), "x");
    }

    #[test]
    fn decode_resp_unescapes() {
        assert_eq!(
            decode_resp(r"http:\/\/x\/a.m3u8?k=%31%32"),
            "http://x/a.m3u8?k=12"
        );
    }
}
