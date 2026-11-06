//! VJAV（vjav.com）：TubeCorporate/KVS 站，全站走 JSON API。
//! 列表 `/api/json/videos2/{lifetime}/{gender}/{sort}/{count}/` +
//! `{section}.{object_id}.{page}.{type}.{duration}.{date}.json`；
//! 详情 `/api/json/video/{lifetime}/{1e6 段}/{1e3 段}/{id}.json`；
//! 分类 `/api/json/categories/{lifetime}/{gender}.{section}.{lang}.json`；
//! 女优 `/api/json/models/{lifetime}/female/filt........../{sort}/60/{page}.json`；
//! 取流 `/api/videofile.php?video_id={id}&lifetime=8640000`，回的
//! video_url 是自定义 base64（西里尔字母表）编码的签名
//! `/get_file/.../{id}_hq.mp4/?d=...&br=...&ti=...` 地址，302 跳到
//! ahcdn 直链，播放器跟随跳转即可。
//! 实测（2026-11-06）：分类 157 项；列表 468870 条，翻页 p1/p2/p3
//! 无重合；搜索 ABF-213 出 1086 条；详情 998037（ABF-213，18:05）；
//! 取流 _hq.mp4 直链 Range 206 + ftypisom，d=1085 与卡片时长一致，
//! 全长非预告；第二片 997903（18:01）同链路解出签名地址。
//! 匿名免费可播，无需登录；只做免费部分，不绕付费墙。
//! 注意：本站是 JS 单页应用，服务端不渲染列表，HTML 壳里无数据，
//! 必须走上面这套 API；本机出口 DNS 会把 vjav.com 劫到黑洞，
//! 实测走 DoH 查真实 IP 直连才通，手机侧正常解析即可。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://vjav.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 站内排序分类（静态段）：站导航最新/最多观看/最高评分/最长/
/// 最多评论 + 女优索引；其余 157 个分类走分类接口动态取。
const SORT_CATS: &[(&str, &str, &str)] = &[
    ("latest", "最新影片", "latest-updates"),
    ("most-viewed", "最多观看", "most-viewed"),
    ("top-rated", "最高评分", "top-rated"),
    ("longest", "最长影片", "longest"),
    ("most-commented", "最多评论", "most-commented"),
];

/// 分类接口挂掉时的兜底：静态段 + 站内量最大的 12 个分类。
const FALLBACK_CATS: &[(&str, &str)] = &[
    ("cat:asian", "Asian"),
    ("cat:japanese", "Japanese"),
    ("cat:hd", "HD"),
    ("cat:jav-censored", "Censored"),
    ("cat:jav-uncensored", "Uncensored"),
    ("cat:big-tits", "Big Tits"),
    ("cat:amateur", "Amateur"),
    ("cat:milf", "MILF"),
    ("cat:creampie", "Creampie/Nakadashi"),
    ("cat:brunette", "Brunette"),
    ("cat:blowjob", "Blowjob/Fera"),
    ("cat:hairy", "Hairy"),
];

/// videofile.php 的 video_url 编码表：标准 base64 字母表里
/// A、B、C、E、M 五个换成了西里尔字母（U+0410/0412/0421/0415/041C）。
const B64_ALPHA: &str = "\u{410}\u{412}\u{421}D\u{415}FGHIJKL\u{41C}NOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,~";

fn video_id_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/videos/(\d+)").unwrap())
}

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", referer);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("VJAV 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn fetch_json_async(url: &str, referer: &str) -> ApiResult<Value> {
    let text = fetch(url, referer).await?;
    serde_json::from_str(&text).map_err(|e| ApiError::Internal(format!("VJAV JSON 解析失败：{e}")))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
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

/// videos2 列表地址：`{section}.{object_id}.{page}.all...json`
///（type=all、duration 与 date 为空）。
fn videos2_url(sort: &str, section: &str, object_id: &str, page: i64) -> String {
    format!("{HOST}/api/json/videos2/86400/str/{sort}/60/{section}.{object_id}.{page}.all...json")
}

/// 详情地址：id 按 1e6 / 1e3 分段，如 998037 → 0/998000。
fn video_url(video_id: i64) -> String {
    let m6 = video_id / 1_000_000 * 1_000_000;
    let m3 = video_id / 1_000 * 1_000;
    format!("{HOST}/api/json/video/86400/{m6}/{m3}/{video_id}.json")
}

fn page_url(video_id: &str, dir: &str) -> String {
    format!("{HOST}/videos/{video_id}/{dir}/")
}

/// 列表 JSON → 视频卡片：id 为详情页地址，封面 scr，备注为时长。
fn parse_videos(v: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    if v.get("error").is_some() {
        return items;
    }
    let Some(arr) = v.get("videos").and_then(|x| x.as_array()) else {
        return items;
    };
    for it in arr {
        let id = it
            .get("video_id")
            .map(|x| x.to_string())
            .unwrap_or_default();
        let id = id.trim_matches('"').to_string();
        let dir = it
            .get("dir")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let title = it
            .get("title")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = it
            .get("scr")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let remark = it
            .get("duration")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        items.push(item_json(
            &page_url(&id, &dir),
            &truncate(&decode_entities(&title), 90),
            &cover,
            &remark,
        ));
    }
    items
}

fn has_more(v: &Value, items_len: usize) -> bool {
    if items_len == 0 {
        return false;
    }
    match v.get("pages").and_then(|x| x.as_i64()) {
        Some(pages) => {
            let page = v
                .get("params")
                .and_then(|p| p.get("page"))
                .and_then(|x| x.as_i64())
                .unwrap_or(1);
            page < pages
        }
        None => items_len >= 60,
    }
}

/// 自定义 base64 解码：先去掉不在表里的字符，再按标准 base64
/// 位运算还原，最后做一遍 %XX 还原（与站内 unescape 对齐）。
fn decode_video_url(enc: &str) -> Option<String> {
    let alpha: Vec<char> = B64_ALPHA.chars().collect();
    let clean: Vec<usize> = enc
        .chars()
        .filter_map(|c| alpha.iter().position(|&a| a == c))
        .collect();
    if clean.len() < 4 {
        return None;
    }
    let mut out: Vec<u8> = Vec::new();
    let mut i = 0;
    while i + 3 < clean.len() {
        let o = clean[i];
        let j = clean[i + 1];
        let l = clean[i + 2];
        let n = clean[i + 3];
        i += 4;
        out.push(((o << 2) | (j >> 4)) as u8);
        if l != 64 {
            out.push((((15 & j) << 4) | (l >> 2)) as u8);
        }
        if n != 64 {
            out.push((((3 & l) << 6) | n) as u8);
        }
    }
    let raw = String::from_utf8_lossy(&out).into_owned();
    Some(percent_decode(&raw))
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && bytes[i + 1].is_ascii_hexdigit()
            && bytes[i + 2].is_ascii_hexdigit()
        {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 从 videofile.php 响应里取默认（_hq.mp4）那条的签名地址。
fn pick_signed_url(body: &Value) -> Option<String> {
    let arr = body.as_array()?;
    let mut fallback: Option<String> = None;
    for it in arr {
        let format = it.get("format").and_then(|x| x.as_str()).unwrap_or("");
        let enc = it.get("video_url").and_then(|x| x.as_str()).unwrap_or("");
        if enc.is_empty() {
            continue;
        }
        let decoded = decode_video_url(enc)?;
        if format == "_hq.mp4" {
            return Some(decoded);
        }
        if fallback.is_none() {
            fallback = Some(decoded);
        }
    }
    fallback
}

fn extract_video_id(text: &str) -> Option<i64> {
    video_id_re()
        .captures(text)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = SORT_CATS
        .iter()
        .map(|(id, name, _)| category_json(id, name))
        .collect();
    list.push(category_json("models", "女优"));
    let url = format!("{HOST}/api/json/categories/14400/str.all.en.json");
    match fetch_json_async(&url, &format!("{HOST}/")).await {
        Ok(v) => {
            if let Some(arr) = v.get("categories").and_then(|x| x.as_array()) {
                for c in arr {
                    let dir = c
                        .get("dir")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string();
                    let title = c
                        .get("title")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string();
                    if dir.is_empty() || title.is_empty() {
                        continue;
                    }
                    list.push(category_json(&format!("cat:{dir}"), &title));
                }
            }
            if list.len() <= SORT_CATS.len() + 1 {
                for (id, name) in FALLBACK_CATS {
                    list.push(category_json(id, name));
                }
            }
        }
        Err(_) => {
            for (id, name) in FALLBACK_CATS {
                list.push(category_json(id, name));
            }
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if category_id == "models" {
        let url = format!(
            "{HOST}/api/json/models/86400/female/filt........../latest-updates/60/{page}.json"
        );
        let v = fetch_json_async(&url, &format!("{HOST}/")).await?;
        let mut items = Vec::new();
        if let Some(arr) = v.get("models").and_then(|x| x.as_array()) {
            for m in arr {
                let id = m.get("id").map(|x| x.to_string()).unwrap_or_default();
                let id = id.trim_matches('"').to_string();
                let dir = m
                    .get("dir")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let title = m
                    .get("title")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                if id.is_empty() || title.is_empty() {
                    continue;
                }
                let cover = m
                    .get("img")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let count = m
                    .get("statistics")
                    .and_then(|s| s.get("videos"))
                    .map(|x| x.to_string())
                    .unwrap_or_default();
                let count = count.trim_matches('"').to_string();
                let remark = if count.is_empty() {
                    dir.clone()
                } else {
                    format!("{count} 部")
                };
                items.push(item_json(&format!("modelid:{id}"), &title, &cover, &remark));
            }
        }
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    let url = if let Some(v) = category_id.strip_prefix("cat:") {
        videos2_url("latest-updates", "categories", v, page)
    } else if let Some(v) = category_id.strip_prefix("modelid:") {
        videos2_url("latest-updates", "model", v, page)
    } else {
        let sort = SORT_CATS
            .iter()
            .find(|(id, _, _)| *id == category_id)
            .map(|(_, _, s)| *s)
            .unwrap_or("latest-updates");
        videos2_url(sort, "", "", page)
    };
    let v = fetch_json_async(&url, &format!("{HOST}/")).await?;
    let items = parse_videos(&v);
    let more = has_more(&v, items.len());
    Ok(json!({"items": items, "has_more": more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = extract_video_id(series_id)
        .ok_or_else(|| ApiError::Internal("VJAV 未从详情地址解出视频 id".into()))?;
    let v = fetch_json_async(&video_url(id), series_id).await?;
    let video = v
        .get("video")
        .ok_or_else(|| ApiError::Internal("VJAV 未返回影片资料".into()))?;
    let title = video
        .get("title")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    if title.is_empty() {
        return Err(ApiError::Internal("VJAV 未返回影片资料".into()));
    }
    let cover = video
        .get("thumb")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let mut desc = video
        .get("description")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let mut cats: Vec<String> = Vec::new();
    if let Some(map) = video.get("categories").and_then(|x| x.as_object()) {
        for (_, c) in map {
            if let Some(t) = c.get("title").and_then(|x| x.as_str()) {
                cats.push(t.to_string());
            }
        }
    }
    if !cats.is_empty() {
        if !desc.is_empty() {
            desc.push('\n');
        }
        desc.push_str(&format!("分类：{}", cats.join("、")));
    }
    let models = video
        .get("models")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    if !models.is_empty() {
        if !desc.is_empty() {
            desc.push('\n');
        }
        desc.push_str(&format!("女优：{models}"));
    }
    let desc = truncate(&decode_entities(&desc), 400);
    let dir = video
        .get("dir")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let url = page_url(&id.to_string(), &dir);
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${url}"), "正片", &url)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let id = extract_video_id(&page_url)
        .ok_or_else(|| ApiError::Internal("VJAV 未从 video_id 解出视频 id".into()))?;
    let url = with_query(
        &format!("{HOST}/api/videofile.php"),
        &[("video_id", &id.to_string()), ("lifetime", "8640000")],
    );
    let v = fetch_json_async(&url, &page_url).await?;
    let path = pick_signed_url(&v)
        .ok_or_else(|| ApiError::Internal("VJAV 未从 videofile 解出播放地址".into()))?;
    Ok(json!({
        "url": format!("{HOST}{path}"),
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{HOST}/api/videos2.php"),
        &[("params", "86400/str/relevance/60/search..1.all...")],
    );
    let url = format!(
        "{url}&s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let v = fetch_json_async(&url, &format!("{HOST}/")).await?;
    let items = parse_videos(&v);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_video_url_real_sample() {
        // 2026-11-06 实测：998037 的 videofile 回包。
        let enc = "L2dldF9maWxlLz\u{41c}vYjRkNT\u{415}x\u{41c}m\u{41c}0\u{41c}jY2N2JmNjJjYTFiZjlmYjQ1NTc2ZTZmZDZjND\u{41c}zZmZjLzk5OD\u{410}w\u{41c}\u{421}85OTgw\u{41c}zcvOTk4\u{41c}D\u{41c}3X2hxLm1wN\u{421}8,ZD0x\u{41c}Dg1JmJyPTI0\u{41c}iZ0aT0xNzkzOTIxOD\u{410}w";
        let out = decode_video_url(enc).unwrap();
        assert_eq!(
            out,
            "/get_file/3/b4d5112c42667bf62ca1bf9fb45576e6fd6c433ffc/998000/998037/998037_hq.mp4/?d=1085&br=242&ti=1793921800"
        );
    }

    #[test]
    fn videos2_url_rules() {
        assert_eq!(
            videos2_url("latest-updates", "", "", 1),
            "https://vjav.com/api/json/videos2/86400/str/latest-updates/60/..1.all...json"
        );
        assert_eq!(
            videos2_url("latest-updates", "categories", "asian", 2),
            "https://vjav.com/api/json/videos2/86400/str/latest-updates/60/categories.asian.2.all...json"
        );
        assert_eq!(
            videos2_url("latest-updates", "model", "478", 1),
            "https://vjav.com/api/json/videos2/86400/str/latest-updates/60/model.478.1.all...json"
        );
        assert_eq!(
            videos2_url("most-viewed", "", "", 3),
            "https://vjav.com/api/json/videos2/86400/str/most-viewed/60/..3.all...json"
        );
    }

    #[test]
    fn video_url_segments() {
        assert_eq!(
            video_url(998037),
            "https://vjav.com/api/json/video/86400/0/998000/998037.json"
        );
        assert_eq!(
            video_url(1234567),
            "https://vjav.com/api/json/video/86400/1000000/1234000/1234567.json"
        );
        assert_eq!(
            extract_video_id("https://vjav.com/videos/998037/abf-213japanese-climax-orgasm/"),
            Some(998037)
        );
    }

    #[test]
    fn parse_videos_card() {
        let v: Value = serde_json::from_str(
            r#"{"total_count":"468870","pages":7815,"videos":[{"video_id":"998037","title":"ABF-213japanese climax orgasm","dir":"abf-213japanese-climax-orgasm","duration":"18:05","scr":"https://tn.vjav.com/contents/videos_screenshots/998000/998037/240x180/1.jpg"},{"video_id":"997903","title":"300MIUM-949","dir":"300mium-949japanese-climax-orgasm","duration":"18:01","scr":"https://tn.vjav.com/contents/videos_screenshots/997000/997903/240x180/1.jpg"}]}"#,
        )
        .unwrap();
        let items = parse_videos(&v);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["title"], "ABF-213japanese climax orgasm");
        assert_eq!(items[0]["remark"], "18:05");
        assert_eq!(
            items[0]["id"],
            "https://vjav.com/videos/998037/abf-213japanese-climax-orgasm/"
        );
        assert!(has_more(&v, 2));
    }

    #[test]
    fn parse_videos_error_empty() {
        let v: Value =
            serde_json::from_str(r#"{"error":1,"code":"invalid_params_section"}"#).unwrap();
        assert!(parse_videos(&v).is_empty());
    }

    #[test]
    fn pick_signed_url_prefers_hq() {
        // 自定义字母表编码的 "/get_file/3/abc/1000/1/1_hq.mp4/?d=10&br=200&ti=123"
        //（A/B/C/E/M 五处为西里尔字母，与实测回包同款写法；此处用 JSON
        // \uXXXX 转义写死，避免肉眼分不清西里尔与拉丁同形字母）。
        let v: Value = serde_json::from_str(
            r#"[{"format":"_hq.mp4","video_url":"L2dldF9maWxlLz\u041cvYWJjLz\u0415w\u041cD\u0410v\u041cS8xX2hxLm1wN\u04218,ZD0x\u041c\u0421Zicj0y\u041cD\u0410mdGk9\u041cTIz","is_default":1}]"#,
        )
        .unwrap();
        let url = pick_signed_url(&v).unwrap();
        assert_eq!(url, "/get_file/3/abc/1000/1/1_hq.mp4/?d=10&br=200&ti=123");
    }

    #[test]
    fn percent_decode_basic() {
        assert_eq!(percent_decode("/a%20b/c.mp4?d=1"), "/a b/c.mp4?d=1");
        assert_eq!(percent_decode("/plain/path"), "/plain/path");
    }
}
