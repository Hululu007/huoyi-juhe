//! 听友听书（tingyou.fm，接口 host appp.fdhtbz.cn）。
//!
//! 照搬 py 原文：固定 5 个榜单分类（最新/热门/推荐/连载/评书）；
//! 目录走 /api/h5/listening/rank（section + page + cache_meta=1）；
//! 详情取专辑 + 章节两接口，分集 id 为“专辑 id|集序号”；取流 POST
//! /api/h5/listening/play 拿 play_url 直链，parse=0 加 UA + Referer
//! 头。搜索没有独立接口：取最新榜单当页再按标题/作者/主播子串过滤
//! （py 原文即如此，核心 search 无页码参数，固定取第 1 页）。
//! init 的预热请求（取一次最新榜单）只起暖机作用，结果不用，核心
//! 不做。x-listening-session 是 py 按 Spider 实例生成的 uuid4，核心
//! 里按进程生成一次复用（md5 拼 uuid v4 格式，无 uuid 依赖）。

use std::sync::atomic::{AtomicU64, Ordering};

use md5::{Digest, Md5};
use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::endpoints::drama::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};
use crate::error::{ApiError, ApiResult};

const HOST: &str = "https://appp.fdhtbz.cn";
const SITE: &str = "https://tingyou.fm";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

const SECTIONS: [(&str, &str); 5] = [
    ("latest", "最新"),
    ("hot", "热门"),
    ("recommend", "推荐"),
    ("serial", "连载"),
    ("storytelling", "评书"),
];

static SESSION_COUNTER: AtomicU64 = AtomicU64::new(0);
static SESSION: Lazy<String> = Lazy::new(|| {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let seed = format!(
        "{}-{}-{}",
        nanos,
        std::process::id(),
        SESSION_COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let digest = Md5::digest(seed.as_bytes());
    let mut b: [u8; 16] = digest.into();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex::encode(b);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
});

fn bool_of(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::String(s) => s == "true" || s == "1",
        Value::Number(n) => n.as_i64().is_some_and(|i| i != 0),
        _ => false,
    }
}

async fn get_json(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let url = format!("{HOST}{path}");
    let resp = client()?
        .get(&with_query(&url, params))
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .header("x-listening-session", SESSION.as_str())
        .header("x-listening-timezone", "UTC")
        .header("Origin", SITE)
        .header("Referer", format!("{SITE}/"))
        .header("Content-Type", "application/json")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("听友听书请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("听友听书数据格式无法识别".into()));
    }
    Ok(body)
}

async fn post_json(path: &str, body: &Value) -> ApiResult<Value> {
    let url = format!("{HOST}{path}");
    let resp = client()?
        .post(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .header("x-listening-session", SESSION.as_str())
        .header("x-listening-timezone", "UTC")
        .header("Origin", SITE)
        .header("Referer", format!("{SITE}/"))
        .header("Content-Type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("听友听书请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("听友听书数据格式无法识别".into()));
    }
    Ok(body)
}

/// 榜单行转卡片：备注与 py 一致（“N集 · 主播”）。
fn rank_items(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for it in rows {
        let id = text_of(it, &["id"]);
        if id.is_empty() {
            continue;
        }
        let title = text_of(it, &["title"]);
        let cover = text_of(it, &["cover_url"]);
        let count = int_of(it, &["count"]);
        let teller = text_of(it, &["teller"]);
        let remark = format!("{count}集 · {teller}");
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

async fn rank(section: &str, page: i64) -> ApiResult<(Vec<Value>, bool)> {
    let page_str = page.to_string();
    let resp = get_json(
        "/api/h5/listening/rank",
        &[
            ("section", section),
            ("page", page_str.as_str()),
            ("cache_meta", "1"),
        ],
    )
    .await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let rows = get(&data, "items").and_then(arr_of);
    let items = match rows {
        Some(rows) => rank_items(rows),
        None => Vec::new(),
    };
    let has_more = get(&data, "has_more").is_some_and(bool_of);
    Ok((items, has_more))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": SECTIONS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let section = if category_id.is_empty() {
        "latest"
    } else {
        category_id
    };
    let page = if page < 1 { 1 } else { page };
    let (items, has_more) = rank(section, page).await?;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let album = get_json(
        &format!("/api/h5/listening/album/{series_id}"),
        &[("cache_meta", "1")],
    )
    .await?;
    let a = get(&album, "data").cloned().unwrap_or(Value::Null);
    let chapters = get_json(
        &format!("/api/h5/listening/chapters/{series_id}"),
        &[("cache_meta", "1")],
    )
    .await?;
    let rows = get(&chapters, "data")
        .and_then(|d| get(d, "chapters"))
        .and_then(arr_of);
    let album_id = text_of(&a, &["id"]);
    let album_id = if album_id.is_empty() {
        series_id
    } else {
        album_id.as_str()
    };
    let mut episodes = Vec::new();
    if let Some(rows) = rows {
        for ch in rows {
            let idx = int_of(ch, &["index"]);
            let raw_title = text_of(ch, &["title"]);
            let title = if raw_title.is_empty() {
                format!("第{idx}集")
            } else {
                raw_title
            };
            let title = title.replace('#', " ").replace('$', " ").trim().to_string();
            let video_id = format!("{album_id}|{idx}");
            episodes.push(episode_json(&video_id, &title, album_id));
        }
    }
    let title = text_of(&a, &["title"]);
    let cover = text_of(&a, &["cover_url"]);
    let synopsis = text_of(&a, &["synopsis", "intro"]);
    let count = int_of(&a, &["count"]);
    let extra = json!({
        "teller": text_of(&a, &["teller"]),
        "author": text_of(&a, &["author"]),
        "type": text_of(&a, &["type", "cat"]),
        "remarks": format!("{count}集"),
    });
    Ok(json!({
        "id": album_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    // py searchContent 没有独立搜索接口：取最新榜单当页，按标题/作者/
    // 主播子串过滤（大小写不敏感）。核心 search 无页码参数，固定取第 1 页。
    let page_str = "1";
    let resp = get_json(
        "/api/h5/listening/rank",
        &[
            ("section", "latest"),
            ("page", page_str),
            ("cache_meta", "1"),
        ],
    )
    .await?;
    let rows = get(&resp, "data")
        .and_then(|d| get(d, "items"))
        .and_then(arr_of);
    let needle = query.to_lowercase();
    let mut out = Vec::new();
    if let Some(rows) = rows {
        let raw: Vec<Value> = rows
            .iter()
            .filter(|it| {
                let title = text_of(it, &["title"]).to_lowercase();
                let author = text_of(it, &["author"]).to_lowercase();
                let teller = text_of(it, &["teller"]).to_lowercase();
                title.contains(&needle) || author.contains(&needle) || teller.contains(&needle)
            })
            .cloned()
            .collect();
        out = rank_items(&raw);
    }
    Ok(json!({"items": out}))
}

/// 取流 id 解析：与 py playerContent 一致（先 |，再 $，都没有则报错）。
fn parse_play_id(raw: &str) -> ApiResult<(String, i64)> {
    let raw = raw.trim();
    if let Some((album, idx)) = raw.split_once('|') {
        let idx = idx
            .trim()
            .parse::<i64>()
            .map_err(|_| ApiError::BadRequest("听友听书集序号无效".into()))?;
        return Ok((album.to_string(), idx));
    }
    if let Some((album, idx)) = raw.split_once('$') {
        let idx = if idx.is_empty() {
            1
        } else {
            idx.trim()
                .parse::<i64>()
                .map_err(|_| ApiError::BadRequest("听友听书集序号无效".into()))?
        };
        return Ok((album.to_string(), idx));
    }
    Err(ApiError::BadRequest("听友听书该集没有播放地址".into()))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (album_id, chapter_idx) = parse_play_id(video_id)?;
    let resp = post_json(
        "/api/h5/listening/play",
        &json!({"album_id": album_id, "chapter_idx": chapter_idx}),
    )
    .await?;
    let play_url = text_of(&resp, &["play_url"]);
    if play_url.is_empty() {
        return Err(ApiError::Internal("听友听书未返回播放地址".into()));
    }
    Ok(json!({
        "url": play_url,
        "header": {"User-Agent": UA, "Referer": format!("{SITE}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn play_id_pipe_wins() {
        assert_eq!(parse_play_id("123|7").unwrap(), ("123".to_string(), 7));
        assert_eq!(parse_play_id("123$9").unwrap(), ("123".to_string(), 9));
        assert_eq!(parse_play_id("123$").unwrap(), ("123".to_string(), 1));
        assert!(parse_play_id("123").is_err());
        assert!(parse_play_id("123|abc").is_err());
    }

    #[test]
    fn session_uuid_shape() {
        let s = SESSION.as_str();
        assert_eq!(s.len(), 36);
        assert_eq!(&s[8..9], "-");
        assert_eq!(&s[13..14], "-");
        assert_eq!(&s[18..19], "-");
        assert_eq!(&s[23..24], "-");
        assert_eq!(&s[14..15], "4");
    }
}
