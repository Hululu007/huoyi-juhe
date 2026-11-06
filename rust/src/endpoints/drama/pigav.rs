//! PIGAV：朱古力视频站（JSON API）。
//!
//! 与 jar 的 ZakaPigavAmns 一一对应：分类（静态排序＋静态频道分类＋
//! 直播拉取的视频频道）、目录（频道/分类/排序三种路径）、详情
//! （/api/v1/videos/{id}，分集来自 streamingPlaylists 与 files）、
//! 搜索、取流（直链透传）。站地址优先 pigav.com，不通切 www 域名。
//! 注意：jar 的取流还带 UA＋Referer 头，核心 play 只回 url，头由
//! 播放器侧默认处理；m3u8 本身在 CDN 上可直拉。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BASE_URL: &str = "https://pigav.com";
const ALT_BASE_URL: &str = "https://www.pigav.com";
const IMG_BASE_URL: &str = "https://img.pigav.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const PAGE_SIZE: i64 = 30;

const TOP: &[(&str, &str)] = &[
    ("t:new", "★最新"),
    ("t:hot", "★热门"),
    ("t:view", "★最多播放"),
    ("t:like", "★最多收藏"),
];

const CATS: &[(&str, &str)] = &[
    ("c:20", "日韓線上"),
    ("c:21", "亞洲線上"),
    ("c:22", "自拍線上"),
    ("c:23", "歐美線上"),
    ("c:24", "動漫線上"),
    ("c:25", "AI短劇"),
];

/// 与 Java 的 URLEncoder 一致：空格成 %20，@ 与 / 不编码。
fn enc_path(raw: &str) -> String {
    let encoded: String =
        url::form_urlencoded::byte_serialize(raw.as_bytes()).collect();
    encoded
        .replace('+', "%20")
        .replace("%40", "@")
        .replace("%2F", "/")
}

/// 与 Java 的 ZakaHttp.enc 一致：标准 URL 编码。
fn enc(raw: &str) -> String {
    url::form_urlencoded::byte_serialize(raw.as_bytes()).collect()
}

fn headers(base: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "application/json, text/plain, */*".to_string(),
        ),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
        ("Referer".to_string(), format!("{base}/")),
    ]
}

async fn get_json(path: &str) -> ApiResult<Value> {
    let mut last_err = String::new();
    for base in [BASE_URL, ALT_BASE_URL] {
        let url = format!("{base}{path}");
        let mut req = client()?.get(&url);
        for (k, v) in headers(base) {
            req = req.header(k, v);
        }
        let resp = match req.send().await {
            Ok(r) => r,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let status = resp.status().as_u16();
        if status != 200 {
            last_err = format!("PIGAV 请求 HTTP {status}");
            continue;
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let body: Value = serde_json::from_str(&text)?;
        if !body.is_object() {
            return Err(ApiError::Internal("PIGAV 数据格式无法识别".into()));
        }
        return Ok(body);
    }
    Err(ApiError::Internal(format!("PIGAV 请求失败：{last_err}")))
}

/// 与 Java 的 pic 一致：// 补 https:，/ 开头补图片域名。
/// 短串守卫只拦既非路径又非文件名的杂项（如 "short"），不用
/// 长度拦——"/a/b.jpg" 这类合法短路径只有 8 个字符。
fn pic(raw: &str) -> String {
    let s = raw.trim();
    if s.is_empty() || (!s.contains('/') && !s.contains('.')) {
        return String::new();
    }
    if let Some(rest) = s.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if let Some(rest) = s.strip_prefix('/') {
        return format!("{IMG_BASE_URL}/{rest}");
    }
    s.to_string()
}

/// 与 Java 的 clock 一致：秒数转 h:mm:ss 或 m:ss。
fn clock(total: i64) -> String {
    if total <= 0 {
        return String::new();
    }
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// 与 Java 的 strip 一致：去 HTML 标签与实体。
fn strip_html(raw: &str) -> String {
    let text = raw.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n");
    let tag = Regex::new("<[^>]+>").unwrap();
    let out = tag.replace_all(&text, "");
    let out = out
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#039;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&");
    let blank = Regex::new("[ \\t\\x0B\\f\\r]+").unwrap();
    let out = blank.replace_all(&out, " ");
    let multi = Regex::new("\\n\\s*\\n+").unwrap();
    multi.replace_all(&out, "\n\n").trim().to_string()
}

/// 与 Java 的 remark 一致：直播标记＋时长＋分类标签＋播放数。
fn remark_of(v: &Value) -> String {
    let mut out = String::new();
    if get(v, "isLive").is_some_and(|x| x.as_bool().unwrap_or(false)) {
        out.push_str("直播");
    }
    let dur = clock(int_of(v, &["duration"]));
    out.push_str(&dur);
    let label = get(v, "category")
        .map(|c| text_of(c, &["label"]))
        .unwrap_or_default();
    if !label.is_empty() {
        if !out.is_empty() {
            out.push('·');
        }
        out.push_str(&label);
    }
    let views = int_of(v, &["views"]);
    if views > 0 {
        if !out.is_empty() {
            out.push('·');
        }
        out.push_str(&format!("{views}次播放"));
    }
    out
}

/// 与 Java 的 one 一致：列表行转视频卡片。
fn one(v: &Value) -> Option<Value> {
    let mut id = text_of(v, &["shortUUID"]);
    if id.is_empty() {
        id = text_of(v, &["uuid"]);
    }
    if id.is_empty() {
        return None;
    }
    let title = text_of(v, &["name"]);
    if title.is_empty() {
        return None;
    }
    let cover = pic(&text_of(v, &["thumbnailPath"]));
    Some(item_json(&id, &title, &cover, &remark_of(v)))
}

fn list_items(rows: &[Value]) -> Vec<Value> {
    rows.iter().filter_map(one).collect()
}

/// 与 Java 的 sortOf 一致。
fn sort_of(tid: &str) -> &'static str {
    match tid {
        "t:hot" => "-hot",
        "t:view" => "-views",
        "t:like" => "-likes",
        _ => "-publishedAt",
    }
}

async fn channels() -> Vec<Value> {
    let mut out = Vec::new();
    let Ok(resp) =
        get_json("/api/v1/video-channels?start=0&count=60&sort=-updatedAt").await
    else {
        return out;
    };
    let Some(rows) = get(&resp, "data").and_then(arr_of) else {
        return out;
    };
    for row in rows {
        if out.len() >= 24 {
            break;
        }
        let name = text_of(row, &["name"]);
        let host = text_of(row, &["host"]);
        let display = text_of(row, &["displayName"]);
        if name.is_empty() || host.is_empty() || display.is_empty() {
            continue;
        }
        out.push(category_json(
            &format!("ch:{name}@{host}"),
            &format!("频道·{display}"),
        ));
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (id, name) in TOP {
        list.push(category_json(id, name));
    }
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    list.extend(channels().await);
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let start = (page - 1) * PAGE_SIZE;
    let path = if let Some(rest) = category_id.strip_prefix("ch:") {
        format!(
            "/api/v1/video-channels/{}/videos?start={}&count={}&sort=-publishedAt",
            enc_path(rest),
            start,
            PAGE_SIZE
        )
    } else if let Some(rest) = category_id.strip_prefix("c:") {
        format!(
            "/api/v1/videos?start={}&count={}&sort=-publishedAt&categoryOneOf={}",
            start,
            PAGE_SIZE,
            enc_path(rest)
        )
    } else {
        format!(
            "/api/v1/videos?start={}&count={}&sort={}",
            start,
            PAGE_SIZE,
            sort_of(category_id)
        )
    };
    let resp = get_json(&path).await?;
    let rows = get(&resp, "data").and_then(arr_of);
    let items = match rows {
        Some(rows) => list_items(rows),
        None => Vec::new(),
    };
    let total = int_of(&resp, &["total"]);
    let has_more = if total > 0 {
        page * PAGE_SIZE < total
    } else {
        items.len() as i64 >= PAGE_SIZE
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 详情的分集收集：streamingPlaylists[].files[] 与顶层 files[]，
/// 每条一个分集（PIGAV-{清晰度标签}），另加 playlistUrl（HLS 自动）。
fn detail_episodes(data: &Value, series_id: &str) -> Vec<Value> {
    let mut episodes: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut push = |episodes: &mut Vec<Value>, seen: &mut HashSet<String>, title: String, url: String| {
        if url.is_empty() || !seen.insert(url.clone()) {
            return;
        }
        episodes.push(episode_json(&url, &title, series_id));
    };
    if let Some(playlists) = get(data, "streamingPlaylists").and_then(arr_of) {
        for pl in playlists {
            if let Some(files) = get(pl, "files").and_then(arr_of) {
                for f in files {
                    let url = text_of(f, &["fileUrl"]);
                    let label = get(f, "resolution")
                        .map(|r| text_of(r, &["label"]))
                        .unwrap_or_default();
                    let label = if label.is_empty() {
                        text_of(f, &["label"])
                    } else {
                        label
                    };
                    let title = if label.is_empty() {
                        "PIGAV-源".to_string()
                    } else {
                        format!("PIGAV-{label}")
                    };
                    push(&mut episodes, &mut seen, title, url);
                }
            }
            let playlist_url = text_of(pl, &["playlistUrl"]);
            push(
                &mut episodes,
                &mut seen,
                "PIGAV-HLS自动".to_string(),
                playlist_url,
            );
        }
    }
    if let Some(files) = get(data, "files").and_then(arr_of) {
        for f in files {
            let url = text_of(f, &["fileUrl"]);
            let label = get(f, "resolution")
                .map(|r| text_of(r, &["label"]))
                .unwrap_or_default();
            let label = if label.is_empty() {
                text_of(f, &["label"])
            } else {
                label
            };
            let title = if label.is_empty() {
                "PIGAV-源".to_string()
            } else {
                format!("PIGAV-{label}")
            };
            push(&mut episodes, &mut seen, title, url);
        }
    }
    let playlist_url = text_of(data, &["playlistUrl"]);
    push(
        &mut episodes,
        &mut seen,
        "PIGAV-HLS自动".to_string(),
        playlist_url,
    );
    episodes
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = format!("/api/v1/videos/{}", enc_path(series_id));
    let resp = get_json(&path).await?;
    let data = match get(&resp, "data") {
        Some(d) if d.is_object() => d,
        _ => return Err(ApiError::Internal("PIGAV 未返回视频资料".into())),
    };
    let title = text_of(data, &["name"]);
    if title.is_empty() {
        return Err(ApiError::Internal("PIGAV 未返回视频资料".into()));
    }
    let cover = pic(&text_of(data, &["thumbnailPath"]));
    let synopsis = strip_html(&text_of(data, &["description"]));
    let published = text_of(data, &["publishedAt"]);
    let year = if published.len() >= 4 {
        published[..4].to_string()
    } else {
        String::new()
    };
    let area = get(data, "channel")
        .map(|c| text_of(c, &["displayName"]))
        .unwrap_or_default();
    let episodes = detail_episodes(data, series_id);
    if episodes.is_empty() {
        return Err(ApiError::Internal("PIGAV 未返回可播放分集".into()));
    }
    let mut extra = serde_json::Map::new();
    if !year.is_empty() {
        extra.insert("year".to_string(), Value::String(year));
    }
    if !area.is_empty() {
        extra.insert("area".to_string(), Value::String(area));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!(
        "/api/v1/search/videos?search={}&start=0&count={}",
        enc(query),
        PAGE_SIZE
    );
    let resp = get_json(&path).await?;
    let rows = get(&resp, "data").and_then(arr_of);
    let items = match rows {
        Some(rows) => list_items(rows),
        None => Vec::new(),
    };
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("PIGAV 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_formats() {
        assert_eq!(clock(0), "");
        assert_eq!(clock(65), "1:05");
        assert_eq!(clock(3661), "1:01:01");
    }

    #[test]
    fn pic_prefixes() {
        assert_eq!(pic("//x/y.jpg"), "https://x/y.jpg");
        assert_eq!(pic("/a/b.jpg"), "https://img.pigav.com/a/b.jpg");
        assert_eq!(pic("short"), "");
    }

    #[test]
    fn sort_mapping() {
        assert_eq!(sort_of("t:hot"), "-hot");
        assert_eq!(sort_of("t:view"), "-views");
        assert_eq!(sort_of("t:like"), "-likes");
        assert_eq!(sort_of("t:new"), "-publishedAt");
    }

    #[test]
    fn episodes_dedup() {
        let data = json!({
            "streamingPlaylists": [
                {"files": [{"fileUrl": "https://x/720.mp4", "resolution": {"label": "720p"}}],
                 "playlistUrl": "https://x/list.m3u8"},
                {"files": [{"fileUrl": "https://x/720.mp4", "resolution": {"label": "720p"}}],
                 "playlistUrl": "https://x/list.m3u8"}
            ],
        });
        let eps = detail_episodes(&data, "s1");
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0]["title"], "PIGAV-720p");
        assert_eq!(eps[1]["title"], "PIGAV-HLS自动");
    }
}
