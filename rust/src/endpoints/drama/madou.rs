//! 2048成人短剧（madou）：麻豆传媒AI 单页应用的同源 API，实测于 2026-11-05。
//!
//! 站点 `https://madouai.xyz/media/`（标题“麻豆传媒AI”，自称 2048
//! 原创短剧），前端为 Vue 单页应用，后端同源 `/api/v1`。
//! 分类与接口一致（23 项，`GET /api/v1/categories?type=video`）：
//! AV - 中文字幕/国产自拍（最新更新）/AV - 无码流出/每日更新/
//! 反差母狗/探花大神/91大神/麻豆x性吧联合原创/清纯少女/麻豆原创AI/
//! 破解偷拍/世界杯专栏/黑料吃瓜/重口调教/直播大秀/白虎嫩妹/网红主播/
//! 家庭乱伦/麻豆传媒/媚黑母狗/熟女偷情/白虎少女/网黄原创。
//! 列表 `GET /api/v1/videos?categoryId=<id>&page=<n>&size=20`
//! （总量 20163，p1/p2 无重叠；单分类如 1 号共 2670 条）；
//! 详情 `GET /api/v1/videos/<id>`；
//! 搜索 `GET /api/v1/videos/search?q=<词>`（“国产”实测 96 条；
//! 注意 `/videos?keyword=`、`?search=`、`?title=` 均被接口忽略，
//! 只回未过滤列表，勿用）。
//! 取流：列表/详情的 `videoUrl` 是相对路径
//! （如 `jpd/20260819/rq/gy/pp/nc/a5d2db70130943eb8a832cdf24d50725.m3u8`），
//! 前端播放器（videoPlayback 块）原样做：以.m3u8 结尾即走同源代理
//! `/api/v1/m3u8/proxy?path=<百分号编码的 videoUrl>`（代理回的清单
//! 200、462 分片、总长 1847.6 秒与详情 durationSec 1848 一致、
//! AES-128、首分片 200）；封面走 `/api/v1/image/proxy?path=…`。
//! 未见 VIP/付费字段（列表与详情均无 vip/price/isVip，取流无需登录；
//! `/auth/login` 接口存在但内容免费，不碰登录）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://madouai.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与接口一致，实测于 2026-11-05（接口返回顺序）。
const CATS: &[(&str, &str)] = &[
    ("2", "AV - 中文字幕"),
    ("1", "国产自拍（最新更新）"),
    ("8", "AV - 无码流出"),
    ("27", "每日更新"),
    ("21", "反差母狗"),
    ("4", "探花大神"),
    ("7", "91大神"),
    ("10", "麻豆x性吧联合原创"),
    ("13", "清纯少女"),
    ("6", "麻豆原创AI"),
    ("20", "破解偷拍"),
    ("28", "世界杯专栏"),
    ("19", "黑料吃瓜"),
    ("14", "重口调教"),
    ("15", "直播大秀"),
    ("22", "白虎嫩妹"),
    ("16", "网红主播"),
    ("23", "家庭乱伦"),
    ("9", "麻豆传媒"),
    ("17", "媚黑母狗"),
    ("24", "熟女偷情"),
    ("18", "白虎少女"),
    ("25", "网黄原创"),
];

async fn get_json(url: &str) -> ApiResult<Value> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<Value> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "2048成人短剧请求 HTTP {status}"
        )));
    }
    resp.json::<Value>()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 查询值百分号编码（encodeURIComponent 风格，/ 也编码）。
fn encode_component(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~') {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// 取流地址：.m3u8 走同源代理，其余原样（相对路径补基址）。
fn playable_url(video_url: &str) -> String {
    let u = video_url.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.to_ascii_lowercase().ends_with(".m3u8") {
        let path = u.strip_prefix('/').unwrap_or(u);
        return format!("{BASE}/api/v1/m3u8/proxy?path={}", encode_component(path));
    }
    if u.starts_with("http") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{BASE}/{rest}");
    }
    format!("{BASE}/{u}")
}

fn fix_cover(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{BASE}/{rest}");
    }
    format!("{BASE}/{u}")
}

fn fmt_duration(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    format!("{:02}:{:02}", secs / 60, secs % 60)
}

/// 列表项解析：id/title/coverUrl/videoUrl/durationSec/categoryName。
fn parse_items(data: &Value) -> Vec<Value> {
    let items = match get(data, "items").and_then(arr_of) {
        Some(items) => items,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for v in items {
        let id = match get(v, "id") {
            Some(n) if n.is_number() => n.to_string(),
            _ => continue,
        };
        let title = text_of(v, &["title"]);
        if title.is_empty() {
            continue;
        }
        let cover = fix_cover(&text_of(v, &["coverUrl"]));
        let dur = get(v, "durationSec").and_then(|n| n.as_i64()).unwrap_or(0);
        out.push(item_json(&id, &title, &cover, &fmt_duration(dur)));
    }
    out
}

fn parse_categories(data: &Value) -> Vec<Value> {
    let list = match arr_of(data) {
        Some(list) => list,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for v in list {
        if text_of(v, &["type"]) != "video" {
            continue;
        }
        if let Some(false) = get(v, "enabled").and_then(|e| e.as_bool()) {
            continue;
        }
        let id = match get(v, "id") {
            Some(n) if n.is_number() => n.to_string(),
            _ => continue,
        };
        let name = text_of(v, &["name"]);
        if name.is_empty() {
            continue;
        }
        out.push(category_json(&id, &name));
    }
    out
}

fn fallback_categories() -> Value {
    json!({
    "categories": CATS
    .iter()
    .map(|(id, name)| category_json(id, name))
    .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/api/v1/categories"), &[("type", "video")]);
    match get_json(&url).await {
        Ok(v) => {
            let data = get(&v, "data").cloned().unwrap_or(Value::Null);
            let list = parse_categories(&data);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/api/v1/videos"),
        &[
            ("categoryId", category_id),
            ("page", &page.max(1).to_string()),
            ("size", "20"),
        ],
    );
    let v = get_json(&url).await?;
    let data = get(&v, "data").cloned().unwrap_or(Value::Null);
    let items = parse_items(&data);
    let total_pages = get(&data, "totalPages")
        .and_then(|n| n.as_i64())
        .unwrap_or(0);
    let has_more = !items.is_empty() && (total_pages <= 0 || page < total_pages);
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.trim();
    let url = format!("{BASE}/api/v1/videos/{vid}");
    let v = get_json(&url).await?;
    let data = get(&v, "data").cloned().unwrap_or(Value::Null);
    let title = text_of(&data, &["title"]);
    let cover = fix_cover(&text_of(&data, &["coverUrl"]));
    let synopsis = text_of(&data, &["description"]);
    let m3u8 = playable_url(&text_of(&data, &["videoUrl"]));
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("2048成人短剧未返回可播放地址".into()));
    }
    let dur = get(&data, "durationSec")
        .and_then(|n| n.as_i64())
        .unwrap_or(0);
    let author = text_of(&data, &["authorName"]);
    let views = get(&data, "viewCount")
        .and_then(|n| n.as_i64())
        .unwrap_or(0);
    Ok(json!({
    "id": series_id,
    "title": title,
    "cover": cover,
    "synopsis": synopsis,
    "extra": {"author": author, "duration_sec": dur, "view_count": views},
    "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("2048成人短剧该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/api/v1/videos/search"),
        &[("q", query.trim())],
    );
    let v = get_json(&url).await?;
    let data = get(&v, "data").cloned().unwrap_or(Value::Null);
    let items = parse_items(&data);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn playable_url_proxy() {
        assert_eq!(
playable_url("jpd/20260819/rq/gy/pp/nc/a5d2db70130943eb8a832cdf24d50725.m3u8"),
"https://madouai.xyz/api/v1/m3u8/proxy?path=jpd%2F20260819%2Frq%2Fgy%2Fpp%2Fnc%2Fa5d2db70130943eb8a832cdf24d50725.m3u8"
);
        assert_eq!(
            playable_url("https://cdn.example.com/a.mp4"),
            "https://cdn.example.com/a.mp4"
        );
        assert_eq!(playable_url(""), "");
    }

    #[test]
    fn parse_categories_real_payload() {
        let v: Value = serde_json::from_str(
r#"[{"id":2,"name":"AV - 中文字幕","productId":1,"type":"video","sortOrder":1,"enabled":true},{"id":1,"name":"国产自拍（最新更新）","productId":1,"type":"video","sortOrder":1,"enabled":true},{"id":99,"name":"已下线","productId":1,"type":"video","sortOrder":1,"enabled":false},{"id":5,"name":"帖子","productId":1,"type":"post","sortOrder":1,"enabled":true}]"#,
)
.unwrap();
        let list = parse_categories(&v);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "2");
        assert_eq!(list[0]["name"], "AV - 中文字幕");
        assert_eq!(list[1]["id"], "1");
    }

    #[test]
    fn fallback_has_23_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 23);
        assert_eq!(list[0]["id"], "2");
        assert_eq!(list[0]["name"], "AV - 中文字幕");
        assert_eq!(list[22]["id"], "25");
        assert_eq!(list[22]["name"], "网黄原创");
    }

    #[test]
    fn parse_items_real_payload() {
        let v: Value = serde_json::from_str(
r#"{"items":[{"id":21758,"title":"为了老公献身老板","description":null,"coverUrl":"/api/v1/image/proxy?path=jhimage%2F20260819%2Fr0%2F3e%2F59%2F5f%2Fc82bb4885ce64818a87584ba5aa2303b.webp","coverEncrypted":false,"videoUrl":"jpd/20260819/rq/gy/pp/nc/a5d2db70130943eb8a832cdf24d50725.m3u8","orientation":null,"categoryId":27,"categoryName":"每日更新","durationSec":1848,"viewCount":71691,"realViewCount":3583,"likeCount":1239,"favoriteCount":9,"sourcePlatform":"gossip","authorName":"淼淼","status":"active","publishedAt":"2026-11-03T15:09:10","updatedAt":"2026-11-05T16:01:15","reviewedAt":null,"tags":[],"liked":null,"favorited":null}],"total":20163,"page":1,"size":20,"totalPages":1009}"#,
)
.unwrap();
        let items = parse_items(&v);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "21758");
        assert_eq!(items[0]["title"], "为了老公献身老板");
        assert_eq!(
items[0]["cover"],
"https://madouai.xyz/api/v1/image/proxy?path=jhimage%2F20260819%2Fr0%2F3e%2F59%2F5f%2Fc82bb4885ce64818a87584ba5aa2303b.webp"
);
        assert_eq!(items[0]["remark"], "30:48");
    }

    #[test]
    fn fmt_duration_cases() {
        assert_eq!(fmt_duration(1848), "30:48");
        assert_eq!(fmt_duration(65), "01:05");
        assert_eq!(fmt_duration(0), "");
    }

    #[test]
    fn fix_cover_cases() {
        assert_eq!(
            fix_cover("/api/v1/image/proxy?path=a%2Fb.webp"),
            "https://madouai.xyz/api/v1/image/proxy?path=a%2Fb.webp"
        );
        assert_eq!(fix_cover(""), "");
    }

    #[test]
    fn encode_component_slash() {
        assert_eq!(
            encode_component("jpd/20260819/a b.m3u8"),
            "jpd%2F20260819%2Fa%20b.m3u8"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://madouai.xyz/api/v1/m3u8/proxy?path=jpd%2F20260819%2Fa.m3u8")
            .unwrap();
        assert_eq!(
            ok["url"],
            "https://madouai.xyz/api/v1/m3u8/proxy?path=jpd%2F20260819%2Fa.m3u8"
        );
        assert!(play_check("21758").is_err());
    }
}
