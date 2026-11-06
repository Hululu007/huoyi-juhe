//! 探花短视频（thdh）：token + 视频/漫画双分类站。
//!
//! - 9 个候选 host，默认第一个；token 失败时按序换 host 重试。
//! - token：POST {site}/index/member.php，表单
//!   type=init&device_id=zk<毫秒十六进制><随机十六进制>&strength=high
//!   &platform=android，响应 code==1 取 data.token；后续请求带
//!   X-Member-Token 头；code==2 时刷新 token 一次。
//! - 分类与站导航 1:1：video 探花短视频、comic 里番漫画。
//! - 视频目录 /index/video.php?type=list&page=N（24 条/页）；详情
//!   ?type=detail&id=；取流 POST type=play_token&id=&free=1，
//!   得 play_url 后跟随跳转取最终地址（最多 3 次）。
//! - 漫画目录 /index/comic.php?type=list&page=N；详情带 chapters，
//!   剧集 video_id 为 ch:<章节id>；取流 ?type=chapter&id=，
//!   取 data.pages[].image_url 拼成 pics:// 地址（图片在播放器内浏览）。
//! - 搜索：站方两个 searchContent 均直接返回空列表，这里同样返回空。

use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const HOSTS: [&str; 9] = [
    "https://thdhhaj.xyz",
    "https://thdhran.xyz",
    "https://thdhjtd.xyz",
    "https://thdhaci.com",
    "https://thdhasw.com",
    "https://thdhadi.com",
    "https://oazgcgg.xyz",
    "https://kbmlarn.xyz",
    "https://ayzizdw.xyz",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 24;

static SITE: Mutex<String> = Mutex::new(String::new());
static TOKEN: Mutex<Option<String>> = Mutex::new(None);

fn site() -> String {
    if let Ok(guard) = SITE.lock() {
        if !guard.is_empty() {
            return guard.clone();
        }
    }
    HOSTS[0].to_string()
}

fn set_site(host: &str) {
    if let Ok(mut guard) = SITE.lock() {
        *guard = host.to_string();
    }
}

fn set_token(token: &str) {
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = Some(token.to_string());
    }
}

fn cached_token() -> Option<String> {
    TOKEN.lock().ok().and_then(|g| g.clone())
}

fn device_id() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let rand: u32 = rand::random();
    format!("zk{ms:x}{rand:x}")
}

fn base_headers(site: &str, with_token: bool) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "application/json, text/plain, */*".to_string(),
        ),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
        ("X-Requested-With".to_string(), "XMLHttpRequest".to_string()),
        ("Referer".to_string(), format!("{site}/")),
    ];
    if with_token {
        if let Some(t) = cached_token() {
            h.push(("X-Member-Token".to_string(), t));
        }
    }
    h
}

/// 换 token：按序试各 host，直到拿到 token。
async fn refresh_token() -> ApiResult<()> {
    let hosts: Vec<String> = {
        let cur = site();
        let mut v: Vec<String> = HOSTS.iter().map(|s| s.to_string()).collect();
        v.sort_by_key(|h| if *h == cur { 0 } else { 1 });
        v
    };
    for host in hosts {
        let body = format!(
            "type=init&device_id={}&strength=high&platform=android",
            device_id()
        );
        let mut req = client()?.post(format!("{host}/index/member.php")).header(
            "Content-Type",
            "application/x-www-form-urlencoded; charset=UTF-8",
        );
        for (k, v) in base_headers(&host, false) {
            req = req.header(k, v);
        }
        let resp = req
            .body(body)
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        if resp.status().as_u16() != 200 {
            continue;
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if int_of(&value, &["code"]) == 1 {
            let token = get(&value, "data")
                .map(|d| text_of(d, &["token"]))
                .unwrap_or_default();
            if !token.is_empty() {
                set_site(&host);
                set_token(&token);
                return Ok(());
            }
        }
    }
    Err(ApiError::Internal("探花短视频 token 获取失败".into()))
}

async fn ensure_token() -> ApiResult<()> {
    if cached_token().is_some() {
        return Ok(());
    }
    refresh_token().await
}

/// 站方 JSON 请求：code==1 取 data；code==2 刷新 token 重试一次。
async fn get_json(url: &str) -> ApiResult<Value> {
    ensure_token().await?;
    tokio::time::sleep(Duration::from_millis(220)).await;
    let host = site();
    let mut attempt = 0;
    loop {
        let mut req = client()?.get(url);
        for (k, v) in base_headers(&host, true) {
            req = req.header(k, v);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let status = resp.status().as_u16();
        if status != 200 {
            return Err(ApiError::Internal(format!("探花短视频请求 HTTP {status}")));
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let code = int_of(&value, &["code"]);
        if code == 1 {
            return Ok(get(&value, "data").cloned().unwrap_or(Value::Null));
        }
        if code == 2 && attempt == 0 {
            attempt += 1;
            refresh_token().await?;
            continue;
        }
        return Err(ApiError::Internal(format!("探花短视频接口 code={code}")));
    }
}

fn fix_cover(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("//") {
        format!("https://{rest}")
    } else {
        url.to_string()
    }
}

fn video_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in rows {
        let id = text_of(e, &["id"]);
        let title = text_of(e, &["title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = fix_cover(&text_of(e, &["cover_url"]));
        let dur = int_of(e, &["duration"]);
        let vip = int_of(e, &["isVip", "vip", "is_vip"]) > 0;
        let remark = if vip {
            "VIP".to_string()
        } else if dur > 0 {
            format!("{dur} 秒")
        } else {
            String::new()
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn comic_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in rows {
        let id = text_of(e, &["id"]);
        let title = text_of(e, &["title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = fix_cover(&text_of(e, &["cover_url"]));
        let chapters = int_of(e, &["chapter_count"]);
        let remark = if chapters > 0 {
            format!("{chapters} 话")
        } else {
            String::new()
        };
        items.push(item_json(&format!("c{id}"), &title, &cover, &remark));
    }
    items
}

fn page_count(total: i64) -> i64 {
    if total <= 0 {
        1
    } else {
        (total + PAGE_SIZE - 1) / PAGE_SIZE
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("video", "🎬 探花短视频"),
        category_json("comic", "📖 里番漫画"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let host = site();
    let (path, is_comic) = if category_id == "comic" {
        ("comic", true)
    } else {
        ("video", false)
    };
    let url = with_query(
        &format!("{host}/index/{path}.php"),
        &[("type", "list"), ("page", &page.to_string())],
    );
    let data = get_json(&url).await?;
    let rows = get(&data, "list")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let total = int_of(&data, &["total"]);
    let items = if is_comic {
        comic_items(&rows)
    } else {
        video_items(&rows)
    };
    Ok(json!({"items": items, "has_more": page < page_count(total)}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let host = site();
    if let Some(cid) = series_id.strip_prefix('c') {
        let url = with_query(
            &format!("{host}/index/comic.php"),
            &[("type", "detail"), ("id", cid)],
        );
        let data = get_json(&url).await?;
        let comic = match get(&data, "comic") {
            Some(v) if v.is_object() => v.clone(),
            _ => return Err(ApiError::Internal("探花短视频未返回漫画资料".into())),
        };
        let title = text_of(&comic, &["title"]);
        let cover = fix_cover(&text_of(&comic, &["cover_url"]));
        let intro = text_of(&comic, &["intro"]);
        let mut episodes: Vec<Value> = Vec::new();
        if let Some(chapters) = get(&data, "chapters").and_then(arr_of) {
            for ch in chapters {
                let ch_id = text_of(ch, &["id"]);
                let ch_title = text_of(ch, &["title"]);
                if ch_id.is_empty() {
                    continue;
                }
                let name = if ch_title.is_empty() {
                    format!("第{}话", text_of(ch, &["seq"]))
                } else {
                    ch_title
                };
                episodes.push(episode_json(&format!("ch:{ch_id}"), &name, series_id));
            }
        }
        if episodes.is_empty() {
            episodes.push(episode_json(&format!("ch:{cid}"), "正片", series_id));
        }
        return Ok(json!({
            "id": series_id,
            "title": title,
            "cover": cover,
            "synopsis": intro,
            "extra": {},
            "episodes": episodes,
        }));
    }
    let url = with_query(
        &format!("{host}/index/video.php"),
        &[("type", "detail"), ("id", series_id)],
    );
    let data = get_json(&url).await?;
    let video = match get(&data, "video") {
        Some(v) if v.is_object() => v.clone(),
        _ => return Err(ApiError::Internal("探花短视频未返回影片资料".into())),
    };
    let title = text_of(&video, &["title"]);
    let cover = fix_cover(&text_of(&video, &["cover_url"]));
    let dur = int_of(&video, &["duration"]);
    let synopsis = if dur > 0 {
        format!("时长：{dur} 秒")
    } else {
        String::new()
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

/// 跟随跳转取最终地址（共享客户端默认跟随跳转，取最终 URL）。
async fn resolve_final(url: &str) -> ApiResult<String> {
    let host = site();
    let mut req = client()?.get(url).header("Range", "bytes=0-0");
    for (k, v) in base_headers(&host, true) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(resp.url().to_string())
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let host = site();
    if let Some(ch_id) = video_id.strip_prefix("ch:") {
        let url = with_query(
            &format!("{host}/index/comic.php"),
            &[("type", "chapter"), ("id", ch_id)],
        );
        let data = get_json(&url).await?;
        let pages = get(&data, "pages")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        let mut urls: Vec<String> = Vec::new();
        for p in &pages {
            let u = text_of(p, &["image_url"]);
            if !u.is_empty() {
                urls.push(u);
            }
        }
        if urls.is_empty() {
            return Err(ApiError::Internal("探花短视频该章节无图片".into()));
        }
        return Ok(json!({"url": format!("pics://{}", urls.join("&&"))}));
    }
    ensure_token().await?;
    let mut last_err = String::new();
    for _ in 0..3 {
        let mut req = client()?.post(format!("{host}/index/video.php")).header(
            "Content-Type",
            "application/x-www-form-urlencoded; charset=UTF-8",
        );
        for (k, v) in base_headers(&host, true) {
            req = req.header(k, v);
        }
        let resp = req
            .body(format!("type=play_token&id={video_id}&free=1"))
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        if resp.status().as_u16() != 200 {
            last_err = format!("探花短视频取流 HTTP {}", resp.status().as_u16());
            refresh_token().await?;
            continue;
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if int_of(&value, &["code"]) != 1 {
            if int_of(&value, &["code"]) == 2 {
                refresh_token().await?;
                continue;
            }
            return Err(ApiError::Internal("探花短视频未返回播放地址".into()));
        }
        let mut url = get(&value, "data")
            .map(|d| text_of(d, &["play_url"]))
            .unwrap_or_default();
        if url.is_empty() {
            return Err(ApiError::Internal("探花短视频未返回播放地址".into()));
        }
        if !url.starts_with("http") {
            url = format!("{host}{url}");
        }
        let final_url = resolve_final(&url).await?;
        return Ok(json!({
            "url": final_url,
            "header": {"User-Agent": UA, "Referer": format!("{host}/")},
        }));
    }
    Err(ApiError::Internal(if last_err.is_empty() {
        "探花短视频取流失败".into()
    } else {
        last_err
    }))
}

pub(crate) async fn search(_query: &str) -> ApiResult<Value> {
    Ok(json!({"items": []}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_id_shape() {
        let d = device_id();
        assert!(d.starts_with("zk"), "{d}");
        assert!(d.len() > 6, "{d}");
    }

    #[test]
    fn video_items_remark() {
        let rows = vec![
            json!({"id": "703", "title": "片A", "cover_url": "//x/c.webp", "duration": 57}),
            json!({"id": "704", "title": "片B", "cover_url": "https://x/d.webp", "duration": 0, "isVip": 1}),
            json!({"id": "", "title": "无id"}),
        ];
        let items = video_items(&rows);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["remark"], "57 秒");
        assert_eq!(items[0]["cover"], "https://x/c.webp");
        assert_eq!(items[1]["remark"], "VIP");
    }

    #[test]
    fn comic_items_prefix() {
        let rows = vec![json!({"id": 853, "title": "漫A", "cover_url": "c", "chapter_count": 3})];
        let items = comic_items(&rows);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "c853");
        assert_eq!(items[0]["remark"], "3 话");
    }

    #[test]
    fn page_count_math() {
        assert_eq!(page_count(668), 28);
        assert_eq!(page_count(24), 1);
        assert_eq!(page_count(0), 1);
    }
}
