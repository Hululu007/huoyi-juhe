//! 爱液视频：官方 App 接口。
//!
//! 来源 jar 类 `ZakaAiyeAmns`。域名先走 DNS TXT 发现
//! （`hostnew.aiye.me` 的 TXT 记录 base64 解码得 `{"url":[...]}`，
//! 无则 `host.aiye.me`，再无则内置 4 个 `0826.aiyejikou000N.com`），
//! 再逐个 `GET /api/home/indextypelist?types=1&type=0` 验
//! `"code":200`，首个通过的置顶，30 分钟缓存。
//! 分类是 `T{id}`（类型）+ `L{id}`（标签文件夹）；`T{id}` 的
//! 目录是子文件夹，子文件夹的原始 id 再进 `/api/vod/list?types=`
//! 取视频；详情走 `/api/vod/info`，线路走
//! `/api/vod/line/list`，分集 id 为 `{视频id}@{线路序号}`。

use base64::Engine as _;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const APPID: &str = "com.aayydd.bsd";
const UA: &str = "okhttp/4.9.0";
const PAGE_SIZE: i64 = 20;
const TXT_POOL: &str = "https://dns.alidns.com/resolve?name=hostnew.aiye.me&short=true&type=16";
const TXT_POOL2: &str = "https://doh.pub/dns-query?name=hostnew.aiye.me&type=TXT";
const TXT_ONE: &str = "https://dns.alidns.com/resolve?name=host.aiye.me&short=true&type=16";
const BUILTIN: &[&str] = &[
    "https://0826.aiyejikou0001.com",
    "https://0826.aiyejikou0002.com",
    "https://0826.aiyejikou0003.com",
    "https://0826.aiyejikou0004.com",
];

static HOSTS: Lazy<Mutex<(Vec<String>, std::time::Instant, usize)>> =
    Lazy::new(|| Mutex::new((Vec::new(), std::time::Instant::now(), 0)));

fn headers() -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", UA.to_string()),
        ("Accept", "application/json, text/plain, */*".to_string()),
        ("x-appid", APPID.to_string()),
        ("terminalType", "android".to_string()),
    ]
}

fn norm_host(s: &str) -> String {
    let mut s = s.trim().to_string();
    if s.is_empty() {
        return s;
    }
    if !s.starts_with("http") {
        s = format!("https://{s}");
    }
    while s.ends_with('/') {
        s.pop();
    }
    s
}

async fn txt(url: &str) -> Option<String> {
    let resp = client().ok()?.get(url).send().await.ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let text = resp.text().await.ok()?;
    let mut s = text.trim().to_string();
    if s.starts_with('[') {
        let arr: Value = serde_json::from_str(&s).ok()?;
        s = arr.as_array()?.first()?.as_str()?.to_string();
    } else if let Some(i) = s.find("\"data\"") {
        let after = &s[i..];
        if let Some(colon) = after.find(':') {
            let rest = &after[colon + 1..];
            let first = rest.find('"')?;
            let second = rest[first + 1..].find('"')?;
            s = rest[first + 1..first + 1 + second].to_string();
        }
    }
    let s = s.trim().trim_matches('"').trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn b64d_safe(s: &str) -> Option<String> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes())
        .ok()
        .or_else(|| {
            base64::engine::general_purpose::URL_SAFE
                .decode(s.as_bytes())
                .ok()
        })?;
    let text = String::from_utf8_lossy(&decoded).to_string();
    if text.contains('{') {
        Some(text)
    } else {
        None
    }
}

async fn refresh_hosts() -> Vec<String> {
    let mut list: Vec<String> = Vec::new();
    let mut pool_txt = txt(TXT_POOL).await;
    if pool_txt.as_deref().unwrap_or("").is_empty() {
        pool_txt = txt(TXT_POOL2).await;
    }
    if let Some(t) = pool_txt {
        if let Some(decoded) = b64d_safe(&t) {
            if let Ok(v) = serde_json::from_str::<Value>(&decoded) {
                if let Some(urls) = get(&v, "url").and_then(arr_of) {
                    for u in urls {
                        let h = norm_host(u.as_str().unwrap_or(""));
                        if !h.is_empty() && !list.contains(&h) {
                            list.push(h);
                        }
                    }
                }
            }
        }
    }
    if list.is_empty() {
        if let Some(t) = txt(TXT_ONE).await {
            let h = norm_host(&t);
            if !h.is_empty() {
                list.push(h);
            }
        }
    }
    if list.is_empty() {
        for h in BUILTIN {
            list.push(h.to_string());
        }
    }
    // 逐个验活，首个通过的置顶。
    for i in 0..list.len() {
        let url = format!("{}/api/home/indextypelist?types=1&type=0", list[i]);
        let mut req = client().ok().map(|c| c.get(&url));
        if let Some(r) = req.take() {
            let mut r = r;
            for (k, v) in headers() {
                r = r.header(k, v);
            }
            if let Ok(resp) = r.send().await {
                if let Ok(text) = resp.text().await {
                    if text.contains("\"code\":200") {
                        let h = list.remove(i);
                        list.insert(0, h);
                        break;
                    }
                }
            }
        }
    }
    list
}

async fn base() -> ApiResult<String> {
    {
        let guard = HOSTS.lock().unwrap();
        let (list, ts, idx) = (&guard.0, guard.1, guard.2);
        if !list.is_empty() && ts.elapsed().as_secs() < 1800 {
            let i = if idx < list.len() { idx } else { 0 };
            return Ok(list[i].clone());
        }
    }
    let list = refresh_hosts().await;
    let mut guard = HOSTS.lock().unwrap();
    *guard = (list.clone(), std::time::Instant::now(), 0);
    list.first()
        .cloned()
        .ok_or_else(|| ApiError::Internal("爱液视频没有可用域名".into()))
}

fn rotate() {
    let mut guard = HOSTS.lock().unwrap();
    if guard.0.len() > 1 {
        guard.2 = (guard.2 + 1) % guard.0.len();
    }
    guard.1 = std::time::Instant::now()
        .checked_sub(std::time::Duration::from_secs(3600))
        .unwrap_or(std::time::Instant::now());
}

async fn api(path: &str) -> ApiResult<Value> {
    let mut last: Option<Value> = None;
    for _ in 0..3 {
        let host = base().await?;
        let url = format!("{host}{path}");
        let mut req = client()?.get(&url);
        for (k, v) in headers() {
            req = req.header(k, v);
        }
        let resp = req.send().await;
        match resp {
            Ok(r) => {
                if let Ok(text) = r.text().await {
                    if let Ok(v) = serde_json::from_str::<Value>(&text) {
                        let code = get(&v, "code").and_then(|c| c.as_i64()).unwrap_or(0);
                        if code == 200 {
                            return Ok(v);
                        }
                        last = Some(v);
                    }
                }
            }
            Err(e) => {
                let _ = e;
            }
        }
        rotate();
    }
    last.ok_or_else(|| ApiError::Internal("爱液视频接口请求失败".into()))
}

fn data_list(body: &Value) -> Vec<&Value> {
    match get(body, "data")
        .and_then(|d| get(d, "list"))
        .and_then(arr_of)
    {
        Some(a) => a.iter().collect(),
        None => Vec::new(),
    }
}

fn data_total(body: &Value) -> i64 {
    get(body, "data")
        .and_then(|d| get(d, "total"))
        .and_then(|v| v.as_i64())
        .unwrap_or(0)
}

fn remark_of(row: &Value) -> String {
    let duration = get(row, "duration").and_then(|v| v.as_i64()).unwrap_or(0);
    let views = get(row, "views").and_then(|v| v.as_i64()).unwrap_or(0);
    let mut remark = String::new();
    if duration > 0 {
        let mins = duration / 60;
        if mins >= 60 {
            remark.push_str(&format!("{} 时 {} 分钟", mins / 60, mins % 60));
        } else {
            remark.push_str(&format!("{mins} 分钟"));
        }
    }
    if views > 0 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        if views >= 10000 {
            remark.push_str(&format!("{}万播放", views / 10000));
        } else {
            remark.push_str(&format!("{views} 播放"));
        }
    }
    remark
}

fn card(row: &Value) -> Value {
    let id = text_of(row, &["id"]);
    let mut title = text_of(row, &["title"]);
    if title.is_empty() {
        title = format!("视频 {id}");
    }
    let cover = text_of(row, &["cover"]);
    item_json(&id, &title, &cover, &remark_of(row))
}

fn folder(id: &str, name: &str, cover: &str, remark: &str) -> Value {
    let mut item = item_json(id, name, cover, remark);
    item["is_folder"] = json!(true);
    item
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    let nav = api("/api/home/indextypelist?types=1&type=0").await?;
    for row in data_list(&nav) {
        let id = text_of(row, &["id"]);
        let name = text_of(row, &["name"]);
        if !id.is_empty() {
            list.push(category_json(&format!("T{id}"), &name));
        }
    }
    let tags = api("/api/home/indextaglist").await?;
    for row in data_list(&tags) {
        let id = text_of(row, &["id"]);
        let name = text_of(row, &["name"]);
        if id.is_empty() {
            continue;
        }
        let mut cover = String::new();
        let mut count = 0i64;
        if let Some(sub) = get(row, "list").and_then(arr_of) {
            count = sub.len() as i64;
            if let Some(first) = sub.first() {
                cover = text_of(first, &["cover"]);
            }
        }
        list.push(category_json(&format!("L{id}"), &name));
        let _ = (cover, count);
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    if let Some(id) = category_id.strip_prefix('T') {
        // T 类的目录是子文件夹。
        let nav = api(&format!("/api/home/indextypelist?types=1&type={id}")).await?;
        let mut items = Vec::new();
        for row in data_list(&nav) {
            let sub_id = text_of(row, &["id"]);
            let name = text_of(row, &["name"]);
            let mut cover = String::new();
            let mut count = 0i64;
            if let Some(sub) = get(row, "list").and_then(arr_of) {
                count = sub.len() as i64;
                if let Some(first) = sub.first() {
                    cover = text_of(first, &["cover"]);
                }
            }
            items.push(folder(&sub_id, &name, &cover, &format!("{count} 部精选")));
        }
        return Ok(json!({"items": items, "has_more": false}));
    }
    let path = if let Some(id) = category_id.strip_prefix('L') {
        format!("/api/vod/list?labels={id}&page={page}")
    } else {
        format!("/api/vod/list?types={category_id}&page={page}")
    };
    let body = api(&path).await?;
    let items: Vec<Value> = data_list(&body).iter().map(|r| card(r)).collect();
    let total = data_total(&body);
    let has_more = if total > 0 {
        page * PAGE_SIZE < total
    } else {
        items.len() as i64 >= PAGE_SIZE
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let info = api(&format!("/api/vod/info?id={series_id}")).await?;
    let data = get(&info, "data").cloned().unwrap_or(Value::Null);
    let mut title = text_of(&data, &["title"]);
    if title.is_empty() {
        title = format!("视频 {series_id}");
    }
    let cover = text_of(&data, &["cover"]);
    let mut synopsis = format!("片号：{series_id}");
    let mut labels = Vec::new();
    if let Some(arr) = get(&data, "labels").and_then(arr_of) {
        for l in arr {
            let name = text_of(l, &["name"]);
            if !name.is_empty() {
                labels.push(name);
            }
        }
    }
    if !labels.is_empty() {
        synopsis.push_str(&format!("\n标签：{}", labels.join(" / ")));
    }
    let views = get(&data, "views").and_then(|v| v.as_i64()).unwrap_or(0);
    let favs = get(&data, "favorites")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    if views > 0 || favs > 0 {
        synopsis.push_str(&format!("\n播放 {views} · 收藏 {favs}"));
    }
    synopsis.push_str("\n来源：爱液视频");
    let lines = api(&format!("/api/vod/line/list?vodid={series_id}")).await?;
    let mut episodes = Vec::new();
    let mut idx = 0i64;
    for row in data_list(&lines) {
        let domain = text_of(row, &["domain"]);
        if domain.is_empty() {
            continue;
        }
        let name = text_of(row, &["name"]);
        let name = if name.is_empty() {
            format!("线路{}", idx + 1)
        } else {
            name
        };
        episodes.push(episode_json(
            &format!("{series_id}@{idx}"),
            &name,
            series_id,
        ));
        idx += 1;
    }
    let play_url = text_of(&data, &["play_url"]);
    if episodes.is_empty() && !play_url.is_empty() {
        episodes.push(episode_json(
            &format!("{series_id}@0"),
            "默认线路",
            series_id,
        ));
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("爱液视频详情暂无可播线路".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"labels": labels.join(" / ")},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let body = api(&format!("/api/vod/clever?wd={enc}&page=1")).await?;
    let items: Vec<Value> = data_list(&body).iter().map(|r| card(r)).collect();
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (vid, idx) = match video_id.rsplit_once('@') {
        Some((v, i)) => (v.to_string(), i.parse::<usize>().unwrap_or(0)),
        None => (video_id.to_string(), 0),
    };
    let lines = api(&format!("/api/vod/line/list?vodid={vid}")).await?;
    let rows = data_list(&lines);
    let mut domain = String::new();
    if idx < rows.len() {
        domain = text_of(rows[idx], &["domain"]);
    }
    if domain.is_empty() && !rows.is_empty() {
        domain = text_of(rows[0], &["domain"]);
    }
    if domain.is_empty() {
        let info = api(&format!("/api/vod/info?id={vid}")).await?;
        domain = text_of(
            &get(&info, "data").cloned().unwrap_or(Value::Null),
            &["play_url"],
        );
    }
    if domain.is_empty() {
        return Err(ApiError::Internal("爱液视频没有播放地址".into()));
    }
    Ok(json!({"url": domain}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn norm_host_adds_scheme() {
        assert_eq!(norm_host("a.com"), "https://a.com");
        assert_eq!(norm_host("https://a.com/"), "https://a.com");
        assert_eq!(norm_host(""), "");
    }

    #[test]
    fn b64d_safe_decodes_txt_json() {
        let payload = base64::engine::general_purpose::STANDARD
            .encode(r#"{"url":["https://x.example.com"]}"#);
        let dec = b64d_safe(&payload).expect("decode");
        assert!(dec.contains("x.example.com"));
    }

    #[test]
    fn remark_formats_duration_and_views() {
        let row = json!({"duration": 3660, "views": 25000});
        assert_eq!(remark_of(&row), "1 时 1 分钟 · 2万播放");
        let row2 = json!({"duration": 300, "views": 500});
        assert_eq!(remark_of(&row2), "5 分钟 · 500 播放");
    }
}
