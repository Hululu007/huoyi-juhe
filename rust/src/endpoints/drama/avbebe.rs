//! Avbebe：H 动画里番（WordPress JSON 接口）。
//!
//! 与 jar 的 ZakaAvbebeAmns 一一对应：分类（最新/热门＋WP 分类，
//! 分类名带数量后缀）、目录（WP posts 接口）、详情（WP 文章
//! JSON＋原文归档页取分集）、搜索（WP search 参数）、取流（直链透传）。
//! 详情取分集修补（2026-11-05 实测）：归档页现已无 jar 的 data-item
//! 播放器 JSON（新旧帖子均如此），视频改走 <iframe
//! src="https://play.52cute.com/e/..."> 嵌页，嵌页内含签名 m3u8 直链，
//! 先按 jar 的 sources 逻辑取归档页，无结果时再抓嵌页取。
//! 注意：jar 的取流还带 UA＋Origin＋Referer 头，核心 play 只回 url。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BASE_URL: &str = "https://avbebe.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

async fn wp_json(path: &str) -> ApiResult<Value> {
    let url = format!("{BASE_URL}/wp-json/wp/v2{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", format!("{BASE_URL}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Avbebe 请求 HTTP {status}")));
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
        Ok(_) => Err(ApiError::Internal("Avbebe 数据格式无法识别".into())),
        Err(e) => Err(e),
    }
}

async fn get_html(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{BASE_URL}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Avbebe 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 ZakaHttp.unescape＋clean 一致：解实体、去标签。
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

/// 与 Java 的 wpTitle 一致。
fn post_title(v: &Value) -> String {
    let rendered = get(v, "title")
        .map(|t| text_of(t, &["rendered"]))
        .unwrap_or_default();
    clean_text(&rendered)
}

/// 与 Java 的 cover 一致：featuredmedia 的 source_url，
/// 否则 media_details.sizes 按 medium/thumb/thumbnail/full 取。
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
    for key in ["medium", "thumb", "thumbnail", "full"] {
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
            let count = int_of(&row, &["count"]);
            let name = clean_text(&text_of(&row, &["name"]));
            if id == 0 || name.is_empty() {
                continue;
            }
            list.push(category_json(&format!("c{id}"), &format!("{name}（{count}）")));
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

/// 与 Java 的 sources 一致：先解析 data-item 的播放器 JSON 取
/// sources[].src，再用 m3u8 正则兜底；去重、只留 http 开头的地址。
fn sources(html: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let item_re = Regex::new("data-item=\"([^\"]+)\"").unwrap();
    for cap in item_re.captures_iter(html) {
        let raw = cap[1]
            .replace("&quot;", "\"")
            .replace("&#039;", "'")
            .replace("&apos;", "'")
            .replace("&#038;", "&")
            .replace("&amp;", "&");
        if let Ok(obj) = serde_json::from_str::<Value>(&raw) {
            if let Some(sources) = get(&obj, "sources").and_then(arr_of) {
                for s in sources {
                    let mut url = text_of(s, &["src"]);
                    url = url.replace("\\/", "/").replace("\\\\", "\\");
                    let url = url.trim().to_string();
                    if url.starts_with("http") && !out.contains(&url) {
                        out.push(url);
                    }
                }
            }
        }
    }
    if out.is_empty() {
        let m3u8 = Regex::new("(https?://[^\"'\\s<>\\\\]+?\\.m3u8[^\"'\\s<>\\\\]*)").unwrap();
        for cap in m3u8.captures_iter(html) {
            let url = cap[1].replace("\\/", "/");
            if !out.contains(&url) {
                out.push(url);
            }
        }
    }
    out
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id: i64 = series_id
        .trim()
        .parse()
        .map_err(|_| ApiError::Internal("Avbebe 详情 id 无法识别".to_string()))?;
    let post =
        wp_json(&format!("/posts/{id}?_embed=wp:featuredmedia")).await?;
    let title = post_title(&post);
    if title.is_empty() {
        return Err(ApiError::Internal("Avbebe 未返回视频资料".into()));
    }
    let date = date_prefix(&post);
    let year = if date.len() >= 4 {
        date[..4].to_string()
    } else {
        String::new()
    };
    let html = get_html(&format!("{BASE_URL}/archives/{id}")).await?;
    let mut urls = sources(&html);
    if urls.is_empty() {
        // 归档页现已无 data-item 播放器数据，改抓视频嵌页（play.52cute.com）。
        let iframe_re = Regex::new(r#"<iframe[^>]+src="([^"]+)""#).unwrap();
        for cap in iframe_re.captures_iter(&html) {
            let src = &cap[1];
            if !src.contains("52cute.com") {
                continue;
            }
            if let Ok(embed) = get_html(src).await {
                urls = sources(&embed);
                if !urls.is_empty() {
                    break;
                }
            }
        }
    }
    if urls.is_empty() {
        return Err(ApiError::Internal("Avbebe 未返回可播放分集".into()));
    }
    let episodes: Vec<Value> = urls
        .iter()
        .enumerate()
        .map(|(i, url)| {
            episode_json(url, &format!("正片·线路{}", i + 1), series_id)
        })
        .collect();
    let mut extra = serde_json::Map::new();
    if !year.is_empty() {
        extra.insert("year".to_string(), Value::String(year));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": post_cover(&post),
        "synopsis": title,
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

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("Avbebe 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sources_from_data_item() {
        let html = r##"<div data-item="{&quot;sources&quot;:[{&quot;src&quot;:&quot;https:\/\/cdn.example.com\/a.m3u8&quot;},{&quot;src&quot;:&quot;https:\/\/cdn.example.com\/b.m3u8&quot;}]}">"##;
        let urls = sources(html);
        assert_eq!(urls.len(), 2);
        assert_eq!(urls[0], "https://cdn.example.com/a.m3u8");
    }

    #[test]
    fn sources_fallback_m3u8() {
        let html = "video: https://x.y/z.m3u8?token=1";
        let urls = sources(html);
        assert_eq!(urls, vec!["https://x.y/z.m3u8?token=1"]);
    }

    #[test]
    fn clean_text_strips_tags() {
        assert_eq!(clean_text("<b>你好</b> &amp; 再见"), "你好 & 再见");
    }
}
