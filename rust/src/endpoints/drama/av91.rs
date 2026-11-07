//! av91：`https://api3.bwkhawkdv.cc`。
//!
//! 来源 jar 类 `ZakaAv91Amns`。基址 `https://api3.bwkhawkdv.cc`，UA 为
//! Chrome 120 Android SM-A205GN；
//! `SIGN_SECRET=f479a05f2c1b6688aed5c4a5213fcdfe`；
//! `AES_KEY=f1b97d6206b8ccd91b75f90d97cb11ea`（32 字节，AES-256）、
//! `AES_IV=bbb5e8de80737ee0`（16 字节）。
//!
//! `call(params)`：固定字段 `oauth_id=8X5CLgmXrHhDEsxG_1784029458860`、
//! `bundleId=com.pwa.jyav`、`version=4.5.1`、`oauth_type=pwa`、
//! `language=zh`、`via=web`、`_hash=<当前毫秒>`，再按插入顺序并入业务参数；
//! JSON 串 PKCS7 填充后 AES/CBC/NoPadding 加密，Base64；
//! `sign = MD5 小写 hex(SHA-256 小写 hex("client=pwa&data=<Base64>&timestamp=<秒>" + SIGN_SECRET))`；
//! POST `<base>/api.php`，body 为
//! `client=pwa&timestamp=<秒>&data=<URLEncoder 编码 Base64>&sign=<URLEncoder 编码 hex>`，
//! 头 UA + `Content-Type: application/x-www-form-urlencoded` + Referer
//! `<base>/`，20 秒超时，失败睡 1 秒最多 3 次；响应 gzip 时 gunzip；
//! `data` 字段非空时 Base64 解码后 AES/CBC 解密去 PKCS7，解析为 JSON
//! （明文须以 `{` 开头）。
//!
//! 分类写死 14 类：`daily` 每日播单、`construct:3` 最新创作、
//! `construct:4` 热门影片、`construct:7` 暗网猎奇、`construct:2` 华语国产、
//! `construct:5` VIP专区、`construct:12` 禁漫天堂、`construct:9` 日本AV、
//! `theme` 主题、`recommend` 推荐、`actor:renqi:` 女优·人气、
//! `actor:av_count:` 女优·片量、`screen:::1` 筛选·免费、
//! `screen:most_play::` 筛选·观看最多。
//! 卡片：`id` 与 `title`/`name` 均非空；付费判定 `is_pay == 1` 或
//! `toll_type` 为 `3`/`4` 或（`coins > 0` 且 `isfree == 2`），付费先
//! 排除、全空时才放回；封面取 `cover_horizontal` → `cover_vertical` →
//! `cover_full` → `cover`（字符串以 `{` 开头时解析其中 `ori`→`720`→
//! `360`）；备注为 `付费` 或时长 `M:SS`（`0 < duration < 100000` 秒）；
//! `type_name` 为 `tags` 或 `tag_list`（空格连）；`vod_id="video:"+id`。
//! `flattenCards(resp)`：`data` 为对象时取 `data.data[]`，否则取
//! `data.mv_recomment_official[]`，否则取 `data.mvs.data[]`，否则取
//! `data.elements[]` 中 `type == 4` 的 `value[]`；`data` 本身为数组时
//! 直接用；逐条 `card(obj, false)`，全空时重试 `card(obj, true)`。
//! 首页：`call({mod: mv, code: search, sort: "", cate: "", toll_type: 1,
//! page: 1, limit: 16})` 经 `flattenCards`。
//! 详情：`theme:<id>` 调 `call({mod: element, code: getConstructById, id,
//! page: 1})` 经 `flattenCards`，分集为 `片名$<vod_id>`；
//! `actor:<id>|<名>` 调 `call({mod: mvactor, code: actorDetail, id, sort:
//! praise})`，分集同上，`vod_actor=<名>`；视频类调 `detailForVideo`
//! （`call({mod: mv, code: detail, id})`，取 `data.mv` 或 `data.detail`
//! 或 `data` 本身），付费时 `vod_play_url` 为空，否则
//! `正片$<playUrlFromDetail>`。
//! `playUrlFromDetail`：`m3u8` → `mv.m3u8` → `preview_url`
//! （`hf-[^.]+.` 换 `hf-long.`）→ `preview_sources.url_264`/`url_265` →
//! `source_720`/`source_480`/`source_240`。
//! 搜索：`call({mod: seek, code: seekInAll, keywords, type: mv, last_ix:
//! 24, page})` 经 `flattenCards`。
//! 取流：video_id 以 `http` 开头直通；`video:` 前缀去后调
//! `detailForVideo`，非付费时用 `playUrlFromDetail`；头为 UA +
//! Referer `<base>/`。

use base64::Engine as _;
use regex::Regex;
use serde_json::{json, Value};
use sha2::{Digest as _, Sha256};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://api3.bwkhawkdv.cc";
const SIGN_SECRET: &str = "f479a05f2c1b6688aed5c4a5213fcdfe";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; SM-A205GN) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36";
const AES_KEY: &[u8] = b"f1b97d6206b8ccd91b75f90d97cb11ea";
const AES_IV: &[u8] = b"bbb5e8de80737ee0";

const CATS: &[(&str, &str)] = &[
    ("daily", "每日播单"),
    ("construct:3", "最新创作"),
    ("construct:4", "热门影片"),
    ("construct:7", "暗网猎奇"),
    ("construct:2", "华语国产"),
    ("construct:5", "VIP专区"),
    ("construct:12", "禁漫天堂"),
    ("construct:9", "日本AV"),
    ("theme", "主题"),
    ("recommend", "推荐"),
    ("actor:renqi:", "女优·人气"),
    ("actor:av_count:", "女优·片量"),
    ("screen:::1", "筛选·免费"),
    ("screen:most_play::", "筛选·观看最多"),
];

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

async fn call(params: &[(&str, &str)]) -> ApiResult<Value> {
    let mut body = String::from("{");
    let mut pairs: Vec<(String, String)> = vec![
        (
            "oauth_id".to_string(),
            "8X5CLgmXrHhDEsxG_1784029458860".to_string(),
        ),
        ("bundleId".to_string(), "com.pwa.jyav".to_string()),
        ("version".to_string(), "4.5.1".to_string()),
        ("oauth_type".to_string(), "pwa".to_string()),
        ("language".to_string(), "zh".to_string()),
        ("via".to_string(), "web".to_string()),
        ("_hash".to_string(), now_ms().to_string()),
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
    let padded = crate::crypto::pkcs7_pad(body.as_bytes(), 16);
    let cipher = crate::crypto::aes_cbc_encrypt(&padded, AES_KEY, AES_IV);
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, cipher);
    let ts = (now_ms() / 1000).to_string();
    let sign = md5_hex(
        sha256_hex(format!("client=pwa&data={b64}&timestamp={ts}{SIGN_SECRET}").as_bytes())
            .as_bytes(),
    );
    let form = format!(
        "client=pwa&timestamp={ts}&data={}&sign={}",
        urlenc(&b64),
        urlenc(&sign)
    );
    let mut last_err = String::new();
    let mut all: Option<Vec<u8>> = None;
    for _ in 0..3 {
        let resp = match client() {
            Ok(c) => c
                .post(format!("{BASE}/api.php"))
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
        return Err(ApiError::Internal(format!("av91 call failed: {last_err}")));
    };
    let v: Value =
        serde_json::from_slice(&all).map_err(|e| ApiError::Internal(format!("av91 json: {e}")))?;
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
    if !s.starts_with('{') {
        return Ok(v);
    }
    serde_json::from_str::<Value>(&s)
        .map_err(|e| ApiError::Internal(format!("av91 inner json: {e}")))
}

fn pic(s: &str) -> String {
    let s = s.trim();
    if s.is_empty() || !s.starts_with("http") {
        return s.to_string();
    }
    format!("https://lxsimg.ystv.top/img?u={}", urlenc(s))
}

fn unwrap_cover(v: &Value) -> String {
    let mut s = text_of(
        v,
        &["cover_horizontal", "cover_vertical", "cover_full", "cover"],
    );
    if s.starts_with('{') {
        if let Ok(obj) = serde_json::from_str::<Value>(&s) {
            s = text_of(&obj, &["ori", "720", "360"]);
        }
    }
    pic(&s)
}

fn is_paid(v: &Value) -> bool {
    get(v, "is_pay").and_then(|x| x.as_i64()) == Some(1)
        || matches!(text_of(v, &["toll_type"]).as_str(), "3" | "4")
        || (get(v, "coins").and_then(|x| x.as_i64()).unwrap_or(0) > 0
            && get(v, "isfree").and_then(|x| x.as_i64()) == Some(2))
}

fn card(v: &Value, include_paid: bool) -> Option<Value> {
    let id = text_of(v, &["id"]);
    let mut title = text_of(v, &["title"]);
    if title.is_empty() {
        title = text_of(v, &["name"]);
    }
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let paid = is_paid(v);
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
    let mut type_name = text_of(v, &["tags"]);
    if type_name.is_empty() {
        type_name = arr_of(get(v, "tag_list").unwrap_or(&Value::Null))
            .map(|a| {
                a.iter()
                    .map(|t| t.as_str().unwrap_or("").to_string())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
            .join(" ");
    }
    let mut it = item_json(&format!("video:{id}"), &title, &unwrap_cover(v), &remark);
    it["type_name"] = json!(type_name);
    Some(it)
}

fn flatten_cards(resp: &Value) -> Vec<Value> {
    let data = get(resp, "data").cloned().unwrap_or(Value::Null);
    let mut list: Vec<Value> = Vec::new();
    if let Some(a) = data.as_array() {
        list = a.clone();
    } else if let Some(a) = arr_of(get(&data, "data").unwrap_or(&Value::Null)) {
        list = a.clone();
    } else if let Some(a) = arr_of(get(&data, "mv_recomment_official").unwrap_or(&Value::Null)) {
        list = a.clone();
    } else if let Some(mvs) = get(&data, "mvs") {
        if let Some(a) = arr_of(get(mvs, "data").unwrap_or(&Value::Null)) {
            list = a.clone();
        }
    } else if let Some(elements) = arr_of(get(&data, "elements").unwrap_or(&Value::Null)) {
        for e in elements {
            if get(e, "type").and_then(|x| x.as_i64()) == Some(4) {
                if let Some(a) = arr_of(get(e, "value").unwrap_or(&Value::Null)) {
                    list.extend(a.iter().cloned());
                }
            }
        }
    }
    let mut out = Vec::new();
    for v in &list {
        if let Some(c) = card(v, false) {
            out.push(c);
        }
    }
    if out.is_empty() {
        for v in &list {
            if let Some(c) = card(v, true) {
                out.push(c);
            }
        }
    }
    out
}

fn play_url_from_detail(v: &Value) -> String {
    let mut s = text_of(v, &["m3u8"]);
    if s.is_empty() {
        if let Some(mv) = get(v, "mv") {
            s = text_of(mv, &["m3u8"]);
        }
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

async fn detail_for_video(id: &str) -> ApiResult<Value> {
    let resp = call(&[("mod", "mv"), ("code", "detail"), ("id", id)]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let mut d = get(&data, "mv").cloned().unwrap_or(Value::Null);
    if d.is_null() {
        d = get(&data, "detail").cloned().unwrap_or(Value::Null);
    }
    if d.is_null() {
        d = data.clone();
    }
    Ok(d)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let page_s = page.to_string();
    let (items, limit): (Vec<Value>, i64) = if category_id == "daily" {
        match call(&[
            ("mod", "mv"),
            ("code", "playlist"),
            ("id", "1"),
            ("page", &page_s),
        ])
        .await
        {
            Ok(resp) => {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                let mut out: Vec<Value> = Vec::new();
                if let Some(groups) = arr_of(get(&data, "data").unwrap_or(&Value::Null)) {
                    for g in groups {
                        if let Some(mvs) = arr_of(get(g, "mv").unwrap_or(&Value::Null)) {
                            for v in mvs {
                                if let Some(c) = card(v, false) {
                                    out.push(c);
                                }
                            }
                        }
                    }
                }
                if out.is_empty() {
                    if let Some(groups) = arr_of(get(&data, "data").unwrap_or(&Value::Null)) {
                        for g in groups {
                            if let Some(mvs) = arr_of(get(g, "mv").unwrap_or(&Value::Null)) {
                                for v in mvs {
                                    if let Some(c) = card(v, true) {
                                        out.push(c);
                                    }
                                }
                            }
                        }
                    }
                }
                (out, 20)
            }
            Err(_) => (Vec::new(), 20),
        }
    } else if let Some(id) = category_id.strip_prefix("construct:") {
        match call(&[
            ("mod", "element"),
            ("code", "getConstructById"),
            ("id", id),
            ("page", &page_s),
        ])
        .await
        {
            Ok(resp) => (flatten_cards(&resp), 20),
            Err(_) => (Vec::new(), 20),
        }
    } else if category_id == "theme" {
        match call(&[("mod", "mv"), ("code", "mvTopicList")]).await {
            Ok(resp) => {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                let mut out = Vec::new();
                if let Some(arr) = arr_of(get(&data, "data").unwrap_or(&Value::Null)) {
                    for t in arr {
                        let cid = text_of(t, &["construct_id"]);
                        let name = text_of(t, &["title"]);
                        if cid.is_empty() || name.is_empty() {
                            continue;
                        }
                        let count = get(t, "mv_count").and_then(|x| x.as_i64()).unwrap_or(0);
                        let mut it = item_json(
                            &format!("theme:{cid}"),
                            &name,
                            "",
                            &format!("主题 {count} 部"),
                        );
                        it["tag"] = json!("folder");
                        out.push(it);
                    }
                }
                (out, 20)
            }
            Err(_) => (Vec::new(), 20),
        }
    } else if category_id == "recommend" {
        match call(&[("mod", "mv"), ("code", "recommendAll")]).await {
            Ok(resp) => (flatten_cards(&resp), 20),
            Err(_) => (Vec::new(), 20),
        }
    } else if let Some(rest) = category_id.strip_prefix("actor:") {
        let parts: Vec<&str> = rest.split(':').collect();
        let sort = parts.first().copied().unwrap_or("");
        let sort = if sort.is_empty() { "renqi" } else { sort };
        let cup = parts.get(1).copied().unwrap_or("");
        match call(&[
            ("mod", "Mvactor"),
            ("code", "actorList"),
            ("sort", sort),
            ("cup_size", cup),
            ("page", &page_s),
            ("limit", "32"),
        ])
        .await
        {
            Ok(resp) => {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                let mut out = Vec::new();
                if let Some(actors) = arr_of(get(&data, "actors").unwrap_or(&Value::Null)) {
                    for a in actors {
                        let aid = text_of(a, &["id"]);
                        let name = text_of(a, &["name"]);
                        if aid.is_empty() || name.is_empty() {
                            continue;
                        }
                        let count = get(a, "av_count").and_then(|x| x.as_i64()).unwrap_or(0);
                        let remark = if cup.is_empty() {
                            format!("片量 {count}")
                        } else {
                            format!("片量 {count} {cup}杯")
                        };
                        let mut it = item_json(
                            &format!("actor:{aid}|{name}"),
                            &name,
                            &pic(&text_of(a, &["cover"])),
                            &remark,
                        );
                        it["tag"] = json!("folder");
                        out.push(it);
                    }
                }
                let has_more = out.len() >= 32;
                return Ok(json!({"items": out, "has_more": has_more, "limit": 32}));
            }
            Err(_) => (Vec::new(), 32),
        }
    } else if let Some(rest) = category_id.strip_prefix("screen:") {
        let parts: Vec<&str> = rest.split(':').collect();
        let sort = parts.first().copied().unwrap_or("");
        let cate = parts.get(1).copied().unwrap_or("");
        let toll = parts.get(2).copied().unwrap_or("");
        match call(&[
            ("mod", "mv"),
            ("code", "search"),
            ("sort", sort),
            ("cate", cate),
            ("toll_type", toll),
            ("page", &page_s),
            ("limit", "16"),
        ])
        .await
        {
            Ok(resp) => (flatten_cards(&resp), 16),
            Err(_) => (Vec::new(), 16),
        }
    } else {
        match call(&[
            ("mod", "element"),
            ("code", "getConstructById"),
            ("id", "3"),
            ("page", &page_s),
        ])
        .await
        {
            Ok(resp) => (flatten_cards(&resp), 20),
            Err(_) => (Vec::new(), 20),
        }
    };
    let has_more = !items.is_empty();
    let _ = limit;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(tid) = id.strip_prefix("theme:") {
        let resp = call(&[
            ("mod", "element"),
            ("code", "getConstructById"),
            ("id", tid),
            ("page", "1"),
        ])
        .await?;
        let items = flatten_cards(&resp);
        let mut episodes: Vec<Value> = Vec::new();
        for c in &items {
            let vid = c["id"].as_str().unwrap_or("").to_string();
            let t = c["title"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&vid, &t, id));
        }
        return Ok(json!({
            "id": id, "title": "", "cover": "", "synopsis": "",
            "extra": {"type_name": "主题"},
            "episodes": episodes,
        }));
    }
    if let Some(rest) = id.strip_prefix("actor:") {
        let (aid, name) = match rest.split_once('|') {
            Some((a, n)) => (a, n),
            None => (rest, ""),
        };
        let resp = call(&[
            ("mod", "mvactor"),
            ("code", "actorDetail"),
            ("id", aid),
            ("sort", "praise"),
        ])
        .await?;
        let items = flatten_cards(&resp);
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
    let vid = id.strip_prefix("video:").unwrap_or(id);
    let d = detail_for_video(vid).await?;
    let mut title = text_of(&d, &["title"]);
    if title.is_empty() {
        title = text_of(&d, &["name"]);
    }
    if title.is_empty() {
        title = format!("视频{vid}");
    }
    let paid = is_paid(&d);
    let url = if paid {
        String::new()
    } else {
        play_url_from_detail(&d)
    };
    let mut episodes: Vec<Value> = Vec::new();
    if !url.is_empty() {
        episodes.push(episode_json(&url, "正片", id));
    }
    Ok(json!({
        "id": id, "title": title, "cover": unwrap_cover(&d),
        "synopsis": text_of(&d, &["desc"]),
        "extra": {"vod_remarks": if paid { "付费" } else { "" }, "vod_actor": text_of(&d, &["actors"])},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let resp = match call(&[
        ("mod", "seek"),
        ("code", "seekInAll"),
        ("keywords", query),
        ("type", "mv"),
        ("last_ix", "24"),
        ("page", "1"),
    ])
    .await
    {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": []})),
    };
    Ok(json!({"items": flatten_cards(&resp)}))
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
    let vid = id.strip_prefix("video:").unwrap_or(id);
    let d = detail_for_video(vid).await?;
    if is_paid(&d) {
        return Err(ApiError::Internal("av91 paid video refused".into()));
    }
    let url = play_url_from_detail(&d);
    if url.is_empty() {
        return Err(ApiError::Internal("av91 no stream url".into()));
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
    fn cats_fourteen() {
        assert_eq!(CATS.len(), 14);
    }

    #[test]
    fn cover_json_unwrap() {
        let v: Value = serde_json::from_str(
            r#"{"cover_horizontal":"{\"ori\":\"https://cdn/a.jpg\",\"720\":\"https://cdn/b.jpg\"}"}"#,
        )
        .unwrap();
        assert_eq!(
            unwrap_cover(&v),
            "https://lxsimg.ystv.top/img?u=https%3A%2F%2Fcdn%2Fa.jpg"
        );
    }

    #[test]
    fn play_url_hf() {
        let v: Value =
            serde_json::from_str(r#"{"preview_url":"https://hf-xyz9.cdn.com/x.m3u8"}"#).unwrap();
        assert_eq!(play_url_from_detail(&v), "https://hf-long.cdn.com/x.m3u8");
    }

    #[test]
    fn card_paid_rules() {
        let v: Value = serde_json::from_str(r#"{"id":"1","title":"t","toll_type":"3"}"#).unwrap();
        assert!(card(&v, false).is_none());
        assert!(card(&v, true).is_some());
        let v2: Value = serde_json::from_str(r#"{"id":"2","title":"t","duration":95}"#).unwrap();
        assert_eq!(card(&v2, false).unwrap()["remark"], "1:35");
    }

    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        assert_eq!(cats["categories"].as_array().unwrap().len(), 14);
        let r = catalog("daily", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!("LIVE av91 cats=14 daily_items={}", items.len());
        assert!(!items.is_empty(), "av91 daily catalog empty");
        assert!(!items[0]["id"].as_str().unwrap_or("").is_empty());
        assert!(!items[0]["title"].as_str().unwrap_or("").is_empty());
    }
}
