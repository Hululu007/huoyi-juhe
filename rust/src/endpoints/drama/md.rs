//! 麻豆：`https://spi.d5c4a712.com`。
//!
//! 来源 jar 类 `ZakaMdAmns`。UA 为 Chrome 126 Android Pixel 7；
//! `AES_KEY = "Vq234zBeSdGgYXzVTEfnnjjdmaTkk7A4"`（32 字节，AES-256）；
//! `IV_PREFIX = "-p9B[~PnPs"`；`SIGN_TAIL =
//! "&m}q%ea6:LDcmS?aK)CeF287bPvd99@E,9Up^"`。
//!
//! `call(path, params)`：TreeMap 复制参数并加 `timestamp = <当前毫秒
//! 时间戳字符串>`；签名串为 TreeMap 排序后 `k=v` 用 `&` 连接（首项前
//! 无 `&`），`encode_sign = MD5 小写 hex(<签名串> + SIGN_TAIL)`，加入
//! 参数表；把含 `encode_sign` 的全部参数拼成 JSON 对象字符串（排序后
//! 顺序）；`suffix = MD5 小写 hex(<当前毫秒时间戳>)` 的前 6 位；明文
//! JSON 按 PKCS7 填充；IV 为 `"-p9B[~PnPs" + suffix`（10+6=16 字节）；
//! AES/CBC/NoPadding 加密（密钥 AES_KEY），Base64 后 URLEncoder 编码；
//! POST body 为 `post-data=<编码>`；请求头 `suffix: <suffix>`、
//! `User-Agent`、`Content-Type: application/x-www-form-urlencoded`，
//! 30 秒超时，最多重试 3 次（失败睡 1 秒）；响应非 200 抛 `http <码>`；
//! `Content-Encoding` 含 gzip 时 gunzip；取响应 JSON 的 `data` 字段
//! （Base64）与 `suffix` 字段，用同一 IV（`IV_PREFIX + 响应 suffix`）
//! AES/CBC 解密并去 PKCS7，解析为 JSON 返回。
//!
//! 分类写死 61 类，按用户口径删其中 `63` “萝莉美少女”，其余照录（共
//! 60 类）。列表：`call("/video/listcache", {list_row: 60, page, type:
//! 2, channel: <分类>（latest 时不传）})`，取 `data.data[]`；卡片要求
//! `id` 与 `video_url` 均非空、标题取 `title` 否则 `description`；
//! `is_vip != 0` 的卡先排除，全空时才放回（含付费标记）；封面为 `thumb`
//! 包 `https://mdimg.ystv.top/img?u=<编码>`；备注为 `付费` 或 tags 的
//! `name` 用 `·` 连接；内容为 `description`；并写入进程缓存供详情/
//! 取流用；分页取 `data.total`/`data.last_page`。
//! 详情：只读缓存（标题/封面/简介/`video_url`/`is_vip`），付费或无
//! `video_url` 时 `vod_play_url` 为空，否则 `正片$<video_url>`；取流：
//! video_id 以 `http` 开头直通，否则查缓存的 `video_url`；头为 UA +
//! Referer `<base>/`。
//! 搜索：`call("/video/list", {list_row: "60", page, type: "2",
//! keyword: <词>})`，取 `data.data[]` 成卡，分页取 `total`/`last_page`。

use std::sync::Mutex;

use base64::Engine as _;
use md5::Digest as _;
use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BASE: &str = "https://spi.d5c4a712.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";
const AES_KEY: &[u8] = b"Vq234zBeSdGgYXzVTEfnnjjdmaTkk7A4";
const IV_PREFIX: &str = "-p9B[~PnPs";
const SIGN_TAIL: &str = "&m}q%ea6:LDcmS?aK)CeF287bPvd99@E,9Up^";

/// 分类：jar 原文 61 类，删 `63` “萝莉美少女”，余 60 类。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新"),
    ("21", "麻豆传媒映画"),
    ("101", "乐播传媒"),
    ("20", "91制作"),
    ("51", "91茄子"),
    ("23", "探花系列"),
    ("14", "SWAG"),
    ("39", "日本AV-4K"),
    ("38", "JVID"),
    ("40", "国产三级片"),
    ("41", "推特福利姬"),
    ("52", "恋脚癖"),
    ("64", "糖心"),
    ("65", "兔子先生"),
    ("74", "天美传媒"),
    ("75", "蜜桃传媒"),
    ("76", "皇家华人"),
    ("77", "杏吧原创"),
    ("80", "mini传媒"),
    ("81", "大象传媒"),
    ("82", "葫芦影业"),
    ("87", "91短视频"),
    ("33", "恐怖色情"),
    ("35", "人妖"),
    ("50", "高清动漫"),
    ("26", "性爱课堂"),
    ("27", "maomiav"),
    ("53", "AI换脸"),
    ("54", "Elise 兔兔"),
    ("55", "Pornhub"),
    ("56", "Team Skeet"),
    ("57", "Wow girls"),
    ("58", "不见星空"),
    ("59", "刘玥"),
    ("60", "国产直播"),
    ("61", "果冻传媒"),
    ("62", "精东影业"),
    ("66", "玩偶姐姐"),
    ("67", "网爆门事件"),
    ("68", "星空传媒"),
    ("69", "柚子猫"),
    ("70", "ASMR"),
    ("71", "Sxyporn"),
    ("72", "XVideos"),
    ("73", "Brazzers"),
    ("78", "AV解说"),
    ("79", "韩国R级"),
    ("83", "COSPLAY"),
    ("84", "拳交女王"),
    ("86", "周甄娜"),
    ("88", "猎奇系列"),
    ("91", "软萌伪娘"),
    ("93", "性爱娃娃"),
    ("94", "约炮小百科"),
    ("95", "xiao e"),
    ("96", "Vivian"),
    ("98", "海外直播"),
    ("15", "性视界传媒"),
    ("99", "爱豆传媒"),
    ("100", "香蕉视频"),
];

static CACHE: Lazy<Mutex<std::collections::HashMap<String, Value>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn md5_hex(data: &[u8]) -> String {
    let mut h = md5::Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

fn urlenc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

fn gunzip_if_needed(bytes: &[u8], encoding: &str) -> Vec<u8> {
    if encoding.to_lowercase().contains("gzip") {
        if let Some(v) = crate::crypto::gunzip(bytes) {
            return v;
        }
    }
    bytes.to_vec()
}

async fn call(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let ts = now_ms().to_string();
    let mut map: Vec<(String, String)> = params.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    map.push(("timestamp".to_string(), ts.clone()));
    map.sort_by(|a, b| a.0.cmp(&b.0));
    let sign_str = map
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&");
    let encode_sign = md5_hex(format!("{sign_str}{SIGN_TAIL}").as_bytes());
    map.push(("encode_sign".to_string(), encode_sign));
    map.sort_by(|a, b| a.0.cmp(&b.0));
    let mut body_json = serde_json::Map::new();
    for (k, v) in &map {
        body_json.insert(k.clone(), json!(v));
    }
    let plain = Value::Object(body_json).to_string();
    let suffix = md5_hex(ts.as_bytes())[..6].to_string();
    let iv = format!("{IV_PREFIX}{suffix}");
    let padded = crate::crypto::pkcs7_pad(plain.as_bytes(), 16);
    let cipher = crate::crypto::aes_cbc_encrypt(&padded, AES_KEY, iv.as_bytes());
    let post_data = urlenc(&base64::engine::general_purpose::STANDARD.encode(cipher));
    let form = format!("post-data={post_data}");
    let url = format!("{BASE}{path}");
    let mut last_err = String::new();
    for _ in 0..3 {
        let resp = match client() {
            Ok(c) => c
                .post(&url)
                .header("suffix", suffix.clone())
                .header("User-Agent", UA)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(form.clone())
                .send()
                .await
                .map_err(|e| format!("http {e}")),
            Err(e) => Err(format!("{e}")),
        };
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = e;
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }
        };
        if !resp.status().is_success() {
            last_err = format!("http {}", resp.status());
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            continue;
        }
        let encoding = resp
            .headers()
            .get("content-encoding")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        let Ok(bytes) = resp.bytes().await else {
            last_err = "empty body".to_string();
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            continue;
        };
        let bytes = gunzip_if_needed(&bytes, &encoding);
        let v: Value = match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(e) => {
                last_err = format!("json {e}");
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }
        };
        let data_b64 = text_of(&v, &["data"]);
        let resp_suffix = text_of(&v, &["suffix"]);
        if data_b64.is_empty() {
            return Ok(v);
        }
        let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(data_b64.as_bytes()) else {
            return Err(ApiError::Internal("md data b64".into()));
        };
        if raw.is_empty() || raw.len() % 16 != 0 {
            return Err(ApiError::Internal("md data len".into()));
        }
        let iv2 = format!("{IV_PREFIX}{resp_suffix}");
        let plain = crate::crypto::aes_cbc_decrypt(&raw, AES_KEY, iv2.as_bytes());
        let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
        let out: Value = serde_json::from_slice(unpadded)
            .map_err(|e| ApiError::Internal(format!("md decrypt json: {e}")))?;
        return Ok(out);
    }
    Err(ApiError::Internal(format!("md call failed: {last_err}")))
}

fn cover(thumb: &str) -> String {
    if thumb.is_empty() {
        return String::new();
    }
    format!("https://mdimg.ystv.top/img?u={}", urlenc(thumb))
}

fn card(v: &Value) -> Option<Value> {
    let id = text_of(v, &["id"]);
    let video_url = text_of(v, &["video_url"]);
    if id.is_empty() || video_url.is_empty() {
        return None;
    }
    let mut title = text_of(v, &["title"]);
    if title.is_empty() {
        title = text_of(v, &["description"]);
    }
    let paid = int_of(v, &["is_vip"]) != 0;
    let remark = if paid {
        "付费".to_string()
    } else {
        arr_of(get(v, "tags").unwrap_or(&Value::Null))
            .map(|a| {
                a.iter()
                    .map(|t| text_of(t, &["name"]))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
            .join("·")
    };
    CACHE.lock().unwrap().insert(id.clone(), v.clone());
    let mut it = item_json(&id, &title, &cover(&text_of(v, &["thumb"])), &remark);
    it["content"] = json!(text_of(v, &["description"]));
    Some(it)
}

fn cards_from(resp: &Value) -> (Vec<Value>, i64, i64) {
    let data = get(resp, "data").cloned().unwrap_or(Value::Null);
    let arr = arr_of(get(&data, "data").unwrap_or(&Value::Null))
        .cloned()
        .unwrap_or_default();
    let total = int_of(&data, &["total"]);
    let last_page = int_of(&data, &["last_page"]);
    let mut free: Vec<Value> = Vec::new();
    let mut paid: Vec<Value> = Vec::new();
    for v in &arr {
        if int_of(v, &["is_vip"]) != 0 {
            if let Some(c) = card(v) {
                paid.push(c);
            }
        } else if let Some(c) = card(v) {
            free.push(c);
        }
    }
    let items = if free.is_empty() { paid } else { free };
    (items, total, last_page)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let page_s = page.to_string();
    let mut params: Vec<(&str, &str)> = vec![("list_row", "60"), ("page", &page_s), ("type", "2")];
    if category_id != "latest" {
        params.push(("channel", category_id));
    }
    let resp = match call("/video/listcache", &params).await {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": [], "has_more": false})),
    };
    let (items, _total, last_page) = cards_from(&resp);
    let has_more = if last_page > 0 { page < last_page } else { !items.is_empty() };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let cached = CACHE.lock().unwrap().get(id).cloned();
    let Some(v) = cached else {
        return Ok(json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}));
    };
    let title = {
        let t = text_of(&v, &["title"]);
        if t.is_empty() {
            text_of(&v, &["description"])
        } else {
            t
        }
    };
    let video_url = text_of(&v, &["video_url"]);
    let paid = int_of(&v, &["is_vip"]) != 0;
    let mut episodes: Vec<Value> = Vec::new();
    if !paid && !video_url.is_empty() {
        episodes.push(episode_json(&video_url, "正片", id));
    }
    Ok(json!({
        "id": id, "title": title,
        "cover": cover(&text_of(&v, &["thumb"])),
        "synopsis": text_of(&v, &["description"]),
        "extra": {"is_vip": paid},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let page_s = "1".to_string();
    let params: Vec<(&str, &str)> = vec![
        ("list_row", "60"),
        ("page", &page_s),
        ("type", "2"),
        ("keyword", query),
    ];
    let resp = match call("/video/list", &params).await {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": []})),
    };
    let (items, _, _) = cards_from(&resp);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }));
    }
    let cached = CACHE.lock().unwrap().get(video_id).cloned();
    let Some(v) = cached else {
        return Err(ApiError::Internal("md video not in cache".into()));
    };
    let url = text_of(&v, &["video_url"]);
    if url.is_empty() {
        return Err(ApiError::Internal("md no video_url".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_sixty_after_delete() {
        assert_eq!(CATS.len(), 60);
        assert!(!CATS.iter().any(|(id, _)| *id == "63"));
    }

    #[test]
    fn suffix_is_six_hex() {
        let s = md5_hex(b"1234567890123");
        assert_eq!(s.len(), 32);
        assert_eq!(&s[..6], &md5_hex(b"1234567890123")[..6]);
    }

    #[test]
    fn card_paid_fallback() {
        let v: Value = serde_json::from_str(
            r#"{"id":"9","video_url":"https://x/v.m3u8","title":"t","thumb":"th","is_vip":1,"tags":[{"name":"a"},{"name":"b"}],"description":"d"}"#,
        )
        .unwrap();
        let c = card(&v).unwrap();
        assert_eq!(c["remark"], "付费");
        assert_eq!(c["cover"], "https://mdimg.ystv.top/img?u=th");
    }
}
