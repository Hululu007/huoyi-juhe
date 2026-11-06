//! 新快猫：IP 发现 + MD5 签名 + AES/CBC 加密请求体。
//!
//! 来源 jar 类 `ZakaKm2Amns`。发现：GET
//! `http://119.28.28.28/d?dn=app.newkm-azuercdn.com`（8 秒超时），首个
//! 分词拼 `http://<ip>:8099`；回退 IP `16.163.155.131`、
//! `119.28.228.253`、`150.109.44.66`（均 `:8099`，http）。
//!
//! 签名+加密：请求体 JSON 按参数顺序拼（int 直接写数字、string 经
//! `jsonQuote` 转义），末尾加 `"signature":"<MD5 大写 hex>"`，其中 MD5
//! 输入为 `<参数名>=<URLEncoder 编码的 raw 值>` 按参数顺序用 `&` 连接 + SALT；
//! 整体 PKCS7 填充（填充字节值 = 补长，含满 16 倍数时补 16）后
//! AES/CBC/NoPadding 加密，再转大写 hex；POST body 为
//! `api_token=&data=<URLEncoder 编码的大写 hex>&device=android&device_type=MI8&device_version=8.0.0&version_code=2`，
//! `Content-Type: application/x-www-form-urlencoded`，UA `okhttp/4.9.0`；
//! 响应以 `{` 开头为明文 JSON，否则为 hex → AES/CBC 解密去 PKCS7；
//! 要求 `code == 200`，成功则锁定该 base。
//!
//! 分类写死 3 类：`3` 热门、`2` 发现、`1` 精选；列表 POST
//! `/api/video/index`，参数 `page`、`type`，取 `data.video_list[]` 或
//! `data.list[]`；卡片只留免费（`type == 1`，且 `gold` 不大于 0，且
//! `is_vip` 为空或 `"0"`），`vod_id=id`、标题 `title`、封面 `cover`、
//! 备注 `nickname`、内容 `点赞 <praise_num>`（>0 时）。
//! 详情 POST `/api/video/info`，参数 `video_id`，取 `data.video_info`；
//! 付费（`gold>0`）不进；`vod_play_url=正片$<id>`，演员为 `nickname`。
//! 搜索：无服务端搜索；Java 在 3 个 type × 前 5 页里按标题+备注小写
//! 含关键词过滤，上限 20 条。取流：同 `/api/video/info` 取 `m3u8_url`，
//! 空则取 `normal_url`；头为 UA + Referer `<base>/`；返回 parse 0。

use std::sync::Mutex;

use md5::Digest as _;
use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const UA: &str = "okhttp/4.9.0";
const SALT: &str = r#"ohI}-bFpD*z8)W7~REusVa]U`YKQ=[C1&XZ."n5:dl<{?@J6NkO+f%c^"$tevxB>j2M_9;G#y3Tw|gL/HS,Pqr0!Ami(49Y_.~Tan#z{5ZLO,_E(7!vJ^HC5_{Xq5$z*"#;
const AES_KEY: &[u8] = b"x;j/6olSp})&{ZJD";
const AES_IV: &[u8] = b"znbV%$JN5olCpt<c";
const DNS_URL: &str = "http://119.28.28.28/d?dn=app.newkm-azuercdn.com";
const FALLBACK_IPS: &[&str] = &["16.163.155.131", "119.28.228.253", "150.109.44.66"];
const FALLBACK_BASE: &str = "http://16.163.155.131:8099";

const CATS: &[(&str, &str)] = &[("3", "热门"), ("2", "发现"), ("1", "精选")];

static BASE_CACHE: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static CACHE: Lazy<Mutex<std::collections::HashMap<String, Value>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

fn md5_hex_upper(data: &[u8]) -> String {
    let mut h = md5::Md5::new();
    h.update(data);
    hex::encode_upper(h.finalize())
}

fn json_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// 参数三元组：(key, rendered, raw)。int 的 rendered 与 raw 均为数字
/// 原样；string 的 rendered 为 `jsonQuote`，raw 为原值。
struct Pair {
    key: String,
    rendered: String,
    raw: String,
}

fn int_pair(key: &str, v: i64) -> Pair {
    Pair {
        key: key.to_string(),
        rendered: v.to_string(),
        raw: v.to_string(),
    }
}

fn str_pair(key: &str, v: &str) -> Pair {
    Pair {
        key: key.to_string(),
        rendered: json_quote(v),
        raw: v.to_string(),
    }
}

fn form_data(pairs: &[Pair]) -> String {
    let mut sign_parts: Vec<String> = Vec::new();
    for p in pairs {
        sign_parts.push(format!(
            "{}={}",
            p.key,
            url::form_urlencoded::byte_serialize(p.raw.as_bytes()).collect::<String>()
        ));
    }
    let sign_input = format!("{}{}", sign_parts.join("&"), SALT);
    let sig = md5_hex_upper(sign_input.as_bytes());
    let mut body = String::from("{");
    for (i, p) in pairs.iter().enumerate() {
        if i > 0 {
            body.push(',');
        }
        body.push_str(&json_quote(&p.key));
        body.push(':');
        body.push_str(&p.rendered);
    }
    if !pairs.is_empty() {
        body.push(',');
    }
    body.push_str("\"signature\":");
    body.push_str(&json_quote(&sig));
    body.push('}');
    let padded = crate::crypto::pkcs7_pad(body.as_bytes(), 16);
    let cipher = crate::crypto::aes_cbc_encrypt(&padded, AES_KEY, AES_IV);
    let hex_up = hex::encode_upper(cipher);
    format!(
        "api_token=&data={}&device=android&device_type=MI8&device_version=8.0.0&version_code=2",
        url::form_urlencoded::byte_serialize(hex_up.as_bytes()).collect::<String>()
    )
}

async fn candidates() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    // DNS 发现用 8 秒超时（与 jar 一致），不用共享的 20 秒 client。
    if let Ok(c) = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
    {
        if let Ok(resp) = c.get(DNS_URL).send().await {
            if let Ok(text) = resp.text().await {
                let first = text
                    .split(|c: char| c == ';' || c == ',' || c == '\n' || c == ' ')
                    .find(|s| !s.is_empty());
                if let Some(ip) = first {
                    out.push(format!("http://{ip}:8099"));
                }
            }
        }
    }
    for ip in FALLBACK_IPS {
        out.push(format!("http://{ip}:8099"));
    }
    out
}

async fn call(path: &str, pairs: &[Pair]) -> ApiResult<Value> {
    let body = form_data(pairs);
    let mut bases: Vec<String> = Vec::new();
    if let Some(b) = BASE_CACHE.lock().unwrap().clone() {
        bases.push(b);
    }
    for c in candidates().await {
        if !bases.contains(&c) {
            bases.push(c);
        }
    }
    let mut last_err = String::new();
    for base in bases {
        let url = format!("{base}{path}");
        let resp = match client() {
            Ok(c) => c
                .post(&url)
                .header("User-Agent", UA)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(body.clone())
                .send()
                .await
                .map_err(|e| format!("http {e}")),
            Err(e) => Err(format!("{e}")),
        };
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = e;
                continue;
            }
        };
        if !resp.status().is_success() {
            last_err = format!("http {}", resp.status());
            continue;
        }
        let Ok(text) = resp.text().await else {
            last_err = "empty body".to_string();
            continue;
        };
        let text = text.trim().to_string();
        let parsed: Option<Value> = if text.starts_with('{') {
            serde_json::from_str(&text).ok()
        } else {
            let hexed = hex::decode(text.as_bytes()).ok();
            hexed.and_then(|bytes| {
                if bytes.is_empty() || bytes.len() % 16 != 0 {
                    return None;
                }
                let plain = crate::crypto::aes_cbc_decrypt(&bytes, AES_KEY, AES_IV);
                let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
                serde_json::from_slice(unpadded).ok()
            })
        };
        let Some(v) = parsed else {
            last_err = "bad json".to_string();
            continue;
        };
        if get(&v, "code").and_then(|c| c.as_i64()) == Some(200) {
            *BASE_CACHE.lock().unwrap() = Some(base);
            return Ok(v);
        }
        last_err = format!(
            "code {} {}",
            get(&v, "code").map(|c| c.to_string()).unwrap_or_default(),
            get(&v, "msg").and_then(|m| m.as_str()).unwrap_or("")
        );
    }
    Err(ApiError::Internal(format!(
        "km2 no base worked: {last_err}"
    )))
}

fn keep(v: &Value) -> bool {
    if let Some(t) = get(v, "type").and_then(|x| x.as_f64()) {
        if t != 1.0 {
            return false;
        }
    }
    if let Some(g) = get(v, "gold").and_then(|x| x.as_f64()) {
        if g > 0.0 {
            return false;
        }
    }
    let vip = text_of(v, &["is_vip"]);
    vip.is_empty() || vip == "0"
}

fn card(v: &Value) -> Option<Value> {
    if !keep(v) {
        return None;
    }
    let id = text_of(v, &["id"]);
    let title = text_of(v, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    CACHE.lock().unwrap().insert(id.clone(), v.clone());
    let mut content = String::new();
    if let Some(p) = get(v, "praise_num").and_then(|x| x.as_f64()) {
        if p > 0.0 {
            content = format!("点赞 {}", p as i64);
        }
    }
    let mut it = item_json(
        &id,
        &title,
        &text_of(v, &["cover"]),
        &text_of(v, &["nickname"]),
    );
    it["content"] = json!(content);
    Some(it)
}

fn cards(arr: Option<&Vec<Value>>) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(arr) = arr {
        for v in arr {
            if let Some(c) = card(v) {
                out.push(c);
            }
        }
    }
    out
}

async fn list_for(type_id: i64, page: i64) -> ApiResult<Vec<Value>> {
    let resp = call(
        "/api/video/index",
        &[int_pair("page", page), int_pair("type", type_id)],
    )
    .await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let arr = arr_of(get(&data, "video_list").unwrap_or(&Value::Null))
        .or_else(|| arr_of(get(&data, "list").unwrap_or(&Value::Null)));
    Ok(cards(arr))
}

async fn info(id: &str) -> ApiResult<Value> {
    let id = match id.find('$') {
        Some(pos) => &id[pos + 1..],
        None => id,
    };
    let resp = call("/api/video/info", &[str_pair("video_id", id)]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    get(&data, "video_info")
        .cloned()
        .ok_or_else(|| ApiError::Internal("km2 no video_info".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let type_id = category_id.parse::<i64>().unwrap_or(3);
    let type_id = if (1..=3).contains(&type_id) {
        type_id
    } else {
        3
    };
    let items = match list_for(type_id, page).await {
        Ok(items) => items,
        Err(_) => Vec::new(),
    };
    let has_more = items.len() >= 10;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let info = match info(id).await {
        Ok(info) => info,
        Err(_) => {
            return Ok(
                json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}),
            );
        }
    };
    if let Some(g) = get(&info, "gold").and_then(|x| x.as_f64()) {
        if g > 0.0 {
            return Ok(
                json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}),
            );
        }
    }
    let mut title = text_of(&info, &["title"]);
    if title.is_empty() {
        title = CACHE
            .lock()
            .unwrap()
            .get(id)
            .map(|c| text_of(c, &["title"]))
            .unwrap_or_default();
    }
    if title.is_empty() {
        title = format!("视频{id}");
    }
    let nickname = text_of(&info, &["nickname"]);
    Ok(json!({
        "id": id, "title": title,
        "cover": text_of(&info, &["cover"]),
        "synopsis": "",
        "extra": {"vod_actor": nickname},
        "episodes": [episode_json(id, "正片", id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = query.to_lowercase();
    if q.is_empty() {
        return Ok(json!({"items": []}));
    }
    let mut items: Vec<Value> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for type_id in [3i64, 2, 1] {
        for page in 1..=5 {
            if items.len() >= 20 {
                break;
            }
            let Ok(list) = list_for(type_id, page).await else {
                continue;
            };
            for it in list {
                if items.len() >= 20 {
                    break;
                }
                let id = it["id"].as_str().unwrap_or("").to_string();
                if id.is_empty() || !seen.insert(id.clone()) {
                    continue;
                }
                let hay = format!(
                    "{} {}",
                    it["title"].as_str().unwrap_or(""),
                    it["remark"].as_str().unwrap_or("")
                )
                .to_lowercase();
                if hay.contains(&q) {
                    items.push(it);
                }
            }
        }
    }
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let info = info(video_id).await?;
    let mut url = text_of(&info, &["m3u8_url"]);
    if url.is_empty() {
        url = text_of(&info, &["normal_url"]);
    }
    if url.is_empty() {
        return Err(ApiError::Internal("km2 no stream url".into()));
    }
    let base = BASE_CACHE
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| FALLBACK_BASE.to_string());
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{base}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_quote_escapes() {
        assert_eq!(json_quote("a\"b\\c\td"), "\"a\\\"b\\\\c\\td\"");
        assert_eq!(json_quote("a\x01b"), "\"a\\u0001b\"");
    }

    #[test]
    fn md5_upper_known() {
        assert_eq!(md5_hex_upper(b"abc"), "900150983CD24FB0D6963F7D28E17F72");
    }

    #[test]
    fn form_data_roundtrip() {
        let pairs = vec![int_pair("page", 1), int_pair("type", 3)];
        let body = form_data(&pairs);
        assert!(body.starts_with("api_token=&data="));
        assert!(
            body.contains("&device=android&device_type=MI8&device_version=8.0.0&version_code=2")
        );
        // data 段为大写 hex，解密后应为签名 JSON。
        let data_enc = body
            .split("data=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap();
        let data_dec =
            url::form_urlencoded::byte_serialize(data_enc.as_bytes()).collect::<String>();
        let _ = data_dec;
        let raw = percent_decode(data_enc);
        let bytes = hex::decode(raw).unwrap();
        let plain = crate::crypto::aes_cbc_decrypt(&bytes, AES_KEY, AES_IV);
        let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
        let text = String::from_utf8(unpadded.to_vec()).unwrap();
        assert!(text.starts_with(r#"{"page":1,"type":3,"signature":""#));
    }

    fn percent_decode(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '%' {
                let h1 = chars.next().unwrap_or('0');
                let h2 = chars.next().unwrap_or('0');
                let v = u8::from_str_radix(&format!("{h1}{h2}"), 16).unwrap_or(b'%');
                out.push(v as char);
            } else if c == '+' {
                out.push(' ');
            } else {
                out.push(c);
            }
        }
        out
    }
}
