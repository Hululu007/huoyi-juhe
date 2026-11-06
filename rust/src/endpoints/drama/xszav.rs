//! XSZAV：HTML 站。
//!
//! 来源 jar 类 `ZakaXszavAmns`（`https://cn.xsz-av.com`）。
//! 目录走 `/videos/{slug}?page=N`；详情走 `/video/{id}`，取
//! master m3u8 的各分辨率变体做分集；搜索走
//! `/search/videos/{关键词}?page=N`。
//! 注意：站可能上 CF 盾，Java 遇盾走 WebView 清理，Rust 核心
//! 无法复现；明文 GET 被挡时本模块的列表/详情/取流即受限。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://cn.xsz-av.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("japanese", "日本AV"),
    ("uncensored", "无码影片"),
    ("uncensored-leak", "无码流出"),
    ("amateur", "素人"),
    ("chinese", "中国"),
    ("korean", "韩国"),
    ("western", "欧美"),
    ("hanime", "动漫"),
];

static RE_CARD_SPLIT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<div class="relative aspect-w-16 aspect-h-9"#).unwrap());
static RE_ID: Lazy<Regex> = Lazy::new(|| Regex::new(r#"href="/video/(\d+)""#).unwrap());
static RE_IMG: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r#"(?:data-src|src)="(https?://(?:img|i\d)\.xszcdn\.net/[^"]+?\.(?:jpg|jpeg|png|webp))""#,
    )
    .unwrap()
});
static RE_TITLE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"line-clamp-1[^"]*"[^>]*>([^<]{1,400}?)</a>"#).unwrap());
static RE_ALT: Lazy<Regex> = Lazy::new(|| Regex::new(r#"alt="([^"]+)""#).unwrap());
static RE_DUR: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"<span class="absolute bottom-1 right-1[^"]*">([\d:]{4,10})</span>"#).unwrap()
});
static RE_PAGES: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"aria-label="Go to page (\d+)""#).unwrap());
static RE_PAGE_Q: Lazy<Regex> = Lazy::new(|| Regex::new(r"\?page=(\d+)").unwrap());

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

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

async fn fetch(path: &str) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("XSZAV 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 1500
        || (!text.contains("xsz-av")
            && !text.contains("q:container")
            && !text.contains("aspect-w-16")
            && !text.contains("/video/"))
    {
        return Err(ApiError::Internal(
            "XSZAV 页面内容不符合预期（可能被盾挡）".into(),
        ));
    }
    Ok(text)
}

fn parse_list(page: &str) -> (Vec<Value>, i64) {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let chunks: Vec<&str> = RE_CARD_SPLIT.split(page).collect();
    for chunk in chunks.iter().skip(1) {
        let chunk = &chunk[..chunk.len().min(6000)];
        let Some(id) = RE_ID
            .captures(chunk)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str())
        else {
            continue;
        };
        if !seen.insert(id.to_string()) {
            continue;
        }
        let mut cover = cap1(&RE_IMG, chunk);
        if cover.contains("/w_") {
            let re_w = Regex::new(r"/w_\d+/").unwrap();
            cover = re_w.replace(&cover, "/w_800/").to_string();
        }
        let mut title = cap1(&RE_TITLE, chunk);
        if title.is_empty() {
            title = cap1(&RE_ALT, chunk);
        }
        let dur = cap1(&RE_DUR, chunk);
        items.push(item_json(id, &unescape(&title), &cover, &dur));
    }
    if items.is_empty() {
        // 兜底：按 href="/video/ 切块。
        for chunk in page.split("href=\"/video/").skip(1) {
            let chunk = &chunk[..chunk.len().min(4000)];
            let id = chunk.split('"').next().unwrap_or("");
            if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            if !seen.insert(id.to_string()) {
                continue;
            }
            let cover = cap1(&RE_IMG, chunk);
            let title = cap1(&RE_TITLE, chunk);
            items.push(item_json(id, &unescape(&title), &cover, ""));
        }
    }
    let mut max_page = RE_PAGES
        .captures_iter(page)
        .filter_map(|c| c.get(1)?.as_str().parse::<i64>().ok())
        .max()
        .unwrap_or(0);
    if max_page == 0 {
        max_page = RE_PAGE_Q
            .captures_iter(page)
            .filter_map(|c| c.get(1)?.as_str().parse::<i64>().ok())
            .max()
            .unwrap_or(0);
    }
    (items, max_page)
}

/// master m3u8 里的变体：(高度, 相对地址)。
fn variants(m3u8: &str) -> Vec<(i64, String)> {
    let mut out = Vec::new();
    let mut pending_h: Option<i64> = None;
    for line in m3u8.lines() {
        let line = line.trim();
        if line.starts_with("#EXT-X-STREAM-INF") {
            let re_res = Regex::new(r"RESOLUTION=\d+x(\d+)").unwrap();
            let re_name = Regex::new(r#"NAME="[^"]*?(\d{3,4})[^"]*""#).unwrap();
            pending_h = re_res
                .captures(line)
                .and_then(|c| c.get(1))
                .and_then(|m| m.as_str().parse::<i64>().ok())
                .or_else(|| {
                    re_name
                        .captures(line)
                        .and_then(|c| c.get(1))
                        .and_then(|m| m.as_str().parse::<i64>().ok())
                });
        } else if !line.is_empty() && !line.starts_with('#') {
            if let Some(h) = pending_h.take() {
                out.push((h, line.to_string()));
            }
        }
    }
    out
}

fn pick_variant(variants: &[(i64, String)], want: i64) -> Option<String> {
    if variants.is_empty() {
        return None;
    }
    if want > 0 {
        let mut best: Option<&(i64, String)> = None;
        for v in variants {
            let diff = (v.0 - want).abs();
            let best_diff = best.map(|b| (b.0 - want).abs()).unwrap_or(i64::MAX);
            if diff < best_diff {
                best = Some(v);
            }
        }
        return best.map(|v| v.1.clone());
    }
    for h in [1080, 720] {
        if let Some(v) = variants.iter().find(|v| v.0 == h) {
            return Some(v.1.clone());
        }
    }
    variants.first().map(|v| v.1.clone())
}

async fn master_m3u8(video_id: &str) -> ApiResult<String> {
    let page_html = fetch(&format!("/video/{video_id}")).await?;
    let re_src = Regex::new(r#"<video[^>]*src="(/media/[^"]+?\.m3u8)""#).unwrap();
    let re_any = Regex::new(r#"(/media/v_[0-9a-fA-F]+\.m3u8)"#).unwrap();
    let path = cap1(&re_src, &page_html);
    let path = if path.is_empty() {
        cap1(&re_any, &page_html)
    } else {
        path
    };
    if path.is_empty() {
        return Err(ApiError::Internal("XSZAV 详情未取到 m3u8".into()));
    }
    let url = format!("{BASE}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Referer", format!("{BASE}/"))
        .header("Origin", BASE)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("XSZAV m3u8 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if !text.contains("#EXTM3U") {
        return Err(ApiError::Internal("XSZAV m3u8 内容不是播放清单".into()));
    }
    Ok(text)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let slug = if category_id.is_empty() {
        "japanese"
    } else {
        category_id
    };
    let page_html = fetch(&format!("/videos/{slug}?page={page}")).await?;
    let (items, max_page) = parse_list(&page_html);
    let has_more = if max_page > 0 {
        page < max_page
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page_html = fetch(&format!("/video/{series_id}")).await?;
    let re_og = |prop: &str| Regex::new(&format!(r#"og:{prop}"\s+content="([^"]*)""#)).unwrap();
    let title = unescape(&cap1(&re_og("title"), &page_html));
    let cover = cap1(&re_og("image"), &page_html);
    let desc = unescape(&cap1(&re_og("description"), &page_html));
    let re_field = Regex::new(
        r#"(?s)<span class="mr-1">([^<]+)：</span>\s*<span class="font-medium">([^<]*)</span>"#,
    )
    .unwrap();
    let mut fields: Vec<(String, String)> = Vec::new();
    for cap in re_field.captures_iter(&page_html) {
        fields.push((
            cap.get(1).unwrap().as_str().trim().to_string(),
            unescape(cap.get(2).unwrap().as_str().trim()),
        ));
    }
    let re_actor = Regex::new(r#"href="/(?:actresses|actress)/[^"]*"[^>]*>([^<]+)</a>"#).unwrap();
    let mut actors = Vec::new();
    for cap in re_actor.captures_iter(&page_html) {
        actors.push(cap.get(1).unwrap().as_str().trim().to_string());
    }
    let re_tag = Regex::new(r#"href="/search/videos/[^"]*"[^>]*>([^<]+)</a>"#).unwrap();
    let mut tags = Vec::new();
    for cap in re_tag.captures_iter(&page_html) {
        tags.push(cap.get(1).unwrap().as_str().trim().to_string());
    }
    let mut synopsis = String::new();
    if !desc.is_empty() {
        synopsis.push_str(&desc);
        synopsis.push('\n');
    }
    for (k, v) in &fields {
        synopsis.push_str(&format!("{k}：{v}\n"));
    }
    if !actors.is_empty() {
        synopsis.push_str(&format!("女优：{}\n", actors.join("、")));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("标签：{}\n", tags.join("、")));
    }
    synopsis.push_str("来源：XSZAV");
    let master = master_m3u8(series_id).await?;
    let vars = variants(&master);
    let mut episodes = vec![episode_json(
        &format!("{series_id}|auto"),
        "默认",
        series_id,
    )];
    let mut heights: Vec<i64> = vars.iter().map(|v| v.0).collect();
    heights.sort_unstable();
    heights.dedup();
    for h in heights {
        episodes.push(episode_json(
            &format!("{series_id}|{h}"),
            &format!("{h}P"),
            series_id,
        ));
    }
    if vars.is_empty() {
        return Err(ApiError::Internal("XSZAV 详情未取到清晰度变体".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { format!("XSZAV {series_id}") } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"actor": actors.join("、"), "tags": tags.join("、")},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let page_html = fetch(&format!("/search/videos/{enc}?page=1")).await?;
    let (items, _) = parse_list(&page_html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (vid, want) = match video_id.split_once('|') {
        Some((v, w)) => (
            v.to_string(),
            if w == "auto" {
                0
            } else {
                w.parse::<i64>().unwrap_or(0)
            },
        ),
        None => (video_id.to_string(), 0),
    };
    let master = master_m3u8(&vid).await?;
    let vars = variants(&master);
    let Some(rel) = pick_variant(&vars, want) else {
        return Err(ApiError::Internal("XSZAV 没有可用的清晰度变体".into()));
    };
    let url = if rel.starts_with("http") {
        rel
    } else if rel.starts_with('/') {
        format!("{BASE}{rel}")
    } else {
        format!("{BASE}/{rel}")
    };
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variants_parse_master() {
        let m3u8 = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n1080/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\n720/index.m3u8\n";
        let vars = variants(m3u8);
        assert_eq!(vars.len(), 2);
        assert_eq!(vars[0], (1080, "1080/index.m3u8".to_string()));
        assert_eq!(pick_variant(&vars, 720), Some("720/index.m3u8".to_string()));
        assert_eq!(pick_variant(&vars, 0), Some("1080/index.m3u8".to_string()));
        assert_eq!(pick_variant(&vars, 480), Some("720/index.m3u8".to_string()));
    }

    #[test]
    fn parse_list_sample() {
        let html = r##"<div class="relative aspect-w-16 aspect-h-9"><a href="/video/12345"><img data-src="https://img.xszcdn.net/w_400/1.jpg"></a><a class="line-clamp-1" href="/video/12345">Sample Title</a><span class="absolute bottom-1 right-1">12:34</span></div>"##;
        let (items, _) = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "12345");
        assert_eq!(items[0]["title"], "Sample Title");
        assert_eq!(items[0]["cover"], "https://img.xszcdn.net/w_800/1.jpg");
        assert_eq!(items[0]["remark"], "12:34");
    }
}
