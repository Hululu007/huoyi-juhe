//! 黄果短剧┃视频：动态发现基址 + 游客登录 + 签名取流。
//!
//! 来源 jar 类 `ZakaHgdjVAmns`。无固定基址：`discover()` 先拉两个
//! `crks.json`（cloudfront 与腾讯云 COS），逐个探
//! `GET <候选>/api/sys/live` 要求 `code == 200`；无可用时在
//! `LINE_DOMAINS` 下拼 1–7 位随机子域名再探；最后试调试地址
//! `http://crksapp.sexbar.site`。
//!
//! 登录（traveler）：`deviceId=8ff2fabf0895c3bc6a54f66b05e2b3ba` 固定；
//! `str = hex(当前秒时间戳)前 8 位 + UUID 去横线前 16 位`；
//! `i = 当前秒 % 8`；密钥 `string = str.substring(i, i+16)` 反转；
//! body `{"encStr": AES/ECB/PKCS5Padding 加密的 {"deviceId":…,
//! "ttb": <随机 1 个字母数字>}}`，密钥为 `string`；
//! POST `<base>/api/user/traveler/<str>/login`，`code == 200` 且
//! `data` 为字符串时，用同一密钥 ECB 解密 `data` 得 `token`、`imgDomain`。
//!
//! 请求头：`Content-Type: application/json`、`Accept: application/json`、
//! `deviceId`、`appVersion: 1.5.8`、`device: Android`、
//! `systemName: Android`、`deviceBrand: google`、`deviceModel: Pixel 3`、
//! `systemVersion: 13`、`t: <毫秒时间戳>`、
//! `s: MD5(<t 的第 3–8 位子串>)` 小写 hex、`User-Agent: okhttp/4.9.0`，
//! 有 token 时加 `aut: <token>`；`code` 为 1001/1003 时重新登录后重试一次。
//!
//! 响应解包 `unwrap`：有 `encData` 且 token 长度 ≥18 时，用 token[2..18]
//!（Java `substring(2, 18)`，16 字节）作 key 与 IV，AES/CBC 解密 Base64 后的 `encData`；
//! 否则取 `data` 对象。
//!
//! 分类 GET `/api/video/classifyList`（动态分类，须先登录+发现基址）。
//! 列表 GET `/api/video/getVideoList?pageSize=30&page=<页>&classifyId=<编码>&sortType=1`，
//! 封面取 `authCoverImg[0]` → `authVerticalImg[0]` → `coverImg[0]` →
//! `verticalImg[0]`，相对路径拼 `domain`（或登录返回的 `imgDomain`），
//! 再包一层 `https://hgimg.ystv.top/?u=<编码>`；备注为 `短剧`
//! （`shortDrama` 真）或 `tagTitles[0]`。详情 GET
//! `/api/video/getVideoById?videoId=<id>`；有 `serialVideos[]` 时分集
//! 为 `标题$<videoId>`（标题空则 `第N集`），否则 `正片$<id>`。
//! 取流 GET `/api/video/can/watch?videoId=<id>` 取 `videoUrl`/`authKey`
//! （空则用详情缓存的同字段；仍空则 GET
//! `/api/m3u8/decode/by/id?videoId=<id>` 取 `videoUrl`/`path`/`url`）；
//! 再取 signKey（GET `/api/v2/m3u8/play/signKey`，缓存 1 小时）与服务
//! 器时间（GET `/api/v2/m3u8/play/time` 的 `unixMilliseconds`，换算为秒）；
//! `sign = HMAC-SHA256(UTF-8: <videoUrl><token><ts 秒><nonce UUID>)`
//! （密钥 signKey，小写 hex）；最终 URL 为
//! `<base>/api/v2/m3u8/play?path=<编码 videoUrl>&token=<编码 token>&ts=<秒>&nonce=<UUID>&sign=<hex>[&authKey=<编码>]`；
//! 无 videoUrl 或无 token 时返回空 URL。取流头只有 `User-Agent: okhttp/4.9.0`。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine as _;
use once_cell::sync::Lazy;
use rand::Rng;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const DEVICE_ID: &str = "8ff2fabf0895c3bc6a54f66b05e2b3ba";
const APP_VERSION: &str = "1.5.8";
const UA: &str = "okhttp/4.9.0";
const DEBUG_LINE: &str = "http://crksapp.sexbar.site";
const CRKS_URLS: &[&str] = &[
    "https://d15beepu2m390g.cloudfront.net/crks.json",
    "https://tc-jp-alijs-1375272368.cos.ap-tokyo.myqcloud.com/crks.json",
];
const LINE_DOMAINS: &[&str] = &["t5jrp0ov.work", "t9ds6oaj.work", "lv6gj9b1.work", "qg74b2wp.work"];
const IMG_RELAY: &str = "https://hgimg.ystv.top/?u=";

struct Session {
    base: Option<String>,
    token: String,
    img_domain: String,
    sign_key: String,
    sign_key_at: Option<Instant>,
    cats: Option<Vec<Value>>,
    detail_cache: std::collections::HashMap<String, Value>,
}

static SESSION: Lazy<Mutex<Session>> = Lazy::new(|| {
    Mutex::new(Session {
        base: None,
        token: String::new(),
        img_domain: String::new(),
        sign_key: String::new(),
        sign_key_at: None,
        cats: None,
        detail_cache: std::collections::HashMap::new(),
    })
});

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn now_sec() -> u64 {
    (now_ms() / 1000) as u64
}

fn md5_hex(data: &[u8]) -> String {
    use md5::Digest as _;
    let mut h = md5::Md5::new();
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

fn rand_alnum(n: usize) -> String {
    const CH: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut rng = rand::thread_rng();
    (0..n)
        .map(|_| CH[rng.gen_range(0..CH.len())] as char)
        .collect()
}

fn aes_ecb_crypt(data: &[u8], key: &[u8], encrypt: bool) -> Option<Vec<u8>> {
    use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit, generic_array::GenericArray};
    if key.len() != 16 || data.len() % 16 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(data.len());
    if encrypt {
        let cipher = aes::Aes128::new(GenericArray::from_slice(key));
        for chunk in data.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.encrypt_block(&mut block);
            out.extend_from_slice(&block);
        }
    } else {
        let cipher = aes::Aes128::new(GenericArray::from_slice(key));
        for chunk in data.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.decrypt_block(&mut block);
            out.extend_from_slice(&block);
        }
    }
    Some(out)
}

fn ecb_enc(plain: &str, key_str: &str) -> Option<String> {
    let padded = crate::crypto::pkcs7_pad(plain.as_bytes(), 16);
    let cipher = aes_ecb_crypt(&padded, key_str.as_bytes(), true)?;
    Some(base64::engine::general_purpose::STANDARD.encode(cipher))
}

fn ecb_dec(b64: &str, key_str: &str) -> Option<String> {
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .ok()?;
    let plain = aes_ecb_crypt(&raw, key_str.as_bytes(), false)?;
    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
    String::from_utf8(unpadded.to_vec()).ok()
}

fn hmac_sha256_hex(key: &[u8], msg: &[u8]) -> String {
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
    hex::encode(outer.finalize())
}

fn headers(token: &str) -> Vec<(String, String)> {
    let t = now_ms().to_string();
    let s = if t.len() >= 8 {
        md5_hex(&t.as_bytes()[3..8])
    } else {
        String::new()
    };
    let mut h: Vec<(String, String)> = vec![
        ("Content-Type".into(), "application/json".into()),
        ("Accept".into(), "application/json".into()),
        ("deviceId".into(), DEVICE_ID.into()),
        ("appVersion".into(), APP_VERSION.into()),
        ("device".into(), "Android".into()),
        ("systemName".into(), "Android".into()),
        ("deviceBrand".into(), "google".into()),
        ("deviceModel".into(), "Pixel 3".into()),
        ("systemVersion".into(), "13".into()),
        ("t".into(), t),
        ("s".into(), s),
        ("User-Agent".into(), UA.into()),
    ];
    if !token.is_empty() {
        h.push(("aut".into(), token.to_string()));
    }
    h
}

async fn http_json_once(method: &str, url: &str, body: Option<&str>) -> Value {
    let token = SESSION.lock().unwrap().token.clone();
    let req = if method == "POST" {
        client().map(|c| c.post(url))
    } else {
        client().map(|c| c.get(url))
    };
    let Ok(mut req) = req else {
        return Value::Object(Default::default());
    };
    for (k, v) in headers(&token) {
        req = req.header(k, v);
    }
    if let Some(b) = body {
        req = req.body(b.to_string());
    }
    let Ok(resp) = req.send().await else {
        return Value::Object(Default::default());
    };
    let Ok(text) = resp.text().await else {
        return Value::Object(Default::default());
    };
    serde_json::from_str(&text).unwrap_or(Value::Object(Default::default()))
}

async fn http_json(method: &str, url: &str, body: Option<&str>, retry: bool) -> Value {
    let v = http_json_once(method, url, body).await;
    let code = int_of(&v, &["code"]);
    if retry && (code == 1001 || code == 1003) {
        login().await;
        return http_json_once(method, url, body).await;
    }
    v
}

async fn http_get(path: &str) -> Value {
    let base = SESSION.lock().unwrap().base.clone().unwrap_or_default();
    if base.is_empty() {
        return Value::Object(Default::default());
    }
    http_json("GET", &format!("{base}{path}"), None, true).await
}

async fn probe(base: &str) -> bool {
    let token = SESSION.lock().unwrap().token.clone();
    let Ok(mut req) = client().map(|c| c.get(format!("{base}/api/sys/live"))) else {
        return false;
    };
    for (k, v) in headers(&token) {
        req = req.header(k, v);
    }
    let Ok(resp) = req.send().await else {
        return false;
    };
    let Ok(text) = resp.text().await else {
        return false;
    };
    serde_json::from_str::<Value>(&text)
        .map(|v| int_of(&v, &["code"]) == 200)
        .unwrap_or(false)
}

async fn discover() -> String {
    let mut candidates: Vec<String> = Vec::new();
    for url in CRKS_URLS {
        if let Ok(resp) = client().map(|c| c.get(*url)) {
            if let Ok(resp) = resp.send().await {
                if let Ok(text) = resp.text().await {
                    if let Ok(arr) = serde_json::from_str::<Vec<String>>(&text) {
                        candidates.extend(arr);
                    }
                }
            }
        }
    }
    for cand in candidates {
        if !cand.starts_with("http") {
            continue;
        }
        let cand = cand.trim_end_matches('/');
        if probe(cand).await {
            return cand.to_string();
        }
    }
    for domain in LINE_DOMAINS {
        let n = rand::thread_rng().gen_range(1..=7);
        let sub = rand_alnum(n);
        let cand = format!("https://{sub}.{domain}");
        if probe(&cand).await {
            return cand;
        }
    }
    if probe(DEBUG_LINE).await {
        DEBUG_LINE.to_string()
    } else {
        String::new()
    }
}

async fn login() {
    let base = SESSION.lock().unwrap().base.clone().unwrap_or_default();
    if base.is_empty() {
        return;
    }
    let sec = now_sec();
    let hex_sec = format!("{sec:x}");
    let head = if hex_sec.len() >= 8 {
        hex_sec[..8].to_string()
    } else {
        format!("{:0>8}", hex_sec)
    };
    let uuid = new_uuid().replace('-', "");
    let s = format!("{}{}", head, &uuid[..16]);
    let i = (sec % 8) as usize;
    let key: String = s[i..i + 16].chars().rev().collect();
    let ttb = rand_alnum(1);
    let inner = json!({"deviceId": DEVICE_ID, "ttb": ttb}).to_string();
    let Some(enc) = ecb_enc(&inner, &key) else {
        return;
    };
    let body = json!({"encStr": enc}).to_string();
    let resp = http_json_once("POST", &format!("{base}/api/user/traveler/{s}/login"), Some(&body)).await;
    if int_of(&resp, &["code"]) == 200 {
        if let Some(data) = get(&resp, "data").and_then(|d| d.as_str()) {
            if let Some(plain) = ecb_dec(data, &key) {
                if let Ok(v) = serde_json::from_str::<Value>(&plain) {
                    let mut sess = SESSION.lock().unwrap();
                    sess.token = text_of(&v, &["token"]);
                    sess.img_domain = text_of(&v, &["imgDomain"]);
                    sess.sign_key.clear();
                    sess.sign_key_at = None;
                }
            }
        }
    }
}

async fn ensure_session() -> ApiResult<()> {
    let base_empty = SESSION.lock().unwrap().base.clone().unwrap_or_default().is_empty();
    if base_empty {
        let base = discover().await;
        if base.is_empty() {
            return Err(ApiError::Internal("hgdjv no live line".into()));
        }
        SESSION.lock().unwrap().base = Some(base);
    }
    let token_empty = SESSION.lock().unwrap().token.is_empty();
    if token_empty {
        login().await;
    }
    Ok(())
}

/// `unwrap`：有 `encData` 且 token 长度 ≥18 时，用 token[2..18]（Java `substring(2, 18)`）
/// 作 key 与 IV，AES/CBC 解密；否则取 `data` 对象。
fn unwrap(resp: Value) -> Value {
    let enc = text_of(&resp, &["encData"]);
    let token = SESSION.lock().unwrap().token.clone();
    if !enc.is_empty() && token.len() >= 18 {
        let key = &token.as_bytes()[2..18];
        if let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(enc.as_bytes()) {
            if !raw.is_empty() && raw.len() % 16 == 0 {
                let plain = crate::crypto::aes_cbc_decrypt(&raw, key, key);
                let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
                if let Ok(v) = serde_json::from_str::<Value>(&String::from_utf8_lossy(unpadded)) {
                    return v;
                }
            }
        }
        return Value::Object(Default::default());
    }
    match get(&resp, "data") {
        Some(d) if d.is_object() => d.clone(),
        _ => Value::Object(Default::default()),
    }
}

fn cover_url(raw: &str, domain: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let mut full = raw.to_string();
    if !full.starts_with("http") {
        let mut d = if domain.is_empty() {
            SESSION.lock().unwrap().img_domain.clone()
        } else {
            domain.to_string()
        };
        if d.is_empty() {
            return raw.to_string();
        }
        while d.ends_with('/') {
            d.pop();
        }
        while full.starts_with('/') {
            full.remove(0);
        }
        full = format!("{d}/{full}");
    }
    format!(
        "{IMG_RELAY}{}",
        url::form_urlencoded::byte_serialize(full.as_bytes()).collect::<String>()
    )
}

fn card(v: &Value, domain: &str) -> Option<Value> {
    let id = text_of(v, &["videoId"]);
    let title = text_of(v, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let mut cover_raw = String::new();
    for key in ["authCoverImg", "authVerticalImg", "coverImg", "verticalImg"] {
        if let Some(arr) = arr_of(get(v, key).unwrap_or(&Value::Null)) {
            if let Some(first) = arr.first().and_then(|x| x.as_str()) {
                if !first.is_empty() {
                    cover_raw = first.to_string();
                    break;
                }
            }
        }
    }
    let cover = cover_url(&cover_raw, domain);
    let remark = if get(v, "shortDrama").and_then(|b| b.as_bool()).unwrap_or(false) {
        "短剧".to_string()
    } else {
        arr_of(get(v, "tagTitles").unwrap_or(&Value::Null))
            .and_then(|a| a.first().map(|x| x.as_str().unwrap_or("").to_string()))
            .unwrap_or_default()
    };
    Some(item_json(&id, &title, &cover, &remark))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    ensure_session().await?;
    {
        let sess = SESSION.lock().unwrap();
        if let Some(cats) = sess.cats.as_ref() {
            return Ok(json!({"categories": cats}));
        }
    }
    let resp = unwrap(http_get("/api/video/classifyList").await);
    let mut cats: Vec<Value> = Vec::new();
    if let Some(arr) = arr_of(get(&resp, "data").unwrap_or(&Value::Null)) {
        for v in arr {
            let id = text_of(v, &["classifyId"]);
            let name = text_of(v, &["classifyTitle"]);
            if !id.is_empty() && !name.is_empty() {
                cats.push(category_json(&id, &name));
            }
        }
    }
    SESSION.lock().unwrap().cats = Some(cats.clone());
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    ensure_session().await?;
    let page = if page < 1 { 1 } else { page };
    let enc = url::form_urlencoded::byte_serialize(category_id.as_bytes()).collect::<String>();
    let resp = unwrap(
        http_get(&format!(
            "/api/video/getVideoList?pageSize=30&page={page}&classifyId={enc}&sortType=1"
        ))
        .await,
    );
    let mut items: Vec<Value> = Vec::new();
    let total: i64;
    if let Some(arr) = arr_of(get(&resp, "data").unwrap_or(&Value::Null)) {
        for v in arr {
            if let Some(card) = card(v, "") {
                items.push(card);
            }
        }
    }
    total = int_of(&resp, &["total"]);
    let has_more = if total > 0 {
        page < (total + 29) / 30
    } else {
        items.len() == 30
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    ensure_session().await?;
    let resp = unwrap(
        http_get(&format!(
            "/api/video/getVideoById?videoId={}",
            url::form_urlencoded::byte_serialize(id.as_bytes()).collect::<String>()
        ))
        .await,
    );
    SESSION
        .lock()
        .unwrap()
        .detail_cache
        .insert(id.to_string(), resp.clone());
    let title = text_of(&resp, &["title"]);
    let mut cover_raw = String::new();
    for key in ["authCoverImg", "authVerticalImg", "coverImg", "verticalImg"] {
        if let Some(arr) = arr_of(get(&resp, key).unwrap_or(&Value::Null)) {
            if let Some(first) = arr.first().and_then(|x| x.as_str()) {
                if !first.is_empty() {
                    cover_raw = first.to_string();
                    break;
                }
            }
        }
    }
    let cover = cover_url(&cover_raw, "");
    let tags = arr_of(get(&resp, "tagTitles").unwrap_or(&Value::Null))
        .map(|a| {
            a.iter()
                .map(|t| t.as_str().unwrap_or("").to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let remark = if get(&resp, "shortDrama").and_then(|b| b.as_bool()).unwrap_or(false) {
        "短剧".to_string()
    } else {
        tags.join(" ")
    };
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(arr) = arr_of(get(&resp, "serialVideos").unwrap_or(&Value::Null)) {
        if !arr.is_empty() {
            for (i, v) in arr.iter().enumerate() {
                let vid = text_of(v, &["videoId"]);
                let t = text_of(v, &["title"]);
                let t = if t.is_empty() {
                    format!("第{}集", i + 1)
                } else {
                    t
                };
                episodes.push(episode_json(&vid, &t, id));
            }
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(id, "正片", id));
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover, "synopsis": remark,
        "extra": {}, "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    ensure_session().await?;
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let resp = unwrap(
        http_get(&format!(
            "/api/search/keyWord?pageSize=20&page=1&searchWord={enc}&searchType=3&shortDrama=true"
        ))
        .await,
    );
    let domain = text_of(&resp, &["domain"]);
    let mut items: Vec<Value> = Vec::new();
    if let Some(arr) = arr_of(get(&resp, "videoList").unwrap_or(&Value::Null)) {
        for v in arr {
            if let Some(c) = card(v, &domain) {
                items.push(c);
            }
        }
    }
    Ok(json!({"items": items}))
}

async fn get_sign_key() -> String {
    {
        let sess = SESSION.lock().unwrap();
        if !sess.sign_key.is_empty() {
            if let Some(at) = sess.sign_key_at {
                if at.elapsed() < Duration::from_secs(3600) {
                    return sess.sign_key.clone();
                }
            }
        }
    }
    let key = text_of(&unwrap(http_get("/api/v2/m3u8/play/signKey").await), &["signKey"]);
    if !key.is_empty() {
        let mut sess = SESSION.lock().unwrap();
        sess.sign_key = key.clone();
        sess.sign_key_at = Some(Instant::now());
    }
    key
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    ensure_session().await?;
    let resp = unwrap(
        http_get(&format!(
            "/api/video/can/watch?videoId={}",
            url::form_urlencoded::byte_serialize(video_id.as_bytes()).collect::<String>()
        ))
        .await,
    );
    let mut video_url = text_of(&resp, &["videoUrl"]);
    let mut auth_key = text_of(&resp, &["authKey"]);
    if video_url.is_empty() {
        let cached = SESSION
            .lock()
            .unwrap()
            .detail_cache
            .get(video_id)
            .cloned();
        if let Some(c) = cached {
            video_url = text_of(&c, &["videoUrl"]);
            if auth_key.is_empty() {
                auth_key = text_of(&c, &["authKey"]);
            }
        }
    }
    if video_url.is_empty() {
        let resp2 = unwrap(
            http_get(&format!(
                "/api/m3u8/decode/by/id?videoId={}",
                url::form_urlencoded::byte_serialize(video_id.as_bytes()).collect::<String>()
            ))
            .await,
        );
        video_url = text_of(&resp2, &["videoUrl"]);
        if video_url.is_empty() {
            video_url = text_of(&resp2, &["path"]);
        }
        if video_url.is_empty() {
            video_url = text_of(&resp2, &["url"]);
        }
    }
    let token = SESSION.lock().unwrap().token.clone();
    let base = SESSION.lock().unwrap().base.clone().unwrap_or_default();
    if video_url.is_empty() || token.is_empty() {
        return Err(ApiError::Internal("hgdjv no videoUrl or token".into()));
    }
    let sign_key = get_sign_key().await;
    let server_ms = int_of(&unwrap(http_get("/api/v2/m3u8/play/time").await), &["unixMilliseconds"]);
    let ts: u64 = if server_ms > 0 {
        ((now_ms() as i64 + (server_ms - now_ms() as i64)) / 1000) as u64
    } else {
        now_sec()
    };
    let nonce = new_uuid();
    let sign_input = format!("{video_url}{token}{ts}{nonce}");
    let sign = if sign_key.is_empty() {
        String::new()
    } else {
        hmac_sha256_hex(sign_key.as_bytes(), sign_input.as_bytes())
    };
    let mut url = format!(
        "{base}/api/v2/m3u8/play?path={}&token={}&ts={ts}&nonce={nonce}&sign={sign}",
        url::form_urlencoded::byte_serialize(video_url.as_bytes()).collect::<String>(),
        url::form_urlencoded::byte_serialize(token.as_bytes()).collect::<String>(),
    );
    if !auth_key.is_empty() {
        url.push_str(&format!(
            "&authKey={}",
            url::form_urlencoded::byte_serialize(auth_key.as_bytes()).collect::<String>()
        ));
    }
    Ok(json!({"url": url, "header": {"User-Agent": UA}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_hex_lowercase() {
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn hmac_sha256_known() {
        // RFC 4231 case 2: key "Jefe", data "what do ya want for nothing?"
        let out = hmac_sha256_hex(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            out,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn ecb_roundtrip() {
        let key = "0123456789abcdef";
        let enc = ecb_enc("hello world test!", key).unwrap();
        let back = ecb_dec(&enc, key).unwrap();
        assert_eq!(back, "hello world test!");
    }
}
