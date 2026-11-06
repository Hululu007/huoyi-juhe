//! 黄果短剧 App：优先走 App 网关（api1.slpctsbs.com 等 15 个
//! host 并发探 /health，首个活的为准），网关数据为 RSA 之外
//! 的 AES 信封（keyPair 接口取密钥，CBC/ECB 双试 + IV 前缀
//! 变体 + gzip/zlib 解压）；网关不通时回落品牌站逻辑（与
//! hgdj.rs 同款：/video/<id>/ 集页 epPlaySrcs 取流）。
//!
//! 修：Java 的 pickLine 在循环 finally 里调 shutdownNow，实
//! 际只探第一个网关且结果从未读取，网关恒等于不通；Rust 按
//! 原意实现并发探活。

use std::io::Read;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use futures::future::join_all;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const HOST: &str = "https://huangguoai.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const APP_UA: &str = "Dart/3.5 (dart:io)";
const API: &str = "/api/v1";
const CFG_URL: &str =
    "https://0530b.vhcepshla.cc/download/hgdj/report-config?aff_code=ac4Ea&channel=ak0006&tpl=B";
const LINE_TTL: Duration = Duration::from_secs(30 * 60);
const KEYS_TTL: Duration = Duration::from_secs(3600);

/// 网关 host（jar 里 base64 存放，已解出）。
const GW: &[&str] = &[
    "api1.slpctsbs.com",
    "api2.slpctsbs.com",
    "api3.slpctsbs.com",
    "api4.slpctsbs.com",
    "api5.slpctsbs.com",
    "api6.slpctsbs.com",
    "api7.slpctsbs.com",
    "api1.fidlexte.cc",
    "api2.fidlexte.cc",
    "api3.fidlexte.cc",
    "api4.fidlexte.cc",
    "api5.fidlexte.cc",
    "api6.fidlexte.cc",
    "bak.slpctsbs.com",
    "api1.huangguojiu.com",
];

static LINE_CACHE: Mutex<Option<(String, Instant)>> = Mutex::new(None);
static KEYS_CACHE: Mutex<Option<(String, String, Instant)>> = Mutex::new(None);

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https?://[^\s"'<>]+\.m3u8"#).unwrap())
}

// ============ 通用 AES ============

/// AES 解块 + CBC 异或，PKCS7 填充合法时去掉，否则保留原数据。
fn aes_cbc_decrypt(data: &[u8], key: &[u8], iv: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if iv.len() < 16 || data.len() % 16 != 0 {
        return None;
    }
    fn run<C>(data: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8>
    where
        C: BlockDecrypt + KeyInit,
    {
        use aes::cipher::generic_array::GenericArray;
        let cipher = C::new(GenericArray::from_slice(key));
        let mut out = Vec::with_capacity(data.len());
        let mut prev = iv[..16].to_vec();
        for chunk in data.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.decrypt_block(&mut block);
            for i in 0..16 {
                out.push(block[i] ^ prev[i]);
            }
            prev = chunk.to_vec();
        }
        out
    }
    let out = match key.len() {
        16 => run::<aes::Aes128>(data, &key[..16], iv),
        24 => run::<aes::Aes192>(data, &key[..24], iv),
        32 => run::<aes::Aes256>(data, &key[..32], iv),
        _ => return None,
    };
    Some(pkcs7_unpad(out))
}

fn aes_ecb_decrypt(data: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if data.len() % 16 != 0 {
        return None;
    }
    fn run<C>(data: &[u8], key: &[u8]) -> Vec<u8>
    where
        C: BlockDecrypt + KeyInit,
    {
        use aes::cipher::generic_array::GenericArray;
        let cipher = C::new(GenericArray::from_slice(key));
        let mut out = Vec::with_capacity(data.len());
        for chunk in data.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.decrypt_block(&mut block);
            out.extend_from_slice(&block);
        }
        out
    }
    let out = match key.len() {
        16 => run::<aes::Aes128>(data, &key[..16]),
        24 => run::<aes::Aes192>(data, &key[..24]),
        32 => run::<aes::Aes256>(data, &key[..32]),
        _ => return None,
    };
    Some(pkcs7_unpad(out))
}

fn pkcs7_unpad(mut out: Vec<u8>) -> Vec<u8> {
    if !out.is_empty() {
        let pad = out[out.len() - 1] as usize;
        if (1..=16).contains(&pad)
            && pad <= out.len()
            && out[out.len() - pad..].iter().all(|&b| b as usize == pad)
        {
            out.truncate(out.len() - pad);
        }
    }
    out
}

fn looks_json(s: &str) -> bool {
    let t = s.trim();
    t.len() >= 2
        && ((t.starts_with('{') && t.ends_with('}')) || (t.starts_with('[') && t.ends_with(']')))
}

fn maybe_unzip(data: &[u8]) -> String {
    if data.len() < 4 {
        return String::new();
    }
    let mut out = Vec::new();
    let decoded: Option<Vec<u8>> = if data[0] == 0x1f && data[1] == 0x8b {
        use flate2::read::GzDecoder;
        let mut d = GzDecoder::new(data);
        d.read_to_end(&mut out).ok().map(|_| out.clone())
    } else {
        use flate2::read::ZlibDecoder;
        let mut d = ZlibDecoder::new(data);
        d.read_to_end(&mut out).ok().map(|_| out.clone())
    };
    match decoded {
        Some(bytes) => match String::from_utf8(bytes) {
            Ok(s) if looks_json(&s) => s,
            _ => String::new(),
        },
        None => String::new(),
    }
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let bytes = hex::decode(s).ok()?;
    Some(bytes)
}

// ============ 网关 ============

fn api_headers(host: &str) -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", APP_UA.to_string()),
        ("Accept", "application/json, text/plain, */*".to_string()),
        (
            "Content-Type",
            "application/json; charset=utf-8".to_string(),
        ),
        ("Host", host.to_string()),
        ("Origin", format!("https://{host}")),
        ("Referer", format!("https://{host}/")),
    ]
}

async fn health_probe(host: &str) -> Option<String> {
    let mut req = client().ok()?.get(format!("https://{host}/health"));
    for (k, v) in api_headers(host) {
        req = req.header(k, v);
    }
    let fut = async move {
        let resp = req.send().await.ok()?;
        let text = resp.text().await.ok()?;
        if text.contains("\"service\"") {
            Some(host.to_string())
        } else {
            None
        }
    };
    tokio::time::timeout(Duration::from_secs(5), fut)
        .await
        .ok()
        .flatten()
}

/// 并发探全部网关，按 GW 顺序取首个活的，缓存 30 分钟。
async fn pick_line() -> ApiResult<String> {
    if let Ok(guard) = LINE_CACHE.lock() {
        if let Some((line, at)) = guard.as_ref() {
            if Instant::now() < *at + LINE_TTL && !line.is_empty() {
                return Ok(line.clone());
            }
        }
    }
    let results = join_all(GW.iter().map(|h| health_probe(h))).await;
    for r in results {
        if let Some(host) = r {
            if let Ok(mut guard) = LINE_CACHE.lock() {
                *guard = Some((host.clone(), Instant::now()));
            }
            return Ok(host);
        }
    }
    Err(ApiError::Internal("黄果短剧App 网关全部线路不通".into()))
}

async fn key_pair() -> Option<(String, String)> {
    if let Ok(guard) = KEYS_CACHE.lock() {
        if let Some((k, iv, at)) = guard.as_ref() {
            if Instant::now() < *at + KEYS_TTL {
                return Some((k.clone(), iv.clone()));
            }
        }
    }
    let req = client()
        .ok()?
        .get(CFG_URL)
        .header("User-Agent", "Mozilla/5.0")
        .header("Accept", "application/json");
    let resp = req.send().await.ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let text = resp.text().await.ok()?;
    let body: Value = serde_json::from_str(text.trim()).ok()?;
    let key = text_of(&body, &["encryption_key"]);
    let iv = text_of(&body, &["encryption_iv"]);
    if key.is_empty() || iv.is_empty() {
        return None;
    }
    if let Ok(mut guard) = KEYS_CACHE.lock() {
        *guard = Some((key.clone(), iv.clone(), Instant::now()));
    }
    Some((key, iv))
}

/// Java addKeyCands：UTF-8 字节对 + 零 IV/固定 IV + hex 对。
fn add_key_cands(out: &mut Vec<(Vec<u8>, Vec<u8>)>, key: &str, iv: &str) {
    let kb = key.as_bytes().to_vec();
    let vb = iv.as_bytes().to_vec();
    if (kb.len() == 16 || kb.len() == 24 || kb.len() == 32) && vb.len() == 16 {
        out.push((kb.clone(), vb.clone()));
    }
    if kb.len() == 16 {
        out.push((kb.clone(), vec![0u8; 16]));
        out.push((kb.clone(), b"0123456789abcdef".to_vec()));
    }
    if key.len() == 16 && iv.len() == 16 {
        if let (Some(hk), Some(hv)) = (hex_decode(key), hex_decode(iv)) {
            out.push((hk, hv));
        }
    }
}

fn try_dec(data: &[u8], key: &[u8], iv: &[u8], cbc: bool, with_iv: bool) -> String {
    let plain = if cbc {
        if with_iv {
            aes_cbc_decrypt(data, key, iv)
        } else {
            aes_cbc_decrypt(data, key, &[0u8; 16])
        }
    } else {
        aes_ecb_decrypt(data, key)
    };
    let Some(bytes) = plain else {
        return String::new();
    };
    if let Ok(s) = String::from_utf8(bytes.clone()) {
        if looks_json(&s) {
            return s;
        }
    }
    maybe_unzip(&bytes)
}

async fn decode_data(data: &str) -> String {
    let t = data.trim();
    if t.len() > 1 && (t.starts_with('{') || t.starts_with('[')) {
        return t.to_string();
    }
    let raw = match base64::Engine::decode(&base64::engine::general_purpose::STANDARD, t) {
        Ok(b) if !b.is_empty() => b,
        _ => return String::new(),
    };
    let mut cands: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
    if let Some((k, iv)) = key_pair().await {
        add_key_cands(&mut cands, &k, &iv);
        if let (Some(hk), Some(hv)) = (hex_decode(&k), hex_decode(&iv)) {
            cands.push((hk, hv));
        }
    }
    add_key_cands(&mut cands, "0123456789abcdef", "0123456789abcdef");
    for (key, iv) in &cands {
        for cbc in [true, false] {
            let s = try_dec(&raw, key, iv, cbc, true);
            if !s.is_empty() {
                return s;
            }
            if raw.len() > 16 {
                let s = try_dec(&raw[16..], key, iv, cbc, false);
                if !s.is_empty() {
                    return s;
                }
            }
        }
    }
    maybe_unzip(&raw)
}

async fn app_post(path: &str, body: Value) -> ApiResult<Value> {
    let line = pick_line().await?;
    let url = format!("https://{line}{API}{path}");
    let mut req = client()?.post(&url).json(&body);
    for (k, v) in api_headers(&line) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "黄果短剧App 网关 HTTP {status}"
        )));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    open_envelope(&text).await
}

async fn open_envelope(text: &str) -> ApiResult<Value> {
    let body: Value = serde_json::from_str(text.trim())?;
    let code = super::int_of(&body, &["errcode", "code"]);
    if code == 0 {
        let data = text_of(&body, &["data"]);
        if data.is_empty() {
            return Err(ApiError::Internal("黄果短剧App 网关未返回 data".into()));
        }
        let decoded = decode_data(&data).await;
        if decoded.is_empty() {
            return Err(ApiError::Internal("黄果短剧App 网关 data 解不开".into()));
        }
        let inner: Value = serde_json::from_str(&decoded)?;
        return Ok(inner);
    }
    let msg = text_of(&body, &["message"]);
    Err(ApiError::Internal(format!(
        "黄果短剧App 网关 errcode={code} {msg}"
    )))
}

/// 深度优先找首个“首元素为对象”的数组。
fn scan_array(v: &Value) -> Option<Vec<Value>> {
    match v {
        Value::Array(arr) => {
            if !arr.is_empty() && arr[0].is_object() {
                return Some(arr.clone());
            }
            for e in arr {
                if let Some(found) = scan_array(e) {
                    return Some(found);
                }
            }
            None
        }
        Value::Object(m) => {
            for (_, val) in m {
                if let Some(found) = scan_array(val) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// 深度优先找首个含 title/name/play_url/m3u8 的对象。
fn first_obj(v: &Value) -> Option<Value> {
    match v {
        Value::Object(m) => {
            if m.contains_key("title")
                || m.contains_key("name")
                || m.contains_key("play_url")
                || m.contains_key("m3u8")
            {
                return Some(v.clone());
            }
            for (_, val) in m {
                if let Some(found) = first_obj(val) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(arr) => {
            for e in arr {
                if let Some(found) = first_obj(e) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

fn scan_pairs(v: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some(arr) = scan_array(v) else {
        return out;
    };
    for e in arr {
        let id = text_of(&e, &["id", "category_id", "theater_id", "type_id", "code"]);
        let name = text_of(&e, &["name", "title", "category_name", "type_name"]);
        if !id.is_empty() && !name.is_empty() {
            out.push((id, name));
        }
    }
    out
}

async fn gw_feed(category_id: Option<&str>, page: i64) -> ApiResult<Vec<Value>> {
    let mut body = json!({"page": page, "size": 20});
    if let Some(cid) = category_id {
        if !cid.is_empty() {
            body["category_id"] = json!(cid);
        }
    }
    let resp = app_post("/content/short-drama/theater/feed", body).await?;
    let Some(arr) = scan_array(&resp) else {
        return Ok(Vec::new());
    };
    let mut items = Vec::new();
    for e in arr {
        let id = text_of(
            &e,
            &["id", "content_id", "video_id", "theater_id", "drama_id"],
        );
        let title = text_of(&e, &["title", "name", "content_title", "drama_name"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = text_of(&e, &["cover", "pic", "image", "poster", "cover_url"]);
        let remark = text_of(&e, &["remark", "episode_text", "subtitle", "tag"]);
        items.push(item_json(&id, &title, &cover, &remark));
    }
    Ok(items)
}

async fn gw_categories() -> ApiResult<Value> {
    let resp = app_post("/content/short-drama/theater/config", json!({})).await?;
    let pairs = scan_pairs(&resp);
    if pairs.is_empty() {
        return Err(ApiError::Internal("黄果短剧App config 无分类".into()));
    }
    let list: Vec<Value> = pairs
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

async fn gw_detail(id: &str) -> ApiResult<Value> {
    let resp = app_post(
        "/content/contents/detail-content",
        json!({"id": id, "content_id": id}),
    )
    .await?;
    let obj =
        first_obj(&resp).ok_or_else(|| ApiError::Internal("黄果短剧App 未返回详情".into()))?;
    let title = text_of(&obj, &["title", "name"]);
    let cover = text_of(&obj, &["cover", "pic", "poster"]);
    let desc = text_of(&obj, &["description", "desc", "content"]);
    let play_url = text_of(&obj, &["play_url", "m3u8", "video_url", "url"]);
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": {},
        "episodes": [episode_json(&format!("正片${play_url}"), "正片", id)],
    }))
}

async fn gw_search(query: &str) -> ApiResult<Value> {
    let resp = app_post(
        "/search_v3/search",
        json!({"keyword": query, "page": 1, "size": 20}),
    )
    .await?;
    let Some(arr) = scan_array(&resp) else {
        return Ok(json!({"items": []}));
    };
    let mut items = Vec::new();
    for e in arr {
        let id = text_of(&e, &["id", "content_id", "video_id"]);
        let title = text_of(&e, &["title", "name"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = text_of(&e, &["cover", "pic", "image"]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    Ok(json!({"items": items}))
}

// ============ 品牌站回落（与 hgdj.rs 同款逻辑） ============

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn attr(block: &str, name: &str) -> String {
    let marker = format!("{name}=\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    block[s..]
        .find('"')
        .map(|e| block[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(block: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = block.find(&open) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

fn class_text(block: &str, class: &str) -> String {
    let marker = format!("class=\"{class}\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
    strip_tags(&after[s..e])
}

fn valid_cover(v: &str) -> bool {
    if v.is_empty() || v.starts_with("data:") {
        return false;
    }
    let low = v.to_lowercase();
    if low.contains("loading")
        || low.contains("placeholder")
        || low.contains("no_preview")
        || low.contains("drama-loading")
    {
        return false;
    }
    if low.contains("/static/") && !low.contains("/upload") {
        return false;
    }
    low.contains(".jpg")
        || low.contains(".jpeg")
        || low.contains(".png")
        || low.contains(".webp")
        || low.contains(".avif")
        || low.contains("img")
}

fn pick_cover(block: &str) -> String {
    for key in ["data-src", "data-original", "data-lazy-src"] {
        let v = attr(block, key);
        if valid_cover(&v) {
            return v;
        }
    }
    if let Some(p) = block.find("<img") {
        let after = &block[p..];
        if let Some(s) = after.find("src=\"") {
            let s = s + 5;
            if let Some(e) = after[s..].find('"') {
                let v = &after[s..s + e];
                if valid_cover(v) {
                    return v.to_string();
                }
            }
        }
    }
    String::new()
}

fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for block in html.split("hg-drama-card").skip(1) {
        let href = if let Some(p) = block.find("href=\"") {
            let s = p + 6;
            block[s..].find('"').map(|e| &block[s..s + e]).unwrap_or("")
        } else {
            ""
        };
        if href.is_empty() || !href.contains("/video/") && !href.contains("/drama/") {
            continue;
        }
        let mut title = attr(block, "data-track-item-name");
        if title.is_empty() {
            title = tag_text(block, "h3");
        }
        if title.is_empty() {
            title = tag_text(block, "h2");
        }
        if title.is_empty() {
            title = class_text(block, "sr-only");
        }
        if title.is_empty() {
            title = attr(block, "alt");
        }
        if title.is_empty() {
            continue;
        }
        let cover = pick_cover(block);
        let mut remark = class_text(block, "hg-drama-card__episode");
        if remark.is_empty() {
            remark = class_text(block, "eps-flag");
        }
        if remark.is_empty() {
            remark = class_text(block, "score");
        }
        if remark.is_empty() {
            remark = class_text(block, "small");
        }
        if remark.is_empty() {
            remark = class_text(block, "badge");
        }
        if remark.is_empty() {
            remark = "AI短剧".to_string();
        }
        items.push(item_json(href, &title, &cover, &remark));
    }
    items
}

fn og(html: &str, prop: &str) -> String {
    let marker = format!("property=\"{prop}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let Some(c) = after.find("content=\"") else {
        return String::new();
    };
    let s = c + 9;
    after[s..]
        .find('"')
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn blob(html: &str, key: &str) -> Option<Value> {
    let pos = html.find(key)?;
    let bytes = html.as_bytes();
    let mut i = pos;
    while i > 0 {
        i -= 1;
        if bytes[i] != b'{' {
            continue;
        }
        let mut depth = 0;
        let mut j = i;
        let mut in_str = false;
        let mut esc = false;
        let mut end = None;
        while j < bytes.len() {
            let b = bytes[j];
            if in_str {
                if esc {
                    esc = false;
                } else if b == b'\\' {
                    esc = true;
                } else if b == b'"' {
                    in_str = false;
                }
            } else if b == b'"' {
                in_str = true;
            } else if b == b'{' {
                depth += 1;
            } else if b == b'}' {
                depth -= 1;
                if depth == 0 {
                    end = Some(j);
                    break;
                }
            }
            j += 1;
        }
        let Some(e) = end else { continue };
        if let Ok(v) = serde_json::from_str::<Value>(&html[i..=e]) {
            if html[i..=e].contains(key) {
                return Some(v);
            }
        }
    }
    None
}

fn best_src(obj: &Value) -> String {
    if let Some(cur) = get(obj, "current") {
        let s = text_of(cur, &["src", "srcHevc"]);
        if !s.is_empty() {
            return s;
        }
    }
    let v = text_of(obj, &["videoSrc"]);
    if !v.is_empty() {
        return v;
    }
    if let Some(eps) = get(obj, "epPlaySrcs") {
        let mut best_n = -1i64;
        let mut best = String::new();
        if let Some(m) = eps.as_object() {
            for (k, val) in m {
                if let Ok(n) = k.parse::<i64>() {
                    let s = super::str_of(val);
                    if n > best_n && !s.is_empty() {
                        best_n = n;
                        best = s;
                    }
                }
            }
        }
        if !best.is_empty() {
            return best;
        }
    }
    String::new()
}

async fn brand_fetch(url: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄果短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn brand_abs(path: &str) -> String {
    if path.starts_with("http") {
        path.to_string()
    } else if path.starts_with('/') {
        format!("{HOST}{path}")
    } else {
        format!("{HOST}/{path}")
    }
}

const BRAND_CLASSES: &[(&str, &str)] = &[
    ("/ai-duanju/", "AI成人短剧"),
    ("/ai-manju/", "AI漫剧"),
    ("/ai-huanlian/", "AI换脸"),
    ("/ai-mogai/", "AI魔改"),
];

async fn brand_categories() -> ApiResult<Value> {
    let list: Vec<Value> = BRAND_CLASSES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

async fn brand_catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page > 1 {
        format!("{}{}{}/", HOST, category_id.trim_end_matches('/'), page)
    } else {
        format!("{HOST}{category_id}")
    };
    let html = brand_fetch(&url).await?;
    let items = parse_cards(&html);
    let has_more = items.len() >= 18;
    Ok(json!({"items": items, "has_more": has_more}))
}

async fn brand_detail(series_id: &str) -> ApiResult<Value> {
    let url = brand_abs(series_id);
    let html = brand_fetch(&url).await?;
    let mut title = tag_text(&html, "h1");
    if title.is_empty() {
        title = og(&html, "og:title");
    }
    if let Some(p) = title.find('《') {
        if let Some(e) = title[p..].find('》') {
            title = title[p + 3..p + e].to_string();
        }
    }
    if let Some(p) = title.find('|') {
        title = title[..p].trim().to_string();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("黄果短剧未返回影片资料".into()));
    }
    let mut cover = String::new();
    for key in ["posterSrc", "coverSrc"] {
        let marker = format!("\"{key}\":\"");
        if let Some(p) = html.find(&marker) {
            let s = p + marker.len();
            if let Some(e) = html[s..].find('"') {
                cover = html[s..s + e].to_string();
                break;
            }
        }
    }
    if cover.is_empty() {
        cover = og(&html, "og:image");
    }
    if cover.contains("cover-placeholder") {
        cover.clear();
    }
    let mut desc = String::new();
    if let Some(p) = html.find("description") {
        let after = &html[p..];
        if let Some(c) = after.find("content=\"") {
            let s = c + 9;
            if let Some(e) = after[s..].find('"') {
                desc = after[s..s + e].to_string();
            }
        }
    }
    if desc.is_empty() {
        desc = og(&html, "og:description");
    }
    let vid = series_id
        .trim_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(series_id)
        .to_string();
    let ep_re = Regex::new(r#"data-ep-id="(\d{1,4})""#).unwrap();
    let mut eps: Vec<i64> = ep_re
        .captures_iter(&html)
        .filter_map(|c| c[1].parse::<i64>().ok())
        .collect();
    if eps.is_empty() {
        let ep_url_re = Regex::new(r"/video/(\d+)/ep-(\d{1,4})/").unwrap();
        eps = ep_url_re
            .captures_iter(&html)
            .filter_map(|c| c[2].parse::<i64>().ok())
            .collect();
    }
    eps.sort_unstable();
    eps.dedup();
    if eps.is_empty() {
        eps.push(1);
    }
    let mut episodes: Vec<Value> = Vec::new();
    for n in &eps {
        let ep_url = if *n == 1 {
            format!("{HOST}/video/{vid}/")
        } else {
            format!("{HOST}/video/{vid}/ep-{n}/")
        };
        episodes.push(episode_json(&ep_url, &format!("第{n}集"), series_id));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": {},
        "episodes": episodes,
    }))
}

// ============ 五个入口：先网关，失败回落品牌站 ============

pub(crate) async fn categories() -> ApiResult<Value> {
    match gw_categories().await {
        Ok(v) => Ok(v),
        Err(_) => brand_categories().await,
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if category_id.starts_with("http")
        || category_id.starts_with('/')
        || category_id.starts_with("t:")
    {
        return brand_catalog(category_id, page).await;
    }
    match gw_feed(Some(category_id), page).await {
        Ok(items) if !items.is_empty() => {
            let has_more = items.len() >= 20;
            Ok(json!({"items": items, "has_more": has_more}))
        }
        _ => brand_catalog(category_id, page).await,
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if series_id.starts_with("http") || series_id.starts_with('/') {
        return brand_detail(series_id).await;
    }
    match gw_detail(series_id).await {
        Ok(v) => Ok(v),
        Err(_) => brand_detail(series_id).await,
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let html = brand_fetch(video_id).await?;
    let mut url = String::new();
    if let Some(obj) = blob(&html, "epPlaySrcs") {
        url = best_src(&obj);
    }
    if url.is_empty() {
        if let Some(p) = html.find("videoSrc") {
            let after = &html[p..];
            let marker = "\"videoSrc\":\"";
            if let Some(q) = after.find(marker) {
                let s = q + marker.len();
                if let Some(e) = after[s..].find('"') {
                    url = after[s..s + e].to_string();
                }
            }
        }
    }
    if url.is_empty() {
        url = m3u8_re()
            .captures(&html)
            .and_then(|c| c.get(0))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }
    if url.is_empty() {
        return Err(ApiError::Internal("黄果短剧未取到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": video_id},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    match gw_search(query).await {
        Ok(v) => Ok(v),
        Err(_) => {
            let url = format!(
                "{HOST}/search/?keyword={}",
                url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
            );
            let html = brand_fetch(&url).await?;
            let items = parse_cards(&html);
            Ok(json!({"items": items}))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gw_list_size() {
        assert_eq!(GW.len(), 15);
    }

    #[test]
    fn looks_json_checks() {
        assert!(looks_json(r#"{"a":1}"#));
        assert!(looks_json(r#"[1,2]"#));
        assert!(!looks_json("not json"));
        assert!(!looks_json(r#"{"a":1"#));
    }

    #[test]
    fn key_cands_include_zero_iv() {
        let mut cands = Vec::new();
        add_key_cands(&mut cands, "0123456789abcdef", "0123456789abcdef");
        assert!(cands.iter().any(|(_, iv)| iv.iter().all(|&b| b == 0)));
    }

    #[test]
    fn scan_array_deep() {
        let v = json!({"data": {"list": [{"id": "1", "name": "A"}]}});
        let arr = scan_array(&v).unwrap();
        assert_eq!(arr.len(), 1);
        let pairs = scan_pairs(&v);
        assert_eq!(pairs[0], ("1".to_string(), "A".to_string()));
    }
}
