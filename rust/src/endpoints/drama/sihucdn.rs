//! 四虎┃免盾CDN：与四虎┃4hu 同一后端、同一数据口、同一加密。
//!
//! 与 jar 的 ZakaSihuCdnAmns 一一对应：五个主方法与 sihu 的
//! const-string 集合完全相同，差别只在 jar 侧的传输层：
//! cdnApi 遍历 P_CDNBASE（hh8dd9.com/hh3hc6.com/d89b94.com
//! 的 /home/ 路径）与 cdnDiscovered() 发现的域名，取回的是
//! HTML 包装页（<script type="text/plain" id="ap-d"
//! data-m="2" data-k="..."> 内含 blob），其解密未从 dex 字
//! 符串里找全（blob base64 解后 6959 字节、非 16 字节对齐，
//! AES-128-CBC 两组 IV 尝试均失败），无法复现、不编造。
//! 本文件改走已验证的 portal.instruno.com 数据口（与 sihu
//! 同款逻辑、同一分类、同一分集），站本身经该路径已验可播；
//! 若后续逆向出 ap-d 传输，再按 jar 原样接回。
//! 注意：jar 的取流还带 UA＋Referer 头，核心 play 只回 url。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{json, Value};

use crate::crypto::{aes_cbc_decrypt, aes_cbc_encrypt, pkcs7_pad, pkcs7_unpad};
use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const PORTAL: &str = "https://portal.instruno.com/public2/json";
const SITE: &str = "https://www.4hu.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const KEY: &[u8] = b"22946bc50fd63164b79df55070a85a92";
const IV: &[u8] = b"kaixin1234567890";

const CDN: &[&str] = &[
    "https://m3u8.34cdn.com",
    "https://m3u8.41cdn.com",
    "https://m3u8.44cdn.com",
    "https://m3u8.46cdn.com",
    "https://m3u8.47cdn.com",
    "https://m3u8.48cdn.com",
    "https://m3u8.73cdn.com",
    "https://m3u8.74cdn.com",
];

const CAT_TTL: Duration = Duration::from_secs(60 * 60);

static CATS: Mutex<Option<(Vec<(String, String)>, Instant)>> = Mutex::new(None);

fn headers(referer: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "application/json,text/plain,*/*".to_string(),
        ),
        (
            "Accept-Language".to_string(),
            "zh-CN,zh;q=0.9,en;q=0.8".to_string(),
        ),
        ("Referer".to_string(), referer.to_string()),
    ]
}

/// 响应解密：data 为 base64url，AES-256-CBC 解密后去填充。
fn decrypt_envelope(body: &Value) -> ApiResult<Value> {
    let data = text_of(body, &["data"]);
    if data.is_empty() {
        return Err(ApiError::Internal("四虎响应无数据".into()));
    }
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(data.trim())
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(data.trim()))
        .map_err(|_| ApiError::Internal("四虎响应 base64 解码失败".into()))?;
    let plain = aes_cbc_decrypt(&raw, KEY, IV);
    let unpadded = pkcs7_unpad(&plain, 16);
    let text = String::from_utf8_lossy(unpadded).into_owned();
    let v: Value = serde_json::from_str(&text)?;
    Ok(v)
}

/// 搜索关键词加密：同款 AES-256-CBC＋PKCS5 填充，标准 Base64。
fn encrypt_keyword(keyword: &str) -> String {
    let padded = pkcs7_pad(keyword.as_bytes(), 16);
    let cipher = aes_cbc_encrypt(&padded, KEY, IV);
    base64::engine::general_purpose::STANDARD.encode(cipher)
}

async fn fetch_json(url: &str, referer: &str) -> ApiResult<Value> {
    let mut req = client()?.get(url);
    for (k, v) in headers(referer) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("四虎请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("四虎数据格式无法识别".into()));
    }
    decrypt_envelope(&body)
}

/// 与 jar 的 plain 一致：去标签、解实体、去空白。
fn plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
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
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 类型：classid 2 为图文、3 为小说，其余为视频；classpath 有值
/// 时优先（pic/book）。
fn kind_of(obj: &Value) -> &'static str {
    let cp = text_of(obj, &["classpath"]);
    if cp == "pic" {
        return "pic";
    }
    if cp == "book" {
        return "book";
    }
    match int_of(obj, &["classid"]) {
        2 => "pic",
        3 => "book",
        _ => "video",
    }
}

fn one(obj: &Value) -> Option<Value> {
    let id = int_of(obj, &["id"]);
    let title = text_of(obj, &["title"]);
    if id <= 0 || title.is_empty() {
        return None;
    }
    let kind = kind_of(obj);
    let vid = if kind == "pic" || kind == "book" {
        format!("m:{id}")
    } else {
        format!("v:{id}")
    };
    let cover = text_of(obj, &["titlepic"]);
    let yulan = text_of(obj, &["yulan"]);
    let remark = if kind == "pic" {
        "图集".to_string()
    } else if kind == "book" {
        "小说".to_string()
    } else if yulan.len() > 8 {
        "预告".to_string()
    } else {
        text_of(obj, &["classname"])
    };
    Some(item_json(&vid, &title, &cover, &remark))
}

fn list_from(arr: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    for obj in arr {
        if let Some(item) = one(obj) {
            let id = item
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if seen.insert(id) {
                items.push(item);
            }
        }
    }
    items
}

/// 与 jar 的 topList 一致：遍历对象全部 key，值是数组的全部扁平
/// 合并（只保留 id>0 的对象），无榜单类型过滤。
fn top_list(obj: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    if let Some(m) = obj.as_object() {
        for (_k, v) in m {
            if let Some(a) = arr_of(v) {
                for item in a {
                    if int_of(item, &["id"]) > 0 {
                        out.push(item.clone());
                    }
                }
            }
        }
    }
    list_from(&out)
}

async fn load_categories() -> ApiResult<Vec<(String, String)>> {
    if let Ok(guard) = CATS.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok(cached.clone());
            }
        }
    }
    let data = fetch_json(
        &format!("{PORTAL}/category-list.json"),
        "https://portal.instruno.com",
    )
    .await?;
    let mut cats: Vec<(String, String)> = Vec::new();
    let mut seen = HashSet::new();
    if let Some(top) = arr_of(&data) {
        for entry in top {
            let id = int_of(entry, &["classid"]);
            let name = text_of(entry, &["classname"]);
            if id > 0 && !name.is_empty() && seen.insert(format!("c:{id}")) {
                cats.push((format!("c:{id}"), name));
            }
            if let Some(subs) = get(entry, "items").and_then(arr_of) {
                for sub in subs {
                    let sid = int_of(sub, &["classid"]);
                    let sname = text_of(sub, &["classname"]);
                    if sid > 0 && !sname.is_empty() && seen.insert(format!("c:{sid}")) {
                        cats.push((format!("c:{sid}"), sname));
                    }
                }
            }
        }
    }
    if let Ok(mut guard) = CATS.lock() {
        *guard = Some((cats.clone(), Instant::now() + CAT_TTL));
    }
    Ok(cats)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut cats = Vec::new();
    match load_categories().await {
        Ok(list) => {
            for (id, name) in list {
                cats.push(category_json(&id, &name));
            }
        }
        Err(_) => {
            for (id, name) in [
                ("c:1", "国产"),
                ("c:28", "女优"),
                ("c:37", "电影"),
                ("c:2", "图文"),
                ("c:3", "小说"),
            ] {
                cats.push(category_json(id, name));
            }
        }
    }
    cats.push(category_json("t:0", "★日榜"));
    cats.push(category_json("t:2", "★周榜"));
    cats.push(category_json("t:3", "★月榜"));
    cats.push(category_json("t:l", "★最新"));
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if let Some(t) = category_id.strip_prefix("t:") {
        let path = match t {
            "2" => "/top/top-Week.json",
            "3" => "/top/top-Moon.json",
            "l" => "/latest.json",
            _ => "/top/top.json",
        };
        let data = fetch_json(&format!("{PORTAL}{path}"), "https://portal.instruno.com").await?;
        let items = if let Some(a) = get(&data, "latest").and_then(arr_of) {
            list_from(a)
        } else if let Some(a) = get(&data, "data").and_then(arr_of) {
            list_from(a)
        } else {
            top_list(&data)
        };
        return Ok(json!({"items": items, "has_more": false}));
    }
    let Some(cid) = category_id.strip_prefix("c:") else {
        return Err(ApiError::Internal("四虎分类格式错误".into()));
    };
    let data = fetch_json(
        &format!("{PORTAL}/category/{cid}-{page}.json"),
        "https://portal.instruno.com",
    )
    .await?;
    let items = match get(&data, "data").and_then(arr_of) {
        Some(a) => list_from(a),
        None => Vec::new(),
    };
    let last_page = int_of(&data, &["last_page"]);
    let has_more = if last_page > 0 {
        page < last_page
    } else {
        false
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

fn pick_detail_obj(data: &Value) -> Option<Value> {
    for key in ["video", "view"] {
        if let Some(o) = get(data, key) {
            if o.is_object() && int_of(o, &["id"]) > 0 {
                return Some(o.clone());
            }
        }
    }
    if data.is_object() && int_of(data, &["id"]) > 0 {
        return Some(data.clone());
    }
    None
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let num: String = series_id.chars().filter(|c| c.is_ascii_digit()).collect();
    let num: i64 = num.parse().unwrap_or(0);
    if num <= 0 {
        return Ok(json!({
            "id": series_id, "title": "", "cover": "",
            "synopsis": "", "extra": {}, "episodes": [],
        }));
    }
    let is_video = series_id.starts_with("v:");
    let data = fetch_json(
        &format!("{PORTAL}/video/{num}.json"),
        "https://portal.instruno.com",
    )
    .await?;
    let mut obj = pick_detail_obj(&data);
    if !is_video || obj.is_none() {
        if let Ok(view) = fetch_json(
            &format!("{PORTAL}/view/{num}.json"),
            "https://portal.instruno.com",
        )
        .await
        {
            if let Some(vobj) = pick_detail_obj(&view) {
                obj = Some(vobj);
            }
        }
    }
    let Some(obj) = obj else {
        return Ok(json!({
            "id": series_id, "title": "", "cover": "",
            "synopsis": "", "extra": {}, "episodes": [],
        }));
    };
    let title = text_of(&obj, &["title"]);
    let cover = text_of(&obj, &["titlepic"]);
    let content = plain(&text_of(&obj, &["content"]));
    let category_name = text_of(&obj, &["category_name"]);
    let keyboard = text_of(&obj, &["keyboard"]);
    let synopsis = if content.is_empty() {
        let mut lines = Vec::new();
        if !category_name.is_empty() {
            lines.push(format!("分类：{category_name}"));
        }
        if !keyboard.is_empty() {
            lines.push(format!("标签：{keyboard}"));
        }
        lines.join("\n")
    } else {
        content
    };
    let mut area = String::new();
    if let Some(bc) = get(&obj, "breadcrumb").and_then(arr_of) {
        let names: Vec<String> = bc
            .iter()
            .map(|b| text_of(b, &["title", "name"]))
            .filter(|s| !s.is_empty())
            .collect();
        if !names.is_empty() {
            area = names.join(" / ");
        }
    }
    let kind = kind_of(&obj);
    let remark = if kind == "pic" {
        "图集"
    } else if kind == "book" {
        "小说"
    } else {
        "正片"
    };
    let mut episodes = Vec::new();
    if is_video {
        let m3u8 = text_of(&obj, &["m3u8"]);
        if m3u8.len() > 4 && m3u8.contains(".m3u8") {
            let path = if m3u8.starts_with('/') {
                m3u8.clone()
            } else {
                format!("/{m3u8}")
            };
            for (i, cdn) in CDN.iter().take(3).enumerate() {
                episodes.push(episode_json(
                    &format!("{cdn}{path}"),
                    &format!("正片·四虎M3U8·{}", i + 1),
                    series_id,
                ));
            }
        }
        let mp4 = text_of(&obj, &["mp4"]);
        if mp4.len() > 8 {
            episodes.push(episode_json(&mp4, "正片·四虎MP4", series_id));
        }
    }
    let _ = remark;
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"area": area},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let keyword = encrypt_keyword(query);
    let mut last_err = String::new();
    for host in [SITE, "https://portal.instruno.com"] {
        let url = with_query(
            &format!("{host}/api/v2/search"),
            &[("keyword", &keyword), ("classid", "0"), ("page", "1")],
        );
        match fetch_json(&url, host).await {
            Ok(data) => {
                let items = match get(&data, "data").and_then(arr_of) {
                    Some(a) => list_from(a),
                    None => Vec::new(),
                };
                return Ok(json!({"items": items}));
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!("四虎搜索失败：{last_err}")))
}

/// 取流：分集 video_id 本身就是 m3u8/mp4 直链，直接回。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id.trim();
    if !url.starts_with("http") {
        return Err(ApiError::Internal("四虎未取到有效地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypt_sample_roundtrip() {
        // 加密再解密应还原（与 jar 的 enc/dec 同款参数）。
        let plain = "hello四虎";
        let cipher = encrypt_keyword(plain);
        let raw = base64::engine::general_purpose::STANDARD
            .decode(cipher)
            .unwrap();
        let back = aes_cbc_decrypt(&raw, KEY, IV);
        let unpadded = pkcs7_unpad(&back, 16);
        assert_eq!(String::from_utf8_lossy(unpadded), plain);
    }

    #[test]
    fn one_video_and_pic() {
        let v = json!({"id": 161553, "title": "t", "titlepic": "https://x/cover.txt", "classid": 5, "classname": "淫妻作乐"});
        let item = one(&v).unwrap();
        assert_eq!(item["id"], "v:161553");
        let p = json!({"id": 9, "title": "t", "titlepic": "https://x/c.txt", "classid": 2, "classname": "图文"});
        let item = one(&p).unwrap();
        assert_eq!(item["id"], "m:9");
        assert_eq!(item["remark"], "图集");
    }

    #[test]
    fn top_list_flattens() {
        let data =
            json!({"day": [{"id": 1, "title": "a"}], "week": [{"id": 2, "title": "b"}], "n": 3});
        let items = top_list(&data);
        assert_eq!(items.len(), 2);
    }
}
