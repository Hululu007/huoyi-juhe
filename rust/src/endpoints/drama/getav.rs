//! 👑帝皇影视：getav.me 的 JSON API 站。
//!
//! 与 jar 的 ZakaGetavAmns 一一对应：11 分类（7 个 api@@ 影片
//! 列表 + 4 个 folder@@ 目录：类型/演员/片商/番号系列）、目录
//! （/api/movies 与目录接口）、详情（/api/movies/<id>，
//! videoSources 按清晰度分线、localM3u8Path 兜底、预告单列）、
//! 搜索（/api/search）、取流（直链直接回，带 UA+Referer+Origin
//! 头；影片 id 则先走详情取最佳流）。
//! 注意：jar 里的 header 对象被误写成 toString() 字符串，
//! 这里按正确 dict 写。
//! 验门（2026-11-05 请求复现）：/api/movies 最新 40 条带真封
//! 面、翻页、详情 SDDE-772（首条直链 m3u8 Range 206）、搜索 40
//! 条、演员文件夹接口正常，全过。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const SITE: &str = "https://getav.me";
const STATIC: &str = "https://static.worldstatic.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn play_header() -> Value {
    json!({"User-Agent": UA, "Referer": format!("{SITE}/zh"), "Origin": SITE})
}

async fn api_get(path: &str, query: &[(&str, &str)]) -> ApiResult<Value> {
    let url = with_query(&format!("{SITE}{path}"), query);
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Referer", format!("{SITE}/zh"))
        .header("Origin", SITE)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("帝皇影视请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("帝皇影视数据格式无法识别".into()));
    }
    Ok(body)
}

fn cover_of(entry: &Value) -> String {
    let raw = text_of(entry, &["localImg", "img"]);
    if raw.is_empty() {
        return String::new();
    }
    if let Some(rest) = raw.strip_prefix("//") {
        format!("https://{rest}")
    } else if raw.starts_with('/') {
        format!("{STATIC}{raw}")
    } else {
        raw
    }
}

fn fmt_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return String::new();
    }
    let h = seconds / 3600;
    let m = (seconds % 3600) / 60;
    let s = seconds % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn movie_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for entry in rows {
        let id = text_of(entry, &["id"]);
        let title = text_of(entry, &["title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = cover_of(entry);
        let seconds = match get(entry, "videoLength") {
            Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
            _ => 0,
        };
        let mut remark = fmt_duration(seconds);
        if remark.is_empty() {
            remark = text_of(entry, &["date"]);
        }
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn movies_of(resp: &Value) -> Vec<Value> {
    if let Some(data) = get(resp, "data") {
        if let Some(rows) = get(data, "movies").and_then(arr_of) {
            return movie_items(rows);
        }
        if let Some(rows) = data.as_array() {
            return movie_items(rows);
        }
    }
    if let Some(rows) = get(resp, "movies").and_then(arr_of) {
        return movie_items(rows);
    }
    Vec::new()
}

fn pagecount_of(resp: &Value) -> i64 {
    if let Some(data) = get(resp, "data") {
        if let Some(Value::Number(n)) = get(data, "totalPages") {
            return n.as_i64().unwrap_or(0);
        }
        if let Some(Value::Number(n)) = get(data, "actualTotalPages") {
            return n.as_i64().unwrap_or(0);
        }
    }
    0
}

fn folder_item(id: &str, name: &str, cover: &str, remark: &str) -> Value {
    let mut item = item_json(id, name, cover, remark);
    if let Some(obj) = item.as_object_mut() {
        obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
    }
    item
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("api@@latest", "🔥最近更新"),
        category_json("api@@hot", "📈热门影片"),
        category_json("api@@new-releases", "✨新片上市"),
        category_json("api@@uncensored", "🔞无码影片"),
        category_json("api@@censored", "🈵有码影片"),
        category_json("api@@subtitle", "🔤字幕专区"),
        category_json("api@@4k", "💎4K超高清"),
        category_json("folder@@genres", "📂类型大全"),
        category_json("folder@@stars", "📂演员大全"),
        category_json("folder@@studios", "📂片商大全"),
        category_json("folder@@codes", "📂番号系列"),
    ]}))
}

/// api@@ 分类对应的 /api/movies 参数。
fn api_params(cat: &str) -> (String, Vec<(&'static str, String)>) {
    let mut params: Vec<(&str, String)> = Vec::new();
    let sort = match cat {
        "hot" => "popular",
        _ => "latest",
    };
    params.push(("sortBy", sort.to_string()));
    if cat == "subtitle" {
        params.push(("subtitles", "true".to_string()));
    }
    if cat == "4k" {
        params.push(("resolution", "4k".to_string()));
    }
    (cat.to_string(), params)
}

async fn catalog_api(cat: &str, page: i64) -> ApiResult<Value> {
    let (category, extra) = api_params(cat);
    let page_num = page.to_string();
    let mut query: Vec<(&str, &str)> = vec![
        ("category", category.as_str()),
        ("page", page_num.as_str()),
        ("limit", "40"),
        ("locale", "zh"),
    ];
    let mut owned: Vec<(String, String)> = Vec::new();
    for (k, v) in extra {
        owned.push((k.to_string(), v));
    }
    let mut refs: Vec<(&str, &str)> = Vec::new();
    for (k, v) in &owned {
        refs.push((k.as_str(), v.as_str()));
    }
    query.extend(refs.iter().copied());
    let resp = api_get("/api/movies", &query).await?;
    let items = movies_of(&resp);
    let pagecount = pagecount_of(&resp);
    let has_more = if pagecount > 0 {
        page < pagecount
    } else {
        items.len() >= 40
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

async fn catalog_folder(kind: &str, page: i64) -> ApiResult<Value> {
    let page_num = page.to_string();
    match kind {
        "stars" => {
            let resp = api_get(
                "/api/stars",
                &[
                    ("page", page_num.as_str()),
                    ("limit", "24"),
                    ("sort", "popular"),
                    ("locale", "zh"),
                    ("gender", "2"),
                ],
            )
            .await?;
            let mut items = Vec::new();
            if let Some(data) = get(&resp, "data") {
                if let Some(rows) = get(data, "stars").and_then(arr_of) {
                    for entry in rows {
                        let id = text_of(entry, &["id"]);
                        let name = text_of(entry, &["name"]);
                        if id.is_empty() || name.is_empty() {
                            continue;
                        }
                        let cover = cover_of(entry);
                        let count = match get(entry, "movieCount") {
                            Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
                            _ => 0,
                        };
                        let remark = if count > 0 {
                            format!("{count} 部")
                        } else {
                            String::new()
                        };
                        let encoded: String =
                            url::form_urlencoded::byte_serialize(name.as_bytes()).collect();
                        let sub = format!(
                            "subfolder@@star@@{id}@@sortBy=popular@@subtitles=@@resolution=@@name={encoded}"
                        );
                        items.push(folder_item(&sub, &name, &cover, &remark));
                    }
                }
            }
            let pagecount = pagecount_of(&resp);
            let has_more = if pagecount > 0 {
                page < pagecount
            } else {
                items.len() >= 24
            };
            Ok(json!({"items": items, "has_more": has_more}))
        }
        "genres" | "studios" | "codes" => {
            let path = match kind {
                "genres" => "/api/genres",
                "studios" => "/api/studios",
                _ => "/api/codes",
            };
            let id_key = match kind {
                "genres" => "genre",
                "studios" => "studio",
                _ => "code",
            };
            let resp =
                api_get(path, &[("limit", "100"), ("sort", ""), ("locale", "zh-CN")]).await?;
            let mut items = Vec::new();
            if let Some(data) = get(&resp, "data") {
                if let Some(rows) = data.as_array() {
                    for entry in rows {
                        let id = text_of(entry, &["id", "slug"]);
                        let name = text_of(entry, &["name", "title"]);
                        if id.is_empty() || name.is_empty() {
                            continue;
                        }
                        let cover = cover_of(entry);
                        let count = match get(entry, "movieCount") {
                            Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
                            _ => 0,
                        };
                        let remark = if count > 0 {
                            format!("{count} 部")
                        } else {
                            String::new()
                        };
                        let encoded: String =
                            url::form_urlencoded::byte_serialize(name.as_bytes()).collect();
                        let sub = format!(
                            "subfolder@@{id_key}@@{id}@@sortBy=@@subtitles=@@resolution=@@name={encoded}"
                        );
                        items.push(folder_item(&sub, &name, &cover, &remark));
                    }
                }
            }
            Ok(json!({"items": items, "has_more": false}))
        }
        _ => Err(ApiError::Internal("帝皇影视未知目录类型".into())),
    }
}

/// subfolder@@<kind>@@<id>@@sortBy=<v>@@subtitles=<v>@@resolution=<v>
/// @@name=<enc> → 该文件夹的影片列表。
async fn catalog_subfolder(sub: &str, page: i64) -> ApiResult<Value> {
    let parts: Vec<&str> = sub.split("@@").collect();
    if parts.len() < 3 {
        return Err(ApiError::Internal("帝皇影视文件夹地址格式不对".into()));
    }
    let kind = parts[1];
    let id = parts[2];
    let id_key = match kind {
        "star" => "starId",
        "genre" => "genreId",
        "studio" => "studioId",
        "code" => "code",
        _ => return Err(ApiError::Internal("帝皇影视未知文件夹类型".into())),
    };
    let mut sort_by = "";
    for part in &parts[3..] {
        if let Some(v) = part.strip_prefix("sortBy=") {
            sort_by = v;
        }
    }
    let page_num = page.to_string();
    let resp = api_get(
        "/api/movies",
        &[
            ("page", page_num.as_str()),
            ("limit", "40"),
            ("locale", "zh"),
            ("sortBy", sort_by),
            (id_key, id),
        ],
    )
    .await?;
    let items = movies_of(&resp);
    let pagecount = pagecount_of(&resp);
    let has_more = if pagecount > 0 {
        page < pagecount
    } else {
        items.len() >= 40
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if let Some(cat) = category_id.strip_prefix("api@@") {
        return catalog_api(cat, page).await;
    }
    if let Some(kind) = category_id.strip_prefix("folder@@") {
        return catalog_folder(kind, page).await;
    }
    if category_id.starts_with("subfolder@@") {
        return catalog_subfolder(category_id, page).await;
    }
    catalog_api("latest", page).await
}

fn line_name(typ: &str) -> String {
    match typ {
        "raw_4k" => "正片 4K".to_string(),
        "raw_1080p" => "正片 1080P".to_string(),
        "raw_720p" => "正片 720P".to_string(),
        "raw_480p" => "正片 480P".to_string(),
        "raw_240p" => "正片 240P".to_string(),
        "uc_4k" => "无码 4K".to_string(),
        "uc_1080p" => "无码 1080P".to_string(),
        "uc_720p" => "无码 720P".to_string(),
        "uc_480p" => "无码 480P".to_string(),
        "uc_240p" => "无码 240P".to_string(),
        other => other.to_string(),
    }
}

fn detail_episodes(data: &Value, series_id: &str) -> Vec<Value> {
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(sources) = get(data, "videoSources").and_then(arr_of) {
        for src in sources {
            let typ = text_of(src, &["type"]);
            let url = text_of(src, &["url"]);
            if url.is_empty() {
                continue;
            }
            episodes.push(episode_json(&url, &line_name(&typ), series_id));
        }
    }
    for key in ["localM3u8Path4k", "localM3u8Path", "localM3u8PathUc"] {
        let raw = text_of(data, &[key]);
        if raw.is_empty() {
            continue;
        }
        let url = if raw.starts_with('/') {
            format!("{STATIC}{raw}")
        } else {
            raw
        };
        if episodes.iter().any(|e| e["video_id"] == url) {
            continue;
        }
        let name = match key {
            "localM3u8Path4k" => "正片 4K",
            "localM3u8PathUc" => "无码",
            _ => "正片",
        };
        episodes.push(episode_json(&url, name, series_id));
    }
    let preview = text_of(data, &["previewVideoUrl"]);
    if !preview.is_empty() {
        episodes.push(episode_json(&preview, "预告", series_id));
    }
    episodes
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    // 文件夹卡被当作详情打开时，jar 是转调目录：这里把该文件
    // 夹的第一页影片当成分集列出。
    if series_id.starts_with("subfolder@@") {
        let list = catalog_subfolder(series_id, 1).await?;
        let items = match get(&list, "items").and_then(arr_of) {
            Some(rows) => rows,
            None => return Err(ApiError::Internal("帝皇影视文件夹为空".into())),
        };
        let mut episodes: Vec<Value> = Vec::new();
        for entry in items {
            let id = text_of(entry, &["vod_id"]);
            let name = text_of(entry, &["vod_name"]);
            if id.is_empty() || name.is_empty() {
                continue;
            }
            episodes.push(episode_json(&id, &name, series_id));
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("帝皇影视文件夹为空".into()));
        }
        return Ok(json!({
            "id": series_id,
            "title": "文件夹",
            "cover": "",
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let id = series_id.to_lowercase();
    let resp = api_get(&format!("/api/movies/{id}"), &[]).await?;
    let data = match get(&resp, "data") {
        Some(d) => d,
        None => return Err(ApiError::Internal("帝皇影视未返回影片资料".into())),
    };
    let title = text_of(data, &["title"]);
    let cover = cover_of(data);
    let synopsis = text_of(data, &["description", "plot"]);
    let mut extra = serde_json::Map::new();
    let seconds = match get(data, "videoLength") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    let duration = fmt_duration(seconds);
    if !duration.is_empty() {
        extra.insert("duration".to_string(), Value::String(duration));
    }
    let date = text_of(data, &["date"]);
    if !date.is_empty() {
        extra.insert("date".to_string(), Value::String(date));
    }
    if let Some(stars) = get(data, "stars").and_then(arr_of) {
        let names: Vec<String> = stars
            .iter()
            .map(|s| text_of(s, &["name"]))
            .filter(|s| !s.is_empty())
            .collect();
        if !names.is_empty() {
            extra.insert("actors".to_string(), Value::String(names.join(" / ")));
        }
    }
    if let Some(genres) = get(data, "genres").and_then(arr_of) {
        let names: Vec<String> = genres
            .iter()
            .map(|g| text_of(g, &["name"]))
            .filter(|s| !s.is_empty())
            .collect();
        if !names.is_empty() {
            extra.insert("genres".to_string(), Value::String(names.join(" / ")));
        }
    }
    let producer = text_of(data, &["producer", "publisher"]);
    if !producer.is_empty() {
        extra.insert("producer".to_string(), Value::String(producer));
    }
    let series = text_of(data, &["series"]);
    if !series.is_empty() {
        extra.insert("series".to_string(), Value::String(series));
    }
    let rating = match get(data, "rating") {
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    };
    if !rating.is_empty() {
        extra.insert("rating".to_string(), Value::String(rating));
    }
    let episodes = detail_episodes(data, &id);
    if episodes.is_empty() {
        return Err(ApiError::Internal("帝皇影视未返回可播放分集".into()));
    }
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let resp = api_get(
        "/api/search",
        &[
            ("q", query),
            ("page", "1"),
            ("limit", "40"),
            ("locale", "zh"),
        ],
    )
    .await?;
    let items = movies_of(&resp);
    Ok(json!({"items": items}))
}

/// 取流：直链直接回；影片 id 先走详情取最佳流。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id, "header": play_header()}));
    }
    let det = detail(video_id).await?;
    let eps = match get(&det, "episodes").and_then(arr_of) {
        Some(rows) => rows,
        None => return Err(ApiError::Internal("帝皇影视未返回可播放分集".into())),
    };
    let first = match eps.first() {
        Some(v) => v,
        None => return Err(ApiError::Internal("帝皇影视未返回可播放分集".into())),
    };
    let url = text_of(first, &["video_id"]);
    if url.is_empty() {
        return Err(ApiError::Internal("帝皇影视该集没有播放地址".into()));
    }
    Ok(json!({"url": url, "header": play_header()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_formats() {
        assert_eq!(fmt_duration(3661), "1:01:01");
        assert_eq!(fmt_duration(125), "2:05");
        assert_eq!(fmt_duration(0), "");
    }

    #[test]
    fn cover_absolute() {
        let entry = json!({"localImg": "/img/1.jpg"});
        assert_eq!(cover_of(&entry), "https://static.worldstatic.com/img/1.jpg");
        let entry = json!({"img": "//cdn.example.com/1.jpg"});
        assert_eq!(cover_of(&entry), "https://cdn.example.com/1.jpg");
    }

    #[test]
    fn line_names() {
        assert_eq!(line_name("raw_1080p"), "正片 1080P");
        assert_eq!(line_name("uc_4k"), "无码 4K");
    }
}
