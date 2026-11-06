//! JAV777（jav777）：`https://www.jav777.xyz`。
//!
//! jar 内 ZakaJav777Amns 的移植。WordPress 站，站域直连吃
//! Cloudflare 挑战（本机出口 403/断流），取页走直连失败后
//! 切中继 `https://tv506.ystv.top/p?u={enc}&r={enc}`（jar 的
//! ZakaShield 中继兜底同款）。分类：最新上架/中文字幕 + 14 个
//! tag（STARS/MIAA/MIDV/NACR/PRED/FSDSS/ADN/CAWD/IPZZ/ALDN/
//! DASD/MIDE/ABP/JUFE）；每页 25 条。
//! 取流链（jar 的 resolve）：详情页 iframe（video.520cc.cc 的
//! player777G.php）→ 页内 get3G.php?rand=&id=&key=&mp4= →
//! 响应是 `var ccsJsCmds = '...'` 混淆串，解码为逐字符减偏移
//! （0–40 试到含 the_video_id 或 `<source` 为止）再做百分号解码
//! → 取其中的 .m3u8（实测偏移 5，流为 surecdn.cc 的 m3u8）。
//! 注意：该 m3u8 是 JPEG 帧序列（923 段、无 .ts，首帧 200、
//! 739592B、image/jpeg），是站方自有播放格式，按 jar 原样返回；
//! 壳的播放器能否播 JPEG 帧序列 HLS，须手机侧复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://www.jav777.xyz";
const RELAY: &str = "https://tv506.ystv.top/p";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn eu(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

fn is_challenge(text: &str) -> bool {
    text.contains("Just a moment")
        || text.contains("cf-challenge")
        || text.contains("Attention Required")
}

/// 取页：先直连，失败/非 200/挑战页时切 tv506 中继
/// （jar 的 ZakaShield 中继兜底同款；直连在本机出口吃 CF 挑战）。
async fn fetch_text(url: &str) -> ApiResult<String> {
    let c = client()?;
    let direct = c
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await;
    if let Ok(resp) = direct {
        if resp.status().is_success() {
            if let Ok(text) = resp.text().await {
                if !text.is_empty() && !is_challenge(&text) {
                    return Ok(text);
                }
            }
        }
    }
    let relay = format!("{RELAY}?u={}&r={}", eu(url), eu(&format!("{HOST}/")));
    let resp = c
        .get(&relay)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("JAV777 中继请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("JAV777 读中继响应失败：{e}")))?;
    if !status.is_success() || text.is_empty() {
        return Err(ApiError::Internal(format!(
            "JAV777 请求失败：HTTP {status}"
        )));
    }
    Ok(text)
}

/// jar 的 clean/stripTags：去标签、去 \u{a0}、去首尾空白。
fn clean(s: &str) -> String {
    let tag = Regex::new(r"<[^>]+>").unwrap();
    tag.replace_all(s, "")
        .replace('\u{a0}', " ")
        .replace("&nbsp;", " ")
        .replace("&#8230;", "…")
        .replace("&#8211;", "–")
        .replace("&#8217;", "'")
        .trim()
        .to_string()
}

/// jar 的 pctDecode：%XX 还原 + &#数字; 实体还原。
fn pct_decode(s: &str) -> String {
    let ent = Regex::new(r"&#(\d+);").unwrap();
    let s = ent.replace_all(s, |c: &regex::Captures| {
        let n: u32 = c.get(1).unwrap().as_str().parse().unwrap_or(0);
        char::from_u32(n)
            .map(|ch| ch.to_string())
            .unwrap_or_default()
    });
    let mut out = String::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && bytes[i + 1].is_ascii_hexdigit()
            && bytes[i + 2].is_ascii_hexdigit()
        {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("00");
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v as char);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

/// jar 的 decodeResp：逐字符减偏移（0–40），pctDecode 后含
/// the_video_id 或 `<source` 即取用，否则换下一偏移。
fn decode_resp(resp: &str) -> String {
    if resp.trim().is_empty() || resp.len() < 40 {
        return String::new();
    }
    for shift in 0..=40u32 {
        let shifted: String = resp
            .chars()
            .map(|c| {
                let v = c as u32;
                char::from_u32(v.wrapping_sub(shift)).unwrap_or(c)
            })
            .collect();
        let decoded = pct_decode(&shifted);
        if decoded.contains("the_video_id") || decoded.contains("<source") {
            return decoded;
        }
    }
    String::new()
}

/// jar 的 catUrl：分类拼列表地址。
fn cat_url(tid: &str, page: i64) -> String {
    if let Some(rest) = tid.strip_prefix("n|") {
        let _ = rest;
        if page <= 1 {
            format!("{HOST}/")
        } else {
            format!("{HOST}/page/{page}/")
        }
    } else if let Some(slug) = tid.strip_prefix("c|") {
        if page <= 1 {
            format!("{HOST}/category/{slug}/")
        } else {
            format!("{HOST}/category/{slug}/page/{page}/")
        }
    } else if let Some(slug) = tid.strip_prefix("t|") {
        if page <= 1 {
            format!("{HOST}/tag/{slug}/")
        } else {
            format!("{HOST}/tag/{slug}/page/{page}/")
        }
    } else if page <= 1 {
        format!("{HOST}/{tid}/")
    } else {
        format!("{HOST}/{tid}/page/{page}/")
    }
}

/// 列表解析：`<div class="post-container">` 块；标题取 h2.post-title
/// 的 a 文本，封面取 wp-post-image 的 srcset 首项，备注取 post-date。
fn parse_list(html: &str, limit: usize) -> Vec<Value> {
    let block_re = Regex::new(r#"<div class="post-container">"#).unwrap();
    let title_re =
        Regex::new(r#"<h2 class="post-title"><a\s+href="([^"]+)"[^>]*>(.*?)</a>"#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+class="[^"]*wp-post-image[^"]*"[^>]*>"#).unwrap();
    let srcset_re = Regex::new(r#"(?:data-srcset|srcset)\s*=\s*["']([^"']+)["']"#).unwrap();
    let src_re = Regex::new(r#"src\s*=\s*["']([^"']+)["']"#).unwrap();
    let date_re = Regex::new(r#"class="post-date"[^>]*>\s*([0-9\-]{4,12})"#).unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let parts: Vec<&str> = block_re.split(html).collect();
    for part in parts.iter().skip(1) {
        let seg = &part[..part.len().min(8000)];
        let Some(cap) = title_re.captures(seg) else {
            continue;
        };
        let url = cap.get(1).unwrap().as_str();
        let title = clean(cap.get(2).unwrap().as_str());
        if title.is_empty() || !seen.insert(url.to_string()) {
            continue;
        }
        let pic = img_re
            .captures(seg)
            .and_then(|c| {
                let tag = c.get(0).unwrap().as_str();
                srcset_re
                    .captures(tag)
                    .and_then(|s| {
                        s.get(1)
                            .unwrap()
                            .as_str()
                            .split(',')
                            .next()
                            .and_then(|e| e.split_whitespace().next())
                            .map(|u| u.to_string())
                    })
                    .or_else(|| {
                        src_re
                            .captures(tag)
                            .map(|s| s.get(1).unwrap().as_str().to_string())
                    })
            })
            .unwrap_or_default();
        let remark = date_re
            .captures(seg)
            .map(|c| c.get(1).unwrap().as_str().to_string())
            .unwrap_or_else(|| "JAV777".to_string());
        out.push(item_json(url, &title, &pic, &remark));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// jar 的 resolve：详情页 iframe → 播放器页 → get3G → 解码 → 取流。
async fn resolve(detail_url: &str) -> ApiResult<Option<String>> {
    let html = fetch_text(detail_url).await?;
    let iframe_re =
        Regex::new(r#"<iframe[^>]+src="(https?://[^"]*(?:player|embed)[^"]*)""#).unwrap();
    let Some(cap) = iframe_re.captures(&html) else {
        return Ok(None);
    };
    let iframe_url = cap.get(1).unwrap().as_str().to_string();
    let player = fetch_text(&iframe_url).await?;
    let g3_re = Regex::new(
        r#"get3G\.php\?rand=(\d+)&(?:amp;)?id=([^&"']+)&(?:amp;)?key=(\d+)&(?:amp;)?mp4=([^&"']*)"#,
    )
    .unwrap();
    let Some(g) = g3_re.captures(&player) else {
        // 播放器页本身可能已含流，直接扫。
        return Ok(scan_stream(&player));
    };
    let origin = iframe_url.split('/').take(3).collect::<Vec<_>>().join("/");
    let g3_url = format!(
        "{origin}/get3G.php?rand={}&id={}&key={}&mp4={}",
        g.get(1).unwrap().as_str(),
        g.get(2).unwrap().as_str(),
        g.get(3).unwrap().as_str(),
        g.get(4).map(|m| m.as_str()).unwrap_or("")
    );
    let resp = fetch_text(&g3_url).await?;
    let decoded = decode_resp(&resp);
    if decoded.is_empty() {
        return Ok(None);
    }
    Ok(scan_stream(&decoded))
}

/// 扫 .m3u8（优先）或 .mp4。
fn scan_stream(text: &str) -> Option<String> {
    let re = Regex::new(r#"https?://[^"'<>\s\\]+\.m3u8[^"'<>\s\\]*"#).unwrap();
    if let Some(cap) = re.captures(text) {
        let u = cap
            .get(0)
            .unwrap()
            .as_str()
            .trim_end_matches('\\')
            .to_string();
        if !u.is_empty() {
            return Some(u);
        }
    }
    let re2 = Regex::new(r#"https?://[^"'<>\s\\]+\.mp4[^"'<>\s\\]*"#).unwrap();
    re2.captures(text).map(|c| {
        c.get(0)
            .unwrap()
            .as_str()
            .trim_end_matches('\\')
            .to_string()
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("n|", "最新上架"),
        category_json("c|%e5%ad%97%e5%b9%95%e3%81%82%e3%82%8a", "中文字幕"),
    ];
    for (slug, name) in [
        ("stars", "STARS"),
        ("miaa", "MIAA"),
        ("midv", "MIDV"),
        ("nacr", "NACR"),
        ("pred", "PRED"),
        ("fsdss", "FSDSS"),
        ("adn", "ADN"),
        ("cawd", "CAWD"),
        ("ipzz", "IPZZ"),
        ("aldn", "ALDN"),
        ("dasd", "DASD"),
        ("mide", "MIDE"),
        ("abp", "ABP"),
        ("jufe", "JUFE"),
    ] {
        list.push(category_json(&format!("t:{slug}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let url = cat_url(category_id, page);
    let html = fetch_text(&url).await?;
    let items = parse_list(&html, 25);
    let has_more = items.len() == 25;
    Ok(json!({
        "page": page,
        "pagecount": if has_more { 9999 } else { page },
        "limit": 25,
        "total": 0,
        "has_more": has_more,
        "list": items,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    let url = video_id.to_string();
    let html = fetch_text(&url).await?;
    let h1_re = Regex::new(r"<h1[^>]*>(.*?)</h1>").unwrap();
    let title_re = Regex::new(r"<title>(.*?)</title>").unwrap();
    let suffix_re = Regex::new(r"\s*&#8211;.*$").unwrap();
    let title = h1_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .filter(|t| !t.is_empty())
        .or_else(|| {
            title_re
                .captures(&html)
                .map(|c| clean(suffix_re.replace(c.get(1).unwrap().as_str(), "").as_ref()))
        })
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "JAV777".to_string());
    let content_re = Regex::new(r#"<div class="post-content">(.*?)</div>"#).unwrap();
    let synopsis = content_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let tags: Vec<String> = {
        let tag_re = Regex::new(r#"rel="tag"[^>]*>([^<]+)<"#).unwrap();
        let mut seen = HashSet::new();
        tag_re
            .captures_iter(&html)
            .map(|c| c.get(1).unwrap().as_str().trim().to_string())
            .filter(|t| !t.is_empty() && seen.insert(t.clone()))
            .collect()
    };
    let stream = resolve(&url).await.ok().flatten();
    let mut episodes = Vec::new();
    if let Some(stream) = stream {
        episodes.push(episode_json(&format!("m|{stream}"), "JAV777·線1", &url));
    }
    episodes.push(episode_json(&url, "JAV777·原頁面", &url));
    Ok(json!({
        "id": video_id,
        "title": title,
        "cover": "",
        "synopsis": if tags.is_empty() { synopsis } else { format!("{}\n標籤: {}", synopsis, tags.join(" / ")) },
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = eu(query.trim());
    let url = format!("{HOST}/?s={enc}&paged=1");
    let html = fetch_text(&url).await?;
    let items = parse_list(&html, 25);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(stream) = video_id.strip_prefix("m|") {
        if stream.starts_with("http") {
            return Ok(json!({"url": stream}));
        }
    }
    if video_id.starts_with("http") {
        // 原頁面集：再走一次 resolve 链。
        if let Ok(Some(stream)) = resolve(video_id).await {
            return Ok(json!({"url": stream}));
        }
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("JAV777 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_resp_uses_shift_five() {
        // 人工构造：把含 the_video_id 的明文逐字符 +5，再让 decode_resp 还原。
        let plain = "x".repeat(50) + "the_video_id=\"my_video_1\"";
        let shifted: String = plain
            .chars()
            .map(|c| char::from_u32(c as u32 + 5).unwrap())
            .collect();
        let decoded = decode_resp(&shifted);
        assert!(decoded.contains("the_video_id"));
    }

    #[test]
    fn cat_url_builds_all_kinds() {
        assert_eq!(cat_url("n|", 1), "https://www.jav777.xyz/");
        assert_eq!(cat_url("n|", 2), "https://www.jav777.xyz/page/2/");
        assert_eq!(cat_url("t|stars", 1), "https://www.jav777.xyz/tag/stars/");
        assert_eq!(
            cat_url("c|%e5%ad%97%e5%b9%95%e3%81%82%e3%82%8a", 1),
            "https://www.jav777.xyz/category/%e5%ad%97%e5%b9%95%e3%81%82%e3%82%8a/"
        );
    }
}
