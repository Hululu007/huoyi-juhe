//! AV01：JSON API + geo 令牌。
//!
//! 来源 jar 类 `ZakaAv01Amns`（`https://www.av01.media`，
//! API `https://www.av01.media/api/v1`，封面
//! `https://files.iw01.xyz`）。封面与取流都要带 geo 令牌：
//! `GET https://files.iw01.xyz/edge/geo.js?json` 得
//! `{token_v2, expires, ip, ttl}`，缓存 ttl-60 秒；
//! 取流先 `GET /videos/{id}/cdn-access?{geoQuery}` 拿
//! `access_token`，再取 master m3u8 选 ≤1080 的最高变体。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://www.av01.media";
const API: &str = "https://www.av01.media/api/v1";
const FILES: &str = "https://files.iw01.xyz";
const GEO_URL: &str = "https://files.iw01.xyz/edge/geo.js?json";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const LIMIT: i64 = 20;
const MAX_HEIGHT: i64 = 1080;

static GEO_CACHE: Lazy<Mutex<(Option<Value>, i64)>> = Lazy::new(|| Mutex::new((None, 0)));
static CDN_CACHE: Lazy<Mutex<std::collections::HashMap<String, (String, i64)>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

/// 翻译字段：`{field}_translations` 里按 cn/tw/hk/lang/en/ja
/// 取首个非空，否则取原字段。
fn tr(obj: &Value, field: &str) -> String {
    let key = format!("{field}_translations");
    if let Some(t) = get(obj, &key) {
        for lang in ["cn", "tw", "hk", "lang", "en", "ja"] {
            let v = text_of(t, &[lang]);
            if !v.is_empty() {
                return v.trim().to_string();
            }
        }
    }
    text_of(obj, &[field]).trim().to_string()
}

fn title_of(obj: &Value) -> String {
    let mut title = tr(obj, "title");
    let dvd = text_of(obj, &["dvd_id"]).trim().to_string();
    if title.is_empty() {
        title = format!("AV01-{}", text_of(obj, &["id"]));
    }
    if !dvd.is_empty() && !title.to_lowercase().contains(&dvd.to_lowercase()) {
        title = format!("{dvd} {title}");
    }
    if title.len() > 120 {
        title = title.chars().take(120).collect();
    }
    title
}

fn cover_of(id: &str) -> String {
    format!("{FILES}/covers/{id}/640.jpg")
}

fn remark_of(obj: &Value) -> String {
    let duration = get(obj, "duration").and_then(|v| v.as_i64()).unwrap_or(0);
    let mut remark = String::new();
    if duration >= 3600 {
        remark.push_str(&format!(
            "{}h{:02}m",
            duration / 3600,
            (duration % 3600) / 60
        ));
    } else if duration > 0 {
        remark.push_str(&format!("{}m", duration / 60));
    }
    let date = text_of(obj, &["release_date"]);
    let date = if date.is_empty() {
        text_of(obj, &["created_at"])
    } else {
        date
    };
    if !date.is_empty() {
        if !remark.is_empty() {
            remark.push(' ');
        }
        remark.push_str(&date.chars().take(10).collect::<String>());
    }
    if text_of(obj, &["censorship_status"]) == "decensored" {
        if !remark.is_empty() {
            remark.push(' ');
        }
        remark.push_str("无码");
    }
    remark
}

async fn geo_query() -> ApiResult<String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    {
        let guard = GEO_CACHE.lock().unwrap();
        if let (Some(cached), exp) = (&guard.0, guard.1) {
            if now < exp - 60 {
                let token = text_of(cached, &["token_v2"]);
                let expires = text_of(cached, &["expires"]);
                let ip = text_of(cached, &["ip"]);
                return Ok(with_query(
                    "",
                    &[("token_v2", &token), ("expires", &expires), ("ip", &ip)],
                )
                .trim_start_matches('?')
                .to_string());
            }
        }
    }
    let resp = client()?
        .get(GEO_URL)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "AV01 geo 请求 HTTP {}",
            resp.status()
        )));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text_of(&body, &["token_v2"]).is_empty() {
        return Err(ApiError::Internal("AV01 geo 未取到 token_v2".into()));
    }
    let expires_raw = text_of(&body, &["expires"]);
    let expires: i64 = expires_raw
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or(0);
    let ttl_raw = text_of(&body, &["ttl"]);
    let ttl: i64 = ttl_raw.parse().unwrap_or(0);
    let exp = if expires > 0 {
        expires
    } else if ttl > 0 {
        now + ttl
    } else {
        now + 3600
    };
    let token = text_of(&body, &["token_v2"]);
    let ip = text_of(&body, &["ip"]);
    let query = with_query(
        "",
        &[("token_v2", &token), ("expires", &expires_raw), ("ip", &ip)],
    )
    .trim_start_matches('?')
    .to_string();
    let mut guard = GEO_CACHE.lock().unwrap();
    *guard = (Some(body), exp);
    Ok(query)
}

async fn api_get(path: &str) -> ApiResult<Value> {
    let url = format!("{API}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "AV01 请求 HTTP {}",
            resp.status()
        )));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(body)
}

fn cards(body: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let rows = match get(body, "videos").and_then(arr_of) {
        Some(a) => a.iter().collect::<Vec<_>>(),
        None => match get(body, "data").and_then(arr_of) {
            Some(a) => a.iter().collect::<Vec<_>>(),
            None => Vec::new(),
        },
    };
    for row in rows {
        let id = text_of(row, &["id"]);
        if id.is_empty() {
            continue;
        }
        let title = title_of(row);
        items.push(item_json(&id, &title, &cover_of(&id), &remark_of(row)));
    }
    items
}

fn total_pages(body: &Value) -> i64 {
    if let Some(p) = get(body, "pagination") {
        if let Some(t) = get(p, "totalPages").and_then(|v| v.as_i64()) {
            return t;
        }
        if let Some(t) = get(p, "total_pages").and_then(|v| v.as_i64()) {
            return t;
        }
        if let Some(total) = get(p, "total").and_then(|v| v.as_i64()) {
            return (total + LIMIT - 1) / LIMIT;
        }
    }
    0
}

async fn cdn_token(video_id: &str) -> ApiResult<String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    {
        let guard = CDN_CACHE.lock().unwrap();
        if let Some((tok, exp)) = guard.get(video_id) {
            if now < *exp {
                return Ok(tok.clone());
            }
        }
    }
    let query = geo_query().await?;
    let url = format!("{API}/videos/{video_id}/cdn-access?{query}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let token = text_of(&body, &["access_token"]);
    if token.is_empty() {
        // 刷新 geo 重试一次。
        {
            let mut guard = GEO_CACHE.lock().unwrap();
            *guard = (None, 0);
        }
        let query = geo_query().await?;
        let url = format!("{API}/videos/{video_id}/cdn-access?{query}");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let body: Value = resp
            .json()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let token = text_of(&body, &["access_token"]);
        if token.is_empty() {
            return Err(ApiError::Internal("AV01 未取到 cdn access_token".into()));
        }
        let exp = text_of(&body, &["expires_at"])
            .parse::<i64>()
            .unwrap_or(now + 3_000_000);
        let mut guard = CDN_CACHE.lock().unwrap();
        guard.insert(video_id.to_string(), (token.clone(), exp));
        return Ok(token);
    }
    let exp = text_of(&body, &["expires_at"])
        .parse::<i64>()
        .unwrap_or(now + 3_000_000);
    let mut guard = CDN_CACHE.lock().unwrap();
    guard.insert(video_id.to_string(), (token.clone(), exp));
    Ok(token)
}

fn master_variants(m3u8: &str) -> Vec<(i64, String)> {
    let mut out = Vec::new();
    let mut pending: Option<i64> = None;
    for line in m3u8.lines() {
        let line = line.trim();
        if line.starts_with("#EXT-X-STREAM-INF") {
            let re = Regex::new(r"RESOLUTION=\d+x(\d+)").unwrap();
            pending = re
                .captures(line)
                .and_then(|c| c.get(1))
                .and_then(|m| m.as_str().parse::<i64>().ok());
        } else if !line.is_empty() && !line.starts_with('#') {
            if let Some(h) = pending.take() {
                out.push((h, line.to_string()));
            }
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("latest", "最新"),
        category_json("hottest", "热门"),
    ];
    let body = api_get("/tags/by-score?page=1&limit=60").await?;
    let rows = match get(&body, "tags").and_then(arr_of) {
        Some(a) => a.iter().collect::<Vec<_>>(),
        None => match get(&body, "data").and_then(arr_of) {
            Some(a) => a.iter().collect::<Vec<_>>(),
            None => Vec::new(),
        },
    };
    for row in rows {
        let id = text_of(row, &["id"]);
        if id.is_empty() {
            continue;
        }
        let name = tr(row, "name");
        let name = if name.is_empty() {
            text_of(row, &["name"])
        } else {
            name
        };
        list.push(category_json(&format!("tag:{id}"), &name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let path = if let Some(tag) = category_id.strip_prefix("tag:") {
        let digits: String = tag.chars().filter(|c| c.is_ascii_digit()).collect();
        format!("/videos/tag/{digits}?page={page}&limit={LIMIT}")
    } else if category_id == "hottest" {
        format!("/videos/types/hottest?page={page}&limit={LIMIT}")
    } else {
        format!("/videos/types/latest?page={page}&limit={LIMIT}")
    };
    let body = api_get(&path).await?;
    let items = cards(&body);
    let total = total_pages(&body);
    let has_more = if total > 0 {
        page < total
    } else {
        !items.is_empty()
    };
    // 封面要带 geo 查询串：这里返回时补上（失败则用无参封面）。
    let mut items = items;
    if let Ok(query) = geo_query().await {
        if !query.is_empty() {
            for item in items.iter_mut() {
                if let Some(cover) = item.get("cover").and_then(|v| v.as_str()) {
                    let cover = cover.to_string();
                    item["cover"] = json!(format!("{cover}?{query}"));
                }
            }
        }
    }
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    static RE_NUM: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\d+)").unwrap());
    let vid = RE_NUM
        .captures(series_id)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| series_id.to_string());
    let body = api_get(&format!("/videos/{vid}")).await?;
    let title = title_of(&body);
    let dvd = text_of(&body, &["dvd_id"]).trim().to_string();
    let mut actors = Vec::new();
    if let Some(arr) = get(&body, "actresses").and_then(arr_of) {
        for a in arr {
            let name = tr(a, "name");
            let name = if name.is_empty() {
                text_of(a, &["name"])
            } else {
                name
            };
            if !name.is_empty() {
                actors.push(name);
            }
        }
    }
    let mut maker = tr(&body, "maker");
    if maker.is_empty() {
        maker = text_of(&body, &["maker"]);
    }
    if actors.is_empty() && !maker.is_empty() {
        actors.push(maker.clone());
    }
    let mut tags = Vec::new();
    if let Some(arr) = get(&body, "tags").and_then(arr_of) {
        for t in arr.iter().take(12) {
            let name = tr(t, "name");
            let name = if name.is_empty() {
                text_of(t, &["name"])
            } else {
                name
            };
            if !name.is_empty() {
                tags.push(name);
            }
        }
    }
    let desc = tr(&body, "description");
    let desc = if desc.is_empty() {
        text_of(&body, &["description"])
    } else {
        desc
    };
    let mut director = tr(&body, "director");
    if director.is_empty() {
        director = text_of(&body, &["director"]);
    }
    let mut synopsis = String::new();
    if !dvd.is_empty() {
        synopsis.push_str(&format!("番号：{dvd}\n"));
    }
    if !maker.is_empty() {
        synopsis.push_str(&format!("制作：{maker}\n"));
    }
    if !director.is_empty() {
        synopsis.push_str(&format!("导演：{director}\n"));
    }
    if !remark_of(&body).is_empty() {
        synopsis.push_str(&format!("规格：{}\n", remark_of(&body)));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("标签：{}\n", tags.join("、")));
    }
    synopsis.push_str(&desc);
    synopsis.push_str("\n来源：AV01");
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { format!("AV01-{vid}") } else { title },
        "cover": cover_of(&vid),
        "synopsis": synopsis,
        "extra": {"actor": actors.join("、"), "dvd": dvd},
        "episodes": [episode_json(&vid, "正片", series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let body = json!({
        "query": query,
        "pagination": {"page": 1, "limit": LIMIT},
    });
    let resp = client()?
        .post(format!("{API}/videos/search?lang=jp"))
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "AV01 搜索 HTTP {}",
            resp.status()
        )));
    }
    let result: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(json!({"items": cards(&result)}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    static RE_NUM: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\d+)").unwrap());
    let vid = RE_NUM
        .captures(video_id)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| video_id.to_string());
    let token = cdn_token(&vid).await?;
    let url = format!("{API}/videos/{vid}/manifest/master.m3u8");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "AV01 清单 HTTP {}",
            resp.status()
        )));
    }
    let m3u8 = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let variants = master_variants(&m3u8);
    let chosen = variants
        .iter()
        .filter(|(h, _)| *h <= MAX_HEIGHT)
        .max_by_key(|(h, _)| *h)
        .or_else(|| variants.first())
        .map(|(_, u)| u.clone());
    let Some(rel) = chosen else {
        return Err(ApiError::Internal("AV01 清单无变体".into()));
    };
    let abs = if rel.starts_with("http") {
        rel
    } else {
        format!("{API}/videos/{vid}/manifest/{rel}")
    };
    let enc = url::form_urlencoded::byte_serialize(token.as_bytes()).collect::<String>();
    let sep = if abs.contains('?') { "&" } else { "?" };
    Ok(json!({"url": format!("{abs}{sep}access_token={enc}")}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tr_prefers_cn() {
        let obj = json!({
            "title_translations": {"cn": "中文名", "en": "English"},
            "title": "fallback"
        });
        assert_eq!(tr(&obj, "title"), "中文名");
        let obj2 = json!({"title_translations": {"en": "English"}, "title": "fallback"});
        assert_eq!(tr(&obj2, "title"), "English");
        let obj3 = json!({"title": "fallback"});
        assert_eq!(tr(&obj3, "title"), "fallback");
    }

    #[test]
    fn title_prefixes_dvd() {
        let obj = json!({"id": "123", "dvd_id": "ABC-001", "title": "Some Title"});
        assert_eq!(title_of(&obj), "ABC-001 Some Title");
        let obj2 = json!({"id": "123", "dvd_id": "ABC-001", "title": "ABC-001 Some Title"});
        assert_eq!(title_of(&obj2), "ABC-001 Some Title");
    }

    #[test]
    fn remark_formats_duration() {
        let obj = json!({"duration": 3660, "censorship_status": "decensored"});
        assert_eq!(remark_of(&obj), "1h01m 无码");
        let obj2 = json!({"duration": 300});
        assert_eq!(remark_of(&obj2), "5m");
    }

    #[test]
    fn master_variants_pick() {
        let m3u8 = "#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1920x1080\n1080.m3u8\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\n720.m3u8\n";
        let vars = master_variants(m3u8);
        assert_eq!(vars.len(), 2);
        let chosen = vars
            .iter()
            .filter(|(h, _)| *h <= MAX_HEIGHT)
            .max_by_key(|(h, _)| *h)
            .unwrap();
        assert_eq!(chosen.1, "1080.m3u8");
    }
}
