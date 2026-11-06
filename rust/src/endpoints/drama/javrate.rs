//! 鉴黄师┃原生：`https://www.javrate.com`。
//!
//! 来源 jar 类 `ZakaJavrateAmns`。站址 `ZakaSec.s(91) =
//! 'https://www.javrate.com'`（已用 `/tmp/sec.py` 解出）；CDN 基址
//! `ZakaSec.s(92) = 'https://videocdn.avking.xyz'`。
//! `ZakaGate` 在本 jar 内全部是空壳：`guard`/`detail`/`attach` 均返回
//! null（即放行），`locked()` 返回 false——鉴权门禁在本 jar 里是未启
//! 用的，不构成障碍。
//! 取页 `html(url)`：先试 `jinaHtml`（GET `https://r.jina.ai/<原 URL>`，
//! 头 UA_D + `Accept: text/html` + `X-Return-Format: html` +
//! `X-No-Cache: true`，25 秒超时；响应短于 200 或含 `just a moment` /
//! `rate limit`（小写）时视为失败），失败再走 `ZakaShield.fetch`
//! （直连 → `ZakaCfg.gateway()` 配置的网关 `/fetch?u=<编码>`，网关默认
//! 未配——本模块直连）；页面缓存 30 秒。UA_D 为 Chrome 131 Windows。
//!
//! 分类（`ZakaJavrateData.CATS`，写死 11 类）：`/movie/new` 最新更新、
//! `/menu/uncensored` 无码A片、`/menu/censored` 日本A片、
//! `/menu/chinese` 国产AV、`/movie/subtitle` 中文字幕、`/best` 最多人看、
//! `__tags` 标签找片、`/actor/list/1-0-1.html` AV女优、`/moviesets`
//! 专辑系列、`/issuer` 片商厂牌、`__tools` 过盾工具（工具类为 `cf::diag`
//! 通道自检、`cf::verify` 重置通道、`cf::log` 查看运行日志、`cf::clear`
//! 清除缓存——核心里不写工具类，`categories()` 只取前 10 个真实分类）。
//! `categoryContent`：`__tags` 调 `html(<site>/keywords/movie/<tag 或默认“中出”>?page=<页>[&moviesort=<tsort>])`；
//! `/actor/list` 开头调 `html(<site>/actor/list/<sort 或 2>-<acat 或 0>-<页>.html)`
//! （第 1 页且无排序/分类时用 `/actor/list/1-0-1.html`），经
//! `actorCards`（`<div class="actor-card` 切块，`vod_id=/actor/detail/<uuid>.html`，
//! 标题取 `<a>` 的 title，封面取首个 img，备注取 `mg[n]?-badge`）；
//! `/moviesets` 调 `html(<site>/moviesets)` 经 `simpleCards`（`<div
//! class="(movieset|issuer)` 切块，链接正则 `/moviesets/[^"?]+`）；
//! `/issuer` 调 `html(<site>/issuer?page=<页>&sort=<sort 或 3>)` 经
//! `simpleCards`（链接 `/issuer/[^"?]+`）；`/best` 调
//! `html(<site>/best)`（第 1 页）或 `html(<site>/best/thisweek?page=<页>)`；
//! `/movie/new` 调 `html(<site>/movie/new)`（第 1 页且无 sort）或
//! `html(<site>/movie/new/<sort 或 2>-2-<页>)`；`/movie/subtitle` 同理
//! （默认 sort `1`）；`/menu/…` 调 `html(<site><分类>)`（第 1 页且无
//! sort）或 `html(<site><分类>/<sort 或 5>-2-<页>/)`；其余调
//! `html(<site><分类>)`（第 1 页）或
//! `html(<site><分类去尾斜杠>/<页>-2-1/)`；取不到页面时插一条
//! `vod_id=cf-blocked` 的提示卡；分页取 `pageInfo`，上限
//! `MAX_PAGE=2000`，无页码信息时按条数推断（≥15 条则下一页，`/best`
//! 为 ≥40 条）。
//! `cards(html)`：按 `<div class="(?:mgn-item|mg-item mg-card)"` 的出现
//! 位置切块，每块取到下一块开头、或 `min(块首+6000, 全长)`；先试正则
//! `<a href="(/movie/detail/([a-f0-9\-]+)\.html)"[^>]*title="([^"]*)"`，
//! `vod_id` 为第 2 组（uuid），标题为第 3 组经 `unescape`+trim；失败再
//! 试 `<a href="(/movie/detail/([a-f0-9\-]+)\.html)"[^>]*>(.*?)</a>`
//! （DOTALL），标题经 `clean`（去标签+unescape）；两正则皆不中则跳过该
//! 块；封面取首个 `<img[^>]+src="([^"]+)"`，以 `//` 开头则补 `https:`；
//! 备注列表依次取 year/type/subtitle 三个 badge（`mg[n]?-badge--?year|type|subtitle[^>]*>([^<]+)`，
//! unescape+trim），用 `" "` 连接；女优取全部
//! `mg[n]?-actress[^>]*>\s*<a[^>]*>([^<]+)`（最多 8 个，非空），
//! `vod_actor` 用 `","` 连接。
//! 搜索：依次试 `<site>/search/<编码词>[?page=<页>]` 与
//! `<site>/search?keyword=<编码词>`，取 `cards`，上限 60 条。
//! 详情：`/actor/detail/` 或 `/actor/movie/` 开头取 `<title>`（去 ` | `
//! 后缀）、og:image、演员（`actor-name|actress-link` 后的 `<a>`，最多
//! 12 个）、meta description，`vod_play_url=暂无影片$<URL>`；
//! `/moviesets/` 或 `/issuer/` 开头取前 3 页 `cards` 作分集
//! （`片名$<vod_id>`，第 2–3 页为 `?page=<n>&sort=5`）；普通影片调
//! `html(<site>/movie/detail/<id>.html)`，取同上元数据，
//! `vod_play_url=正片$<URL>`（URL 为详情页本身）。
//! 取流 `resolveSignedUrl`：从详情页取 `id="v2-player" src`、`<iframe
//! src="/[Pp]layer…">` 或 `"embedUrl":"…"`，逐个取播放器页；从中取
//! `movieId`/`sessionId`/`guidId`/`apiSecret`（`key[:=]'…'` 或 `"…"`）
//! 与 `initialSignedUrl`/`signedUrl`/`https?://videocdn…m3u8`；四项
//! 齐全时调 `token`：POST `<site>/api/token/generate`，JSON
//! `{"sessionId","movieId","guidId","timestamp":<秒>,"url":"<site>/player/v2","signature":"<HMAC-SHA256 Base64>"}`，
//! 其中签名输入为 `<movieId>|<秒>|<sessionId>`，密钥为 `apiSecret`，头
//! `Content-Type: application/json`、`Origin`、Referer、UA_D；成功返回
//! `<site>/<guid>/playlist.m3u8?token=<编码>&expires=<expires>[&token_path=<tokenPath>]`
//! （`token` 缓存于 `tokCache`，键 `<movieId>|<sessionId>`）；无 token
//! 时回退已签名的 URL 或页内 `extractM3u8`（`var source|now|url|videoUrl|src|playUrl = "…"`
//! 或任意 `.m3u8`，排除含 `/Player?` 或 `/player/` 的）；
//! `playerContent` 返回 parse 0 + 签名的 m3u8 URL（jar 原文是
//! `JR.hls(<详情 URL>)` 本地代理中继地址，核心里改为直接返回签名的
//! m3u8 URL）或 parse 1 + 原 URL（msg“未解析到播放地址，交给播放器嗅探”）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine as _;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use sha2::{Digest as _, Sha256};

use crate::error::ApiResult;

use super::{category_json, client, episode_json, item_json};

const SITE: &str = "https://www.javrate.com";
const UA_D: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MAX_PAGE: i64 = 2000;

const CATS: &[(&str, &str)] = &[
    ("/movie/new", "最新更新"),
    ("/menu/uncensored", "无码A片"),
    ("/menu/censored", "日本A片"),
    ("/menu/chinese", "国产AV"),
    ("/movie/subtitle", "中文字幕"),
    ("/best", "最多人看"),
    ("__tags", "标签找片"),
    ("/actor/list/1-0-1.html", "AV女优"),
    ("/moviesets", "专辑系列"),
    ("/issuer", "片商厂牌"),
];

static PAGE_CACHE: Lazy<Mutex<std::collections::HashMap<String, (Instant, String)>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));
static TOK_CACHE: Lazy<Mutex<std::collections::HashMap<String, String>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn urlenc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

fn html_unescape(s: &str) -> String {
    let mut out = s.to_string();
    for (from, to) in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&nbsp;", " "),
    ] {
        out = out.replace(from, to);
    }
    let re_num = Regex::new(r"&#(\d+);").unwrap();
    while let Some(cap) = re_num.captures(&out) {
        let n: u32 = cap[1].parse().unwrap_or(0);
        let ch = char::from_u32(n).unwrap_or('\u{fffd}').to_string();
        out = out.replacen(&cap[0], &ch, 1);
    }
    let re_hex = Regex::new(r"&#x([0-9a-fA-F]+);").unwrap();
    while let Some(cap) = re_hex.captures(&out) {
        let n: u32 = u32::from_str_radix(&cap[1], 16).unwrap_or(0);
        let ch = char::from_u32(n).unwrap_or('\u{fffd}').to_string();
        out = out.replacen(&cap[0], &ch, 1);
    }
    out
}

fn clean_html(s: &str) -> String {
    let re_tag = Regex::new(r"<[^>]+>").unwrap();
    html_unescape(re_tag.replace_all(s, "").as_ref()).trim().to_string()
}

fn first_img(block: &str) -> String {
    let re = Regex::new(r#"<img[^>]+src="([^"]+)""#).unwrap();
    match re.captures(block) {
        Some(cap) => {
            let s = cap[1].to_string();
            if s.starts_with("//") {
                format!("https:{s}")
            } else {
                s
            }
        }
        None => String::new(),
    }
}

async fn fetch_direct(url: &str, referer: Option<&str>) -> Option<String> {
    let mut req = match client() {
        Ok(c) => c.get(url).header("User-Agent", UA_D).header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ).header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8"),
        Err(_) => return None,
    };
    if let Some(r) = referer {
        req = req.header("Referer", r);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.text().await.ok()
}

async fn html(url: &str) -> String {
    {
        let cache = PAGE_CACHE.lock().unwrap();
        if let Some((t, body)) = cache.get(url) {
            if t.elapsed() < Duration::from_secs(30) {
                return body.clone();
            }
        }
    }
    let mut body = String::new();
    let jina_url = format!("https://r.jina.ai/{url}");
    if let Ok(c) = client() {
        if let Ok(resp) = c
            .get(&jina_url)
            .header("User-Agent", UA_D)
            .header("Accept", "text/html")
            .header("X-Return-Format", "html")
            .header("X-No-Cache", "true")
            .send()
            .await
        {
            if resp.status().is_success() {
                if let Ok(text) = resp.text().await {
                    let lower = text.to_lowercase();
                    if text.len() >= 200
                        && !lower.contains("just a moment")
                        && !lower.contains("rate limit")
                    {
                        body = text;
                    }
                }
            }
        }
    }
    if body.is_empty() {
        if let Some(text) = fetch_direct(url, None).await {
            body = text;
        }
    }
    if !body.is_empty() {
        PAGE_CACHE
            .lock()
            .unwrap()
            .insert(url.to_string(), (Instant::now(), body.clone()));
    }
    body
}

fn split_blocks(html: &str, pat: &str, cap: usize) -> Vec<String> {
    let re = Regex::new(pat).unwrap();
    let starts: Vec<usize> = re.find_iter(html).map(|m| m.start()).collect();
    let mut out = Vec::new();
    for (i, &s) in starts.iter().enumerate() {
        let end = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            html.len().min(s + cap)
        };
        out.push(html[s..end].to_string());
    }
    out
}

fn cards(page_html: &str) -> Vec<Value> {
    let re1 = Regex::new(
        r##"<a href="(/movie/detail/([a-f0-9\-]+)\.html)"[^>]*title="([^"]*)""##,
    )
    .unwrap();
    let re2 = Regex::new(
        r##"(?s)<a href="(/movie/detail/([a-f0-9\-]+)\.html)"[^>]*>(.*?)</a>"##,
    )
    .unwrap();
    let badge_pats = [
        Regex::new(r"mg[n]?-badge--?year[^>]*>([^<]+)").unwrap(),
        Regex::new(r"mg[n]?-badge--?type[^>]*>([^<]+)").unwrap(),
        Regex::new(r"mg[n]?-badge--?subtitle[^>]*>([^<]+)").unwrap(),
    ];
    let re_actress = Regex::new(r"mg[n]?-actress[^>]*>\s*<a[^>]*>([^<]+)").unwrap();
    let mut out = Vec::new();
    for block in split_blocks(page_html, r#"<div class="(?:mgn-item|mg-item mg-card)""#, 6000) {
        let (vod_id, title) = if let Some(cap) = re1.captures(&block) {
            (cap[2].to_string(), html_unescape(&cap[3]).trim().to_string())
        } else if let Some(cap) = re2.captures(&block) {
            (cap[2].to_string(), clean_html(&cap[3]))
        } else {
            continue;
        };
        if title.is_empty() {
            continue;
        }
        let cover = first_img(&block);
        let mut remarks: Vec<String> = Vec::new();
        for bp in &badge_pats {
            if let Some(cap) = bp.captures(&block) {
                let t = html_unescape(&cap[1]).trim().to_string();
                if !t.is_empty() {
                    remarks.push(t);
                }
            }
        }
        let mut actresses: Vec<String> = Vec::new();
        for cap in re_actress.captures_iter(&block) {
            if actresses.len() >= 8 {
                break;
            }
            let t = html_unescape(&cap[1]).trim().to_string();
            if !t.is_empty() {
                actresses.push(t);
            }
        }
        let mut it = item_json(&vod_id, &title, &cover, &remarks.join(" "));
        it["vod_actor"] = json!(actresses.join(","));
        out.push(it);
    }
    out
}

fn actor_cards(page_html: &str) -> Vec<Value> {
    let re = Regex::new(
        r##"<a href="(/actor/detail/([a-f0-9\-]+)\.html)"[^>]*title="([^"]*)""##,
    )
    .unwrap();
    let re_badge = Regex::new(r"mg[n]?-badge[^>]*>([^<]+)").unwrap();
    let mut out = Vec::new();
    for block in split_blocks(page_html, r#"<div class="actor-card"#, 8000) {
        let Some(cap) = re.captures(&block) else {
            continue;
        };
        let title = html_unescape(&cap[3]).trim().to_string();
        if title.is_empty() {
            continue;
        }
        let mut remarks: Vec<String> = Vec::new();
        for c in re_badge.captures_iter(&block) {
            let t = html_unescape(&c[1]).trim().to_string();
            if !t.is_empty() {
                remarks.push(t);
            }
        }
        let mut it = item_json(&cap[1], &title, &first_img(&block), &remarks.join(" "));
        it["tag"] = json!("folder");
        out.push(it);
    }
    out
}

fn simple_cards(page_html: &str, link_pat: &str) -> Vec<Value> {
    let mut blocks = split_blocks(
        page_html,
        r#"<div class="(?:movieset|issuer)[^"]*""#,
        6000,
    );
    if blocks.is_empty() {
        let re = Regex::new(&format!(r#"<a[^>]+href="{link_pat}""#)).unwrap();
        let starts: Vec<usize> = re.find_iter(page_html).map(|m| m.start()).collect();
        for (i, &s) in starts.iter().enumerate() {
            let end = if i + 1 < starts.len() {
                starts[i + 1]
            } else {
                page_html.len().min(s + 6000)
            };
            blocks.push(page_html[s..end].to_string());
        }
    }
    let re_link = Regex::new(&format!(r#"(?s)href="({link_pat})"[^>]*>(.*?)</a>"#)).unwrap();
    let mut out = Vec::new();
    for block in blocks {
        let Some(cap) = re_link.captures(&block) else {
            continue;
        };
        let title = clean_html(&cap[2]);
        if title.is_empty() {
            continue;
        }
        out.push(item_json(&cap[1], &title, &first_img(&block), ""));
    }
    out
}

fn page_info(page_html: &str) -> i64 {
    let pats = [
        r"(?:page|p)(?:=|/)(\d+)[^0-9]{0,20}?(?:页|共)",
        r"共\s*(\d+)\s*页",
        r"/页\s*(\d+)",
    ];
    for p in pats {
        if let Ok(re) = Regex::new(p) {
            if let Some(cap) = re.captures(page_html) {
                if let Ok(n) = cap[1].parse::<i64>() {
                    return n;
                }
            }
        }
    }
    0
}

fn meta_name(page_html: &str, fallback: &str) -> String {
    let re = Regex::new(r"<title>([^<]+)</title>").unwrap();
    match re.captures(page_html) {
        Some(cap) => {
            let mut s = html_unescape(&cap[1]);
            if let Some(pos) = s.find('|') {
                s.truncate(pos);
            }
            let s = s.trim().to_string();
            if s.is_empty() {
                fallback.to_string()
            } else {
                s
            }
        }
        None => fallback.to_string(),
    }
}

fn meta_pic(page_html: &str) -> String {
    let re1 = Regex::new(r#"property="og:image"[^>]+content="([^"]+)""#).unwrap();
    let re2 = Regex::new(r#"content="([^"]+)"[^>]+property="og:image""#).unwrap();
    for re in [&re1, &re2] {
        if let Some(cap) = re.captures(page_html) {
            let s = cap[1].to_string();
            return if s.starts_with("//") {
                format!("https:{s}")
            } else {
                s
            };
        }
    }
    String::new()
}

fn meta_desc(page_html: &str) -> String {
    let re = Regex::new(r#"name="description"[^>]+content="([^"]+)""#).unwrap();
    match re.captures(page_html) {
        Some(cap) => html_unescape(&cap[1]).trim().to_string(),
        None => String::new(),
    }
}

fn meta_actors(page_html: &str) -> String {
    let re = Regex::new(r"(?:actor-name|actress-link)[^>]*>\s*<a[^>]*>([^<]+)").unwrap();
    let mut out: Vec<String> = Vec::new();
    for cap in re.captures_iter(page_html) {
        if out.len() >= 12 {
            break;
        }
        let t = html_unescape(&cap[1]).trim().to_string();
        if !t.is_empty() {
            out.push(t);
        }
    }
    out.join(",")
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        let h = Sha256::digest(key);
        k[..32].copy_from_slice(&h);
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(msg);
    let inner_hash = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_hash);
    outer.finalize().into()
}

fn grab(page_html: &str, key: &str) -> String {
    let re1 = Regex::new(&format!(r"{key}\s*[:=]\s*'([^']+)'")).unwrap();
    if let Some(cap) = re1.captures(page_html) {
        return cap[1].to_string();
    }
    let re2 = Regex::new(&format!(r#"{key}\s*[:=]\s*"([^"]+)""#)).unwrap();
    match re2.captures(page_html) {
        Some(cap) => cap[1].to_string(),
        None => String::new(),
    }
}

async fn token(movie_id: &str, session_id: &str, api_secret: &str, guid_id: &str) -> String {
    let key = format!("{movie_id}|{session_id}");
    {
        let cache = TOK_CACHE.lock().unwrap();
        if let Some(v) = cache.get(&key) {
            if !v.is_empty() {
                return v.clone();
            }
        }
    }
    let ts = now_secs();
    let sig_input = format!("{movie_id}|{ts}|{session_id}");
    let sig = base64::engine::general_purpose::STANDARD.encode(hmac_sha256(api_secret.as_bytes(), sig_input.as_bytes()));
    let body = json!({
        "sessionId": session_id,
        "movieId": movie_id,
        "guidId": guid_id,
        "timestamp": ts,
        "url": format!("{SITE}/player/v2"),
        "signature": sig,
    })
    .to_string();
    let url = format!("{SITE}/api/token/generate");
    let resp = match client() {
        Ok(c) => c
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Origin", SITE)
            .header("Referer", format!("{SITE}/"))
            .header("User-Agent", UA_D)
            .body(body)
            .send()
            .await,
        Err(_) => return String::new(),
    };
    let Ok(resp) = resp else {
        return String::new();
    };
    if !resp.status().is_success() {
        return String::new();
    }
    let Ok(v) = resp.json::<Value>().await else {
        return String::new();
    };
    let data = v.get("data").cloned().unwrap_or(Value::Null);
    let tok = data.get("token").and_then(|x| x.as_str()).unwrap_or("");
    if tok.is_empty() {
        return String::new();
    }
    let expires = data.get("expires").and_then(|x| x.as_i64()).unwrap_or(0);
    let mut out = format!(
        "{SITE}/{}{}playlist.m3u8?token={}&expires={}",
        if guid_id.is_empty() { String::new() } else { format!("{guid_id}/") },
        "",
        urlenc(tok),
        expires
    );
    let token_path = data.get("tokenPath").and_then(|x| x.as_str()).unwrap_or("");
    if !token_path.is_empty() {
        out.push_str(&format!("&token_path={token_path}"));
    }
    TOK_CACHE.lock().unwrap().insert(key, out.clone());
    out
}

fn extract_m3u8(page_html: &str) -> String {
    let pats = [
        r#"var\s+source\s*=\s*["']([^"']+)"#,
        r#"var\s+(?:now|url|videoUrl|src|playUrl)\s*=\s*["']([^"']+)"#,
        r#"["'](https?://[^"'<>\s]+\.m3u8[^"'<>\s]*)"#,
    ];
    for p in pats {
        if let Ok(re) = Regex::new(p) {
            if let Some(cap) = re.captures(page_html) {
                let mut s = html_unescape(&cap[1]);
                if s.starts_with("//") {
                    s = format!("https:{s}");
                }
                if !s.contains("/Player?") && !s.contains("/player/") && s.contains(".m3u8") {
                    return s;
                }
            }
        }
    }
    String::new()
}

async fn resolve_signed_url(detail_url: &str) -> String {
    let page_html = html(detail_url).await;
    if page_html.is_empty() {
        return String::new();
    }
    let pats = [
        r#"id="v2-player"[^>]*src="([^"]+)""#,
        r#"<iframe[^>]+src="(/[Pp]layer[^"]*)""#,
        r#""embedUrl":\s*"([^"]+)""#,
    ];
    let mut candidates: Vec<String> = Vec::new();
    for p in pats {
        if let Ok(re) = Regex::new(p) {
            if let Some(cap) = re.captures(&page_html) {
                candidates.push(html_unescape(&cap[1]).replace("\\/", "/"));
            }
        }
    }
    for cand in candidates {
        let player_url = if cand.starts_with("http") {
            cand.clone()
        } else {
            format!("{SITE}{cand}")
        };
        let player_html = match fetch_direct(&player_url, Some(detail_url)).await {
            Some(h) if !h.is_empty() => h,
            _ => continue,
        };
        let movie_id = grab(&player_html, "movieId");
        let session_id = grab(&player_html, "sessionId");
        let guid_id = grab(&player_html, "guidId");
        let api_secret = grab(&player_html, "apiSecret");
        let mut signed = String::new();
        let re1 = Regex::new(r"initialSignedUrl:\s*'([^']+)'").unwrap();
        let re2 = Regex::new(r"signedUrl:\s*'([^']+)'").unwrap();
        let re3 = Regex::new(r#"(https?://videocdn[^\s\"']+m3u8[^\s\"']*)"#).unwrap();
        if let Some(cap) = re1.captures(&player_html) {
            signed = cap[1].to_string();
        } else if let Some(cap) = re2.captures(&player_html) {
            signed = cap[1].to_string();
        } else if let Some(cap) = re3.captures(&player_html) {
            signed = cap[1].to_string();
        }
        let signed = html_unescape(&signed).replace("\\/", "/");
        if !movie_id.is_empty() && !api_secret.is_empty() && !session_id.is_empty() && !signed.is_empty() {
            let tok = token(&movie_id, &session_id, &api_secret, &guid_id).await;
            if !tok.is_empty() {
                return tok;
            }
        }
        if !signed.is_empty() {
            return signed;
        }
        let ext = extract_m3u8(&player_html);
        if !ext.is_empty() {
            return ext;
        }
    }
    String::new()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let (items, has_more) = if category_id == "__tags" {
        let tag = "中出";
        let url = format!("{SITE}/keywords/movie/{}?page={page}", urlenc(tag));
        let page_html = html(&url).await;
        let items = cards(&page_html);
        let total = page_info(&page_html);
        let has_more = if total > 0 {
            page < total.min(MAX_PAGE)
        } else {
            items.len() >= 15
        };
        (items, has_more)
    } else if category_id.starts_with("/actor/list") {
        let url = if page == 1 {
            format!("{SITE}/actor/list/1-0-1.html")
        } else {
            format!("{SITE}/actor/list/2-0-{page}.html")
        };
        let page_html = html(&url).await;
        let items = actor_cards(&page_html);
        let has_more = items.len() >= 25;
        (items, has_more)
    } else if category_id == "/moviesets" {
        let page_html = html(&format!("{SITE}/moviesets")).await;
        let items = simple_cards(&page_html, "/moviesets/[^\"?]+");
        (items, false)
    } else if category_id == "/issuer" {
        let url = format!("{SITE}/issuer?page={page}&sort=3");
        let page_html = html(&url).await;
        let items = simple_cards(&page_html, "/issuer/[^\"?]+");
        let has_more = !items.is_empty();
        (items, has_more)
    } else if category_id == "/best" {
        let url = if page == 1 {
            format!("{SITE}/best")
        } else {
            format!("{SITE}/best/thisweek?page={page}")
        };
        let page_html = html(&url).await;
        let items = cards(&page_html);
        let has_more = items.len() >= 40;
        (items, has_more)
    } else if category_id == "/movie/new" || category_id == "/movie/subtitle" {
        let sort = if category_id == "/movie/new" { "2" } else { "1" };
        let url = if page == 1 {
            format!("{SITE}{category_id}")
        } else {
            format!("{SITE}{category_id}/{sort}-2-{page}")
        };
        let page_html = html(&url).await;
        let items = cards(&page_html);
        let total = page_info(&page_html);
        let has_more = if total > 0 {
            page < total.min(MAX_PAGE)
        } else {
            items.len() >= 15
        };
        (items, has_more)
    } else if let Some(menu) = category_id.strip_prefix("/menu/") {
        let url = if page == 1 {
            format!("{SITE}{category_id}")
        } else {
            format!("{SITE}/menu/{menu}/5-2-{page}/")
        };
        let page_html = html(&url).await;
        let items = cards(&page_html);
        let total = page_info(&page_html);
        let has_more = if total > 0 {
            page < total.min(MAX_PAGE)
        } else {
            items.len() >= 15
        };
        (items, has_more)
    } else {
        let url = if page == 1 {
            format!("{SITE}{category_id}")
        } else {
            format!(
                "{SITE}{}/{page}-2-1/",
                category_id.trim_end_matches('/')
            )
        };
        let page_html = html(&url).await;
        let mut items = cards(&page_html);
        if page_html.is_empty() {
            items = vec![item_json(
                "cf-blocked",
                "这一页没取到（站点盾较严）",
                "",
                "稍后重试，或把这个源挂到你自己的中继上",
            )];
        }
        let total = page_info(&page_html);
        let has_more = if total > 0 {
            page < total.min(MAX_PAGE)
        } else {
            items.len() >= 15
        };
        (items, has_more)
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let detail_url = if id.starts_with("http") {
        id.to_string()
    } else if id.starts_with('/') {
        format!("{SITE}{id}")
    } else {
        format!("{SITE}/movie/detail/{id}.html")
    };
    if id.contains("/actor/detail/") || id.contains("/actor/movie/") {
        let page_html = html(&detail_url).await;
        if page_html.is_empty() {
            return Ok(json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}));
        }
        let title = meta_name(&page_html, id);
        let mut episodes: Vec<Value> = Vec::new();
        episodes.push(episode_json(&detail_url, "暂无影片", id));
        return Ok(json!({
            "id": id, "title": title, "cover": meta_pic(&page_html),
            "synopsis": meta_desc(&page_html),
            "extra": {"vod_actor": meta_actors(&page_html)},
            "episodes": episodes,
        }));
    }
    if id.contains("/moviesets/") || id.contains("/issuer/") || id.contains("/Issuer/") {
        let base = detail_url.split('?').next().unwrap_or(&detail_url).to_string();
        let page1 = html(&detail_url).await;
        let mut all_items: Vec<Value> = Vec::new();
        all_items.extend(cards(&page1));
        for p in 2..=3 {
            let h = html(&format!("{base}?page={p}&sort=5")).await;
            let items = cards(&h);
            if items.is_empty() {
                break;
            }
            all_items.extend(items);
        }
        let mut episodes: Vec<Value> = Vec::new();
        for c in all_items.iter().take(500) {
            let vid = c["id"].as_str().unwrap_or("").to_string();
            let t = c["title"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&vid, &t, id));
        }
        let title = meta_name(&page1, id);
        return Ok(json!({
            "id": id, "title": title, "cover": meta_pic(&page1),
            "synopsis": meta_desc(&page1),
            "extra": {"vod_actor": meta_actors(&page1), "vod_remarks": format!("收录 {} 部", episodes.len())},
            "episodes": episodes,
        }));
    }
    let page_html = html(&detail_url).await;
    let title = meta_name(&page_html, id);
    let synopsis = if page_html.is_empty() {
        "详情取页失败：站点盾较严，稍后重试".to_string()
    } else {
        meta_desc(&page_html)
    };
    let mut episodes: Vec<Value> = Vec::new();
    episodes.push(episode_json(&detail_url, "正片", id));
    Ok(json!({
        "id": id, "title": title, "cover": meta_pic(&page_html),
        "synopsis": synopsis,
        "extra": {"vod_actor": meta_actors(&page_html)},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = urlenc(query.trim());
    let urls = [
        format!("{SITE}/search/{enc}"),
        format!("{SITE}/search?keyword={enc}"),
    ];
    for url in urls {
        let page_html = html(&url).await;
        let items = cards(&page_html);
        if !items.is_empty() {
            let items: Vec<Value> = items.into_iter().take(60).collect();
            return Ok(json!({"items": items}));
        }
    }
    Ok(json!({"items": []}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let detail_url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{SITE}/movie/detail/{video_id}.html")
    };
    let resolved = if detail_url.contains("/play/id/") || detail_url.contains(".m3u8") {
        detail_url.clone()
    } else {
        resolve_signed_url(&detail_url).await
    };
    if resolved.is_empty() {
        return Ok(json!({
            "url": detail_url,
            "parse": 1,
            "msg": "未解析到播放地址，交给播放器嗅探",
            "header": {"User-Agent": UA_D, "Referer": format!("{SITE}/")},
        }));
    }
    Ok(json!({
        "url": resolved,
        "header": {"User-Agent": UA_D, "Referer": format!("{SITE}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_ten_no_tools() {
        assert_eq!(CATS.len(), 10);
        assert!(!CATS.iter().any(|(id, _)| *id == "__tools"));
    }

    #[test]
    fn cards_parse() {
        let html = r#"<div class="mgn-item"><a href="/movie/detail/123e4567-e89b-12d3-a456-426614174000.html" title="测试影片"><img src="https://cdn/c.jpg"></a><span class="mg-badge--year">2024</span><span class="mg-badge--type">无码</span><span class="mg-actress"><a>演员A</a></span></div>"#;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "123e4567-e89b-12d3-a456-426614174000");
        assert_eq!(items[0]["title"], "测试影片");
        assert_eq!(items[0]["vod_actor"], "演员A");
    }

    #[test]
    fn meta_name_cuts_at_pipe() {
        let html = "<title>影片名 | Javrate</title>";
        assert_eq!(meta_name(html, "x"), "影片名");
    }

    #[test]
    fn hmac_sha256_rfc4231_case2() {
        // RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?".
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            hex::encode(mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }
}
