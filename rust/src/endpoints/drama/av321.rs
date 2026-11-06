//! 321AV：MacCMS 风格站，列表为 /vodplay 卡片，详情嵌 player_aaaa。
//!
//! 与 Dart 的 Zaka321avAmns 一一对应。分类与站内导航 1:1（5 项，含
//! 演员库 /actor.html 女优索引，作品卡片形式）。分页：路径去 .html
//! 后缀补 `-<页>.html`（如 /vodtype/20-2.html、/enter-2.html）。
//! 详情：player_aaaa JSON 的 url 字段经 slugOf 解码（URL 解码后再
//! base64 解，ss 数组取首项路径的末段，如 /cn/ktra-... 取
//! ktra-...；整段原样拼 /private-getvideo/ 会被 302 到死链）；
//! 分集 video_id 即 slug，play() 现取 `/private-getvideo/<slug>`
//! 的 playlist，优先 hersav 线与 QualityUrls 线（实测 1856 分片、
//! 7422 秒全长；首条 vckeepw 线无 Referer 只给 10 秒提示片、带站
//! 方 Referer 回 403，不可用）。
//! 搜索：`/index.php/ajax/suggest?mid=1&wd=<词>` 返回 JSON list。

use base64::{engine::general_purpose::URL_SAFE as B64URL, Engine as _};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of, with_query};

const HOSTS: &[&str] = &[
    "https://321av.fans",
    "https://321xav.cc",
    "https://321av.vip",
    "https://321av.xyz",
    "https://321av.top",
    "https://321av.men",
    "https://321av.icu",
    "https://321av.org",
    "https://321av.sbs",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[路径, 名]，与站内导航 1:1。
const CATEGORIES: &[(&str, &str)] = &[
    ("/enter", "推荐(首页)"),
    ("/vodtype/20.html", "有码影片"),
    ("/vodtype/21.html", "无码影片"),
    ("/vodtype/22.html", "中文字幕"),
    ("/actor.html", "演员库"),
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
    let mut last_err = ApiError::Internal("321AV 请求失败".into());
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
            .header("Referer", format!("{host}/enter"))
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
            last_err = ApiError::Internal(format!("321AV HTTP {}", resp.status().as_u16()));
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
            last_err = ApiError::Internal("321AV 返回内容不可用".into());
            continue;
        }
        return Ok((host.to_string(), text));
    }
    Err(last_err)
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

/// 分页：页<=1 原样；.html 结尾去后缀补 `-<页>.html`，否则直接补后缀。
fn page_url(path: &str, page: i64) -> String {
    if page <= 1 {
        return path.to_string();
    }
    if let Some(base) = path.strip_suffix(".html") {
        format!("{base}-{page}.html")
    } else {
        format!("{path}-{page}.html")
    }
}

/// 视频卡片：按 /vodplay 链接切块，块内取 data-src 封面、alt 片名、时长徽章。
fn parse_cards(html: &str) -> Vec<Value> {
    let img_re = Regex::new(r#"data-src="([^"]+)"[^>]*?alt="([^"]*)""#).unwrap();
    let dur_re = Regex::new(r#"bg-gray-800 bg-opacity-75">([^<]{2,12})<"#).unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a href=\"/vodplay/").skip(1) {
        let end = block.find('"').unwrap_or(block.len());
        let head = &block[..end];
        let digits: String = head.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() || seen.contains(&digits) {
            continue;
        }
        let (cover, title) = match img_re.captures(block) {
            Some(c) => (
                c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
                c.get(2).map(|m| unesc(m.as_str())).unwrap_or_default(),
            ),
            None => continue,
        };
        if title.is_empty() {
            continue;
        }
        seen.push(digits.clone());
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let id = format!("/vodplay/{digits}-1-1.html");
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 女优列表：按 /actordetail- 链接切块，块内取 data-src 封面、alt 名字。
fn parse_actors(html: &str) -> Vec<Value> {
    let img_re = Regex::new(r#"data-src="([^"]+)"[^>]*?alt="([^"]*)""#).unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a href=\"/actordetail-").skip(1) {
        let end = block.find('"').unwrap_or(block.len());
        let head = &block[..end];
        let digits: String = head.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() || seen.contains(&digits) {
            continue;
        }
        let (cover, name) = match img_re.captures(block) {
            Some(c) => (
                c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
                c.get(2).map(|m| unesc(m.as_str())).unwrap_or_default(),
            ),
            None => continue,
        };
        if name.is_empty() {
            continue;
        }
        seen.push(digits.clone());
        let id = format!("/actordetail-{digits}.html");
        out.push(item_json(&id, &name, &cover, "演员"));
    }
    out
}

/// 从 start（指向 `{`）按括号平衡截取，处理字符串与转义。
fn slice_balanced(text: &str, start: usize) -> Option<&str> {
    let bytes = text.as_bytes();
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
        } else if b == b'{' {
            depth += 1;
        } else if b == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some(&text[start..i + 1]);
            }
        }
        i += 1;
    }
    None
}

/// 取 player_aaaa JSON：找 `player_aaaa = {` 后按括号平衡截取。
fn player_json(html: &str) -> Option<Value> {
    let pos = html.find("player_aaaa")?;
    let rest = &html[pos..];
    let eq = rest.find('{')?;
    let frag = slice_balanced(rest, eq)?;
    serde_json::from_str(frag).ok()
}

/// slugOf：url 字段含 % 先 URL 解码，再 base64 解；若为 JSON 取 ss 首项。
fn slug_of(raw: &str) -> Option<String> {
    let mut s = raw.trim().to_string();
    if s.contains('%') {
        s = percent_decode(&s);
    }
    let mut padded = s.clone();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let decoded = B64URL.decode(padded.as_bytes()).ok()?;
    let text = String::from_utf8(decoded).ok()?;
    let text = text.trim().to_string();
    if text.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            if let Some(ss) = get(&v, "ss").and_then(|x| x.as_array()) {
                if let Some(first) = ss.first() {
                    if let Some(str_v) = first.as_str() {
                        return Some(clean_slug(str_v));
                    }
                    if let Some(arr) = first.as_array() {
                        for item in arr.iter().rev() {
                            if let Some(str_v) = item.as_str() {
                                if !str_v.is_empty() {
                                    return Some(clean_slug(str_v));
                                }
                            }
                        }
                    }
                }
            }
        }
        return None;
    }
    Some(clean_slug(&text))
}

/// 去 `?`/`#` 后缀、`slug:` 前缀，并取路径末段（ss 常给
/// `/cn/<slug>` 全路径，取流接口只认末段；整段拼上去会被 302）。
fn clean_slug(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if let Some(idx) = s.find(['?', '#']) {
        s.truncate(idx);
    }
    if let Some(rest) = s.strip_prefix("slug:") {
        s = rest.to_string();
    }
    if let Some(idx) = s.rfind('/') {
        s = s[idx + 1..].to_string();
    }
    s
}

/// 百分号解码（%XX 还原字节）。
fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(n) = u8::from_str_radix(&raw[i + 1..i + 3], 16) {
                out.push(n);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// 取 og:image（双引号与单引号两版）。
fn og_image(html: &str) -> String {
    let re = Regex::new(r#"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#).unwrap();
    if let Some(c) = re.captures(html) {
        return c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default();
    }
    let re_sq = Regex::new(r#"<meta[^>]+property='og:image'[^>]+content='([^']+)'"#).unwrap();
    re_sq
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

/// 取 og:description。
fn og_description(html: &str) -> String {
    let re = Regex::new(r#"<meta[^>]+property="og:description"[^>]+content="([^"]+)""#).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

/// 取 <h1> 文本。
fn h1_text(html: &str) -> String {
    let re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| {
            let t = m.as_str();
            let tag = Regex::new(r"<[^>]+>").unwrap();
            unesc(tag.replace_all(t, "").as_ref())
        })
        .unwrap_or_default()
}

/// URLEncoder 式编码：空格成 %20（与 ZakaProxy.enc 一致；slug 经
/// clean_slug 已取末段、不含 `/`，此处只做兜底编码）。
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

/// 现取 playlist：GET /private-getvideo/<编码后 slug>，取 playlist[0].url。
async fn fetch_playlist(slug: &str) -> ApiResult<String> {
    let mut last_err = ApiError::Internal("321AV 取流失败".into());
    for host in HOSTS {
        let url = format!("{host}/private-getvideo/{}", url_enc(slug));
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", format!("{host}/enter"))
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
            last_err = ApiError::Internal(format!("321AV 取流 HTTP {}", resp.status().as_u16()));
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            let mut candidates: Vec<(String, String)> = Vec::new();
            for key in ["playlist", "QualityUrls"] {
                if let Some(list) = get(&v, key).and_then(|x| x.as_array()) {
                    for entry in list {
                        let u = text_of(entry, &["url", "play", "src"]);
                        if u.starts_with("http") && u.contains(".m3u8") {
                            let kind = text_of(entry, &["type", "urlType"]);
                            candidates.push((u, kind));
                        }
                    }
                }
            }
            // 优先 hersav 线（带/不带站方 Referer 都给全长清单）；
            // 其次 QualityUrls 线（须带站方 Referer）；首条 vckeepw
            // 线不可用（无 Referer 只给 10 秒提示片、带 Referer 403）。
            for want_hersav in [true, false] {
                for (u, kind) in &candidates {
                    let is_hersav = u.contains("hersav");
                    let is_quality = kind == "QualityUrls";
                    if want_hersav && is_hersav {
                        return Ok(u.clone());
                    }
                    if !want_hersav && is_quality {
                        return Ok(u.clone());
                    }
                }
            }
            if let Some((u, _)) = candidates.first() {
                return Ok(u.clone());
            }
        }
        if let Some(m) = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#)
            .unwrap()
            .find(&text)
        {
            return Ok(m.as_str().to_string());
        }
        last_err = ApiError::Internal("321AV 取流未返回清单".into());
    }
    Err(last_err)
}

/// 由详情页取 slug：抓 player_aaaa 的 url 字段再 slugOf。
async fn slug_from_detail_page(path: &str) -> ApiResult<String> {
    let (_host, html) = fetch(path).await?;
    let player =
        player_json(&html).ok_or_else(|| ApiError::Internal("321AV 详情未取到播放信息".into()))?;
    let url = text_of(&player, &["url"]);
    slug_of(&url).ok_or_else(|| ApiError::Internal("321AV 播放地址解码失败".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(path, name)| category_json(path, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.trim();
    let tid = if tid.is_empty() { "/enter" } else { tid };
    let url = page_url(tid, page);
    let (_host, html) = fetch(&url).await?;
    let cards = if tid.starts_with("/actor") {
        parse_actors(&html)
    } else {
        parse_cards(&html)
    };
    let has_more = cards.len() >= 12;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    if let Some(rest) = sid.strip_prefix("/actordetail-") {
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        let path = format!("/actordetail-{digits}.html");
        let (_host, html) = fetch(&path).await?;
        let name = h1_text(&html);
        if name.is_empty() {
            return Err(ApiError::Internal("321AV 未返回演员资料".into()));
        }
        let cover = og_image(&html);
        let works = parse_cards(&html);
        let mut episodes: Vec<Value> = Vec::new();
        for work in works.iter().take(60) {
            let vid = work.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let title = work.get("title").and_then(|v| v.as_str()).unwrap_or("");
            if vid.is_empty() || title.is_empty() {
                continue;
            }
            episodes.push(episode_json(vid, title, sid));
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("321AV 该演员暂无作品".into()));
        }
        return Ok(json!({
            "id": sid,
            "title": name,
            "cover": cover,
            "synopsis": "演员作品",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let digits: String = sid.chars().filter(|c| c.is_ascii_digit()).collect();
    let path = format!("/vodplay/{digits}-1-1.html");
    let (_host, html) = fetch(&path).await?;
    let player = player_json(&html);
    let slug = player
        .as_ref()
        .map(|p| text_of(p, &["url"]))
        .and_then(|u| slug_of(&u));
    let title = player
        .as_ref()
        .and_then(|p| get(p, "vod_data"))
        .map(|d| text_of(d, &["name", "title", "vod_name"]))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| h1_text(&html));
    if title.is_empty() {
        return Err(ApiError::Internal("321AV 未返回影片资料".into()));
    }
    let cover = player
        .as_ref()
        .and_then(|p| get(p, "vod_data"))
        .map(|d| text_of(d, &["pic", "cover", "vod_pic"]))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| og_image(&html));
    let mut synopsis = String::new();
    if let Some(p) = player.as_ref() {
        let actor = text_of(p, &["vod_actor"]);
        if !actor.is_empty() {
            synopsis.push_str(&format!("演员：{actor}\n"));
        }
        let class = text_of(p, &["vod_class"]);
        if !class.is_empty() {
            synopsis.push_str(&format!("分类：{class}\n"));
        }
    }
    let desc = og_description(&html);
    if !desc.is_empty() {
        synopsis.push_str(&desc);
    }
    let slug = match slug {
        Some(s) => s,
        None => return Err(ApiError::Internal("321AV 未取到播放地址".into())),
    };
    let episodes = vec![episode_json(&slug, "正片", sid)];
    Ok(json!({
        "id": sid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        "/index.php/ajax/suggest",
        &[("mid", "1"), ("wd", query.trim())],
    );
    let mut last_err = ApiError::Internal("321AV 搜索失败".into());
    for host in HOSTS {
        let full = format!("{host}{url}");
        let resp = client()?
            .get(&full)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", format!("{host}/enter"))
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
            last_err = ApiError::Internal(format!("321AV 搜索 HTTP {}", resp.status().as_u16()));
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = ApiError::Internal(e.to_string());
                continue;
            }
        };
        let value: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => {
                last_err = ApiError::Internal("321AV 搜索返回格式无法识别".into());
                continue;
            }
        };
        let list = get(&value, "list")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut cards: Vec<Value> = Vec::new();
        for entry in &list {
            let id = text_of(entry, &["id"]);
            if id.is_empty() {
                continue;
            }
            let name = text_of(entry, &["name"]);
            if name.is_empty() {
                continue;
            }
            let pic = text_of(entry, &["pic"]);
            let vid = format!("/vodplay/{id}-1-1.html");
            cards.push(item_json(&vid, &name, &pic, "搜索"));
        }
        return Ok(json!({"items": cards}));
    }
    Err(last_err)
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") && vid.contains(".m3u8") {
        return Ok(json!({"url": vid}));
    }
    let slug = if vid.starts_with("/vodplay/") || vid.chars().all(|c| c.is_ascii_digit()) {
        slug_from_detail_page(vid).await?
    } else {
        vid.to_string()
    };
    let url = fetch_playlist(&slug).await?;
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_5() {
        assert_eq!(CATEGORIES.len(), 5);
        assert_eq!(CATEGORIES[4], ("/actor.html", "演员库"));
    }

    #[test]
    fn page_url_rules() {
        assert_eq!(page_url("/enter", 1), "/enter");
        assert_eq!(page_url("/enter", 2), "/enter-2.html");
        assert_eq!(page_url("/vodtype/20.html", 2), "/vodtype/20-2.html");
    }

    #[test]
    fn slug_of_json_ss() {
        let inner = r#"{"ss":[["x","myslug123"]]}"#;
        let b64 = B64URL.encode(inner.as_bytes());
        let enc: String = b64.bytes().map(|b| format!("%{:02X}", b)).collect();
        assert_eq!(slug_of(&enc).unwrap(), "myslug123");
    }

    #[test]
    fn slug_of_cn_path_takes_last_segment() {
        let inner = r#"{"ss":[[0,"/cn/ktra-650-uncensored-leak"]]}"#;
        let b64 = B64URL.encode(inner.as_bytes());
        let enc: String = b64.bytes().map(|b| format!("%{:02X}", b)).collect();
        assert_eq!(slug_of(&enc).unwrap(), "ktra-650-uncensored-leak");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a href="/vodplay/123-1-1.html"><img data-src="https://pic/c.jpg" alt="Sample Title"><span class="bg-gray-800 bg-opacity-75">12:34</span></a>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/vodplay/123-1-1.html");
        assert_eq!(cards[0]["title"], "Sample Title");
        assert_eq!(cards[0]["remark"], "12:34");
    }
}
