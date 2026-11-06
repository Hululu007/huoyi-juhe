//! 鲍鱼盒子：App 接口站，双 host 探活（/api/video/home_recommend
//! 回 code 200 者为准），先调 /api/tourist_login。
//!
//! 分类 = 排行榜 + 5 个 module 的分类树；直播分类不进核心影视区
//! （直播区不走分类体系，用户 2026-11-05 令）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const HOSTS: &[&str] = &["https://103.44.236.131:8001", "https://kk.zzijzn.com:8001"];
const UA: &str = "Dart/3.5 (dart:io)";
const HOST_TTL: Duration = Duration::from_secs(3600);

static HOST_CACHE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// module：接口名 -> 名。
const MODULES: &[(&str, &str)] = &[
    ("video", "国产优选好片"),
    ("index", "岛国热门AV"),
    ("west", "欧美精选影片"),
    ("tertiary", "精选热门三级"),
    ("comic", "成人高清动漫"),
];

fn headers() -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", UA.to_string()),
        ("Accept", "application/json, text/plain, */*".to_string()),
        ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
    ]
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
        return Err(ApiError::Internal(format!("鲍鱼盒子请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn get_json(url: &str) -> ApiResult<Value> {
    let text = get_text(url).await?;
    let body: Value = serde_json::from_str(&text)?;
    Ok(body)
}

fn data_of(body: &Value) -> Value {
    match get(body, "data") {
        Some(d) => d.clone(),
        None => body.clone(),
    }
}

fn code_of(body: &Value) -> i64 {
    super::int_of(body, &["code"])
}

/// 探活：逐个 host 调 /api/video/home_recommend，code 200 者为准。
async fn base() -> ApiResult<String> {
    if let Ok(guard) = HOST_CACHE.lock() {
        if let Some((host, at)) = guard.as_ref() {
            if Instant::now() < *at + HOST_TTL {
                return Ok(host.clone());
            }
        }
    }
    for host in HOSTS {
        let url = format!("{host}/api/video/home_recommend");
        if let Ok(body) = get_json(&url).await {
            if code_of(&body) == 200 {
                if let Ok(mut guard) = HOST_CACHE.lock() {
                    *guard = Some((host.to_string(), Instant::now()));
                }
                return Ok(host.to_string());
            }
        }
    }
    Err(ApiError::Internal(
        "鲍鱼盒子两个 host 均未返回有效首页".into(),
    ))
}

async fn tourist_login(host: &str) {
    let _ = get_json(&format!("{host}/api/tourist_login")).await;
}

fn dur_str(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    if secs >= 60 {
        format!("{} 分钟", secs / 60)
    } else {
        format!("{secs} 秒")
    }
}

fn cards(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let kind = text_of(e, &["kind"]);
        if kind == "advert" || kind == "ad" {
            continue;
        }
        let id = text_of(e, &["vid", "id"]);
        let name = text_of(e, &["name", "title"]);
        if id.is_empty() || name.is_empty() {
            continue;
        }
        let cover = text_of(e, &["vertical_cover", "cover"]);
        let dur = int_of(e, &["duration", "dur"]);
        let cat = text_of(e, &["categor_name", "category_name"]);
        let vip = int_of(e, &["is_vip", "vip"]);
        let mut remark = String::new();
        let d = dur_str(dur);
        if !d.is_empty() {
            remark.push_str(&d);
        }
        if !cat.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&cat);
        }
        if vip == 1 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str("VIP");
        }
        items.push(item_json(&id, &name, &cover, &remark));
    }
    items
}

async fn module_cats(host: &str) -> Vec<Value> {
    let mut out = vec![category_json("rank", "排行榜")];
    let mut seen: Vec<String> = Vec::new();
    for (module, _name) in MODULES {
        let url = format!("{host}/api/video/module_video?module={module}");
        if let Ok(body) = get_json(&url).await {
            let data = data_of(&body);
            // data 可能是对象 {list:[...]}，也可能是数组 [{list:[...]}]（2026-11-06 实测为数组组形式）。
            let mut lists: Vec<&Vec<Value>> = Vec::new();
            if let Some(list) = get(&data, "list").and_then(arr_of) {
                lists.push(list);
            }
            if let Some(groups) = arr_of(&data) {
                for g in groups {
                    if let Some(list) = get(g, "list").and_then(arr_of) {
                        lists.push(list);
                    }
                }
            }
            for list in lists {
                for e in list {
                    let cid = text_of(e, &["cid", "id"]);
                    let name = text_of(e, &["categor_name", "category_name", "name"]);
                    if cid.is_empty() || name.is_empty() || seen.contains(&cid) {
                        continue;
                    }
                    seen.push(cid.clone());
                    out.push(category_json(&format!("c{cid}"), &name));
                }
            }
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let host = base().await?;
    tourist_login(&host).await;
    let list = module_cats(&host).await;
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let host = base().await?;
    if category_id == "rank" {
        let body = get_json(&format!("{host}/api/video/home_recommend")).await?;
        let data = data_of(&body);
        let rows = get(&data, "list")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        return Ok(json!({"items": cards(&rows), "has_more": false}));
    }
    let cid = category_id.strip_prefix('c').unwrap_or(category_id);
    let page_s = page.to_string();
    let url = with_query(
        &format!("{host}/api/category/category_video"),
        &[("category_id", cid), ("page", &page_s)],
    );
    let body = get_json(&url).await?;
    let data = data_of(&body);
    let rows = get(&data, "list")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let count = int_of(&data, &["count"]);
    let has_more = count > page * 20;
    Ok(json!({"items": cards(&rows), "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let host = base().await?;
    let url = format!("{host}/api/video/detail/{series_id}?token=");
    let body = get_json(&url).await?;
    let data = data_of(&body);
    let video = match get(&data, "video") {
        Some(v) if v.is_object() => v.clone(),
        _ => data.clone(),
    };
    let name = text_of(&video, &["name", "title"]);
    if name.is_empty() {
        return Err(ApiError::Internal("鲍鱼盒子未返回影片资料".into()));
    }
    let cover = text_of(&video, &["vertical_cover", "cover"]);
    let area = text_of(&video, &["area"]);
    let created = text_of(&video, &["created_at"]);
    let year = created.get(..4).unwrap_or("").to_string();
    let cats = text_of(&video, &["categorys", "category"]);
    let actors = text_of(&video, &["actors"]);
    let brief = text_of(&video, &["brief", "description"]);
    let vip = int_of(&video, &["is_vip", "vip"]);
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(links) = get(&video, "links").and_then(arr_of) {
        for (i, l) in links.iter().enumerate() {
            let url = text_of(l, &["url", "gaoqin"]);
            if url.is_empty() {
                continue;
            }
            let line = text_of(l, &["tongdao_name", "name"]);
            let label = if line.is_empty() {
                format!("线路{}", i + 1)
            } else {
                line
            };
            episodes.push(episode_json(&url, &label, series_id));
        }
    }
    let try_play = text_of(&video, &["try_play_url"]);
    if !try_play.is_empty() {
        episodes.push(episode_json(&try_play, "试看", series_id));
    }
    if episodes.is_empty() {
        let url = text_of(&video, &["play_url", "url"]);
        if !url.is_empty() {
            episodes.push(episode_json(&url, "正片", series_id));
        }
    }
    let mut extra = serde_json::Map::new();
    if !area.is_empty() {
        extra.insert("area".to_string(), json!(area));
    }
    if !year.is_empty() {
        extra.insert("year".to_string(), json!(year));
    }
    if !cats.is_empty() {
        extra.insert("category".to_string(), json!(cats));
    }
    if !actors.is_empty() {
        extra.insert("actor".to_string(), json!(actors));
    }
    if vip == 1 {
        extra.insert("vip".to_string(), json!("VIP"));
    }
    Ok(json!({
        "id": series_id,
        "title": name,
        "cover": cover,
        "synopsis": brief,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if !video_id.starts_with("http") {
        return Err(ApiError::Internal("鲍鱼盒子该集没有播放地址".into()));
    }
    let host = base().await.unwrap_or_else(|_| HOSTS[0].to_string());
    Ok(json!({
        "url": video_id,
        "header": {"User-Agent": UA, "Referer": format!("{host}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let host = base().await?;
    let url = with_query(
        &format!("{host}/api/index/word_search"),
        &[("keyword", query), ("page", "1")],
    );
    let body = get_json(&url).await?;
    let data = data_of(&body);
    let rows = get(&data, "list")
        .and_then(arr_of)
        .cloned()
        .or_else(|| arr_of(&data).cloned())
        .unwrap_or_default();
    let mut items = Vec::new();
    for e in &rows {
        let id = text_of(e, &["vid", "id"]);
        let mut name = text_of(e, &["name", "title"]);
        name = name.replace("<em>", "").replace("</em>", "");
        if let Some(p) = name.rfind("_prob") {
            let tail = &name[p..];
            if tail.chars().skip(5).all(|c| c.is_ascii_digit()) {
                name.truncate(p);
            }
        }
        if id.is_empty() || name.is_empty() {
            continue;
        }
        let cover = text_of(e, &["vertical_cover", "cover"]);
        items.push(item_json(&id, &name, &cover, ""));
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dur_formats() {
        assert_eq!(dur_str(90), "1 分钟");
        assert_eq!(dur_str(45), "45 秒");
        assert_eq!(dur_str(0), "");
    }

    #[test]
    fn cards_skip_ads() {
        let rows = vec![
            json!({"vid": "1", "name": "A", "kind": "advert"}),
            json!({"vid": "2", "name": "B", "duration": 120, "categor_name": "国产", "is_vip": 1}),
        ];
        let items = cards(&rows);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["remark"], "2 分钟 · 国产 · VIP");
    }
}
