//! 香蕉视频：API 站，基地址先试默认
//! lw7k481j3l003h95pnwf.xjspapps.com，再试 5 个发现域名
//! （ios.bxguwen.com 直连，其余随机 12 位子域名），
//! /getGlobalData 回 retcode 0 者为准。列表走 /index、
//! /vod/<榜单>-0-…-<页>、/minivod/<榜>-0-…-<页>、专题走
//! /special/listing-0-0-1；详情先查缓存、再扫 3 个榜单；
//! 取流走 /vod/reqplay/<id>（带随机 X-Forwarded-For），
//! retcode 6 为空，data.httpurl 为直链。

use std::collections::HashSet;
use std::sync::Mutex;

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const DEFAULT_BASE: &str = "https://lw7k481j3l003h95pnwf.xjspapps.com";
const DISCOVER_DOMAINS: &[&str] = &[
    "ios.bxguwen.com",
    "025vslo7kf.com",
    "5usaoh4t88.com",
    "xzjgz.com",
    "hm789.top",
];
const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";

/// 17 个静态分类，与 jar 的 classes() 一致。
const CLASSES: &[(&str, &str)] = &[
    ("home:latestrows", "首页·最新视频"),
    ("home:likerows", "首页·猜你喜欢"),
    ("home:a_vodrows", "首页·偷拍自拍"),
    ("home:b_vodrows", "首页·成人动漫"),
    ("home:c_vodrows", "首页·经典伦理"),
    ("home:d_vodrows", "首页·中文字幕"),
    ("home:tagvodrows", "首页·不雅视频"),
    ("home:hotrows", "首页·热片视频"),
    ("vod:recommend", "榜单·推荐"),
    ("vod:hot", "榜单·热点"),
    ("vod:latest", "榜单·最新"),
    ("specials", "专题"),
    ("mini:topzan", "短视频·点赞榜"),
    ("mini:topcomment", "短视频·评论榜"),
    ("mini:topplay", "短视频·播放榜"),
    ("mini:topnew", "短视频·最新榜"),
    ("mini:topcoin", "短视频·投币榜"),
];

static BASE_CACHE: Mutex<Option<String>> = Mutex::new(None);
static CACHE: Mutex<Vec<(String, Value)>> = Mutex::new(Vec::new());

fn rand_sub() -> String {
    use rand::Rng;
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    (0..12)
        .map(|_| CHARS[rng.gen_range(0..36)] as char)
        .collect()
}

fn rand_ip() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    format!(
        "{}.{}.{}.{}",
        rng.gen_range(1..255),
        rng.gen_range(0..256),
        rng.gen_range(0..256),
        rng.gen_range(0..256)
    )
}

async fn http_get_json(url: &str, extra: &[(&str, &str)]) -> ApiResult<Value> {
    let mut req = client()?.get(url).header("User-Agent", UA);
    for (k, v) in extra {
        req = req.header(*k, *v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("香蕉视频请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    Ok(body)
}

async fn ensure_base() -> String {
    if let Ok(guard) = BASE_CACHE.lock() {
        if let Some(b) = guard.as_ref() {
            return b.clone();
        }
    }
    let mut base = DEFAULT_BASE.to_string();
    for domain in DISCOVER_DOMAINS {
        let candidate = if domain.contains("ios") {
            format!("https://{domain}")
        } else {
            format!("https://{}.{domain}", rand_sub())
        };
        if let Ok(body) = http_get_json(&format!("{candidate}/getGlobalData"), &[]).await {
            if super::int_of(&body, &["retcode"]) == 0 {
                base = candidate;
                break;
            }
        }
    }
    if let Ok(mut guard) = BASE_CACHE.lock() {
        *guard = Some(base.clone());
    }
    base
}

async fn call(path: &str, extra: &[(&str, &str)]) -> ApiResult<Value> {
    let base = ensure_base().await;
    http_get_json(&format!("{base}{path}"), extra).await
}

fn is_paid(e: &Value) -> bool {
    text_of(e, &["isvip"]) == "1"
}

fn card(e: &Value, allow_paid: bool) -> Option<Value> {
    let id = text_of(e, &["vodid"]);
    let title = text_of(e, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let paid = is_paid(e);
    if paid && !allow_paid {
        return None;
    }
    let mut remark = if paid {
        "付费".to_string()
    } else {
        text_of(e, &["catename"])
    };
    if remark.is_empty() && !paid {
        remark = text_of(e, &["definition"]);
    }
    let cover = text_of(e, &["coverpic"]);
    let mut item = item_json(&id, &title, &cover, &remark);
    if let Some(m) = item.as_object_mut() {
        m.insert("type_name".to_string(), json!(text_of(e, &["catename"])));
        m.insert("content".to_string(), json!(text_of(e, &["intro"])));
    }
    if let Ok(mut guard) = CACHE.lock() {
        guard.retain(|(k, _)| k != &id);
        guard.push((id, e.clone()));
    }
    Some(item)
}

/// 去重；全为付费时放行付费（与 Java 的 cards 两遍逻辑一致）。
fn cards(list: &[Value]) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for e in list {
        if let Some(v) = card(e, false) {
            let id = text_of(&v, &["id"]);
            if seen.insert(id) {
                out.push(v);
            }
        }
    }
    if out.is_empty() {
        for e in list {
            if let Some(v) = card(e, true) {
                let id = text_of(&v, &["id"]);
                if seen.insert(id) {
                    out.push(v);
                }
            }
        }
    }
    out
}

fn list_obj(items: Vec<Value>, page: i64) -> Value {
    let has_more = !items.is_empty();
    json!({"items": items, "has_more": has_more, "page": page})
}

async fn find_video(id: &str) -> Option<Value> {
    for path in [
        "/vod/recommend-0-0-0-0-0-0-0-0-0-1",
        "/vod/hot-0-0-0-0-0-0-0-0-0-1",
        "/vod/latest-0-0-0-0-0-0-0-0-0-1",
    ] {
        if let Ok(body) = call(path, &[]).await {
            if let Some(rows) = get(&body, "data")
                .and_then(|d| get(d, "vodrows"))
                .and_then(arr_of)
            {
                for e in rows {
                    if text_of(e, &["vodid"]) == id {
                        return Some(e.clone());
                    }
                }
            }
        }
    }
    None
}

fn cache_get(id: &str) -> Option<Value> {
    if let Ok(guard) = CACHE.lock() {
        for (k, v) in guard.iter() {
            if k == id {
                return Some(v.clone());
            }
        }
    }
    None
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CLASSES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if let Some(row) = category_id.strip_prefix("home:") {
        if page > 1 {
            return Ok(list_obj(Vec::new(), page));
        }
        let body = call("/index", &[]).await?;
        let rows = get(&body, "data")
            .and_then(|d| get(d, row))
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        return Ok(list_obj(cards(&rows), page));
    }
    if let Some(kind) = category_id.strip_prefix("vod:") {
        let body = call(&format!("/vod/{kind}-0-0-0-0-0-0-0-0-0-{page}"), &[]).await?;
        let rows = get(&body, "data")
            .and_then(|d| get(d, "vodrows"))
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        return Ok(list_obj(cards(&rows), page));
    }
    if category_id == "specials" {
        if page > 1 {
            return Ok(list_obj(Vec::new(), page));
        }
        let body = call("/special/listing-0-0-1", &[]).await?;
        let mut items = Vec::new();
        if let Some(rows) = get(&body, "data")
            .and_then(|d| get(d, "rows"))
            .and_then(arr_of)
        {
            for e in rows {
                let spid = text_of(e, &["spid"]);
                let name = text_of(e, &["spname"]);
                if spid.is_empty() || name.is_empty() {
                    continue;
                }
                let mut item = item_json(
                    &format!("dir:special:{spid}"),
                    &name,
                    &text_of(e, &["coverpic"]),
                    &text_of(e, &["itemcount"]),
                );
                if let Some(m) = item.as_object_mut() {
                    m.insert("tag".to_string(), json!("folder"));
                    m.insert("type_name".to_string(), json!("专题"));
                }
                items.push(item);
            }
        }
        return Ok(list_obj(items, page));
    }
    if let Some(kind) = category_id.strip_prefix("mini:") {
        let body = call(&format!("/minivod/{kind}-0-0-0-0-0-0-0-0-0-0-{page}"), &[]).await?;
        let rows = get(&body, "data")
            .and_then(|d| get(d, "vodrows"))
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        return Ok(list_obj(cards(&rows), page));
    }
    if let Some(kw) = category_id.strip_prefix("dir:actor:") {
        return search(kw).await;
    }
    let body = call(&format!("/vod/recommend-0-0-0-0-0-0-0-0-0-{page}"), &[]).await?;
    let rows = get(&body, "data")
        .and_then(|d| get(d, "vodrows"))
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    Ok(list_obj(cards(&rows), page))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if let Some(spid) = series_id.strip_prefix("dir:special:") {
        let body = call(&format!("/special/detail/{spid}"), &[]).await?;
        let data = get(&body, "data").cloned().unwrap_or(Value::Null);
        let row = get(&data, "row").cloned().unwrap_or(Value::Null);
        let name = text_of(&row, &["spname"]);
        let name = if name.is_empty() {
            spid.to_string()
        } else {
            name
        };
        let cover = text_of(&row, &["coverpic"]);
        let intro = text_of(&row, &["intro"]);
        let rows = get(&data, "vodrows")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        let eps = cards(&rows);
        let play_url = eps
            .iter()
            .map(|e| format!("{}${}", text_of(e, &["title"]), text_of(e, &["id"])))
            .collect::<Vec<_>>()
            .join("#");
        return Ok(json!({
            "id": series_id,
            "title": name,
            "cover": cover,
            "synopsis": intro,
            "extra": {"type": "专题"},
            "episodes": [episode_json(&play_url, "专题", series_id)],
        }));
    }
    let found = match cache_get(series_id) {
        Some(v) => Some(v),
        None => find_video(series_id).await,
    };
    let title = found
        .as_ref()
        .map(|v| text_of(v, &["title"]))
        .unwrap_or_default();
    let title = if title.is_empty() {
        format!("视频{series_id}")
    } else {
        title
    };
    let cover = found
        .as_ref()
        .map(|v| text_of(v, &["coverpic"]))
        .unwrap_or_default();
    let catename = found
        .as_ref()
        .map(|v| text_of(v, &["catename"]))
        .unwrap_or_default();
    let intro = found
        .as_ref()
        .map(|v| text_of(v, &["intro"]))
        .unwrap_or_default();
    let actor_tags = found
        .as_ref()
        .map(|v| text_of(v, &["actor_tags"]))
        .unwrap_or_default();
    let paid = found.as_ref().map(|v| is_paid(v)).unwrap_or(false);
    let remark = if paid { "付费".to_string() } else { catename };
    let mut extra = serde_json::Map::new();
    if !actor_tags.is_empty() {
        extra.insert("actor".to_string(), json!(actor_tags));
    }
    if !remark.is_empty() {
        extra.insert("remark".to_string(), json!(remark));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": intro,
        "extra": extra,
        "episodes": if paid { vec![] } else { vec![episode_json(series_id, "正片", series_id)] },
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let base = ensure_base().await;
    let mut vid = video_id.to_string();
    if let Some(p) = vid.find('$') {
        vid = vid[p + 1..].to_string();
    }
    if vid.starts_with("http") {
        return Ok(json!({
            "url": vid,
            "header": {"User-Agent": UA, "Referer": format!("{base}/")},
        }));
    }
    let body = call(
        &format!("/vod/reqplay/{vid}"),
        &[("X-Forwarded-For", &rand_ip())],
    )
    .await?;
    let mut url = String::new();
    if super::int_of(&body, &["retcode"]) != 6 {
        if let Some(data) = get(&body, "data") {
            url = text_of(data, &["httpurl"]);
        }
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{base}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let body = call(&format!("/search?page=1&wd={encoded}"), &[]).await?;
    let data = get(&body, "data").cloned().unwrap_or(Value::Null);
    let mut rows = get(&data, "vodrows")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    if rows.is_empty() {
        rows = get(&data, "hotrows")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
    }
    Ok(json!({"items": cards(&rows)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_count() {
        assert_eq!(CLASSES.len(), 17);
    }

    #[test]
    fn cards_paid_fallback() {
        let rows = vec![
            json!({"vodid": "1", "title": "A", "isvip": "1"}),
            json!({"vodid": "2", "title": "B", "isvip": "1"}),
        ];
        let items = cards(&rows);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["remark"], "付费");
    }

    #[test]
    fn cards_skip_paid_when_free_exists() {
        let rows = vec![
            json!({"vodid": "1", "title": "A", "isvip": "1"}),
            json!({"vodid": "2", "title": "B", "isvip": "0", "catename": "国产"}),
        ];
        let items = cards(&rows);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2");
    }
}
