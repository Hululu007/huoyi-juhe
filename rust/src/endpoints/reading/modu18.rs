//! modu18：与火蚁TV 的 modu18.py 一一对应。
//!
//! 成人漫画站（默认分类“最新A漫”，A 即成人向）：纯 JSON 接口，
//! 不走 HTML；部分响应带 encrypted 字段，须取小数点后一段做
//! base64 解码，再与 KEY（SHA256("MoDu18Comic2024!") 的十六进制
//! 前 32 字）循环异或、解 UTF-8 后再解析 JSON。分类来自
//! /api/categories（失败回退最新A漫）；目录按最新或分类过滤
//! （页大小 80 条）；详情按 series 出分集（无 series 时回退全
//! 集）；搜索在 py 里恒为空；取流时按章节图片文件名拼图床地址
//! 成 pics://。图片服务器地址只取一次并缓存（py 按实例缓存）。

use std::sync::{Mutex, OnceLock};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::error::{ApiError, ApiResult};

const API_URL: &str = "https://api.modu18.vip";
const SITE_URL: &str = "https://modu18.vip";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const DEFAULT_IMG_SERVER: &str = "https://cdn-msp.jmapinodeudzn.net";

static HTTP: OnceLock<Option<reqwest::Client>> = OnceLock::new();
static IMG_SERVER: Mutex<Option<String>> = Mutex::new(None);

fn client() -> ApiResult<&'static reqwest::Client> {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .ok()
    })
    .as_ref()
    .ok_or_else(|| ApiError::Internal("modu18 client unavailable".into()))
}

fn category_json(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

fn item_json(id: &str, title: &str, cover: &str, remark: &str) -> Value {
    json!({"id": id, "title": title, "cover": cover, "remark": remark})
}

fn episode_json(video_id: &str, title: &str, series_id: &str) -> Value {
    json!({"video_id": video_id, "title": title, "series_id": series_id})
}

fn str_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

fn get<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object().and_then(|m| m.get(key))
}

fn int_of(v: &Value, keys: &[&str]) -> i64 {
    for key in keys {
        if let Some(value) = get(v, key) {
            match value {
                Value::Number(n) => {
                    if let Some(i) = n.as_i64() {
                        return i;
                    }
                    if let Some(u) = n.as_u64() {
                        return u as i64;
                    }
                }
                Value::String(s) => {
                    if let Ok(i) = s.trim().parse::<i64>() {
                        return i;
                    }
                }
                _ => {}
            }
        }
    }
    0
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 与 py 的 _fetch 一致：单次请求，失败返回空串（由 _api 转 None）。
async fn fetch_text(path: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    let url = format!("{API_URL}{path}");
    let result = c
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{SITE_URL}/"))
        .send()
        .await;
    match result {
        Ok(resp) => resp.text().await.unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn decrypt_key() -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"MoDu18Comic2024!");
    let digest = hasher.finalize();
    let hex = hex::encode(digest);
    hex[..32].as_bytes().to_vec()
}

/// 与 py 的 _api 一致：解析 JSON；带 encrypted 时解密后重解析；
/// 任一步失败返回 None。
async fn api(path: &str) -> Option<Value> {
    let text = fetch_text(path).await;
    let raw: Value = serde_json::from_str(&text).ok()?;
    let encrypted = match get(&raw, "encrypted") {
        Some(Value::String(s)) => s.clone(),
        _ => return Some(raw),
    };
    let part = encrypted.split_once('.')?.1;
    let data = STANDARD.decode(part).ok()?;
    let key = decrypt_key();
    let plain: Vec<u8> = data
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ key[i % key.len()])
        .collect();
    let text = String::from_utf8(plain).ok()?;
    serde_json::from_str(&text).ok()
}

async fn img_server() -> String {
    if let Ok(guard) = IMG_SERVER.lock() {
        if let Some(cached) = guard.as_ref() {
            return cached.clone();
        }
    }
    let mut server = DEFAULT_IMG_SERVER.to_string();
    if let Some(data) = api("/api/image-servers").await {
        if let Some(servers) = get(&data, "servers").and_then(|v| v.as_array()) {
            if let Some(first) = servers.first() {
                let url = str_of(get(first, "url").unwrap_or(&Value::Null));
                if !url.is_empty() {
                    server = url;
                }
            }
        }
    }
    if let Ok(mut guard) = IMG_SERVER.lock() {
        *guard = Some(server.clone());
    }
    server
}

async fn cover(aid: &str) -> String {
    let server = img_server().await;
    format!(
        "{}/media/albums/{aid}_3x4.jpg",
        server.trim_end_matches('/')
    )
}

async fn categories_list() -> Vec<Value> {
    let mut cats = Vec::new();
    if let Some(data) = api("/api/categories").await {
        if let Some(inner) = get(&data, "data") {
            if let Some(rows) = get(inner, "categories").and_then(|v| v.as_array()) {
                for row in rows {
                    let slug = str_of(get(row, "slug").unwrap_or(&Value::Null));
                    let slug = if slug.is_empty() {
                        "latest".to_string()
                    } else {
                        slug
                    };
                    let name = str_of(get(row, "name").unwrap_or(&Value::Null));
                    cats.push(category_json(&slug, &name));
                }
            }
        }
    }
    if cats.is_empty() {
        cats.push(category_json("latest", "最新A漫"));
    }
    cats
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": categories_list().await}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let path = if category_id.is_empty() || category_id == "latest" {
        format!("/api/latest?page={page}")
    } else {
        format!(
            "/api/categories/filter?page={page}&o=latest&c={}",
            pct_encode_query(category_id)
        )
    };
    let data = api(&path).await;
    let mut raw_items: Vec<Value> = Vec::new();
    let mut total = 0i64;
    if let Some(data) = &data {
        if let Some(inner) = get(data, "data") {
            match inner {
                Value::Array(list) => raw_items = list.clone(),
                Value::Object(_) => {
                    if let Some(content) = get(inner, "content").and_then(|v| v.as_array()) {
                        raw_items = content.clone();
                    } else if let Some(list) = get(inner, "list").and_then(|v| v.as_array()) {
                        raw_items = list.clone();
                    }
                    total = int_of(inner, &["total"]);
                }
                _ => {}
            }
        }
    }
    let mut seen = std::collections::HashSet::new();
    let mut cards = Vec::new();
    for it in &raw_items {
        let aid = str_of(get(it, "id").unwrap_or(&Value::Null));
        if aid.is_empty() || !seen.insert(aid.clone()) {
            continue;
        }
        let name = str_of(get(it, "name").unwrap_or(&Value::Null));
        let remark = match get(it, "author") {
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        let pic = cover(&aid).await;
        cards.push(item_json(&aid, &name, &pic, &remark));
    }
    let pagecount = if total > 0 { (total + 79) / 80 } else { 0 };
    let has_more = if pagecount > 0 {
        page < pagecount
    } else {
        !cards.is_empty()
    };
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let aid = series_id;
    let data = api(&format!("/api/album?id={}", pct_encode_query(aid))).await;
    let alb: Value = match data.as_ref().and_then(|d| get(d, "data")) {
        Some(v) => v.clone(),
        None => Value::Null,
    };
    let title = {
        let t = str_of(get(&alb, "name").unwrap_or(&Value::Null));
        if t.is_empty() {
            aid.to_string()
        } else {
            t
        }
    };
    let desc = str_of(get(&alb, "description").unwrap_or(&Value::Null));
    let series = get(&alb, "series").and_then(|v| v.as_array()).cloned();
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(series) = series {
        for entry in &series {
            match entry {
                Value::Object(_) => {
                    let eid = str_of(get(entry, "id").unwrap_or(&Value::Null));
                    if eid.is_empty() {
                        continue;
                    }
                    let mut label = str_of(get(entry, "title").unwrap_or(&Value::Null));
                    if label.is_empty() {
                        label = str_of(get(entry, "name").unwrap_or(&Value::Null));
                    }
                    if label.is_empty() {
                        label = "章节".to_string();
                    }
                    episodes.push(episode_json(&format!("modu18:{eid}"), &label, aid));
                }
                Value::String(s) if !s.is_empty() => {
                    episodes.push(episode_json(&format!("modu18:{aid}"), s, aid));
                }
                _ => {}
            }
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("modu18:{aid}"), "全集", aid));
    }
    let pic = cover(aid).await;
    Ok(json!({
        "id": aid,
        "title": title,
        "cover": pic,
        "synopsis": desc,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(_query: &str) -> ApiResult<Value> {
    Ok(json!({"items": []}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let raw = strip_label(video_id);
    let cid = if raw.starts_with("modu18:") {
        let segs: Vec<&str> = raw.split(':').collect();
        if segs.len() >= 2 {
            segs[1].to_string()
        } else {
            String::new()
        }
    } else {
        String::new()
    };
    if cid.is_empty() {
        return Err(ApiError::Internal("modu18章节号无效".into()));
    }
    let data = api(&format!("/api/chapter?id={}", pct_encode_query(&cid))).await;
    let images: Vec<Value> = match data.as_ref().and_then(|d| get(d, "data")) {
        Some(inner) => get(inner, "images")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default(),
        None => Vec::new(),
    };
    let server = img_server().await;
    let base = server.trim_end_matches('/');
    let mut urls = Vec::new();
    for fn_value in &images {
        let name = str_of(fn_value);
        if !name.is_empty() {
            urls.push(format!("{base}/media/photos/{cid}/{name}"));
        }
    }
    if urls.is_empty() {
        return Err(ApiError::Internal("modu18未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", urls.join("&&"))}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypt_key_is_32_ascii_bytes() {
        let key = decrypt_key();
        assert_eq!(key.len(), 32);
        assert!(key.iter().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn xor_roundtrip() {
        let key = decrypt_key();
        let plain = b"{\"a\":1}";
        let cipher: Vec<u8> = plain
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ key[i % key.len()])
            .collect();
        let back: Vec<u8> = cipher
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ key[i % key.len()])
            .collect();
        assert_eq!(back, plain);
    }

    #[test]
    fn pagecount_formula() {
        assert_eq!((0i64 + 79) / 80, 0);
        assert_eq!((1i64 + 79) / 80, 1);
        assert_eq!((80i64 + 79) / 80, 1);
        assert_eq!((81i64 + 79) / 80, 2);
    }
}
