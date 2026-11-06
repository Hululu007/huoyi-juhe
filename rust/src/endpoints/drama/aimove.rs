//! 🔞新黄果短剧：aimove.click 的 API 站，单独建站，不与黄果短剧 hgdj 合并。
//!
//! 站点结构（实测于 2026-11-06，均为同源 JSON 接口，匿名可调）：
//! - 分类 GET `/api/dramas/categories`，13 条（API 原序，另有“全部”标签）；
//! - 列表 GET `/api/dramas`，一次回全部 282 条，含 currentEpisode（第 1 集地址）；
//! - 详情 GET `/api/dramas/{id}`，含 episodes[]：每集 id/episodeNo/videoUrl
//!   （未解锁为空串）/unlockPoints/isUnlocked；
//! - 第 1 集免费：videoUrl 为 `/api/media/<hex>/index.m3u8`，主清单 4 档，
//!   720P 分清单 35 分片、总 211.9 秒，AES-128，首分片 200；
//! - 第 2 集起每集 8 金币：匿名调详情拿不到地址；访客自动注册
//!   POST `/api/member/auto/register` 得 10 金币，签到
//!   POST `/api/member/daily-check-in` 再得 8 金币；解锁
//!   POST `/api/member/dramas/{id}/unlock`（持 token，无集数参数，
//!   每次只解下一集未解锁的集）扣 8 金币并回该集地址；余额不足回
//!   400 insufficient points，服务端验余额；新访客一路可播到第 3 集。
//! - 出口间歇断连，请求带 3 次重试。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, str_of, text_of};

const BASE: &str = "https://aimove.click";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 24;

/// 访客 token 缓存：自动注册一次后复用，401 时清空重注册。
static GUEST_TOKEN: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn guest_slot() -> &'static Mutex<Option<String>> {
    GUEST_TOKEN.get_or_init(|| Mutex::new(None))
}

fn abs_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    format!("{BASE}/{u}")
}

/// 带重试的 GET JSON：出口间歇断连，最多试 3 次。
async fn get_json(url: &str, token: Option<&str>) -> ApiResult<Value> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_json(url, None, token).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn post_json(url: &str, token: Option<&str>) -> ApiResult<Value> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_json(url, Some("{}"), token).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_json(url: &str, body: Option<&str>, token: Option<&str>) -> ApiResult<Value> {
    let mut req = if let Some(b) = body {
        client()?
            .post(url)
            .header("Content-Type", "application/json")
            .body(b.to_string())
    } else {
        client()?.get(url)
    };
    req = req
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", format!("{BASE}/"));
    if let Some(t) = token {
        req = req.header("Authorization", format!("Bearer {t}"));
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let value: Value = serde_json::from_str(&text)
        .map_err(|_| ApiError::Internal("新黄果短剧返回非 JSON".into()))?;
    if status != 200 {
        let msg = text_of(&value, &["message"]);
        return Err(ApiError::Internal(format!(
            "新黄果短剧请求 HTTP {status}{}",
            if msg.is_empty() {
                String::new()
            } else {
                format!("：{msg}")
            }
        )));
    }
    if let Some(code) = get(&value, "code").and_then(|v| v.as_i64()) {
        if code != 0 {
            let msg = text_of(&value, &["message"]);
            return Err(ApiError::Internal(format!(
                "新黄果短剧接口错误 code {code}{}",
                if msg.is_empty() {
                    String::new()
                } else {
                    format!("：{msg}")
                }
            )));
        }
    }
    Ok(value)
}

/// 访客自动注册：每位访客进站即注册，得 10 金币；失败时如实报错。
async fn guest_token() -> ApiResult<String> {
    {
        let slot = guest_slot()
            .lock()
            .map_err(|_| ApiError::Internal("新黄果短剧访客 token 锁异常".into()))?;
        if let Some(t) = slot.as_ref() {
            if !t.is_empty() {
                return Ok(t.clone());
            }
        }
    }
    let value = post_json(&format!("{BASE}/api/member/auto/register"), None).await?;
    let token = value
        .pointer("/data/accessToken")
        .map(str_of)
        .unwrap_or_default();
    if token.is_empty() {
        return Err(ApiError::Internal("新黄果短剧自动注册未返回 token".into()));
    }
    if let Ok(mut slot) = guest_slot().lock() {
        *slot = Some(token.clone());
    }
    Ok(token)
}

fn clear_guest_token() {
    if let Ok(mut slot) = guest_slot().lock() {
        *slot = None;
    }
}

/// 每日签到：新访客 day1 得 8 金币，已签过只回当前余额，不重复给。
async fn check_in(token: &str) {
    let _ = post_json(&format!("{BASE}/api/member/daily-check-in"), Some(token)).await;
}

/// 解下一集未解锁的集：扣 8 金币，余额不足时服务端回 insufficient points。
async fn unlock_next(drama_id: &str, token: &str) -> ApiResult<Value> {
    post_json(
        &format!("{BASE}/api/member/dramas/{drama_id}/unlock"),
        Some(token),
    )
    .await
}

fn drama_card(v: &Value) -> Option<Value> {
    let id = int_of(v, &["id"]);
    if id == 0 {
        return None;
    }
    let title = text_of(v, &["title"]);
    if title.is_empty() {
        return None;
    }
    let cover = abs_url(&text_of(v, &["coverUrl"]));
    let total = int_of(v, &["totalEpisodes"]);
    let views = int_of(v, &["viewCount"]);
    let remark = if total > 0 && views > 0 {
        format!("{total}集 · {views}播放")
    } else if total > 0 {
        format!("{total}集")
    } else {
        String::new()
    };
    Some(item_json(&id.to_string(), &title, &cover, &remark))
}

async fn list_all() -> ApiResult<Vec<Value>> {
    let value = get_json(&format!("{BASE}/api/dramas"), None).await?;
    let Some(items) = get(&value, "data").and_then(arr_of) else {
        return Err(ApiError::Internal("新黄果短剧列表未返回 data 数组".into()));
    };
    Ok(items.clone())
}

fn paginate(items: Vec<Value>, page: i64) -> Value {
    let page = if page < 1 { 1 } else { page };
    let start = ((page - 1) * PAGE_SIZE) as usize;
    let total = items.len();
    let slice: Vec<Value> = if start >= total {
        Vec::new()
    } else {
        items[start..total.min(start + PAGE_SIZE as usize)].to_vec()
    };
    let has_more = start + slice.len() < total;
    json!({"items": slice, "has_more": has_more})
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let value = get_json(&format!("{BASE}/api/dramas/categories"), None).await?;
    let mut list: Vec<Value> = vec![category_json("all", "全部")];
    if let Some(items) = get(&value, "data").and_then(arr_of) {
        for v in items {
            let id = int_of(v, &["id"]);
            let name = text_of(v, &["name"]);
            if id != 0 && !name.is_empty() {
                list.push(category_json(&id.to_string(), &name));
            }
        }
    }
    if list.len() <= 1 {
        return Err(ApiError::Internal("新黄果短剧未返回分类".into()));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if category_id.is_empty() || category_id == "all" {
        format!("{BASE}/api/dramas")
    } else {
        match category_id.parse::<i64>() {
            Ok(_) => format!("{BASE}/api/dramas?categoryId={category_id}"),
            Err(_) => format!("{BASE}/api/dramas"),
        }
    };
    let value = get_json(&url, None).await?;
    let Some(items) = get(&value, "data").and_then(arr_of) else {
        return Err(ApiError::Internal("新黄果短剧列表未返回 data 数组".into()));
    };
    let items: Vec<Value> = items.iter().filter_map(|v| drama_card(v)).collect();
    Ok(paginate(items, page))
}

fn episode_title(ep: &Value) -> String {
    let no = int_of(ep, &["episodeNo"]);
    let base = if no > 0 {
        format!("第{no}集")
    } else {
        text_of(ep, &["title"])
    };
    let locked = !get(ep, "isUnlocked")
        .map(|v| v.as_bool().unwrap_or(false))
        .unwrap_or(false);
    if locked {
        let cost = int_of(ep, &["unlockPoints"]);
        if cost > 0 {
            return format!("{base}（{cost}金币）");
        }
        return format!("{base}（未解锁）");
    }
    base
}

async fn fetch_detail(drama_id: &str, token: Option<&str>) -> ApiResult<Value> {
    let value = get_json(&format!("{BASE}/api/dramas/{drama_id}"), token).await?;
    let Some(data) = get(&value, "data") else {
        return Err(ApiError::Internal("新黄果短剧详情未返回 data".into()));
    };
    Ok(data.clone())
}

fn find_episode<'a>(detail: &'a Value, episode_id: &str) -> Option<&'a Value> {
    let eps = get(detail, "episodes").and_then(arr_of)?;
    eps.iter()
        .find(|e| int_of(e, &["id"]).to_string() == episode_id)
}

fn episode_url(ep: &Value) -> String {
    abs_url(&text_of(ep, &["videoUrl"]))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let data = fetch_detail(series_id, None).await?;
    let title = text_of(&data, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("新黄果短剧详情无标题".into()));
    }
    let cover = abs_url(&text_of(&data, &["coverUrl"]));
    let synopsis = text_of(&data, &["intro"]);
    let total = int_of(&data, &["totalEpisodes"]);
    let views = int_of(&data, &["viewCount"]);
    let remark = if total > 0 && views > 0 {
        format!("{total}集 · {views}播放")
    } else if total > 0 {
        format!("{total}集")
    } else {
        String::new()
    };
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(eps) = get(&data, "episodes").and_then(arr_of) {
        for ep in eps {
            let eid = int_of(ep, &["id"]);
            if eid == 0 {
                continue;
            }
            episodes.push(episode_json(
                &format!("{series_id}:{eid}"),
                &episode_title(ep),
                series_id,
            ));
        }
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"remark": remark, "actor": ""},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let needle = query.trim().to_lowercase();
    let all = list_all().await?;
    let items: Vec<Value> = all
        .into_iter()
        .filter(|v| text_of(v, &["title"]).to_lowercase().contains(&needle))
        .filter_map(|v| drama_card(&v))
        .collect();
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let Some((drama_id, episode_id)) = video_id.split_once(':') else {
        return Err(ApiError::BadRequest(format!(
            "新黄果短剧未知 video_id {video_id}"
        )));
    };
    let detail = fetch_detail(drama_id, None).await?;
    let Some(ep) = find_episode(&detail, episode_id) else {
        return Err(ApiError::Internal("新黄果短剧未找到该集".into()));
    };
    let url = episode_url(ep);
    if !url.is_empty() {
        return Ok(json!({"url": url}));
    }
    let episode_no = int_of(ep, &["episodeNo"]);
    let token = guest_token().await?;
    check_in(&token).await;
    let mut last_err = String::new();
    let bound = if episode_no > 0 { episode_no } else { 1 };
    for _ in 0..bound {
        match unlock_next(drama_id, &token).await {
            Ok(_) => {}
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("401") || msg.contains("token") {
                    clear_guest_token();
                    return Err(e);
                }
                last_err = msg;
                break;
            }
        }
        let detail = fetch_detail(drama_id, Some(&token)).await?;
        let Some(ep) = find_episode(&detail, episode_id) else {
            return Err(ApiError::Internal("新黄果短剧解锁后未找到该集".into()));
        };
        let url = episode_url(ep);
        if !url.is_empty() {
            return Ok(json!({"url": url}));
        }
    }
    if last_err.is_empty() {
        last_err = "新黄果短剧该集仍未解锁".to_string();
    }
    Err(ApiError::Internal(last_err))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATS_JSON: &str = r#"{"code":0,"data":[{"id":68,"code":"category-1789825923616544998","name":"二次元区","sort":0,"count":3},{"id":10,"code":"","name":"家庭伦理","sort":0,"count":44},{"id":2,"code":"","name":"都市爱情","sort":0,"count":65}]}"#;

    const DETAIL_JSON: &str = r#"{"code":0,"data":{"id":318,"title":"韵母攻略","categoryId":10,"categoryName":"家庭伦理","coverUrl":"/vod/short-drama/covers/2026-10-21/cover-1792576517645966006.jpg","intro":"","totalEpisodes":4,"unlockedCount":1,"viewCount":11052,"episodes":[{"id":2643,"episodeNo":1,"videoUrl":"/api/media/488778aeb33b42ccbb55f6603df9e60d/index.m3u8","unlockPoints":0,"isUnlocked":true},{"id":2644,"episodeNo":2,"videoUrl":"","unlockPoints":8,"isUnlocked":false}]}}"#;

    #[test]
    fn abs_url_cases() {
        assert_eq!(abs_url("/vod/x.jpg"), "https://aimove.click/vod/x.jpg");
        assert_eq!(
            abs_url("https://vod.mfantasy.net/m/a/b"),
            "https://vod.mfantasy.net/m/a/b"
        );
        assert_eq!(abs_url("//x.y/z"), "https://x.y/z");
        assert_eq!(abs_url(""), "");
    }

    #[test]
    fn categories_parse_real_payload() {
        let v: Value = serde_json::from_str(CATS_JSON).unwrap();
        let items = get(&v, "data").and_then(arr_of).unwrap();
        assert_eq!(items.len(), 3);
        assert_eq!(int_of(&items[0], &["id"]), 68);
        assert_eq!(text_of(&items[1], &["name"]), "家庭伦理");
    }

    #[test]
    fn detail_episodes_split_locked_free() {
        let v: Value = serde_json::from_str(DETAIL_JSON).unwrap();
        let data = get(&v, "data").unwrap();
        assert_eq!(text_of(data, &["title"]), "韵母攻略");
        let eps = get(data, "episodes").and_then(arr_of).unwrap();
        assert_eq!(eps.len(), 2);
        let ep1 = find_episode(data, "2643").unwrap();
        assert!(!episode_url(ep1).is_empty());
        assert_eq!(episode_title(ep1), "第1集");
        let ep2 = find_episode(data, "2644").unwrap();
        assert!(episode_url(ep2).is_empty());
        assert_eq!(episode_title(ep2), "第2集（8金币）");
        assert!(find_episode(data, "9999").is_none());
    }

    #[test]
    fn drama_card_remark() {
        let v: Value = serde_json::from_str(
            r#"{"id":318,"title":"韵母攻略","coverUrl":"/vod/c.jpg","totalEpisodes":4,"viewCount":11052}"#,
        )
        .unwrap();
        let card = drama_card(&v).unwrap();
        assert_eq!(card["id"], "318");
        assert_eq!(card["title"], "韵母攻略");
        assert_eq!(card["cover"], "https://aimove.click/vod/c.jpg");
        assert_eq!(card["remark"], "4集 · 11052播放");
        assert!(drama_card(&json!({"id": 0, "title": "x"})).is_none());
    }

    #[test]
    fn paginate_slices_24() {
        let items: Vec<Value> = (0..50)
            .map(|i| item_json(&i.to_string(), "t", "", ""))
            .collect();
        let p1 = paginate(items.clone(), 1);
        assert_eq!(p1["items"].as_array().unwrap().len(), 24);
        assert_eq!(p1["has_more"], true);
        let p3 = paginate(items.clone(), 3);
        assert_eq!(p3["items"].as_array().unwrap().len(), 2);
        assert_eq!(p3["has_more"], false);
        let p9 = paginate(items, 9);
        assert_eq!(p9["items"].as_array().unwrap().len(), 0);
        assert_eq!(p9["has_more"], false);
    }
}
