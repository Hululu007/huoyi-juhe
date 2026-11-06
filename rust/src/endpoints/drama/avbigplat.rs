//! AV大平台（avbigplat）：主域 `https://www.9sex.tv`，
//! 备用 `https://porndav.com`（主域本机出口 RemoteDisconnected，
//! 备用域直连通；jar 的 DOMAINS + buildDomains 同款轮换）。
//!
//! jar 内 Zaka9SexAmns 的移植。分类 15 个（/tw/ 下）；列表每页
//! 24 条，`{path}?page={n}`；卡片链接形如 /video/detail/{id}，
//! 封面不在链接内——在上一卡片与本卡片之间的间隙文本里
//! （picture/img 的 src，jar 的 lastImg 同款），标题取
//! title 属性（空则取 h3 文本）。
//! 详情：h1/og:image/og:description/時長/日期/演員（/actors/ 链
//! 接）完整；详情页无直出流（无 JSON 流键、无 source、无
//! iframe、无 m3u8），播放器靠 loadFilm('…/trailer/{id}') 挂预告。
//! 取流：仅预告可免费播——`/trailer/{id}` 直出 AES-128 m3u8
//! （12 段 × 8.34 秒 ≈ 100 秒，首分片 200、841120B、video/mp2t，
//! 密钥 16 字节可取）；正片是金幣付費購買（POST /tw/user/exchange，
//! 须登录 + CSRF），jar 的 L3“免费票复用”须先从 /tw/free 取
//! 免费样本，但该页静态 HTML 里无任何影片、无法复现，且属绕
//! 付费墙，按用户不绕付费口径不做破解链——本文件只给预告集，
//! 正片流未验、须手机侧复验。
//! 搜索：GET `/tw/search?q=&page=1` 本机 0 结果（带会话饼干亦
//! 0 条），POST 兜底（/tw/search 405、/search 404）亦不通，
//! 按 jar 原文实现、须手机侧复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const DOMAINS: &[&str] = &["https://www.9sex.tv", "https://porndav.com"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";

fn eu(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// jar 的 clean：去标签、去 \u{a0}、去首尾空白。
fn clean(s: &str) -> String {
    let tag = Regex::new(r"<[^>]+>").unwrap();
    tag.replace_all(s, "")
        .replace('\u{a0}', " ")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .trim()
        .to_string()
}

fn unesc(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 单域取页（jar 的 ZakaHttp.get 同款头）。
async fn fetch_one(url: &str, domain: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{domain}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("AV大平台 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("AV大平台 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!(
            "AV大平台 请求失败：HTTP {status}"
        )));
    }
    Ok(text)
}

/// jar 的 pageAny：按域名顺序试，首个成功者为准；返回（正文，域名）。
async fn fetch_any(path: &str) -> ApiResult<(String, String)> {
    let mut last_err = ApiError::Internal("AV大平台 全部域名请求失败".into());
    for domain in DOMAINS {
        let url = format!("{domain}{path}");
        match fetch_one(&url, domain).await {
            Ok(text) => return Ok((text, domain.to_string())),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

/// jar 的 pathOf：分类键拼路径。
fn path_of(tid: &str) -> String {
    match tid {
        "all" => "/tw/video/all".to_string(),
        "exclusive" => "/tw/video/exclusive".to_string(),
        "jav" => "/tw/video/type/jav".to_string(),
        "not-pixelated" => "/tw/video/type/not-pixelated".to_string(),
        "europe-america" => "/tw/video/type/europe-america".to_string(),
        "china" => "/tw/video/type/china".to_string(),
        "free" => "/tw/free".to_string(),
        "cumshot" => "/tw/video/cumshot".to_string(),
        "big-boobs" => "/tw/video/big-boobs".to_string(),
        "wife" => "/tw/video/wife".to_string(),
        "ntr" => "/tw/video/ntr".to_string(),
        "monomer-works" => "/tw/video/monomer-works".to_string(),
        "shorts" => "/tw/shorts".to_string(),
        "rank" => "/tw/rank".to_string(),
        "daily" => "/tw/daily".to_string(),
        other => format!("/tw/video/type/{other}"),
    }
}

/// jar 的 lastImg/firstImg：从一段文本里取最后一张/第一张
/// http 图片（跳 data:image 与 logo）。
fn last_img(seg: &str) -> Option<String> {
    let re = Regex::new(
        r#"(?:data-src|data-original|data-lazy-src|data-echo|src)="(https?://[^"]+?\.(?:jpe?g|png|webp|gif))""#,
    )
    .unwrap();
    re.captures_iter(seg)
        .filter_map(|c| {
            let u = c.get(1).unwrap().as_str();
            if u.contains("logo") {
                None
            } else {
                Some(unesc(u))
            }
        })
        .last()
}

fn first_img(seg: &str) -> Option<String> {
    let re = Regex::new(
        r#"(?:data-src|data-original|data-lazy-src|data-echo|src)="(https?://[^"]+?\.(?:jpe?g|png|webp|gif))""#,
    )
    .unwrap();
    let out = re
        .captures_iter(seg)
        .filter_map(|c| {
            let u = c.get(1).unwrap().as_str();
            if u.contains("logo") {
                None
            } else {
                Some(unesc(u))
            }
        })
        .next();
    out
}

/// 列表解析（jar 的 parseList）：先去 header/nav/footer；卡片
/// 正则取 href 与 id；标题取 title 属性（空则 h3）；封面取
/// 上一卡片尾到本卡片首的间隙文本里的最后一张图（无则取
/// 本卡片尾之后的第一张图）；备注取時長或日期。
fn parse_list(html: &str, limit: usize) -> Vec<Value> {
    let strip_re =
        Regex::new(r"(?is)<(header|nav|footer)[^>]*>[\s\S]*?</(header|nav|footer)>").unwrap();
    let html = strip_re.replace_all(html, "").to_string();
    let card_re =
        Regex::new(r#"<a[^>]+href="([^"]*?/video/detail/(\d+)[^"]*)"[^>]*>([\s\S]{0,4000}?)</a>"#)
            .unwrap();
    let title_re = Regex::new(r#"title="([^"]{2,120})""#).unwrap();
    let h3_re = Regex::new(r"<h3[^>]*>([\s\S]{0,300}?)</h3>").unwrap();
    let dur_re = Regex::new(
        r"(?:duration|時長|时长|片長)[^0-9]{0,20}(\d{1,3}\s*[:：]\s*\d{2}(?:\s*[:：]\s*\d{2})?)",
    )
    .unwrap();
    let date_re = Regex::new(r"(20\d{2}[-/.]\d{1,2}[-/.]\d{1,2})").unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let matches: Vec<regex::Captures> = card_re.captures_iter(&html).collect();
    for (idx, cap) in matches.iter().enumerate() {
        let id = cap.get(2).unwrap().as_str();
        if !seen.insert(id.to_string()) {
            continue;
        }
        let inner = cap.get(3).unwrap().as_str();
        let title = title_re
            .captures(inner)
            .map(|c| clean(c.get(1).unwrap().as_str()))
            .filter(|t| !t.is_empty())
            .or_else(|| {
                h3_re
                    .captures(inner)
                    .map(|c| clean(c.get(1).unwrap().as_str()))
                    .filter(|t| !t.is_empty())
            })
            .unwrap_or_else(|| format!("影片 {id}"));
        let m_start = cap.get(0).unwrap().start();
        let m_end = cap.get(0).unwrap().end();
        let prev_end = if idx == 0 {
            0
        } else {
            matches[idx - 1].get(0).unwrap().end()
        };
        let next_start = if idx + 1 < matches.len() {
            matches[idx + 1].get(0).unwrap().start()
        } else {
            html.len()
        };
        let pic = last_img(&html[prev_end..m_start])
            .or_else(|| first_img(&html[m_end..next_start]))
            .unwrap_or_default();
        let remark = dur_re
            .captures(inner)
            .map(|c| c.get(1).unwrap().as_str().trim().to_string())
            .or_else(|| {
                date_re
                    .captures(inner)
                    .map(|c| c.get(1).unwrap().as_str().to_string())
            })
            .unwrap_or_else(|| "AV大平台".to_string());
        out.push(item_json(id, &title, &pic, &remark));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// jar 的 digStream（L1 前端直挖）：JSON 流键、source/video
/// 标签、iframe、m3u8/mp4 扫描、base64/hex 解码后复扫。
fn dig_stream(html: &str) -> Option<String> {
    let key_re = Regex::new(
        r#""(?:file|src|source|url|video|videoUrl|play_url|playUrl|m3u8|hls|hlsUrl|stream|streamUrl|path)"\s*:\s*"([^"]{12,600})""#,
    )
    .unwrap();
    for cap in key_re.captures_iter(html) {
        let u = unesc(cap.get(1).unwrap().as_str());
        if is_playable(&u) {
            return Some(u);
        }
    }
    let src_re = Regex::new(r#"<(?:source|video)[^>]+src="([^"]+)""#).unwrap();
    if let Some(cap) = src_re.captures(html) {
        let u = unesc(cap.get(1).unwrap().as_str());
        if is_playable(&u) {
            return Some(u);
        }
    }
    let iframe_re = Regex::new(r#"<iframe[^>]+src="([^"]+)""#).unwrap();
    if let Some(cap) = iframe_re.captures(html) {
        let u = unesc(cap.get(1).unwrap().as_str());
        if u.contains("player") || u.contains("embed") || u.contains("/v/") {
            return Some(u);
        }
    }
    if let Some(u) = first_url(html, r#"https?://[^\s"'<>\\)]+?\.m3u8[^\s"'<>\\)]*"#) {
        return Some(u);
    }
    if let Some(u) = first_url(html, r#"https?://[^\s"'<>\\)]+?\.(?:mp4|m4v)[^\s"'<>\\)]*"#) {
        return Some(u);
    }
    let b64_re = Regex::new(r#""([A-Za-z0-9+/]{40,}={0,2})""#).unwrap();
    for cap in b64_re.captures_iter(html).take(20) {
        let raw = cap.get(1).unwrap().as_str();
        if let Ok(decoded) =
            base64::Engine::decode(&base64::engine::general_purpose::STANDARD, raw.as_bytes())
        {
            let text = String::from_utf8_lossy(&decoded).to_string();
            if let Some(u) = first_url(&text, r#"https?://[^\s"'<>\\)]+?\.m3u8[^\s"'<>\\)]*"#) {
                return Some(u);
            }
            if let Some(u) = first_url(
                &text,
                r#"https?://[^\s"'<>\\)]+?\.(?:mp4|m4v)[^\s"'<>\\)]*"#,
            ) {
                return Some(u);
            }
        }
    }
    let hex_re = Regex::new(r#""([0-9a-fA-F]{48,})""#).unwrap();
    for cap in hex_re.captures_iter(html).take(10) {
        let raw = cap.get(1).unwrap().as_str();
        if let Ok(bytes) = hex::decode(raw) {
            let text = String::from_utf8_lossy(&bytes).to_string();
            if let Some(u) = first_url(&text, r#"https?://[^\s"'<>\\)]+?\.m3u8[^\s"'<>\\)]*"#) {
                return Some(u);
            }
        }
    }
    None
}

fn first_url(text: &str, pat: &str) -> Option<String> {
    let re = Regex::new(pat).unwrap();
    re.captures(text).map(|c| {
        unesc(c.get(0).unwrap().as_str())
            .replace("\\/", "/")
            .replace("&amp;", "&")
    })
}

/// jar 的 isPlayable：m3u8/mp4 直链，且非广告/测试地址。
fn is_playable(u: &str) -> bool {
    let lower = u.to_lowercase();
    if !(lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".m4v")) {
        return false;
    }
    if lower.contains("speed_test") || lower.contains("download_test") {
        return false;
    }
    u.starts_with("http") && u.len() >= 12
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list = vec![
        category_json("all", "最新上架"),
        category_json("exclusive", "大平台獨家"),
        category_json("jav", "中文"),
        category_json("not-pixelated", "無碼"),
        category_json("europe-america", "歐美"),
        category_json("china", "國產"),
        category_json("free", "限時免費"),
        category_json("cumshot", "中出內射"),
        category_json("big-boobs", "巨乳"),
        category_json("wife", "人妻"),
        category_json("ntr", "NTR"),
        category_json("monomer-works", "單體作品"),
        category_json("shorts", "短影片"),
        category_json("rank", "排行榜"),
        category_json("daily", "每日上新"),
    ];
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let path = format!("{}?page={page}", path_of(category_id));
    let (html, _) = fetch_any(&path).await?;
    let items = parse_list(&html, 24);
    let has_more = items.len() == 24;
    Ok(json!({
        "page": page,
        "pagecount": if has_more { 9999 } else { page },
        "limit": 24,
        "total": 0,
        "has_more": has_more,
        "list": items,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    let (html, domain) = fetch_any(&format!("/tw/video/detail/{video_id}")).await?;
    let h1_re = Regex::new(r"<h1[^>]*>([\s\S]*?)</h1>").unwrap();
    let og_re = Regex::new(
        r#"<meta[^>]+(?:property|name)="(og:title|og:image|og:description|description|keywords)"[^>]+content="([^"]*)""#,
    )
    .unwrap();
    let title = h1_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .filter(|t| !t.is_empty())
        .or_else(|| {
            og_re.captures_iter(&html).find_map(|c| {
                if c.get(1).unwrap().as_str() == "og:title" {
                    let t = clean(c.get(2).unwrap().as_str());
                    if t.is_empty() {
                        None
                    } else {
                        Some(t)
                    }
                } else {
                    None
                }
            })
        })
        .unwrap_or_else(|| format!("影片 {video_id}"));
    let mut cover = String::new();
    let mut desc = String::new();
    for cap in og_re.captures_iter(&html) {
        match cap.get(1).unwrap().as_str() {
            "og:image" => {
                if cover.is_empty() {
                    cover = unesc(cap.get(2).unwrap().as_str());
                }
            }
            "og:description" | "description" => {
                if desc.is_empty() {
                    desc = clean(cap.get(2).unwrap().as_str());
                }
            }
            _ => {}
        }
    }
    let dur_re = Regex::new(
        r"(?:duration|時長|时长|片長)[^0-9]{0,20}(\d{1,3}\s*[:：]\s*\d{2}(?:\s*[:：]\s*\d{2})?)",
    )
    .unwrap();
    let duration = dur_re
        .captures(&html)
        .map(|c| c.get(1).unwrap().as_str().trim().to_string())
        .unwrap_or_default();
    let date_re = Regex::new(r"(20\d{2}[-/.]\d{1,2}[-/.]\d{1,2})").unwrap();
    let date = date_re
        .captures(&html)
        .map(|c| c.get(1).unwrap().as_str().to_string())
        .unwrap_or_default();
    let actor_re =
        Regex::new(r#"<a[^>]+href="[^"]*?/actors/(\d+)"[^>]*>([\s\S]{0,60}?)</a>"#).unwrap();
    let mut actors = Vec::new();
    let mut seen = HashSet::new();
    for cap in actor_re.captures_iter(&html) {
        let name = clean(cap.get(2).unwrap().as_str());
        if !name.is_empty() && seen.insert(name.clone()) {
            actors.push(name);
        }
    }
    let tag_re =
        Regex::new(r#"<a[^>]+href="[^"]*?/tag/([^"/]+)"[^>]*>([\s\S]{0,40}?)</a>"#).unwrap();
    let mut tags = Vec::new();
    let mut seen_t = HashSet::new();
    for cap in tag_re.captures_iter(&html) {
        let name = clean(cap.get(2).unwrap().as_str());
        if !name.is_empty() && seen_t.insert(name.clone()) {
            tags.push(name);
        }
    }
    let mut synopsis = String::new();
    if !actors.is_empty() {
        synopsis.push_str(&format!("演員: {}\n", actors.join(" / ")));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("標籤: {}\n", tags.join(" / ")));
    }
    if !duration.is_empty() {
        synopsis.push_str(&format!("時長: {duration}\n"));
    }
    if !date.is_empty() {
        synopsis.push_str(&format!("日期: {date}\n"));
    }
    if !desc.is_empty() {
        synopsis.push_str(&desc);
    }
    synopsis.push_str("\n本片正片為金幣付費購買，此處僅提供預告。");
    let mut episodes = Vec::new();
    if let Some(stream) = dig_stream(&html) {
        episodes.push(episode_json(
            &stream,
            "AV大平台·直鏈",
            &format!("{domain}/tw/video/detail/{video_id}"),
        ));
    }
    episodes.push(episode_json(
        &format!("trailer|{video_id}"),
        "AV大平台·預告",
        &format!("{domain}/tw/video/detail/{video_id}"),
    ));
    Ok(json!({
        "id": video_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim(),
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = eu(query.trim());
    // 先 GET /tw/search?q=&page=1（jar 的 searchContent 同款）。
    if let Ok((html, _)) = fetch_any(&format!("/tw/search?q={enc}&page=1")).await {
        let items = parse_list(&html, 24);
        if !items.is_empty() {
            return Ok(json!({"items": items}));
        }
    }
    // 再 POST /search（q=&keyword=，XHR 头）。
    let c = client()?;
    for domain in DOMAINS {
        let resp = c
            .post(format!("{domain}/search"))
            .header("User-Agent", UA)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Referer", format!("{domain}/"))
            .body(format!("q={enc}&keyword={enc}"))
            .send()
            .await;
        if let Ok(resp) = resp {
            if resp.status().is_success() {
                if let Ok(text) = resp.text().await {
                    let items = parse_list(&text, 24);
                    if !items.is_empty() {
                        return Ok(json!({"items": items}));
                    }
                }
            }
        }
    }
    Ok(json!({"items": []}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(id) = video_id.strip_prefix("trailer|") {
        // 预告直出 m3u8（jar 的 loadFilm 同款地址）。
        for domain in DOMAINS {
            let url = format!("{domain}/trailer/{id}");
            if let Ok(text) = fetch_one(&url, domain).await {
                if text.contains("#EXTM3U") {
                    return Ok(json!({"url": url}));
                }
            }
        }
        return Err(ApiError::Internal("AV大平台 预告取不到".into()));
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("AV大平台 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_of_builds_all_kinds() {
        assert_eq!(path_of("all"), "/tw/video/all");
        assert_eq!(path_of("jav"), "/tw/video/type/jav");
        assert_eq!(path_of("free"), "/tw/free");
        assert_eq!(path_of("shorts"), "/tw/shorts");
    }

    #[test]
    fn dig_stream_finds_m3u8_and_skips_speed_test() {
        let html = r#"{"file":"https://5a439.sh06.co/speed_test/download_test.mp4"} "m3u8":"https://cdn.example.com/a/index.m3u8""#;
        assert_eq!(
            dig_stream(html).as_deref(),
            Some("https://cdn.example.com/a/index.m3u8")
        );
    }
}
