//! sex8：视频 + 有声电台。
//!
//! 来源 jar 类 `ZakaSex8Amns`。基址 `https://kongsjieie.bar/`，UA
//! `okhttp/4.9.0`，头 `APPIMAGE: 100`、`VERSIONNAME: 1.0.0`、
//! `Accept: application/json, text/plain, */*`。
//!
//! 加密 AES/CBC/NoPadding，`KEY=Af234dfdf0io@#$*`、`IV=1234567890123456`；
//! `dec`：以 `{` 开头的明文直通，否则 Base64 解码（长度须为 16 倍数）
//! 再解密去尾空白；`radioEnc`：零填充到 16 倍数后加密再 Base64（NO_WRAP）。
//! 电台接口 POST `http://radioluntan.space/apiv286.php?0=<毫秒时间戳>`，
//! body 为 `request=<URLEncoder 编码的 radioEnc(JSON)>`，
//! `Content-Type: application/x-www-form-urlencoded`；响应解密后要求
//! `status` 为空或 `"1"`。
//!
//! 分类写死 9 类：`video` 视频、`audio:rank:recommand/hot/new/host`
//! 排行·推荐/热门/最新/主播、`audio:long/short/mic/other` 有声·长篇/
//! 短篇/骚麦/其他。视频分类 GET `/v1/video/index/free/data`（响应整体
//! 经 `dec` 解密），取 `data.models[]`，只留免费（`is_free` 为 `1` /
//! `true` / 空，且 `price` 为空 / `0` / `0.00000` 或不大于 0），卡片
//! `vod_id=v:<tid>`、标题 `subject`、封面 `images[0]`、备注
//! `author · <views>播放`；仅第 1 页有内容。视频详情查缓存，
//! `vod_play_url=正片$v:<tid>`；取流直接取该 model 的 `video_url`，
//! parse 0 + UA + Referer `https://kongsjieie.bar/`。
//!
//! 音频详情：专辑 `a:<album_id>` 经 `radio({v: radio_album_info,
//! album_id, device_type: "1"})` 取 `data`，只留免费集
//! （`radio_list[]`，`radio_id` 非空且非付费），分集 video_id 为
//! `ep:<album_id>:<radio_id>`；取流经 `radio({v: album_radio,
//! album_id, radio_id, op: 0, device_type: "1"})`，在
//! `data.radio_list[]` 中找同 `radio_id` 的 `url`（无则取 `data.url`），
//! 付费集拒绝。
//!
//! 注意：Java 的 `searchContent` 原样返回空列表，无服务端搜索；本模
//! 块的 `search` 按本地过滤实现（在 `videoModels()` 结果里按标题含
//! 关键词过滤），与 jar 空搜索不同，属改动。

use std::sync::Mutex;

use base64::Engine as _;
use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://kongsjieie.bar/";
const UA: &str = "okhttp/4.9.0";
const RADIO_URL: &str = "http://radioluntan.space/apiv286.php";
const AES_KEY: &[u8] = b"Af234dfdf0io@#$*";
const AES_IV: &[u8] = b"1234567890123456";

const CATS: &[(&str, &str)] = &[
    ("video", "视频"),
    ("audio:rank:recommand", "排行·推荐"),
    ("audio:rank:hot", "排行·热门"),
    ("audio:rank:new", "排行·最新"),
    ("audio:rank:host", "排行·主播"),
    ("audio:long", "有声·长篇"),
    ("audio:short", "有声·短篇"),
    ("audio:mic", "有声·骚麦"),
    ("audio:other", "有声·其他"),
];

static MODELS_CACHE: Lazy<Mutex<Option<Vec<Value>>>> = Lazy::new(|| Mutex::new(None));

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// `dec`：以 `{` 开头的明文直通，否则 Base64 解码（长度须为 16 倍数）
//  再 AES/CBC/NoPadding 解密去尾空白。
fn dec(s: &str) -> String {
    let t = s.trim();
    if t.starts_with('{') {
        return t.to_string();
    }
    let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(t.as_bytes()) else {
        return t.to_string();
    };
    if raw.len() % 16 != 0 {
        return t.to_string();
    }
    let plain = crate::crypto::aes_cbc_decrypt(&raw, AES_KEY, AES_IV);
    String::from_utf8_lossy(&plain).trim().to_string()
}

/// `radioEnc`：零填充到 16 倍数后 AES/CBC/NoPadding 加密再 Base64。
fn radio_enc(s: &str) -> String {
    let bytes = s.as_bytes();
    let pad = 16 - (bytes.len() % 16);
    let mut buf = bytes.to_vec();
    buf.extend(std::iter::repeat_n(0u8, pad));
    let cipher = crate::crypto::aes_cbc_encrypt(&buf, AES_KEY, AES_IV);
    base64::engine::general_purpose::STANDARD.encode(cipher)
}

async fn get_text(url: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .header("APPIMAGE", "100")
        .header("VERSIONNAME", "1.0.0")
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.text().await.ok()
}

/// `radio(body)`：POST 电台接口，响应解密后要求 `status` 为空或 `"1"`。
async fn radio(body: &Value) -> ApiResult<Value> {
    let enc = radio_enc(&body.to_string());
    let form = format!(
        "request={}",
        url::form_urlencoded::byte_serialize(enc.as_bytes()).collect::<String>()
    );
    let url = format!("{RADIO_URL}?0={}", now_ms());
    let resp = client()?
        .post(&url)
        .header("User-Agent", UA)
        .header("APPIMAGE", "100")
        .header("VERSIONNAME", "1.0.0")
        .header("Accept", "application/json, text/plain, */*")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(form)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("sex8 radio http: {e}")))?;
    if !resp.status().is_success() {
        return Err(ApiError::Internal(format!(
            "sex8 radio http {}",
            resp.status()
        )));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("sex8 radio body: {e}")))?;
    let plain = dec(&text);
    let v: Value = serde_json::from_str(&plain)
        .map_err(|e| ApiError::Internal(format!("sex8 radio json: {e}")))?;
    let status = v
        .get("status")
        .map(|s| s.as_str().unwrap_or("").to_string())
        .unwrap_or_default();
    if status.is_empty() || status == "1" {
        Ok(v)
    } else {
        Err(ApiError::Internal(format!("sex8 radio status {status}")))
    }
}

fn is_paid(v: &Value) -> bool {
    let free = text_of(v, &["is_free"]);
    if !free.is_empty() && free != "1" && !free.eq_ignore_ascii_case("true") {
        return true;
    }
    let price = text_of(v, &["price"]);
    if price.is_empty() || price == "0" || price == "0.00000" {
        return false;
    }
    price.parse::<f64>().map(|n| n > 0.0).unwrap_or(false)
}

fn video_card(v: &Value) -> Option<Value> {
    let tid = text_of(v, &["tid"]);
    let title = text_of(v, &["subject"]);
    if tid.is_empty() || title.is_empty() {
        return None;
    }
    let cover = arr_of(get(v, "images").unwrap_or(&Value::Null))
        .and_then(|a| a.first().map(|x| x.as_str().unwrap_or("").to_string()))
        .unwrap_or_default();
    let author = text_of(v, &["author"]);
    let views = text_of(v, &["views"]);
    let remark = if views.is_empty() {
        author
    } else if author.is_empty() {
        format!("{views}播放")
    } else {
        format!("{author} · {views}播放")
    };
    Some(item_json(&format!("v:{tid}"), &title, &cover, &remark))
}

async fn video_models() -> ApiResult<Vec<Value>> {
    {
        let guard = MODELS_CACHE.lock().unwrap();
        if let Some(models) = guard.as_ref() {
            return Ok(models.clone());
        }
    }
    let text = get_text("https://kongsjieie.bar/v1/video/index/free/data")
        .await
        .ok_or_else(|| ApiError::Internal("sex8 video index empty".into()))?;
    let plain = dec(&text);
    let v: Value = serde_json::from_str(&plain)
        .map_err(|e| ApiError::Internal(format!("sex8 video json: {e}")))?;
    let models = get(&v, "data")
        .and_then(|d| arr_of(get(d, "models").unwrap_or(&Value::Null)))
        .cloned()
        .unwrap_or_default();
    let mut guard = MODELS_CACHE.lock().unwrap();
    *guard = Some(models.clone());
    Ok(models)
}

fn find_model(models: &[Value], tid: &str) -> Option<Value> {
    models
        .iter()
        .find(|m| text_of(m, &["tid"]) == tid)
        .cloned()
}

fn album_card(v: &Value) -> Option<Value> {
    let id = text_of(v, &["radio_album_id"]);
    let name = text_of(v, &["name"]);
    if id.is_empty() || name.is_empty() {
        return None;
    }
    let cover = text_of(v, &["cover_img"]);
    let cover = if cover.is_empty() {
        text_of(v, &["album_img"])
    } else {
        cover
    };
    let host = text_of(v, &["host_name"]);
    let host = if host.is_empty() {
        text_of(v, &["host"])
    } else {
        host
    };
    let count = text_of(v, &["radio_count"]);
    let count_part = if count.is_empty() {
        String::new()
    } else {
        format!("{count}集")
    };
    let remark = if host.is_empty() {
        count_part
    } else if count_part.is_empty() {
        host
    } else {
        format!("{count_part} · {host}")
    };
    Some(item_json(&format!("a:{id}"), &name, &cover, &remark))
}

/// `albumList(body, page)`：body 加 `page` 与 `page_size: "10"` 后
/// `radio`，逐条 `albumCard`。
async fn album_list(body: Value, page: i64) -> ApiResult<Vec<Value>> {
    let mut body = body;
    if let Some(o) = body.as_object_mut() {
        o.insert("page".to_string(), json!(page));
        o.insert("page_size".to_string(), json!("10"));
    }
    let resp = radio(&body).await?;
    let mut out = Vec::new();
    if let Some(arr) = arr_of(get(&resp, "data").unwrap_or(&Value::Null)) {
        for v in arr {
            if let Some(card) = album_card(v) {
                out.push(card);
            }
        }
    }
    Ok(out)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if category_id == "video" {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let models = video_models().await?;
        let mut items = Vec::new();
        for m in &models {
            if !is_paid(m) {
                if let Some(card) = video_card(m) {
                    items.push(card);
                }
            }
        }
        return Ok(json!({"items": items, "has_more": false}));
    }
    // 音频分类。
    if category_id == "audio:rank:host" {
        let body = json!({"v": "rankhost_list", "page": page, "page_size": "10"});
        let resp = radio(&body).await?;
        let mut items = Vec::new();
        if let Some(arr) = arr_of(get(&resp, "data").unwrap_or(&Value::Null)) {
            for v in arr {
                let host_id = text_of(v, &["host_id"]);
                let name = text_of(v, &["name"]);
                if host_id.is_empty() || name.is_empty() {
                    continue;
                }
                let img = text_of(v, &["img"]);
                let hits = text_of(v, &["hits_count"]);
                let remark = if hits.is_empty() {
                    String::new()
                } else {
                    format!("{hits}人气")
                };
                items.push(item_json(&format!("dir:host:{host_id}"), &name, &img, &remark));
            }
        }
        let has_more = items.len() == 10;
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    if let Some(id) = category_id.strip_prefix("dir:host:") {
        let body = json!({"v": "radio_by_hostid", "hostid": id});
        let items = album_list(body, page).await?;
        let has_more = items.len() == 10;
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    if let Some(t) = category_id.strip_prefix("audio:rank:") {
        let body = json!({"v": "rank_list", "type": t});
        let items = album_list(body, page).await?;
        let has_more = items.len() == 10;
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    let category = match category_id {
        "audio:long" => "erotic_long",
        "audio:short" => "erotic_short",
        "audio:mic" => "passion_mic",
        "audio:other" => "other",
        _ => "",
    };
    let body = json!({"v": "radio_album_list", "type": "new", "category": category, "child_category": ""});
    let items = album_list(body, page).await?;
    let has_more = items.len() == 10;
    Ok(json!({"items": items, "has_more": has_more}))
}

async fn album_info(album_id: &str) -> ApiResult<Value> {
    let body = json!({"v": "radio_album_info", "album_id": album_id, "device_type": "1"});
    let resp = radio(&body).await?;
    get(&resp, "data")
        .cloned()
        .ok_or_else(|| ApiError::Internal("sex8 album empty".into()))
}

fn free_audio_eps(info: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(arr) = arr_of(get(info, "radio_list").unwrap_or(&Value::Null)) {
        for v in arr {
            if !is_paid(v) && !text_of(v, &["radio_id"]).is_empty() {
                out.push(v.clone());
            }
        }
    }
    out
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(tid) = id.strip_prefix("v:") {
        let models = video_models().await?;
        let Some(m) = find_model(&models, tid) else {
            return Ok(json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}));
        };
        let title = text_of(&m, &["subject"]);
        let cover = arr_of(get(&m, "images").unwrap_or(&Value::Null))
            .and_then(|a| a.first().map(|x| x.as_str().unwrap_or("").to_string()))
            .unwrap_or_default();
        let author = text_of(&m, &["author"]);
        return Ok(json!({
            "id": id, "title": title, "cover": cover, "synopsis": "",
            "extra": {"vod_actor": author},
            "episodes": [episode_json(&format!("v:{tid}"), "正片", id)],
        }));
    }
    if let Some(album_id) = id.strip_prefix("a:") {
        let info = album_info(album_id).await?;
        let title = text_of(&info, &["name"]);
        let cover = text_of(&info, &["cover_img"]);
        let cover = if cover.is_empty() {
            text_of(&info, &["album_img"])
        } else {
            cover
        };
        let eps = free_audio_eps(&info);
        let mut episodes: Vec<Value> = Vec::new();
        for (i, ep) in eps.iter().enumerate() {
            let rid = text_of(ep, &["radio_id"]);
            let name = text_of(ep, &["name"]);
            let name = if name.is_empty() {
                format!("第{}集", i + 1)
            } else {
                name
            };
            episodes.push(episode_json(&format!("ep:{album_id}:{rid}"), &name, id));
        }
        return Ok(json!({
            "id": id, "title": title, "cover": cover, "synopsis": "",
            "extra": {}, "episodes": episodes,
        }));
    }
    if let Some(host_id) = id.strip_prefix("dir:host:") {
        let body = json!({"v": "radio_by_hostid", "hostid": host_id});
        let items = album_list(body, 1).await?;
        let mut episodes: Vec<Value> = Vec::new();
        for it in &items {
            let aid = it["id"].as_str().unwrap_or("");
            let name = it["title"].as_str().unwrap_or("");
            episodes.push(episode_json(aid, name, id));
        }
        return Ok(json!({
            "id": id, "title": "", "cover": "", "synopsis": "",
            "extra": {}, "episodes": episodes,
        }));
    }
    Err(ApiError::BadRequest("bad sex8 id".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    // Java 原样返回空列表；此处按本地过滤实现（见模块头注释）。
    let models = video_models().await?;
    let q = query.to_lowercase();
    let mut items = Vec::new();
    for m in &models {
        if is_paid(m) {
            continue;
        }
        let title = text_of(m, &["subject"]);
        if title.to_lowercase().contains(&q) {
            if let Some(card) = video_card(m) {
                items.push(card);
            }
        }
    }
    Ok(json!({"items": items}))
}

async fn resolve_ep(album_id: &str, radio_id: &str) -> ApiResult<String> {
    let body = json!({"v": "album_radio", "album_id": album_id, "radio_id": radio_id, "op": 0, "device_type": "1"});
    let resp = radio(&body).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    if let Some(arr) = arr_of(get(&data, "radio_list").unwrap_or(&Value::Null)) {
        for v in arr {
            if text_of(v, &["radio_id"]) == radio_id {
                let url = text_of(v, &["url"]);
                if !url.is_empty() {
                    return Ok(url);
                }
            }
        }
    }
    let url = text_of(&data, &["url"]);
    if url.is_empty() {
        return Err(ApiError::Internal("sex8 no audio url".into()));
    }
    Ok(url)
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(tid) = video_id.strip_prefix("v:") {
        let models = video_models().await?;
        let Some(m) = find_model(&models, tid) else {
            return Err(ApiError::Internal("sex8 video not found".into()));
        };
        let url = text_of(&m, &["video_url"]);
        if url.is_empty() {
            return Err(ApiError::Internal("sex8 no video_url".into()));
        }
        return Ok(json!({
            "url": url,
            "header": {"User-Agent": UA, "Referer": BASE},
        }));
    }
    if let Some(rest) = video_id.strip_prefix("ep:") {
        let parts: Vec<&str> = rest.splitn(2, ':').collect();
        if parts.len() != 2 {
            return Err(ApiError::BadRequest("bad sex8 episode id".into()));
        }
        let (album_id, radio_id) = (parts[0], parts[1]);
        // 付费集拒绝：先查专辑免费集。
        let info = album_info(album_id).await?;
        let eps = free_audio_eps(&info);
        if !eps.iter().any(|e| text_of(e, &["radio_id"]) == radio_id) {
            return Err(ApiError::Internal("sex8 paid episode refused".into()));
        }
        let url = resolve_ep(album_id, radio_id).await?;
        return Ok(json!({
            "url": url,
            "header": {"User-Agent": UA, "Referer": BASE},
        }));
    }
    Err(ApiError::BadRequest("bad sex8 video id".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_paid_rules() {
        let free: Value = serde_json::from_str(r#"{"is_free":"1","price":"0"}"#).unwrap();
        assert!(!is_paid(&free));
        let free2: Value = serde_json::from_str(r#"{"is_free":"","price":"0.00000"}"#).unwrap();
        assert!(!is_paid(&free2));
        let paid: Value = serde_json::from_str(r#"{"is_free":"0","price":""}"#).unwrap();
        assert!(is_paid(&paid));
        let paid2: Value = serde_json::from_str(r#"{"is_free":"1","price":"9.9"}"#).unwrap();
        assert!(is_paid(&paid2));
    }

    #[test]
    fn radio_enc_roundtrip() {
        let plain = "hello world test";
        let enc = radio_enc(plain);
        let raw = base64::engine::general_purpose::STANDARD
            .decode(enc.as_bytes())
            .unwrap();
        assert_eq!(raw.len() % 16, 0);
        let back = crate::crypto::aes_cbc_decrypt(&raw, AES_KEY, AES_IV);
        assert_eq!(&back[..plain.len()], plain.as_bytes());
    }

    #[test]
    fn album_card_remark() {
        let v: Value = serde_json::from_str(
            r#"{"radio_album_id":"5","name":"专辑","cover_img":"c","host_name":"主播","radio_count":"12"}"#,
        )
        .unwrap();
        let card = album_card(&v).unwrap();
        assert_eq!(card["id"], "a:5");
        assert_eq!(card["remark"], "12集 · 主播");
    }
}
