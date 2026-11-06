//! 糖心Fans：设备登录 + AES 协议。
//!
//! 来源 jar 类 `ZakaTxfansAmns`（`https://txfansmm.com`）。
//! 每次请求：信封 `{"data":params,"token":token,"deviceId":deviceId}`
//! 先 gzip 再 AES-256-CBC 加密（密钥 = 以 `e04d703b2a73c9bf` 为
//! key、对 requestId 的 UUID 字节做 HMAC-SHA256），`IV‖密文`
//! base64 后 POST，响应同样解密。token 由 `/api/login/device`
//! 的设备登录取得并缓存。

use base64::Engine as _;
use once_cell::sync::Lazy;
use rand::Rng;
use serde_json::{json, Value};
use std::future::Future;
use std::pin::Pin;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://txfansmm.com";
const KEY_STR: &str = "e04d703b2a73c9bf";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("hot", "热门推荐"),
    ("new", "最新发布"),
    ("rand", "随机推荐"),
    ("video", "视频专区"),
    ("free", "免费内容"),
    ("buy", "付费内容"),
    ("sub", "订阅内容"),
    ("creator", "创作者榜"),
];

static TOKEN: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static DEVICE_ID: Lazy<String> = Lazy::new(|| {
    let uuid = new_uuid();
    let compact: String = uuid.chars().filter(|c| *c != '-').collect();
    format!("ZK{}", &compact[..18].to_uppercase())
});
static VID_CACHE: Lazy<Mutex<HashMap<String, String>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn new_uuid() -> String {
    let mut rng = rand::thread_rng();
    let mut b = [0u8; 16];
    rng.fill(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
    )
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        let h = Sha256::digest(key);
        k[..32].copy_from_slice(&h);
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(msg);
    let inner_hash = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_hash);
    outer.finalize().into()
}

/// HMAC-SHA256（key=`KEY_STR`，消息=去掉 `-` 后 hex 解码的 UUID 字节）。
fn hmac_key(request_id: &str) -> Vec<u8> {
    let compact: String = request_id.chars().filter(|c| *c != '-').collect();
    let msg = hex::decode(&compact).unwrap_or_default();
    hmac_sha256(KEY_STR.as_bytes(), &msg).to_vec()
}

fn encrypt(plain: &str, request_id: &str) -> String {
    let key = hmac_key(request_id);
    let gz = crate::crypto::gzip(plain.as_bytes());
    let padded = crate::crypto::pkcs7_pad(&gz, 16);
    let mut rng = rand::thread_rng();
    let mut iv = [0u8; 16];
    rng.fill(&mut iv);
    let cipher = crate::crypto::aes_cbc_encrypt(&padded, &key, &iv);
    let mut out = iv.to_vec();
    out.extend_from_slice(&cipher);
    base64::engine::general_purpose::STANDARD.encode(out)
}

fn decrypt(b64: &str, request_id: &str) -> Option<Value> {
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64.trim().as_bytes())
        .ok()?;
    if raw.len() < 32 || raw.len() % 16 != 0 {
        return None;
    }
    let key = hmac_key(request_id);
    let plain = crate::crypto::aes_cbc_decrypt(&raw[16..], &key, &raw[..16]);
    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
    let gz = crate::crypto::gunzip(unpadded)?;
    let text = String::from_utf8_lossy(&gz).to_string();
    serde_json::from_str::<Value>(&text).ok()
}

fn token() -> Option<String> {
    TOKEN.lock().unwrap().clone()
}

/// 加密 POST；`retry=true` 时状态非 `y` 先登录再重试一次。
async fn call(path: &str, params: Value, retry: bool) -> ApiResult<Value> {
    let request_id = new_uuid();
    let envelope = json!({
        "data": params,
        "token": token().unwrap_or_default(),
        "deviceId": DEVICE_ID.as_str(),
    });
    let body = encrypt(&envelope.to_string(), &request_id);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
        .to_string();
    let time = millis.chars().take(11).collect::<String>();
    let resp = client()?
        .post(format!("{BASE}{path}"))
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Content-Type", "text/plain")
        .header("devicetype", "web")
        .header("version", "1.0.0")
        .header("requestid", &request_id)
        .header("time", time)
        .body(body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("糖心Fans 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let Some(dec) = decrypt(&text, &request_id) else {
        return Err(ApiError::Internal("糖心Fans 响应解密失败".into()));
    };
    let ok = dec.get("status").and_then(|v| v.as_str()).unwrap_or("") == "y";
    if !ok && retry {
        ensure_login().await?;
        return call_no_retry(path, params).await;
    }
    Ok(dec)
}

fn call_no_retry(
    path: &str,
    params: Value,
) -> Pin<Box<dyn Future<Output = ApiResult<Value>> + Send + '_>> {
    Box::pin(call(path, params, false))
}

async fn ensure_login() -> ApiResult<()> {
    for path in ["/api/login/device", "/api/device"] {
        let resp = call_no_retry(path, json!({})).await;
        if let Ok(dec) = resp {
            let data = dec.get("data").cloned().unwrap_or(Value::Null);
            let tk = data.get("token").and_then(|v| v.as_str()).unwrap_or("");
            let uid = data.get("user_id").and_then(|v| v.as_str()).unwrap_or("");
            if !tk.is_empty() {
                let mut guard = TOKEN.lock().unwrap();
                *guard = Some(format!("{tk}_{uid}"));
                return Ok(());
            }
        }
    }
    Err(ApiError::Internal("糖心Fans 设备登录失败".into()))
}

fn strip_tags(s: &str) -> String {
    let tag = regex::Regex::new(r"<[^>]*>").unwrap();
    let collapsed = regex::Regex::new(r"\s+").unwrap();
    collapsed
        .replace_all(tag.replace_all(s, " ").as_ref(), " ")
        .trim()
        .to_string()
}

fn abs_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{BASE}{u}")
    } else {
        u.to_string()
    }
}

fn first_m3u8(item: &Value) -> String {
    if let Some(videos) = get(item, "videos").and_then(arr_of) {
        for v in videos {
            let url = text_of(v, &["m3u8_url"]);
            if !url.is_empty() {
                return abs_url(&url);
            }
        }
    }
    String::new()
}

fn cache_vid(id: &str, url: &str) {
    if url.is_empty() {
        return;
    }
    let mut guard = VID_CACHE.lock().unwrap();
    if guard.len() > 3000 {
        guard.clear();
    }
    guard.insert(id.to_string(), url.to_string());
}

/// 列表查询：`extra` 为分类附加字段。
async fn search_list(
    order: &str,
    page: i64,
    extra: &[(&str, Value)],
    keyword: Option<&str>,
) -> ApiResult<Vec<Value>> {
    let mut body = json!({
        "order": order,
        "page": page,
        "page_size": 24,
    });
    for (k, v) in extra {
        body[k] = v.clone();
    }
    if let Some(kw) = keyword {
        body["keyword"] = json!(kw);
    }
    let resp = call("/api/search/post", body, true).await?;
    let mut items = Vec::new();
    let Some(rows) = get(&resp, "data")
        .and_then(|d| get(d, "data"))
        .and_then(arr_of)
    else {
        return Ok(items);
    };
    for row in rows {
        if text_of(row, &["type"]) == "ad" {
            continue;
        }
        let id = text_of(row, &["id"]);
        if id.is_empty() {
            continue;
        }
        let title = text_of(row, &["title"]);
        let cover = abs_url(&text_of(row, &["cover"]));
        let actor = text_of(row, &["actor", "nickname"]);
        let permission = text_of(row, &["permission"]);
        let price = get(row, "price").and_then(|v| v.as_i64()).unwrap_or(0);
        let pay = match permission.as_str() {
            "public" => "免费".to_string(),
            "buy" => format!("💰{price}糖豆"),
            "subscribe" => "🔒订阅".to_string(),
            _ => "💰付费".to_string(),
        };
        let remark = if actor.is_empty() {
            pay
        } else {
            format!("{actor} · {pay}")
        };
        let created = text_of(row, &["created_at"]);
        let year = created.chars().take(10).collect::<String>();
        let m3u8 = first_m3u8(row);
        cache_vid(&id, &m3u8);
        let mut item = item_json(&id, &title, &cover, &remark);
        if !year.is_empty() {
            item["year"] = json!(year);
        }
        items.push(item);
    }
    Ok(items)
}

fn cat_params(category_id: &str) -> (&'static str, Vec<(&'static str, Value)>) {
    match category_id {
        "new" => ("new", vec![]),
        "rand" => ("rand", vec![]),
        "video" => ("new", vec![("has_videos", json!("y"))]),
        "free" => ("hot", vec![("permission", json!("public"))]),
        "buy" => ("new", vec![("permission", json!("buy"))]),
        "sub" => ("new", vec![("permission", json!("subscribe"))]),
        "creator" => ("hot", vec![("position", json!("normal"))]),
        _ => ("hot", vec![("hot", json!(1))]),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let (order, extra) = cat_params(category_id);
    let items = search_list(order, page, &extra, None).await?;
    Ok(json!({"items": items, "has_more": true}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let resp = call("/api/post/detail", json!({"id": series_id}), true).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let data = get(&data, "data").cloned().unwrap_or(data);
    let title = text_of(&data, &["title"]);
    let cover = abs_url(&text_of(&data, &["cover"]));
    let content = strip_tags(&text_of(&data, &["content"]));
    let actor = text_of(&data, &["actor", "nickname"]);
    let permission = text_of(&data, &["permission"]);
    let price = get(&data, "price").and_then(|v| v.as_i64()).unwrap_or(0);
    let mut episodes = Vec::new();
    if let Some(videos) = get(&data, "videos").and_then(arr_of) {
        for (i, v) in videos.iter().enumerate() {
            let url = text_of(v, &["m3u8_url"]);
            if url.is_empty() {
                continue;
            }
            let name = text_of(v, &["name"]);
            let name = if name.is_empty() {
                format!("线路{}", i + 1)
            } else {
                name
            };
            episodes.push(episode_json(&abs_url(&url), &name, series_id));
        }
    }
    if episodes.is_empty() {
        // 按标题在热门第 1 页找同名条目取其视频。
        if !title.is_empty() {
            if let Ok(list) = search_list("hot", 1, &[("hot", json!(1))], Some(&title)).await {
                let _ = list;
            }
            // 上面 search_list 只回卡片；同名视频走 VID_CACHE。
            let cached = VID_CACHE.lock().unwrap().get(series_id).cloned();
            if let Some(url) = cached {
                episodes.push(episode_json(&url, "糖心", series_id));
            }
        }
    }
    if episodes.is_empty() {
        let tip = match permission.as_str() {
            "buy" => format!("本片需 {price} 糖豆购买（服务端未下发播放链）"),
            "subscribe" => "本片需订阅创作者（服务端未下发播放链）".to_string(),
            _ => "该条目服务端未下发播放链".to_string(),
        };
        episodes.push(episode_json(&format!("{BASE}/"), &tip, series_id));
    }
    let mut synopsis = content;
    if !actor.is_empty() {
        synopsis.push_str(&format!("\n作者：{actor}"));
    }
    synopsis.push_str("\n来源：糖心Fans");
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { format!("糖心Fans {series_id}") } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"actor": actor},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let items = search_list("hot", 1, &[("hot", json!(1))], Some(query)).await?;
    if !items.is_empty() {
        return Ok(json!({"items": items}));
    }
    let resp = call(
        "/api/search/post",
        json!({"keyword": query, "page": 1, "page_size": 24}),
        true,
    )
    .await?;
    let mut out = Vec::new();
    if let Some(rows) = get(&resp, "data")
        .and_then(|d| get(d, "data"))
        .and_then(arr_of)
    {
        for row in rows {
            let id = text_of(row, &["id"]);
            if id.is_empty() {
                continue;
            }
            let title = text_of(row, &["title"]);
            let cover = abs_url(&text_of(row, &["cover"]));
            out.push(item_json(&id, &title, &cover, ""));
        }
    }
    Ok(json!({"items": out}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with('/') {
        format!("{BASE}{video_id}")
    } else {
        video_id.to_string()
    };
    if url.is_empty() {
        return Err(ApiError::Internal("糖心Fans 没有播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_key_is_32_bytes() {
        let key = hmac_key("550e8400-e29b-41d4-a716-446655440000");
        assert_eq!(key.len(), 32);
        // 同一 requestId 结果稳定。
        assert_eq!(key, hmac_key("550e8400-e29b-41d4-a716-446655440000"));
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let rid = new_uuid();
        let plain = r#"{"data":{"order":"hot"},"token":"","deviceId":"ZKTEST"}"#;
        let enc = encrypt(plain, &rid);
        let dec = decrypt(&enc, &rid).expect("decrypt");
        assert_eq!(dec["data"]["order"], "hot");
    }

    #[test]
    fn cat_params_hot() {
        let (order, extra) = cat_params("hot");
        assert_eq!(order, "hot");
        assert_eq!(extra[0].0, "hot");
    }
}
