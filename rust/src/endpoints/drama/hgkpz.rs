//! 黄瓜看片（dykt1d.gyjwazo.cn，2026-11-06 复验：旧域 huanguaa.jykvyq.cn TLS 已断）：游客注册 + AES-ECB 解包。
//!
//! - 与 wnzs 同后端家族（同款 AES-ECB 密钥、同款注册流程），
//!   但注册路径是 /api/vip/v1/ai/register（带 vip/v1），appkey
//!   为空；直接用默认域名，无 ext 的 TXT 换域名通道。
//! - unwrap：明文 JSON 直通；含 Not Found 返回空；否则 base64
//!   解码 → AES-128-ECB 解密 → UTF-8。
//! - 注册：unique_code = tvbox + 毫秒时间戳低 32 位十六进制；
//!   username 随机 10 位、passwd 随机 12 位（a-z0-9）；POST
//!   /api/vip/v1/ai/register，取 data.token。注册返回 code=200。
//! - apiGet：GET {base}{path}?appkey=&accessToken={token}&参数；
//!   code 401/403 时清 token、重注册、重试一次。
//! - 分类：GET /api/vip/v1/video/index 的 data.cateParentList，
//!   id 为 cate_<pid>，最前加 new 最新入库；分类按站原样写，不过滤。
//! - 封面传原始 enpic：封面字节可能经 XOR -120 混淆，本文件
//!   不做本地代理还原。

use std::sync::Mutex;
use std::time::Instant;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const BASE: &str = "https://dykt1d.gyjwazo.cn";
const UA: &str = "okhttp/4.9.3";
const AES_KEY: &[u8] = b"=^%7@84%0^!8892-";

static TOKEN_CACHE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

fn aes_ecb_decrypt(data: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if key.len() < 16 || data.len() % 16 != 0 {
        return None;
    }
    let cipher = aes::Aes128::new(GenericArray::from_slice(&key[..16]));
    let mut out = Vec::with_capacity(data.len());
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    if out.is_empty() {
        return None;
    }
    let pad = out[out.len() - 1] as usize;
    if (1..=16).contains(&pad)
        && pad <= out.len()
        && out[out.len() - pad..].iter().all(|&b| b as usize == pad)
    {
        out.truncate(out.len() - pad);
    }
    Some(out)
}

fn unwrap(text: &str) -> Value {
    let t = text.trim();
    if t.is_empty() || t.contains("Not Found") {
        return Value::Null;
    }
    if t.starts_with('{') || t.starts_with('[') {
        return serde_json::from_str(t).unwrap_or(Value::Null);
    }
    use base64::Engine;
    let raw = match base64::engine::general_purpose::STANDARD.decode(t) {
        Ok(b) => b,
        Err(_) => return Value::Null,
    };
    match aes_ecb_decrypt(&raw, AES_KEY) {
        Some(plain) => match String::from_utf8(plain) {
            Ok(s) => serde_json::from_str(s.trim()).unwrap_or(Value::Null),
            Err(_) => Value::Null,
        },
        None => Value::Null,
    }
}

fn data_of(body: &Value) -> Value {
    match get(body, "data") {
        Some(d) => d.clone(),
        None => body.clone(),
    }
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄瓜请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn rand_str(n: usize) -> String {
    use rand::Rng;
    const CHARSET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    (0..n)
        .map(|_| CHARSET[rng.gen_range(0..CHARSET.len())] as char)
        .collect()
}

/// 注册拿 token：POST /api/vip/v1/ai/register。
async fn register() -> ApiResult<String> {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u32)
        .unwrap_or(0);
    let unique = format!("tvbox{:08x}", ms & 0xffffffff);
    let body = json!({
        "username": rand_str(10),
        "passwd": rand_str(12),
        "unique_code": unique,
        "model": "ios",
        "channelCode": "293",
    });
    let resp = client()?
        .post(format!("{BASE}/api/vip/v1/ai/register"))
        .header("User-Agent", UA)
        .header("Content-Type", "application/json; charset=utf-8")
        .json(&body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄瓜注册 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body = unwrap(&text);
    let token = text_of(&data_of(&body), &["token"]);
    if token.is_empty() {
        return Err(ApiError::Internal("黄瓜注册未返回 token".into()));
    }
    if let Ok(mut guard) = TOKEN_CACHE.lock() {
        *guard = Some((token.clone(), Instant::now()));
    }
    Ok(token)
}

async fn token() -> ApiResult<String> {
    if let Ok(guard) = TOKEN_CACHE.lock() {
        if let Some((t, _)) = guard.as_ref() {
            if !t.is_empty() {
                return Ok(t.clone());
            }
        }
    }
    register().await
}

async fn api_get(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let token = token().await?;
    let mut all: Vec<(String, String)> = vec![
        ("appkey".to_string(), String::new()),
        ("accessToken".to_string(), token),
    ];
    for (k, v) in params {
        all.push((k.to_string(), v.to_string()));
    }
    let refs: Vec<(&str, &str)> = all.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let url = with_query(&format!("{BASE}{path}"), &refs);
    let mut body = unwrap(&get_text(&url).await?);
    let code = int_of(&body, &["code"]);
    if body.is_null() || code == 401 || code == 403 {
        if let Ok(mut guard) = TOKEN_CACHE.lock() {
            *guard = None;
        }
        let token2 = register().await?;
        let mut all2: Vec<(String, String)> = vec![
            ("appkey".to_string(), String::new()),
            ("accessToken".to_string(), token2),
        ];
        for (k, v) in params {
            all2.push((k.to_string(), v.to_string()));
        }
        let refs2: Vec<(&str, &str)> = all2.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let url2 = with_query(&format!("{BASE}{path}"), &refs2);
        body = unwrap(&get_text(&url2).await?);
    }
    Ok(body)
}

async fn api_post(path: &str, body: Value) -> ApiResult<Value> {
    let token = token().await?;
    let url = with_query(
        &format!("{BASE}{path}"),
        &[("appkey", ""), ("accessToken", token.as_str())],
    );
    let mut text = post_json(&url, &body).await?;
    let mut parsed = unwrap(&text);
    let code = int_of(&parsed, &["code"]);
    if parsed.is_null() || code == 401 || code == 403 {
        if let Ok(mut guard) = TOKEN_CACHE.lock() {
            *guard = None;
        }
        let token2 = register().await?;
        let url2 = with_query(
            &format!("{BASE}{path}"),
            &[("appkey", ""), ("accessToken", token2.as_str())],
        );
        text = post_json(&url2, &body).await?;
        parsed = unwrap(&text);
    }
    Ok(parsed)
}

async fn post_json(url: &str, body: &Value) -> ApiResult<String> {
    let resp = client()?
        .post(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Content-Type", "application/json; charset=utf-8")
        .json(body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄瓜请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// pickList：对象取其 data[]；数组取每项的 videoList[] 展平。
fn pick_list(data: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(arr) = arr_of(data) {
        for item in arr {
            if let Some(vl) = get(item, "videoList").and_then(arr_of) {
                out.extend(vl.iter().cloned());
            }
        }
    } else if let Some(arr) = get(data, "data").and_then(arr_of) {
        out.extend(arr.iter().cloned());
    }
    out
}

fn card(v: &Value) -> Option<Value> {
    let vid = text_of(v, &["vid"]);
    if vid.is_empty() {
        return None;
    }
    let name = text_of(v, &["vod_name", "title", "name"]);
    let pic = text_of(v, &["enpic", "vod_pic", "cover"]);
    let duration = text_of(v, &["duration"]);
    let eyes = int_of(v, &["eyes"]);
    let mut remark = duration;
    if eyes > 0 {
        remark.push_str(&format!(" · 🔥{eyes}"));
    }
    Some(item_json(&vid, &name, &pic, &remark))
}

fn cards_of(data: &Value) -> Vec<Value> {
    pick_list(data).iter().filter_map(card).collect()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![category_json("new", "🔥最新入库")];
    if let Ok(body) = api_get("/api/vip/v1/video/index", &[]).await {
        let data = data_of(&body);
        if let Some(parents) = get(&data, "cateParentList").and_then(arr_of) {
            for p in parents {
                let title = text_of(p, &["title"]);
                if title.is_empty() {
                    continue;
                }
                let pid = text_of(p, &["cate_pid"]);
                if pid.is_empty() {
                    continue;
                }
                list.push(category_json(&format!("cate_{pid}"), &title));
            }
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page_s = page.to_string();
    let body = if category_id == "new" {
        api_get(
            "/api/vip/v1/video/newVideoList",
            &[("page", page_s.as_str()), ("limit", "24")],
        )
        .await?
    } else {
        let pid = category_id.strip_prefix("cate_").unwrap_or(category_id);
        api_get(
            "/api/vip/v1/video/cateVideoList",
            &[
                ("page", page_s.as_str()),
                ("limit", "24"),
                ("cate_pid", pid),
            ],
        )
        .await?
    };
    let data = data_of(&body);
    let items = cards_of(&data);
    let total = int_of(&data, &["total"]);
    let has_more = if total > 0 {
        page < (total + 23) / 24
    } else {
        items.len() >= 24
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let body = api_get("/api/vip/v1/video/detail", &[("vid", series_id)]).await?;
    let data = data_of(&body);
    let video = match get(&data, "video") {
        Some(v) => v.clone(),
        None => data.clone(),
    };
    let title = text_of(&video, &["vod_name", "title", "name"]);
    let play_url = text_of(&video, &["play_url"]);
    let pic = text_of(&video, &["enpic", "vod_pic", "cover"]);
    let from = text_of(&video, &["vod_play_from"]);
    let from = if from.is_empty() {
        "黄瓜".to_string()
    } else {
        from
    };
    let update = text_of(&video, &["update_time"]);
    let year = if update.len() >= 4 { &update[..4] } else { "" };
    let duration = text_of(&video, &["duration"]);
    let eyes = int_of(&video, &["eyes"]);
    let mut episodes = Vec::new();
    if !play_url.is_empty() {
        episodes.push(episode_json(&play_url, &title, series_id));
    }
    if let Some(rel) = get(&data, "relatedVideoList") {
        for v in pick_list(rel).iter().take(12) {
            let vid = text_of(v, &["vid"]);
            let name = text_of(v, &["vod_name", "title", "name"]);
            if vid.is_empty() || name.is_empty() {
                continue;
            }
            episodes.push(episode_json(&vid, &name, series_id));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(series_id, "正片", series_id));
    }
    let mut syn = String::from("站源：黄瓜看片，游客注册取流\n取流：详情接口直出 play_url");
    if !year.is_empty() {
        syn.push_str(&format!("\n年份：{year}"));
    }
    if !duration.is_empty() {
        syn.push_str(&format!("\n时长：{duration}"));
    }
    if eyes > 0 {
        syn.push_str(&format!("\n热度：{eyes}"));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": pic,
        "synopsis": syn,
        "extra": {"vod_play_from": format!("{from}直连$$$🔎相关推荐")},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.chars().all(|c| c.is_ascii_digit()) && !video_id.is_empty() {
        let d = detail(video_id).await?;
        d.get("episodes")
            .and_then(|e| e.as_array())
            .and_then(|a| a.first())
            .and_then(|e| e.get("video_id"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    } else {
        video_id.to_string()
    };
    if url.is_empty() {
        return Err(ApiError::Internal("黄瓜未取到播放地址".into()));
    }
    Ok(json!({"url": url, "header": {"User-Agent": UA}}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let body = api_post(
        "/api/vip/v1/video/search",
        json!({"keyword": query, "page": 1, "limit": 24}),
    )
    .await?;
    let data = data_of(&body);
    Ok(json!({"items": cards_of(&data)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwrap_passthrough() {
        let v = unwrap("{\"code\":200,\"data\":[]}");
        assert_eq!(v["code"], 200);
    }

    #[test]
    fn unwrap_not_found() {
        assert!(unwrap("404 Not Found!").is_null());
    }

    #[test]
    fn aes_ecb_roundtrip() {
        use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
        let cipher = aes::Aes128::new(GenericArray::from_slice(&AES_KEY[..16]));
        let plain = b"hello world 1234";
        let mut block = GenericArray::clone_from_slice(&plain[..]);
        cipher.encrypt_block(&mut block);
        let dec = aes_ecb_decrypt(&block, AES_KEY).unwrap();
        assert_eq!(dec, plain);
    }

    #[test]
    fn pick_list_flattens() {
        let data =
            json!([{"videoList": [{"vid": "1"}, {"vid": "2"}]}, {"videoList": [{"vid": "3"}]}]);
        assert_eq!(pick_list(&data).len(), 3);
        let data2 = json!({"data": [{"vid": "9"}]});
        assert_eq!(pick_list(&data2).len(), 1);
    }

    #[test]
    fn card_remark() {
        let v = json!({"vid": "123", "vod_name": "标题", "enpic": "https://x/y.jpg", "duration": "12:34", "eyes": 100});
        let c = card(&v).unwrap();
        assert_eq!(c["remark"], "12:34 · 🔥100");
    }
}
