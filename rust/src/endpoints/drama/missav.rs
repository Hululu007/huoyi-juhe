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

use std::future::Future;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const MISS: &str = "https://missav.ws286.ystv.top";
const DEVICE: &str = "Pixel 8-Google";
const SRC: &str = "missav-official";
const TOKEN_TTL: Duration = Duration::from_secs(6 * 3600);
const DESKTOP_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 429 退避重试：中继被 CF 临时限流（2026-11-07 约 40 分钟后自通）
/// 时逐个重试、不并行 burst（12 路并行曾全灭，逐个都通）。最多
/// 重试 3 次（共 4 次尝试），退避 2/5/10 秒；重试换新客户端
/// （新连接池→新连接→新出口 IP），不用同一个 IP 死磕。
/// 429 响应本身回得快，退避总共 17 秒；20 秒单次超时只在服务端
/// 挂起时才触发。只对 429 重试，别的错立即回。
const MAX_429_RETRIES: u32 = 3;
const RETRY_429_BACKOFF: [Duration; 3] = [
    Duration::from_secs(2),
    Duration::from_secs(5),
    Duration::from_secs(10),
];

/// 429 时第 attempt 次尝试后该等多久：非 429 或已用完重试次数
/// 时为 None（不重试）。纯函数，可单测。
fn backoff_for_429(status: u16, attempt: u32) -> Option<Duration> {
    if status != 429 {
        return None;
    }
    let idx = attempt as usize;
    if idx < MAX_429_RETRIES as usize && idx < RETRY_429_BACKOFF.len() {
        Some(RETRY_429_BACKOFF[idx])
    } else {
        None
    }
}

/// 新客户端：与共享客户端同款超时，但连接池全新——重试时用它发
/// 请求就是新连接，走出口代理换新 IP。调前须先保证共享客户端
/// 建过（它装 rustls 默认 provider），建不出来如实报错。
fn fresh_client() -> ApiResult<reqwest::Client> {
    let _ = client()?;
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 429 退避重试发送器：send_once(attempt) 发一次拿回响应；
/// 429 且未用完次数时按退避表睡一会儿再试（逐个、不并行）。
/// 传输出错直接回错，不重试；backoff 切片供测试用短间隔。
async fn send_with_429_retry_backoff<F, Fut>(
    mut send_once: F,
    backoff: &[Duration],
) -> ApiResult<reqwest::Response>
where
    F: FnMut(u32) -> Fut,
    Fut: Future<Output = ApiResult<reqwest::Response>>,
{
    let mut attempt: u32 = 0;
    loop {
        let resp = send_once(attempt).await?;
        let status = resp.status().as_u16();
        let wait = if status == 429 && (attempt as usize) < backoff.len() {
            Some(backoff[attempt as usize])
        } else {
            None
        };
        match wait {
            Some(d) => {
                tokio::time::sleep(d).await;
                attempt += 1;
            }
            None => return Ok(resp),
        }
    }
}

async fn send_with_429_retry<F, Fut>(send_once: F) -> ApiResult<reqwest::Response>
where
    F: FnMut(u32) -> Fut,
    Fut: Future<Output = ApiResult<reqwest::Response>>,
{
    send_with_429_retry_backoff(send_once, &RETRY_429_BACKOFF).await
}

static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 中继回的播放头：UA okhttp/3.12.0＋Referer 中继站。
fn relay_header() -> Value {
    json!({"User-Agent": "okhttp/3.12.0", "Referer": format!("{MISS}/")})
}

/// 注册：POST /api/tvbox/reg，body {"dev","src"}，回 {"ok","tok"}。
/// 429 时换新客户端（新连接→新出口 IP）逐个重试，最多 3 次。
async fn register() -> ApiResult<String> {
    let resp = send_with_429_retry(|attempt| async move {
        if attempt == 0 {
            send_reg(client()?).await
        } else {
            let fresh = fresh_client()?;
            send_reg(&fresh).await
        }
    })
    .await?;
    let status = resp.status().as_u16();
    if status == 429 {
        return Err(ApiError::Internal(
            "MissAV 注册被限流 429（已重试 3 次）".into(),
        ));
    }
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

/// 注册请求体：供 register 的重试闭包用，客户端由调用方给
/// （首试共享客户端，重试新客户端；借用只活在本次 send 内）。
async fn send_reg(c: &reqwest::Client) -> ApiResult<reqwest::Response> {
    c.post(format!("{MISS}/api/tvbox/reg"))
        .header("User-Agent", DESKTOP_UA)
        .json(&json!({"dev": DEVICE, "src": SRC}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 带令牌的 GET：每次请求带 ?t=<tok>&dev=<dev>。429 时换新客户端
/// （新连接→新出口 IP）逐个重试，最多 3 次。
async fn send_authed(c: &reqwest::Client, url: &str) -> ApiResult<reqwest::Response> {
    c.get(url)
        .header("User-Agent", DESKTOP_UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
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
    let resp = send_with_429_retry(|attempt| {
        let url = url.clone();
        async move {
            if attempt == 0 {
                send_authed(client()?, &url).await
            } else {
                let fresh = fresh_client()?;
                send_authed(&fresh, &url).await
            }
        }
    })
    .await?;
    let status = resp.status().as_u16();
    if status == 429 {
        return Err(ApiError::Internal(
            "MissAV 请求被限流 429（已重试 3 次）".into(),
        ));
    }
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

/// 播放头（JSON 对象）套到请求上：只取字符串值。
fn apply_header(req: reqwest::RequestBuilder, header: &Value) -> reqwest::RequestBuilder {
    let mut req = req;
    if let Some(map) = header.as_object() {
        for (k, v) in map {
            if let Value::String(s) = v {
                req = req.header(k.as_str(), s.as_str());
            }
        }
    }
    req
}

/// 拉中继给的清单：只 200 才算拿到，别的都算拿不到。
async fn fetch_playlist(url: &str, header: &Value) -> Option<String> {
    let req = apply_header(
        client().ok()?.get(url).header("User-Agent", DESKTOP_UA),
        header,
    );
    let resp = req.send().await.ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    resp.text().await.ok()
}

/// 清单检查结果：Complete 能播；Incomplete 确定缺片（200 但清单
/// 不完整，或 404/410 对象不存在）；Unknown 验不出来（拉取失败、
/// 403 等——比如分流到 surrit 后 Rust 客户端吃 CF 403，证明不了
/// 清单坏，只能原样回）。
enum PlaylistCheck {
    Complete,
    Incomplete,
    Unknown,
}

/// 验中继给的 .m3u8：跟随跳转后按最终状态与清单内容定性。
async fn check_playlist(url: &str, header: &Value) -> PlaylistCheck {
    let req = match client() {
        Ok(c) => apply_header(c.get(url).header("User-Agent", DESKTOP_UA), header),
        Err(_) => return PlaylistCheck::Unknown,
    };
    let resp = match req.send().await {
        Ok(r) => r,
        Err(_) => return PlaylistCheck::Unknown,
    };
    let status = resp.status().as_u16();
    if status == 404 || status == 410 {
        return PlaylistCheck::Incomplete;
    }
    if status != 200 {
        return PlaylistCheck::Unknown;
    }
    match resp.text().await {
        Ok(body) => {
            if playlist_complete(&body) {
                PlaylistCheck::Complete
            } else {
                PlaylistCheck::Incomplete
            }
        }
        Err(_) => PlaylistCheck::Unknown,
    }
}

/// 清单完整才算能播：主清单至少 1 条分档 .m3u8 行；媒体清单
/// 至少 1 个分片行且带 #EXT-X-ENDLIST（VOD 完整标志）。缺
/// ENDLIST/无分片/非 m3u8（如 CF 挑战页）都算缺片。
fn playlist_complete(m3u8: &str) -> bool {
    if !m3u8.contains("#EXTM3U") {
        return false;
    }
    if m3u8.contains("#EXT-X-STREAM-INF") {
        return m3u8.lines().any(|l| l.trim().ends_with(".m3u8"));
    }
    let has_seg = m3u8
        .lines()
        .any(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'));
    has_seg && m3u8.contains("#EXT-X-ENDLIST")
}

/// 原生兜底：中继清单缺片/拉不到时，走 missavoff 详情拿原生流。
/// quality 对上分集名（1080→1080P、720→720P，其余取首集即主清单）。
async fn missavoff_fallback(slug: &str, quality: &str) -> ApiResult<Value> {
    let d = super::missavoff::detail(slug).await?;
    let eps = match d.get("episodes").and_then(|v| v.as_array()) {
        Some(eps) if !eps.is_empty() => eps,
        _ => return Err(ApiError::Internal("MissAV原生兜底无分集".into())),
    };
    let want = if quality.contains("1080") {
        "1080P"
    } else if quality.contains("720") {
        "720P"
    } else {
        ""
    };
    let mut picked: Option<&Value> = None;
    if !want.is_empty() {
        picked = eps.iter().find(|e| {
            e.get("title")
                .and_then(|t| t.as_str())
                .map(|t| t == want)
                .unwrap_or(false)
        });
    }
    let ep = picked.or_else(|| eps.first()).unwrap();
    let url = match ep.get("video_id").and_then(|v| v.as_str()) {
        Some(u) if u.contains(".m3u8") => u.to_string(),
        _ => return Err(ApiError::Internal("MissAV原生兜底无 m3u8".into())),
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": DESKTOP_UA, "Referer": "https://missav.live/"},
    }))
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
            // 任务 6：中继清单缺片时回退原生 missavoff。只验 .m3u8；
            // 非 m3u8 直链不验、原样回（无缺片场景行为不变）。
            if url.contains(".m3u8") {
                match fetch_playlist(&url, &header).await {
                    Some(list) if playlist_complete(&list) => {
                        return Ok(json!({"url": url, "header": header}));
                    }
                    _ => {
                        if let Ok(fb) = missavoff_fallback(&slug, &quality).await {
                            return Ok(fb);
                        }
                        // 兜底也失败，继续走原 resolve/hls-go 链路。
                    }
                }
            } else {
                return Ok(json!({"url": url, "header": header}));
            }
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
                    // 任务 6（同 relay 步）：resolve 给的也是中继清单，
                    // 实测 fjin-172@auto 回的 hls/uuid 清单在 surrit
                    // 上 404（对象不存在）。确定缺片才回退原生；
                    // 验不出来（拉取失败/403）时原样回，不乱切。
                    if url.contains(".m3u8") {
                        match check_playlist(&url, &header).await {
                            PlaylistCheck::Complete | PlaylistCheck::Unknown => {
                                return Ok(json!({"url": url, "header": header}));
                            }
                            PlaylistCheck::Incomplete => {
                                if let Ok(fb) = missavoff_fallback(&slug, &quality).await {
                                    return Ok(fb);
                                }
                                return Ok(json!({"url": url, "header": header}));
                            }
                        }
                    }
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

    #[test]
    fn backoff_for_429_table() {
        assert_eq!(backoff_for_429(429, 0), Some(Duration::from_secs(2)));
        assert_eq!(backoff_for_429(429, 1), Some(Duration::from_secs(5)));
        assert_eq!(backoff_for_429(429, 2), Some(Duration::from_secs(10)));
        assert_eq!(backoff_for_429(429, 3), None);
        assert_eq!(backoff_for_429(429, 99), None);
        assert_eq!(backoff_for_429(200, 0), None);
        assert_eq!(backoff_for_429(500, 0), None);
        assert_eq!(backoff_for_429(403, 0), None);
    }

    #[test]
    fn playlist_complete_table() {
        let full = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nvideo0.jpeg\n#EXT-X-ENDLIST\n";
        assert!(playlist_complete(full));
        let no_endlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\nvideo0.jpeg\n";
        assert!(!playlist_complete(no_endlist), "缺 ENDLIST 应判缺片");
        let no_seg = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-ENDLIST\n";
        assert!(!playlist_complete(no_seg), "无分片应判缺片");
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080\n1080p/video.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=854x480\n480p/video.m3u8\n";
        assert!(playlist_complete(master));
        let master_empty = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=8000000\n";
        assert!(!playlist_complete(master_empty));
        assert!(!playlist_complete(""));
        assert!(!playlist_complete(
            "<!DOCTYPE html><title>Attention Required!"
        ));
    }

    /// 模拟 429 路径：本地服务前 2 次回 429、第 3 次回 200，
    /// 验重试器逐个重试 3 次拿到 200（真限流已过，实测不了）。
    #[tokio::test]
    async fn retry_429_simulation() {
        use std::sync::Arc;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let count = Arc::new(Mutex::new(0u32));
        let count2 = count.clone();
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let mut buf = [0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    continue;
                }
                let n = {
                    let mut c = count2.lock().unwrap();
                    *c += 1;
                    *c
                };
                let resp = if n <= 2 {
                    "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                };
                sock.write_all(resp.as_bytes()).await.ok();
                sock.shutdown().await.ok();
            }
        });
        let url = format!("http://{addr}/");
        let backoff = [
            Duration::from_millis(10),
            Duration::from_millis(10),
            Duration::from_millis(10),
        ];
        let resp = send_with_429_retry_backoff(
            |_| {
                let url = url.clone();
                async move {
                    client()?
                        .get(&url)
                        .send()
                        .await
                        .map_err(|e| ApiError::Internal(e.to_string()))
                }
            },
            &backoff,
        )
        .await
        .unwrap();
        assert_eq!(resp.status().as_u16(), 200);
        assert_eq!(*count.lock().unwrap(), 3, "应恰好发 3 次请求");
        server.abort();
    }

    /// 探针：直接调 relay 取流接口，看它对 fjin-172 各分集回什么
    /// （live_play 只拿到 hls/go 兜底，要确认 relay 是空回还是报错）。
    #[tokio::test]
    #[ignore]
    async fn probe_relay_play_raw() {
        for id in [
            "fjin-172",
            "fjin-172@auto",
            "fjin-172@720",
            "fjin-172@1080",
            "fjin-172@master",
        ] {
            match authed_get("/api/tvbox/play", &[("id", id), ("mode", "relay")]).await {
                Ok(body) => eprintln!("PROBE relay play {id} -> {body}"),
                Err(e) => eprintln!("PROBE relay play {id} ERR {e}"),
            }
        }
        for id in ["fjin-172@auto", "fjin-172@720", "fjin-172@1080"] {
            match play(id).await {
                Ok(r) => eprintln!(
                    "PROBE play {id} -> {} header={}",
                    r["url"].as_str().unwrap_or(""),
                    r["header"].is_object()
                ),
                Err(e) => eprintln!("PROBE play {id} ERR {e}"),
            }
        }
    }

    /// 本地验 check_playlist 定性：200 完整→Complete；200 缺
    /// ENDLIST→Incomplete；404→Incomplete；403→Unknown（验不出）。
    #[tokio::test]
    async fn check_playlist_table() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let mut buf = [0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    continue;
                }
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = req
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("")
                    .to_string();
                let (status, body) = match path.as_str() {
                    "/complete" => (
                        "200 OK",
                        "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\nvideo0.jpeg\n#EXT-X-ENDLIST\n",
                    ),
                    "/truncated" => (
                        "200 OK",
                        "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\nvideo0.jpeg\n",
                    ),
                    "/gone" => ("404 Not Found", ""),
                    _ => ("403 Forbidden", ""),
                };
                let resp = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                sock.write_all(resp.as_bytes()).await.ok();
                sock.shutdown().await.ok();
            }
        });
        let header = json!({});
        let base = format!("http://{addr}");
        assert!(matches!(
            check_playlist(&format!("{base}/complete"), &header).await,
            PlaylistCheck::Complete
        ));
        assert!(matches!(
            check_playlist(&format!("{base}/truncated"), &header).await,
            PlaylistCheck::Incomplete
        ));
        assert!(matches!(
            check_playlist(&format!("{base}/gone"), &header).await,
            PlaylistCheck::Incomplete
        ));
        assert!(matches!(
            check_playlist(&format!("{base}/denied"), &header).await,
            PlaylistCheck::Unknown
        ));
        server.abort();
    }

    #[tokio::test]
    #[ignore]
    async fn live_play_relay_or_fallback() {
        let d = detail("fjin-172").await.expect("missav detail fjin-172");
        let eps = d["episodes"].as_array().cloned().unwrap_or_default();
        assert!(!eps.is_empty(), "missav detail 无分集");
        let vid = eps[0]["video_id"].as_str().unwrap_or("").to_string();
        let r = play(&vid).await.expect("missav play");
        let url = r["url"].as_str().unwrap_or("");
        eprintln!("LIVE missav play {vid} -> {url}");
        assert!(!url.is_empty(), "取流回空地址");
        assert!(r["header"].is_object(), "取流无播放头");
        // 缺片兜底：@auto 的 resolve 清单在 surrit 上 404（死链），
        // 应回退到原生流；@720 同理。relay 若恢复，回中继真 m3u8
        // 也算过；但绝不能是第 3 步 hls/go 兜底（那是没拿到流）。
        for id in ["fjin-172@auto", "fjin-172@720"] {
            let r = play(id).await.expect("missav play fallback");
            let url = r["url"].as_str().unwrap_or("").to_string();
            eprintln!("LIVE missav play {id} -> {url}");
            assert!(url.contains(".m3u8"), "{id} 取流不是 m3u8：{url}");
            assert!(
                url.contains("surrit.com/9b88e28b") || url.contains("ystv.top/hls/"),
                "{id} 取流既不是原生也不是中继真流：{url}"
            );
            assert!(
                !url.contains("/hls/go?"),
                "{id} 落到 hls/go 兜底，说明中继与原生都没拿到流：{url}"
            );
        }
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
