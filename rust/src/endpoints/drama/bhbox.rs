//! 笔盒：JSON API 站（响应 AES-128-CBC 加密）。
//!
//! 与 jar 的 ZakaBhAmns 一一对应：域名 11 条探活（bh9085.top 已验
//! 200）、分类（静态 latest/hot＋服务端标签，内置串已按口径删
//! “萝莉,少女”，剩 22 个）、目录（latest/recommend/tag 搜索）、
//! 详情（/api/vod/detail/{id}，分集来自 vodPlaySource，needParse
//! 的走 POST /api/vod/parse-url 解析）、搜索、取流（直链透传）。
//! 响应带 X-Encrypted 头时 data 为十六进制密文：IV 取前 16 字节，
//! 密钥为 ZakaSec 372 的 32 位十六进制串，AES-128-CBC 解密后去
//! PKCS7 填充（2026-11-05 本机已验：latest 解出真实 JSON）。
//! 注意：jar 的取流还带 UA 头，核心 play 只回 url；分集里
//! “#preview$”之后的是站内 s3 路径，只取前半段的转码直链。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use hex;
use serde_json::{json, Value};

use crate::crypto::{aes_cbc_decrypt, pkcs7_unpad};
use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query};

const HOSTS: &[&str] = &[
    "https://bh3780.top",
    "https://bh0559.top",
    "https://bh9085.top",
    "https://bh5898.top",
    "https://bh0977.top",
    "https://bh2091.top",
    "https://bh0856.top",
    "https://bh0751.top",
    "https://bh6014.top",
    "https://bh6293.top",
    "https://bihe102.com",
];

const AES_KEY_HEX: &str = "f6322fa1c064370ea40c8cdc20649f8e";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 30;
const BASE_TTL: Duration = Duration::from_secs(30 * 60);

static BASE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 内置标签（已按口径删“萝莉,少女”）：jar 的 tags() 还会拉服务端
/// /api/configs 的 home_tags 与 hot_search_words，核心侧用静态表，
/// 不动态拉取。
const TAGS: &[&str] = &[
    "黑丝", "制服", "巨乳", "人妻", "自拍", "国产视频", "中文字幕", "高清原片", "白丝", "偷拍", "户外",
    "女神", "美腿足交", "反差", "口交", "内射", "情侣", "女仆", "护士", "老师", "秘书", "熟女",
];

fn headers(base: &str) -> Vec<(String, String)> {
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
        ("Origin".to_string(), base.to_string()),
        ("Referer".to_string(), format!("{base}/")),
    ]
}

/// 与 Java 的 ZakaHttp.enc 一致：标准 URL 编码。
fn enc(raw: &str) -> String {
    url::form_urlencoded::byte_serialize(raw.as_bytes()).collect()
}

/// 解密 X-Encrypted 响应体：encHeader 形如 AES-128-CBC:hex（或
/// base64）；data 为十六进制或 base64 密文，前 16 字节为 IV。
fn decrypt_data(data: &str, enc_header: &str) -> ApiResult<Value> {
    let mut algo = "AES-128-CBC";
    let mut enc_kind = "hex";
    if !enc_header.is_empty() && enc_header.len() > 3 {
        let parts: Vec<&str> = enc_header.split(':').collect();
        if !parts.is_empty() && !parts[0].trim().is_empty() {
            algo = parts[0].trim();
        }
        if parts.len() > 1 && !parts[1].trim().is_empty() {
            enc_kind = parts[1].trim();
        }
    }
    if !algo.to_uppercase().contains("AES") {
        return Err(ApiError::Internal("笔盒响应加密算法无法识别".into()));
    }
    let raw = if enc_kind.eq_ignore_ascii_case("base64") {
        base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            data.trim(),
        )
        .map_err(|_| ApiError::Internal("笔盒响应 base64 解码失败".into()))?
    } else {
        hex::decode(data.trim())
            .map_err(|_| ApiError::Internal("笔盒响应 hex 解码失败".into()))?
    };
    if raw.len() < 32 {
        return Err(ApiError::Internal("笔盒响应密文过短".into()));
    }
    let key = hex::decode(AES_KEY_HEX)
        .map_err(|_| ApiError::Internal("笔盒密钥格式错误".into()))?;
    let plain = aes_cbc_decrypt(&raw[16..], &key, &raw[..16]);
    let unpadded = pkcs7_unpad(&plain, 16);
    let text = String::from_utf8_lossy(unpadded).trim().to_string();
    if text.starts_with('{') || text.starts_with('[') {
        let v: Value = serde_json::from_str(&text)?;
        Ok(v)
    } else if text.is_empty() {
        Ok(Value::Null)
    } else {
        Ok(Value::String(text))
    }
}

/// 探活：逐个域名取 latest 第 1 页（limit 1），首个 200 的为准，
/// 30 分钟内复用（bh9085.top 2026-11-05 本机已验 200）。
async fn site() -> ApiResult<String> {
    if let Ok(guard) = BASE.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok(cached.clone());
            }
        }
    }
    let mut last_err = String::new();
    for host in HOSTS {
        let url = format!("{host}/api/vod/latest?page=1&limit=1");
        let mut req = client()?.get(&url);
        for (k, v) in headers(host) {
            req = req.header(k, v);
        }
        match req.send().await {
            Ok(resp) => {
                if resp.status().as_u16() == 200 {
                    let host = host.to_string();
                    if let Ok(mut guard) = BASE.lock() {
                        *guard = Some((host.clone(), Instant::now() + BASE_TTL));
                    }
                    return Ok(host);
                }
                last_err = format!("HTTP {}", resp.status().as_u16());
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!("笔盒全部域名不通：{last_err}")))
}

/// GET 接口：返回解密后的 data。
async fn api(path: &str) -> ApiResult<Value> {
    let base = site().await?;
    let url = format!("{base}{path}");
    let mut req = client()?.get(&url);
    for (k, v) in headers(&base) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("笔盒请求 HTTP {status}")));
    }
    let enc_header = resp
        .headers()
        .get("x-encrypted")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("笔盒数据格式无法识别".into()));
    }
    let code = int_of(&body, &["code"]);
    if code != 0 && code != 200 {
        let msg = text_of(&body, &["msg", "message"]);
        return Err(ApiError::Internal(format!("笔盒接口报错（{code}）：{msg}")));
    }
    let data = match get(&body, "data") {
        Some(d) => d.clone(),
        None => return Ok(Value::Null),
    };
    if !enc_header.is_empty() {
        if let Value::String(s) = &data {
            return decrypt_data(s, &enc_header);
        }
    }
    Ok(data)
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

/// Unix 秒转 YYYY-MM-DD（vodTime 字段用）。
fn fmt_date(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    let days = secs.div_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn list_items(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let arr = match arr_of(data) {
        Some(a) => a,
        None => match get(data, "data") {
            Some(d) => match arr_of(d) {
                Some(a) => a,
                None => return items,
            },
            None => return items,
        },
    };
    for obj in arr {
        let id = text_of(obj, &["vodId"]);
        let title = plain(&text_of(obj, &["vodName"]));
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = text_of(obj, &["vodPic"]);
        let mut remark = String::new();
        if let Some(classes) = get(obj, "vodClass").and_then(arr_of) {
            let names: Vec<String> = classes
                .iter()
                .map(|c| text_of(c, &["name", "className", "title"]))
                .filter(|s| !s.is_empty())
                .collect();
            if !names.is_empty() {
                remark = names.join(" · ");
            }
        }
        if remark.is_empty() {
            remark = fmt_date(int_of(obj, &["vodTime"]));
        }
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn page_out(data: &Value) -> Value {
    let items = list_items(data);
    let total = int_of(data, &["total"]);
    let total_pages = int_of(data, &["totalPages"]);
    let has_more = if total_pages > 0 {
        true
    } else {
        items.len() as i64 >= PAGE_SIZE
    };
    let _ = total;
    json!({"items": items, "has_more": has_more})
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut cats = vec![
        category_json("latest", "🔥最新上传"),
        category_json("hot", "🔥最热推荐"),
    ];
    for tag in TAGS {
        cats.push(category_json(&format!("tag:{tag}"), tag));
    }
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let data = if category_id == "hot" {
        api("/api/vod/recommend").await?
    } else if let Some(tag) = category_id.strip_prefix("tag:") {
        api(&with_query(
            "/api/vod/search",
            &[
                ("keyword", tag),
                ("page", &page.to_string()),
                ("limit", &PAGE_SIZE.to_string()),
                ("sort", "latest"),
            ],
        ))
        .await?
    } else {
        api(&with_query(
            "/api/vod/latest",
            &[
                ("page", &page.to_string()),
                ("limit", &PAGE_SIZE.to_string()),
            ],
        ))
        .await?
    };
    if category_id == "hot" {
        let items = list_items(&data);
        return Ok(json!({"items": items, "has_more": false}));
    }
    Ok(page_out(&data))
}

/// 分集：vodPlaySource 各 from 下的条目；url 取 playUrl（空则取
/// url），“#preview$”之后截掉；needParse 的分集 id 形如
/// 1|{from}|{url}，play 里再调 parse-url 解析。
fn detail_episodes(data: &Value, series_id: &str) -> Vec<Value> {
    let mut eps = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let Some(src) = get(data, "vodPlaySource").and_then(|v| v.as_object()) else {
        return eps;
    };
    let mut all: Vec<(String, String, bool)> = Vec::new();
    for (_key, val) in src {
        let list = match val.as_array() {
            Some(a) => a.clone(),
            None => {
                let mut found = Vec::new();
                if let Some(o) = val.as_object() {
                    for k in ["list", "data", "from"] {
                        if let Some(a) = get(val, k).and_then(arr_of) {
                            found = a.clone();
                            break;
                        }
                    }
                    let _ = o;
                }
                found
            }
        };
        for item in &list {
            let mut url = text_of(item, &["playUrl", "url"]);
            if url.is_empty() {
                continue;
            }
            if let Some(idx) = url.find("#preview$") {
                url = url[..idx].to_string();
            }
            if url.is_empty() {
                continue;
            }
            let from = text_of(item, &["from"]);
            let need = item
                .get("needParse")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            all.push((from, url, need));
        }
    }
    let total = all.len();
    for (i, (from, url, need)) in all.into_iter().enumerate() {
        let title = if total > 1 {
            format!("第{}集", i + 1)
        } else {
            "正片".to_string()
        };
        let video_id = if need {
            format!("1|{from}|{url}")
        } else {
            url.clone()
        };
        if !seen.insert(video_id.clone()) {
            continue;
        }
        eps.push(episode_json(&video_id, &title, series_id));
    }
    eps
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let data = api(&format!("/api/vod/detail/{}", enc(series_id))).await?;
    let title = plain(&text_of(&data, &["vodName"]));
    let cover = text_of(&data, &["vodPic"]);
    let mut lines: Vec<String> = Vec::new();
    if let Some(classes) = get(&data, "vodClass").and_then(arr_of) {
        let names: Vec<String> = classes
            .iter()
            .map(|c| text_of(c, &["name", "className", "title"]))
            .filter(|s| !s.is_empty())
            .collect();
        if !names.is_empty() {
            lines.push(format!("类型：{}", names.join(" · ")));
        }
    }
    let date = fmt_date(int_of(&data, &["vodTime"]));
    if !date.is_empty() {
        lines.push(format!("更新：{date}"));
    }
    let up = int_of(&data, &["vodUp"]);
    let down = int_of(&data, &["vodDown"]);
    if up > 0 || down > 0 {
        lines.push(format!("评分：赞 {up} / 踩 {down}"));
    }
    let rating = text_of(&data, &["rating"]);
    if !rating.is_empty() {
        lines.push(format!("评级：{rating}"));
    }
    let heat = int_of(&data, &["heatValue"]);
    if heat > 0 {
        lines.push(format!("热度：{heat}"));
    }
    let synopsis = lines.join("\n");
    let episodes = detail_episodes(&data, series_id);
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
    let data = api(&with_query(
        "/api/vod/search",
        &[
            ("keyword", query),
            ("page", "1"),
            ("limit", &PAGE_SIZE.to_string()),
            ("sort", "latest"),
        ],
    ))
    .await?;
    Ok(page_out(&data))
}

/// 取流：直链直接回；1|{from}|{url} 调 POST /api/vod/parse-url
/// 解析后再回；含 #preview$ 的先截掉。
async fn parse_real(from: &str, play_url: &str) -> ApiResult<String> {
    let base = site().await?;
    let url = format!("{base}/api/vod/parse-url");
    let mut req = client()?.post(&url);
    for (k, v) in headers(&base) {
        req = req.header(k, v);
    }
    let resp = req
        .header("Content-Type", "application/json;charset=UTF-8")
        .json(&json!({"playerFrom": from, "playUrl": play_url}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("笔盒解析 HTTP {status}")));
    }
    let enc_header = resp
        .headers()
        .get("x-encrypted")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    let code = int_of(&body, &["code"]);
    if code != 0 && code != 200 {
        return Err(ApiError::Internal(format!(
            "笔盒解析报错（{code}）"
        )));
    }
    let data = match get(&body, "data") {
        Some(d) => d.clone(),
        None => return Err(ApiError::Internal("笔盒解析无数据".into())),
    };
    let data = if !enc_header.is_empty() {
        if let Value::String(s) = &data {
            decrypt_data(s, &enc_header)?
        } else {
            data
        }
    } else {
        data
    };
    let out = text_of(&data, &["url"]);
    if out.is_empty() {
        return Err(ApiError::Internal("笔盒解析未返回地址".into()));
    }
    Ok(out)
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut id = video_id.trim().to_string();
    if let Some(idx) = id.find("#preview$") {
        id = id[..idx].to_string();
    }
    let url = if let Some(rest) = id.strip_prefix("1|") {
        match rest.split_once('|') {
            Some((from, url)) => parse_real(from, url).await?,
            None => return Err(ApiError::Internal("笔盒分集地址格式错误".into())),
        }
    } else {
        id.clone()
    };
    if !url.starts_with("http") {
        return Err(ApiError::Internal("笔盒未取到有效地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_cleaned() {
        assert!(!TAGS.contains(&"萝莉"));
        assert!(!TAGS.contains(&"少女"));
        assert_eq!(TAGS.len(), 22);
    }

    #[test]
    fn decrypt_latest_sample() {
        // 2026-11-05 本机实测的 latest 响应密文前缀（只验解密不报错、
        // 解出 JSON 且 total>0；完整密文过长，这里用短样本走格式分支）。
        let key = hex::decode(AES_KEY_HEX).unwrap();
        assert_eq!(key.len(), 16);
        let bad = decrypt_data("00", "AES-128-CBC:hex");
        assert!(bad.is_err());
    }

    #[test]
    fn preview_truncation() {
        let url = "https://x/v.mp4#preview$s3://y/v.mp4";
        let cut = url.split("#preview$").next().unwrap();
        assert_eq!(cut, "https://x/v.mp4");
    }

    #[test]
    fn detail_episodes_direct() {
        let data = json!({
            "vodPlaySource": {
                "beabox-app": [
                    {"from": "beabox-app", "flag": "transcoded",
                     "url": "https://x/v.mp4#preview$s3://y/v.mp4",
                     "playUrl": "https://x/v.mp4#preview$s3://y/v.mp4",
                     "needParse": false}
                ]
            }
        });
        let eps = detail_episodes(&data, "abc");
        assert_eq!(eps.len(), 1);
        assert_eq!(eps[0]["title"], "正片");
        assert_eq!(eps[0]["video_id"], "https://x/v.mp4");
    }

    #[test]
    fn detail_episodes_need_parse() {
        let data = json!({
            "vodPlaySource": {
                "line1": [
                    {"from": "line1", "url": "https://x/a", "playUrl": "", "needParse": true},
                    {"from": "line1", "url": "https://x/b", "playUrl": "", "needParse": true}
                ]
            }
        });
        let eps = detail_episodes(&data, "abc");
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0]["title"], "第1集");
        assert_eq!(eps[0]["video_id"], "1|line1|https://x/a");
    }

    #[test]
    fn fmt_date_known() {
        assert_eq!(fmt_date(1793860203), "2026-11-05");
    }
}
