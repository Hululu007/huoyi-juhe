//! Utube：`https://bak.vkxrpigoi.cc`。
//!
//! 来源 jar 类 `ZakaUtubeAmns`。基址 `https://bak.vkxrpigoi.cc`，
//! `ORIGIN=https://p2.ihkzdjg.xyz`，UA 为 Chrome 120 Android SM-A205GN；
//! `SECRET=cb7c22174dc30d664784e6d322fd664d`；
//! `AES_KEY=b26243c9efcd5514`、`AES_IV=66fe2be26e8b65b9`（各 16 字节）；
//! `OAUTH_POOL` 为 12 个 32 hex 字符串（随机取一个作 `oauth_id`，自 jar
//! 原文逐字抄录）。
//!
//! `call(path, params)`：JSON 体固定字段 `oauth_id`（随机池）、
//! `bundleId=com.pwa.wyll`、`version=1.6.0`、`oauth_type=web`、
//! `language=zh`、`via=pwa`、`_hash=<当前毫秒>`，再并入业务参数；PKCS7
//! 填充后 AES/CBC/NoPadding 加密，Base64；
//! `sign = MD5 小写 hex(SHA-256 小写 hex("client=pwa&data=<Base64>&timestamp=<秒>" + SECRET))`；
//! POST body 为 `client=pwa&timestamp=<秒>&data=<URLEncoder 编码的
//! Base64>&sign=<hex>`，头 `Content-Type:
//! application/x-www-form-urlencoded`、`Origin:
//! https://p2.ihkzdjg.xyz`、`Referer: https://p2.ihkzdjg.xyz/`、UA，
//! 30 秒超时；成功即停、失败睡 1 秒最多 3 次（dex 字节码证实成功后有
//! `goto` 跳出循环，jadx 丢了该 break）；响应 JSON 的 `data` 字段非空
//! 时 Base64 解码后 AES/CBC 解密去 PKCS7，明文以 `{` 开头作对象、以
//! `[` 开头包成 `{"data": […]}`，否则返回原 JSON。
//!
//! 分类写死 11 类，按用户口径删 `construct:75` “制服萝莉”，余 10 类：
//! `rec` 推荐、`discover2` 发现、`construct:1` YouTube精选、
//! `construct:73` 伦理道德、`construct:2` 品牌传媒、`construct:238`
//! 官方原创、`melon` 黑料吃瓜、`live` 直播、`vlog` 短视频、`popular` 热门。
//! `listFor`：`rec` → `/api.php/api/index/index`（`id=1`，`page`，
//! `limit=16`），取 `data.list[].items[]`（作 `video`）+
//! `materials[]`（作 `melon`），空时回退 `data.list[]` 作 `video`；
//! `discover2` → `/api.php/api/mv/discover2`（`sort=see`）；
//! `construct:<id>` → `/api.php/api/mv/list_construct`（`sort=see`）；
//! `melon` → `/api.php/api/material/list_sort`（`sort=new`，`id=1`，取
//! `materials`）；`live` → `/api.php/api/live/index`（取 `lives`）；
//! `vlog` → `/api.php/api/vlog/list_sort`（`sort=rec`，`data` 数组或
//! `data.list`）；`popular` → `/api.php/api/mv/discover`
//! （`sort=popular`）。
//!
//! 卡片：`vod_id=<类型>:<id>`（类型 video/melon/live/vlog）；标题取
//! `title` → `username` → `name`；付费判定 `is_pay == 1` 或
//! （`coins > 0` 且 `isfree == 2`），视频类付费先排除、全空时才放回；
//! 封面取 `cover_horizontal` → `cover_vertical` → `cover`，含
//! `drleao.cn` 才包 `lxsimg` 中继；备注为 `付费` 或时长 `M:SS`；内容为
//! `tags` 或 `tag_list`（逗号连）或 `theme`。
//! 详情：`live:<id>` 调 `/api.php/api/live/detail` 取 `data.live.username`
//! 与封面，`vod_play_url=正片$live:<id>`；`melon:<id>` 调
//! `/api.php/api/material/detail` 取 `data.detail.title`/`txt`（空则
//! `content`），`vod_play_url` 为空（无视频）；视频类调
//! `/api.php/api/mv/getDetail` 取 `data.detail`（空则取 `data` 本身），
//! 付费则 `vod_play_url` 为空，否则 `正片$<playUrl>`。
//! `playUrl(obj)` 优先级：`m3u8` → `mv.m3u8` → `mv_m3u8` →
//! `preview_url` → `preview_sources.url_264` → `url_265` →
//! `video_sources.url_264` → `url_265` → `source_720` → `source_480`
//! → `source_240`；最后把 `hf-[^.]+.` 替换为 `hf-long.`。
//! 搜索：`call("/api.php/api/mv/search", {word, type: 1, page, limit:
//! 16})`，`data` 数组或 `data.list`，按 `video` 展平。
//! 取流：video_id 以 `http` 开头直通；`live:<id>` 调 live detail 取
//! `hls[0].url`；否则取 id 冒号后部分调 `getDetail`，非付费时用
//! `playUrl`；头为 UA + Referer `https://p2.ihkzdjg.xyz/`。
//!
//! 注意：jar 的 `pageObj` 置 `pagecount = 当前页`（永不宣告下一页）；
//! 本模块按“满页（16 条）即有下一页”算 `has_more`，否则分类翻页
//! 无法进行，属修复。

use std::sync::Mutex;

use base64::Engine as _;
use md5::Digest as _;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use sha2::Sha256;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://bak.vkxrpigoi.cc";
const ORIGIN: &str = "https://p2.ihkzdjg.xyz";
const SECRET: &str = "cb7c22174dc30d664784e6d322fd664d";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; SM-A205GN) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36";
const AES_KEY: &[u8] = b"b26243c9efcd5514";
const AES_IV: &[u8] = b"66fe2be26e8b65b9";

const OAUTH_POOL: &[&str] = &[
    "86e4fe877f2341155fdd5de6388c38b1",
    "06ad03456940117f22575181682e0936",
    "e5d0e0510d1f8a6f409870f7ab2b1fa7",
    "5e114a9be00839cdcd9d082bb31ae5f7",
    "4801676163e6a4d3739d956dfcc11119",
    "8952cc0d6e239dac4f04879420f12f39",
    "22ed40c3ea737788b7b505704021c0a1",
    "14831ee00e290183e724664375d92d50",
    "9dc7f5360a5d59aef3b961522c51a5b5",
    "21d80c585c5caaf4ff29cd2cc1ef2c3b",
    "9405a0e887560552a91b9599bfeb44f7",
    "53fbc5be0ee27d28d0901ea97a7c2055",
];

/// 分类：jar 原文 11 类，删 `construct:75` “制服萝莉”，余 10 类。
const CATS: &[(&str, &str)] = &[
    ("rec", "推荐"),
    ("discover2", "发现"),
    ("construct:1", "YouTube精选"),
    ("construct:73", "伦理道德"),
    ("construct:2", "品牌传媒"),
    ("construct:238", "官方原创"),
    ("melon", "黑料吃瓜"),
    ("live", "直播"),
    ("vlog", "短视频"),
    ("popular", "热门"),
];

static CACHE: Lazy<Mutex<std::collections::HashMap<String, Value>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn md5_hex(data: &[u8]) -> String {
    let mut h = md5::Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

fn urlenc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

async fn call(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let oauth = OAUTH_POOL[rand::random::<usize>() % OAUTH_POOL.len()];
    let mut body = json!({
        "oauth_id": oauth,
        "bundleId": "com.pwa.wyll",
        "version": "1.6.0",
        "oauth_type": "web",
        "language": "zh",
        "via": "pwa",
        "_hash": now_ms().to_string(),
    });
    if let Some(o) = body.as_object_mut() {
        for (k, v) in params {
            o.insert(k.to_string(), json!(v));
        }
    }
    let padded = crate::crypto::pkcs7_pad(body.to_string().as_bytes(), 16);
    let cipher = crate::crypto::aes_cbc_encrypt(&padded, AES_KEY, AES_IV);
    let b64 = base64::engine::general_purpose::STANDARD.encode(cipher);
    let ts = (now_ms() / 1000).to_string();
    let sign = md5_hex(
        sha256_hex(format!("client=pwa&data={b64}&timestamp={ts}{SECRET}").as_bytes()).as_bytes(),
    );
    let form = format!(
        "client=pwa&timestamp={ts}&data={}&sign={sign}",
        urlenc(&b64)
    );
    let url = format!("{BASE}{path}");
    let mut last_err = String::new();
    let mut all: Option<Vec<u8>> = None;
    for _ in 0..3 {
        let resp = match client() {
            Ok(c) => c
                .post(&url)
                .header("User-Agent", UA)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("Origin", ORIGIN)
                .header("Referer", format!("{ORIGIN}/"))
                .body(form.clone())
                .send()
                .await
                .map_err(|e| format!("http {e}")),
            Err(e) => Err(format!("{e}")),
        };
        match resp {
            Ok(r) => {
                if !r.status().is_success() {
                    last_err = format!("http {}", r.status());
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    continue;
                }
                match r.bytes().await {
                    Ok(b) => {
                        all = Some(b.to_vec());
                        break;
                    }
                    Err(e) => {
                        last_err = format!("body {e}");
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    }
                }
            }
            Err(e) => {
                last_err = e;
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    let Some(all) = all else {
        return Err(ApiError::Internal(format!("utube call failed: {last_err}")));
    };
    let v: Value =
        serde_json::from_slice(&all).map_err(|e| ApiError::Internal(format!("utube json: {e}")))?;
    let data_s = text_of(&v, &["data"]);
    if data_s.is_empty() {
        return Ok(v);
    }
    let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(data_s.as_bytes()) else {
        return Ok(v);
    };
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Ok(v);
    }
    let plain = crate::crypto::aes_cbc_decrypt(&raw, AES_KEY, AES_IV);
    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
    let s = String::from_utf8_lossy(unpadded).to_string();
    if !s.starts_with('{') && !s.starts_with('[') {
        return Ok(v);
    }
    if let Ok(obj) = serde_json::from_str::<Value>(&s) {
        return Ok(obj);
    }
    if let Ok(arr) = serde_json::from_str::<Vec<Value>>(&s) {
        return Ok(json!({"data": arr}));
    }
    Ok(v)
}

fn img(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    if !s.contains("drleao.cn") {
        return s.to_string();
    }
    format!("https://lxsimg.ystv.top/img?u={}", urlenc(s))
}

fn is_paid(v: &Value) -> bool {
    get(v, "is_pay").and_then(|x| x.as_i64()) == Some(1)
        || (get(v, "coins").and_then(|x| x.as_i64()).unwrap_or(0) > 0
            && get(v, "isfree").and_then(|x| x.as_i64()) == Some(2))
}

fn cover_of(v: &Value) -> String {
    img(&text_of(
        v,
        &["cover_horizontal", "cover_vertical", "cover"],
    ))
}

fn title_of(v: &Value) -> String {
    text_of(v, &["title", "username", "name"])
}

fn card(v: &Value, kind: &str, include_paid: bool) -> Option<Value> {
    if text_of(v, &["id"]).is_empty() || title_of(v).is_empty() {
        return None;
    }
    let paid = kind == "video" && is_paid(v);
    if paid && !include_paid {
        return None;
    }
    let remark = if paid {
        "付费".to_string()
    } else {
        let dur = get(v, "duration").and_then(|x| x.as_i64()).unwrap_or(0);
        if dur > 0 && dur < 100000 {
            format!("{}:{:02}", dur / 60, dur % 60)
        } else {
            String::new()
        }
    };
    let mut content = text_of(v, &["tags"]);
    if content.is_empty() {
        content = arr_of(get(v, "tag_list").unwrap_or(&Value::Null))
            .map(|a| {
                a.iter()
                    .map(|t| t.as_str().unwrap_or("").to_string())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
            .join(",");
    }
    if content.is_empty() {
        content = text_of(v, &["theme"]);
    }
    let vod_id = format!("{kind}:{}", text_of(v, &["id"]));
    CACHE.lock().unwrap().insert(vod_id.clone(), v.clone());
    let mut it = item_json(&vod_id, &title_of(v), &cover_of(v), &remark);
    it["content"] = json!(content);
    Some(it)
}

fn flatten(arr: Option<&Vec<Value>>, kind: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut list: Vec<Value> = Vec::new();
    if let Some(arr) = arr {
        list = arr.clone();
    }
    for v in &list {
        if let Some(c) = card(v, kind, false) {
            out.push(c);
        }
    }
    if out.is_empty() {
        for v in &list {
            if let Some(c) = card(v, kind, true) {
                out.push(c);
            }
        }
    }
    out
}

fn data_list_or_array(resp: &Value) -> Option<Vec<Value>> {
    let data = get(resp, "data").cloned().unwrap_or(Value::Null);
    if let Some(a) = data.as_array() {
        return Some(a.clone());
    }
    arr_of(get(&data, "list").unwrap_or(&Value::Null)).cloned()
}

async fn list_for(category_id: &str, page: i64) -> ApiResult<Vec<Value>> {
    let page_s = page.to_string();
    if category_id == "rec" {
        let resp = call(
            "/api.php/api/index/index",
            &[("id", "1"), ("page", &page_s), ("limit", "16")],
        )
        .await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let mut out: Vec<Value> = Vec::new();
        if let Some(groups) = arr_of(get(&data, "list").unwrap_or(&Value::Null)) {
            for g in groups {
                if let Some(a) = arr_of(get(g, "items").unwrap_or(&Value::Null)) {
                    out.extend(flatten(Some(a), "video"));
                }
                if let Some(a) = arr_of(get(g, "materials").unwrap_or(&Value::Null)) {
                    out.extend(flatten(Some(a), "melon"));
                }
            }
        }
        if out.is_empty() {
            if let Some(a) = arr_of(get(&data, "list").unwrap_or(&Value::Null)) {
                out = flatten(Some(a), "video");
            }
        }
        return Ok(out);
    }
    if category_id == "discover2" {
        let resp = call(
            "/api.php/api/mv/discover2",
            &[("sort", "see"), ("page", &page_s), ("limit", "16")],
        )
        .await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        return Ok(flatten(
            arr_of(get(&data, "list").unwrap_or(&Value::Null)),
            "video",
        ));
    }
    if let Some(id) = category_id.strip_prefix("construct:") {
        let resp = call(
            "/api.php/api/mv/list_construct",
            &[
                ("sort", "see"),
                ("id", id),
                ("page", &page_s),
                ("limit", "16"),
            ],
        )
        .await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        return Ok(flatten(
            arr_of(get(&data, "list").unwrap_or(&Value::Null)),
            "video",
        ));
    }
    if category_id == "melon" {
        let resp = call(
            "/api.php/api/material/list_sort",
            &[
                ("sort", "new"),
                ("id", "1"),
                ("page", &page_s),
                ("limit", "16"),
            ],
        )
        .await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        return Ok(flatten(
            arr_of(get(&data, "materials").unwrap_or(&Value::Null)),
            "melon",
        ));
    }
    if category_id == "live" {
        let resp = call(
            "/api.php/api/live/index",
            &[("id", "1"), ("page", &page_s), ("limit", "16")],
        )
        .await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        return Ok(flatten(
            arr_of(get(&data, "lives").unwrap_or(&Value::Null)),
            "live",
        ));
    }
    if category_id == "vlog" {
        let resp = call(
            "/api.php/api/vlog/list_sort",
            &[("sort", "rec"), ("page", &page_s)],
        )
        .await?;
        return Ok(flatten(data_list_or_array(&resp).as_ref(), "vlog"));
    }
    if category_id == "popular" {
        let resp = call(
            "/api.php/api/mv/discover",
            &[("sort", "popular"), ("page", &page_s), ("limit", "16")],
        )
        .await?;
        return Ok(flatten(data_list_or_array(&resp).as_ref(), "video"));
    }
    Ok(Vec::new())
}

fn play_url(v: &Value) -> String {
    let mut s = text_of(v, &["m3u8"]);
    if s.is_empty() {
        if let Some(mv) = get(v, "mv") {
            s = text_of(mv, &["m3u8"]);
        }
    }
    if s.is_empty() {
        s = text_of(v, &["mv_m3u8"]);
    }
    if s.is_empty() {
        s = text_of(v, &["preview_url"]);
    }
    if s.is_empty() {
        if let Some(ps) = get(v, "preview_sources") {
            s = text_of(ps, &["url_264"]);
            if s.is_empty() {
                s = text_of(ps, &["url_265"]);
            }
        }
    }
    if s.is_empty() {
        if let Some(vs) = get(v, "video_sources") {
            s = text_of(vs, &["url_264"]);
            if s.is_empty() {
                s = text_of(vs, &["url_265"]);
            }
        }
    }
    if s.is_empty() {
        s = text_of(v, &["source_720"]);
    }
    if s.is_empty() {
        s = text_of(v, &["source_480"]);
    }
    if s.is_empty() {
        s = text_of(v, &["source_240"]);
    }
    let re = Regex::new(r"hf-[^.]+\.").unwrap();
    re.replace_all(&s, "hf-long.").to_string()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let items = match list_for(category_id, page).await {
        Ok(items) => items,
        Err(_) => Vec::new(),
    };
    // jar 的 pageObj 置 pagecount = 当前页；此处按满页即有下一页算。
    let has_more = items.len() == 16;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let (kind, rest) = match id.find(':') {
        Some(pos) => (&id[..pos], &id[pos + 1..]),
        None => ("video", id),
    };
    if kind == "live" {
        let resp = call("/api.php/api/live/detail", &[("id", rest)]).await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let live = get(&data, "live").cloned().unwrap_or(Value::Null);
        let mut title = text_of(&live, &["username"]);
        if title.is_empty() {
            title = format!("直播{rest}");
        }
        return Ok(json!({
            "id": id, "title": title, "cover": cover_of(&live), "synopsis": "",
            "extra": {},
            "episodes": [episode_json(&format!("live:{rest}"), "正片", id)],
        }));
    }
    if kind == "melon" {
        let resp = call("/api.php/api/material/detail", &[("id", rest)]).await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let d = get(&data, "detail").cloned().unwrap_or(Value::Null);
        let mut title = text_of(&d, &["title"]);
        if title.is_empty() {
            title = format!("黑料{rest}");
        }
        let mut content = text_of(&d, &["txt"]);
        if content.is_empty() {
            content = text_of(&d, &["content"]);
        }
        return Ok(json!({
            "id": id, "title": title, "cover": cover_of(&d), "synopsis": content,
            "extra": {}, "episodes": [],
        }));
    }
    let resp = call("/api.php/api/mv/getDetail", &[("id", rest)]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let mut d = get(&data, "detail").cloned().unwrap_or(Value::Null);
    if d.is_null() {
        d = data.clone();
    }
    let mut title = text_of(&d, &["title"]);
    let mut cover = cover_of(&d);
    if title.is_empty() {
        if let Some(cached) = CACHE.lock().unwrap().get(id).cloned() {
            title = title_of(&cached);
            if cover.is_empty() {
                cover = cover_of(&cached);
            }
        }
    }
    if title.is_empty() {
        title = format!("视频{rest}");
    }
    let mut content = text_of(&d, &["desc"]);
    if content.is_empty() {
        content = text_of(&d, &["tags"]);
    }
    let paid = kind == "video" && is_paid(&d);
    let url = if paid { String::new() } else { play_url(&d) };
    let mut episodes: Vec<Value> = Vec::new();
    if !url.is_empty() {
        episodes.push(episode_json(&url, "正片", id));
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover, "synopsis": content,
        "extra": {"vod_remarks": if paid { "付费" } else { "" }},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let resp = match call(
        "/api.php/api/mv/search",
        &[
            ("word", query),
            ("type", "1"),
            ("page", "1"),
            ("limit", "16"),
        ],
    )
    .await
    {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": []})),
    };
    Ok(json!({"items": flatten(data_list_or_array(&resp).as_ref(), "video")}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{ORIGIN}/")},
        }));
    }
    let id = match video_id.find('$') {
        Some(pos) => &video_id[pos + 1..],
        None => video_id,
    };
    let mut url = String::new();
    if let Some(live_id) = id.strip_prefix("live:") {
        let resp = call("/api.php/api/live/detail", &[("id", live_id)]).await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let live = get(&data, "live").cloned().unwrap_or(Value::Null);
        if let Some(hls) = arr_of(get(&live, "hls").unwrap_or(&Value::Null)) {
            if let Some(first) = hls.first() {
                url = text_of(first, &["url"]);
            }
        }
    } else {
        let rest = match id.find(':') {
            Some(pos) => &id[pos + 1..],
            None => id,
        };
        let resp = call("/api.php/api/mv/getDetail", &[("id", rest)]).await?;
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let mut d = get(&data, "detail").cloned().unwrap_or(Value::Null);
        if d.is_null() {
            d = data.clone();
        }
        if !is_paid(&d) {
            url = play_url(&d);
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("utube no stream url".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{ORIGIN}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_ten_after_delete() {
        assert_eq!(CATS.len(), 10);
        assert!(!CATS.iter().any(|(id, _)| *id == "construct:75"));
    }

    #[test]
    fn play_url_priority_and_hf() {
        let v: Value = serde_json::from_str(
            r#"{"preview_url":"https://hf-abc123.cdn.com/x.m3u8","source_720":"https://cdn/720.m3u8"}"#,
        )
        .unwrap();
        assert_eq!(play_url(&v), "https://hf-long.cdn.com/x.m3u8");
        let v2: Value = serde_json::from_str(r#"{"m3u8":"https://cdn/a.m3u8"}"#).unwrap();
        assert_eq!(play_url(&v2), "https://cdn/a.m3u8");
    }

    #[test]
    fn card_paid_rules() {
        let v: Value = serde_json::from_str(r#"{"id":"1","title":"t","is_pay":1}"#).unwrap();
        assert!(card(&v, "video", false).is_none());
        assert!(card(&v, "video", true).is_some());
        let v2: Value =
            serde_json::from_str(r#"{"id":"2","title":"t","coins":5,"isfree":2,"duration":125}"#)
                .unwrap();
        let c = card(&v2, "video", true).unwrap();
        assert_eq!(c["remark"], "付费");
        let v3: Value = serde_json::from_str(r#"{"id":"3","title":"t","duration":125}"#).unwrap();
        let c3 = card(&v3, "video", false).unwrap();
        assert_eq!(c3["remark"], "2:05");
    }
}
