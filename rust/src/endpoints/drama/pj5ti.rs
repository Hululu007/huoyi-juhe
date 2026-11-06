//! 蜜桃社（pj5ti.com）：App 接口站，全站请求体 AES-256-CBC 加密。
//!
//! - 引导：依次 POST {api}/base/getTimeStamp 空 JSON，code==0 锁定
//!   apiBase 并记服务端时间戳；ents=服务端时间+(本地时间-记时时间)，
//!   无服务端时间时为本地时间-28800；code==607 时重置重引导。
//! - 请求体：{"endata": aes(业务JSON), "ents": aes(秒级时间戳)}，
//!   AES-256-CBC，密钥为 32 字节 ASCII，IV=密钥前 16 字节，
//!   PKCS7 填充，base64 输出；响应取 data 字段。
//! - 分类先调 /videos/getType，失败回退 5 个静态分类；目录
//!   /videos/getList（offset=(page-1)*20）；详情 /videos/getInfo；
//!   搜索 /base/globalSearch（type 1 无结果时改 type 2 再试）；
//!   取流 /videos/getPreUrl，地址做 start=0&end=999999 加宽。
//! - 封面为加密字节地址（coverImgUrl 原样返回，壳侧按原地址取）。
//! - 取流地址为短效签名地址，需现取现播。

use std::sync::Mutex;
use std::time::Instant;

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const DEF_HOST: &str = "https://www.pj5ti.com";
const API_BASES: [&str; 2] = ["https://a83k.aqx84.com", "https://a48j.jot4v.com"];
const AES_KEY: &[u8] = b"B77A9FF7F323B5404902102257503C2F";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 20;
const TZ_OFF: i64 = -28800;

static STATE: Mutex<Option<(String, i64, Instant)>> = Mutex::new(None);

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// AES-256-CBC 加密（PKCS7 填充，IV=密钥前 16 字节），输出 base64。
fn aes_enc(plain: &str) -> String {
    use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
    let cipher = aes::Aes256::new(GenericArray::from_slice(&AES_KEY[..32]));
    let mut data = plain.as_bytes().to_vec();
    let pad = 16 - (data.len() % 16);
    data.extend(std::iter::repeat(pad as u8).take(pad));
    let mut out = Vec::with_capacity(data.len());
    let mut prev: [u8; 16] = AES_KEY[..16].try_into().unwrap();
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        for i in 0..16 {
            block[i] ^= prev[i];
        }
        cipher.encrypt_block(&mut block);
        prev.copy_from_slice(&block);
        out.extend_from_slice(&block);
    }
    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &out)
}

fn ents_value() -> i64 {
    if let Ok(guard) = STATE.lock() {
        if let Some((_, server_ts, ts_at)) = guard.as_ref() {
            return server_ts + ts_at.elapsed().as_secs() as i64;
        }
    }
    now_secs() + TZ_OFF
}

async fn raw_post(base: &str, path: &str, obj: &Value) -> ApiResult<Value> {
    let body = json!({
        "endata": aes_enc(&obj.to_string()),
        "ents": aes_enc(&ents_value().to_string()),
    });
    let resp = client()?
        .post(format!("{base}{path}"))
        .header("Content-Type", "application/json;charset=UTF-8;")
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Did", "1")
        .header("source", "1")
        .header("Origin", DEF_HOST)
        .header("Referer", format!("{DEF_HOST}/"))
        .header("User-Agent", UA)
        .json(&body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("蜜桃社请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    serde_json::from_str::<Value>(&text)
        .map_err(|_| ApiError::Internal("蜜桃社响应不是 JSON".into()))
}

async fn bootstrap() -> ApiResult<String> {
    if let Ok(guard) = STATE.lock() {
        if let Some((base, _, _)) = guard.as_ref() {
            return Ok(base.clone());
        }
    }
    for base in API_BASES {
        if let Ok(resp) = raw_post(base, "/base/getTimeStamp", &json!({})).await {
            if int_of(&resp, &["code"]) == 0 {
                let server_ts = get(&resp, "data")
                    .map(|d| int_of(d, &["timeStamp"]))
                    .unwrap_or(0);
                if let Ok(mut guard) = STATE.lock() {
                    *guard = Some((base.to_string(), server_ts, Instant::now()));
                }
                return Ok(base.to_string());
            }
        }
    }
    Err(ApiError::Internal("蜜桃社引导失败".into()))
}

async fn api(path: &str, obj: &Value) -> ApiResult<Value> {
    let base = bootstrap().await?;
    let resp = raw_post(&base, path, obj).await?;
    if int_of(&resp, &["code"]) == 607 {
        if let Ok(mut guard) = STATE.lock() {
            *guard = None;
        }
        let base = bootstrap().await?;
        return raw_post(&base, path, obj).await;
    }
    Ok(resp)
}

fn data_of(resp: &Value) -> Value {
    match get(resp, "data") {
        Some(d) => d.clone(),
        None => Value::Null,
    }
}

fn fallback_categories() -> Value {
    json!({"categories": [
        category_json("4", "国产"),
        category_json("11", "主播"),
        category_json("17", "日韩"),
        category_json("23", "欧美"),
        category_json("29", "动漫"),
    ]})
}

/// 秒转“分:秒”。
fn fmt_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return String::new();
    }
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

fn catalog_items(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let id = int_of(e, &["id"]);
        let title = text_of(e, &["name"]);
        if id <= 0 || title.is_empty() {
            continue;
        }
        let cover = text_of(e, &["coverImgUrl"]);
        let type_name = text_of(e, &["typeName"]);
        let year = text_of(e, &["addTime"]).get(..4).unwrap_or("").to_string();
        let remark = format!("{type_name} {year}").trim().to_string();
        items.push(item_json(&id.to_string(), &title, &cover, &remark));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match api("/videos/getType", &json!({})).await {
        Ok(resp) => {
            let mut list = Vec::new();
            if let Some(rows) = get(&data_of(&resp), "list").and_then(arr_of) {
                for e in rows {
                    let id = int_of(e, &["id"]);
                    let name = text_of(e, &["type_name"]);
                    if id > 0 && !name.is_empty() {
                        list.push(category_json(&id.to_string(), &name));
                    }
                }
            }
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let type_id: i64 = category_id.parse().unwrap_or(0);
    let mut obj = json!({
        "offset": (page - 1) * PAGE_SIZE,
        "length": PAGE_SIZE,
    });
    if type_id != 0 {
        obj["typeId"] = json!(type_id);
    }
    let resp = api("/videos/getList", &obj).await?;
    let data = data_of(&resp);
    let rows = get(&data, "list")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let items = catalog_items(&rows);
    let total = int_of(&data, &["count"]);
    let page_count = if total > 0 {
        (total + PAGE_SIZE - 1) / PAGE_SIZE
    } else {
        page + 1
    };
    Ok(json!({"items": items, "has_more": page < page_count}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let video_id: i64 = series_id
        .parse()
        .map_err(|_| ApiError::Internal("蜜桃社视频 id 非数字".into()))?;
    let resp = api(
        "/videos/getInfo",
        &json!({"videoId": video_id, "videoSort": 1}),
    )
    .await?;
    let data = data_of(&resp);
    let info = match get(&data, "info") {
        Some(v) if v.is_object() => v.clone(),
        _ => return Err(ApiError::Internal("蜜桃社未返回影片资料".into())),
    };
    let name = text_of(&info, &["name"]);
    let cover = text_of(&info, &["coverImgUrl"]);
    let type_name = text_of(&info, &["typeName"]);
    let tags = text_of(&info, &["tags"]);
    let add_time = text_of(&info, &["addTime"]);
    let length = int_of(&info, &["length"]);
    let see_count = int_of(&info, &["seeCount"]);
    let like_count = int_of(&info, &["likeCount"]);
    let can_play = match get(&data, "canPlay") {
        Some(Value::Bool(b)) => *b,
        _ => false,
    };
    let is_vip = int_of(&info, &["isVip"]) != 0;
    let status = if can_play {
        "已解锁"
    } else if is_vip {
        "站方会员专享片"
    } else {
        "付费片·本源直出完整线路（站方标价，不花）"
    };
    let synopsis = format!(
        "影片 id：{series_id}\n分类：{type_name}\n时长：{}\n播放：{see_count} 点赞：{like_count}\n标签：{tags}\n上架：{add_time}\n状态：{status}",
        fmt_duration(length)
    );
    Ok(json!({
        "id": series_id,
        "title": name,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"vod_play_from": "蜜桃社"},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

/// 取流地址加宽：start 改 0、end 改 999999，缺失则补。
fn widen_url(url: &str) -> String {
    if url.is_empty() {
        return String::new();
    }
    let mut out = url.to_string();
    for (key, val) in [("start", "0"), ("end", "999999")] {
        let (base, query) = match out.split_once('?') {
            Some((b, q)) => (b.to_string(), q.to_string()),
            None => (out.clone(), String::new()),
        };
        let mut parts: Vec<String> = Vec::new();
        let mut replaced = false;
        for seg in query.split('&') {
            if seg.is_empty() {
                continue;
            }
            if let Some((k, _)) = seg.split_once('=') {
                if k == key {
                    parts.push(format!("{key}={val}"));
                    replaced = true;
                    continue;
                }
            }
            parts.push(seg.to_string());
        }
        if !replaced {
            parts.push(format!("{key}={val}"));
        }
        out = if parts.is_empty() {
            base
        } else {
            format!("{base}?{}", parts.join("&"))
        };
    }
    out
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let id: i64 = video_id
        .parse()
        .map_err(|_| ApiError::Internal("蜜桃社视频 id 非数字".into()))?;
    let resp = api("/videos/getPreUrl", &json!({"videoId": id})).await?;
    let data = data_of(&resp);
    let mut url = text_of(&data, &["url"]).replace("\\/", "/");
    if url.is_empty() {
        url = text_of(&data, &["preUrl"]).replace("\\/", "/");
    }
    if url.is_empty() {
        return Err(ApiError::Internal("蜜桃社未取到播放地址".into()));
    }
    let url = widen_url(&url);
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{DEF_HOST}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let body = json!({"key": query, "type": 1, "offset": 0, "length": PAGE_SIZE});
    let resp = api("/base/globalSearch", &body).await?;
    let mut data = data_of(&resp);
    let mut rows: Vec<Value> = get(&data, "infos")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    if rows.is_empty() {
        rows = get(&data, "list")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
    }
    if rows.is_empty() {
        let resp2 = api(
            "/base/globalSearch",
            &json!({"key": query, "type": 2, "offset": 0, "length": PAGE_SIZE}),
        )
        .await?;
        data = data_of(&resp2);
        rows = get(&data, "infos")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        if rows.is_empty() {
            rows = get(&data, "list")
                .and_then(arr_of)
                .cloned()
                .unwrap_or_default();
        }
    }
    let mut items = Vec::new();
    for e in &rows {
        let id = int_of(e, &["id"]);
        let mut title = text_of(e, &["name", "title"]);
        if id <= 0 || title.is_empty() {
            continue;
        }
        if int_of(e, &["gatherId"]) > 0 {
            title = format!("合集 · {title}");
        }
        let cover = text_of(e, &["coverImgUrl", "cover"]);
        items.push(item_json(&id.to_string(), &title, &cover, ""));
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aes_enc_is_stable_base64() {
        let a = aes_enc("{}");
        let b = aes_enc("{}");
        assert_eq!(a, b);
        assert!(!a.is_empty());
        assert!(base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &a).is_ok());
    }

    #[test]
    fn duration_formats() {
        assert_eq!(fmt_duration(0), "");
        assert_eq!(fmt_duration(65), "1:05");
        assert_eq!(fmt_duration(2214), "36:54");
    }

    #[test]
    fn widen_rewrites_and_appends() {
        let u = widen_url("https://x/index.m3u8?start=10&end=100&sign=abc");
        assert!(u.contains("start=0"), "{u}");
        assert!(u.contains("end=999999"), "{u}");
        assert!(u.contains("sign=abc"), "{u}");
        let u2 = widen_url("https://x/index.m3u8");
        assert!(u2.contains("?start=0"), "{u2}");
        assert!(u2.contains("end=999999"), "{u2}");
    }

    #[test]
    fn catalog_skips_bad_rows() {
        let rows = vec![
            json!({"id": 371, "name": "片A", "coverImgUrl": "c1", "typeName": "自拍", "addTime": "2018-01-01"}),
            json!({"id": 0, "name": "无id"}),
            json!({"id": 372, "name": ""}),
        ];
        let items = catalog_items(&rows);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "371");
        assert_eq!(items[0]["remark"], "自拍 2018");
    }
}
