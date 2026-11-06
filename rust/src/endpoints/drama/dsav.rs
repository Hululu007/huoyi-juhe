//! DSAV影视：加密网关直取。
//!
//! 来源 jar 类 `ZakaDsavAmns`。API host 每次进程随机 6 位种子
//! （`api{seed}.230110.xyz` 等），三个域名逐个试、通的记住
//! （2026-11-05 实测：`230110` 通、`230220`/`230330` 本机出
//! 口超时，单随机选会 2/3 撞死）；请求体 JSON 经 AES-128-CBC
//! 加密（key `OPQT123412FRANME`，IV `MRDCQP12QPM13412`），
//! 外层 `{"sign": md5Hex(base64(明文) + nonce + timestamp + 盐),
//! "nonce": uuid, "timestamp": 秒, "data": 密文}`；响应同样
//! 解密。`/config` 之外且 `http_sign_flag` 为真时另加 RFC 9421
//! 风格的 Content-Digest / Signature 头。
//!
//! 取流缺口：Java 的播放走应用内本地代理（`DsavProxy`），把
//! MPD 解析成各清晰度 Track、分片地址签名后改写成带签名 MPD
//! 或 HLS master；Rust 核心 `play()` 只能回 URL 字符串且本次
//! 不加新路由，无法承载该代理改写——`play()` 回原始
//! `video_url`（MPD，2 小时 14 分全长）。2026-11-05 实测：
//! 原始 MPD 可取（200），其分片未签名回 403；签名方案已验
//! 通——`sign = base64url去填充(md5字节(SIGN_SALT + path +
//! expire))`，path 含前导 `/`，expire 取 config 的
//! `video_sign_expire`（1798732800），签名后分片 206 + fMP4
//! 魔数（`stypmsdh`/`ftypiso5`）。后续做代理改写端点时按此
//! 方案实现。

use base64::Engine as _;
use md5::{Digest, Md5};
use once_cell::sync::Lazy;
use rand::Rng;
use serde_json::{json, Value};
use sha2::Sha256;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const WEB: &str = "https://dsav26.com";
const API_HOSTS: &[&str] = &[
    "https://api.230110.xyz/v1",
    "https://api.230220.xyz/v1",
    "https://api.230330.xyz/v1",
];
const LANG: &str = "zh-tw";
const UA: &str = "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const AES_KEY: &[u8] = b"OPQT123412FRANME";
const AES_IV: &[u8] = b"MRDCQP12QPM13412";
const SIGN_SALT: &str = "AjPuom638LmWfWyeM5YueKuJ9PuWLdRn";
const PAGE_SIZE: i64 = 24;

static SEED: Lazy<String> = Lazy::new(|| {
    let mut rng = rand::thread_rng();
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    (0..6)
        .map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char)
        .collect()
});
static WORKING_HOST: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

fn api_hosts() -> Vec<String> {
    API_HOSTS
        .iter()
        .map(|h| h.replacen("api.", &format!("api{}.", *SEED), 1))
        .collect()
}
static CONFIG: Lazy<Mutex<Option<Value>>> = Lazy::new(|| Mutex::new(None));

fn md5_hex(data: &[u8]) -> String {
    let mut h = Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

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

fn b64_encode(data: &[u8]) -> String {
    let s = base64::engine::general_purpose::STANDARD.encode(data);
    let s = s.replace('-', "+").replace('_', "/");
    let rem = s.len() % 4;
    if rem == 0 {
        s
    } else {
        format!("{}{}", s, "=".repeat(4 - rem))
    }
}

/// 请求加密：JSON → AES-128-CBC → base64（`-`→`+`、`_`→`/`、补 `=`）。
fn encrypt_body(plain: &[u8]) -> String {
    let padded = crate::crypto::pkcs7_pad(plain, 16);
    let cipher = crate::crypto::aes_cbc_encrypt(&padded, AES_KEY, AES_IV);
    b64_encode(&cipher)
}

fn decrypt_body(b64: &str) -> Option<String> {
    let fixed = b64.replace('-', "+").replace('_', "/");
    let raw = base64::engine::general_purpose::STANDARD
        .decode(fixed.as_bytes())
        .ok()?;
    if raw.len() % 16 != 0 {
        return None;
    }
    let plain = crate::crypto::aes_cbc_decrypt(&raw, AES_KEY, AES_IV);
    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
    String::from_utf8(unpadded.to_vec()).ok()
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    use sha2::Digest as _;
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

fn config() -> Pin<Box<dyn Future<Output = ApiResult<Value>> + Send + 'static>> {
    Box::pin(async move {
        {
            let guard = CONFIG.lock().unwrap();
            if let Some(c) = guard.as_ref() {
                return Ok(c.clone());
            }
        }
        let v = api("/config", json!({})).await?;
        let mut guard = CONFIG.lock().unwrap();
        *guard = Some(v.clone());
        Ok(v)
    })
}

/// 加密 POST；返回解密后的明文 JSON（`code==200` 的 `data` 字段，
/// 或整个对象）。
async fn api(route: &str, params: Value) -> ApiResult<Value> {
    let mut body_obj = json!({"lang": LANG, "route": route});
    if let Value::Object(map) = params {
        for (k, v) in map {
            body_obj[k] = v;
        }
    }
    let plain = body_obj.to_string();
    let data = encrypt_body(plain.as_bytes());
    let nonce = new_uuid();
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        .to_string();
    let sign_input = format!(
        "{}{}{}{}",
        base64::engine::general_purpose::STANDARD.encode(plain.as_bytes()),
        nonce,
        timestamp,
        SIGN_SALT
    );
    let sign = md5_hex(sign_input.as_bytes());
    let outer = json!({
        "sign": sign,
        "nonce": nonce,
        "timestamp": timestamp,
        "data": data,
    });
    let outer_str = outer.to_string();
    let mut candidates = api_hosts();
    if let Some(w) = WORKING_HOST.lock().unwrap().clone() {
        candidates.retain(|h| h != &w);
        candidates.insert(0, w);
    }
    let mut last_err = ApiError::Internal("DSAV影视无可用接口域名".into());
    for host in candidates {
        match api_once(&host, route, &outer_str, &timestamp).await {
            Ok(v) => {
                *WORKING_HOST.lock().unwrap() = Some(host);
                return Ok(v);
            }
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

async fn api_once(host: &str, route: &str, outer_str: &str, timestamp: &str) -> ApiResult<Value> {
    let mut req = client()?
        .post(host)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("Referer", format!("{WEB}/"))
        .header("Accept-Language", "en-US");
    if route != "/config" {
        if let Ok(cfg) = config().await {
            let flag = get(&cfg, "http_sign_flag")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let sign_id = text_of(&cfg, &["http_sign_id"]);
            let sign_key = text_of(&cfg, &["http_sign_key"]);
            if flag && !sign_id.is_empty() && !sign_key.is_empty() {
                let digest = base64::engine::general_purpose::STANDARD
                    .encode(Sha256::digest(outer_str.as_bytes()));
                let digest_hdr = format!("sha-256=:{digest}:");
                let params_str = format!(
                    "(\"@method\" \"@target-uri\" \"content-digest\" \"@created\");created={timestamp};keyid=\"{sign_id}\";alg=\"hmac-sha256\""
                );
                let sig_base = format!(
                    "\"@method\": POST\n\"@target-uri\": {route}\ncontent-digest: {digest_hdr}\n\"@created\": {timestamp}\n\"@signature-params\": {params_str}"
                );
                let sig = base64::engine::general_purpose::STANDARD
                    .encode(hmac_sha256(sign_key.as_bytes(), sig_base.as_bytes()));
                req = req
                    .header("Content-Digest", digest_hdr)
                    .header("Signature-Input", format!("v1={params_str}"))
                    .header("Signature", format!("v1=:{sig}:"));
            }
        }
    }
    let resp = req
        .body(outer_str.to_string())
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("DSAV影视请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    let code = get(&body, "code").and_then(|v| v.as_i64()).unwrap_or(-1);
    if code != 200 {
        return Err(ApiError::Internal(format!("DSAV影视接口 code {code}")));
    }
    let data = get(&body, "data").cloned().unwrap_or(Value::Null);
    let cipher = data.as_str().unwrap_or("");
    if cipher.is_empty() {
        return Ok(body);
    }
    let Some(plain) = decrypt_body(cipher) else {
        return Err(ApiError::Internal("DSAV影视响应解密失败".into()));
    };
    let plain_json: Value = serde_json::from_str(&plain)?;
    Ok(plain_json)
}

fn fmt_count(n: i64) -> String {
    if n >= 10000 {
        format!("{:.1}万", n as f64 / 10000.0)
    } else {
        n.to_string()
    }
}

fn cards(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let rows: Vec<&Value> = match data {
        Value::Array(a) => a.iter().collect(),
        _ => match get(data, "list").and_then(arr_of) {
            Some(a) => a.iter().collect(),
            None => Vec::new(),
        },
    };
    for row in rows {
        let id = text_of(row, &["video_id"]);
        if id.is_empty() {
            continue;
        }
        let mut title = text_of(row, &["video_title"]);
        if title.is_empty() {
            title = id.clone();
        }
        let cover = text_of(row, &["video_cover"]);
        let duration = text_of(row, &["video_duration"]);
        let hits = get(row, "video_hits").and_then(|v| v.as_i64()).unwrap_or(0);
        let level = get(row, "video_level")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let mut remark = String::new();
        if !duration.is_empty() {
            remark.push_str(&duration);
        }
        if hits > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("{}播放", fmt_count(hits)));
        }
        if level > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("HD{level}"));
        }
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

async fn search_videos(params: Value) -> ApiResult<Value> {
    let data = api("/videos/search", params).await?;
    Ok(json!({"items": cards(&data)}))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let cfg = config().await?;
    let mut list = vec![
        category_json("hot", "热门推荐"),
        category_json("fresh", "最新上架"),
    ];
    if let Some(types) = get(&cfg, "video_type").and_then(arr_of) {
        for t in types {
            let id = get(t, "type_id").and_then(|v| v.as_i64()).unwrap_or(0);
            let name = text_of(t, &["type_name"]);
            if id > 0 && !name.is_empty() {
                list.push(category_json(&format!("type:{id}"), &name));
            }
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let offset = (page - 1) * PAGE_SIZE;
    let params = if category_id == "hot" || category_id == "fresh" || category_id.is_empty() {
        json!({"search_type": "video_hot_search", "offset": offset, "limit": PAGE_SIZE})
    } else if let Some(id) = category_id.strip_prefix("type:") {
        let n: i64 = id.parse().unwrap_or(0);
        json!({"search_type": "video_type_search", "type_id": n, "offset": offset, "limit": PAGE_SIZE})
    } else {
        json!({"search_type": "video_hot_search", "offset": offset, "limit": PAGE_SIZE})
    };
    search_videos(params).await
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let data = api(
        "/videos/search",
        json!({"search_type": "video_detail_filter_id", "video_id": series_id}),
    )
    .await?;
    let rows: Vec<&Value> = match &data {
        Value::Array(a) => a.iter().collect(),
        _ => match get(&data, "list").and_then(arr_of) {
            Some(a) => a.iter().collect(),
            None => Vec::new(),
        },
    };
    let Some(row) = rows.first() else {
        return Err(ApiError::Internal("DSAV影视详情为空".into()));
    };
    let title = text_of(row, &["video_title"]);
    let cover = text_of(row, &["video_cover"]);
    let url = text_of(row, &["video_url"]);
    let tag = text_of(row, &["video_tag"]);
    let duration = text_of(row, &["video_duration"]);
    let hits = get(row, "video_hits").and_then(|v| v.as_i64()).unwrap_or(0);
    let level = get(row, "video_level")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let thumb = text_of(row, &["video_thumbnail"]);
    let mut synopsis = String::new();
    if !tag.is_empty() {
        synopsis.push_str(&format!("标签：{tag}\n"));
    }
    if !duration.is_empty() {
        synopsis.push_str(&format!("时长：{duration}\n"));
    }
    if hits > 0 {
        synopsis.push_str(&format!("播放：{}次\n", fmt_count(hits)));
    }
    if level > 0 {
        synopsis.push_str(&format!("清晰度：HD{level}\n"));
    }
    synopsis.push_str("来源：DSAV影视");
    if url.is_empty() {
        return Err(ApiError::Internal("DSAV影视详情未取到播放地址".into()));
    }
    let payload = base64::engine::general_purpose::STANDARD
        .encode(json!({"i": series_id, "u": url}).to_string());
    let _ = thumb;
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { format!("DSAV影视 {series_id}") } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"tag": tag},
        "episodes": [
            episode_json(&format!("dsav:{payload}"), "DSAV·DASH", series_id),
            episode_json(&format!("dsav:{payload}"), "DSAV·HSL", series_id),
        ],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    search_videos(json!({
        "search_type": "video_wd_search",
        "q": query,
        "offset": 0,
        "limit": PAGE_SIZE,
    }))
    .await
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let payload = video_id.strip_prefix("dsav:").unwrap_or(video_id);
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(payload.as_bytes())
        .unwrap_or_default();
    let text = String::from_utf8_lossy(&decoded).to_string();
    let parsed: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    let url = text_of(&parsed, &["u"]);
    if url.is_empty() {
        return Err(ApiError::Internal("DSAV影视没有播放地址".into()));
    }
    // 缺口：原始 video_url 是 MPD 地址，Java 经本地代理改写成带签
    // 名 MPD/HLS；此处只回原始地址，待实测后定是否需代理端点。
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let plain = b"{\"lang\":\"zh-tw\",\"route\":\"/config\"}";
        let enc = encrypt_body(plain);
        let dec = decrypt_body(&enc).expect("decrypt");
        assert_eq!(dec, String::from_utf8_lossy(plain));
    }

    #[test]
    fn md5_hex_known() {
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn b64_encode_pads() {
        // 3 字节密文不需补 `=`；1 字节补 `==`。
        assert_eq!(b64_encode(&[0x61, 0x62, 0x63]), "YWJj");
        assert_eq!(b64_encode(&[0x61]), "YQ==");
    }
}
