//! 黄瓜视频。
//!
//! 来源 jar 类 `ZakaCucumberAmns`。基址 4 个轮询；`ORIGIN` 为
//! `https://cuke01.live`；流域名 `STREAM=https://hgapi-pnt017.soymfb.com`，
//! 备用 `STREAM_FB=https://hgapi7.scxhht.com`；图片中继
//! `https://cuimg.ystv.top/img?u=<编码>`。
//!
//! `call(method, path, params, jsonBody)`：轮询 BASES；签名串为
//! `<METHOD><path>?Authorization=&Seq=<seq>&X-Auth-Key=<AUTH_KEY>&X-Auth-Nonce=<随机 0–9999>&X-Auth-TimeStamp=<毫秒>`
//! + 排序后的全部参数（含固定 `pkg=cuke0001`、`release=410`、
//! `terminal=4`），形如 `&k=v` 拼接（值不编码）；签名为 HmacSHA1
//! （密钥 `HMAC_KEY`）后 Base64 再 URLEncoder 编码（SHA-1 与 HMAC 均
//! 手写，因 Cargo 未引 sha1/hmac crate）；请求头 `release: 410`、
//! `origin`、`seq`、`x-auth-key`、`pkg`、`terminal`、`x-auth-nonce`、
//! `x-auth-sign`、`x-auth-timestamp`、UA `okhttp/4.9.0`；响应头 `seq`
//! 更新本地 seq；响应含 `encryptedData`（非空且非 `----`）时 Base64
//! 解码后 AES/ECB/PKCS5Padding 解密（密钥 `AES_KEY`），明文以 `[` 开头
//! 则包成 `{"arr":…}` 存 `dataArr`，否则存 `data`；要求 `code == 0`。
//!
//! `channels()`：GET `/home/defaultchannels`，取 `parentModule != 0`
//! 的频道；取不到时用写死 11 条；缓存 30 分钟。`classes()`：`choice`
//! 精选 + 各频道 `ch:<parentModule>:<channelType>:<hasSelection>` +
//! `col` 专栏 + 12 个 `rank:<viewmov|newmov|lusir|tucao>:<1|2|3>` +
//! 3 个 `rank:actors:<1|2|3>` 女优榜 + `actor` 女优 +
//! `short:Time` 短剧·最新 + `short:Play` 短剧·最热。
//!
//! `listFor`：`choice` 仅第 1 页（GET `/home/selection/query`，每组
//! name 空则“精选”）；`ch:<m>:<t>:<sel>` 4 段（`sel=="1"` 仅第 1 页，
//! GET `/home/selection/query2`；否则 POST `/home/movlist`，
//! `pageNo`/`pageSize 12`/`selectionType`/`moduleId`）；`col` 仅第 1
//! 页（GET `/module/list`，`navId`/`navName` 空跳过，卡片
//! `vod_id="dir:nav:"+navId+":"+navCls`、备注 `modName`、标签“专栏”）；
//! `dir:nav:<navId>:<navCls>`（POST `/module/movlist2`，JSON 里
//! navId/navCls 为 int）；`rank:<type>:<period>`（`actors` 时 GET
//! `/ranking/actors` 出女优卡，否则 GET `/ranking/<type>`）；
//! `actor`（GET `/home/actor/list`，`queryType 1`、`cupType 0`、
//! `pageSize 21`，女优卡备注 `nameEn` 否则 `"<cup>杯"`）；
//! `dir:actor:<id>`（GET `/actor/movie/list`）；`short:<order>`（GET
//! `/shortvideo/listOrderBy<order>`，内联短剧卡）。
//!
//! `card`：`videoId`/`videoTitle` 非空才成卡；付费（`vipFlag != 0` 或
//! `isLimit != 0`）返回 null；备注取 `mins` 否则 `movScore`，否则
//! `"<strPlayCnt>播放"`；封面 `videoCover`；简介 `videoDesc`。
//! `cover`：`http` 开头直走中继；`img` 开头拼 `IMG_PREFIX`；`/jqn`
//! 或 `/yvn` 开头拼 `SEKIRO`；否则补 `/` 后拼 `AES_COVER`，再统一走
//! `img()` 中继；`pic`：`http` 开头直走中继，否则拼 `PIC_HOSTS[0]`。
//!
//! 详情：`dir:actor:<id>`（GET `/home/actor/detail`，简介含身高三围
//! 罩杯，备注 `cup+"杯"`，标签“女优”；再 GET `/actor/movie/list`
//! 作分集）；`dir:nav:<navId>:<navCls>`（GET `/module/nav`，备注与
//! 标签均为“专栏”；再 `listFor(id, 1)` 作分集）；普通影片
//! `browse(id)`（GET `/mov/browse2`），简介为 `videoDesc` +
//! `movScore | strPlayCnt | gmtCreate | movSnOri`，备注 `mins`，演员取
//! `actorList[]` 元素（见下）+ 回退 `obj.actor` 字符串。
//!
//! 修复（dex 实证的两处 jar bug，回报中另行注明）：
//! ① `detailContent` 演员循环取键的寄存器值为 `"vod_play_url"`，
//! 演员对象里不可能有该键，循环恒为空，只有回退的 `obj.actor` 字符串
//! 生效；Rust 按合理修复：actorList 元素先试 `actor` 再试 `name`。
//! ② `playerContent` 字面逻辑为“只有付费视频才取流”（`isPaid` 为真
//! 才调 `address`），与 `card()` 剔除付费矛盾，列表里的免费视频按
//! 字面会全返回空地址；Rust 按合理修复取反（免费才取流），待探针实
//! 测 `browse2` 的免费视频是否带 `address` 且 `isPaid` 为假来定夺。
//! 地址处理：`http` 开头直用；`/` 开头拼 `STREAM + "/" + addr`
//! （addr 本就以 `/` 开头，故为双斜杠，原样保留），`playlistOK`
//! （GET 前 64KB 含 `#EXTM3U`，UA + Referer `https://cuke01.live/`）
//! 通过后优先试 `STREAM_FB + "/" + addr`，通过则用 FB，否则用 STREAM。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine as _;
use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const UA: &str = "okhttp/4.9.0";
const ORIGIN: &str = "https://cuke01.live";
const STREAM: &str = "https://hgapi-pnt017.soymfb.com";
const STREAM_FB: &str = "https://hgapi7.scxhht.com";
const SEKIRO: &str = "https://hgustp.sekiro.info";
const AES_COVER: &str = "https://hghktp-bp-lk.hlvsja.com";
const IMG_PREFIX: &str = "https://gvc.n90yl.work/";
const IMG_WORKER: &str = "https://cuimg.ystv.top";
const PIC_HOST: &str = "https://gvc.imgcuke.work/img/";
const AUTH_KEY: &str = "feb48d9bffffebb322a773d8f213eebm";
const HMAC_KEY: &str = "cuke@majiaSecret#12021#0811";
const AES_KEY: &[u8] = b"V%4SdZ^ElKdOVU0m";
const SEQ_INIT: &str = "8f966d17ae1749699c124e1f1ca89662C30mC30mCJ8sC3G";
const BASES: &[&str] = &[
    "https://api66.capcom.work",
    "https://api88.awk2.work",
    "https://api55.wtttli.com",
    "https://api55.nmrgqb.com",
];

const FALLBACK_CHANNELS: &[(&str, &str, &str, &str)] = &[
    ("25", "1", "1", "国产"),
    ("36", "1", "1", "传媒机构"),
    ("23", "1", "1", "日本AV"),
    ("27", "1", "1", "动漫"),
    ("24", "1", "1", "欧美"),
    ("26", "1", "1", "三级"),
    ("33", "1", "0", "主播"),
    ("34", "2", "0", "UP人气热播"),
    ("34", "2", "0", "UP本周推荐"),
    ("41", "2", "0", "AI精彩影片"),
    ("41", "1", "1", "月度精选"),
];

static SEQ: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(SEQ_INIT.to_string()));
static CHAN_CACHE: Lazy<Mutex<(Vec<[String; 4]>, Option<Instant>)>> =
    Lazy::new(|| Mutex::new((Vec::new(), None)));

// ============ SHA-1（手写：Cargo 未引 sha1/hmac crate） ============

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let bitlen = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    for chunk in msg.chunks_exact(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A827999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let tmp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = tmp;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }
    let mut out = [0u8; 20];
    for (i, v) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

fn hmac_sha1(key: &[u8], msg: &[u8]) -> [u8; 20] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        let h = sha1(key);
        k[..20].copy_from_slice(&h);
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let mut inner = ipad.to_vec();
    inner.extend_from_slice(msg);
    let ih = sha1(&inner);
    let mut outer = opad.to_vec();
    outer.extend_from_slice(&ih);
    sha1(&outer)
}

fn aes_ecb_decrypt(data: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if key.len() != 16 || data.len() % 16 != 0 {
        return None;
    }
    let cipher = aes::Aes128::new(GenericArray::from_slice(key));
    let mut out = Vec::with_capacity(data.len());
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    Some(out)
}

// ============ 通用 ============

fn urlenc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// 签名串：`<METHOD><path>?Authorization=&Seq=<seq>&X-Auth-Key=…&X-Auth-Nonce=…&X-Auth-TimeStamp=…`
/// + 排序后的全部参数（含固定 pkg/release/terminal），形如 `&k=v`（值不编码）。
fn sign(
    method: &str,
    path: &str,
    params: &[(String, String)],
    nonce: &str,
    ts: &str,
    seq: &str,
) -> String {
    let mut all: Vec<(String, String)> = params.to_vec();
    all.push(("pkg".into(), "cuke0001".into()));
    all.push(("release".into(), "410".into()));
    all.push(("terminal".into(), "4".into()));
    all.sort_by(|a, b| a.0.cmp(&b.0));
    let mut s = format!(
        "{method}{path}?Authorization=&Seq={seq}&X-Auth-Key={AUTH_KEY}&X-Auth-Nonce={nonce}&X-Auth-TimeStamp={ts}"
    );
    for (k, v) in &all {
        s.push('&');
        s.push_str(k);
        s.push('=');
        s.push_str(v);
    }
    let mac = hmac_sha1(HMAC_KEY.as_bytes(), s.as_bytes());
    urlenc(&base64::engine::general_purpose::STANDARD.encode(mac))
}

fn query_string(params: &[(String, String)]) -> String {
    let mut sorted = params.to_vec();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    sorted
        .iter()
        .map(|(k, v)| format!("{}={}", urlenc(k), urlenc(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn sorted_params(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = pairs
        .iter()
        .map(|(k, val)| (k.to_string(), val.to_string()))
        .collect();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v
}

async fn call(
    method: &str,
    path: &str,
    params: &[(String, String)],
    json_body: Option<&Value>,
) -> ApiResult<Value> {
    let mut last_err = String::new();
    for base in BASES {
        let (nonce, ts, seq) = {
            let seq = SEQ.lock().unwrap().clone();
            (rand::random::<u32>() % 10000, now_ms().to_string(), seq)
        };
        let nonce = nonce.to_string();
        let sig = sign(method, path, params, &nonce, &ts, &seq);
        let qs = query_string(params);
        let url = if qs.is_empty() {
            format!("{base}{path}")
        } else {
            format!("{base}{path}?{qs}")
        };
        let req = match client() {
            Ok(c) => {
                let mut r = if method == "POST" {
                    c.post(&url)
                } else {
                    c.get(&url)
                };
                r = r
                    .header("release", "410")
                    .header("origin", ORIGIN)
                    .header("seq", seq.clone())
                    .header("x-auth-key", AUTH_KEY)
                    .header("pkg", "cuke0001")
                    .header("terminal", "4")
                    .header("x-auth-nonce", nonce.clone())
                    .header("x-auth-sign", sig)
                    .header("x-auth-timestamp", ts.clone())
                    .header("User-Agent", UA);
                if let Some(body) = json_body {
                    r = r
                        .header("Content-Type", "application/json; charset=utf-8")
                        .body(body.to_string());
                }
                r
            }
            Err(e) => {
                last_err = format!("{e}");
                continue;
            }
        };
        let resp = match req.send().await {
            Ok(r) => r,
            Err(e) => {
                last_err = format!("http {e}");
                continue;
            }
        };
        if let Some(new_seq) = resp.headers().get("seq").and_then(|v| v.to_str().ok()) {
            if !new_seq.is_empty() {
                *SEQ.lock().unwrap() = new_seq.to_string();
            }
        }
        if !resp.status().is_success() {
            last_err = format!("http {}", resp.status());
            continue;
        }
        let Ok(text) = resp.text().await else {
            last_err = "empty body".to_string();
            continue;
        };
        let mut v: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                last_err = format!("json {e}");
                continue;
            }
        };
        let enc = text_of(&v, &["encryptedData"]);
        if !enc.is_empty() && enc != "----" {
            if let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(enc.as_bytes()) {
                if let Some(plain) = aes_ecb_decrypt(&raw, AES_KEY) {
                    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
                    let s = String::from_utf8_lossy(unpadded).trim().to_string();
                    if s.starts_with('[') {
                        if let Ok(arr) = serde_json::from_str::<Value>(&s) {
                            if let Some(o) = v.as_object_mut() {
                                o.insert("dataArr".to_string(), arr);
                                o.remove("data");
                            }
                        }
                    } else if let Ok(obj) = serde_json::from_str::<Value>(&s) {
                        if let Some(o) = v.as_object_mut() {
                            o.insert("data".to_string(), obj);
                        }
                    }
                }
            }
        }
        if int_of(&v, &["code"]) == 0 {
            return Ok(v);
        }
        last_err = format!("code {} {}", int_of(&v, &["code"]), text_of(&v, &["msg"]));
    }
    Err(ApiError::Internal(format!(
        "cucumber no base worked: {last_err}"
    )))
}

fn data_list(resp: &Value) -> Vec<Value> {
    if let Some(arr) = arr_of(get(resp, "data").unwrap_or(&Value::Null)) {
        return arr.clone();
    }
    if let Some(arr) = arr_of(get(resp, "dataArr").unwrap_or(&Value::Null)) {
        return arr.clone();
    }
    Vec::new()
}

fn page_info(resp: &Value) -> i64 {
    int_of(resp, &["pageCount"])
}

// ============ 图片 / 卡片 ============

fn img(url: &str) -> String {
    if url.is_empty() {
        return String::new();
    }
    format!("{IMG_WORKER}/img?u={}", urlenc(url))
}

fn cover(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    if s.starts_with("http") {
        return img(s);
    }
    if let Some(rest) = s.strip_prefix("img") {
        let _ = rest;
        return img(&format!("{IMG_PREFIX}{s}"));
    }
    if s.starts_with("/jqn") || s.starts_with("/yvn") {
        return img(&format!("{SEKIRO}{s}"));
    }
    let s = if s.starts_with('/') {
        s.to_string()
    } else {
        format!("/{s}")
    };
    img(&format!("{AES_COVER}{s}"))
}

fn pic(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    if s.starts_with("http") {
        return img(s);
    }
    let s = if s.starts_with('/') {
        s.to_string()
    } else {
        format!("/{s}")
    };
    img(&format!("{}{}", PIC_HOST, &s[1..]))
}

fn video_id(v: &Value) -> String {
    let id = text_of(v, &["movId"]);
    if !id.is_empty() {
        return id;
    }
    text_of(v, &["id"])
}

fn video_title(v: &Value) -> String {
    let t = text_of(v, &["movName"]);
    if !t.is_empty() {
        return t;
    }
    text_of(v, &["name"])
}

fn video_cover(v: &Value) -> String {
    if let Some(c) = get(v, "cover") {
        if let Some(s) = c.as_str() {
            let s = s.trim();
            if s.starts_with('{') {
                if let Ok(obj) = serde_json::from_str::<Value>(s) {
                    let h = text_of(&obj, &["horizontal_large"]);
                    if !h.is_empty() {
                        return cover(&h);
                    }
                }
            }
            if !s.is_empty() {
                return cover(s);
            }
        } else if let Some(o) = c.as_object() {
            let h = o
                .get("horizontal_large")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            if !h.is_empty() {
                return cover(h);
            }
        }
    }
    if let Some(o) = get(v, "allCovers").and_then(|x| x.as_object()) {
        let h = o
            .get("horizontal_large")
            .and_then(|x| x.as_str())
            .unwrap_or("");
        if !h.is_empty() {
            return cover(h);
        }
    }
    if let Some(o) = get(v, "url").and_then(|x| x.as_object()) {
        let h = o
            .get("horizontal_large")
            .and_then(|x| x.as_str())
            .unwrap_or("");
        if !h.is_empty() {
            return cover(h);
        }
    }
    String::new()
}

fn video_desc(v: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    let desc = text_of(v, &["movDesc"]);
    if !desc.is_empty() {
        parts.push(desc);
    }
    let tags = arr_of(get(v, "tags").unwrap_or(&Value::Null))
        .map(|a| {
            a.iter()
                .map(|t| text_of(t, &["name"]))
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !tags.is_empty() {
        parts.push(tags.join(" / "));
    }
    if parts.is_empty() {
        let rel = arr_of(get(v, "relTagName").unwrap_or(&Value::Null))
            .map(|a| {
                a.iter()
                    .map(|t| text_of(t, &["name"]))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if !rel.is_empty() {
            parts.push(rel.join(" / "));
        }
    }
    parts.join("\n")
}

fn is_paid(v: &Value) -> bool {
    get(v, "vipFlag").and_then(|x| x.as_f64()).unwrap_or(0.0) != 0.0
        || get(v, "isLimit").and_then(|x| x.as_f64()).unwrap_or(0.0) != 0.0
}

fn card(v: &Value, tag: &str) -> Option<Value> {
    let id = video_id(v);
    let title = video_title(v);
    if id.is_empty() || title.is_empty() || is_paid(v) {
        return None;
    }
    let mut remark = text_of(v, &["mins"]);
    if remark.is_empty() {
        remark = text_of(v, &["movScore"]);
    }
    if remark.is_empty() {
        let cnt = text_of(v, &["strPlayCnt"]);
        if !cnt.is_empty() {
            remark = format!("{cnt}播放");
        }
    }
    let mut it = item_json(&id, &title, &video_cover(v), &remark);
    it["tag"] = json!(tag);
    it["content"] = json!(video_desc(v));
    Some(it)
}

fn cards(arr: &[Value], tag: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for v in arr {
        if let Some(c) = card(v, tag) {
            let key = format!("{}/{}", text_of(v, &["movId"]), text_of(v, &["id"]));
            if seen.insert(key) {
                out.push(c);
            }
        }
    }
    out
}

fn actor_card(v: &Value, id_key: &str, name_keys: &[&str]) -> Option<Value> {
    let id = text_of(v, &[id_key]);
    let name = text_of(v, name_keys);
    if id.is_empty() || name.is_empty() {
        return None;
    }
    let mut it = item_json(
        &format!("dir:actor:{id}"),
        &name,
        &pic(&text_of(v, &["photoUrl"])),
        &text_of(v, &["nameEn"]),
    );
    it["tag"] = json!("女优");
    it["content"] = json!(text_of(v, &["briefIntroduction"]));
    Some(it)
}

// ============ 频道 / 分类 ============

async fn channels() -> Vec<[String; 4]> {
    {
        let guard = CHAN_CACHE.lock().unwrap();
        if let Some(at) = guard.1 {
            if at.elapsed() < Duration::from_secs(1800) && !guard.0.is_empty() {
                return guard.0.clone();
            }
        }
    }
    let mut list: Vec<[String; 4]> = Vec::new();
    if let Ok(resp) = call("GET", "/home/defaultchannels", &[], None).await {
        for v in data_list(&resp) {
            let m = int_of(&v, &["parentModule"]);
            let name = text_of(&v, &["name"]);
            if m != 0 && !name.is_empty() {
                let t = int_of(&v, &["channelType"]);
                let sel = if get(&v, "hasSelection")
                    .and_then(|b| b.as_bool())
                    .unwrap_or(false)
                {
                    "1"
                } else {
                    "0"
                };
                list.push([m.to_string(), t.to_string(), sel.to_string(), name]);
            }
        }
    }
    if list.is_empty() {
        list = FALLBACK_CHANNELS
            .iter()
            .map(|(a, b, c, d)| [a.to_string(), b.to_string(), c.to_string(), d.to_string()])
            .collect();
    }
    *CHAN_CACHE.lock().unwrap() = (list.clone(), Some(Instant::now()));
    list
}

async fn classes() -> Vec<Value> {
    let mut out: Vec<Value> = vec![category_json("choice", "精选")];
    for ch in channels().await {
        out.push(category_json(
            &format!("ch:{}:{}:{}", ch[0], ch[1], ch[2]),
            &ch[3],
        ));
    }
    out.push(category_json("col", "专栏"));
    for (code, name) in [
        ("viewmov", "观影榜"),
        ("newmov", "新片榜"),
        ("lusir", "撸sir榜"),
        ("tucao", "吐槽榜"),
    ] {
        for (p, pname) in [("1", "日榜"), ("2", "周榜"), ("3", "月榜")] {
            out.push(category_json(
                &format!("rank:{code}:{p}"),
                &format!("{name}·{pname}"),
            ));
        }
    }
    for (p, pname) in [("1", "日榜"), ("2", "周榜"), ("3", "月榜")] {
        out.push(category_json(
            &format!("rank:actors:{p}"),
            &format!("女优榜·{pname}"),
        ));
    }
    out.push(category_json("actor", "女优"));
    out.push(category_json("short:Time", "短剧·最新"));
    out.push(category_json("short:Play", "短剧·最热"));
    out
}

// ============ 列表 ============

/// dex 的 `listFor` 本体。
async fn list_for(id: &str, page: i64) -> ApiResult<Vec<Value>> {
    if id.is_empty() || id == "choice" {
        if page != 1 {
            return Ok(Vec::new());
        }
        let resp = call("GET", "/home/selection/query", &[], None).await?;
        let mut out = Vec::new();
        for g in data_list(&resp) {
            let name = text_of(&g, &["name"]);
            let name = if name.is_empty() {
                "精选".to_string()
            } else {
                name
            };
            if let Some(arr) = arr_of(get(&g, "movList").unwrap_or(&Value::Null)) {
                out.extend(cards(arr, &name));
            }
        }
        return Ok(out);
    }
    if let Some(rest) = id.strip_prefix("ch:") {
        let parts: Vec<&str> = id.split(':').collect();
        if parts.len() != 4 {
            return Ok(Vec::new());
        }
        let (m, t, sel) = (parts[1], parts[2], parts[3]);
        let _ = rest;
        if sel == "1" {
            if page != 1 {
                return Ok(Vec::new());
            }
            let resp = call(
                "GET",
                "/home/selection/query2",
                &sorted_params(&[("moduleId", m)]),
                None,
            )
            .await?;
            let mut out = Vec::new();
            for g in data_list(&resp) {
                let name = text_of(&g, &["name"]);
                let name = if name.is_empty() {
                    "精选".to_string()
                } else {
                    name
                };
                if let Some(arr) = arr_of(get(&g, "movList").unwrap_or(&Value::Null)) {
                    out.extend(cards(arr, &name));
                }
            }
            return Ok(out);
        }
        let params = sorted_params(&[
            ("pageNo", &page.to_string()),
            ("pageSize", "12"),
            ("selectionType", t),
            ("moduleId", m),
        ]);
        let body = json!({
            "pageNo": page.to_string(), "pageSize": "12",
            "selectionType": t, "moduleId": m,
        });
        let resp = call("POST", "/home/movlist", &params, Some(&body)).await?;
        return Ok(cards(&data_list(&resp), ""));
    }
    if id == "col" {
        if page != 1 {
            return Ok(Vec::new());
        }
        let resp = call("GET", "/module/list", &[], None).await?;
        let mut out = Vec::new();
        for m in data_list(&resp) {
            let mod_name = text_of(&m, &["modName"]);
            if let Some(subs) = arr_of(get(&m, "subclass").unwrap_or(&Value::Null)) {
                for s in subs {
                    let nav_id = text_of(s, &["navId"]);
                    let nav_cls = text_of(s, &["navCls"]);
                    let nav_name = text_of(s, &["navName"]);
                    if nav_id.is_empty() || nav_name.is_empty() {
                        continue;
                    }
                    let mut it = item_json(
                        &format!("dir:nav:{nav_id}:{nav_cls}"),
                        &nav_name,
                        &pic(&text_of(s, &["navImage"])),
                        &mod_name,
                    );
                    it["tag"] = json!("专栏");
                    it["content"] = json!(text_of(s, &["intro"]));
                    out.push(it);
                }
            }
        }
        return Ok(out);
    }
    if let Some(rest) = id.strip_prefix("dir:nav:") {
        let parts: Vec<&str> = rest.split(':').collect();
        if parts.len() != 2 {
            return Ok(Vec::new());
        }
        let (nav_id, nav_cls) = (parts[0], parts[1]);
        let params = sorted_params(&[
            ("pageNo", &page.to_string()),
            ("pageSize", "12"),
            ("navId", nav_id),
            ("navCls", nav_cls),
        ]);
        let body = json!({
            "pageNo": page,
            "pageSize": 12,
            "navId": nav_id.parse::<i64>().unwrap_or(0),
            "navCls": nav_cls.parse::<i64>().unwrap_or(0),
        });
        let resp = call("POST", "/module/movlist2", &params, Some(&body)).await?;
        return Ok(cards(&data_list(&resp), ""));
    }
    if let Some(rest) = id.strip_prefix("rank:") {
        let parts: Vec<&str> = id.split(':').collect();
        if parts.len() != 3 {
            return Ok(Vec::new());
        }
        let (kind, period) = (parts[1], parts[2]);
        let _ = rest;
        if kind == "actors" {
            let params = sorted_params(&[
                ("pageNo", &page.to_string()),
                ("pageSize", "30"),
                ("type", period),
            ]);
            let resp = call("GET", "/ranking/actors", &params, None).await?;
            let mut out = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for v in data_list(&resp) {
                let aid = text_of(&v, &["actorsId"]);
                let aid = if aid.is_empty() {
                    text_of(&v, &["id"])
                } else {
                    aid
                };
                let name = text_of(&v, &["nameCn"]);
                let name = if name.is_empty() {
                    text_of(&v, &["name"])
                } else {
                    name
                };
                if aid.is_empty() || name.is_empty() || !seen.insert(aid.clone()) {
                    continue;
                }
                let cup = text_of(&v, &["cup"]);
                let num = text_of(&v, &["movNumber"]);
                let mut remark = String::new();
                if !cup.is_empty() {
                    remark.push_str(&format!("{cup}杯 "));
                }
                if !num.is_empty() {
                    remark.push_str(&format!("{num}部"));
                }
                let mut it = item_json(
                    &format!("dir:actor:{aid}"),
                    &name,
                    &pic(&text_of(&v, &["photoUrl"])),
                    remark.trim(),
                );
                it["tag"] = json!("女优");
                it["content"] = json!(text_of(&v, &["briefIntroduction"]));
                out.push(it);
            }
            return Ok(out);
        }
        let params = sorted_params(&[
            ("pageNo", &page.to_string()),
            ("pageSize", "30"),
            ("type", period),
        ]);
        let resp = call("GET", &format!("/ranking/{kind}"), &params, None).await?;
        return Ok(cards(&data_list(&resp), ""));
    }
    if id == "actor" {
        let params = sorted_params(&[
            ("queryType", "1"),
            ("cupType", "0"),
            ("pageNo", &page.to_string()),
            ("pageSize", "21"),
        ]);
        let resp = call("GET", "/home/actor/list", &params, None).await?;
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for v in data_list(&resp) {
            let aid = text_of(&v, &["id"]);
            let name = text_of(&v, &["nameCn"]);
            if aid.is_empty() || name.is_empty() || !seen.insert(aid.clone()) {
                continue;
            }
            let mut remark = text_of(&v, &["nameEn"]);
            let cup = text_of(&v, &["cup"]);
            if !cup.is_empty() {
                remark = format!("{cup}杯");
            }
            let mut it = item_json(
                &format!("dir:actor:{aid}"),
                &name,
                &pic(&text_of(&v, &["photoUrl"])),
                &remark,
            );
            it["tag"] = json!("女优");
            it["content"] = json!(text_of(&v, &["briefIntroduction"]));
            out.push(it);
        }
        return Ok(out);
    }
    if let Some(aid) = id.strip_prefix("dir:actor:") {
        let params = sorted_params(&[
            ("id", aid),
            ("pageNo", &page.to_string()),
            ("queryType", "1"),
            ("pageSize", "12"),
        ]);
        let resp = call("GET", "/actor/movie/list", &params, None).await?;
        return Ok(cards(&data_list(&resp), ""));
    }
    if let Some(order) = id.strip_prefix("short:") {
        let params = sorted_params(&[("pageNo", &page.to_string())]);
        let resp = call(
            "GET",
            &format!("/shortvideo/listOrderBy{order}"),
            &params,
            None,
        )
        .await?;
        let mut out = Vec::new();
        for v in data_list(&resp) {
            let vid = text_of(&v, &["videoId"]);
            let title = text_of(&v, &["videoTitle"]);
            if vid.is_empty() || title.is_empty() || is_paid(&v) {
                continue;
            }
            let mut it = item_json(
                &vid,
                &title,
                &cover(&text_of(&v, &["cover"])),
                &text_of(&v, &["mins"]),
            );
            it["tag"] = json!("短剧");
            it["content"] = json!(text_of(&v, &["movDesc"]));
            out.push(it);
        }
        return Ok(out);
    }
    Ok(Vec::new())
}

/// dex 的 `listForPc`：返回（列表，lastPc）。
async fn list_for_pc(id: &str, page: i64) -> ApiResult<(Vec<Value>, i64)> {
    if id.is_empty() || id == "choice" {
        let items = list_for(id, page).await?;
        return Ok((items, page));
    }
    if id.starts_with("ch:") {
        let parts: Vec<&str> = id.split(':').collect();
        if parts.len() == 4 && parts[3] != "1" {
            let params = sorted_params(&[
                ("pageNo", &page.to_string()),
                ("pageSize", "12"),
                ("selectionType", parts[2]),
                ("moduleId", parts[1]),
            ]);
            let body = json!({
                "pageNo": page.to_string(), "pageSize": "12",
                "selectionType": parts[2], "moduleId": parts[1],
            });
            let resp = call("POST", "/home/movlist", &params, Some(&body)).await?;
            let last_pc = page_info(&resp);
            return Ok((cards(&data_list(&resp), ""), last_pc));
        }
    }
    if id.starts_with("dir:nav:") {
        let parts: Vec<&str> = id.split(':').collect();
        if parts.len() == 4 {
            let params = sorted_params(&[
                ("pageNo", &page.to_string()),
                ("pageSize", "12"),
                ("navId", parts[2]),
                ("navCls", parts[3]),
            ]);
            let body = json!({
                "pageNo": page,
                "pageSize": 12,
                "navId": parts[2].parse::<i64>().unwrap_or(0),
                "navCls": parts[3].parse::<i64>().unwrap_or(0),
            });
            let resp = call("POST", "/module/movlist2", &params, Some(&body)).await?;
            let last_pc = page_info(&resp);
            return Ok((cards(&data_list(&resp), ""), last_pc));
        }
        let items = list_for(id, page).await?;
        return Ok((items, page));
    }
    if id == "actor" {
        let params = sorted_params(&[
            ("queryType", "1"),
            ("cupType", "0"),
            ("pageNo", &page.to_string()),
            ("pageSize", "21"),
        ]);
        let resp = call("GET", "/home/actor/list", &params, None).await?;
        let last_pc = page_info(&resp);
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for v in data_list(&resp) {
            let aid = text_of(&v, &["id"]);
            let name = text_of(&v, &["nameCn"]);
            if aid.is_empty() || name.is_empty() || !seen.insert(aid.clone()) {
                continue;
            }
            let mut remark = text_of(&v, &["nameEn"]);
            let cup = text_of(&v, &["cup"]);
            if !cup.is_empty() {
                remark = format!("{cup}杯");
            }
            let mut it = item_json(
                &format!("dir:actor:{aid}"),
                &name,
                &pic(&text_of(&v, &["photoUrl"])),
                &remark,
            );
            it["tag"] = json!("女优");
            it["content"] = json!(text_of(&v, &["briefIntroduction"]));
            out.push(it);
        }
        return Ok((out, last_pc));
    }
    if id.starts_with("dir:actor:") {
        let aid = id.strip_prefix("dir:actor:").unwrap_or("");
        let params = sorted_params(&[
            ("id", aid),
            ("pageNo", &page.to_string()),
            ("queryType", "1"),
            ("pageSize", "12"),
        ]);
        let resp = call("GET", "/actor/movie/list", &params, None).await?;
        let last_pc = page_info(&resp);
        return Ok((cards(&data_list(&resp), ""), last_pc));
    }
    let items = list_for(id, page).await?;
    Ok((items, page))
}

fn pagecount_for(id: &str, page: i64, last_pc: i64, len: i64) -> i64 {
    if id.is_empty() || id == "choice" || id == "col" {
        return page;
    }
    if !id.starts_with("ch:") {
        if id.starts_with("dir:nav:") || id == "actor" || id.starts_with("dir:actor:") {
            return if last_pc > 0 { last_pc } else { page };
        }
        if id.starts_with("rank:") {
            if !id.starts_with("rank:actors:") && len >= 30 {
                return page + 1;
            }
            return page;
        }
        if !id.starts_with("short:") || len <= 0 {
            return page;
        }
        return page + 1;
    }
    let parts: Vec<&str> = id.split(':').collect();
    if parts.len() == 4 && parts[3] == "1" {
        return page;
    }
    if last_pc == 0 {
        if len > 0 {
            return page + 1;
        }
        return page;
    }
    last_pc
}

// ============ 详情 / 搜索 / 取流 ============

async fn browse(id: &str) -> ApiResult<Value> {
    let id = match id.find('$') {
        Some(pos) => &id[pos + 1..],
        None => id,
    };
    let params = sorted_params(&[("movId", id)]);
    let resp = call("GET", "/mov/browse2", &params, None).await?;
    let list = data_list(&resp);
    list.into_iter()
        .next()
        .ok_or_else(|| ApiError::Internal("cucumber video not found".into()))
}

fn address(v: &Value) -> String {
    let Some(addr) = get(v, "address").and_then(|a| a.as_object()) else {
        return String::new();
    };
    for key in ["1080P", "720P", "480P", "360P", "240P"] {
        let s = addr
            .get(key)
            .map(|x| x.as_str().unwrap_or("").to_string())
            .unwrap_or_default();
        if !s.is_empty() {
            return s;
        }
    }
    String::new()
}

async fn playlist_ok(url: &str) -> bool {
    let Ok(resp) = client().map(|c| {
        c.get(url)
            .header("User-Agent", UA)
            .header("Referer", format!("{ORIGIN}/"))
    }) else {
        return false;
    };
    let Ok(resp) = resp.send().await else {
        return false;
    };
    let Ok(bytes) = resp.bytes().await else {
        return false;
    };
    let head = &bytes[..bytes.len().min(65536)];
    String::from_utf8_lossy(head).contains("#EXTM3U")
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": classes().await}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let (items, last_pc) = match list_for_pc(category_id, page).await {
        Ok(v) => v,
        Err(_) => (Vec::new(), page),
    };
    let pagecount = pagecount_for(category_id, page, last_pc, items.len() as i64);
    Ok(json!({"items": items, "has_more": page < pagecount}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(aid) = id.strip_prefix("dir:actor:") {
        let params = sorted_params(&[("id", aid)]);
        let resp = call("GET", "/home/actor/detail", &params, None).await?;
        let first = data_list(&resp).into_iter().next().unwrap_or(Value::Null);
        let name = text_of(&first, &["nameCn"]);
        let name = if name.is_empty() {
            text_of(&first, &["name"])
        } else {
            name
        };
        let title = if name.is_empty() {
            id.to_string()
        } else {
            name.clone()
        };
        let cup = text_of(&first, &["cup"]);
        let content = format!(
            "{}\n身高：{} cm 三围：{}-{}-{} cm 罩杯：{}",
            text_of(&first, &["briefIntroduction"]),
            text_of(&first, &["height"]),
            text_of(&first, &["bust"]),
            text_of(&first, &["waist"]),
            text_of(&first, &["hips"]),
            cup
        );
        let params2 = sorted_params(&[
            ("id", aid),
            ("pageNo", "1"),
            ("queryType", "1"),
            ("pageSize", "12"),
        ]);
        let resp2 = call("GET", "/actor/movie/list", &params2, None).await?;
        let mut episodes: Vec<Value> = Vec::new();
        for c in cards(&data_list(&resp2), "") {
            let vid = c["id"].as_str().unwrap_or("").to_string();
            let t = c["title"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&vid, &t, id));
        }
        return Ok(json!({
            "id": id, "title": title,
            "cover": pic(&text_of(&first, &["photoUrl"])),
            "synopsis": content,
            "extra": {"vod_actor": name, "vod_tag": "女优"},
            "episodes": episodes,
        }));
    }
    if id.starts_with("dir:nav:") {
        let parts: Vec<&str> = id.split(':').collect();
        let nav_id = if parts.len() > 2 { parts[2] } else { id };
        let params = sorted_params(&[("navId", nav_id)]);
        let resp = call("GET", "/module/nav", &params, None).await?;
        let first = data_list(&resp).into_iter().next().unwrap_or(Value::Null);
        let name = text_of(&first, &["navName"]);
        let name = if name.is_empty() {
            nav_id.to_string()
        } else {
            name
        };
        let items = list_for(id, 1).await.unwrap_or_default();
        let mut episodes: Vec<Value> = Vec::new();
        for c in &items {
            let vid = c["id"].as_str().unwrap_or("").to_string();
            let t = c["title"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&vid, &t, id));
        }
        return Ok(json!({
            "id": id, "title": name,
            "cover": pic(&text_of(&first, &["photoAddr"])),
            "synopsis": text_of(&first, &["intro"]),
            "extra": {"vod_tag": "专栏"},
            "episodes": episodes,
        }));
    }
    let obj = match browse(id).await {
        Ok(o) => o,
        Err(_) => {
            return Ok(
                json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}),
            );
        }
    };
    let mut title = video_title(&obj);
    if title.is_empty() {
        title = format!("视频{id}");
    }
    let mut synopsis = video_desc(&obj);
    let remarks = format!(
        "{} | {} | {} | {}",
        text_of(&obj, &["movScore"]),
        text_of(&obj, &["strPlayCnt"]),
        text_of(&obj, &["gmtCreate"]),
        text_of(&obj, &["movSnOri"])
    );
    if !synopsis.is_empty() {
        synopsis.push('\n');
    }
    synopsis.push_str(&remarks);
    // jar bug 修复：actorList 元素先试 `actor` 再试 `name`（jar 原文取
    // 键为 `"vod_play_url"`，恒为空）；再回退 `obj.actor` 字符串。
    let mut actors: Vec<String> = Vec::new();
    if let Some(arr) = arr_of(get(&obj, "actorList").unwrap_or(&Value::Null)) {
        for a in arr {
            let mut n = text_of(a, &["actor"]);
            if n.is_empty() {
                n = text_of(a, &["name"]);
            }
            if !n.is_empty() {
                actors.push(n);
            }
        }
    }
    if actors.is_empty() {
        let s = text_of(&obj, &["actor"]);
        if !s.is_empty() {
            actors.push(s);
        }
    }
    let actor_str = actors.join(", ");
    let mut extra = json!({"vod_actor": actor_str, "actor": actor_str});
    let director = text_of(&obj, &["director"]);
    if !director.is_empty() {
        extra["director"] = json!(director);
    }
    Ok(json!({
        "id": id, "title": title,
        "cover": video_cover(&obj),
        "synopsis": synopsis,
        "extra": extra,
        "episodes": [episode_json(&video_id(&obj), "正片", id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let params = sorted_params(&[("q", query), ("pageNo", "1"), ("pageSize", "10")]);
    let resp = match call("GET", "/es/mov/search", &params, None).await {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": []})),
    };
    Ok(json!({"items": cards(&data_list(&resp), "搜索")}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let id = match video_id.find('$') {
        Some(pos) => &video_id[pos + 1..],
        None => video_id,
    };
    let obj = browse(id).await?;
    // jar 字面为“付费才取流”，与 card 剔付费矛盾；此处按修复取反：
    // 免费才取流（待探针确认）。
    if is_paid(&obj) {
        return Err(ApiError::Internal("cucumber paid video refused".into()));
    }
    let addr = address(&obj);
    if addr.is_empty() {
        return Err(ApiError::Internal("cucumber no address".into()));
    }
    let url = if addr.starts_with("http") {
        addr.clone()
    } else {
        let p = if addr.starts_with('/') {
            format!("/{addr}")
        } else {
            addr.clone()
        };
        let stream_url = format!("{STREAM}{p}");
        if playlist_ok(&stream_url).await {
            let fb_url = format!("{STREAM_FB}{p}");
            if playlist_ok(&fb_url).await {
                fb_url
            } else {
                stream_url
            }
        } else {
            stream_url
        }
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{STREAM}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_known() {
        assert_eq!(
            hex::encode(sha1(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert_eq!(
            hex::encode(sha1(b"")),
            "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        );
    }

    #[test]
    fn hmac_sha1_known() {
        // RFC 2202 case 2: key "Jefe", data "what do ya want for nothing?"
        assert_eq!(
            hex::encode(hmac_sha1(b"Jefe", b"what do ya want for nothing?")),
            "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"
        );
    }

    #[test]
    fn address_order() {
        let v: Value =
            serde_json::from_str(r#"{"address":{"240P":"low","720P":"mid","1080P":"high"}}"#)
                .unwrap();
        assert_eq!(address(&v), "high");
    }

    #[test]
    fn is_paid_flags() {
        let v: Value = serde_json::from_str(r#"{"vipFlag":0,"isLimit":1}"#).unwrap();
        assert!(is_paid(&v));
        let v2: Value = serde_json::from_str(r#"{"vipFlag":0,"isLimit":0}"#).unwrap();
        assert!(!is_paid(&v2));
    }

    #[test]
    fn pagecount_for_choice() {
        assert_eq!(pagecount_for("choice", 2, 5, 10), 2);
        assert_eq!(pagecount_for("rank:viewmov:1", 1, 0, 30), 2);
        assert_eq!(pagecount_for("rank:actors:1", 1, 0, 30), 1);
    }
}
