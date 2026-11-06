//! Netflav：`https://netflav.com`。
//!
//! jar 内 ZakaNetflavAmns 的移植。Next.js 站：列表页取
//! `__NEXT_DATA__` 里 `props.initialState.{栏目}.docs`（栏目：
//! trending/censored/uncensored/chinese/actress/search）。
//! 分类：最受歡迎/有碼/無碼/中文字幕/女優 + 23 个 g: 類別。
//! 详情取 `/video?id=` 的 state.video.data；本站一般无直出流
//! （srcs/premiumUrl 常为空），靠 MissAV 借播：先 POST
//! `missav.ws286.ystv.top/api/tvbox/reg` 拿 tok，再搜番號、取
//! detail 的 vod_play_url 里的 `{id}@auto`，经
//! `/api/tvbox/play?id=&mode=relay` 拿带签名的 m3u8。
//! 注意：借播按番號搜，镜像收录不全（如 ATID-698 搜不到），
//! 搜不到时详情只剩简介、无播放集；磁力只列不播，核心不回磁力集。

use std::collections::HashSet;
use std::sync::Mutex;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://netflav.com";
const MISS: &str = "https://missav.ws286.ystv.top";
const MISS_REFERER: &str = "https://missav.ws/";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MISS_UA: &str = "okhttp/4.9.0";

/// 23 个 g: 類別（jar 的 GENRES 原文）。
const GENRES: &[&str] = &[
    "口交",
    "乳交",
    "高畫質",
    "單體作品",
    "DMM獨家",
    "中出",
    "巨乳",
    "已婚婦女",
    "成熟的女人",
    "數位馬賽克",
    "美少女",
    "業餘",
    "企畫",
    "4小時以上作品",
    "出軌",
    "多P",
    "蕩婦",
    "潮吹",
    "乳房",
    "戲劇",
    "苗條",
    "亂倫",
    "高中女生",
];

/// MissAV 的 tok 缓存（jar 的 ensureTok 同款，注册一次复用）。
static TOK: Mutex<Option<String>> = Mutex::new(None);

/// 带头取页（jar 的 page 同款头）。
async fn fetch_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("Netflav 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("Netflav 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!(
            "Netflav 请求失败：HTTP {status}"
        )));
    }
    Ok(text)
}

/// jar 的 nextData：取 `__NEXT_DATA__` 的 JSON。
fn next_data(html: &str) -> Option<Value> {
    if html.len() < 100 {
        return None;
    }
    let i = html.find("__NEXT_DATA__")?;
    let j = html[i..].find('>')? + i;
    let k = html[j..].find("</script>")? + j;
    serde_json::from_str(&html[j + 1..k]).ok()
}

/// jar 的 state：`props.initialState`。
fn initial_state(html: &str) -> Option<Value> {
    let nd = next_data(html)?;
    nd.get("props")?
        .get("initialState")?
        .as_object()
        .map(|_| nd["props"]["initialState"].clone())
}

fn unesc(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// jar 的 unplus：'+' 变空格（api98 扁平串与标题里用）。
fn unplus(s: &str) -> String {
    s.replace('+', " ")
}

/// jar 的 first：取第一个非空字符串。
fn first<'a>(vals: &[&'a str]) -> &'a str {
    vals.iter()
        .find(|v| !v.trim().is_empty())
        .copied()
        .unwrap_or("")
}

/// 相对地址补成绝对地址。
fn abs_url(u: &str) -> String {
    let u = unesc(u.trim());
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u;
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https:{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{u}")
}

/// 列表卡片（jar 的 card 同款）：标题取 title_zh/title，封面取
/// preview_hp，备注拼“磁力 · 日期 · views:数”。
fn card(doc: &Value) -> Option<Value> {
    let video_id = doc.get("videoId")?.as_str()?.trim();
    if video_id.is_empty() {
        return None;
    }
    let title_zh = doc.get("title_zh").and_then(|v| v.as_str()).unwrap_or("");
    let title = doc.get("title").and_then(|v| v.as_str()).unwrap_or("");
    let name = unplus(first(&[title_zh, title]));
    let name = if name.is_empty() {
        "Netflav 影片".to_string()
    } else {
        name.trim().to_string()
    };
    let pic = abs_url(doc.get("preview_hp").and_then(|v| v.as_str()).unwrap_or(""));
    let mut remarks: Vec<String> = Vec::new();
    let has_mag = doc
        .get("hasMagnets")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
        || doc
            .get("magnets")
            .and_then(|v| v.as_array())
            .map(|a| !a.is_empty())
            .unwrap_or(false);
    if has_mag {
        remarks.push("磁力".to_string());
    }
    if let Some(d) = doc.get("sourceDate").and_then(|v| v.as_str()) {
        if d.len() >= 10 {
            remarks.push(d[..10].to_string());
        }
    }
    if let Some(v) = doc.get("views").and_then(|v| v.as_i64()) {
        remarks.push(format!("views:{v}"));
    }
    let remark = if remarks.is_empty() {
        "Netflav".to_string()
    } else {
        remarks.join(" · ")
    };
    Some(item_json(video_id, &name, &pic, &remark))
}

/// 女优卡片：vod_id 为 `actress:{名}`，备注为“{n} 部”。
fn actress_card(doc: &Value) -> Option<Value> {
    let name = first(&[
        doc.get("name").and_then(|v| v.as_str()).unwrap_or(""),
        doc.get("name_en").and_then(|v| v.as_str()).unwrap_or(""),
    ]);
    if name.is_empty() {
        return None;
    }
    let pic = abs_url(doc.get("icon").and_then(|v| v.as_str()).unwrap_or(""));
    let count = doc.get("videoCount").and_then(|v| v.as_i64()).unwrap_or(0);
    Some(item_json(
        &format!("actress:{name}"),
        name,
        &pic,
        &format!("{count} 部"),
    ))
}

/// jar 的 listUrl：分类拼列表地址；返回（地址，栏目键）。
fn list_url(tid: &str, page: i64) -> (String, String) {
    if let Some(genre) = tid.strip_prefix("g:") {
        let enc = percent_encoding::utf8_percent_encode(genre, percent_encoding::NON_ALPHANUMERIC)
            .to_string();
        (
            format!("{HOST}/censored?genre={enc}&page={page}"),
            "censored".to_string(),
        )
    } else if tid == "actress" {
        (format!("{HOST}/actress?page={page}"), "actress".to_string())
    } else {
        (format!("{HOST}/{tid}?page={page}"), tid.to_string())
    }
}

/// 取某栏目的 docs/total/pages。
async fn section_docs(url: &str, section: &str) -> ApiResult<(Vec<Value>, i64, i64)> {
    let html = fetch_text(url).await?;
    let state =
        initial_state(&html).ok_or_else(|| ApiError::Internal("Netflav 未取到页面数据".into()))?;
    let sec = state
        .get(section)
        .ok_or_else(|| ApiError::Internal(format!("Netflav 无栏目 {section}")))?;
    let docs = sec
        .get("docs")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let total = sec.get("total").and_then(|v| v.as_i64()).unwrap_or(0);
    let pages = sec.get("pages").and_then(|v| v.as_i64()).unwrap_or(1);
    Ok((docs, total, pages))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("trending", "最受歡迎"),
        category_json("censored", "有碼"),
        category_json("uncensored", "無碼"),
        category_json("chinese", "中文字幕"),
        category_json("actress", "女優"),
    ];
    for genre in GENRES {
        list.push(category_json(
            &format!("g:{genre}"),
            &format!("類別·{genre}"),
        ));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let (url, section) = list_url(category_id, page);
    let (docs, total, pages) = section_docs(&url, &section).await?;
    let items: Vec<Value> = if section == "actress" {
        docs.iter().filter_map(actress_card).take(48).collect()
    } else {
        docs.iter().filter_map(card).take(20).collect()
    };
    let limit = if section == "actress" { 48 } else { 20 };
    Ok(json!({
        "page": page,
        "pagecount": pages.max(1),
        "limit": limit,
        "total": total,
        "has_more": page < pages,
        "list": items,
    }))
}

/// jar 的 normCode：从标题/番號里抽 `字母-数字` 形番號。
fn norm_code(code: &str) -> String {
    let re = Regex::new(r"(?i)\b([a-z]{2,6})[-_ ]?(\d{2,5})\b").unwrap();
    re.captures(code)
        .map(|c| {
            format!(
                "{}-{}",
                c.get(1).unwrap().as_str().to_uppercase(),
                c.get(2).unwrap().as_str()
            )
        })
        .unwrap_or_else(|| code.trim().to_string())
}

/// MissAV 注册拿 tok（jar 的 ensureTok 同款，缓存复用）。
async fn ensure_tok() -> ApiResult<String> {
    if let Ok(guard) = TOK.lock() {
        if let Some(tok) = guard.as_ref() {
            if !tok.is_empty() {
                return Ok(tok.clone());
            }
        }
    }
    let resp = client()?
        .post(format!("{MISS}/api/tvbox/reg"))
        .header("User-Agent", MISS_UA)
        .json(&json!({"dev": "tvbox-device", "src": "missav-official"}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("MissAV 注册失败：{e}")))?;
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("MissAV 注册响应失败：{e}")))?;
    let tok = body
        .get("tok")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if tok.is_empty() {
        return Err(ApiError::Internal("MissAV 注册未返回 tok".into()));
    }
    if let Ok(mut guard) = TOK.lock() {
        *guard = Some(tok.clone());
    }
    Ok(tok)
}

/// MissAV 的 msvGet：地址后拼 `t={tok}&dev=tvbox-device`。
async fn msv_get(path: &str) -> ApiResult<Value> {
    let tok = ensure_tok().await?;
    let sep = if path.contains('?') { "&" } else { "?" };
    let url = format!("{MISS}{path}{sep}t={tok}&dev=tvbox-device");
    let resp = client()?
        .get(&url)
        .header("User-Agent", MISS_UA)
        .header("Referer", format!("{MISS}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("MissAV 请求失败：{e}")))?;
    let status = resp.status();
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("MissAV 响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!(
            "MissAV 请求失败：HTTP {status}"
        )));
    }
    Ok(body)
}

/// jar 的 borrow：按番號在 MissAV 搜，取 detail 的 vod_play_url
/// 里第一个 `{id}@auto` 形播放 id。
async fn borrow(code: &str) -> ApiResult<String> {
    let norm = norm_code(code);
    let enc = percent_encoding::utf8_percent_encode(&norm, percent_encoding::NON_ALPHANUMERIC)
        .to_string();
    let found = msv_get(&format!("/api/tvbox/search?wd={enc}&pg=1")).await?;
    let first = found
        .get("list")
        .and_then(|v| v.as_array())
        .and_then(|a| a.first().cloned());
    let Some(item) = first else {
        return Err(ApiError::Internal(format!("MissAV 未收录番號 {norm}")));
    };
    let vod_id = item
        .get("vod_id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if vod_id.is_empty() {
        return Err(ApiError::Internal("MissAV 搜索结果无 vod_id".into()));
    }
    let enc_id = percent_encoding::utf8_percent_encode(&vod_id, percent_encoding::NON_ALPHANUMERIC)
        .to_string();
    let detail = msv_get(&format!("/api/tvbox/detail?id={enc_id}")).await?;
    let play_url = detail
        .get("list")
        .and_then(|v| v.as_array())
        .and_then(|a| a.first())
        .and_then(|v| v.get("vod_play_url"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    // 形如：自动${id}@auto#720P${id}@720#1080P${id}@1080...
    let first_seg = play_url.split('#').next().unwrap_or("");
    let play_id = first_seg.split('$').nth(1).unwrap_or("").trim().to_string();
    if play_id.is_empty() {
        return Err(ApiError::Internal("MissAV 详情未给出播放 id".into()));
    }
    Ok(play_id)
}

/// jar 的 msvPlay：`/api/tvbox/play?id=&mode=relay` 拿带签名 m3u8。
async fn msv_play(play_id: &str) -> ApiResult<String> {
    let enc = percent_encoding::utf8_percent_encode(play_id, percent_encoding::NON_ALPHANUMERIC)
        .to_string();
    let body = msv_get(&format!("/api/tvbox/play?id={enc}&mode=relay")).await?;
    let url = body
        .get("url")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if url.is_empty() {
        return Err(ApiError::Internal("MissAV 未返回播放地址".into()));
    }
    Ok(url)
}

/// jar 的 detailData：取 `/video?id=` 的 state.video.data；缺字段
/// 时走 `/api98/video/v3/retrieveVideo/{id}` 的扁平串补。
async fn detail_data(video_id: &str) -> ApiResult<Value> {
    let html = fetch_text(&format!("{HOST}/video?id={video_id}")).await?;
    let state =
        initial_state(&html).ok_or_else(|| ApiError::Internal("Netflav 未取到详情数据".into()))?;
    let data = state
        .get("video")
        .and_then(|v| v.get("data"))
        .cloned()
        .unwrap_or(Value::Null);
    let has_title = data
        .get("title_zh")
        .and_then(|v| v.as_str())
        .map(|s| !s.is_empty())
        .unwrap_or(false)
        || data
            .get("title")
            .and_then(|v| v.as_str())
            .map(|s| !s.is_empty())
            .unwrap_or(false);
    if has_title {
        return Ok(data);
    }
    // api98 扁平串：key$value|key$value...，'+' 为空格。
    let resp = client()?
        .get(format!("{HOST}/api98/video/v3/retrieveVideo/{video_id}"))
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("Referer", format!("{HOST}/video?id={video_id}"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("Netflav api98 请求失败：{e}")))?;
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("Netflav api98 响应失败：{e}")))?;
    let flat = body
        .get("result")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let mut obj = serde_json::Map::new();
    for part in flat.split('|') {
        if let Some((k, v)) = part.split_once('$') {
            let val = percent_encoding::percent_decode_str(&unplus(v))
                .decode_utf8_lossy()
                .to_string();
            obj.insert(k.to_string(), Value::String(val));
        }
    }
    Ok(Value::Object(obj))
}

/// 女优详情（jar 的 actressDetail 同款）：按女优名站内搜作品。
async fn actress_detail(name: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(name, percent_encoding::NON_ALPHANUMERIC).to_string();
    let (docs, _, _) =
        section_docs(&format!("{HOST}/search?keyword={enc}&page=1"), "search").await?;
    let mut episodes = Vec::new();
    let mut seen = HashSet::new();
    let mut cover = String::new();
    for doc in docs.iter().take(30) {
        if let Some(item) = card(doc) {
            let id = item["vod_id"].as_str().unwrap_or("").to_string();
            if !seen.insert(id.clone()) {
                continue;
            }
            if cover.is_empty() {
                cover = item["vod_pic"].as_str().unwrap_or("").to_string();
            }
            let title = item["vod_name"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&id, &title, &format!("actress:{name}")));
        }
    }
    let synopsis = format!("女優: {name}\n作品 {} 部（來源 netflav）", episodes.len());
    Ok(json!({
        "id": format!("actress:{name}"),
        "title": format!("女優 {name}"),
        "cover": cover,
        "synopsis": synopsis,
        "episodes": episodes,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    if let Some(name) = video_id.strip_prefix("actress:") {
        return actress_detail(name).await;
    }
    let data = detail_data(video_id).await?;
    let title_zh = data.get("title_zh").and_then(|v| v.as_str()).unwrap_or("");
    let title = data.get("title").and_then(|v| v.as_str()).unwrap_or("");
    let name = unplus(first(&[title_zh, title]));
    let name = if name.is_empty() {
        "Netflav 影片".to_string()
    } else {
        name.trim().to_string()
    };
    let cover = abs_url(first(&[
        data.get("preview_hp")
            .and_then(|v| v.as_str())
            .unwrap_or(""),
        data.get("preview").and_then(|v| v.as_str()).unwrap_or(""),
    ]));
    let desc = data
        .get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let code = data.get("code").and_then(|v| v.as_str()).unwrap_or("");
    let duration = data
        .get("duration")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let category = data
        .get("category")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let actors = data
        .get("actors")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .map(|s| s.split(':').nth(1).unwrap_or(s).to_string())
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default();
    let mut synopsis = String::new();
    if !code.is_empty() {
        synopsis.push_str(&format!("番號：{code}\n"));
    }
    if !actors.is_empty() {
        synopsis.push_str(&format!("女優: {actors}\n"));
    }
    if !duration.is_empty() {
        synopsis.push_str(&format!("片長：{duration}\n"));
    }
    if !category.is_empty() {
        synopsis.push_str(&format!("分類：{category}\n"));
    }
    synopsis.push_str(&desc);
    let mut episodes = Vec::new();
    // 本站直出流（一般为空，有则先放）。
    let mut direct: Vec<String> = Vec::new();
    for key in ["premiumUrl", "previewVideo"] {
        if let Some(u) = data.get(key).and_then(|v| v.as_str()) {
            if u.starts_with("http") {
                direct.push(u.to_string());
            }
        }
    }
    for key in ["srcs", "otherSrcs"] {
        if let Some(arr) = data.get(key).and_then(|v| v.as_array()) {
            for v in arr {
                if let Some(u) = v.as_str() {
                    if u.starts_with("http") {
                        direct.push(u.to_string());
                    }
                }
            }
        }
    }
    for (i, u) in direct.iter().enumerate() {
        episodes.push(episode_json(u, &format!("Netflav·直出{}", i + 1), video_id));
    }
    // 借播（jar 原文：borrow 失败时详情无此集，不报错）。
    if !code.is_empty() {
        if let Ok(play_id) = borrow(code).await {
            episodes.push(episode_json(
                &format!("msv|{play_id}"),
                "⚡ 在線播放（借播）",
                video_id,
            ));
        }
    }
    Ok(json!({
        "id": video_id,
        "title": name,
        "cover": cover,
        "synopsis": synopsis.trim(),
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let (docs, _, _) =
        section_docs(&format!("{HOST}/search?keyword={enc}&page=1"), "search").await?;
    let items: Vec<Value> = docs.iter().filter_map(card).take(40).collect();
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(play_id) = video_id.strip_prefix("msv|") {
        // 先 @auto，空则试 @master（jar 的 probePlay 同款）。
        match msv_play(play_id).await {
            Ok(url) => return Ok(json!({"url": url})),
            Err(_) => {
                let alt = play_id.replace("@auto", "@master");
                if alt != play_id {
                    let url = msv_play(&alt).await?;
                    return Ok(json!({"url": url}));
                }
                return Err(ApiError::Internal("MissAV 未返回播放地址".into()));
            }
        }
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("Netflav 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn norm_code_extracts_code() {
        assert_eq!(norm_code("ATID-698"), "ATID-698");
        assert_eq!(norm_code("[中字]waaa 682 夜里"), "WAAA-682");
        assert_eq!(norm_code("IPZZ300"), "IPZZ-300");
    }

    #[test]
    fn next_data_reads_initial_state() {
        let html = r#"<script id="__NEXT_DATA__" type="application/json">{"props":{"initialState":{"trending":{"docs":[],"total":0,"pages":1}}}}</script>"#;
        let state = initial_state(html).unwrap();
        assert_eq!(state["trending"]["total"], 0);
    }

    #[test]
    fn card_reads_doc_fields() {
        let doc = json!({
            "videoId": "abc123",
            "title_zh": "[中字]ATID-698 影片",
            "code": "ATID-698",
            "preview_hp": "https://pics/x.jpg",
            "views": 294,
            "sourceDate": "2026-10-29T16:40:19.631Z",
            "magnets": ["magnet:?xt=urn:btih:abc"]
        });
        let item = card(&doc).unwrap();
        assert_eq!(item["id"], "abc123");
        assert_eq!(item["title"], "[中字]ATID-698 影片");
        assert_eq!(item["remark"], "磁力 · 2026-10-29 · views:294");
    }
}
