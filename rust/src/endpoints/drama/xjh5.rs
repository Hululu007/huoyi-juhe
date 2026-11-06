//! 香蕉视频 H5：与土豆视频同后端（videoh5.86027a.xyz），客户端
//! 形态不同：表单 POST（application/x-www-form-urlencoded），
//! 注册多带 source=h5、dun_token、agent=bf111、pid、
//! mobile_name=iPhone、mobile_version=17.0、app_version=1.0；
//! 封面取不到 videoHost 时回落 IMG_HOST；category_id 与详情
//! id 均按字符串传；标题做 HTML 反转义。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const SITE: &str = "https://videoh5.86027a.xyz";
const IMG_HOST: &str = "https://image.86027a.xyz";
const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const PAGE_SIZE: i64 = 20;
const TOKEN_TTL: Duration = Duration::from_secs(6 * 3600);
const VHOST_TTL: Duration = Duration::from_secs(3600);

static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);
static VHOST: Mutex<Option<(String, Instant)>> = Mutex::new(None);
static PU_CACHE: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

fn machine_code() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..32)
        .map(|_| format!("{:x}", rng.gen_range(0..16)))
        .collect()
}

fn now_secs() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default()
}

/// JSON 对象转表单串（与 Java 的 qs 一致：逐键 URLEncoder 编码）。
fn qs(v: &Value) -> String {
    let mut out = String::new();
    if let Some(m) = v.as_object() {
        for (k, val) in m {
            if !out.is_empty() {
                out.push('&');
            }
            out.push_str(&url::form_urlencoded::byte_serialize(k.as_bytes()).collect::<String>());
            out.push('=');
            out.push_str(
                &url::form_urlencoded::byte_serialize(super::str_of(val).as_bytes())
                    .collect::<String>(),
            );
        }
    }
    out
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn headers(token: &str) -> Vec<(&'static str, String)> {
    vec![
        (
            "Content-Type",
            "application/x-www-form-urlencoded".to_string(),
        ),
        ("Accept", "application/json, text/plain, */*".to_string()),
        ("token", token.to_string()),
        ("cid", "1".to_string()),
        ("timestamp", now_secs()),
        ("Accept-Language", "tw".to_string()),
        ("User-Agent", UA.to_string()),
        ("Origin", SITE.to_string()),
        ("Referer", format!("{SITE}/")),
    ]
}

async fn post_form(url: &str, body: &str, token: &str) -> ApiResult<String> {
    let mut req = client()?.post(url).body(body.to_string());
    for (k, v) in headers(token) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("香蕉视频H5 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn ensure_token() -> ApiResult<String> {
    if let Ok(guard) = TOKEN.lock() {
        if let Some((t, at)) = guard.as_ref() {
            if Instant::now() < *at + TOKEN_TTL && !t.is_empty() {
                return Ok(t.clone());
            }
        }
    }
    let body = qs(&json!({
        "source": "h5",
        "dun_token": "",
        "agent": "bf111",
        "pid": "",
        "machine_code": machine_code(),
        "mobile_name": "iPhone",
        "mobile_version": "17.0",
        "app_version": "1.0",
    }));
    let text = post_form(&format!("{SITE}/api/user/dunGustRegister"), &body, "").await?;
    let v: Value = serde_json::from_str(&text)?;
    let token = text_of(get(&v, "data").unwrap_or(&v), &["token"]);
    if token.len() > 8 {
        if let Ok(mut guard) = TOKEN.lock() {
            *guard = Some((token.clone(), Instant::now()));
        }
        return Ok(token);
    }
    Err(ApiError::Internal("香蕉视频H5 注册未返回 token".into()))
}

async fn api_post(path: &str, body: &Value) -> ApiResult<Value> {
    let token = ensure_token().await?;
    let text = post_form(&format!("{SITE}/api/{path}"), &qs(body), &token).await?;
    let v: Value = serde_json::from_str(&text)?;
    Ok(v)
}

fn data_arr(body: &Value, key: Option<&str>) -> Vec<Value> {
    let Some(data) = get(body, "data") else {
        return Vec::new();
    };
    if let Some(arr) = arr_of(data) {
        return arr.clone();
    }
    if let Some(k) = key {
        if let Some(arr) = get(data, k).and_then(arr_of) {
            return arr.clone();
        }
    }
    if let Some(arr) = get(data, "l").and_then(arr_of) {
        if !arr.is_empty() {
            return arr.clone();
        }
    }
    get(data, "list")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default()
}

fn dur(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    format!("{:02}:{:02}", secs / 60, secs % 60)
}

async fn video_host() -> String {
    if let Ok(guard) = VHOST.lock() {
        if let Some((h, at)) = guard.as_ref() {
            if Instant::now() < *at + VHOST_TTL && h.len() > 8 {
                return h.clone();
            }
        }
    }
    let mut host = String::new();
    if let Ok(body) = api_post("user/getVideoUrl", &json!({})).await {
        let v = text_of(get(&body, "data").unwrap_or(&body), &["video_url"]);
        if v.len() > 8 {
            host = v.trim_end_matches('/').to_string();
            if let Ok(mut guard) = VHOST.lock() {
                *guard = Some((host.clone(), Instant::now()));
            }
        }
    }
    host
}

async fn cover(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    if path.starts_with("http") {
        return path.to_string();
    }
    let rel = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let host = video_host().await;
    if host.len() > 8 {
        return format!("{host}{rel}");
    }
    format!("{IMG_HOST}{rel}")
}

fn to_vod(e: &Value, cover: &str) -> Option<Value> {
    let id = text_of(e, &["id"]);
    let title = unescape(&text_of(e, &["t", "title"]));
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let actress = text_of(e, &["a", "actress"]);
    let tags = text_of(e, &["tl", "tag_list"]);
    let tm = int_of(e, &["tm"]);
    let vip = int_of(e, &["iv"]);
    let paid = int_of(e, &["ib"]);
    let mut remark = String::new();
    let d = dur(tm);
    if !d.is_empty() {
        remark.push_str(&d);
    }
    if !actress.is_empty() {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str(&actress);
    }
    if !tags.is_empty() {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str(&tags);
    }
    if vip == 1 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("VIP");
    } else if paid == 1 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("付费");
    }
    Some(item_json(&id, &title, cover, &remark))
}

async fn cards(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let c = cover(&text_of(e, &["c", "cover"])).await;
        if let Some(v) = to_vod(e, &c) {
            items.push(v);
        }
    }
    items
}

fn pu_get(id: &str) -> Option<String> {
    if let Ok(guard) = PU_CACHE.lock() {
        for (k, v) in guard.iter() {
            if k == id {
                return Some(v.clone());
            }
        }
    }
    None
}

fn pu_put(id: &str, pu: &str) {
    if let Ok(mut guard) = PU_CACHE.lock() {
        guard.retain(|(k, _)| k != id);
        guard.push((id.to_string(), pu.to_string()));
    }
}

async fn detail_data(id: &str) -> ApiResult<Value> {
    let resp = api_post("video/v2/detail", &json!({"id": id})).await?;
    Ok(match get(&resp, "data") {
        Some(d) => d.clone(),
        None => resp,
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let body = api_post("video/category", &json!({})).await?;
    let rows = data_arr(&body, None);
    let mut list = Vec::new();
    for e in &rows {
        let id = text_of(e, &["id"]);
        let name = text_of(e, &["name"]);
        if !id.is_empty() && !name.is_empty() {
            list.push(category_json(&id, &name));
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let body = json!({"page": page, "page_size": PAGE_SIZE, "category_id": category_id});
    let resp = api_post("video/v2/list", &body).await?;
    let rows = data_arr(&resp, Some("l"));
    let items = cards(&rows).await;
    let has_more = rows.len() as i64 >= PAGE_SIZE;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let data = detail_data(series_id).await?;
    let title = unescape(&text_of(&data, &["t", "title"]));
    if title.is_empty() {
        return Err(ApiError::Internal("香蕉视频H5 未返回影片资料".into()));
    }
    let c = cover(&text_of(&data, &["c", "cover"])).await;
    let pu = text_of(&data, &["pu", "play_url"]);
    let tags = text_of(&data, &["tl", "tag_list"]);
    let tm = int_of(&data, &["tm"]);
    let vip = int_of(&data, &["iv"]);
    let paid = int_of(&data, &["ib"]);
    if !pu.is_empty() {
        pu_put(series_id, &pu);
    }
    let mut remark = dur(tm);
    if vip == 1 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("VIP");
    } else if paid == 1 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("付费");
    }
    let play_url = if pu.is_empty() {
        "暂无可播地址$".to_string()
    } else {
        let host = video_host().await;
        format!("{}$", title.replace('$', " ")) + &format!("{host}{pu}")
    };
    let mut extra = serde_json::Map::new();
    if !tags.is_empty() {
        extra.insert("tag".to_string(), json!(tags));
    }
    if !remark.is_empty() {
        extra.insert("remark".to_string(), json!(remark));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": c,
        "synopsis": title.clone() + &if tags.is_empty() { String::new() } else { format!("\n分类：{tags}") },
        "extra": extra,
        "episodes": [episode_json(&play_url, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{SITE}/")},
        }));
    }
    let id = video_id.split('$').last().unwrap_or(video_id);
    if id.starts_with("http") {
        return Ok(json!({
            "url": id,
            "header": {"User-Agent": UA, "Referer": format!("{SITE}/")},
        }));
    }
    let mut pu = pu_get(id);
    if pu.is_none() {
        if let Ok(data) = detail_data(id).await {
            let p = text_of(&data, &["pu", "play_url"]);
            if !p.is_empty() {
                pu_put(id, &p);
                pu = Some(p);
            }
        }
    }
    let url = match pu {
        Some(p) if !p.is_empty() => format!("{}{}", video_host().await, p),
        _ => String::new(),
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{SITE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let body = json!({"page": 1, "page_size": PAGE_SIZE, "keyword": query});
    let resp = api_post("video/v2/list", &body).await?;
    let rows = data_arr(&resp, Some("l"));
    let items = cards(&rows).await;
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qs_encodes() {
        let v = json!({"page": 1, "keyword": "a b"});
        let s = qs(&v);
        assert!(
            s.contains("keyword=a+b") || s.contains("keyword=a%20b"),
            "{s}"
        );
        assert!(s.contains("page=1"), "{s}");
    }

    #[test]
    fn unescape_entities() {
        assert_eq!(unescape("A &amp; B &#039;C&#039;"), "A & B 'C'");
    }
}
