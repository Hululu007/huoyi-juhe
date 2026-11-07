//! 大哥视频：Vue3 SPA + 站方自建 JSON API。
//!
//! 与 Dart 的 ZakaDageAmns 一一对应：列表 `/api/lists/<id>/<页>/24.json`、
//! 详情与取流共用 `/api/play/<id>.json`（player[].play 即直链 m3u8）、
//! 搜索 `/api/vodsearch?key=&page=&limit=24`。响应信封须先解包：
//! status==1 时 data 经 `/`→`0`、`@`→`/`、`.`→`+` 三处替换后整体
//! 反转，再标准 base64 解出真正 JSON（与 Java 的 unlock 一致）。
//! 分集名是“线路+序号”（player[].name 只作非空校验，不进分集名）。

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const HOSTS: &[&str] = &["https://dage.one", "https://www.dagexxx.com"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：与站内导航 1:1（id, 名）。一区 56-63、二区 101-108、
/// 三区 83-90、四区 92-99；重名分类（中文字幕、SM调教）各出现两次，
/// id 不同，照原样保留。
const CATEGORIES: &[(&str, &str)] = &[
    ("56", "亚洲有码"),
    ("57", "亚洲无码"),
    ("58", "亚洲主播"),
    ("59", "韩国高清"),
    ("60", "大陆高清"),
    ("61", "欧美高清"),
    ("62", "H动漫"),
    ("63", "三级伦理"),
    ("101", "日韩无码"),
    ("102", "中文字幕"),
    ("103", "国产自制"),
    ("104", "约炮偷拍"),
    ("105", "传媒剧情"),
    ("106", "强制乱伦"),
    ("107", "SM调教"),
    ("108", "剧情动漫"),
    ("83", "国产制片"),
    ("84", "日本无码"),
    ("85", "中文字幕"),
    ("86", "AV剧情"),
    ("87", "长腿丝袜"),
    ("88", "邻家人妻"),
    ("89", "网红主播"),
    ("90", "国模私拍"),
    ("92", "抖阴视频"),
    ("93", "网红头条"),
    ("94", "AV解说"),
    ("95", "制服诱惑"),
    ("96", "明星换脸"),
    ("97", "SM调教"),
    ("98", "女同性恋"),
    ("99", "VR视角"),
];

/// 去 HTML 标签与常见实体（与 ZakaHttp.clean 的常用行为一致）。
fn clean_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_tag = false;
    for ch in raw.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(ch);
                }
            }
        }
    }
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 封面补全：站内相对地址补 host，`//` 补 `https:`。
fn abs_pic(host: &str, img: &str) -> String {
    if img.is_empty() {
        return String::new();
    }
    if img.starts_with("http") {
        img.to_string()
    } else if let Some(rest) = img.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = img.strip_prefix('/') {
        format!("{host}/{rest}")
    } else {
        format!("{host}/{img}")
    }
}

/// 解包响应信封：status==1，data 替换三处字符后反转再 base64 解。
fn unlock(body: &str) -> ApiResult<Value> {
    let envelope: Value = serde_json::from_str(body)?;
    if !envelope.is_object() {
        return Err(ApiError::Internal("大哥视频响应格式无法识别".into()));
    }
    let status = get(&envelope, "status")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    if status != 1 {
        let detail = text_of(&envelope, &["msg", "message", "error"]);
        let mut message = format!("大哥视频接口返回 status={status}");
        if !detail.is_empty() {
            message.push_str(&format!("：{detail}"));
        }
        return Err(ApiError::Internal(message));
    }
    let data = text_of(&envelope, &["data"]);
    if data.len() < 8 {
        return Err(ApiError::Internal("大哥视频响应缺少数据".into()));
    }
    let swapped: String = data
        .chars()
        .map(|c| match c {
            '/' => '0',
            '@' => '/',
            '.' => '+',
            other => other,
        })
        .collect();
    let reversed: String = swapped.chars().rev().collect();
    let mut padded = reversed;
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let decoded = B64
        .decode(padded.as_bytes())
        .map_err(|_| ApiError::Internal("大哥视频数据解包失败".into()))?;
    let text = String::from_utf8(decoded)
        .map_err(|_| ApiError::Internal("大哥视频数据解包失败".into()))?;
    let value: Value = serde_json::from_str(&text)?;
    Ok(value)
}

/// 调站方 JSON 接口：两个 host 按顺序尝试，失败换下一个。
async fn api(path: &str) -> ApiResult<Value> {
    let mut last_err = ApiError::Internal("大哥视频接口请求失败".into());
    for host in HOSTS {
        let url = format!("{host}{path}");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Accept-Language", "zh-CN,zh;q=0.9,zh-TW;q=0.8,en;q=0.7")
            .header("Referer", format!("{host}/enter"))
            .send()
            .await;
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        let status = resp.status().as_u16();
        if status != 200 {
            last_err = ApiError::Internal(format!("大哥视频接口 HTTP {status}"));
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        match unlock(&text) {
            Ok(value) => return Ok(value),
            Err(e) => {
                last_err = e;
                continue;
            }
        }
    }
    Err(last_err)
}

/// 列表条目转视频卡片（与 Java 的 itemsToVods 一致）。
fn items_to_cards(host: &str, items: &[Value]) -> Vec<Value> {
    let mut out = Vec::new();
    for entry in items {
        let id = text_of(entry, &["vod_id", "id"]);
        if id.is_empty() {
            continue;
        }
        let title = clean_text(&text_of(entry, &["title"]));
        if title.is_empty() {
            continue;
        }
        let cover = abs_pic(host, &text_of(entry, &["img"]));
        let duration = text_of(entry, &["duration"]);
        let time = text_of(entry, &["time"]);
        let remark = if !duration.is_empty() { duration } else { time };
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let digits: String = category_id.chars().filter(|c| c.is_ascii_digit()).collect();
    let list_id = if digits.is_empty() {
        "56"
    } else {
        digits.as_str()
    };
    let resp = api(&format!("/api/lists/{list_id}/{page}/24.json")).await?;
    let host = HOSTS[0];
    let items = get(&resp, "items")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let cards = items_to_cards(host, &items);
    let has_more = cards.len() >= 24;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let resp = match api(&format!("/api/play/{series_id}.json")).await {
        Ok(v) => v,
        Err(_) => {
            return Err(ApiError::Internal("详情接口临时不可用，稍后再试".into()));
        }
    };
    let mut title = clean_text(&text_of(&resp, &["title"]));
    if title.is_empty() {
        title = clean_text(
            &text_of(&resp, &["s_title"])
                .replace("正在播放:", "")
                .trim()
                .to_string(),
        );
    }
    if title.is_empty() {
        return Err(ApiError::Internal("大哥视频未返回影片资料".into()));
    }
    let cover = abs_pic(HOSTS[0], &text_of(&resp, &["img"]));
    let cname = text_of(&resp, &["cname"]);
    let time = text_of(&resp, &["time"]);
    let mut tags: Vec<String> = Vec::new();
    if let Some(arr) = get(&resp, "tags").and_then(arr_of) {
        for t in arr {
            let s = t.as_str().unwrap_or("").trim().to_string();
            if !s.is_empty() {
                tags.push(s);
            }
        }
    }
    let mut actors: Vec<String> = Vec::new();
    if let Some(arr) = get(&resp, "actors").and_then(arr_of) {
        for a in arr {
            let s = a.as_str().unwrap_or("").trim().to_string();
            if !s.is_empty() {
                actors.push(s);
            }
        }
    }
    let content = clean_text(&text_of(&resp, &["content"]));
    let mut synopsis = String::new();
    if !cname.is_empty() {
        synopsis.push_str(&format!("分类：{cname}\n"));
    }
    if !time.is_empty() {
        synopsis.push_str(&format!("日期：{time}\n"));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("标签：{}\n", tags.join(" / ")));
    }
    if !actors.is_empty() {
        synopsis.push_str(&format!("演员：{}\n", actors.join(" / ")));
    }
    if !content.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push('\n');
        }
        synopsis.push_str(&content);
    }
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(players) = get(&resp, "player").and_then(arr_of) {
        for (i, entry) in players.iter().enumerate() {
            let name = text_of(entry, &["name"]);
            if name.is_empty() {
                continue;
            }
            let play = text_of(entry, &["play"]).trim().to_string();
            if play.len() < 10 {
                continue;
            }
            episodes.push(episode_json(&play, &format!("线路{}", i + 1), series_id));
        }
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("大哥视频未返回可播放分集".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = with_query(
        "/api/vodsearch",
        &[("key", query), ("page", "1"), ("limit", "24")],
    );
    let resp = api(&path).await?;
    let items = get(&resp, "items")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let cards = items_to_cards(HOSTS[0], &items);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("大哥视频该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pack(payload: &str) -> String {
        let b64 = B64.encode(payload.as_bytes());
        let reversed: String = b64.chars().rev().collect();
        reversed
            .chars()
            .map(|c| match c {
                '0' => '/',
                '/' => '@',
                '+' => '.',
                other => other,
            })
            .collect()
    }

    #[test]
    fn unlock_roundtrip() {
        let payload =
            r#"{"items":[{"vod_id":1,"title":"T","img":"i","duration":"12:34"}],"page":1}"#;
        let body = format!("{{\"status\":1,\"data\":\"{}\"}}", pack(payload));
        let value = unlock(&body).unwrap();
        assert_eq!(value["items"][0]["title"], "T");
        assert_eq!(value["items"][0]["vod_id"], 1);
    }

    #[test]
    fn unlock_rejects_bad_status() {
        let body = r#"{"status":0,"data":"xxxx"}"#;
        assert!(unlock(body).is_err());
    }

    #[test]
    fn categories_are_32() {
        assert_eq!(CATEGORIES.len(), 32);
        assert_eq!(CATEGORIES[0], ("56", "亚洲有码"));
        assert_eq!(CATEGORIES[31], ("99", "VR视角"));
    }

    #[test]
    fn items_map_fields() {
        let items = vec![
            json!({"vod_id": 511753, "title": "A <b>B</b>", "img": "https://x/i.jpg", "duration": "10:00", "time": "2026-11-05"}),
        ];
        let cards = items_to_cards(HOSTS[0], &items);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "511753");
        assert_eq!(cards[0]["title"], "A B");
        assert_eq!(cards[0]["remark"], "10:00");
    }

    #[tokio::test]
    async fn play_passthrough() {
        assert_eq!(
            play("https://c32.dycp444.com/x/index.m3u8").await.unwrap()["url"],
            "https://c32.dycp444.com/x/index.m3u8"
        );
        assert!(play("not-a-url").await.is_err());
    }
    #[tokio::test]
    #[ignore]
    async fn live_avjieshuo_catalog() {
        let start = std::time::Instant::now();
        let r = catalog("94", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE dage av解说 cat=94 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "dage AV解说 catalog empty");
    }
}
