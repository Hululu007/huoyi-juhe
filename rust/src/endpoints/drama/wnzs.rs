//! WNZS：App 接口站，host 走阿里 DoH 的 TXT 记录（wnzs.5ibox.top），
//! 响应非 JSON 时为 base64 + AES/ECB 密文（key `=^%7@84%0^!8892-`），
//! 先 POST /api/ai/register 拿 token，后续请求带 appkey +
//! accessToken 查询参数，401/403 时重注册再试一次。
//! 封面走本地图片代理，核心返回原地址（图片字节可能为 XOR -120
//! 混淆，待手机侧验证）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const DEF_HOST: &str = "https://wnzsapia.yasqhm.cn";
const TXT: &str = "wnzs.5ibox.top";
const APPKEY: &str = "tp19";
const UA: &str = "okhttp/4.9.3";
const AES_KEY: &[u8] = b"=^%7@84%0^!8892-";

static HOST_CACHE: Mutex<Option<String>> = Mutex::new(None);
static TOKEN_CACHE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

fn headers() -> Vec<(&'static str, String)> {
    vec![("User-Agent", UA.to_string())]
}

async fn get_text(url: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("WNZS 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// DoH 取 TXT：首个以 | 分隔的 http 地址作 host，失败用兜底。
async fn base() -> String {
    if let Ok(guard) = HOST_CACHE.lock() {
        if let Some(h) = guard.as_ref() {
            return h.clone();
        }
    }
    let mut host = DEF_HOST.to_string();
    let url = format!("https://dns.alidns.com/resolve?name={TXT}&type=TXT");
    if let Ok(text) = get_text(&url).await {
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            if let Some(answers) = get(&v, "Answer").and_then(arr_of) {
                for a in answers {
                    if int_of(a, &["type"]) == 16 {
                        let data = text_of(a, &["data"]);
                        let data = data.trim_matches('"');
                        for part in data.split('|') {
                            let p = part.trim().trim_end_matches('/');
                            if p.starts_with("http") {
                                host = p.to_string();
                                break;
                            }
                        }
                        if host != DEF_HOST {
                            break;
                        }
                    }
                }
            }
        }
    }
    if let Ok(mut guard) = HOST_CACHE.lock() {
        *guard = Some(host.clone());
    }
    host
}

/// AES/ECB 解密（Java Cipher "AES" 默认即 ECB/PKCS5Padding）。
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

/// 解包：JSON 直用；含 Not Found 返空；否则 base64 + AES/ECB 解。
fn unwrap(text: &str) -> Value {
    let t = text.trim();
    if t.is_empty() || t.contains("Not Found") {
        return Value::Null;
    }
    if t.starts_with('{') || t.starts_with('[') {
        return serde_json::from_str(t).unwrap_or(Value::Null);
    }
    let raw = match base64::Engine::decode(&base64::engine::general_purpose::STANDARD, t) {
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

/// 注册拿 token：POST /api/ai/register?appkey=tp19。
async fn register(host: &str) -> ApiResult<String> {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u32)
        .unwrap_or(0);
    let unique = format!("tvbox{:08x}", ms & 0xffffffff);
    let url = format!("{host}/api/ai/register?appkey={APPKEY}");
    let body = json!({
        "pid": 1,
        "unique_code": unique,
        "model": "android",
        "channelCode": "2020",
    });
    let req = client()?
        .post(&url)
        .header("User-Agent", UA)
        .header("Content-Type", "application/json")
        .json(&body);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("WNZS 注册 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body = unwrap(&text);
    let token = text_of(&data_of(&body), &["token"]);
    if token.is_empty() {
        return Err(ApiError::Internal("WNZS 注册未返回 token".into()));
    }
    if let Ok(mut guard) = TOKEN_CACHE.lock() {
        *guard = Some((token.clone(), Instant::now()));
    }
    Ok(token)
}

async fn token(host: &str) -> ApiResult<String> {
    if let Ok(guard) = TOKEN_CACHE.lock() {
        if let Some((t, _)) = guard.as_ref() {
            if !t.is_empty() {
                return Ok(t.clone());
            }
        }
    }
    register(host).await
}

async fn api_get(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let host = base().await;
    let token = token(&host).await?;
    let mut all: Vec<(String, String)> = vec![
        ("appkey".to_string(), APPKEY.to_string()),
        ("accessToken".to_string(), token),
    ];
    for (k, v) in params {
        all.push((k.to_string(), v.to_string()));
    }
    let refs: Vec<(&str, &str)> = all.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let url = with_query(&format!("{host}{path}"), &refs);
    let mut text = get_text(&url).await?;
    let mut body = unwrap(&text);
    if body.is_null() {
        // 疑似 token 失效：清 token 重注册再试一次。
        if let Ok(mut guard) = TOKEN_CACHE.lock() {
            *guard = None;
        }
        let token2 = register(&host).await?;
        let mut all2: Vec<(String, String)> = vec![
            ("appkey".to_string(), APPKEY.to_string()),
            ("accessToken".to_string(), token2),
        ];
        for (k, v) in params {
            all2.push((k.to_string(), v.to_string()));
        }
        let refs2: Vec<(&str, &str)> = all2.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let url2 = with_query(&format!("{host}{path}"), &refs2);
        text = get_text(&url2).await?;
        body = unwrap(&text);
    }
    Ok(body)
}

async fn api_post(path: &str, body: Value) -> ApiResult<Value> {
    let host = base().await;
    let token = token(&host).await?;
    let url = with_query(
        &format!("{host}{path}"),
        &[("appkey", APPKEY), ("accessToken", &token)],
    );
    let req = client()?
        .post(&url)
        .header("User-Agent", UA)
        .header("Content-Type", "application/json")
        .json(&body);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status == 401 || status == 403 {
        if let Ok(mut guard) = TOKEN_CACHE.lock() {
            *guard = None;
        }
        let token2 = register(&host).await?;
        let url2 = with_query(
            &format!("{host}{path}"),
            &[("appkey", APPKEY), ("accessToken", &token2)],
        );
        let req2 = client()?
            .post(&url2)
            .header("User-Agent", UA)
            .header("Content-Type", "application/json")
            .json(&body);
        let resp2 = req2
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let text2 = resp2
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        return Ok(unwrap(&text2));
    }
    if status != 200 {
        return Err(ApiError::Internal(format!("WNZS 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(unwrap(&text))
}

fn pick_list_data(body: &Value) -> Vec<Value> {
    let data = data_of(body);
    if let Some(arr) = arr_of(&data) {
        return arr.clone();
    }
    if let Some(m) = data.as_object() {
        for (_, v) in m {
            if let Some(arr) = arr_of(v) {
                return arr.clone();
            }
        }
    }
    Vec::new()
}

fn cards(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let vid = text_of(e, &["vid", "id"]);
        let name = text_of(e, &["vod_name", "name", "title"]);
        if vid.is_empty() || name.is_empty() {
            continue;
        }
        let cover = text_of(e, &["enpic", "cover", "pic"]);
        let dur = text_of(e, &["duration"]);
        let eyes = int_of(e, &["eyes"]);
        let mut remark = dur;
        if eyes > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("🔥{eyes}"));
        }
        items.push(item_json(&vid, &name, &cover, &remark));
    }
    items
}

/// 删萝莉类分类（用户令：站照常写，只删带萝莉的分类）。
/// live 实测 2026-11-05：cateParentList 首项即 cate_pid=152「萝莉」。
fn is_blocked_title(t: &str) -> bool {
    t.contains('萝') && t.contains('莉') || t.contains("幼女") || t.contains("未成年")
}

/// live 实测的萝莉分类 id（与标题过滤双重保险）。
const BLOCKED_CATE_PIDS: &[&str] = &["152"];

pub(crate) async fn categories() -> ApiResult<Value> {
    let body = api_get("/api/video/index", &[]).await?;
    let data = data_of(&body);
    let mut list = vec![category_json("new", "🔥最新入库")];
    if let Some(parents) = get(&data, "cateParentList").and_then(arr_of) {
        for p in parents {
            let pid = text_of(p, &["cate_pid", "id"]);
            let title = text_of(p, &["title", "name"]);
            if !pid.is_empty() && !title.is_empty() && !is_blocked_title(&title) {
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
            "/api/video/newVideoList",
            &[("page", &page_s), ("limit", "24")],
        )
        .await?
    } else {
        let pid = category_id.strip_prefix("cate_").unwrap_or(category_id);
        if BLOCKED_CATE_PIDS.contains(&pid) {
            return Ok(json!({"items": [], "has_more": false}));
        }
        api_get(
            "/api/video/cateVideoList",
            &[("page", &page_s), ("limit", "24"), ("cate_pid", pid)],
        )
        .await?
    };
    let data = data_of(&body);
    let rows = pick_list_data(&body);
    let total = int_of(&data, &["total"]);
    let has_more = total > page * 24 || rows.len() >= 24;
    Ok(json!({"items": cards(&rows), "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let body = api_get("/api/video/detail", &[("vid", series_id)]).await?;
    let data = data_of(&body);
    let video = match get(&data, "video") {
        Some(v) if v.is_object() => v.clone(),
        _ => data.clone(),
    };
    let name = text_of(&video, &["vod_name", "name", "title"]);
    if name.is_empty() {
        return Err(ApiError::Internal("WNZS 未返回影片资料".into()));
    }
    let cover = text_of(&video, &["enpic", "cover", "pic"]);
    let play_url = text_of(&video, &["play_url"]);
    let from = text_of(&video, &["vod_play_from"]);
    let from = if from.is_empty() {
        "WNZS".to_string()
    } else {
        from
    };
    let update = text_of(&video, &["update_time"]);
    let year = update.get(..4).unwrap_or("").to_string();
    let dur = text_of(&video, &["duration"]);
    let eyes = int_of(&video, &["eyes"]);
    let mut episodes: Vec<Value> = Vec::new();
    if !play_url.is_empty() {
        episodes.push(episode_json(&play_url, &format!("{from}直连"), series_id));
    }
    let mut related: Vec<Value> = Vec::new();
    if let Some(list) = get(&data, "relatedVideoList").and_then(arr_of) {
        for e in list.iter().take(12) {
            let vid = text_of(e, &["vid", "id"]);
            let n = text_of(e, &["vod_name", "name", "title"]);
            if !vid.is_empty() && !n.is_empty() {
                related.push(episode_json(&vid, &n, series_id));
            }
        }
    }
    if !related.is_empty() {
        episodes.push(episode_json(
            &related
                .iter()
                .map(|e| format!("{}${}", text_of(e, &["title"]), text_of(e, &["video_id"])))
                .collect::<Vec<_>>()
                .join("#"),
            "🔎相关推荐",
            series_id,
        ));
    }
    let mut extra = serde_json::Map::new();
    if !year.is_empty() {
        extra.insert("year".to_string(), json!(year));
    }
    if !dur.is_empty() {
        extra.insert("duration".to_string(), json!(dur));
    }
    if eyes > 0 {
        extra.insert("views".to_string(), json!(eyes));
    }
    Ok(json!({
        "id": series_id,
        "title": name,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA},
        }));
    }
    // 纯数字 vid：先调详情取 play_url；相关推荐的集 id 同样是 vid。
    let body = api_get("/api/video/detail", &[("vid", video_id)]).await?;
    let data = data_of(&body);
    let video = match get(&data, "video") {
        Some(v) if v.is_object() => v.clone(),
        _ => data.clone(),
    };
    let play_url = text_of(&video, &["play_url"]);
    if play_url.is_empty() {
        return Err(ApiError::Internal("WNZS 未取到播放地址".into()));
    }
    Ok(json!({
        "url": play_url,
        "header": {"User-Agent": UA},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let body = api_post(
        "/api/video/search",
        json!({"keyword": query, "page": 1, "limit": 24}),
    )
    .await?;
    let rows = pick_list_data(&body);
    Ok(json!({"items": cards(&rows)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwrap_passthrough() {
        let v = unwrap(r#"{"code":0,"data":{"token":"abc"}}"#);
        assert_eq!(text_of(&data_of(&v), &["token"]), "abc");
    }

    #[test]
    fn unwrap_not_found() {
        assert!(unwrap("Not Found").is_null());
    }

    #[test]
    fn ecb_roundtrip() {
        use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
        let key = AES_KEY;
        let cipher = aes::Aes128::new(GenericArray::from_slice(&key[..16]));
        let plain = b"{\"token\":\"abc\"}";
        let mut padded = plain.to_vec();
        let pad = 16 - (plain.len() % 16);
        padded.extend(std::iter::repeat(pad as u8).take(pad));
        let mut ct = Vec::new();
        for chunk in padded.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.encrypt_block(&mut block);
            ct.extend_from_slice(&block);
        }
        let out = aes_ecb_decrypt(&ct, key).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "{\"token\":\"abc\"}");
    }
}
