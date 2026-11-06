//! 芽果：核心里的第一个影视区站点。
//!
//! 与 Dart 的 YaguoContentClient 一一对应：登录拿令牌（顶层与 data 嵌
//! 套双兼容）、分类（失败回退剧场/榜单）、目录（榜单分类走排行接口）、
//! 详情（分集按 num 排序）、搜索、取流（直链透传）。令牌在核心里缓存
//! 6 小时，与 Dart 侧一致。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const BASE_URL: &str = "https://app.whjzjx.cn";
const LOGIN_URL: &str = "https://u.shytkjgs.com/user/v1/account/login";
const DEVICE: &str = "24250683a3bdb3f118dff25ba4b1cba1a";
const VERSION_NAME: &str = "3.8.3.1";
const TOKEN_TTL: Duration = Duration::from_secs(6 * 3600);

static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 从登录响应里取令牌：先顶层，再 data 嵌套一层；都没有则按 Dart 原
/// 文案报错（带服务端 code 与 msg/message/error）。
fn extract_token(body: &Value) -> ApiResult<String> {
    let mut token = text_of(body, &["token", "access_token", "accessToken"]);
    if token.is_empty() {
        if let Some(data) = get(body, "data") {
            token = text_of(data, &["token", "access_token", "accessToken"]);
        }
    }
    if !token.is_empty() {
        return Ok(token);
    }
    let detail = text_of(body, &["msg", "message", "error"]);
    let code = text_of(body, &["code", "errorCode"]);
    let mut message = "芽果未返回有效的访问令牌".to_string();
    if !code.is_empty() {
        message.push_str(&format!("（{code}）"));
    }
    if !detail.is_empty() {
        message.push_str(&format!("：{detail}"));
    }
    Err(ApiError::Internal(message))
}

/// 令牌：缓存 6 小时内直接复用，过期或无缓存才重新登录。
async fn token() -> ApiResult<String> {
    if let Ok(guard) = TOKEN.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok(cached.clone());
            }
        }
    }
    let resp = client()?
        .post(LOGIN_URL)
        .header("platform", "1")
        .header("Content-Type", "application/json")
        .json(&json!({"device": DEVICE}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("芽果登录 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("芽果登录数据格式无法识别".into()));
    }
    let fresh = extract_token(&body)?;
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = Some((fresh.clone(), Instant::now() + TOKEN_TTL));
    }
    Ok(fresh)
}

/// 带令牌的 GET：与 Dart 的 _request 一致（Referer、authorization、
/// platform、version_name 四个头，状态与对象校验文案一致）。
async fn request(path: &str, query: &[(&str, &str)]) -> ApiResult<Value> {
    let token = token().await?;
    let url = format!("{BASE_URL}{path}");
    let resp = client()?
        .get(&with_query(&url, query))
        .header("Referer", format!("{BASE_URL}/"))
        .header("authorization", token)
        .header("platform", "1")
        .header("version_name", VERSION_NAME)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("芽果请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("芽果数据格式无法识别".into()));
    }
    Ok(body)
}

/// 搜索 POST：与 Dart 的 search 一致（/v3/search，body 是 {"text": query}）。
async fn search_request(query: &str) -> ApiResult<Value> {
    let token = token().await?;
    let url = format!("{BASE_URL}/v3/search");
    let resp = client()?
        .post(&url)
        .header("Referer", format!("{BASE_URL}/"))
        .header("authorization", token)
        .header("platform", "1")
        .header("version_name", VERSION_NAME)
        .header("Content-Type", "application/json")
        .json(&json!({"text": query}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("芽果搜索 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("芽果搜索数据格式无法识别".into()));
    }
    Ok(body)
}

/// 目录行转视频卡片：与 Dart 的 parseCatalog 一致（theater 嵌套优先、
/// id/title/cover 多 key 回退、集数备注）。
fn catalog_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for entry in rows {
        let node_value = entry;
        let theater = get(node_value, "theater");
        let target = match theater {
            Some(t) if t.as_object().is_some_and(|m| !m.is_empty()) => t,
            _ => node_value,
        };
        let id = text_of(target, &["id", "theater_id", "theater_parent_id"]);
        if id.is_empty() {
            continue;
        }
        let title = text_of(target, &["title", "name"]);
        if title.is_empty() {
            continue;
        }
        let count = int_of(target, &["total", "total_num", "current_num"]);
        let remark = if count > 0 {
            format!("共{count}集")
        } else {
            String::new()
        };
        let cover = text_of(target, &["cover_url", "son_cover_url", "cover"]);
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 整包目录解析：读 data.list（与 Dart 的 parseCatalog 一致）。
fn parse_catalog(resp: &Value) -> Vec<Value> {
    let rows = get(resp, "data")
        .and_then(|d| get(d, "list"))
        .and_then(arr_of);
    match rows {
        Some(rows) => catalog_items(rows),
        None => Vec::new(),
    }
}

/// 详情解析：与 Dart 的 parseDetail 一致（分集按 num 排序、无号用序号、
/// 无地址跳过、无资料与无分集皆报错）。
fn parse_detail(resp: &Value, series_id: &str) -> ApiResult<Value> {
    let data = match get(resp, "data") {
        Some(d) if d.as_object().is_some_and(|m| !m.is_empty()) => d,
        _ => return Err(ApiError::Internal("芽果未返回剧集资料".into())),
    };
    let title = text_of(data, &["title", "share_title"]);
    let cover = text_of(data, &["cover_url", "share_cover"]);
    let raw_list = match get(data, "theaters").and_then(arr_of) {
        Some(list) => list,
        None => return Err(ApiError::Internal("芽果未返回可播放分集".into())),
    };
    let mut indexed: Vec<(i64, Value)> = Vec::new();
    for (i, entry) in raw_list.iter().enumerate() {
        let url = text_of(entry, &["son_video_url", "video_url"]);
        if url.is_empty() {
            continue;
        }
        let mut number = int_of(entry, &["num", "sort"]);
        if number <= 0 {
            number = i as i64 + 1;
        }
        let node_title = text_of(entry, &["son_title", "title"]);
        let episode_title = if node_title.is_empty() {
            format!("第{number}集")
        } else {
            node_title
        };
        indexed.push((number, episode_json(&url, &episode_title, series_id)));
    }
    if indexed.is_empty() {
        return Err(ApiError::Internal("芽果未返回可播放分集".into()));
    }
    indexed.sort_by_key(|(number, _)| *number);
    let episodes: Vec<Value> = indexed.into_iter().map(|(_, e)| e).collect();
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

/// 分类解析：与 Dart 的 categories 一致（alg_class 下钻、id 去重、名
/// 超 24 字跳过、空 id/名跳过）。
fn categories_from(resp: &Value) -> Vec<Value> {
    let groups = match get(resp, "data").and_then(arr_of) {
        Some(groups) => groups,
        None => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for group in groups {
        let classes = match get(group, "alg_class").and_then(arr_of) {
            Some(classes) => classes,
            None => continue,
        };
        for entry in classes {
            let id = text_of(entry, &["id"]);
            let name = text_of(entry, &["class_name", "name"]);
            if id.is_empty() || name.is_empty() || name.chars().count() > 24 {
                continue;
            }
            if !seen.insert(id.clone()) {
                continue;
            }
            categories.push(category_json(&id, &name));
        }
    }
    categories
}

/// 是否还有下一页：与 Dart 的 catalog 一致（未结束且有条目且总数大于
/// 已翻页数乘以当页条数）。
fn calc_has_more(data: &Value, items_len: usize, page: i64) -> bool {
    let is_end = match get(data, "is_end") {
        Some(Value::Bool(true)) => true,
        Some(Value::String(s)) if s == "true" => true,
        _ => false,
    };
    let total = int_of(data, &["total"]);
    !is_end && items_len > 0 && total > page * items_len as i64
}

fn fallback_categories() -> Value {
    json!({"categories": [category_json("1", "剧场"), category_json("9", "榜单")]})
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match request("/cloud/v2/theater/classes", &[]).await {
        Ok(resp) => {
            let list = categories_from(&resp);
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
    if category_id == "9" {
        let resp = request("/cloud/v1/first_level_ranking/detail", &[("id", "1")]).await?;
        let rows = get(&resp, "data")
            .and_then(|d| get(d, "list"))
            .and_then(arr_of);
        return match rows {
            Some(rows) => Ok(json!({
                "items": catalog_items(rows),
                "has_more": false,
            })),
            None => Ok(json!({"items": [], "has_more": false})),
        };
    }
    let class_id = if category_id.parse::<i64>().is_ok() {
        category_id
    } else {
        ""
    };
    let page_num = page.to_string();
    let resp = request(
        "/cloud/v2/theater/home_page",
        &[
            ("theater_class_id", class_id),
            ("type", "1"),
            ("class2_ids", "0"),
            ("page_num", page_num.as_str()),
            ("page_size", "24"),
        ],
    )
    .await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let items = parse_catalog(&resp);
    let has_more = calc_has_more(&data, items.len(), page);
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let resp = request(
        "/v2/theater_parent/detail",
        &[("theater_parent_id", series_id)],
    )
    .await?;
    parse_detail(&resp, series_id)
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("芽果该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let resp = search_request(query).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let rows = get(&data, "list").and_then(arr_of).or_else(|| {
        get(&data, "theater")
            .and_then(|t| get(t, "search_data"))
            .and_then(arr_of)
    });
    match rows {
        Some(rows) => Ok(json!({"items": catalog_items(rows)})),
        None => Ok(json!({"items": []})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_top_level_wins() {
        let body = json!({"token": "abc", "code": 0});
        assert_eq!(extract_token(&body).unwrap(), "abc");
    }

    #[test]
    fn token_nested_data() {
        let body = json!({"data": {"access_token": "xyz"}});
        assert_eq!(extract_token(&body).unwrap(), "xyz");
    }

    #[test]
    fn token_missing_reports_code_and_detail() {
        let body = json!({"code": 401, "msg": "未登录"});
        let err = extract_token(&body).unwrap_err();
        let message = err.to_string();
        assert!(message.contains("芽果未返回有效的访问令牌"), "{message}");
        assert!(message.contains("401"), "{message}");
        assert!(message.contains("未登录"), "{message}");
    }

    #[test]
    fn catalog_theater_nesting_and_fallbacks() {
        let resp = json!({"data": {"list": [
            {"theater": {"id": "7", "title": "剧A", "cover_url": "c1", "total": 12}},
            {"id": "8", "name": "剧B", "son_cover_url": "c2", "current_num": 3},
            {"id": "", "title": "无id跳过"},
            {"id": "9", "title": ""},
        ]}});
        let items = parse_catalog(&resp);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "7");
        assert_eq!(items[0]["remark"], "共12集");
        assert_eq!(items[1]["title"], "剧B");
        assert_eq!(items[1]["cover"], "c2");
        assert_eq!(items[1]["remark"], "共3集");
    }

    #[test]
    fn detail_sorts_and_fills_titles() {
        let resp = json!({"data": {
            "title": "剧名", "cover_url": "cov",
            "theaters": [
                {"num": 2, "son_video_url": "https://x/2.m3u8", "son_title": "第二集"},
                {"num": 1, "video_url": "https://x/1.m3u8"},
                {"num": 3, "son_video_url": ""},
            ],
        }});
        let detail = parse_detail(&resp, "s1").unwrap();
        let episodes = detail["episodes"].as_array().unwrap();
        assert_eq!(episodes.len(), 2);
        assert_eq!(episodes[0]["video_id"], "https://x/1.m3u8");
        assert_eq!(episodes[0]["title"], "第1集");
        assert_eq!(episodes[1]["title"], "第二集");
        assert_eq!(episodes[1]["series_id"], "s1");
    }

    #[test]
    fn detail_errors() {
        assert!(parse_detail(&json!({}), "s1").is_err());
        assert!(parse_detail(&json!({"data": {"theaters": []}}), "s1").is_err());
        assert!(parse_detail(&json!({"data": {"theaters": [{"title": "无地址"}]}}), "s1").is_err());
    }

    #[test]
    fn categories_dedup_and_length() {
        let resp = json!({"data": [
            {"alg_class": [
                {"id": "1", "class_name": "剧场"},
                {"id": "1", "class_name": "重复"},
                {"id": "2", "name": "这是一个超过二十四个字的分类名称肯定要被跳过真的很长"},
                {"id": "", "class_name": "无id"},
            ]},
        ]});
        let list = categories_from(&resp);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["id"], "1");
    }

    #[test]
    fn has_more_rules() {
        let data = json!({"total": 100});
        assert!(calc_has_more(&data, 24, 1));
        assert!(!calc_has_more(&data, 24, 5));
        assert!(!calc_has_more(
            &json!({"total": 100, "is_end": true}),
            24,
            1
        ));
        assert!(!calc_has_more(
            &json!({"total": 100, "is_end": "true"}),
            24,
            1
        ));
        assert!(!calc_has_more(&data, 0, 1));
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://x/1.m3u8").unwrap();
        assert_eq!(ok["url"], "https://x/1.m3u8");
        assert!(play_check("relative/path").is_err());
    }
}
