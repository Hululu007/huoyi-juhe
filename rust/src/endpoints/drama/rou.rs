//! 肉视频：Next.js RSC 站，列表与详情都嵌在页内 RSC 数据里。
//!
//! 与 Dart 的 ZakaRouAmns 一一对应。分类与站内导航 1:1（25 项，含
//! 文件夹分类：全部题材 /t、四个主分类 /t/探花 等）。分页：路径后补
//! `?page=<页>`（已有查询串时用 `&`）。列表解析：取页内 `videos:` /
//! `list:` / `seriesList:` 三个 RSC 数组，去掉 `$R[n]=` 引用前缀后按
//! JSON 解析。详情：`/s/<id>` 为剧集（取 `episodes:` 数组），`/v/<id>`
//! 为单视频（取 `video:` 对象）。取流：GET `/api/hls/<id>`，跟随 302
//! 落 CDN 清单；若回 `ev:{d,k}` 则按字节减 k 解出 videoUrl。清单播放
//! 须带头：Referer 为 host + "/home"。

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: &[&str] = &[
    "https://rou666.cc",
    "https://rou666.net",
    "https://rou666.com",
    "https://rou01.cc",
    "https://rou168.com",
    "https://rou1.pw",
    "https://rouav.sbs",
    "https://rou1.mom",
    "https://rou1.art",
    "https://rouxxx.net",
    "https://rou1.sbs",
    "https://rouxxx.sbs",
    "https://rouxxx.cc",
    "https://rou163.top",
    "https://rou2.sbs",
    "https://rou2.mom",
    "https://rou1.men",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[路径, 名]，与站内导航 1:1；folder@ 为文件夹分类。
const CATEGORIES: &[(&str, &str)] = &[
    ("/series?f=fresh", "最新更新"),
    ("/v", "视频库·5.5万部"),
    ("/series", "剧集库·AI短剧"),
    ("/t/中文字幕", "中文字幕"),
    ("/t/AI短劇", "AI短剧"),
    ("/t/探花", "探花"),
    ("/t/自拍流出", "自拍流出"),
    ("/t/國產AV", "国产AV"),
    ("/t/日本", "日本AV"),
    ("/t/麻豆傳媒", "麻豆传媒"),
    ("/t/OnlyFans", "OnlyFans"),
    ("/t/中出", "中出"),
    ("/t/巨乳", "巨乳"),
    ("/t/人妻", "人妻"),
    ("/t/熟女", "熟女"),
    ("/t/NTR", "NTR"),
    ("/t/絲襪", "丝袜"),
    ("/t/都市", "都市"),
    ("/t/後宮", "后宫"),
    ("folder@/t", "全部题材"),
    ("folder@/t/探花", "主分类·探花"),
    ("folder@/t/國產AV", "主分类·国产AV"),
    ("folder@/t/麻豆傳媒", "主分类·麻豆传媒"),
    ("folder@/t/OnlyFans", "主分类·OnlyFans"),
];

/// 是否像 Cloudflare 拦截页。
fn is_challenge(body: &str) -> bool {
    let lower = body.to_lowercase();
    lower.contains("just a moment")
        || lower.contains("cf_chl")
        || lower.contains("challenge-form")
        || lower.contains("attention required")
        || body.contains("继续访问")
}

/// 正文可用：够长且无 CF 挑战标记。
fn looks_ok(body: &str) -> bool {
    body.len() >= 3000 && !is_challenge(body)
}

/// 按顺序试各 host，首个返回可用正文的即用；返回（所用 host，正文）。
async fn fetch(path: &str) -> ApiResult<(String, String)> {
    let mut last_err = ApiError::Internal("肉视频请求失败".into());
    for host in HOSTS {
        let url = if path.starts_with("http") {
            path.to_string()
        } else {
            format!("{host}{path}")
        };
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,zh-TW;q=0.8,en;q=0.7")
            .header("Upgrade-Insecure-Requests", "1")
            .header("Referer", format!("{host}/home"))
            .send()
            .await;
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if resp.status().as_u16() != 200 {
            last_err = ApiError::Internal(format!("肉视频 HTTP {}", resp.status().as_u16()));
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if !looks_ok(&text) {
            last_err = ApiError::Internal("肉视频返回内容不可用".into());
            continue;
        }
        return Ok((host.to_string(), text));
    }
    Err(last_err)
}

/// 路径编码：保留 `/` `?` `=` `&` 与 ASCII 可见字符，非 ASCII 成 %XX。
fn enc_path(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'~'
            | b'/'
            | b'?'
            | b'='
            | b'&'
            | b'%' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 分页：页<=1 原样，否则补 `?page=` 或 `&page=`。
fn page_url(path: &str, page: i64) -> String {
    if page <= 1 {
        return path.to_string();
    }
    let sep = if path.contains('?') { '&' } else { '?' };
    format!("{path}{sep}page={page}")
}

/// 秒数转时长文本：>=1 小时为 h:mm:ss，否则为 m:ss。
fn fmt_dur(secs: f64) -> String {
    let total = secs.round() as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// 解常见 HTML 实体。
fn unesc(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 从 start（指向 `[` 或 `{`）按括号平衡截取，处理字符串与转义。
fn slice_balanced(text: &str, start: usize) -> Option<(usize, &str)> {
    let bytes = text.as_bytes();
    let open = bytes[start];
    let close = if open == b'[' { b']' } else { b'}' };
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else if b == b'"' {
            in_str = true;
        } else if b == open {
            depth += 1;
        } else if b == close {
            depth -= 1;
            if depth == 0 {
                return Some((i + 1, &text[start..i + 1]));
            }
        }
        i += 1;
    }
    None
}

/// 取 key 后的第一个 JSON 数组/对象：跳过 `$R[n]=` 引用前缀。
fn extract_json_after<'a>(html: &'a str, key: &str) -> Option<&'a str> {
    let pos = html.find(key)? + key.len();
    let rest = &html[pos..];
    let mut i = 0;
    while i < rest.len() && rest.as_bytes()[i].is_ascii_whitespace() {
        i += 1;
    }
    if rest[i..].starts_with("$R[") {
        let close = rest[i..].find(']')?;
        let mut j = i + close + 1;
        while j < rest.len() && rest.as_bytes()[j].is_ascii_whitespace() {
            j += 1;
        }
        if j < rest.len() && rest.as_bytes()[j] == b'=' {
            j += 1;
            while j < rest.len() && rest.as_bytes()[j].is_ascii_whitespace() {
                j += 1;
            }
            i = j;
        }
    }
    if i >= rest.len() || (rest.as_bytes()[i] != b'[' && rest.as_bytes()[i] != b'{') {
        return None;
    }
    let (_end, frag) = slice_balanced(rest, i)?;
    Some(frag)
}

/// RSC 载荷归一化：删 `$R[n]=`、余下 `$R[n]` 换 null、`!0`/`!1` 换布尔值、
/// `:undefined` 换 null、裸 key 加引号，再按 JSON 解析。
fn normalize_payload(frag: &str) -> Option<Value> {
    let ref_eq = Regex::new(r"\$R\[\d+\]=").unwrap();
    let step = ref_eq.replace_all(frag, "");
    let ref_only = Regex::new(r"\$R\[\d+\]").unwrap();
    let step = ref_only.replace_all(&step, "null");
    let step = step.replace("!0", "true").replace("!1", "false");
    let step = step.replace(":undefined", ":null");
    let key_re = Regex::new(r"([,{]\s*)([A-Za-z_$][A-Za-z0-9_$]*)\s*:").unwrap();
    let step = key_re.replace_all(&step, "${1}\"$2\":");
    serde_json::from_str(&step).ok()
}

/// 取页内指定 key 的 RSC 数组并解析。
fn extract_array(html: &str, key: &str) -> Vec<Value> {
    match extract_json_after(html, key).and_then(normalize_payload) {
        Some(Value::Array(arr)) => arr,
        _ => Vec::new(),
    }
}

/// 取页内指定 key 的 RSC 对象并解析。
fn extract_object(html: &str, key: &str) -> Option<Value> {
    match extract_json_after(html, key).and_then(normalize_payload) {
        Some(Value::Object(_)) => extract_json_after(html, key).and_then(normalize_payload),
        _ => None,
    }
}

fn str_field(v: &Value, keys: &[&str]) -> String {
    for k in keys {
        if let Some(s) = v.get(*k).and_then(|x| x.as_str()) {
            if !s.is_empty() {
                return s.to_string();
            }
        }
    }
    String::new()
}

fn num_field(v: &Value, keys: &[&str]) -> f64 {
    for k in keys {
        if let Some(n) = v.get(*k).and_then(|x| x.as_f64()) {
            return n;
        }
    }
    0.0
}

/// RSC 条目转视频卡片：带集数者为剧集（/s/<id>），否则为单视频（/v/<id>）。
fn add_cards(items: &[Value], out: &mut Vec<Value>, seen: &mut Vec<String>) {
    for entry in items {
        let id = str_field(entry, &["id"]);
        if id.len() < 8 || seen.contains(&id) {
            continue;
        }
        let title = unesc(&str_field(entry, &["name", "nameZh", "title"]));
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        let cover = str_field(entry, &["coverImageUrl", "cover", "poster"]);
        let episodes = num_field(entry, &["episodeCount", "totalEpisodes"]);
        if episodes > 0.0 {
            let remark = format!("共{}集", episodes as u64);
            out.push(item_json(&format!("/s/{id}"), &title, &cover, &remark));
        } else {
            let dur = num_field(entry, &["duration"]);
            let remark = if dur > 0.0 {
                fmt_dur(dur)
            } else {
                String::new()
            };
            out.push(item_json(&format!("/v/{id}"), &title, &cover, &remark));
        }
    }
}

/// 列表解析：videos: / list: / seriesList: 三处取卡去重。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for key in ["videos:", "list:", "seriesList:"] {
        let items = extract_array(html, key);
        add_cards(&items, &mut out, &mut seen);
        if out.len() >= 60 {
            break;
        }
    }
    out
}

/// taxonomy：取 /cat 页的 taxonomy 对象，返回目录项（路径，名，数量）。
fn taxonomy_items(html: &str) -> Vec<(String, String, usize)> {
    let mut out: Vec<(String, String, usize)> = Vec::new();
    let Some(tax) = extract_object(html, "taxonomy:") else {
        return out;
    };
    if let Some(cats) = tax.get("cats").and_then(|v| v.as_array()) {
        for c in cats {
            let name = str_field(c, &["name", "nameZh"]);
            let path = str_field(c, &["path", "slug"]);
            let count = num_field(c, &["count", "total", "num"]) as usize;
            if name.is_empty() || path.is_empty() {
                continue;
            }
            let full = if path.starts_with("/t") {
                path
            } else {
                format!("/t/{path}")
            };
            out.push((full, name, count));
        }
    }
    out
}

/// 解 ev 信封：d 经 base64 解，每字节减 k 成串后取 videoUrl。
fn decode_ev(body: &str) -> Option<String> {
    let re = Regex::new(r#"ev:\{d:"([^"]+)",k:(\d+)\}"#).unwrap();
    let caps = re.captures(body).or_else(|| {
        Regex::new(r#"\{d:"([A-Za-z0-9+/=_-]{20,})",k:(\d+)\}"#)
            .unwrap()
            .captures(body)
    })?;
    let d = caps.get(1)?.as_str();
    let k: i64 = caps.get(2)?.as_str().parse().ok()?;
    let raw = B64
        .decode(d)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(d))
        .ok()?;
    let mut text = String::new();
    for b in raw {
        let ch = char::from_u32((b as i32 - k as i32) as u16 as u32).unwrap_or('\0');
        text.push(ch);
    }
    let value: Value = serde_json::from_str(&text).ok()?;
    let url = str_field(&value, &["videoUrl", "url"]);
    if url.starts_with("http") {
        Some(url)
    } else {
        None
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(path, name)| category_json(path, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let mut tid = category_id.trim().to_string();
    if let Some(rest) = tid.strip_prefix("folder@") {
        tid = rest.to_string();
    }
    if tid.is_empty() {
        tid = "/v".to_string();
    }
    if tid == "/t" {
        let (_host, html) = fetch("/cat").await?;
        let items = taxonomy_items(&html);
        let cards: Vec<Value> = items
            .iter()
            .map(|(path, name, count)| {
                item_json(&format!("folder@{path}"), name, "", &format!("{count} 项"))
            })
            .collect();
        return Ok(json!({"items": cards, "has_more": false}));
    }
    let url = page_url(&tid, page);
    let (_host, html) = fetch(&enc_path(&url)).await?;
    let cards = parse_cards(&html);
    let has_more = cards.len() >= 20;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    if let Some(rest) = sid.strip_prefix("folder@") {
        let path = rest.to_string();
        let (_host, html) = fetch(&enc_path(&path)).await?;
        let cards = parse_cards(&html);
        let (_h2, cat_html) = fetch("/cat").await.unwrap_or_default();
        let count = taxonomy_items(&cat_html)
            .iter()
            .find(|(p, _, _)| *p == path)
            .map(|(_, _, c)| *c)
            .unwrap_or(cards.len());
        let synopsis = format!("目录 · {count} 项\n片库 · 本页 {} 部", cards.len());
        let mut episodes: Vec<Value> = Vec::new();
        if let Some(first) = cards.first() {
            let vid = first.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let vid = vid.trim_start_matches("/v/").trim_start_matches("/s/");
            if !vid.is_empty() {
                episodes.push(episode_json(vid, "直通本目录第一部", sid));
            }
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("肉视频该目录下暂无影片".into()));
        }
        return Ok(json!({
            "id": sid,
            "title": format!("目录 {path}"),
            "cover": "",
            "synopsis": synopsis,
            "extra": {},
            "episodes": episodes,
        }));
    }
    if let Some(rest) = sid.strip_prefix("/s/") {
        let id = rest.trim_matches('/').to_string();
        let (_host, html) = fetch(&enc_path(&format!("/s/{id}"))).await?;
        let series = extract_object(&html, "series:");
        let title = series
            .as_ref()
            .map(|s| unesc(&str_field(s, &["name", "nameZh", "title"])))
            .unwrap_or_default();
        if title.is_empty() {
            return Err(ApiError::Internal("肉视频未返回剧集资料".into()));
        }
        let cover = series
            .as_ref()
            .map(|s| str_field(s, &["coverImageUrl", "cover", "poster"]))
            .unwrap_or_default();
        let desc = series
            .as_ref()
            .map(|s| unesc(&str_field(s, &["description", "desc"])))
            .unwrap_or_default();
        let mut episodes: Vec<Value> = Vec::new();
        for ep in extract_array(&html, "episodes:") {
            let n = num_field(&ep, &["episode", "ep", "index"]) as u64;
            let eid = str_field(&ep, &["id"]);
            if eid.is_empty() {
                continue;
            }
            let name = if n > 0 {
                format!("第{n}集")
            } else {
                "正片".to_string()
            };
            episodes.push(episode_json(&eid, &name, sid));
        }
        if episodes.is_empty() {
            if let Some(first) = series
                .as_ref()
                .map(|s| str_field(s, &["firstEpisodeId", "firstVideoId"]))
                .filter(|s| !s.is_empty())
            {
                episodes.push(episode_json(&first, "第1集", sid));
            }
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("肉视频该剧集暂无分集".into()));
        }
        return Ok(json!({
            "id": sid,
            "title": title,
            "cover": cover,
            "synopsis": desc,
            "extra": {},
            "episodes": episodes,
        }));
    }
    let id = sid
        .trim_start_matches("/v/")
        .trim_start_matches('/')
        .to_string();
    let (_host, html) = fetch(&enc_path(&format!("/v/{id}"))).await?;
    let video = extract_object(&html, "video:");
    let title = video
        .as_ref()
        .map(|v| unesc(&str_field(v, &["name", "nameZh", "title"])))
        .unwrap_or_default();
    if title.is_empty() {
        return Err(ApiError::Internal("肉视频未返回影片资料".into()));
    }
    let cover = video
        .as_ref()
        .map(|v| str_field(v, &["coverImageUrl", "cover", "poster"]))
        .unwrap_or_default();
    let desc = video
        .as_ref()
        .map(|v| unesc(&str_field(v, &["description", "desc"])))
        .unwrap_or_default();
    let dur = video
        .as_ref()
        .map(|v| num_field(v, &["duration"]))
        .unwrap_or(0.0);
    let mut synopsis = String::new();
    if dur > 0.0 {
        synopsis.push_str(&format!("时长：{}\n", fmt_dur(dur)));
    }
    if !desc.is_empty() {
        synopsis.push_str(&desc);
    }
    let vid = format!("/v/{id}");
    let episodes = vec![episode_json(&id, "正片", &vid)];
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>();
    let path = format!("/search?q={q}&page=1");
    let (_host, html) = fetch(&path).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let id = vid
        .trim_start_matches("/api/hls/")
        .trim_start_matches("/v/")
        .trim_start_matches("/s/")
        .trim_start_matches('/')
        .to_string();
    if id.is_empty() {
        return Err(ApiError::Internal("肉视频该集没有播放地址".into()));
    }
    let mut last_err = ApiError::Internal("肉视频取流失败".into());
    for host in HOSTS {
        let url = format!("{host}/api/hls/{id}");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "*/*")
            .header("Referer", format!("{host}/home"))
            .send()
            .await;
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        let final_url = resp.url().to_string();
        if resp.status().as_u16() != 200 {
            last_err = ApiError::Internal(format!("肉视频取流 HTTP {}", resp.status().as_u16()));
            continue;
        }
        if final_url.contains(".m3u8") {
            return Ok(json!({"url": final_url}));
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if text.contains(".m3u8") {
            if let Some(m) = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#)
                .unwrap()
                .find(&text)
            {
                return Ok(json!({"url": m.as_str()}));
            }
        }
        if let Some(url) = decode_ev(&text) {
            return Ok(json!({"url": url}));
        }
        last_err = ApiError::Internal("肉视频取流未返回清单".into());
    }
    Err(last_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_24() {
        assert_eq!(CATEGORIES.len(), 24);
        assert_eq!(CATEGORIES[0], ("/series?f=fresh", "最新更新"));
        // 主分类是 folder@ 文件夹分类（catalog 会按 folder@ 下钻），
        // id 带 folder@ 前缀，不是不带前缀的裸路径。
        assert_eq!(CATEGORIES[23], ("folder@/t/OnlyFans", "主分类·OnlyFans"));
    }

    #[test]
    fn page_url_rules() {
        assert_eq!(page_url("/v", 1), "/v");
        assert_eq!(page_url("/v", 2), "/v?page=2");
        assert_eq!(page_url("/series?f=fresh", 2), "/series?f=fresh&page=2");
    }

    #[test]
    fn rsc_array_parses() {
        let html = r#"videos:$R[1]=[{id:"abc123456789",name:"Test",coverImageUrl:"https://x/c.jpg",duration:125.5,episodeCount:!0}]"#;
        let items = extract_array(html, "videos:");
        assert_eq!(items.len(), 1);
        let mut out = Vec::new();
        let mut seen = Vec::new();
        add_cards(&items, &mut out, &mut seen);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["id"], "/v/abc123456789");
        assert_eq!(out[0]["remark"], "2:06");
    }

    #[test]
    fn decode_ev_roundtrip() {
        let plain = r#"{"videoUrl":"https://cdn/x.m3u8"}"#;
        let k = 7i64;
        let enc: Vec<u8> = plain.bytes().map(|b| b.wrapping_add(k as u8)).collect();
        let d = B64.encode(&enc);
        let body = format!("ev:{{d:\"{d}\",k:{k}}}");
        assert_eq!(decode_ev(&body).unwrap(), "https://cdn/x.m3u8");
    }
}
