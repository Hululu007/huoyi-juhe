//! 🔞MissAV官方：走 ystv 中继站的 MissAV 官方源。
//!
//! 与 jar 的 ZakaMissavAmns 一一对应：注册拿令牌（POST /api/tvbox/reg，
//! body dev/src，令牌与设备指纹绑定、同一设备串复用）、分类（home
//! 接口，失败回退 6 固定分类）、目录、详情、搜索、取流（relay 接口
//! 回中继 m3u8＋头，无则 resolve 接口，再兜底 hls/go 直链）。
//! 注意：中继 m3u8 必须带接口回的头（UA okhttp/3.12.0＋Referer）才
//! 能拉到分片，桌面 UA 直接 403；取流只回真直链加 dict 头。
//! 验门（2026-11-05 请求复现）：注册、分类 6 条、目录 48 条带真
//! 封面、翻页、详情、搜索 48 条、取流中继 m3u8 首分片 200 全过。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const MISS: &str = "https://missav.ws286.ystv.top";
const DEVICE: &str = "Pixel 8-Google";
const SRC: &str = "missav-official";
const TOKEN_TTL: Duration = Duration::from_secs(6 * 3600);

static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 中继回的播放头：UA okhttp/3.12.0＋Referer 中继站。
fn relay_header() -> Value {
    json!({"User-Agent": "okhttp/3.12.0", "Referer": format!("{MISS}/")})
}

/// 注册：POST /api/tvbox/reg，body {"dev","src"}，回 {"ok","tok"}。
async fn register() -> ApiResult<String> {
    let resp = client()?
        .post(format!("{MISS}/api/tvbox/reg"))
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        .json(&json!({"dev": DEVICE, "src": SRC}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("MissAV 注册 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    let tok = text_of(&body, &["tok"]);
    if tok.is_empty() {
        return Err(ApiError::Internal("MissAV 未返回访问令牌".into()));
    }
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = Some((tok.clone(), Instant::now() + TOKEN_TTL));
    }
    Ok(tok)
}

/// 令牌：6 小时内复用缓存，过期重注册。
async fn token() -> ApiResult<String> {
    if let Ok(guard) = TOKEN.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok(cached.clone());
            }
        }
    }
    register().await
}

/// 令牌失效时清缓存，下次调用重注册。
fn drop_token() {
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = None;
    }
}

/// 带令牌的 GET：每次请求带 ?t=<tok>&dev=<dev>。
async fn authed_get(path: &str, query: &[(&str, &str)]) -> ApiResult<Value> {
    let tok = token().await?;
    let mut params: Vec<(&str, &str)> = vec![("t", tok.as_str()), ("dev", DEVICE)];
    params.extend_from_slice(query);
    let url = with_query(&format!("{MISS}{path}"), &params);
    let resp = client()?
        .get(&url)
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("MissAV 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("MissAV 数据格式无法识别".into()));
    }
    Ok(body)
}

fn fallback_categories() -> Value {
    json!({"categories": [
        category_json("cn/new", "最近更新"),
        category_json("cn/release", "新作上市"),
        category_json("cn/uncensored-leak", "无码流出"),
        category_json("cn/actresses", "女优一览"),
        category_json("cn/genres", "类型"),
        category_json("cn/makers", "发行商"),
    ]})
}

/// 目录行转视频卡片：vod_id/vod_name/vod_pic/vod_remarks 直取。
fn catalog_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for entry in rows {
        let id = text_of(entry, &["vod_id"]);
        let title = text_of(entry, &["vod_name"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = text_of(entry, &["vod_pic"]);
        let remark = text_of(entry, &["vod_remarks"]);
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn parse_list(resp: &Value) -> Vec<Value> {
    match get(resp, "list").and_then(arr_of) {
        Some(rows) => catalog_items(rows),
        None => Vec::new(),
    }
}

fn parse_pagecount(resp: &Value) -> i64 {
    let total = match get(resp, "total") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    let pagecount = match get(resp, "pagecount") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    if pagecount > 0 {
        return pagecount;
    }
    let limit = match get(resp, "limit") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    if total > 0 && limit > 0 {
        return (total + limit - 1) / limit;
    }
    0
}

/// 分集串转分集：形如 "自动$wawa-045@auto#720P$wawa-045@720"，取 $ 后
/// 的地址作 video_id，$ 前的作集名；无 $ 时整段作集名与地址。
fn parse_episodes(play_url: &str, series_id: &str) -> Vec<Value> {
    let mut episodes = Vec::new();
    for part in play_url.split('#') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let (title, video_id) = match part.split_once('$') {
            Some((t, u)) if !u.is_empty() => (t.to_string(), u.to_string()),
            _ => (part.to_string(), part.to_string()),
        };
        let title = if title.is_empty() {
            video_id.clone()
        } else {
            title
        };
        episodes.push(episode_json(&video_id, &title, series_id));
    }
    episodes
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match authed_get("/api/tvbox/home", &[("nav", "1")]).await {
        Ok(resp) => {
            let list = match get(&resp, "class").and_then(arr_of) {
                Some(rows) => {
                    let mut list = Vec::new();
                    for entry in rows {
                        let id = text_of(entry, &["type_id"]);
                        let name = text_of(entry, &["type_name"]);
                        if !id.is_empty() && !name.is_empty() {
                            list.push(category_json(&id, &name));
                        }
                    }
                    list
                }
                None => Vec::new(),
            };
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
    let cid = if category_id.is_empty() {
        "hot:latest"
    } else {
        category_id
    };
    let page_num = page.to_string();
    let resp = authed_get(
        "/api/tvbox/list",
        &[("cid", cid), ("pg", page_num.as_str())],
    )
    .await?;
    let items = parse_list(&resp);
    let pagecount = parse_pagecount(&resp);
    let has_more = if pagecount > 0 {
        page < pagecount
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let resp = authed_get("/api/tvbox/detail", &[("id", series_id)]).await?;
    let rows = match get(&resp, "list").and_then(arr_of) {
        Some(rows) => rows,
        None => return Err(ApiError::Internal("MissAV 未返回影片资料".into())),
    };
    let first = match rows.first() {
        Some(v) => v,
        None => return Err(ApiError::Internal("MissAV 未返回影片资料".into())),
    };
    let title = text_of(first, &["vod_name"]);
    let cover = text_of(first, &["vod_pic"]);
    let remark = text_of(first, &["vod_remarks"]);
    let synopsis = text_of(first, &["vod_content"]);
    let play_url = text_of(first, &["vod_play_url"]);
    let episodes = parse_episodes(&play_url, series_id);
    if episodes.is_empty() {
        return Err(ApiError::Internal("MissAV 未返回可播放分集".into()));
    }
    let mut extra = serde_json::Map::new();
    if !remark.is_empty() {
        extra.insert("remark".to_string(), Value::String(remark));
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
    let resp = authed_get("/api/tvbox/search", &[("wd", query), ("pg", "1")]).await?;
    let items = parse_list(&resp);
    Ok(json!({"items": items}))
}

/// 取流：先 relay 接口，无则 resolve 接口（uuid 拼 surrit 直链），
/// 最后兜底 hls/go 直链；回真直链加接口给的头。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (slug, quality) = match video_id.split_once('@') {
        Some((s, q)) => (s.to_string(), q.to_string()),
        None => (video_id.to_string(), String::new()),
    };
    let slug = slug.trim().to_string();
    if slug.is_empty() {
        return Err(ApiError::Internal("MissAV 该集没有播放地址".into()));
    }
    let id_param = if quality.is_empty() || quality == "main" {
        slug.clone()
    } else {
        format!("{slug}@{quality}")
    };
    // 1. relay 接口
    let resp = authed_get(
        "/api/tvbox/play",
        &[("id", id_param.as_str()), ("mode", "relay")],
    )
    .await;
    if let Ok(body) = resp {
        let url = text_of(&body, &["url"]);
        if !url.is_empty() {
            let header = match get(&body, "header") {
                Some(h) if h.is_object() => h.clone(),
                _ => relay_header(),
            };
            return Ok(json!({"url": url, "header": header}));
        }
        if text_of(&body, &["error"]) == "unauthorized" {
            drop_token();
        }
    }
    // 2. resolve 接口
    let tok = token().await?;
    let url = with_query(
        &format!("{MISS}/api/msv/resolve"),
        &[("slug", slug.as_str()), ("t", tok.as_str())],
    );
    let resp = client()?
        .get(&url)
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() == 200 {
        if let Ok(text) = resp.text().await {
            if let Ok(body) = serde_json::from_str::<Value>(&text) {
                let url = text_of(&body, &["url"]);
                if !url.is_empty() {
                    let header = match get(&body, "header") {
                        Some(h) if h.is_object() => h.clone(),
                        _ => relay_header(),
                    };
                    return Ok(json!({"url": url, "header": header}));
                }
                let uuid = text_of(&body, &["uuid"]);
                if !uuid.is_empty() {
                    return Ok(json!({
                        "url": format!("https://surrit.com/{uuid}/playlist.m3u8"),
                        "header": {"User-Agent": "okhttp/3.12.0", "Referer": "https://missav.ws/"},
                    }));
                }
            }
        }
    }
    // 3. 兜底 hls/go 直链
    let go = with_query(
        &format!("{MISS}/hls/go"),
        &[("slug", slug.as_str()), ("k", tok.as_str())],
    );
    Ok(json!({"url": go, "header": relay_header()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn episodes_split() {
        let eps = parse_episodes(
            "自动$wawa-045@auto#720P$wawa-045@720#1080P$wawa-045@1080",
            "wawa-045",
        );
        assert_eq!(eps.len(), 3);
        assert_eq!(eps[0]["video_id"], "wawa-045@auto");
        assert_eq!(eps[0]["title"], "自动");
        assert_eq!(eps[1]["video_id"], "wawa-045@720");
        assert_eq!(eps[2]["title"], "1080P");
    }

    #[test]
    fn episodes_plain() {
        let eps = parse_episodes("wawa-045@auto", "wawa-045");
        assert_eq!(eps.len(), 1);
        assert_eq!(eps[0]["video_id"], "wawa-045@auto");
    }

    #[test]
    fn pagecount_from_total() {
        let resp = json!({"page": 1, "pagecount": 0, "limit": 48, "total": 240});
        assert_eq!(parse_pagecount(&resp), 5);
        let resp2 = json!({"pagecount": 12, "limit": 48, "total": 240});
        assert_eq!(parse_pagecount(&resp2), 12);
    }

    #[test]
    fn fallback_has_six() {
        let cats = fallback_categories();
        assert_eq!(cats["categories"].as_array().unwrap().len(), 6);
    }

    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert!(!list.is_empty(), "missav categories empty");
        let first = list[0]["id"].as_str().unwrap().to_string();
        let r = catalog(&first, 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE missav cats={} first={first} items={}",
            list.len(),
            items.len()
        );
        assert!(!items.is_empty(), "missav catalog empty for {first}");
        assert!(!items[0]["id"].as_str().unwrap_or("").is_empty());
        assert!(!items[0]["title"].as_str().unwrap_or("").is_empty());
    }
}
