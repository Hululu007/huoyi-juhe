//! 69VJ：xvideos 片库（WordPress JSON 接口）。
//!
//! 与 jar 的 Zaka69vjAmns 一一对应：分类（最新/热门＋WP 分类）、
//! 目录（WP posts 接口）、详情（WP 文章 JSON＋原文链接页里的
//! embedframe iframe）、搜索（WP search 参数）、取流（抓嵌页
//! 取 m3u8，不通时经 tv506 代理中转，再验清单有效性）。
//! 注意：jar 的取流还带 UA＋Referer 头，核心 play 只回 url。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BASE_URL: &str = "https://69vj.com";
const PROXY_BASE: &str = "https://tv506.ystv.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn wp_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "application/json, text/plain, */*".to_string(),
        ),
        ("Referer".to_string(), format!("{BASE_URL}/")),
    ]
}

async fn get_text(url: &str, referer: &str) -> ApiResult<String> {
    let mut req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*");
    if !referer.is_empty() {
        req = req.header("Referer", referer);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("69VJ 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn wp_json(path: &str) -> ApiResult<Value> {
    let url = format!("{BASE_URL}/wp-json/wp/v2{path}");
    let mut req = client()?.get(&url);
    for (k, v) in wp_headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("69VJ 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    Ok(body)
}

async fn wp_arr(path: &str) -> ApiResult<Vec<Value>> {
    match wp_json(path).await {
        Ok(Value::Array(rows)) => Ok(rows),
        Ok(_) => Err(ApiError::Internal("69VJ 数据格式无法识别".into())),
        Err(e) => Err(e),
    }
}

/// 与 Java 的 ZakaHttp.unescape＋stripTags 一致：解实体、去标签。
fn clean_text(raw: &str) -> String {
    let un = raw
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#039;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&#038;", "&")
        .replace("&nbsp;", " ");
    let tag = Regex::new("<[^>]+>").unwrap();
    tag.replace_all(&un, "").trim().to_string()
}

/// 与 Java 的 title 一致：title.rendered 解码去标签。
fn post_title(v: &Value) -> String {
    let rendered = get(v, "title")
        .map(|t| text_of(t, &["rendered"]))
        .unwrap_or_default();
    clean_text(&rendered)
}

/// 与 Java 的 cover 一致：featuredmedia 的 source_url，
/// 否则 media_details.sizes 按 medium/thumb/thumbnail/coverthumb/full 取。
fn post_cover(v: &Value) -> String {
    let media = get(v, "_embedded")
        .and_then(|e| get(e, "wp:featuredmedia"))
        .and_then(arr_of)
        .and_then(|rows| rows.first());
    let Some(media) = media else {
        return String::new();
    };
    let direct = text_of(media, &["source_url"]);
    if !direct.is_empty() {
        return direct;
    }
    let sizes = get(media, "media_details").and_then(|m| get(m, "sizes"));
    for key in ["medium", "thumb", "thumbnail", "coverthumb", "full"] {
        let url = sizes
            .and_then(|s| get(s, key))
            .map(|o| text_of(o, &["source_url"]))
            .unwrap_or_default();
        if !url.is_empty() {
            return url;
        }
    }
    String::new()
}

fn date_prefix(v: &Value) -> String {
    let date = text_of(v, &["date"]);
    if date.len() >= 10 {
        date[..10].to_string()
    } else {
        date
    }
}

/// 与 Java 的 toItems 一致：WP 文章转视频卡片。
fn to_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for row in rows {
        let id = int_of(row, &["id"]);
        if id == 0 {
            continue;
        }
        let title = post_title(row);
        if title.is_empty() {
            continue;
        }
        items.push(item_json(
            &id.to_string(),
            &title,
            &post_cover(row),
            &date_prefix(row),
        ));
    }
    items
}

async fn posts(query: &str) -> ApiResult<Vec<Value>> {
    let rows = wp_arr(&format!("/posts?{query}&_embed=wp:featuredmedia")).await?;
    Ok(to_items(&rows))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("new", "🔥最新上架"),
        category_json("hot", "🔥熱門播放"),
    ];
    if let Ok(rows) = wp_arr("/categories?per_page=100&orderby=count&order=desc").await
    {
        for row in rows {
            let id = int_of(&row, &["id"]);
            let name = clean_text(&text_of(&row, &["name"]));
            if id == 0 || name.is_empty() {
                continue;
            }
            list.push(category_json(&format!("c{id}"), &name));
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let query = if let Some(rest) = category_id.strip_prefix('c') {
        format!("per_page=20&page={page}&categories={rest}")
    } else if category_id == "hot" {
        format!("per_page=20&page={page}&orderby=comment_count&order=desc")
    } else {
        format!("per_page=20&page={page}")
    };
    let items = posts(&query).await?;
    let has_more = items.len() == 20;
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 与 Java 的 postLink 一致：取文章的原文链接。
async fn post_link(id: i64) -> ApiResult<String> {
    let body =
        wp_json(&format!("/posts/{id}?_fields=link")).await?;
    let link = text_of(&body, &["link"]);
    if link.is_empty() {
        Ok(format!("{BASE_URL}/?p={id}"))
    } else {
        Ok(link)
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id: i64 = series_id
        .trim()
        .parse()
        .map_err(|_| ApiError::Internal("69VJ 详情 id 无法识别".to_string()))?;
    let post =
        wp_json(&format!("/posts/{id}?_embed=wp:featuredmedia")).await?;
    let title = post_title(&post);
    if title.is_empty() {
        return Err(ApiError::Internal("69VJ 未返回视频资料".into()));
    }
    let date = date_prefix(&post);
    let year = if date.len() >= 4 {
        date[..4].to_string()
    } else {
        String::new()
    };
    let mut synopsis = title.clone();
    let mut episodes: Vec<Value> = Vec::new();
    if let Ok(link) = post_link(id).await {
        if let Ok(html) = get_text(&link, BASE_URL).await {
            let iframe = Regex::new(
                "<iframe[^>]+src=\"(https?://[^\"]*embedframe/[^\"]+)\"",
            )
            .unwrap();
            if let Some(cap) = iframe.captures(&html) {
                let src = cap[1].to_string();
                if !src.is_empty() {
                    synopsis = format!("{title}\n\n播放器：{src}");
                    episodes.push(episode_json(&format!("@xv@{src}"), "正片", series_id));
                }
            }
        }
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("69VJ 未返回可播放分集".into()));
    }
    let mut extra = serde_json::Map::new();
    if !year.is_empty() {
        extra.insert("year".to_string(), Value::String(year));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": post_cover(&post),
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String =
        url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let items = posts(&format!("per_page=20&page=1&search={encoded}")).await?;
    Ok(json!({"items": items}))
}

/// 与 Java 的 mirror 一致：xvideos 域名逐个换镜像。
fn mirror(url: &str) -> String {
    url.replace("//www.xvideos.com/", "//www.xvideos.es/")
        .replace("//www.xvideos.es/", "//m.xvideos.com/")
        .replace("//m.xvideos.com/", "//xvideos.com/")
}

/// 与 Java 的 edgeUrl 一致：经 tv506 代理中转。
fn edge_url(url: &str) -> String {
    let encoded: String =
        url::form_urlencoded::byte_serialize(url.as_bytes()).collect();
    format!("{PROXY_BASE}/api/v1/proxy?url={encoded}")
}

async fn edge_text(url: &str) -> ApiResult<String> {
    let target = edge_url(url);
    let resp = client()?
        .get(&target)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{PROXY_BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("69VJ 代理请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 pick 一致：先找 m3u8（跳过 thumb 图），再找高清直链。
fn pick(html: &str) -> String {
    let m3u8 = Regex::new("(https?://[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*)").unwrap();
    if let Some(cap) = m3u8.captures(html) {
        let url = cap[1].replace("\\/", "/");
        if !url.contains("thumb") {
            return url;
        }
    }
    let high = Regex::new("setVideoUrlHigh\\('([^']+)'").unwrap();
    if let Some(cap) = high.captures(html) {
        return cap[1].replace("\\/", "/");
    }
    String::new()
}

/// 与 Java 的 isEmbedPage 一致：含播放器标记或 m3u8 即为嵌页。
fn is_embed_page(html: &str) -> bool {
    html.contains("html5player") || html.contains(".m3u8") || html.contains("setVideoUrlHigh")
}

/// 与 Java 的 resolve 一致：抓嵌页取流，不通换镜像走代理。
async fn resolve(url: &str) -> ApiResult<String> {
    let html = get_text(url, BASE_URL).await?;
    if is_embed_page(&html) {
        let found = pick(&html);
        if !found.is_empty() {
            return Ok(found);
        }
    }
    let mirrored = mirror(url);
    let html = edge_text(&mirrored).await?;
    if is_embed_page(&html) {
        let found = pick(&html);
        if !found.is_empty() {
            return Ok(found);
        }
    }
    Err(ApiError::Internal("69VJ 未取到播放地址".into()))
}

/// 与 Java 的 reachableOr 一致：m3u8 拉首段验有效，无效走代理地址。
async fn reachable_or(url: &str) -> ApiResult<String> {
    if !url.contains("m3u8") {
        return Ok(url.to_string());
    }
    let head = get_text(url, BASE_URL).await.unwrap_or_default();
    if head.contains("#EXTM3U") {
        return Ok(url.to_string());
    }
    Ok(edge_url(url))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if let Some(rest) = video_id.strip_prefix("@xv@") {
        rest.to_string()
    } else if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        return Err(ApiError::Internal("69VJ 该集没有播放地址".into()));
    };
    let resolved = if url.starts_with("http") {
        resolve(&url).await?
    } else {
        url
    };
    let final_url = reachable_or(&resolved).await?;
    if final_url.is_empty() {
        return Err(ApiError::Internal("69VJ 未取到播放地址".into()));
    }
    Ok(json!({"url": final_url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_text_strips_tags() {
        assert_eq!(clean_text("<b>你好</b> &amp; 再见"), "你好 & 再见");
    }

    #[test]
    fn mirror_chain() {
        assert_eq!(
            mirror("https://www.xvideos.com/embedframe/1"),
            "https://xvideos.com/embedframe/1"
        );
    }

    #[test]
    fn pick_m3u8_and_high() {
        let html = "x setVideoUrlHigh('https://cdn.example.com/v.m3u8') y";
        assert_eq!(pick(html), "https://cdn.example.com/v.m3u8");
        let html2 = "src=\"https://a.b/c.m3u8?x=1\"";
        assert_eq!(pick(html2), "https://a.b/c.m3u8?x=1");
    }

    #[test]
    fn edge_url_encodes() {
        assert!(edge_url("https://a.b/c?d=e").starts_with("https://tv506.ystv.top/api/v1/proxy?url="));
    }
}
