//! 🏆JAV排行榜：javrank 榜单站，走 ystv 中继取流。
//!
//! 与 jar 的 ZakaJavRankAmns 一一对应：注册拿令牌（src javrank，
//! 设备串 zaka-javrank-<十六进制时间戳秒>，进程内只生成一次）、
//! 分类（home 接口的 class 数组，失败时解析 groups 再回退 8 固定
//! 分类）、目录、详情、搜索、取流（与 MissAV 同一条中继链：relay
//! 接口→resolve 接口→miss 页地址）。
//! 验门（2026-11-05 请求复现）：home、目录 24 条带真封面、翻页、
//! 详情、搜索全过；取流当时中继取不到源（@main unavailable、@raw
//! 回 404 占位 m3u8、resolve 回 missav.ws 429，疑似源站限流；同
//! 源 MissAV 的中继当时正常），链路照 jar 原样写，待中继恢复后
//! 在手机侧复验取流。

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const SITE: &str = "https://javrank849.ystv.top";
const MISS: &str = "https://missav.ws286.ystv.top";
const SRC: &str = "javrank";
const TOKEN_TTL: Duration = Duration::from_secs(6 * 3600);

static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);
static DEVICE: OnceLock<String> = OnceLock::new();

/// 设备串：zaka-javrank-<十六进制时间戳秒>，进程内只生成一次，
/// 与注册时绑定的指纹一致。
fn device() -> &'static str {
    DEVICE.get_or_init(|| {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(1_700_000_000);
        format!("zaka-javrank-{secs:x}")
    })
}

fn relay_header() -> Value {
    json!({"User-Agent": "okhttp/3.12.0", "Referer": format!("{MISS}/")})
}

async fn register() -> ApiResult<String> {
    let resp = client()?
        .post(format!("{MISS}/api/tvbox/reg"))
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        .json(&json!({"dev": device(), "src": SRC}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAV排行榜注册 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    let tok = text_of(&body, &["tok"]);
    if tok.is_empty() {
        return Err(ApiError::Internal("JAV排行榜未返回访问令牌".into()));
    }
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = Some((tok.clone(), Instant::now() + TOKEN_TTL));
    }
    Ok(tok)
}

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

fn drop_token() {
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = None;
    }
}

/// 带令牌的站内 GET：/api/...?t=&dev=。
async fn site_get(path: &str, query: &[(&str, &str)]) -> ApiResult<Value> {
    let tok = token().await?;
    let mut params: Vec<(&str, &str)> = vec![("t", tok.as_str()), ("dev", device())];
    params.extend_from_slice(query);
    let url = with_query(&format!("{SITE}{path}"), &params);
    let resp = client()?
        .get(&url)
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAV排行榜请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("JAV排行榜数据格式无法识别".into()));
    }
    Ok(body)
}

/// 带令牌的中继 GET：/api/tvbox/...?t=&dev=。
async fn relay_get(path: &str, query: &[(&str, &str)]) -> ApiResult<Value> {
    let tok = token().await?;
    let mut params: Vec<(&str, &str)> = vec![("t", tok.as_str()), ("dev", device())];
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
        return Err(ApiError::Internal(format!("JAV排行榜请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("JAV排行榜数据格式无法识别".into()));
    }
    Ok(body)
}

fn fallback_categories() -> Value {
    json!({"categories": [
        category_json("rk-all", "🏆全站神作总榜"),
        category_json("rk-top100", "🏆TOP100"),
        category_json("rk-javdb-top250", "JAVDB TOP250"),
        category_json("rk-javlibrary-top250", "JAVLibrary TOP250"),
        category_json("st-high", "⭐高分"),
        category_json("st-new", "⭐新作"),
        category_json("yr-2025", "2025"),
        category_json("yr-2024", "2024"),
    ]})
}

fn catalog_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for entry in rows {
        let id = text_of(entry, &["vod_id", "id"]);
        let title = text_of(entry, &["vod_name", "name", "title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = text_of(entry, &["vod_pic", "pic", "cover"]);
        let remark = text_of(entry, &["vod_remarks", "remark"]);
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
    let pagecount = match get(resp, "pagecount") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    if pagecount > 0 {
        return pagecount;
    }
    let total = match get(resp, "total") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    let limit = match get(resp, "limit") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        _ => 0,
    };
    if total > 0 && limit > 0 {
        return (total + limit - 1) / limit;
    }
    0
}

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
    match site_get("/api/home", &[]).await {
        Ok(resp) => {
            let mut list = Vec::new();
            if let Some(rows) = get(&resp, "class").and_then(arr_of) {
                for entry in rows {
                    let id = text_of(entry, &["type_id"]);
                    let name = text_of(entry, &["type_name"]);
                    if !id.is_empty() && !name.is_empty() {
                        list.push(category_json(&id, &name));
                    }
                }
            }
            if list.is_empty() {
                if let Some(groups) = get(&resp, "groups").and_then(arr_of) {
                    for group in groups {
                        let gname = text_of(group, &["name", "group_name"]);
                        let prefix: String = gname.chars().take(2).collect();
                        if let Some(cats) = get(group, "cats").and_then(arr_of) {
                            for entry in cats {
                                let id = text_of(entry, &["type_id"]);
                                let name = text_of(entry, &["type_name"]);
                                if !id.is_empty() && !name.is_empty() {
                                    list.push(category_json(&id, &format!("{prefix}{name}")));
                                }
                            }
                        }
                    }
                }
            }
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
    let cat = if category_id.is_empty() {
        "rk-all"
    } else {
        category_id
    };
    let page_num = page.to_string();
    let resp = site_get("/api/list", &[("cat", cat), ("page", page_num.as_str())]).await?;
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
    let resp = site_get("/api/detail", &[("id", series_id)]).await?;
    let rows = match get(&resp, "list").and_then(arr_of) {
        Some(rows) => rows,
        None => return Err(ApiError::Internal("JAV排行榜未返回影片资料".into())),
    };
    let first = match rows.first() {
        Some(v) => v,
        None => return Err(ApiError::Internal("JAV排行榜未返回影片资料".into())),
    };
    let title = text_of(first, &["vod_name"]);
    let cover = text_of(first, &["vod_pic"]);
    let remark = text_of(first, &["vod_remarks"]);
    let synopsis = text_of(first, &["vod_content"]);
    let play_url = text_of(first, &["vod_play_url"]);
    let episodes = parse_episodes(&play_url, series_id);
    if episodes.is_empty() {
        return Err(ApiError::Internal("JAV排行榜未返回可播放分集".into()));
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
    let resp = site_get("/api/search", &[("wd", query), ("page", "1")]).await?;
    let items = parse_list(&resp);
    Ok(json!({"items": items}))
}

/// 取流：直链直接回；番号[@清晰度]走中继 relay 接口，无则 resolve
/// 接口（uuid 拼 surrit 直链），最后兜底 miss 页地址。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id, "header": relay_header()}));
    }
    let slug = video_id.trim();
    if slug.is_empty() {
        return Err(ApiError::Internal("JAV排行榜该集没有播放地址".into()));
    }
    // 1. relay 接口（q 非 main 时带 q 参，与 jar 一致）
    let (id_param, q_param) = match slug.split_once('@') {
        Some((_, q)) if !q.is_empty() && q != "main" => (slug.to_string(), Some(q.to_string())),
        Some(_) => (slug.split('@').next().unwrap_or(slug).to_string(), None),
        None => (slug.to_string(), None),
    };
    let mut query: Vec<(&str, &str)> = vec![("id", id_param.as_str()), ("mode", "relay")];
    if let Some(q) = &q_param {
        query.push(("q", q.as_str()));
    }
    if let Ok(body) = relay_get("/api/tvbox/play", &query).await {
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
    let base_slug = slug.split('@').next().unwrap_or(slug);
    let tok = token().await?;
    let url = with_query(
        &format!("{MISS}/api/msv/resolve"),
        &[("slug", base_slug), ("t", tok.as_str())],
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
    // 3. 兜底 miss 页地址（壳侧嗅探）
    Ok(json!({
        "url": format!("{MISS}/miss/{}", base_slug.to_lowercase()),
        "header": relay_header(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_prefix() {
        assert!(device().starts_with("zaka-javrank-"));
    }

    #[test]
    fn episodes_keep_preview() {
        let eps = parse_episodes(
            "预告片$https://static.javranking.cc/video/preview/3.mp4#正片(高清)$IPX-811@main",
            "IPX-811",
        );
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0]["title"], "预告片");
        assert_eq!(eps[1]["video_id"], "IPX-811@main");
    }

    #[test]
    fn fallback_has_eight() {
        let cats = fallback_categories();
        assert_eq!(cats["categories"].as_array().unwrap().len(), 8);
    }
}
