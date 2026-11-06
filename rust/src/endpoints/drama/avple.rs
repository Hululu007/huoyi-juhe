//! AVPle：API 站（avple.ystv.top），分类走 /cats，列表走 /list，
//! 详情走 /detail；取流按 srcType 拼 CDN 候选地址，并发探活后取
//! 最多 3 条活的；无活则用 playUrls。

use std::time::Duration;

use futures::future::join_all;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const API: &str = "https://avple.ystv.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const SUFFIX: &str = ".cdnedge.live";
/// ZakaSec.s(331) 解出的 30 个 CDN host 前缀。
const HOSTS: &[&str] = &[
    "d862cp", "q2cyl7", "u89ey", "zo392", "wo880", "6m7d", "8bb88", "fa678", "pg2z7", "1xp60",
    "47b61", "i3qss", "10j99", "je40u", "s2jfy", "l87ul", "s6s6u", "rup0u", "ja34l", "rr0s1",
    "c4m6s", "60frt", "rd192", "2nm9j", "l8uao", "ie2ow", "fhq06", "b3h6s", "sms9q", "xre5q",
];

fn headers() -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", UA.to_string()),
        ("Accept", "application/json".to_string()),
    ]
}

async fn get_json(url: &str) -> ApiResult<Value> {
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
        return Err(ApiError::Internal(format!("AVPle 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    Ok(body)
}

/// 取 data（无 data 则用根对象）。
fn data_of(body: &Value) -> Value {
    match get(body, "data") {
        Some(d) => d.clone(),
        None => body.clone(),
    }
}

fn cards(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let id = text_of(e, &["id"]);
        let title = text_of(e, &["title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = text_of(e, &["cover"]);
        let code = text_of(e, &["code"]);
        let dur = text_of(e, &["dur"]);
        let date = text_of(e, &["date"]);
        let views = int_of(e, &["views"]);
        let mut remark = String::new();
        if !code.is_empty() {
            remark.push_str(&code);
        }
        if !dur.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&dur);
        }
        if !date.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&date);
        }
        if views > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("🔥{views}"));
        }
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 探活：Range 取前 1024 字节，读到 16 字节以上即活。
async fn probe(url: &str) -> bool {
    let req = match client() {
        Ok(c) => c
            .get(url)
            .header("User-Agent", UA)
            .header("Range", "bytes=0-1023")
            .timeout(Duration::from_millis(3200)),
        Err(_) => return false,
    };
    let fut = async move {
        let resp = req.send().await.ok()?;
        let status = resp.status().as_u16();
        if status != 200 && status != 206 {
            return None;
        }
        let bytes = resp.bytes().await.ok()?;
        if bytes.len() >= 16 {
            Some(())
        } else {
            None
        }
    };
    tokio::time::timeout(Duration::from_secs(6), fut)
        .await
        .ok()
        .flatten()
        .is_some()
}

/// 按 srcType 拼候选地址，并发探活取最多 3 条；无活返回空。
async fn pick_live(play: &str, src_type: i64) -> Vec<String> {
    let mut cands: Vec<String> = Vec::new();
    match src_type {
        1 | 1001 => {
            cands.push(format!(
                "https://hqua8q61at{SUFFIX}/file/avple-asserts/{play}"
            ));
        }
        2 | 3 | 4 | 7 | 8 => {
            for h in HOSTS {
                cands.push(format!("https://{h}{SUFFIX}/file/avple-images/{play}"));
            }
        }
        _ => {
            for h in HOSTS {
                cands.push(format!("https://{h}1{SUFFIX}/file/avple-asserts/{play}"));
            }
        }
    }
    let results = join_all(cands.iter().map(|u| probe(u))).await;
    let mut live: Vec<String> = Vec::new();
    for (u, ok) in cands.iter().zip(results) {
        if ok {
            live.push(u.clone());
            if live.len() >= 3 {
                break;
            }
        }
    }
    live
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("139|date", "最新上架"),
        category_json("140|hot", "熱門影片"),
        category_json("139|views", "最多播放"),
    ];
    if let Ok(body) = get_json(&format!("{API}/cats")).await {
        let data = data_of(&body);
        if let Some(tags) = get(&data, "tags").and_then(arr_of) {
            for t in tags {
                let id = text_of(t, &["id"]);
                let name = text_of(t, &["name"]);
                if !id.is_empty() && !name.is_empty() {
                    list.push(category_json(&format!("{id}|date"), &name));
                }
            }
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (cat, sort) = match category_id.split_once('|') {
        Some((c, s)) => (c.to_string(), s.to_string()),
        None => (category_id.to_string(), "date".to_string()),
    };
    let page_s = page.to_string();
    let url = with_query(
        &format!("{API}/list"),
        &[("cat", &cat), ("page", &page_s), ("sort", &sort)],
    );
    let body = get_json(&url).await?;
    let data = data_of(&body);
    let rows = get(&data, "list")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let items = cards(&rows);
    let total_page = int_of(&data, &["totalPage"]);
    let has_more = total_page > 0 && page < total_page;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{API}/detail"), &[("id", series_id)]);
    let body = get_json(&url).await?;
    let data = data_of(&body);
    let title = text_of(&data, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("AVPle 未返回影片资料".into()));
    }
    let cover = text_of(&data, &["cover"]);
    let code = text_of(&data, &["code"]);
    let date = text_of(&data, &["date"]);
    let dur = text_of(&data, &["dur"]);
    let mut tags = Vec::new();
    if let Some(list) = get(&data, "tags").and_then(arr_of) {
        for t in list.iter().take(20) {
            let n = text_of(t, &["name"]);
            if !n.is_empty() {
                tags.push(n);
            }
        }
    }
    let play = text_of(&data, &["play"]);
    let src_type = int_of(&data, &["srcType"]);
    let mut urls: Vec<String> = Vec::new();
    if play.starts_with("http") {
        urls.push(play.clone());
    } else if !play.is_empty() {
        urls = pick_live(&play, src_type).await;
        if urls.is_empty() {
            if let Some(list) = get(&data, "playUrls").and_then(arr_of) {
                for u in list {
                    let s = super::str_of(u);
                    if s.starts_with("http") {
                        urls.push(s);
                    }
                }
            }
        }
    }
    let mut episodes: Vec<Value> = Vec::new();
    for (i, u) in urls.iter().enumerate() {
        let label = if urls.len() > 1 {
            format!("AVPle·线路{}", i + 1)
        } else {
            "正片".to_string()
        };
        episodes.push(episode_json(u, &label, series_id));
    }
    let mut extra = serde_json::Map::new();
    if !code.is_empty() {
        extra.insert("code".to_string(), json!(code));
    }
    if !date.is_empty() {
        extra.insert("date".to_string(), json!(date));
    }
    if !dur.is_empty() {
        extra.insert("duration".to_string(), json!(dur));
    }
    if !tags.is_empty() {
        extra.insert("tag".to_string(), json!(tags.join(" / ")));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
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
            "header": {"User-Agent": UA, "Referer": format!("{API}/")},
        }));
    }
    Err(ApiError::Internal("AVPle 未取到播放地址，稍后重试".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{API}/search"), &[("kw", query), ("page", "1")]);
    let body = get_json(&url).await?;
    let data = data_of(&body);
    let rows = get(&data, "list")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    Ok(json!({"items": cards(&rows)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_pool_size() {
        assert_eq!(HOSTS.len(), 30);
    }

    #[test]
    fn cards_remark() {
        let rows = vec![
            json!({"id": "1", "title": "T", "code": "ABC-1", "dur": "10:00", "date": "2026-01-01", "views": 5}),
        ];
        let items = cards(&rows);
        assert_eq!(items[0]["remark"], "ABC-1 · 10:00 · 2026-01-01 · 🔥5");
    }
}
