//! YouTube成人版（rohu）：PWA 后端，请求体 AES 加密 + 签名。
//!
//! 与 Dart 的 ZakaRohuAmns 一一对应。调用流程：params（bundleId、
//! version 2.1.1、language zh、via pwa、oauth_id、oauth_type web、
//! support_webp 1、new_hash 0，token 有则加）拼成 JSON → UTF-8 →
//! AES/CBC/PKCS5Padding 加密 → base64 得 data；ts 为当前毫秒；
//! signInput=`_ver=v2&client=pwa&data=<data>&timestamp=<ts>`，
//! sign=md5(sha256(signInput + 签名密钥))（均为 hex 小写）；POST
//! `client=pwa&timestamp=<ts>&data=<编码data>&sign=<sign>&_ver=v2`，
//! 头含 Content-Type、安卓 UA、Origin/Referer 均为
//! https://w1.rohuzsqwk.com。响应 data 若为非空字符串则 base64 解码
//! 后 AES 解密成 JSON，否则原样返回。两后端轮换、最多 3 次。
//!
//! 分类是动态的：groups 调 /api/element/getElementById 取
//! data.value[]（每项 name 与 params.id），homeContent 在最前加
//! “最近更新”（new）与“最热”（hot）；动态取不到时用静态回退表
//! （已删“萝莉”分类，剩 28 项）。数字 tid 走 list_construct，
//! 其余走搜索，hot 按播放量降序。详情取 /api/mv/getDetail；
//! 取流：正片优先 video_sources.url_264/url_265，其次试看地址换
//! 正片 CDN、hevcFull、source_240_hevc、source_1080/720/480/240；
//! 分集 video_id 即 URL 本身。封面 URL 若为密文则用图片密钥
//! AES 解密（pic）。注意：本机无法验——域名解析到 CGNAT 地址、
//! 60 秒超时，全链须手机侧复验；核心无登录入口，匿名访问。

use aes::Aes128;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use cbc::{Decryptor, Encryptor};
use md5::Digest as _;
use serde_json::{json, Map, Value};
use sha2::Sha256;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, obj_of};

const BASES: &[&str] = &[
    "https://api1.gkxgquhl.cc/api.php",
    "https://bak.gkxgquhl.cc/api.php",
];
const BUNDLE: &str = "com.pwa.wyll";
const OAUTH_DEFAULT: &str = "6a1f01ad3bcdd3f86ccf0edabbfce94c";
const APP_VER: &str = "2.1.1";
const ORIGIN: &str = "https://w1.rohuzsqwk.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const CDN_PREVIEW: &str = "yd-10play.bnfuiu.cn";
const CDN_FULL: &str = "video.iwanna.tv";

const AES_KEY: &[u8] = &[
    0x33, 0x65, 0x66, 0x34, 0x33, 0x37, 0x64, 0x39, 0x38, 0x31, 0x35, 0x31, 0x35, 0x39, 0x34, 0x36,
];
const AES_IV: &[u8] = &[
    0x38, 0x32, 0x34, 0x64, 0x33, 0x37, 0x35, 0x37, 0x33, 0x33, 0x62, 0x36, 0x32, 0x34, 0x35, 0x65,
];
const IMG_KEY: &[u8] = &[
    0x66, 0x35, 0x64, 0x39, 0x36, 0x35, 0x64, 0x66, 0x37, 0x35, 0x33, 0x33, 0x36, 0x32, 0x37, 0x30,
];
const IMG_IV: &[u8] = &[
    0x39, 0x37, 0x62, 0x36, 0x30, 0x33, 0x39, 0x34, 0x61, 0x62, 0x63, 0x32, 0x66, 0x62, 0x65, 0x31,
];
const SIGN_SECRET: &str = "03d20341be99573e4c497a02d7eee40a";

/// 静态回退分类：[显示名, 关键词]，已删“萝莉”，剩 28 项。
const FALLBACK_CATS: &[(&str, &str)] = &[
    ("热门推荐", "热门"),
    ("有码", "有码"),
    ("无码", "无码"),
    ("中文字幕", "中文字幕"),
    ("人妻熟女", "人妻"),
    ("少妇", "少妇"),
    ("制服诱惑", "制服"),
    ("巨乳", "巨乳"),
    ("黑丝美腿", "黑丝"),
    ("丝袜", "丝袜"),
    ("女教师", "教师"),
    ("护士", "护士"),
    ("按摩", "按摩"),
    ("户外", "户外"),
    ("NTR", "ntr"),
    ("强奸", "强奸"),
    ("3P群交", "3p"),
    ("口交", "口交"),
    ("内射", "内射"),
    ("泰国", "泰国"),
    ("日本", "日本"),
    ("韩国", "韩国"),
    ("欧美", "欧美"),
    ("自拍流出", "自拍"),
    ("探花", "探花"),
    ("麻豆传媒", "麻豆"),
    ("AV解说", "解说"),
];

/// 取值转字符串（字符串/数字/布尔均可）。
fn s(v: &Value) -> String {
    match v {
        Value::String(t) => t.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// 取值转整数（数字或数字字符串）。
fn n(v: &Value) -> i64 {
    match v {
        Value::Number(n) => n.as_i64().unwrap_or(0),
        Value::String(t) => t.trim().parse::<i64>().unwrap_or(0),
        _ => 0,
    }
}

/// 取对象里多个候选键的首个非空字符串。
fn pick_str<'a>(v: &'a Value, keys: &[&str]) -> String {
    for k in keys {
        if let Some(val) = get(v, k) {
            let t = s(val);
            if !t.is_empty() {
                return t;
            }
        }
    }
    String::new()
}

/// 取对象里多个候选键的首个非零整数。
fn pick_int(v: &Value, keys: &[&str]) -> i64 {
    for k in keys {
        if let Some(val) = get(v, k) {
            let x = n(val);
            if x != 0 {
                return x;
            }
        }
    }
    0
}

/// 秒数转 `分:秒`（%02d:%02d）。
fn dur(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    format!("{:02}:{:02}", secs / 60, secs % 60)
}

/// 小写 hex。
fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// AES/CBC/PKCS7 加密。
fn aes_encrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Vec<u8> {
    Encryptor::<Aes128>::new_from_slices(key, iv)
        .expect("rohu aes key/iv")
        .encrypt_padded_vec_mut::<Pkcs7>(data)
}

/// AES/CBC/PKCS7 解密，失败返回 None。
fn aes_decrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Option<Vec<u8>> {
    Decryptor::<Aes128>::new_from_slices(key, iv)
        .ok()?
        .decrypt_padded_vec_mut::<Pkcs7>(data)
        .ok()
}

/// base64 解码（标准与 URL 安全双兼容）。
fn b64dec(raw: &str) -> Option<Vec<u8>> {
    STANDARD
        .decode(raw)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(raw))
        .ok()
}

/// URLEncoder 式编码：空格成 %20。
fn url_enc(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 当前毫秒时间戳。
fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// 基础请求参数（匿名：无 token）。
fn params(extra: &[(&str, Value)]) -> Value {
    let mut map = Map::new();
    map.insert("bundleId".into(), json!(BUNDLE));
    map.insert("version".into(), json!(APP_VER));
    map.insert("language".into(), json!("zh"));
    map.insert("via".into(), json!("pwa"));
    map.insert("oauth_id".into(), json!(OAUTH_DEFAULT));
    map.insert("oauth_type".into(), json!("web"));
    map.insert("support_webp".into(), json!(1));
    map.insert("new_hash".into(), json!(0));
    for (k, v) in extra {
        map.insert((*k).to_string(), v.clone());
    }
    Value::Object(map)
}

/// 一次加密签名调用：两后端轮换、最多 3 次。返回 data 解密后的 JSON。
async fn call(path: &str, body: Value) -> ApiResult<Value> {
    let body_str = serde_json::to_string(&body).unwrap_or_else(|_| "{}".into());
    let data = STANDARD.encode(aes_encrypt(AES_KEY, AES_IV, body_str.as_bytes()));
    let ts = now_ms();
    let sign_input = format!("_ver=v2&client=pwa&data={data}&timestamp={ts}");
    let sha = hex_lower(&Sha256::digest(
        format!("{sign_input}{SIGN_SECRET}").as_bytes(),
    ));
    let sign = format!("{:x}", md5::compute(sha.as_bytes()));
    let form = format!(
        "client=pwa&timestamp={ts}&data={}&sign={sign}&_ver=v2",
        url_enc(&data)
    );
    let mut last_err = String::new();
    for attempt in 0..3 {
        let base = BASES[attempt % BASES.len()];
        let url = format!("{base}{path}");
        let resp = client()?
            .post(&url)
            .header("User-Agent", UA)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("Origin", ORIGIN)
            .header("Referer", format!("{ORIGIN}/"))
            .body(form.clone())
            .send()
            .await;
        match resp {
            Ok(r) if r.status().as_u16() == 200 => {
                let text = r.text().await.unwrap_or_default();
                let parsed: Value = match serde_json::from_str(&text) {
                    Ok(v) => v,
                    Err(_) => {
                        last_err = "响应不是 JSON".into();
                        continue;
                    }
                };
                if let Some(d) = get(&parsed, "data") {
                    if let Value::String(enc) = d {
                        if !enc.is_empty() {
                            if let Some(raw) = b64dec(enc) {
                                if let Some(plain) = aes_decrypt(AES_KEY, AES_IV, &raw) {
                                    if let Ok(v) = serde_json::from_slice::<Value>(&plain) {
                                        return Ok(v);
                                    }
                                }
                            }
                            last_err = "data 解密失败".into();
                            continue;
                        }
                    }
                    return Ok(d.clone());
                }
                return Ok(parsed);
            }
            Ok(r) => last_err = format!("HTTP {}", r.status().as_u16()),
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!("rohu 调用失败：{last_err}")))
}

/// 封面 URL：JSON 串取 720→ori→360；密文则 AES 解密；明文直返。
fn pic(raw: &str) -> String {
    let mut u = raw.trim().to_string();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(&u) {
            for k in ["720", "ori", "360"] {
                if let Some(val) = get(&v, k) {
                    let t = s(val);
                    if !t.is_empty() {
                        u = t;
                        break;
                    }
                }
            }
        }
    }
    u = u.replace("\\/", "/");
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u;
    }
    if let Some(raw_bytes) = b64dec(&u) {
        if let Some(plain) = aes_decrypt(IMG_KEY, IMG_IV, &raw_bytes) {
            if let Ok(t) = String::from_utf8(plain) {
                let t = t.trim().to_string();
                if t.starts_with("http") {
                    return t;
                }
            }
        }
    }
    u
}

/// 试看地址换正片 CDN；否则去掉 `?` 后的查询串。
fn swap_cdn(url: &str) -> String {
    if url.is_empty() {
        return String::new();
    }
    if url.contains(CDN_PREVIEW) {
        url.replace(CDN_PREVIEW, CDN_FULL)
    } else {
        match url.find('?') {
            Some(pos) => url[..pos].to_string(),
            None => url.to_string(),
        }
    }
}

/// hevc_full：hevc_meta→submit_result→data→file_url（http 开头者）。
fn hevc_full(detail: &Value) -> String {
    if let Some(meta) = get(detail, "hevc_meta") {
        if let Some(sub) = get(meta, "submit_result") {
            if let Some(data) = get(sub, "data") {
                let f = pick_str(data, &["file_url", "url"]);
                if f.starts_with("http") {
                    return f;
                }
            }
        }
    }
    String::new()
}

/// 正片地址回退链。
fn video_url(detail: &Value) -> String {
    if let Some(vs) = get(detail, "video_sources") {
        let u = pick_str(vs, &["url_264", "url_265"]);
        if !u.is_empty() {
            return u;
        }
    }
    let pv = preview_url(detail);
    if !pv.is_empty() {
        return pv;
    }
    let h = hevc_full(detail);
    if !h.is_empty() {
        return h;
    }
    let s240 = pick_str(detail, &["source_240_hevc"]);
    if s240.starts_with("http") {
        return s240;
    }
    for k in ["source_1080", "source_720", "source_480", "source_240"] {
        let u = pick_str(detail, &[k]);
        if u.starts_with("http") {
            return u;
        }
    }
    String::new()
}

/// 试看地址（换 CDN 后）。
fn preview_url(detail: &Value) -> String {
    let mut p = pick_str(detail, &["preview_url"]);
    if p.is_empty() {
        if let Some(ps) = get(detail, "preview_sources") {
            p = pick_str(ps, &["url_264", "url_265"]);
        }
    }
    swap_cdn(&p)
}

/// 影片卡片，附带播放量排序键。
fn video_card(obj: &Value) -> (i64, Value) {
    let id = pick_str(obj, &["id", "vod_id"]);
    let mut title = pick_str(obj, &["title", "name"]);
    let isfree = pick_int(obj, &["isfree"]);
    if isfree == 0 {
        let coins = pick_int(obj, &["coins", "coin"]);
        title = format!("[金币{coins}] {title}");
    }
    let cover = pic(&pick_str(obj, &["cover_vertical", "cover", "pic"]));
    let remark = dur(pick_int(obj, &["duration"]));
    let sort = pick_int(obj, &["play_ct", "play_count", "count_play"]);
    (sort, item_json(&id, &title, &cover, &remark))
}

/// 从 data 里 tolerant 取卡片数组：数组本身 / data.list 数组 /
//  data.list[].items[] 展平。
fn cards_from(data: &Value) -> Vec<(i64, Value)> {
    let mut out: Vec<(i64, Value)> = Vec::new();
    if let Some(arr) = arr_of(data) {
        for obj in arr {
            out.push(video_card(obj));
        }
        return out;
    }
    if let Some(list) = get(data, "list") {
        if let Some(arr) = arr_of(list) {
            for section in arr {
                if let Some(items) = get(section, "items") {
                    if let Some(iarr) = arr_of(items) {
                        for obj in iarr {
                            out.push(video_card(obj));
                        }
                    }
                } else {
                    out.push(video_card(section));
                }
            }
        }
    }
    out
}

/// 首页列表：/api/index/index。
async fn home_list(page: i64) -> ApiResult<Vec<(i64, Value)>> {
    let body = params(&[
        ("id", json!(1)),
        ("page", json!(page)),
        ("limit", json!(24)),
    ]);
    let data = call("/api/index/index", body).await?;
    Ok(cards_from(&data))
}

/// 动态分类：/api/element/getElementById。
async fn groups() -> Vec<(String, String)> {
    let body = params(&[("id", json!(1))]);
    let mut out: Vec<(String, String)> = Vec::new();
    if let Ok(data) = call("/api/element/getElementById", body).await {
        if let Some(vals) = get(&data, "value") {
            if let Some(arr) = arr_of(vals) {
                for item in arr {
                    let name = pick_str(item, &["name"]);
                    let id = if let Some(p) = get(item, "params") {
                        pick_str(p, &["id"])
                    } else {
                        String::new()
                    };
                    if !name.is_empty() && !id.is_empty() {
                        out.push((id, name));
                    }
                }
            }
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = vec![
        category_json("new", "最近更新"),
        category_json("hot", "最热"),
    ];
    let dyn_cats = groups().await;
    if dyn_cats.is_empty() {
        for (name, word) in FALLBACK_CATS {
            list.push(category_json(word, name));
        }
    } else {
        for (id, name) in dyn_cats {
            list.push(category_json(&id, &name));
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.trim();
    let mut cards: Vec<(i64, Value)> = Vec::new();
    if tid.is_empty() || tid == "new" {
        cards = home_list(page).await?;
    } else if tid == "hot" {
        cards = home_list(page).await?;
        cards.sort_by(|a, b| b.0.cmp(&a.0));
    } else if tid.chars().all(|c| c.is_ascii_digit()) {
        let id_num: i64 = tid.parse().unwrap_or(0);
        let body = params(&[
            ("id", json!(id_num)),
            ("page", json!(page)),
            ("limit", json!(24)),
            ("sort", json!("")),
        ]);
        let data = call("/api/tabnew/list_construct", body).await?;
        cards = cards_from(&data);
    } else {
        let body = params(&[
            ("word", json!(tid)),
            ("page", json!(page)),
            ("limit", json!(24)),
        ]);
        let data = call("/api/mv/search", body).await?;
        cards = cards_from(&data);
    }
    let items: Vec<Value> = cards.into_iter().map(|(_, c)| c).collect();
    let has_more = items.len() >= 24;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    if sid.is_empty() {
        return Err(ApiError::Internal("rohu 未指定影片".into()));
    }
    let id_val = if sid.chars().all(|c| c.is_ascii_digit()) {
        json!(sid.parse::<i64>().unwrap_or(0))
    } else {
        json!(sid)
    };
    let body = params(&[("id", id_val)]);
    let data = call("/api/mv/getDetail", body).await?;
    let det = match get(&data, "detail") {
        Some(d) if obj_of(d).is_some() => d.clone(),
        _ => data.clone(),
    };
    let title = pick_str(&det, &["title", "name"]);
    if title.is_empty() {
        return Err(ApiError::Internal("rohu 未返回影片标题".into()));
    }
    let mut cover = pic(&pick_str(&det, &["cover_horizontal"]));
    if cover.is_empty() {
        cover = pic(&pick_str(&det, &["cover_vertical", "cover"]));
    }
    let seconds = pick_int(&det, &["duration"]);
    let mut synopsis = pick_str(&det, &["desc", "description", "vod_blurb"]);
    let plays = pick_int(&det, &["count_play", "play_ct", "play_count"]);
    let favs = pick_int(&det, &["favorites", "fav_count"]);
    synopsis.push_str(&format!(
        "\n时长 {} · 播放 {plays} · 收藏 {favs}",
        dur(seconds)
    ));
    let is_pay = pick_int(&det, &["is_pay"]);
    if is_pay == 1 {
        let coins = pick_int(&det, &["coins", "coin"]);
        synopsis.push_str(&format!(" · 金币片({coins})"));
    }
    let area = pick_str(&det, &["video_tag_name", "vod_area"]);
    if !area.is_empty() {
        synopsis.push_str(&format!("\n地区：{area}"));
    }
    let class = pick_str(&det, &["tags", "vod_class"]).replace(',', " / ");
    if !class.is_empty() {
        synopsis.push_str(&format!("\n分类：{class}"));
    }
    let actors = pick_str(&det, &["actors", "vod_actor"]);
    if !actors.is_empty() {
        synopsis.push_str(&format!("\n演员：{actors}"));
    }
    let directors = pick_str(&det, &["directors", "vod_director"]);
    if !directors.is_empty() {
        synopsis.push_str(&format!("\n导演：{directors}"));
    }
    let year_raw = pick_str(&det, &["release_date", "created_at", "update_time", "date"]);
    let year = if year_raw.len() >= 4 {
        year_raw[..4].to_string()
    } else {
        pick_str(&det, &["vod_year"])
    };
    let full = video_url(&det);
    let preview = preview_url(&det);
    let mut episodes: Vec<Value> = Vec::new();
    if !full.is_empty() {
        episodes.push(episode_json(&full, "全片", sid));
        synopsis.push_str("\n[全片] 已走正片 CDN");
    }
    if !preview.is_empty() && preview != full {
        episodes.push(episode_json(&preview, "试看", sid));
    }
    if episodes.is_empty() {
        synopsis.push_str("\n[无线路] 试看 CDN 未命中，换域也拿不到");
    }
    let mut extra = Map::new();
    if !year.is_empty() {
        extra.insert("year".into(), json!(year));
    }
    Ok(json!({
        "id": sid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = query.trim();
    let body = params(&[("word", json!(q)), ("page", json!(1)), ("limit", json!(24))]);
    let data = call("/api/mv/search", body).await?;
    let items: Vec<Value> = cards_from(&data).into_iter().map(|(_, c)| c).collect();
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id.trim();
    if url.starts_with("http") {
        Ok(json!({"url": url}))
    } else {
        Err(ApiError::Internal("rohu 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_cats_are_28_without_loli() {
        assert_eq!(FALLBACK_CATS.len(), 28);
        assert!(!FALLBACK_CATS
            .iter()
            .any(|(n, w)| *n == "萝莉" || *w == "萝莉"));
    }

    #[test]
    fn dur_formats() {
        assert_eq!(dur(125), "02:05");
        assert_eq!(dur(0), "");
    }

    #[test]
    fn swap_cdn_rules() {
        assert_eq!(
            swap_cdn("https://yd-10play.bnfuiu.cn/x/1.m3u8?k=1"),
            "https://video.iwanna.tv/x/1.m3u8?k=1"
        );
        assert_eq!(swap_cdn("https://a.b/c.mp4?x=1&y=2"), "https://a.b/c.mp4");
    }

    #[test]
    fn url_enc_spaces() {
        assert_eq!(url_enc("a b+c/d"), "a%20b%2Bc%2Fd");
    }
}
