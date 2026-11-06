//! 🔞Senzuri Tube（senzuri.tube）：Vue 单页应用 + JSON API 站。
//!
//! 列表/详情/搜索走 /api/json/videos2、/api/json/video、
//! /api/videos2.php；分类清单走 /api/json/main；取流走
//! /api/videofile.php，返回的 video_url 是 base164 编码
//!（字母表含西里尔字母 А/В/С/Е/М，见 BASE164_ALPHABET），
//! 解出本站 /get_file/ 直链（302 跳到 ahcdn 签名 mp4）。
//! 验门（2026-11-06 本机出口实测）：视频 10785303
//! 《09119,Naughty porn with guys and girls》31:12；
//! videofile 解出的 get_file 302 → ahcdn 签名 mp4，Range
//! 206 + ftypisom 魔数；最新列表 p1/p2 各 60 条 0 重合；
//! 分类 jav-censored 60 条全含该分类；搜索 jav 60 条、
//! 总数 160864；main 接口分类 10 个。
//! 注意：直接调 /api/json/categories/ 返回空列表，分类
//! 清单须走 main 接口；/api/videos_search.php 本机 404，
//! 搜索改走 /api/videos2.php（301 跟随）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://senzuri.tube";
const API: &str = "https://senzuri.tube/api";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// base164 字母表：前 5 个大写字母是西里尔字母
/// А(U+0410) В(U+0412) С(U+0421) Е(U+0415) М(U+041C)，
/// 其余为拉丁字母；第 65 个字符 ~ 为填充位（索引 64）。
const BASE164_ALPHABET: &str = "АВСDЕFGHIJKLМNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,~";

/// 静态分类：3 路排序 + main 接口返回的 10 个分类。
const CATS: &[(&str, &str)] = &[
    ("latest-updates", "最新"),
    ("most-popular", "最热"),
    ("longest", "最长"),
    ("cat:jav-censored", "JAV Censored"),
    ("cat:hd", "HD"),
    ("cat:cuckold", "Cuckold"),
    ("cat:asian", "Asian"),
    ("cat:toys", "Toys"),
    ("cat:japanese", "Japanese"),
    ("cat:cheating", "Cheating"),
    ("cat:female-orgasm", "Female Orgasm"),
    ("cat:compilation", "Compilation"),
    ("cat:blowjob-fera", "Blowjob/Fera"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/html, */*")
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Senzuri 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
        .trim()
        .to_string()
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// 站内 JS 的 base164 解码：4 字符一组，索引 64（~ 或缺失）为填充。
fn base164_decode(input: &str) -> String {
    let alpha: Vec<char> = BASE164_ALPHABET.chars().collect();
    let clean: Vec<char> = input.chars().filter(|c| alpha.contains(c)).collect();
    let idx = |c: char| -> usize { alpha.iter().position(|&a| a == c).unwrap_or(64) };
    let mut out: Vec<u8> = Vec::new();
    let mut i = 0;
    while i < clean.len() {
        let a = idx(clean[i]);
        let b = if i + 1 < clean.len() {
            idx(clean[i + 1])
        } else {
            64
        };
        let c = if i + 2 < clean.len() {
            idx(clean[i + 2])
        } else {
            64
        };
        let d = if i + 3 < clean.len() {
            idx(clean[i + 3])
        } else {
            64
        };
        out.push(((a << 2) | (b >> 4)) as u8);
        if c != 64 {
            out.push((((b & 15) << 4) | (c >> 2)) as u8);
        }
        if d != 64 {
            out.push((((c & 3) << 6) | d) as u8);
        }
        i += 4;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn videos_url(category_id: &str, page: i64) -> String {
    if let Some(dir) = category_id.strip_prefix("cat:") {
        format!("{API}/json/videos2/86400/str/latest-updates/60/categories.{dir}.{page}.all...json")
    } else {
        format!("{API}/json/videos2/86400/str/{category_id}/60/..{page}.all...json")
    }
}

/// videos2 返回的 videos[] 解析：id、标题、封面、时长。
fn parse_videos(json_text: &str) -> Vec<Value> {
    let Ok(v) = serde_json::from_str::<Value>(json_text) else {
        return Vec::new();
    };
    let Some(arr) = v.get("videos").and_then(|x| x.as_array()) else {
        return Vec::new();
    };
    let mut items = Vec::new();
    for video in arr {
        let id = text_of(video, &["video_id"]);
        if id.is_empty() {
            continue;
        }
        let title = decode_entities(&text_of(video, &["title"]));
        if title.is_empty() {
            continue;
        }
        let mut cover = text_of(video, &["thumbsrc"]);
        if cover.is_empty() {
            cover = text_of(video, &["thumb"]);
        }
        let remark = text_of(video, &["duration"]);
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn video_json_url(video_id: &str) -> Option<String> {
    let n: i64 = video_id.parse().ok()?;
    let m = 1_000_000 * (n / 1_000_000);
    let k = 1_000 * (n / 1_000);
    Some(format!("{API}/json/video/86400/{m}/{k}/{video_id}.json"))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = videos_url(category_id, page);
    let text = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_videos(&text);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = video_json_url(series_id)
        .ok_or_else(|| ApiError::Internal("Senzuri 视频 id 非数字".into()))?;
    let text = fetch(&url, &format!("{HOST}/")).await?;
    let v: Value = serde_json::from_str(&text).map_err(|e| ApiError::Internal(e.to_string()))?;
    let video = v.get("video").cloned().unwrap_or(Value::Null);
    let title = decode_entities(&text_of(&video, &["title"]));
    if title.is_empty() {
        return Err(ApiError::Internal("Senzuri 未返回影片资料".into()));
    }
    let mut cover = text_of(&video, &["thumbsrc"]);
    if cover.is_empty() {
        cover = text_of(&video, &["thumb"]);
    }
    let desc = decode_entities(&text_of(&video, &["description"]));
    let duration = text_of(&video, &["duration"]);
    let mut cats: Vec<String> = Vec::new();
    if let Some(map) = video.get("categories").and_then(|c| c.as_object()) {
        for (_, c) in map {
            let t = text_of(c, &["title"]);
            if !t.is_empty() {
                cats.push(t);
            }
        }
    }
    let mut lines: Vec<String> = Vec::new();
    if !cats.is_empty() {
        lines.push(format!("分类：{}", cats.join("、")));
    }
    if !duration.is_empty() {
        lines.push(format!("时长：{duration}"));
    }
    let mut synopsis = desc;
    if !lines.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push('\n');
        }
        synopsis.push_str(&lines.join("\n"));
    }
    let synopsis = truncate(&synopsis, 400);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

/// videofile.php 返回 [{format, video_url(base164), is_default}]，
/// 取默认清晰度解出 /get_file/ 直链。
async fn fetch_stream_url(video_id: &str) -> ApiResult<String> {
    let url = format!("{API}/videofile.php?video_id={video_id}&lifetime=864000");
    let text = fetch(&url, &format!("{HOST}/videos/{video_id}/")).await?;
    let v: Value = serde_json::from_str(&text).map_err(|e| ApiError::Internal(e.to_string()))?;
    let Some(arr) = v.as_array() else {
        return Err(ApiError::Internal("Senzuri 取流返回非数组".into()));
    };
    let mut chosen: Option<&Value> = None;
    for entry in arr {
        if text_of(entry, &["is_default"]) == "1" {
            chosen = Some(entry);
            break;
        }
        if chosen.is_none() {
            chosen = Some(entry);
        }
    }
    let entry = chosen.ok_or_else(|| ApiError::Internal("Senzuri 取流为空".into()))?;
    let enc = text_of(entry, &["video_url"]);
    if enc.is_empty() {
        return Err(ApiError::Internal("Senzuri 取流无 video_url".into()));
    }
    let decoded = base164_decode(&enc);
    if decoded.is_empty() || !decoded.contains("get_file/") {
        return Err(ApiError::Internal("Senzuri 取流解码失败".into()));
    }
    if let Some(rest) = decoded.strip_prefix('/') {
        Ok(format!("{HOST}/{rest}"))
    } else if decoded.starts_with("http") {
        Ok(decoded)
    } else {
        Ok(format!("{HOST}/{decoded}"))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let id = video_id.split('$').last().unwrap_or(video_id);
    let url = fetch_stream_url(id).await?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/videos/{id}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{API}/videos2.php?params=86400/str/relevance/60/search..1.all...&s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let text = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_videos(&text);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base164_decode_real_sample() {
        // videofile.php 对视频 10785303 返回的真实编码串。
        let enc = "L2dldF9maWxlLz\u{415}v\u{41c}GUz\u{41c}TNkNz\u{41c}wZWFkZj\u{415}1YW\u{415}4ZmU4OGQxZDY5YTU0NWFlOW\u{41c}0ZTNjYj\u{415}4Lz\u{415}wNzg1\u{41c}D\u{410}wLz\u{415}wNzg1\u{41c}z\u{410}zLz\u{415}wNzg1\u{41c}z\u{410}zX2hxLm1wN\u{421}8,ZD0xODcyJmJyPTkwJnRpPT\u{415}3OT\u{41c}5\u{41c}jg0NjQ~";
        assert_eq!(
            base164_decode(enc),
            "/get_file/1/0e313d730eadf15aa8fe88d1d69a545ae9c4e3cb18/10785000/10785303/10785303_hq.mp4/?d=1872&br=90&ti=1793928464"
        );
    }

    #[test]
    fn videos_parse_list() {
        let text = r#"{"total_count":"226840","pages":3781,"videos":[{"video_id":"10785303","title":"09119,Naughty porn with guys and girls","duration":"31:12","dir":"09119-naughty-porn-with-guys-and-girls_26139_34688","thumbsrc":"https://tn.senzuri.tube/contents/videos_screenshots/10785000/10785303/preview.jpg","categories_data":"blowjob-fera|507|Blowjob/Fera"}]}"#;
        let items = parse_videos(text);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "10785303");
        assert_eq!(items[0]["title"], "09119,Naughty porn with guys and girls");
        assert_eq!(
            items[0]["cover"],
            "https://tn.senzuri.tube/contents/videos_screenshots/10785000/10785303/preview.jpg"
        );
        assert_eq!(items[0]["remark"], "31:12");
    }

    #[test]
    fn videos_url_rules() {
        assert_eq!(
            videos_url("latest-updates", 2),
            "https://senzuri.tube/api/json/videos2/86400/str/latest-updates/60/..2.all...json"
        );
        assert_eq!(
            videos_url("cat:jav-censored", 1),
            "https://senzuri.tube/api/json/videos2/86400/str/latest-updates/60/categories.jav-censored.1.all...json"
        );
    }

    #[test]
    fn video_json_url_buckets() {
        assert_eq!(
            video_json_url("10785303").unwrap(),
            "https://senzuri.tube/api/json/video/86400/10000000/10785000/10785303.json"
        );
        assert!(video_json_url("abc").is_none());
    }
}
