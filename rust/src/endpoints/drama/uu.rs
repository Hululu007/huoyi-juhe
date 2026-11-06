//! Uu视频：API 型站，响应信封为 base64 + XOR 加密串。
//!
//! 与 Dart 的 ZakaUuAmns 一一对应。宿主池（jar 的 SEED，经 ZakaSec 解
//! 出并实测）：aad.ubh19fa.com、kua.j7r7ugx.com、765.8ei79s5.com、
//! 3h6.3h62dn.com:51666（第四宿主本机出口连不上，排最后兜底）。
//! 信封 `{"code":200,"data":"<加密串>","key":"<32字符>"}`：data 经
//! URL-safe base64 解码后与 key 字节循环异或，再按 UTF-8 解析 JSON。
//! 指纹登录 POST /api-user/v2/login/fingerprint（body 为 channel 空
//! 串 + 随机 UUID），取 data.accessToken（TTL 约 1860 秒，核心内缓存）。
//! 分类：固定三项（最新 last@0、热门 hot@0、好评 good@0）+ 导航
//! /api/v2/home/public/nav/list 里 type 为 cate/label 且 cate 为空或
//! 含 video_long 的项（type_id 为 type@tid，按 type_id 去重；2026-11-05
//! 实测导航 26 项映射出 21 分类，无萝莉/幼女/未成年相关分类名）。
//! 目录 /api/v2/home/public/video/list（type/page/limit=24，cate/label/
//! collect 时追加 typeId），详情 /api/v2/home/public/video/long/detail，
//! 搜索 /api/v2/home/public/video/search（videoType=long）。
//! 取流：GET /api/v2/home/user/video/play/url?id=（Bearer 令牌），取
//! data.masterUrl（无则 p720Url、p480Url），相对地址拼宿主，`//` 开头
//! 补 `https:`；返回 master 清单地址 + Referer 头（实测：master 清单
//! 200、720p 变体清单 200 含 AES-128 KEY、分片 200 且 Range 206，
//! KEY 与分片均无需头）。
//! 封面：thumb 为相对 .enc 路径，取图地址为 CDN 线路 picUrl +
//! `/encryption-ts` + thumb（/api/v2/home/public/cdn/index 默认线路
//! 实测 200；图片线路 pps.aiide.online 回 403，不用）。注意：图字节
//! 本身是 AES-256-CBC 加密（密钥为 ZakaSec.s(359)，IV 为前 16 字节，
//! 实测解密后为合法 JPEG），须由解密代理出图后才是真封面；本模块先
//! 返回 CDN 原地址（cover_url 单点，注册时改指解密路由即可），
//! CachedNetworkImage 直取会解码失败，见回报。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::engine::{general_purpose::URL_SAFE, Engine};
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query};

/// jar 的 SEED 宿主（ZakaSec.s(355..358)）。
const HOSTS: &[&str] = &[
    "https://aad.ubh19fa.com",
    "https://kua.j7r7ugx.com",
    "https://765.8ei79s5.com",
    "https://3h6.3h62dn.com:51666",
];

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// CDN 默认线路兜底（/cdn/index 默认线路实测值）。
const FALLBACK_PIC: &str = "https://jqsp.xn--xhq15jk0k96h.cn";
const FALLBACK_BUCKET: &str = "encryption-ts";

const PAGE_SIZE: i64 = 24;

static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);
static CDN: Mutex<Option<(String, String, Instant)>> = Mutex::new(None);

/// 解信封：data 经 URL-safe base64 解码后与 key 字节循环异或。
fn unwrap(body: &str) -> ApiResult<Value> {
    let env: Value = serde_json::from_str(body)?;
    let code = int_of(&env, &["code"]);
    if code != 200 {
        let msg = text_of(&env, &["message"]);
        return Err(ApiError::Internal(format!("Uu 接口返回 {code}{}", if msg.is_empty() { String::new() } else { format!("：{msg}") })));
    }
    let data = text_of(&env, &["data"]);
    let key = text_of(&env, &["key"]);
    if data.is_empty() || key.is_empty() {
        return Err(ApiError::Internal("Uu 信封缺少 data/key".into()));
    }
    let raw = {
        let mut std = data.replace('-', "+").replace('_', "/");
        while std.len() % 4 != 0 {
            std.push('=');
        }
        base64::engine::general_purpose::STANDARD
            .decode(std)
            .map_err(|_| ApiError::Internal("Uu 信封 base64 解码失败".into()))?
    };
    let kb = key.as_bytes();
    let plain: Vec<u8> = raw
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ kb[i % kb.len()])
        .collect();
    let text = String::from_utf8(plain).map_err(|_| ApiError::Internal("Uu 信封异或后非 UTF-8".into()))?;
    let value: Value = serde_json::from_str(&text)?;
    Ok(value)
}

/// 随机指纹（UUID 形，与 jar 的 fingerPrint 一致）。
fn fingerprint() -> String {
    let v = rand::random::<u128>();
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        (v >> 96) as u32,
        ((v >> 80) & 0xffff) as u16,
        ((v >> 64) & 0xffff) as u16,
        ((v >> 48) & 0xffff) as u16,
        v & 0xffff_ffff_ffff
    )
}

/// 令牌：缓存到过期前 60 秒，过期或无缓存才重新指纹登录。
async fn token() -> ApiResult<String> {
    if let Ok(guard) = TOKEN.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok(cached.clone());
            }
        }
    }
    let mut last_err = String::new();
    for host in HOSTS {
        let url = format!("{host}/api-user/v2/login/fingerprint");
        let resp = client()?
            .post(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Content-Type", "application/json")
            .json(&json!({"channel": "", "fingerPrint": fingerprint()}))
            .send()
            .await;
        let text = match resp {
            Ok(r) if r.status().as_u16() == 200 => r.text().await.unwrap_or_default(),
            Ok(r) => {
                last_err = format!("HTTP {}", r.status().as_u16());
                continue;
            }
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let body = match unwrap(&text) {
            Ok(b) => b,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        // 登录解包后 accessToken 就在顶层（无 data 嵌套）。
        let access = text_of(&body, &["accessToken"]);
        if access.is_empty() {
            last_err = "登录未返回 accessToken".into();
            continue;
        }
        let ttl = int_of(&body, &["accessTokenTtl"]);
        let ttl = if ttl > 120 { ttl - 60 } else { 1800 };
        if let Ok(mut guard) = TOKEN.lock() {
            *guard = Some((access.clone(), Instant::now() + Duration::from_secs(ttl as u64)));
        }
        return Ok(access);
    }
    Err(ApiError::Internal(format!("Uu 指纹登录失败：{last_err}")))
}

/// 对指定宿主发公开 GET 并解信封。
async fn api_get(host: &str, path: &str, query: &[(&str, &str)]) -> ApiResult<Value> {
    let url = with_query(&format!("{host}{path}"), query);
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Uu 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    unwrap(&text)
}

/// 按宿主顺序试公开接口，首个成功即用。
async fn get_data(path: &str, query: &[(&str, &str)]) -> ApiResult<(Value, String)> {
    let mut last_err = String::new();
    for host in HOSTS {
        match api_get(host, path, query).await {
            Ok(v) => return Ok((v, host.to_string())),
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!("Uu 各宿主均不可用：{last_err}")))
}

/// CDN 取图线路（picUrl + bucket）：缓存 1 小时，失败用默认线路兜底。
async fn cdn_pic() -> (String, String) {
    if let Ok(guard) = CDN.lock() {
        if let Some((pic, bucket, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return (pic.clone(), bucket.clone());
            }
        }
    }
    let mut pic = FALLBACK_PIC.to_string();
    let mut bucket = FALLBACK_BUCKET.to_string();
    if let Ok((body, _)) = get_data("/api/v2/home/public/cdn/index", &[]).await {
        if let Some(rows) = get(&body, "list").and_then(arr_of) {
            let pick = rows
                .iter()
                .find(|r| get(r, "isDefault").is_some_and(|v| v.as_bool().unwrap_or(false)))
                .or_else(|| rows.first());
            if let Some(row) = pick {
                let p = text_of(row, &["picUrl"]);
                let b = text_of(row, &["bucket"]);
                if !p.is_empty() {
                    pic = p;
                }
                if !b.is_empty() {
                    bucket = b;
                }
            }
        }
    }
    if let Ok(mut guard) = CDN.lock() {
        *guard = Some((pic.clone(), bucket.clone(), Instant::now() + Duration::from_secs(3600)));
    }
    (pic, bucket)
}

/// 封面地址：`//` 开头补 `https:`；http 开头直出；相对路径拼 CDN 线路
/// + bucket（jar 的 imgUrl 同款拼接；图字节为 AES 加密，见模块头注）。
fn cover_url(thumb: &str, pic: &str, bucket: &str) -> String {
    let t = thumb.trim();
    if t.is_empty() {
        return String::new();
    }
    if t.starts_with("//") {
        return format!("https:{t}");
    }
    if t.starts_with("http://") || t.starts_with("https://") {
        return t.to_string();
    }
    let base = pic.trim_end_matches('/');
    let path = t.trim_start_matches('/');
    format!("{base}/{bucket}/{path}")
}

/// 导航映射：固定三项 + type 为 cate/label 且 cate 为空或含 video_long
/// 的项，type_id 去重（与 jar 的 homeContent 一致）。
fn categories_from_nav(nav: &Value) -> Vec<Value> {
    let mut out = vec![
        category_json("last@0", "最新"),
        category_json("hot@0", "热门"),
        category_json("good@0", "好评"),
    ];
    let mut seen: HashSet<String> = HashSet::new();
    let rows = match get(nav, "list").and_then(arr_of) {
        Some(rows) => rows,
        None => return out,
    };
    for entry in rows {
        let ty = text_of(entry, &["type"]).to_lowercase().replace(' ', "");
        if ty != "cate" && ty != "label" {
            continue;
        }
        let cate = text_of(entry, &["cate"]);
        if !cate.is_empty() && !cate.contains("video_long") {
            continue;
        }
        let tid = text_of(entry, &["tid"]);
        if tid.is_empty() {
            continue;
        }
        let id = format!("{ty}@{tid}");
        if !seen.insert(id.clone()) {
            continue;
        }
        let name = text_of(entry, &["title"]);
        if name.is_empty() {
            continue;
        }
        out.push(category_json(&id, &name));
    }
    out
}

/// 目录查询：cate/label/collect 时追加 typeId（与 jar 一致）。
fn list_query(kind: &str, tid: &str, page: i64) -> Vec<(String, String)> {
    let page = page.to_string();
    let mut q = vec![
        ("type".to_string(), kind.to_string()),
        ("page".to_string(), page),
        ("limit".to_string(), PAGE_SIZE.to_string()),
    ];
    if matches!(kind, "cate" | "label" | "collect") && !tid.is_empty() {
        q.push(("typeId".to_string(), tid.to_string()));
    }
    q
}

/// 拆 `type@tid`。
fn split_category(category_id: &str) -> (String, String) {
    match category_id.split_once('@') {
        Some((a, b)) => (a.to_string(), b.to_string()),
        None => (category_id.to_string(), String::new()),
    }
}

/// 目录行转视频卡片（id/title/thumb/createdAt 前 10 位为备注）。
fn catalog_items(rows: &[Value], pic: &str, bucket: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for entry in rows {
        let id = text_of(entry, &["id"]);
        if id.is_empty() {
            continue;
        }
        let title = text_of(entry, &["title"]);
        if title.is_empty() {
            continue;
        }
        let thumb = text_of(entry, &["thumb"]);
        let cover = cover_url(&thumb, pic, bucket);
        let created = text_of(entry, &["createdAt"]);
        let remark = created.chars().take(10).collect::<String>();
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 去 HTML 标签后取纯文本（详情简介用）。
fn strip_tags(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_tag = false;
    for c in raw.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 取流地址归一：`//` 开头补 `https:`，相对地址拼宿主。
fn normalize_play_url(raw: &str, host: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("//") {
        return format!("https:{u}");
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    format!("{}{}", host.trim_end_matches('/'), u)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_data("/api/v2/home/public/nav/list", &[("channel", "")]).await {
        Ok((nav, _)) => Ok(json!({"categories": categories_from_nav(&nav)})),
        Err(_) => Ok(json!({"categories": [
            category_json("last@0", "最新"),
            category_json("hot@0", "热门"),
            category_json("good@0", "好评"),
        ]})),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (kind, tid) = split_category(category_id.trim());
    let kind = if kind.is_empty() { "last".to_string() } else { kind };
    let page = if page < 1 { 1 } else { page };
    let query = list_query(&kind, &tid, page);
    let qref: Vec<(&str, &str)> = query.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let (body, _host) = get_data("/api/v2/home/public/video/list", &qref).await?;
    let total = int_of(&body, &["total"]);
    let rows = get(&body, "list").and_then(arr_of).cloned().unwrap_or_default();
    let (pic, bucket) = cdn_pic().await;
    let items = catalog_items(&rows, &pic, &bucket);
    let shown = (page - 1) * PAGE_SIZE + items.len() as i64;
    let has_more = total > 0 && shown < total;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    if sid.is_empty() {
        return Err(ApiError::Internal("Uu 缺少影片 id".into()));
    }
    let (body, _host) = get_data(
        "/api/v2/home/public/video/long/detail",
        &[("id", sid)],
    )
    .await?;
    let title = text_of(&body, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("Uu 未返回影片标题".into()));
    }
    let (pic, bucket) = cdn_pic().await;
    let thumb = text_of(&body, &["thumb"]);
    let cover = cover_url(&thumb, &pic, &bucket);
    let content = strip_tags(&text_of(&body, &["content"]));
    let mut synopsis = String::new();
    if !content.is_empty() {
        synopsis.push_str(&content);
        synopsis.push('\n');
    }
    let classify = text_of(&body, &["classifyTitles"]);
    let labels = text_of(&body, &["labelTitles"]);
    let mut tags: Vec<&str> = Vec::new();
    if !classify.is_empty() {
        tags.push(&classify);
    }
    if !labels.is_empty() {
        tags.push(&labels);
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("分类: {}\n", tags.join("，")));
    }
    let created = text_of(&body, &["createdAt"]);
    if !created.is_empty() {
        synopsis.push_str(&format!("发布: {created}\n"));
    }
    synopsis.push_str("来源: Uu视频");
    Ok(json!({
        "id": sid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim().to_string(),
        "extra": {},
        "episodes": [episode_json(sid, "正片", sid)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = query.trim();
    if q.is_empty() {
        return Ok(json!({"items": []}));
    }
    let (body, _host) = get_data(
        "/api/v2/home/public/video/search",
        &[
            ("page", "1"),
            ("limit", "24"),
            ("keyword", q),
            ("videoType", "long"),
        ],
    )
    .await?;
    let rows = get(&body, "list").and_then(arr_of).cloned().unwrap_or_default();
    let (pic, bucket) = cdn_pic().await;
    let items = catalog_items(&rows, &pic, &bucket);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid, "header": {"User-Agent": UA}}));
    }
    if vid.is_empty() {
        return Err(ApiError::Internal("Uu 该集没有播放地址".into()));
    }
    let access = token().await?;
    let mut last_err = String::new();
    for host in HOSTS {
        let url = with_query(
            &format!("{host}/api/v2/home/user/video/play/url"),
            &[("id", vid)],
        );
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Authorization", format!("Bearer {access}"))
            .send()
            .await;
        let text = match resp {
            Ok(r) if r.status().as_u16() == 200 => r.text().await.unwrap_or_default(),
            Ok(r) => {
                last_err = format!("HTTP {}", r.status().as_u16());
                continue;
            }
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let body = match unwrap(&text) {
            Ok(b) => b,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        // 取流解包后 masterUrl 就在顶层（无 data 嵌套）。
        let raw = text_of(&body, &["masterUrl", "p720Url", "p480Url"]);
        if raw.is_empty() {
            last_err = "取流未返回播放地址".into();
            continue;
        }
        let url = normalize_play_url(&raw, host);
        return Ok(json!({
            "url": url,
            "header": {"User-Agent": UA, "Referer": format!("{host}/")},
        }));
    }
    Err(ApiError::Internal(format!("Uu 取流失败：{last_err}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 按 jar 的 unwrap 算法打包信封（测试夹具用）。
    fn wrap(payload: &str, key: &str) -> String {
        let kb = key.as_bytes();
        let enc: Vec<u8> = payload
            .as_bytes()
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ kb[i % kb.len()])
            .collect();
        let b64 = URL_SAFE.encode(enc);
        json!({"code": 200, "message": "OK", "data": b64, "key": key}).to_string()
    }

    #[test]
    fn unwrap_roundtrip() {
        let payload = r#"{"list":[{"title":"黑料","cate":"video_long","type":"cate","tid":347}]}"#;
        let body = wrap(payload, "PcceJE0KmtmjfuDOJ9BHkPwl0FD53PIi");
        let v = unwrap(&body).unwrap();
        assert_eq!(v["list"][0]["title"], "黑料");
        assert_eq!(v["list"][0]["tid"], 347);
    }

    #[test]
    fn unwrap_rejects_bad_code() {
        let body = r#"{"code":401,"message":"未登录","data":"","key":"x"}"#;
        assert!(unwrap(body).is_err());
    }

    #[test]
    fn categories_from_nav_filters() {
        let nav: Value = serde_json::from_str(
            r#"{"list":[
                {"title":"首页","cate":"video_long","type":"home","tid":0},
                {"title":"热门","cate":"video_long","type":"hot","tid":0},
                {"title":"黑料","cate":"video_long","type":"cate","tid":347},
                {"title":"传媒","cate":"video_long","type":"cate","tid":266},
                {"title":"日本","cate":"video_long","type":"cate","tid":263},
                {"title":"日本AV","cate":"video_long","type":"cate","tid":263},
                {"title":"小说漫画","cate":"novel_cartoon","type":"cate","tid":900},
                {"title":"短视频","cate":"video_short","type":"cate","tid":901},
                {"title":"ai短剧","cate":"video_long","type":"series","tid":902},
                {"title":"探花","cate":"","type":"label","tid":143},
                {"title":"探花","cate":"","type":"label","tid":143}
            ]}"#,
        )
        .unwrap();
        let list = categories_from_nav(&nav);
        assert_eq!(list.len(), 3 + 4);
        assert_eq!(list[0]["id"], "last@0");
        assert_eq!(list[3]["id"], "cate@347");
        assert_eq!(list[4]["id"], "cate@266");
        assert_eq!(list[5]["id"], "cate@263");
        assert_eq!(list[5]["name"], "日本");
        assert_eq!(list[6]["id"], "label@143");
        assert_eq!(list[6]["name"], "探花");
    }

    #[test]
    fn list_query_appends_type_id_only_for_typed() {
        let q = list_query("cate", "347", 2);
        assert!(q.iter().any(|(k, v)| k == "typeId" && v == "347"));
        assert!(q.iter().any(|(k, v)| k == "page" && v == "2"));
        let q2 = list_query("last", "0", 1);
        assert!(!q2.iter().any(|(k, _)| k == "typeId"));
    }

    #[test]
    fn split_category_shapes() {
        assert_eq!(split_category("cate@347"), ("cate".to_string(), "347".to_string()));
        assert_eq!(split_category("last@0"), ("last".to_string(), "0".to_string()));
        assert_eq!(split_category(""), (String::new(), String::new()));
    }

    #[test]
    fn catalog_item_mapping() {
        let rows: Vec<Value> = serde_json::from_str(
            r#"[{"id":124664,"createdAt":"2026-11-05 16:08:10","title":"抖音纯欲系女网红 周梓萌 最新福利合集流出","classifyTitles":"网曝黑料,吃瓜","labelTitles":"黑料","thumb":"/uploads/file/20261105/e2c75c99651e41e18d9a8c57b09be0a7_compress.jpg.enc"},{"id":"","title":"无id跳过","thumb":"/x.jpg.enc"},{"id":124663,"title":"","thumb":"/x.jpg.enc"}]"#,
        )
        .unwrap();
        let items = catalog_items(&rows, "https://jqsp.xn--xhq15jk0k96h.cn", "encryption-ts");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "124664");
        assert_eq!(items[0]["title"], "抖音纯欲系女网红 周梓萌 最新福利合集流出");
        assert_eq!(
            items[0]["cover"],
            "https://jqsp.xn--xhq15jk0k96h.cn/encryption-ts/uploads/file/20261105/e2c75c99651e41e18d9a8c57b09be0a7_compress.jpg.enc"
        );
        assert_eq!(items[0]["remark"], "2026-11-05");
    }

    #[test]
    fn cover_url_shapes() {
        let pic = "https://jqsp.xn--xhq15jk0k96h.cn";
        assert_eq!(
            cover_url("//cdn.example.com/a.jpg.enc", pic, "encryption-ts"),
            "https://cdn.example.com/a.jpg.enc"
        );
        assert_eq!(
            cover_url("https://cdn.example.com/a.jpg.enc", pic, "encryption-ts"),
            "https://cdn.example.com/a.jpg.enc"
        );
        assert_eq!(
            cover_url("/uploads/x.jpg.enc", pic, "encryption-ts"),
            "https://jqsp.xn--xhq15jk0k96h.cn/encryption-ts/uploads/x.jpg.enc"
        );
        assert_eq!(cover_url("", pic, "encryption-ts"), "");
    }

    #[test]
    fn normalize_play_url_shapes() {
        let host = "https://aad.ubh19fa.com";
        assert_eq!(
            normalize_play_url("//cdn.example.com/x.m3u8", host),
            "https://cdn.example.com/x.m3u8"
        );
        assert_eq!(
            normalize_play_url("/api/v2/x.m3u8?cdnId=0", host),
            "https://aad.ubh19fa.com/api/v2/x.m3u8?cdnId=0"
        );
        assert_eq!(
            normalize_play_url("https://cdn.example.com/x.m3u8", host),
            "https://cdn.example.com/x.m3u8"
        );
        assert_eq!(normalize_play_url("", host), "");
    }

    #[test]
    fn strip_tags_plain() {
        assert_eq!(
            strip_tags("<p>你好<b>世界</b></p><img src=\"/x.jpg\">尾"),
            "你好 世界 尾"
        );
        assert_eq!(strip_tags("纯文本"), "纯文本");
    }

    #[test]
    fn login_and_play_bodies_are_top_level() {
        // 解包后的登录/取流体：accessToken 与 masterUrl 都在顶层，无 data 嵌套。
        let login: Value =
            serde_json::from_str(r#"{"accessToken":"tok","accessTokenTtl":1860}"#).unwrap();
        assert_eq!(text_of(&login, &["accessToken"]), "tok");
        assert_eq!(int_of(&login, &["accessTokenTtl"]), 1860);
        let play: Value =
            serde_json::from_str(r#"{"masterUrl":"/api/x.m3u8","p720Url":"/api/y.m3u8"}"#).unwrap();
        assert_eq!(text_of(&play, &["masterUrl", "p720Url"]), "/api/x.m3u8");
    }

    #[test]
    fn fingerprint_shape() {
        let f = fingerprint();
        assert_eq!(f.len(), 36);
        assert_eq!(f.matches('-').count(), 4);
    }
}

