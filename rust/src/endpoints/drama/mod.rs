//! 影视区：我方自有短剧站点的核心实现。
//!
//! 上游源码里没有影视区（它原来只有一个官方短剧站），所以这里是全新
//! 增加的模块，不改上游原有的任何端点、路由与数据。首批只进修复好能
//! 播的站：芽果、剧果、黄豆、野果、牛果；坏站（发果已死、花果手机
//! 问题未解、伍果要网页引擎）不进核心，仍留在 Dart 侧。
//!
//! 路由（全部走 query，不占路径段，与书旗一致）：
//! - `/api/v1/drama/categories?site_id=...`
//! - `/api/v1/drama/catalog?site_id=...&category_id=...&page=...`
//! - `/api/v1/drama/detail?site_id=...&id=...`
//! - `/api/v1/drama/search?site_id=...&query=...`
//! - `/api/v1/drama/play?site_id=...&video_id=...`
//!
//! 返回的 JSON 字段与 Dart 的 DramaSite* 模型一一对应（id/title/cover/
//! remark、episodes 的 video_id/title/series_id），Dart 侧只做直译，不
//! 再做字段归一。

mod hgdj;
mod hgdj58;
mod hgdjv;

use std::time::Duration;

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::egress_proxy::{apply_to_builder, ClientSlot};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

/// 影视区上游请求超时：与 Dart 侧 ApiClient 的默认超时一致。
const DRAMA_TIMEOUT_SECS: u64 = 20;

static DRAMA_CLIENT: ClientSlot = ClientSlot::new();

/// 影视区共用的明文 HTTP 客户端（第三方站，无番茄设备签名，与 video.rs
/// 的 streaming_client 同款做法：懒建，建不出来时调用方如实报错）。
/// 走出口代理配置：代理变了下次取时重建（ClientSlot 按代理版本号缓存）。
pub(crate) fn client() -> ApiResult<&'static reqwest::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    DRAMA_CLIENT
        .get_or_build(|| {
            apply_to_builder(
                reqwest::Client::builder().timeout(Duration::from_secs(DRAMA_TIMEOUT_SECS)),
            )
            .build()
            .ok()
        })
        .ok_or_else(|| ApiError::Internal("drama client unavailable".into()))
}

/// 把 query 参数拼到 URL 上：reqwest 未开 `query` 特性，`RequestBuilder::query`
/// 不可用（cfg 掉了），这里用 url 的 form 编码手动拼，与 requests 的
/// params= 同款编码（空格成 `+`，中文成 %XX）。
pub(crate) fn with_query(url: &str, params: &[(&str, &str)]) -> String {
    if params.is_empty() {
        return url.to_string();
    }
    let mut out = String::with_capacity(url.len() + 64);
    out.push_str(url);
    out.push(if url.contains('?') { '&' } else { '?' });
    for (i, (k, v)) in params.iter().enumerate() {
        if i > 0 {
            out.push('&');
        }
        out.push_str(&url::form_urlencoded::byte_serialize(k.as_bytes()).collect::<String>());
        out.push('=');
        out.push_str(&url::form_urlencoded::byte_serialize(v.as_bytes()).collect::<String>());
    }
    out
}

pub fn register(s: &mut Server) {
    s.add_route("drama_categories", handle_categories);
    s.add_route("drama_catalog", handle_catalog);
    s.add_route("drama_detail", handle_detail);
    s.add_route("drama_search", handle_search);
    s.add_route("drama_play", handle_play);
}

/// JSON 对象取值：非对象一律视作缺失（与 Dart 的 _asMap 一致）。
pub(crate) fn obj_of(v: &Value) -> Option<&Map<String, Value>> {
    v.as_object()
}

/// JSON 对象里按 key 取值：非对象或无此 key 返回 None。
pub(crate) fn get<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object().and_then(|m| m.get(key))
}

/// JSON 数组取值：非数组返回 None。
pub(crate) fn arr_of(v: &Value) -> Option<&Vec<Value>> {
    v.as_array()
}

/// 标量转字符串：字符串去空白，数字/布尔按原样，null 与复合值为空
/// （与 Dart 的 _stringOf 对标量字段的行为一致）。
pub(crate) fn str_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// 按 key 顺序取第一个非空字符串（与 Dart 的 _firstString 一致）。
pub(crate) fn text_of(v: &Value, keys: &[&str]) -> String {
    let Some(m) = v.as_object() else {
        return String::new();
    };
    for key in keys {
        if let Some(value) = m.get(*key) {
            let s = str_of(value);
            if !s.is_empty() {
                return s;
            }
        }
    }
    String::new()
}

/// 按 key 顺序取第一个整数：JSON 数字直接取整，字符串解析，皆无则 0
/// （与 Dart 的 _firstInt 一致）。
pub(crate) fn int_of(v: &Value, keys: &[&str]) -> i64 {
    let Some(m) = v.as_object() else {
        return 0;
    };
    for key in keys {
        if let Some(value) = m.get(*key) {
            match value {
                Value::Number(n) => {
                    if let Some(i) = n.as_i64() {
                        return i;
                    }
                    if let Some(u) = n.as_u64() {
                        return u as i64;
                    }
                    if let Some(f) = n.as_f64() {
                        return f as i64;
                    }
                }
                Value::String(s) => {
                    if let Ok(i) = s.trim().parse::<i64>() {
                        return i;
                    }
                }
                _ => {}
            }
        }
    }
    0
}

/// 分类卡片：与 Dart 的 DramaSiteCategory(id, name) 对应。
pub(crate) fn category_json(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

/// 视频卡片：与 Dart 的 DramaSiteItem(id, title, cover, remark) 对应。
pub(crate) fn item_json(id: &str, title: &str, cover: &str, remark: &str) -> Value {
    json!({"id": id, "title": title, "cover": cover, "remark": remark})
}

/// 分集：与 Dart 的 DramaSiteEpisode(video_id, title, series_id) 对应。
pub(crate) fn episode_json(video_id: &str, title: &str, series_id: &str) -> Value {
    json!({"video_id": video_id, "title": title, "series_id": series_id})
}

fn site_id(params: &Params) -> ApiResult<String> {
    let id = params.get_str("site_id");
    if id.is_empty() {
        return Err(ApiError::BadRequest("missing site_id parameter".into()));
    }
    Ok(id)
}

fn page_of(params: &Params) -> i64 {
    let page = params.get_str("page").parse::<i64>().unwrap_or(1);
    if page < 1 {
        1
    } else {
        page
    }
}

fn handle_categories<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    Box::pin(async move {
        match site?.as_str() {
            "hgdj" => hgdj::categories().await,
            "hgdj58" => hgdj58::categories().await,
            "hgdjv" => hgdjv::categories().await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}

fn handle_catalog<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let category_id = params.get_str("category_id");
    let page = page_of(params);
    Box::pin(async move {
        match site?.as_str() {
            "hgdj" => hgdj::catalog(&category_id, page).await,
            "hgdj58" => hgdj58::catalog(&category_id, page).await,
            "hgdjv" => hgdjv::catalog(&category_id, page).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}

fn handle_detail<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let id = params.get_str("id");
    Box::pin(async move {
        if id.is_empty() {
            return Err(ApiError::BadRequest("missing id parameter".into()));
        }
        match site?.as_str() {
            "hgdj" => hgdj::detail(&id).await,
            "hgdj58" => hgdj58::detail(&id).await,
            "hgdjv" => hgdjv::detail(&id).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}

fn handle_search<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let query = params.get_str("query");
    Box::pin(async move {
        if query.is_empty() {
            return Err(ApiError::BadRequest("missing query parameter".into()));
        }
        match site?.as_str() {
            "hgdj" => hgdj::search(&query).await,
            "hgdj58" => hgdj58::search(&query).await,
            "hgdjv" => hgdjv::search(&query).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}

fn handle_play<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let video_id = params.get_str("video_id");
    Box::pin(async move {
        if video_id.is_empty() {
            return Err(ApiError::BadRequest("missing video_id parameter".into()));
        }
        match site?.as_str() {
            "hgdj" => hgdj::play(&video_id).await,
            "hgdj58" => hgdj58::play(&video_id).await,
            "hgdjv" => hgdjv::play(&video_id).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}
