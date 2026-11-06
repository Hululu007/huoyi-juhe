//! SupJav：WordPress 站，列表为 post 卡片，详情取 data-link 多线路。
//!
//! 与 Dart 的 ZakaSupjavAmns 一一对应（ext relay 为中继地址）。分类与
//! 站内导航 1:1（8 项：最新、热门、6 个分类 slug）。分页：首页
//! `/page/<页>/`、热门 `/popular/page/<页>/`、分类
//! `/category/<slug>/page/<页>/`。直连 supjav.com 会被 CF 拦（本机
//! 实测 403），故列表/详情/搜索统一先走中继（/fs 再 /page 依次试，
//! 本机实测两者均 200、66 条以上），直连只作回退。详情：标题取 h1，
//! 封面取 img.supjav.com，data-link（40 位 hex 以上）每条一集
//! （标签按 TV/VOE/FST 排序），另加“TV·中继”一集。
//! 取流（真直链，非中继）：分集 video_id 为 `sj:<数字id>:<sha1|relay>`；
//! 令牌反转后走跳链 `lk1.supremejav.com/supjav.php?c=<反转>`，302 到
//! 真实嵌页（EVS/VidHide、streamtape、VOE 等）；VidHide 嵌页解
//! packer 混淆取 links.hls2/hls4 直链，streamtape 嵌页取
//! get_video 直链，其余通用扫 m3u8/mp4（含 base64 串内）。中继
//! /stream 已死（回 CF 挑战页），不再使用。
//! 实测（2026-11-06）：列表 66 条、翻页 66 条、搜索 24 条、详情
//! 5 线路；EVS 线解包出真 m3u8（时长 3443.07 秒），ST 线解出
//! get_video 参数；但本机出口拉不到末端媒体（EVS m3u8 403/000、
//! ST 直链 000），取流末端须手机侧复验。

use base64::Engine;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://supjav.com";
const RELAY: &str = "https://py.fzcrym.link:1314";
const JUMP_HOSTS: &[&str] = &["https://lk1.supremejav.com"];
const PAGE_EPS: &[&str] = &["/fs", "/page"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类：[slug, 名]，与站内导航 1:1。
const CATEGORIES: &[(&str, &str)] = &[
    ("__home", "最新"),
    ("__popular", "热门"),
    ("censored-jav", "有码 Censored"),
    ("uncensored-jav", "无码 Uncensored"),
    ("amateur", "素人 Amateur"),
    ("chinese-subtitles", "中文字幕 Chn Sub"),
    ("reducing-mosaic", "破解 Reducing Mosaic"),
    ("english-subtitles", "英文字幕 Eng Sub"),
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
fn usable(body: &str) -> bool {
    body.len() >= 3000 && !is_challenge(body)
}

/// URLEncoder 式编码：空格成 %20（与 ZakaProxy.enc 一致）。
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

/// 中继地址：中继 + 路径 + `?u=<编码地址>`（r 非空时再补 `&r=`）。
fn relay_url(path: &str, u: &str, r: &str) -> String {
    let mut url = format!("{RELAY}{path}?u={}", url_enc(u));
    if !r.is_empty() {
        url.push_str(&format!("&r={}", url_enc(r)));
    }
    url
}

/// 取页：先走中继（/fs 再 /page），再直连；首个可用正文即用。
async fn page_fetch(url: &str) -> ApiResult<String> {
    for ep in PAGE_EPS {
        let rurl = relay_url(ep, url, "");
        if let Ok(resp) = client()?
            .get(&rurl)
            .header("User-Agent", UA)
            .header("Referer", format!("{HOST}/"))
            .send()
            .await
        {
            if resp.status().as_u16() == 200 {
                if let Ok(text) = resp.text().await {
                    if usable(&text) {
                        return Ok(text);
                    }
                }
            }
        }
    }
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().as_u16() == 200 => {
            let text = r.text().await.unwrap_or_default();
            if usable(&text) {
                Ok(text)
            } else {
                Err(ApiError::Internal("SupJav 返回内容不可用".into()))
            }
        }
        Ok(r) => Err(ApiError::Internal(format!(
            "SupJav HTTP {}",
            r.status().as_u16()
        ))),
        Err(e) => Err(ApiError::Internal(e.to_string())),
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

/// 帖子卡片：按 `<div class="post">` 切块，取链接、标题、封面、番号备注。
fn parse_cards(html: &str) -> Vec<Value> {
    let link_re = Regex::new(r#"href="https://supjav\.com/(\d+)\.html""#).unwrap();
    let title_re = Regex::new(r#"title="([^"]+)""#).unwrap();
    let cover_re =
        Regex::new(r#"(?:data-original|data-src|src)="(https://img\.supjav\.com/[^"]+)""#).unwrap();
    let cover_any = Regex::new(r#"(?:data-original|data-src|src)="(https?://[^"]+)""#).unwrap();
    let code_re = Regex::new(r"\b([A-Z]{2,6}-?\d{2,6}|FC2PPV[\s-]?\d{5,8})\b").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"post\">").skip(1) {
        let id = match link_re.captures(block) {
            Some(c) => c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
            None => continue,
        };
        if id.is_empty() || seen.contains(&id) {
            continue;
        }
        let title = title_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(m.as_str()))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        let cover = cover_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .or_else(|| {
                cover_any
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
            .unwrap_or_default();
        let remark = code_re
            .captures(&title)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 线路排序：TV=10、VOE=20、FST=30，其余按原序排后。
fn line_order(label: &str) -> u32 {
    let upper = label.to_uppercase();
    if upper.contains("TV") {
        10
    } else if upper.contains("VOE") {
        20
    } else if upper.contains("FST") {
        30
    } else {
        40
    }
}

fn list_path(slug: &str, page: i64) -> String {
    match slug {
        "__home" => {
            if page <= 1 {
                "/".to_string()
            } else {
                format!("/page/{page}/")
            }
        }
        "__popular" => {
            if page <= 1 {
                "/popular/".to_string()
            } else {
                format!("/popular/page/{page}/")
            }
        }
        other => {
            if page <= 1 {
                format!("/category/{other}")
            } else {
                format!("/category/{other}/page/{page}/")
            }
        }
    }
}

/// 取 <h1> 文本。
fn h1_text(html: &str) -> String {
    let re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| {
            let tag = Regex::new(r"<[^>]+>").unwrap();
            unesc(tag.replace_all(m.as_str(), "").as_ref())
        })
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(slug, name)| category_json(slug, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let slug = category_id.trim();
    let slug = if slug.is_empty() { "__home" } else { slug };
    let url = format!("{HOST}{}", list_path(slug, page));
    let html = page_fetch(&url).await?;
    let cards = parse_cards(&html);
    let has_more = cards.len() >= 20;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let digits: String = sid.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return Err(ApiError::Internal("SupJav 未指定影片".into()));
    }
    let url = format!("{HOST}/{digits}.html");
    let html = page_fetch(&url).await?;
    let title = h1_text(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("SupJav 未返回影片标题".into()));
    }
    let cover_re =
        Regex::new(r#"background-image:\s*url\((https://img\.supjav\.com/[^)]+)\)"#).unwrap();
    let cover = cover_re
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .or_else(|| {
            Regex::new(r#"https://img\.supjav\.com/[^"'\s)]+\.(?:jpg|jpeg|png|webp)"#)
                .unwrap()
                .find(&html)
                .map(|m| m.as_str().to_string())
        })
        .unwrap_or_default();
    let mut synopsis = String::new();
    let views_re = Regex::new(r#"<span class="views">([^<]+)</span>"#).unwrap();
    if let Some(c) = views_re.captures(&html) {
        let v = c.get(1).map(|m| m.as_str().trim()).unwrap_or("");
        if !v.is_empty() {
            synopsis.push_str(&format!("观看：{v}\n"));
        }
    }
    let tag_re = Regex::new(r#"href="https://supjav\.com/(?:tag|actress)/([^"/]+)"#).unwrap();
    let mut tags: Vec<String> = Vec::new();
    for cap in tag_re.captures_iter(&html) {
        let t = cap
            .get(1)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        if !t.is_empty() && !tags.contains(&t) {
            tags.push(t);
        }
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("标签：{}\n", tags.join(" / ")));
    }
    let year_re = Regex::new(r"/images/(\d{4})/").unwrap();
    if let Some(c) = year_re.captures(&html) {
        let y = c.get(1).map(|m| m.as_str()).unwrap_or("");
        synopsis.push_str(&format!("年份：{y}\n"));
    }
    let link_re = Regex::new(r#"data-link="([0-9a-f]{40,})""#).unwrap();
    let label_re = Regex::new(r#"data-link="[0-9a-f]{40,}"[^>]*>([^<]{1,12})<"#).unwrap();
    let mut lines: Vec<(u32, String, String)> = Vec::new();
    for cap in link_re.captures_iter(&html) {
        let sha = cap
            .get(1)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        if sha.is_empty() || lines.iter().any(|(_, s, _)| *s == sha) {
            continue;
        }
        let label = label_re
            .captures(&html[cap.get(0).map(|m| m.start()).unwrap_or(0)..])
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_else(|| "线路".to_string());
        let order = line_order(&label);
        lines.push((order, sha, label));
    }
    lines.sort_by(|a, b| a.0.cmp(&b.0));
    let mut episodes: Vec<Value> = Vec::new();
    for (_order, sha, label) in &lines {
        let vid = format!("sj:{digits}:{sha}");
        episodes.push(episode_json(&vid, label, sid));
    }
    episodes.push(episode_json(&format!("sj:{digits}:relay"), "TV·中继", sid));
    Ok(json!({
        "id": digits,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = url_enc(query.trim());
    let url = format!("{HOST}/?s={q}");
    let html = page_fetch(&url).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    let parts: Vec<&str> = vid.split(':').collect();
    if parts.len() >= 3 && parts[0] == "sj" {
        let id = parts[1];
        if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
            return Err(ApiError::Internal("SupJav 该集没有播放地址".into()));
        }
        let sha = if parts[2] == "relay" {
            first_sha(id).await?
        } else {
            parts[2].to_string()
        };
        return resolve_sha(&sha).await;
    }
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    Err(ApiError::Internal("SupJav 该集没有播放地址".into()))
}

/// “TV·中继”集：重取详情页，取第一条 data-link 令牌再走跳链。
async fn first_sha(id: &str) -> ApiResult<String> {
    let url = format!("{HOST}/{id}.html");
    let html = page_fetch(&url).await?;
    let link_re = Regex::new(r#"data-link="([0-9a-f]{40,})""#).unwrap();
    link_re
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| ApiError::Internal("SupJav 详情无播放线路".into()))
}

/// 跳链取页（跟 302 到嵌页）：返回（最终地址，正文）。
async fn fetch_jump(url: &str, referer: &str) -> ApiResult<(String, String)> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("SupJav 跳链 HTTP {status}")));
    }
    let final_url = resp.url().to_string();
    let body = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok((final_url, body))
}

/// 令牌反转 → 跳链 302 → 嵌页直解，返回真直链。
async fn resolve_sha(sha: &str) -> ApiResult<Value> {
    let rev: String = sha.chars().rev().collect();
    let mut last_err = String::new();
    for jump in JUMP_HOSTS {
        let c_url = format!("{jump}/supjav.php?c={rev}");
        let referer = format!("{jump}/supjav.php");
        match fetch_jump(&c_url, &referer).await {
            Ok((final_url, body)) => {
                let host = final_url.to_ascii_lowercase();
                if host.contains("streamtape.") || host.contains("tapecontent.") {
                    if let Some(direct) = resolve_streamtape(&body) {
                        return Ok(
                            json!({"url": direct, "header": {"User-Agent": UA, "Referer": "https://streamtape.com/"}}),
                        );
                    }
                    return Ok(json!({"url": final_url}));
                }
                if let Some(iframe) = iframe_src(&body) {
                    if let Ok((u2, b2)) = fetch_jump(&iframe, &final_url).await {
                        if let Some(direct) = resolve_from_embed(&u2, &b2) {
                            return Ok(direct);
                        }
                        return Ok(json!({"url": u2}));
                    }
                }
                if let Some(direct) = resolve_from_embed(&final_url, &body) {
                    return Ok(direct);
                }
                return Ok(json!({"url": final_url}));
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!("SupJav 跳链失败：{last_err}")))
}

/// 嵌页直解：先 VidHide packer 取 hls2/hls4，再通用扫 m3u8/mp4。
fn resolve_from_embed(embed_url: &str, body: &str) -> Option<Value> {
    if let Some(unpacked) = unpack_packed(body) {
        let hls2_re = Regex::new(r#""hls2":"(https?://[^"]+\.m3u8[^"]*)""#).unwrap();
        if let Some(c) = hls2_re.captures(&unpacked) {
            let u = c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default();
            if !u.is_empty() {
                return Some(json!({"url": u, "header": {"User-Agent": UA, "Referer": embed_url}}));
            }
        }
        let hls4_re = Regex::new(r#""hls4":"(/[^"]+\.m3u8[^"]*)""#).unwrap();
        if let Some(c) = hls4_re.captures(&unpacked) {
            let rel = c.get(1).map(|m| m.as_str()).unwrap_or("");
            if !rel.is_empty() {
                if let Ok(base) = url::Url::parse(embed_url) {
                    if let Ok(joined) = base.join(rel) {
                        return Some(
                            json!({"url": joined.to_string(), "header": {"User-Agent": UA, "Referer": embed_url}}),
                        );
                    }
                }
            }
        }
    }
    if let Some(direct) = resolve_generic(body) {
        return Some(json!({"url": direct, "header": {"User-Agent": UA, "Referer": embed_url}}));
    }
    None
}

/// streamtape 嵌页取 get_video 直链。
fn resolve_streamtape(html: &str) -> Option<String> {
    let re = Regex::new(
        r#"get_video\?id=([A-Za-z0-9]+)&(?:amp;)?expires=(\d+)&(?:amp;)?ip=([^&"'<]+)&(?:amp;)?token=([^&"'<]+)"#,
    )
    .unwrap();
    re.captures(html).map(|c| {
        format!(
            "https://streamtape.com/get_video?id={}&expires={}&ip={}&token={}",
            &c[1], &c[2], &c[3], &c[4]
        )
    })
}

/// 通用扫：直链 m3u8/mp4，扫不到再解长 base64 串找 m3u8。
fn resolve_generic(html: &str) -> Option<String> {
    let m3u8_re = Regex::new(r#"https?://[^\s"'<>\\]+\.m3u8[^\s"'<>\\]*"#).unwrap();
    if let Some(m) = m3u8_re.find(html) {
        return Some(m.as_str().to_string());
    }
    let mp4_re = Regex::new(r#"https?://[^\s"'<>\\]+\.mp4[^\s"'<>\\]*"#).unwrap();
    for m in mp4_re.find_iter(html) {
        let u = m.as_str();
        if !u.contains("thumb") && !u.contains("poster") {
            return Some(u.to_string());
        }
    }
    let b64_re = Regex::new(r"[A-Za-z0-9+/=]{120,}").unwrap();
    for m in b64_re.find_iter(html) {
        let raw = m.as_str();
        let padded = match raw.len() % 4 {
            0 => raw.to_string(),
            r => format!("{}{}", raw, "=".repeat(4 - r)),
        };
        let decoded = base64::engine::general_purpose::STANDARD.decode(&padded);
        if let Ok(bytes) = decoded {
            let text = String::from_utf8_lossy(&bytes).to_string();
            if let Some(mm) = m3u8_re.find(&text) {
                return Some(mm.as_str().to_string());
            }
        }
    }
    None
}

/// 嵌页 iframe 地址。
fn iframe_src(html: &str) -> Option<String> {
    let re = Regex::new(r#"<iframe[^>]+src="([^"]+)""#).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

/// 解 packer 混淆：`eval(function(p,a,c,k,e,d){...}('载荷',进制,条数,
// '词1|词2|...'.split('|'),0,{}))`，按 baseN 词典逐词还原。
fn unpack_packed(html: &str) -> Option<String> {
    let re = Regex::new(
        r"(?s)eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)",
    )
    .unwrap();
    let caps = re.captures(html)?;
    let payload = unescape_js(caps.get(1)?.as_str());
    let radix: u32 = caps.get(2)?.as_str().parse().ok()?;
    let count: usize = caps.get(3)?.as_str().parse().ok()?;
    let dict: Vec<&str> = caps.get(4)?.as_str().split('|').collect();
    if radix < 2 || radix > 36 || dict.is_empty() {
        return None;
    }
    let mut out = payload;
    for idx in (0..count).rev() {
        let word = dict.get(idx).copied().unwrap_or("");
        if word.is_empty() {
            continue;
        }
        let token = to_base(idx as u32, radix);
        let token_re = Regex::new(&format!(r"\b{}\b", regex::escape(&token))).unwrap();
        let replacement = word.to_string();
        out = token_re
            .replace_all(&out, |_: &regex::Captures| replacement.clone())
            .to_string();
    }
    Some(out)
}

/// JS 单引号串反转义（`\'` `\"` `\\` `\n` 等）。
fn unescape_js(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

/// 数字转 baseN（packer 词典下标，数字表 0-9a-z）。
fn to_base(mut n: u32, base: u32) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    if n == 0 {
        return "0".to_string();
    }
    let mut buf = Vec::new();
    while n > 0 {
        buf.push(DIGITS[(n % base) as usize]);
        n /= base;
    }
    buf.reverse();
    String::from_utf8(buf).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_8() {
        assert_eq!(CATEGORIES.len(), 8);
        assert_eq!(CATEGORIES[0], ("__home", "最新"));
        assert_eq!(CATEGORIES[7], ("english-subtitles", "英文字幕 Eng Sub"));
    }

    #[test]
    fn list_paths() {
        assert_eq!(list_path("__home", 1), "/");
        assert_eq!(list_path("__home", 2), "/page/2/");
        assert_eq!(list_path("__popular", 2), "/popular/page/2/");
        assert_eq!(list_path("amateur", 1), "/category/amateur");
        assert_eq!(list_path("amateur", 3), "/category/amateur/page/3/");
    }

    #[test]
    fn relay_url_encodes() {
        let u = relay_url(
            "/stream",
            "https://supjav.com/469659.html",
            "https://supjav.com/",
        );
        assert_eq!(
            u,
            "https://py.fzcrym.link:1314/stream?u=https%3A%2F%2Fsupjav.com%2F469659.html&r=https%3A%2F%2Fsupjav.com%2F"
        );
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<div class="post"><a href="https://supjav.com/469659.html" title="ABC-123 Sample Title"><img data-original="https://img.supjav.com/c.jpg"></a></div>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "469659");
        assert_eq!(cards[0]["remark"], "ABC-123");
    }

    #[test]
    fn to_base_cases() {
        assert_eq!(to_base(0, 36), "0");
        assert_eq!(to_base(35, 36), "z");
        assert_eq!(to_base(36, 36), "10");
        assert_eq!(to_base(549, 36), "f9");
    }

    #[test]
    fn unpack_packed_sample() {
        // 迷你 packer 样例：0->https，1->example.com，2->master
        let html = r#"eval(function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\\b'+c.toString(a)+'\\b','g'),k[c]);return p}('var links={"hls2":"0://1/2.m3u8"};',36,3,'https|example.com|master'.split('|'),0,{}))"#;
        let out = unpack_packed(html).unwrap();
        assert!(out.contains("https://example.com/master.m3u8"));
        let direct = resolve_from_embed("https://evsishere.xyz/embed/x", html);
        assert!(direct.is_some());
        assert_eq!(direct.unwrap()["url"], "https://example.com/master.m3u8");
    }

    #[test]
    fn streamtape_params() {
        let html = r#"robotlink' id="ideoolink" href="https://streamtape.com/get_video?id=LYqzDgVqLqHRRkv&expires=1793977661&ip=FRMOERyOEOWYFxf&token=eCWG9bWp1cde">"#;
        assert_eq!(
            resolve_streamtape(html).unwrap(),
            "https://streamtape.com/get_video?id=LYqzDgVqLqHRRkv&expires=1793977661&ip=FRMOERyOEOWYFxf&token=eCWG9bWp1cde"
        );
    }

    #[test]
    fn generic_finds_m3u8() {
        let html = "player.setup({file:'https://cdn.example.com/v/master.m3u8'})";
        assert_eq!(
            resolve_generic(html).unwrap(),
            "https://cdn.example.com/v/master.m3u8"
        );
    }
}
