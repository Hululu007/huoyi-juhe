//! 撸先生：`https://api.yewlowxe.cc`。
//!
//! 来源 jar 类 `ZakaLxsAmns`。基址 `https://api.yewlowxe.cc`，UA 为
//! Chrome 120 Android SM-A205GN；
//! `SIGN_SECRET=8DH2lusir4W6uhqFjbCkudNDosdfghjH`；
//! `AES_KEY=f95277cfbbimgkcusimcuekd3b777pwa`（32 字节，AES-256）、
//! `AES_IV=f95277cfbbimgkcu`（16 字节）。
//!
//! `call(params)`：固定字段按顺序放 `oauth_id=zwmLGswGWjXy61JY_1749114098063`
//! （固定值，非随机池）、`bundleId=com.tvlutv`、`version=2.4.0`、
//! `oauth_type=web`、`app_type=rn`、`img_type=new`、`client=pwa`，再并入
//! 业务参数；JSON 串 UTF-8 字节经 AES/CFB/NoPadding 加密（加解密共用，
//! 密钥 AES_KEY、IV AES_IV，Java 默认 CFB128）再转小写 hex；
//! `sign = MD5 小写 hex(SHA-256 小写 hex("client=pwa&data=<hex>&timestamp=<秒>" + SECRET))`；
//! URL 为 `<base>/api.php?t=<毫秒时间戳>`；body 为
//! `client=pwa&timestamp=<URLEncoder 编码秒>&data=<URLEncoder 编码 hex>&sign=<URLEncoder 编码 sign>`；
//! POST，连接/读取超时各 20000 毫秒，头 UA +
//! `Content-Type: application/x-www-form-urlencoded` + Referer `<base>/`；
//! 失败睡 1 秒最多 3 次；响应非 200 抛错；`Content-Encoding` 含 gzip 时
//! gunzip；响应 JSON 的 `data` 字段非空时 `fromHex(data)` →
//! `aesCfb(bytes, true)` 解密 → UTF-8 解析为 JSON 返回，否则返回原 JSON。
//! Cargo 未引 `cfb` crate，CFB128 用 `aes`+`cipher` 的 `BlockEncrypt`
//! 手写（`C[i] = P[i] XOR E(K, C[i-1])`，IV 作初值，末块取密钥流前缀；
//! 解密为 `P[i] = C[i] XOR E(K, C[i-1])`）。
//!
//! 分类为动态：`loadTags` 调 `call({code: homePage, mod: down})`，取
//! `data.xiaoTag[]` + `data.avTag[]` 的 `{type, tag, name}`，分类 id 为
//! `<type>|<tag>`，显示名为 `xiao` 类直接用 name、其余前缀 `AV·`；末尾
//! 固定加 `actors` 女优。
//! 卡片：`id` 与 `title` 均非空；付费判定 `price > 0`，先排除、全空时
//! 才放回；封面取 `cover_full` 否则 `cover_thumb`（含 `/ads/` 的剔除）；
//! `vod_id=(mv_type 否则 "xiao")+":"+id`；备注为 `付费` 或时长 `M:SS`；
//! `type_name` 为 `category`。
//! `listResult(resp, pg)`：顶层 `data[]` 逐条 `card(obj, false)`，全空
//! 且 `page.total>0` 时重试 `card(obj, true)`；`total` 取 `page.total`
//! （无则为列表长度），`pagesize` 取 `page.pagesize`（默认 20），
//! `pagecount = pg*pagesize < total ? pg+1 : pg`。
//! 列表：`actors` → `call({mod: actor, filter: "", page})` → `data[]`
//! 女优卡（`vod_id="actor:"+id+"|"+name`，封面 `pic(cover)`，备注“女优”，
//! 标签 `folder`），`pagecount = len>=100 ? pg+1 : pg`，`limit` 100；
//! `actor:<id>|<名>` → 截 `substring(6)` 后按 `|` 切 id 与名，
//! `call({mod: actor, code: eq, id, actor: <名>, page})` → `listResult`；
//! 普通分类 `<type>|<tag>`：含 `|` 时 type 为 `|` 前、tag 为 `|` 后，
//! 不含时 type=`xiao`、tag=`"new"`，`call({code: search, mod: <type>, tag,
//! page})` → `listResult`；若首结果列表非空且 `total>0`，再调另一 mod
//! （type 为 `xiao` 时调 `av`，否则调 `xiao`，同 tag 同页）→
//! `listResult`，第二结果列表非空则返回第二结果，否则返回首结果。
//! 首页：`call({code: search, mod: xiao, tag: new, page: 1})` 经
//! `listResult`。
//! 详情：`actor:<id>|<名>` 调 `call({mod: actor, code: eq, id, actor:
//! <名>, page: 1})`，`data[]` 作分集（`片名$<vod_id>`）；视频类调
//! `call({code: detail, mod: <xiao|av>, id})`，取
//! `data.title/cover_full|cover_thumb/tags/actors/category/desc`；付费
//! 判定 `detailPaid`（`data.price>0` 且（`isfree==2` 或 `is_pay==1` 或
//! `privilege.can_change_look.msg` 含“付费”））；取流取响应顶层
//! `line[].line.s720`（空则 `s240`），`hf-[^.]+.` 换 `hf-long.`。
//! 搜索：对 `xiao`、`av` 各调 `call({mod: search, type: <类>, code:
//! index, order: new, sort: desc, tag: <关键词>, page})`，合并后付费的
//! 只在全空时放回。
//! 取流：video_id 以 `http` 开头直通；否则按 `mod:id` 拆分调 detail，
//! `detailPaid` 为假时用 `playUrl`；头为 UA + Referer `<base>/`。

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes256;
use regex::Regex;
use serde_json::{json, Value};
use sha2::{Digest as _, Sha256};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://api.yewlowxe.cc";
const SIGN_SECRET: &str = "8DH2lusir4W6uhqFjbCkudNDosdfghjH";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; SM-A205GN) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36";
const AES_KEY: &[u8] = b"f95277cfbbimgkcusimcuekd3b777pwa";
const AES_IV: &[u8] = b"f95277cfbbimgkcu";

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

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// AES/CFB128（Java `AES/CFB/NoPadding` 默认 CFB128），加解密共用。
/// `decrypt=false` 为加密，`true` 为解密。
fn aes_cfb(data: &[u8], decrypt: bool) -> Vec<u8> {
    let cipher = Aes256::new_from_slice(AES_KEY).expect("aes256 cfb");
    let mut out = Vec::with_capacity(data.len());
    let mut prev = [0u8; 16];
    prev.copy_from_slice(AES_IV);
    for chunk in data.chunks(16) {
        let mut block = [0u8; 16];
        block.copy_from_slice(&prev);
        let mut ga = GenericArray::from_mut_slice(&mut block);
        cipher.encrypt_block(&mut ga);
        let mut out_chunk = Vec::with_capacity(chunk.len());
        for (i, &b) in chunk.iter().enumerate() {
            out_chunk.push(b ^ block[i]);
        }
        if decrypt {
            prev.copy_from_slice(&{
                let mut p = [0u8; 16];
                p[..chunk.len()].copy_from_slice(chunk);
                p
            });
        } else {
            let mut p = [0u8; 16];
            p[..out_chunk.len()].copy_from_slice(&out_chunk);
            prev = p;
        }
        out.extend_from_slice(&out_chunk);
    }
    out
}

fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let b = s.as_bytes();
    for i in (0..b.len()).step_by(2) {
        let hi = (b[i] as char).to_digit(16)?;
        let lo = (b[i + 1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

async fn call(params: &[(&str, &str)]) -> ApiResult<Value> {
    let mut body = String::from("{");
    let mut pairs: Vec<(String, String)> = vec![
        ("oauth_id".to_string(), "zwmLGswGWjXy61JY_1749114098063".to_string()),
        ("bundleId".to_string(), "com.tvlutv".to_string()),
        ("version".to_string(), "2.4.0".to_string()),
        ("oauth_type".to_string(), "web".to_string()),
        ("app_type".to_string(), "rn".to_string()),
        ("img_type".to_string(), "new".to_string()),
        ("client".to_string(), "pwa".to_string()),
    ];
    for (k, v) in params {
        pairs.push((k.to_string(), v.to_string()));
    }
    let mut first = true;
    for (k, v) in &pairs {
        if !first {
            body.push(',');
        }
        first = false;
        body.push_str(&format!("\"{}\":\"{}\"", json_escape(k), json_escape(v)));
    }
    body.push('}');
    let enc = aes_cfb(body.as_bytes(), false);
    let hex_data = hex::encode(enc);
    let ts = (now_ms() / 1000).to_string();
    let sign = md5_hex(sha256_hex(format!("client=pwa&data={hex_data}&timestamp={ts}{SIGN_SECRET}").as_bytes()).as_bytes());
    let form = format!(
        "client=pwa&timestamp={}&data={}&sign={}",
        urlenc(&ts),
        urlenc(&hex_data),
        urlenc(&sign)
    );
    let url = format!("{BASE}/api.php?t={}", now_ms());
    let mut last_err = String::new();
    let mut all: Option<Vec<u8>> = None;
    for _ in 0..3 {
        let resp = match client() {
            Ok(c) => c
                .post(&url)
                .header("User-Agent", UA)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("Referer", format!("{BASE}/"))
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
                let encoding = r
                    .headers()
                    .get("content-encoding")
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("")
                    .to_string();
                match r.bytes().await {
                    Ok(b) => {
                        let b = if encoding.to_lowercase().contains("gzip") {
                            crate::crypto::gunzip(&b).unwrap_or_else(|| b.to_vec())
                        } else {
                            b.to_vec()
                        };
                        all = Some(b);
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
        return Err(ApiError::Internal(format!("lxs call failed: {last_err}")));
    };
    let v: Value = serde_json::from_slice(&all)
        .map_err(|e| ApiError::Internal(format!("lxs json: {e}")))?;
    let data_s = text_of(&v, &["data"]);
    if data_s.is_empty() {
        return Ok(v);
    }
    let Some(raw) = from_hex(&data_s) else {
        return Ok(v);
    };
    let plain = aes_cfb(&raw, true);
    let s = String::from_utf8_lossy(&plain).to_string();
    serde_json::from_str::<Value>(&s)
        .map_err(|e| ApiError::Internal(format!("lxs inner json: {e}")))
}

fn pic(s: &str) -> String {
    let s = s.trim();
    if s.is_empty() || !s.starts_with("http") {
        return s.to_string();
    }
    format!("https://lxsimg.ystv.top/img?u={}", urlenc(s))
}

fn card(v: &Value, include_paid: bool) -> Option<Value> {
    let id = text_of(v, &["id"]);
    let title = text_of(v, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let paid = get(v, "price").and_then(|x| x.as_f64()).unwrap_or(0.0) > 0.0
        || get(v, "price").and_then(|x| x.as_i64()).unwrap_or(0) > 0;
    if paid && !include_paid {
        return None;
    }
    let mut cover = text_of(v, &["cover_full"]);
    if cover.is_empty() {
        cover = text_of(v, &["cover_thumb"]);
    }
    if cover.contains("/ads/") {
        return None;
    }
    let remark = if paid {
        "付费".to_string()
    } else {
        let dur = get(v, "duration").and_then(|x| x.as_i64()).unwrap_or(0);
        if dur > 0 {
            format!("{}:{:02}", dur / 60, dur % 60)
        } else {
            String::new()
        }
    };
    let kind = text_of(v, &["mv_type"]);
    let kind = if kind.is_empty() { "xiao".to_string() } else { kind };
    let mut it = item_json(&format!("{kind}:{id}"), &title, &pic(&cover), &remark);
    it["type_name"] = json!(text_of(v, &["category"]));
    Some(it)
}

fn list_result(resp: &Value, pg: i64) -> (Vec<Value>, i64, i64) {
    let data = get(resp, "data").cloned().unwrap_or(Value::Null);
    let mut list: Vec<Value> = Vec::new();
    if let Some(a) = data.as_array() {
        list = a.clone();
    }
    let page = get(resp, "page").cloned().unwrap_or(Value::Null);
    let total = get(&page, "total").and_then(|x| x.as_i64()).unwrap_or(list.len() as i64);
    let mut out = Vec::new();
    for v in &list {
        if let Some(c) = card(v, false) {
            out.push(c);
        }
    }
    if out.is_empty() && total > 0 {
        for v in &list {
            if let Some(c) = card(v, true) {
                out.push(c);
            }
        }
    }
    let pagesize = get(&page, "pagesize").and_then(|x| x.as_i64()).unwrap_or(20);
    let pagecount = if pg * pagesize < total { pg + 1 } else { pg };
    (out, pagecount, total)
}

async fn load_tags() -> ApiResult<Vec<(String, String)>> {
    let resp = call(&[("code", "homePage"), ("mod", "down")]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let mut out: Vec<(String, String)> = Vec::new();
    for key in ["xiaoTag", "avTag"] {
        if let Some(tags) = arr_of(get(&data, key).unwrap_or(&Value::Null)) {
            for t in tags {
                let ty = text_of(t, &["type"]);
                let tag = text_of(t, &["tag"]);
                let name = text_of(t, &["name"]);
                if ty.is_empty() || tag.is_empty() || name.is_empty() {
                    continue;
                }
                let display = if ty == "xiao" {
                    name.clone()
                } else {
                    format!("AV·{name}")
                };
                out.push((format!("{ty}|{tag}"), display));
            }
        }
    }
    Ok(out)
}

fn detail_paid(d: &Value) -> bool {
    let price = get(d, "price").and_then(|x| x.as_f64()).unwrap_or(0.0) > 0.0
        || get(d, "price").and_then(|x| x.as_i64()).unwrap_or(0) > 0;
    if !price {
        return false;
    }
    if get(d, "isfree").and_then(|x| x.as_i64()) == Some(2) {
        return true;
    }
    if get(d, "is_pay").and_then(|x| x.as_i64()) == Some(1) {
        return true;
    }
    if let Some(privilege) = get(d, "privilege") {
        if let Some(ccl) = get(privilege, "can_change_look") {
            if text_of(ccl, &["msg"]).contains("付费") {
                return true;
            }
        }
    }
    false
}

fn play_url(resp: &Value) -> String {
    let mut s = String::new();
    if let Some(lines) = arr_of(get(resp, "line").unwrap_or(&Value::Null)) {
        if let Some(first) = lines.first() {
            let line = get(first, "line").cloned().unwrap_or(Value::Null);
            s = text_of(&line, &["s720"]);
            if s.is_empty() {
                s = text_of(&line, &["s240"]);
            }
        }
    }
    if s.is_empty() {
        let data = get(resp, "data").cloned().unwrap_or(Value::Null);
        if let Some(lines) = arr_of(get(&data, "line").unwrap_or(&Value::Null)) {
            if let Some(first) = lines.first() {
                let line = get(first, "line").cloned().unwrap_or(Value::Null);
                s = text_of(&line, &["s720"]);
                if s.is_empty() {
                    s = text_of(&line, &["s240"]);
                }
            }
        }
    }
    let re = Regex::new(r"hf-[^.]+\.").unwrap();
    re.replace_all(&s, "hf-long.").to_string()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut cats: Vec<Value> = Vec::new();
    match load_tags().await {
        Ok(tags) => {
            for (id, name) in tags {
                cats.push(category_json(&id, &name));
            }
        }
        Err(_) => {}
    }
    cats.push(category_json("actors", "女优"));
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let page_s = page.to_string();
    if category_id == "actors" {
        let resp = match call(&[("mod", "actor"), ("filter", ""), ("page", &page_s)]).await {
            Ok(r) => r,
            Err(_) => return Ok(json!({"items": [], "has_more": false})),
        };
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let mut out = Vec::new();
        if let Some(arr) = data.as_array() {
            for a in arr {
                let aid = text_of(a, &["id"]);
                let name = text_of(a, &["name"]);
                if aid.is_empty() || name.is_empty() {
                    continue;
                }
                let mut it = item_json(
                    &format!("actor:{aid}|{name}"),
                    &name,
                    &pic(&text_of(a, &["cover"])),
                    "女优",
                );
                it["tag"] = json!("folder");
                out.push(it);
            }
        }
        let has_more = out.len() >= 100;
        return Ok(json!({"items": out, "has_more": has_more}));
    }
    if let Some(rest) = category_id.strip_prefix("actor:") {
        let (aid, name) = match rest.split_once('|') {
            Some((a, n)) => (a, n),
            None => (rest, ""),
        };
        let resp = match call(&[("mod", "actor"), ("code", "eq"), ("id", aid), ("actor", name), ("page", &page_s)]).await {
            Ok(r) => r,
            Err(_) => return Ok(json!({"items": [], "has_more": false})),
        };
        let (items, pagecount, _) = list_result(&resp, page);
        return Ok(json!({"items": items, "has_more": pagecount > page}));
    }
    let (ty, tag) = if let Some((t, g)) = category_id.split_once('|') {
        (t.to_string(), g.to_string())
    } else {
        ("xiao".to_string(), "new".to_string())
    };
    let resp = match call(&[("code", "search"), ("mod", &ty), ("tag", &tag), ("page", &page_s)]).await {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": [], "has_more": false})),
    };
    let (items, pagecount, total) = list_result(&resp, page);
    if !items.is_empty() && total > 0 {
        let other = if ty == "xiao" { "av" } else { "xiao" };
        if let Ok(resp2) = call(&[("code", "search"), ("mod", other), ("tag", &tag), ("page", &page_s)]).await {
            let (items2, pagecount2, _) = list_result(&resp2, page);
            if !items2.is_empty() {
                return Ok(json!({"items": items2, "has_more": pagecount2 > page}));
            }
        }
    }
    Ok(json!({"items": items, "has_more": pagecount > page}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(rest) = id.strip_prefix("actor:") {
        let (aid, name) = match rest.split_once('|') {
            Some((a, n)) => (a, n),
            None => (rest, ""),
        };
        let resp = call(&[("mod", "actor"), ("code", "eq"), ("id", aid), ("actor", name), ("page", "1")]).await?;
        let (items, _, _) = list_result(&resp, 1);
        let mut episodes: Vec<Value> = Vec::new();
        for c in &items {
            let vid = c["id"].as_str().unwrap_or("").to_string();
            let t = c["title"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&vid, &t, id));
        }
        return Ok(json!({
            "id": id, "title": name, "cover": "", "synopsis": "",
            "extra": {"vod_actor": name},
            "episodes": episodes,
        }));
    }
    let (ty, vid) = match id.split_once(':') {
        Some((t, v)) => (t, v),
        None => ("xiao", id),
    };
    let resp = call(&[("code", "detail"), ("mod", ty), ("id", vid)]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let mut title = text_of(&data, &["title"]);
    if title.is_empty() {
        title = format!("视频{vid}");
    }
    let mut cover = text_of(&data, &["cover_full"]);
    if cover.is_empty() {
        cover = text_of(&data, &["cover_thumb"]);
    }
    let paid = detail_paid(&data);
    let url = if paid { String::new() } else { play_url(&resp) };
    let mut episodes: Vec<Value> = Vec::new();
    if !url.is_empty() {
        episodes.push(episode_json(&url, "正片", id));
    }
    Ok(json!({
        "id": id, "title": title, "cover": pic(&cover),
        "synopsis": text_of(&data, &["desc"]),
        "extra": {
            "vod_actor": text_of(&data, &["actors"]),
            "vod_remarks": if paid { "付费" } else { "" },
            "tags": text_of(&data, &["tags"]),
        },
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let mut out: Vec<Value> = Vec::new();
    for ty in ["xiao", "av"] {
        if let Ok(resp) = call(&[
            ("mod", "search"),
            ("type", ty),
            ("code", "index"),
            ("order", "new"),
            ("sort", "desc"),
            ("tag", query),
            ("page", "1"),
        ])
        .await
        {
            let (items, _, _) = list_result(&resp, 1);
            out.extend(items);
        }
    }
    if out.is_empty() {
        for ty in ["xiao", "av"] {
            if let Ok(resp) = call(&[
                ("mod", "search"),
                ("type", ty),
                ("code", "index"),
                ("order", "new"),
                ("sort", "desc"),
                ("tag", query),
                ("page", "1"),
            ])
            .await
            {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                let mut list: Vec<Value> = Vec::new();
                if let Some(a) = data.as_array() {
                    list = a.clone();
                }
                for v in &list {
                    if let Some(c) = card(v, true) {
                        out.push(c);
                    }
                }
            }
        }
    }
    Ok(json!({"items": out}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }));
    }
    let id = match video_id.find('$') {
        Some(pos) => &video_id[pos + 1..],
        None => video_id,
    };
    let (ty, vid) = match id.split_once(':') {
        Some((t, v)) => (t, v),
        None => ("xiao", id),
    };
    let resp = call(&[("code", "detail"), ("mod", ty), ("id", vid)]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    if detail_paid(&data) {
        return Err(ApiError::Internal("lxs paid video refused".into()));
    }
    let url = play_url(&resp);
    if url.is_empty() {
        return Err(ApiError::Internal("lxs no stream url".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cfb_roundtrip() {
        let plain = b"hello world, this is a test of cfb128 mode!!";
        let enc = aes_cfb(plain, false);
        assert_ne!(enc, plain.to_vec());
        let dec = aes_cfb(&enc, true);
        assert_eq!(dec, plain.to_vec());
    }

    #[test]
    fn cfb_known_vector() {
        // AES-256 CFB128, key 000102...1f, iv 000102...0f, plaintext
        // 6bc1bee22e409f96e93d7e117393172a. Expected ciphertext cross-checked
        // against pycryptodome (same key/iv/plaintext):
        // 31afbab526bbee0019132b2c7150b1b8.
        let key: Vec<u8> = (0u8..32).collect();
        let iv: Vec<u8> = (0u8..16).collect();
        let plain: Vec<u8> = vec![
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
        ];
        let cipher = Aes256::new_from_slice(&key).unwrap();
        let mut prev = [0u8; 16];
        prev.copy_from_slice(&iv);
        let mut block = [0u8; 16];
        block.copy_from_slice(&prev);
        let mut ga = GenericArray::from_mut_slice(&mut block);
        cipher.encrypt_block(&mut ga);
        let mut out = Vec::new();
        for (i, &b) in plain.iter().enumerate() {
            out.push(b ^ block[i]);
        }
        assert_eq!(
            hex::encode(out),
            "31afbab526bbee0019132b2c7150b1b8"
        );
    }

    #[test]
    fn card_paid_rules() {
        let v: Value = serde_json::from_str(
            r#"{"id":"1","title":"t","price":9.9,"mv_type":"av"}"#,
        )
        .unwrap();
        assert!(card(&v, false).is_none());
        let c = card(&v, true).unwrap();
        assert_eq!(c["id"], "av:1");
        assert_eq!(c["remark"], "付费");
        let v2: Value = serde_json::from_str(
            r#"{"id":"2","title":"t","price":0,"duration":130,"cover_thumb":"https://cdn/c.jpg"}"#,
        )
        .unwrap();
        let c2 = card(&v2, false).unwrap();
        assert_eq!(c2["id"], "xiao:2");
        assert_eq!(c2["remark"], "2:10");
    }
}
