//! 快播至臻版：API 站（dy.ykfryrx.cn），GET /api/<方法>?platform=9
//! &_b=mucritmg&参数（_b 为固定常量，非签名）；分类走
//! getVideoCategory（失败用 12 个静态分类兜底），列表走
//! getVideos，短视频走 getShortVideos；详情与取流靠扫列表
//! 找条目（findItem）；取流走 CDN 节点地址，探活失败时换
//! 1bf05/1bf06 节点重试；搜索走 6 个分类 × 8 页的本地池
//! 子串匹配（本站无搜索接口）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use futures::future::join_all;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const SITE: &str = "https://dy.ykfryrx.cn";
const PLATFORM: &str = "9";
const SALT: &str = "mucritmg";
const PAGE_SIZE: i64 = 20;
const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const CAT_TTL: Duration = Duration::from_secs(600);
const POOL_TTL: Duration = Duration::from_secs(900);

const FALLBACK_CATS: &[(&str, &str)] = &[
    ("1867182196224204800", "最新"),
    ("1894020375656161280", "精选"),
    ("1886971380250411008", "乱伦"),
    ("9764928318986788913", "国产自拍"),
    ("1893977910253346816", "网黄博主"),
    ("1897272767587745792", "尤物圈"),
    ("2079872705886507008", "黄豆魔改"),
    ("9764928318982594583", "传媒厂商"),
    ("9764928318990983203", "日韩AV"),
    ("9764928318986788886", "欧美超模"),
    ("9764928318990983174", "经典三级"),
    ("9764928318982594590", "痴汉专区"),
];

const POOL_CATS: &[&str] = &[
    "1867182196224204800",
    "1894020375656161280",
    "9764928318986788913",
    "9764928318982594583",
    "9764928318990983203",
    "1893977910253346816",
];

const CDN_NODES: &[&str] = &["1bf05", "1bf06"];

static CAT_CACHE: Mutex<Option<(Vec<Value>, Instant)>> = Mutex::new(None);
static POOL_CACHE: Mutex<Option<(Vec<Value>, Instant)>> = Mutex::new(None);

fn node_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(ycsf|txsf)1bf\d{2}\.(.+)$").unwrap())
}

fn node_re2() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(ycsf|txsf)(\d+)\.(.+)$").unwrap())
}

fn headers() -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", UA.to_string()),
        ("Accept", "application/json, text/plain, */*".to_string()),
        ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
        ("Referer", format!("{SITE}/h/tz/")),
    ]
}

async fn api(method: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let mut all: Vec<(String, String)> = vec![
        ("platform".to_string(), PLATFORM.to_string()),
        ("_b".to_string(), SALT.to_string()),
    ];
    for (k, v) in params {
        all.push((k.to_string(), v.to_string()));
    }
    let refs: Vec<(&str, &str)> = all.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let url = with_query(&format!("{SITE}/api/{method}"), &refs);
    let mut req = client()?.get(&url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("快播至臻版请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if super::int_of(&body, &["code"]) != 0 {
        return Err(ApiError::Internal("快播至臻版接口返回非 0".into()));
    }
    Ok(match get(&body, "data") {
        Some(d) => d.clone(),
        None => body,
    })
}

fn items_of(data: &Value) -> Vec<Value> {
    match get(data, "video_list")
        .and_then(|v| get(v, "data"))
        .and_then(arr_of)
    {
        Some(arr) => arr.clone(),
        None => Vec::new(),
    }
}

fn last_of(data: &Value) -> i64 {
    let Some(vl) = get(data, "video_list") else {
        return 0;
    };
    let last = int_of(vl, &["last_page"]);
    if last > 0 {
        return last;
    }
    let total = int_of(vl, &["total"]);
    if total > 0 {
        return (total + PAGE_SIZE - 1) / PAGE_SIZE;
    }
    0
}

async fn list_data(cat: &str, page: i64) -> ApiResult<Value> {
    api("getVideos", &[("id", cat), ("page", &page.to_string())]).await
}

async fn short_data(page: i64) -> ApiResult<Value> {
    api("getShortVideos", &[("page", &page.to_string())]).await
}

async fn categories_raw() -> Vec<Value> {
    if let Ok(guard) = CAT_CACHE.lock() {
        if let Some((cats, at)) = guard.as_ref() {
            if Instant::now() < *at + CAT_TTL {
                return cats.clone();
            }
        }
    }
    let mut cats: Vec<Value> = Vec::new();
    if let Ok(data) = api("getVideoCategory", &[]).await {
        if let Some(list) = get(&data, "video_category_list").and_then(arr_of) {
            if !list.is_empty() {
                cats = list.clone();
                if let Ok(mut guard) = CAT_CACHE.lock() {
                    *guard = Some((cats.clone(), Instant::now()));
                }
            }
        }
    }
    if cats.is_empty() {
        cats = FALLBACK_CATS
            .iter()
            .map(|(id, name)| json!({"id": id, "title": name, "children": []}))
            .collect();
    }
    cats
}

fn pic_of(e: &Value) -> String {
    text_of(e, &["image", "imagejs", "imagetxt"])
}

fn play_of(e: &Value) -> String {
    text_of(e, &["m3u8", "url", "play_url", "video_url"])
}

fn to_vod(e: &Value, prefix: &str) -> Option<Value> {
    let id = text_of(e, &["id"]);
    if id.is_empty() {
        return None;
    }
    let name = text_of(e, &["name", "title"]);
    let name = if name.is_empty() { id.clone() } else { name };
    let remark = text_of(e, &["remarks", "duration"]);
    Some(item_json(
        &format!("{prefix}{id}"),
        &name,
        &pic_of(e),
        &remark,
    ))
}

fn on_node_pool(url: &str) -> bool {
    let Ok(u) = url::Url::parse(url) else {
        return false;
    };
    let Some(host) = u.host_str() else {
        return false;
    };
    (host.starts_with("ycsf") || host.starts_with("txsf"))
        && (host.ends_with(".ablog168.com") || host.ends_with(".wasxzo82.com"))
}

fn swap_node(url: &str, node: &str) -> String {
    let Ok(u) = url::Url::parse(url) else {
        return url.to_string();
    };
    let Some(host) = u.host_str() else {
        return url.to_string();
    };
    let new_host = if let Some(cap) = node_re().captures(host) {
        format!("{}{}.{}", &cap[1], node, &cap[2])
    } else if let Some(cap) = node_re2().captures(host) {
        format!("{}{}.{}", &cap[1], node, &cap[3])
    } else {
        return url.to_string();
    };
    url.replacen(&format!("//{host}"), &format!("//{new_host}"), 1)
}

/// 探活：清单含 #EXTM3U，且首个 http 行的分片拉到 1024 字节以上。
async fn probe(url: &str) -> bool {
    let fut = async move {
        let req = client()
            .ok()?
            .get(url)
            .header("User-Agent", UA)
            .header("Referer", SITE)
            .timeout(Duration::from_secs(12));
        let resp = req.send().await.ok()?;
        let text = resp.text().await.ok()?;
        if !text.contains("#EXTM3U") {
            return None;
        }
        let first = text
            .lines()
            .map(|l| l.trim())
            .find(|l| l.starts_with("http"))?;
        let req2 = client()
            .ok()?
            .get(first)
            .header("User-Agent", UA)
            .header("Referer", SITE)
            .timeout(Duration::from_secs(12));
        let resp2 = req2.send().await.ok()?;
        let bytes = resp2.bytes().await.ok()?;
        if bytes.len() > 1024 {
            Some(())
        } else {
            None
        }
    };
    tokio::time::timeout(Duration::from_secs(13), fut)
        .await
        .ok()
        .flatten()
        .is_some()
}

async fn pick_playable(url: &str) -> String {
    if url.is_empty() || !on_node_pool(url) || probe(url).await {
        return url.to_string();
    }
    for node in CDN_NODES {
        let swapped = swap_node(url, node);
        if swapped != url && probe(&swapped).await {
            return swapped;
        }
    }
    url.to_string()
}

/// 在列表里找条目：有分类前缀时扫该分类 1..=6 页；无前缀先扫
/// 短视频，再扫全部分类 1..=3 页。
async fn find_item(vod_id: &str) -> Option<Value> {
    let (prefix, id) = match vod_id.split_once('|') {
        Some((p, i)) => (p.to_string(), i.to_string()),
        None => (String::new(), vod_id.to_string()),
    };
    if prefix == "short" {
        if let Ok(data) = short_data(1).await {
            for e in items_of(&data) {
                if text_of(&e, &["id"]) == id {
                    return Some(e);
                }
            }
        }
        return None;
    }
    if !prefix.is_empty() {
        for p in 1..=6 {
            let Ok(data) = list_data(&prefix, p).await else {
                break;
            };
            let items = items_of(&data);
            if items.is_empty() {
                break;
            }
            for e in items {
                if text_of(&e, &["id"]) == id {
                    return Some(e);
                }
            }
        }
        return None;
    }
    if let Ok(data) = short_data(1).await {
        for e in items_of(&data) {
            if text_of(&e, &["id"]) == id {
                return Some(e);
            }
        }
    }
    for cat in categories_raw().await {
        let cid = text_of(&cat, &["id"]);
        if cid.is_empty() || cid == "short" {
            continue;
        }
        for p in 1..=3 {
            let Ok(data) = list_data(&cid, p).await else {
                break;
            };
            let items = items_of(&data);
            if items.is_empty() {
                break;
            }
            for e in items {
                if text_of(&e, &["id"]) == id {
                    return Some(e);
                }
            }
        }
    }
    None
}

async fn find_in_pool(vod_id: &str) -> Option<Value> {
    for cat in categories_raw().await {
        let cid = text_of(&cat, &["id"]);
        if cid.is_empty() || cid == "short" {
            continue;
        }
        for p in 1..=5 {
            let Ok(data) = list_data(&cid, p).await else {
                break;
            };
            let items = items_of(&data);
            if items.is_empty() {
                break;
            }
            for e in items {
                if text_of(&e, &["id"]) == vod_id {
                    return Some(e);
                }
            }
        }
    }
    if let Ok(data) = short_data(1).await {
        for e in items_of(&data) {
            if text_of(&e, &["id"]) == vod_id {
                return Some(e);
            }
        }
    }
    None
}

async fn search_pool() -> Vec<Value> {
    if let Ok(guard) = POOL_CACHE.lock() {
        if let Some((pool, at)) = guard.as_ref() {
            if Instant::now() < *at + POOL_TTL {
                return pool.clone();
            }
        }
    }
    let mut pool: Vec<Value> = Vec::new();
    for cat in POOL_CATS {
        for p in 1..=8 {
            let Ok(data) = list_data(cat, p).await else {
                break;
            };
            let items = items_of(&data);
            if items.is_empty() {
                break;
            }
            for mut e in items {
                if let Some(m) = e.as_object_mut() {
                    m.insert("_src".to_string(), json!(cat));
                }
                pool.push(e);
            }
        }
    }
    if !pool.is_empty() {
        if let Ok(mut guard) = POOL_CACHE.lock() {
            *guard = Some((pool.clone(), Instant::now()));
        }
    }
    pool
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let raw = categories_raw().await;
    let mut list: Vec<Value> = Vec::new();
    for cat in &raw {
        let id = text_of(cat, &["id"]);
        let name = text_of(cat, &["title"]);
        if id.is_empty() || name.is_empty() {
            continue;
        }
        list.push(category_json(&id, &name));
        if let Some(children) = get(cat, "children").and_then(arr_of) {
            for ch in children {
                let cid = text_of(ch, &["id"]);
                let cname = text_of(ch, &["title"]);
                if !cid.is_empty() && !cname.is_empty() {
                    list.push(category_json(
                        &format!("{id}|{cid}"),
                        &format!("{name}·{cname}"),
                    ));
                }
            }
        }
    }
    list.push(category_json("short", "🔥短视频"));
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (data, last) = if category_id == "short" {
        (short_data(page).await?, 9999)
    } else {
        // 子分类 id 形如 <父>|<子>：按子 id 取列表。
        let list_id = category_id
            .split_once('|')
            .map(|(_, c)| c)
            .unwrap_or(category_id);
        let data = list_data(list_id, page).await?;
        let last = last_of(&data);
        (data, last)
    };
    let items_raw = items_of(&data);
    let prefix = if category_id == "short" {
        "short|".to_string()
    } else {
        format!(
            "{}|",
            category_id
                .split_once('|')
                .map(|(_, c)| c)
                .unwrap_or(category_id)
        )
    };
    let mut items = Vec::new();
    for e in &items_raw {
        if let Some(v) = to_vod(e, &prefix) {
            items.push(v);
        }
    }
    Ok(json!({
        "items": items,
        "has_more": last > 0 && page < last,
    }))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let item = find_item(series_id).await;
    let Some(item) = item else {
        return Ok(json!({
            "id": series_id,
            "title": "快播至臻版",
            "cover": "",
            "synopsis": "这条从源上取不回来了，返回列表换一条吧。",
            "extra": {"remark": "条目已失效"},
            "episodes": [],
        }));
    };
    let title = text_of(&item, &["name", "title"]);
    let cover = pic_of(&item);
    let dur = text_of(&item, &["duration"]);
    let views = int_of(&item, &["views"]);
    let likes = int_of(&item, &["likes"]);
    let remarks = text_of(&item, &["remarks"]);
    let media_type = text_of(&item, &["media_type"]);
    let mut content = String::new();
    if !remarks.is_empty() {
        content.push_str(&remarks);
        content.push_str(" ｜ ");
    }
    content.push_str(&format!(
        "时长 {} ｜ 播放 {views} ｜ 点赞 {likes}",
        if dur.is_empty() {
            "--".to_string()
        } else {
            dur
        }
    ));
    let type_name = if media_type == "2" {
        "短视频"
    } else {
        "长视频"
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": content,
        "extra": {"type": type_name, "duration": dur},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut vid = video_id.trim().to_string();
    if !vid.starts_with("http") {
        let item = find_item(&vid).await;
        let item = match item {
            Some(i) => Some(i),
            None if !vid.contains('|') => find_in_pool(&vid).await,
            None => None,
        };
        if let Some(i) = item {
            let p = play_of(&i);
            if !p.is_empty() {
                vid = pick_playable(&p).await;
            }
        }
    }
    if vid.starts_with("http") {
        return Ok(json!({
            "url": vid,
            "header": {"User-Agent": UA, "Referer": format!("{SITE}/")},
        }));
    }
    Err(ApiError::Internal("快播至臻版未取到播放地址".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let pool = search_pool().await;
    let needle = query.to_lowercase();
    let mut items = Vec::new();
    for e in &pool {
        if items.len() >= 60 {
            break;
        }
        let name = text_of(e, &["name", "title"]);
        if name.is_empty() || !name.to_lowercase().contains(&needle) {
            continue;
        }
        let src = text_of(e, &["_src"]);
        if let Some(v) = to_vod(e, &format!("{src}|")) {
            items.push(v);
        }
    }
    if items.is_empty() && pool.is_empty() {
        items.push(item_json(
            "diagnostic",
            "快播至臻版 · 搜索池拉取失败",
            "",
            "换个网络再试，或直接进分类翻",
        ));
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_pool_check() {
        assert!(on_node_pool("https://ycsf1bf05.ablog168.com/x.m3u8"));
        assert!(on_node_pool("https://txsf123.wasxzo82.com/x.m3u8"));
        assert!(!on_node_pool("https://cdn.example.com/x.m3u8"));
    }

    #[test]
    fn swap_node_rules() {
        assert_eq!(
            swap_node("https://ycsf1bf03.ablog168.com/a.m3u8", "1bf05"),
            "https://ycsf1bf05.ablog168.com/a.m3u8"
        );
        assert_eq!(
            swap_node("https://txsf999.wasxzo82.com/a.m3u8", "1bf06"),
            "https://txsf1bf06.wasxzo82.com/a.m3u8"
        );
    }

    #[test]
    fn fallback_cat_count() {
        assert_eq!(FALLBACK_CATS.len(), 12);
    }
}
