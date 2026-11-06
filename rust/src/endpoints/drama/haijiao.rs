//! 海角社区：`https://api1.ogokfmrx.com`。
//!
//! 来源 jar 类 `ZakaHaijiaoAmns`。基址
//! `https://api1.ogokfmrx.com`，`ORIGIN=https://p3.soqjpaqj.cc`，UA 为
//! iPhone Safari；`SALT=5589d41f92a597d016b037ac37db243d`；
//! `AES_KEY=2acf7e91e9864673`、`AES_IV=1c29882d3ddfcfd6`（各 16 字节）。
//! `TRIPLES` 为 5 组三元组（每组：32 hex 字符、32 hex 字符、约 300
//! hex 字符），自 jar 原文逐字抄录。
//!
//! `call(path, params)`：逐个试 TRIPLES：body JSON =
//! `{oauth_id: T[i][0], sid: T[i][1], token: T[i][2], bundleId:
//! "com.pwa.hjsq", version: "4.1.5", oauth_type: "web", language: "zh",
//! via: "pwa", _hash: <秒时间戳字符串>}` + 业务参数；PKCS7 填充后
//! AES/CBC/NoPadding 加密，Base64；
//! `sign = MD5hex(SHA256hex("client=pwa&data="+b64+"&timestamp="+ts+SALT))`；
//! POST `<base><path>`，body 为
//! `client=pwa&timestamp=<ts>&data=<URLEncoder 编码 b64>&sign=<sign>`，
//! 头为 UA + `Content-Type: application/x-www-form-urlencoded` +
//! `Origin: https://p3.soqjpaqj.cc`，连接/读取超时各 30 秒；非 200 抛
//! `http <码>`；响应先试 Base64 解码 + AES/CBC 解密 + 去 PKCS7 后解析
//! JSON，失败则按原字符串解析 JSON；成功条件为 `status == 1`，否则抛
//! `status <n> <msg>`；`data` 校验：数组须长度>0；对象须 `list[]` 或
//! `posts[]` 长度>0，或 `detail` 对象非空且对象本身长度>0，否则抛
//! `empty data` 并试下一组；全部失败后重抛最后一次异常，无异常时抛
//! `no triple worked`。
//!
//! 分类写死 20 类：`video:1` 推荐、`video:73` 伦理之爱、`video:238`
//! 官方原创、`video:220` 重口猎奇、`video:3` 国产精选、`video:2`
//! 华语原创、`video:257` 性感网黄、`video:4` 日韩欧美、`video:5`
//! 禁漫天堂、`video:203` 男男之爱、`video:75` 少女制服、`video:185`
//! 异域风情、`post:54` 海角原创、`post:49` 海角伦理、`post:63`
//! 海角认证、`comm:1` 热门推荐、`comm:6` 分享、`comm:4` 娱乐、
//! `comm:3` 禁区、`short` 短视频。
//! `listFor`：`video:` →
//! `call("/api.php/api/api/mv/list_construct", {sort: see, id, page,
//! limit: 30})` 经 `videoList`；`post:` →
//! `call("/api.php/api/api/original/topic", {sort: recommend, id, page,
//! limit: 30})` 经 `postCards`；`comm:` →
//! `call("/api.php/api/community/construct", {sort: recommend, id, page,
//! limit: 30})` 经 `postCards`；`short` →
//! `call("/api.php/api/vlog/list_sort", {sort: rec, limit: 30, page})`
//! 经 `shortCards`。
//!
//! `videoList`：取 `data.list[]` + `data.bot_style_one[].list[]` +
//! `data.bot_style_two[]`；`videoCard`：`aff` 为空字符串时剔除；
//! id/title 必有；封面取 `cover_horizontal` 否则 `cover_vertical`
//! （JSON 字符串时取其中 `720`→`ori`→`360`）；含 `drleao.cn` 的封面
//! 才包 `https://lxsimg.ystv.top/img?u=<编码>`；备注为时长 `MM:SS` +
//! `X次播放`（≥10000 时 `X.X万次播放`）+ 付费标记；内容为 tags +
//! created_at。
//! `postCards`：`data.posts[]`；每帖取 `medias[]` 中首个 `type==2`
//! 且 `media_url` 非空的媒体，无则跳过该帖；
//! `vod_id = "post:" + id + ":" + unlock_coins + ":" + media_url`；
//! 备注为 `unlock_coins>0? "视频帖 · 解锁<N>金币": "视频帖"`；标题取帖
//! `title`，封面为 `img(media.cover)`，简介取帖 `content`；同时写入
//! 进程缓存供详情/取流用。
//! `shortCards`：`data` 为数组或 `data.list[]`；`source_240` 优先
//! 否则由 `preview_url` 经 `playURL2` 换算（取 `https?://` 后首个无点
//! 段，替换为同目录的 `m3u8`）；`vod_id=short:<id>:<is_pay>:<url>`，
//! 并写入进程缓存供详情/取流用。
//!
//! 详情：`post:`/`short:` 直接用缓存（标题/封面/备注/简介），
//! `vod_play_url=正片$<原 id>`；视频类调
//! `call("/api.php/api/mv/getDetail", {id})` 取 `data.detail`（标题、
//! 封面、时长/播放/付费、desc、tag_list、actors、created_at），
//! `vod_play_url=正片$<id>`。
//! 搜索：`call("/api.php/api/mv/search", {word, type: 1, page, limit:
//! 30})`，`data` 为数组时逐条 `videoCard`，为对象时走 `videoList`。
//! 取流：video_id 以 `http` 开头直通；`post:`/`short:` 形如
//! `…:<is_pay>:<url>` 且 `is_pay <= 0` 时取第 4 段 URL；视频类调
//! `getDetail`，`is_pay == 0` 时用 `playURL2(source_240,
//! preview_url)`；头为 UA + Referer `<base>/`。

use std::sync::Mutex;

use base64::Engine as _;
use md5::Digest as _;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use sha2::Sha256;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BASE: &str = "https://api1.ogokfmrx.com";
const ORIGIN: &str = "https://p3.soqjpaqj.cc";
const SALT: &str = "5589d41f92a597d016b037ac37db243d";
const UA: &str = "Mozilla/5.0 (iPhone 12; CPU iPhone OS 14_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Mobile/15E148 Safari/604.1";
const AES_KEY: &[u8] = b"2acf7e91e9864673";
const AES_IV: &[u8] = b"1c29882d3ddfcfd6";

/// jar 原文 `TRIPLES`（5 组三元组，逐字抄录）。
const TRIPLES: &[(&str, &str, &str)] = &[
    ("dbd843be20cde9b12222bc5e2d484db2", "7073399b9ec74c0e80ff40ccaa8add5d", "9150C3A62C06D814442A6DA9CDA19AE5B03AEB95DBECF9D6747C09398671006BF1898D618ED1EE6DCFECE450A362275D6192641B5583AFFD487DEAEDF0799BFB911663BC69367CFCACCA6E3B6AB49656B3E62557C17AB0EBDCA7FD038620157FC00B768D3910F88F564A4069FD3E5C7D"),
    ("286afbc74a810ee711a2607d8794471d", "5e284b9452dc4360983e4a231f78dd6c", "C1598BA62CD8B2B85F38179D3E9AE948C54A7BD2B5F14F50A383CC8F32D2CF6C7CD60C88171A169A3BBF42567C9FF574281BF7F1BBAE19205F3395F799010B611C92AB30BBB703B1BB9B4FEA3DBE159A797DC49BB97D6C28929786619D29E1EACEA32022B4150ED1B8C47444B155619D"),
    ("de5a851f101c20842e26b3d35f6a048b", "11dfbcce9b89495e9476211fe49f0f37", "5FD285734E0B3F287078CA48C68279BD8348F1CA4099FC189016EA24CE2365AD5E4253C646D29369DD325353D9F4584D6141607D15072188A450763E1DA917F2FBC7197483D66C07A5BC1322EAE849E293FF1E48CDDF25AB92DB087E355FE98EE5188A53A8E54CF8AAD2A962381927F2"),
    ("c70169845085faa0ad39852357de8bb8", "f9976b9ce0e94692819f4f18e5684dbd", "2932C2BAA0A35BEE1318CF1F88B5F4F127E09740F5646FF37807F5998A764CAFA38D86941C49C388B694DD56752FB2F5A0441FE62768C603DDE3B7D55995B38D524CBD874FC48B64BB3DD2F0A38D70A03E9BD842DA1E4FE2D6A86F788CF80BE7B5E888847EC750D78B643AA41F7A97FA"),
    ("33d771b56b6522bcbde85eb5fcd34037", "2a43c42ef3be409595a49963a3123325", "D05760D6D22622E0FDDB8E4ABB3581DA23238081F715709FF5A9B9553C6E956AB14966064B2E2446D130F075933489FD9E97BCF0E2BA8FB7C691AC208859DD39C883D10171086352CE3BA98E2A5CA5EBF2F265CC8D3C6B3ACB422EAADD0511AE78A2EA2E0F14BEAE77DCC0E936B07D50"),
];

const CATS: &[(&str, &str)] = &[
    ("video:1", "推荐"),
    ("video:73", "伦理之爱"),
    ("video:238", "官方原创"),
    ("video:220", "重口猎奇"),
    ("video:3", "国产精选"),
    ("video:2", "华语原创"),
    ("video:257", "性感网黄"),
    ("video:4", "日韩欧美"),
    ("video:5", "禁漫天堂"),
    ("video:203", "男男之爱"),
    ("video:75", "少女制服"),
    ("video:185", "异域风情"),
    ("post:54", "海角原创"),
    ("post:49", "海角伦理"),
    ("post:63", "海角认证"),
    ("comm:1", "热门推荐"),
    ("comm:6", "分享"),
    ("comm:4", "娱乐"),
    ("comm:3", "禁区"),
    ("short", "短视频"),
];

/// post:/short: 列表写下的详情缓存（标题/封面/备注/简介），供详情用。
static CACHE: Lazy<Mutex<std::collections::HashMap<String, Value>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

fn now_sec() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
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

fn img(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    if !s.contains("drleao.cn") {
        return s.to_string();
    }
    format!("https://lxsimg.ystv.top/img?u={}", urlenc(s))
}

fn cover_of(s: &str) -> String {
    let t = s.trim();
    if t.is_empty() {
        return String::new();
    }
    if t.starts_with('{') {
        if let Ok(obj) = serde_json::from_str::<Value>(t) {
            for key in ["720", "ori", "360"] {
                let v = text_of(&obj, &[key]);
                if !v.is_empty() {
                    return img(&v);
                }
            }
            return img(t);
        }
        return img(t);
    }
    img(t)
}

/// `playURL2(source_240, preview_url)`：`source_240` 优先；否则把
/// `preview_url` 里 `https?://` 后首个无点段替换为 `m3u8`。
fn play_url2(source_240: &str, preview_url: &str) -> String {
    if !source_240.is_empty() {
        return source_240.to_string();
    }
    if preview_url.is_empty() {
        return String::new();
    }
    let re = Regex::new(r"(https?://)[^.]+").unwrap();
    let Some(m) = re.find(preview_url) else {
        return preview_url.to_string();
    };
    let group = m.as_str();
    let cut = group.rfind('/').map(|i| i + 1).unwrap_or(0);
    let replacement = format!("{}m3u8", &group[..cut]);
    format!(
        "{}{}{}",
        &preview_url[..m.start()],
        replacement,
        &preview_url[m.end()..]
    )
}

fn duration(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    format!("{:02}:{:02}", secs / 60, secs % 60)
}

fn play_ct(n: i64) -> String {
    if n >= 10000 {
        format!("{:.1}万次播放", n as f64 / 10000.0)
    } else {
        format!("{n}次播放")
    }
}

fn remark_for(v: &Value) -> String {
    let mut r = duration(int_of(v, &["duration"]));
    let ct = play_ct(int_of(v, &["play_ct"]));
    if ct != "0次播放" {
        if r.is_empty() {
            r = ct;
        } else {
            r = format!("{r} · {ct}");
        }
    }
    if int_of(v, &["is_pay"]) != 0 {
        if r.is_empty() {
            r = "付费".to_string();
        } else {
            r = format!("{r} · 付费");
        }
    }
    r
}

fn video_card(v: &Value) -> Option<Value> {
    if get(v, "aff").and_then(|a| a.as_str()) == Some("") {
        return None;
    }
    let id = text_of(v, &["id"]);
    let title = text_of(v, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let mut cover = cover_of(&text_of(v, &["cover_horizontal"]));
    if cover.is_empty() {
        cover = cover_of(&text_of(v, &["cover_vertical"]));
    }
    let mut content = text_of(v, &["tags"]);
    let created = text_of(v, &["created_at"]);
    if !created.is_empty() {
        if !content.is_empty() {
            content = format!("{content}\n{created}");
        } else {
            content = created;
        }
    }
    let mut it = item_json(&id, &title, &cover, &remark_for(v));
    it["content"] = json!(content);
    Some(it)
}

fn video_list(resp: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    let Some(data) = get(resp, "data") else {
        return out;
    };
    if let Some(arr) = arr_of(get(data, "list").unwrap_or(&Value::Null)) {
        for v in arr {
            if let Some(c) = video_card(v) {
                out.push(c);
            }
        }
    }
    if let Some(arr) = arr_of(get(data, "bot_style_one").unwrap_or(&Value::Null)) {
        for g in arr {
            if let Some(list) = arr_of(get(g, "list").unwrap_or(&Value::Null)) {
                for v in list {
                    if let Some(c) = video_card(v) {
                        out.push(c);
                    }
                }
            }
        }
    }
    if let Some(arr) = arr_of(get(data, "bot_style_two").unwrap_or(&Value::Null)) {
        for v in arr {
            if let Some(c) = video_card(v) {
                out.push(c);
            }
        }
    }
    out
}

fn post_cards(resp: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    let Some(data) = get(resp, "data") else {
        return out;
    };
    let Some(posts) = arr_of(get(data, "posts").unwrap_or(&Value::Null)) else {
        return out;
    };
    for post in posts {
        let id = text_of(post, &["id"]);
        if id.is_empty() {
            continue;
        }
        let mut media: Option<Value> = None;
        if let Some(medias) = arr_of(get(post, "medias").unwrap_or(&Value::Null)) {
            for m in medias {
                if int_of(m, &["type"]) == 2 && !text_of(m, &["media_url"]).is_empty() {
                    media = Some(m.clone());
                    break;
                }
            }
        }
        let Some(media) = media else {
            continue;
        };
        let media_url = text_of(&media, &["media_url"]);
        let coins = int_of(post, &["unlock_coins"]);
        let vod_id = format!("post:{id}:{coins}:{media_url}");
        let remark = if coins > 0 {
            format!("视频帖 · 解锁{coins}金币")
        } else {
            "视频帖".to_string()
        };
        let title = text_of(post, &["title"]);
        let cover = img(&text_of(&media, &["cover"]));
        let desc = text_of(post, &["content"]);
        let mut it = item_json(&vod_id, &title, &cover, &remark);
        it["content"] = json!(desc);
        CACHE.lock().unwrap().insert(
            vod_id.clone(),
            json!({"title": title, "cover": cover, "remark": remark, "desc": desc}),
        );
        out.push(it);
    }
    out
}

fn short_cards(resp: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    let Some(data) = get(resp, "data") else {
        return out;
    };
    let arr: Vec<Value> = if let Some(a) = data.as_array() {
        a.clone()
    } else if let Some(a) = arr_of(get(data, "list").unwrap_or(&Value::Null)) {
        a.clone()
    } else {
        return out;
    };
    for v in &arr {
        // aff 为空字符串时剔除；aff 缺失时保留。
        if get(v, "aff").and_then(|a| a.as_str()) == Some("") {
            continue;
        }
        let id = text_of(v, &["id"]);
        if id.is_empty() {
            continue;
        }
        let url = play_url2(&text_of(v, &["source_240"]), &text_of(v, &["preview_url"]));
        if url.is_empty() {
            continue;
        }
        let is_pay = int_of(v, &["is_pay"]);
        let mut cover = cover_of(&text_of(v, &["cover_vertical"]));
        if cover.is_empty() {
            cover = cover_of(&text_of(v, &["cover_horizontal"]));
        }
        let remark = remark_for(v);
        let vod_id = format!("short:{id}:{is_pay}:{url}");
        let title = text_of(v, &["title"]);
        let desc = text_of(v, &["tags"]);
        let mut it = item_json(&vod_id, &title, &cover, &remark);
        it["content"] = json!(desc);
        CACHE.lock().unwrap().insert(
            vod_id.clone(),
            json!({"title": title, "cover": cover, "remark": remark, "desc": desc}),
        );
        out.push(it);
    }
    out
}

async fn call(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let ts = now_sec().to_string();
    let mut last_err = String::new();
    for t in TRIPLES {
        let mut body = json!({
            "oauth_id": t.0,
            "sid": t.1,
            "token": t.2,
            "bundleId": "com.pwa.hjsq",
            "version": "4.1.5",
            "oauth_type": "web",
            "language": "zh",
            "via": "pwa",
            "_hash": ts,
        });
        if let Some(o) = body.as_object_mut() {
            for (k, v) in params {
                o.insert(k.to_string(), json!(v));
            }
        }
        let padded = crate::crypto::pkcs7_pad(body.to_string().as_bytes(), 16);
        let cipher = crate::crypto::aes_cbc_encrypt(&padded, AES_KEY, AES_IV);
        let b64 = base64::engine::general_purpose::STANDARD.encode(cipher);
        let sign_input = format!("client=pwa&data={b64}&timestamp={ts}{SALT}");
        let sign = md5_hex(sha256_hex(sign_input.as_bytes()).as_bytes());
        let form = format!(
            "client=pwa&timestamp={ts}&data={}&sign={sign}",
            urlenc(&b64)
        );
        let url = format!("{BASE}{path}");
        let resp = match client() {
            Ok(c) => c
                .post(&url)
                .header("User-Agent", UA)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("Origin", ORIGIN)
                .body(form)
                .send()
                .await
                .map_err(|e| format!("http {e}")),
            Err(e) => Err(format!("{e}")),
        };
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = e;
                continue;
            }
        };
        if !resp.status().is_success() {
            last_err = format!("http {}", resp.status());
            continue;
        }
        let Ok(text) = resp.text().await else {
            last_err = "empty body".to_string();
            continue;
        };
        // 先试 Base64 解码 + AES/CBC 解密 + 去 PKCS7 后解析 JSON，失败
        // 则按原字符串解析 JSON。
        let parsed: Option<Value> = {
            let mut v: Option<Value> = None;
            if let Ok(raw) =
                base64::engine::general_purpose::STANDARD.decode(text.trim().as_bytes())
            {
                if !raw.is_empty() && raw.len() % 16 == 0 {
                    let plain = crate::crypto::aes_cbc_decrypt(&raw, AES_KEY, AES_IV);
                    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
                    v = serde_json::from_slice(unpadded).ok();
                }
            }
            v.or_else(|| serde_json::from_str(&text).ok())
        };
        let Some(v) = parsed else {
            last_err = "bad json".to_string();
            continue;
        };
        if int_of(&v, &["status"]) != 1 {
            last_err = format!(
                "status {} {}",
                int_of(&v, &["status"]),
                text_of(&v, &["msg"])
            );
            continue;
        }
        let data = get(&v, "data").cloned().unwrap_or(Value::Null);
        let valid = if let Some(arr) = data.as_array() {
            !arr.is_empty()
        } else if let Some(o) = data.as_object() {
            let list_ok = arr_of(get(&data, "list").unwrap_or(&Value::Null))
                .map(|a| !a.is_empty())
                .unwrap_or(false);
            let posts_ok = arr_of(get(&data, "posts").unwrap_or(&Value::Null))
                .map(|a| !a.is_empty())
                .unwrap_or(false);
            let detail_ok = get(&data, "detail")
                .and_then(|d| d.as_object())
                .map(|d| !d.is_empty())
                .unwrap_or(false)
                && !o.is_empty();
            list_ok || posts_ok || detail_ok
        } else {
            false
        };
        if !valid {
            last_err = "empty data".to_string();
            continue;
        }
        return Ok(v);
    }
    if last_err.is_empty() {
        last_err = "no triple worked".to_string();
    }
    Err(ApiError::Internal(format!(
        "haijiao call failed: {last_err}"
    )))
}

async fn list_for(category_id: &str, page: i64) -> ApiResult<Vec<Value>> {
    if let Some(id) = category_id.strip_prefix("video:") {
        let resp = call(
            "/api.php/api/api/mv/list_construct",
            &[
                ("sort", "see"),
                ("id", id),
                ("page", &page.to_string()),
                ("limit", "30"),
            ],
        )
        .await?;
        return Ok(video_list(&resp));
    }
    if let Some(id) = category_id.strip_prefix("post:") {
        let resp = call(
            "/api.php/api/api/original/topic",
            &[
                ("sort", "recommend"),
                ("id", id),
                ("page", &page.to_string()),
                ("limit", "30"),
            ],
        )
        .await?;
        return Ok(post_cards(&resp));
    }
    if let Some(id) = category_id.strip_prefix("comm:") {
        let resp = call(
            "/api.php/api/community/construct",
            &[
                ("sort", "recommend"),
                ("id", id),
                ("page", &page.to_string()),
                ("limit", "30"),
            ],
        )
        .await?;
        return Ok(post_cards(&resp));
    }
    if category_id == "short" {
        let resp = call(
            "/api.php/api/vlog/list_sort",
            &[
                ("sort", "rec"),
                ("limit", "30"),
                ("page", &page.to_string()),
            ],
        )
        .await?;
        return Ok(short_cards(&resp));
    }
    Ok(Vec::new())
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
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

async fn get_detail(id: &str) -> ApiResult<Value> {
    let resp = call("/api.php/api/mv/getDetail", &[("id", id)]).await?;
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    Ok(get(&data, "detail").cloned().unwrap_or(Value::Null))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if id.starts_with("post:") || id.starts_with("short:") {
        let cached = CACHE.lock().unwrap().get(id).cloned();
        let title = cached
            .as_ref()
            .map(|c| text_of(c, &["title"]))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| id.to_string());
        let cover = cached
            .as_ref()
            .map(|c| text_of(c, &["cover"]))
            .unwrap_or_default();
        let remark = cached
            .as_ref()
            .map(|c| text_of(c, &["remark"]))
            .unwrap_or_default();
        let desc = cached
            .as_ref()
            .map(|c| text_of(c, &["desc"]))
            .unwrap_or_default();
        return Ok(json!({
            "id": id, "title": title, "cover": cover, "synopsis": desc,
            "extra": {"vod_remarks": remark},
            "episodes": [episode_json(id, "正片", id)],
        }));
    }
    let d = get_detail(id).await.unwrap_or(Value::Null);
    let mut title = text_of(&d, &["title"]);
    if title.is_empty() {
        title = format!("视频{id}");
    }
    let mut cover = cover_of(&text_of(&d, &["cover_horizontal"]));
    if cover.is_empty() {
        cover = cover_of(&text_of(&d, &["cover_vertical"]));
    }
    let mut parts: Vec<String> = Vec::new();
    let desc = text_of(&d, &["desc"]);
    if !desc.is_empty() {
        parts.push(desc);
    }
    let tags = arr_of(get(&d, "tag_list").unwrap_or(&Value::Null))
        .map(|a| {
            a.iter()
                .map(|t| t.as_str().unwrap_or("").to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !tags.is_empty() {
        parts.push(format!("标签: {}", tags.join("、")));
    }
    let actors = text_of(&d, &["actors"]);
    if !actors.is_empty() {
        parts.push(format!("演员: {actors}"));
    }
    let created = text_of(&d, &["created_at"]);
    if !created.is_empty() {
        parts.push(created);
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover,
        "synopsis": parts.join("\n"),
        "extra": {"vod_remarks": remark_for(&d)},
        "episodes": [episode_json(id, "正片", id)],
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
            ("limit", "30"),
        ],
    )
    .await
    {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": []})),
    };
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    if let Some(arr) = data.as_array() {
        let mut out = Vec::new();
        for v in arr {
            if let Some(c) = video_card(v) {
                out.push(c);
            }
        }
        return Ok(json!({"items": out}));
    }
    Ok(json!({"items": video_list(&resp)}))
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
    let mut url = String::new();
    if id.starts_with("post:") {
        let parts: Vec<&str> = id.splitn(4, ':').collect();
        if parts.len() == 4 {
            if let Ok(coins) = parts[2].parse::<i64>() {
                if coins <= 0 {
                    url = parts[3].to_string();
                }
            }
        }
    } else if id.starts_with("short:") {
        let parts: Vec<&str> = id.splitn(4, ':').collect();
        if parts.len() == 4 {
            if let Ok(pay) = parts[2].parse::<i64>() {
                if pay == 0 {
                    url = parts[3].to_string();
                }
            }
        }
    } else {
        let d = get_detail(id).await.unwrap_or(Value::Null);
        if int_of(&d, &["is_pay"]) == 0 {
            url = play_url2(
                &text_of(&d, &["source_240"]),
                &text_of(&d, &["preview_url"]),
            );
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("haijiao no stream url".into()));
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
    fn play_url2_replaces_first_label() {
        assert_eq!(
            play_url2("", "https://abc.def.com/x/preview.mp4"),
            "https://m3u8.def.com/x/preview.mp4"
        );
        assert_eq!(
            play_url2("https://cdn/s240.m3u8", "https://abc.def.com/x.mp4"),
            "https://cdn/s240.m3u8"
        );
        assert_eq!(play_url2("", ""), "");
    }

    #[test]
    fn duration_and_play_ct() {
        assert_eq!(duration(125), "02:05");
        assert_eq!(duration(0), "");
        assert_eq!(play_ct(9999), "9999次播放");
        assert_eq!(play_ct(12345), "1.2万次播放");
    }

    #[test]
    fn video_card_aff_empty_dropped() {
        let v: Value = serde_json::from_str(r#"{"aff":"","id":"1","title":"t"}"#).unwrap();
        assert!(video_card(&v).is_none());
        let v2: Value =
            serde_json::from_str(r#"{"id":"1","title":"t","duration":65,"play_ct":5}"#).unwrap();
        let c = video_card(&v2).unwrap();
        assert_eq!(c["remark"], "01:05 · 5次播放");
    }
}
