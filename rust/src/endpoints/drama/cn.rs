//! 🔞中文秘密资源：cnlovehubx18.xyz 的 HTML 站。
//!
//! 与 jar 的 ZakaCnAmns 一一对应：4 分类（国产传媒、日本有码、
//! 中文字幕、日本无码）、目录（卡片解析，翻页为 -<N>/）、详情
//! （player_aaaa 对象取标题封面、vodplay 正则取分集）、搜索
//! （vodsearch 路径）、取流（播放页 player_aaaa.url 或裸 m3u8
//! 正则，无则回播放页）。
//! 验门（2026-11-05）：本机出口连不上本站（DNS 解析到
//! 198.18.59.100，代理 RemoteDisconnected、直连 000，三次尝试
//! 均失败），5 项均未验；文件按 jar 逻辑写，须手机侧复验。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://cnlovehubx18.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
}

fn abs_url(href: &str) -> String {
    let href = href.trim();
    if href.starts_with("//") {
        return format!("https:{href}");
    }
    if href.starts_with("http") {
        return href.to_string();
    }
    if let Some(rest) = href.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{href}")
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "中文秘密资源请求 HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 ZakaDrama.matchEnd 一致：从 { 起括号配对，串内
/// 的括号不算，返回配对 } 的下标。
fn match_end(page: &str, start: usize) -> Option<usize> {
    let bytes = page.as_bytes();
    let mut depth: i64 = 0;
    let mut in_str = false;
    let mut escaped = false;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if in_str {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_str = false;
            }
        } else if c == '"' {
            in_str = true;
        } else if c == '{' {
            depth += 1;
        } else if c == '}' {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// 与 Java 的 ZakaDrama.blob 一致：找含 key 的 JSON 对象。
fn blob(page: &str, key: &str) -> String {
    let mut offset = 0usize;
    for _ in 0..8 {
        let Some(rel) = page[offset..].find(key) else {
            return String::new();
        };
        let idx = offset + rel;
        let mut pos = idx;
        for _ in 0..300 {
            let Some(open) = page[..pos].rfind('{') else {
                break;
            };
            pos = open;
            if let Some(end) = match_end(page, open) {
                if end > idx {
                    let cand = &page[open..=end];
                    if cand.len() <= 3 * 1024 * 1024 && serde_json::from_str::<Value>(cand).is_ok()
                    {
                        return cand.to_string();
                    }
                }
            }
            if pos == 0 {
                break;
            }
            let Some(prev) = page[..pos.saturating_sub(1)].rfind('{') else {
                break;
            };
            pos = prev + 1;
        }
        offset = idx + key.len();
    }
    String::new()
}

/// 与 Java 的 ZakaDrama.svRaw 一致：正则取 "key":"..."。
fn sv_raw(s: &str, key: &str) -> String {
    let pattern = format!("\"{}\"\\s*:\\s*\"([^\"]*)\"", regex::escape(key));
    let Ok(re) = Regex::new(&pattern) else {
        return String::new();
    };
    match re.captures(s) {
        Some(cap) => cap[1].replace("\\/", "/"),
        None => String::new(),
    }
}

/// 与 Java 的 ZakaDrama.sv 一致：先按 JSON 取，取不到走正则。
fn sv(blob_json: &str, key: &str) -> String {
    if let Ok(body) = serde_json::from_str::<Value>(blob_json) {
        let v = text_of(&body, &[key]);
        if !v.is_empty() {
            return v;
        }
    }
    sv_raw(blob_json, key)
}

fn pick(page: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(page) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 与 Java 的 parseCards 一致：按卡片 <a> 分块，取链接、标题、
/// 封面，备注为番号大写。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let marker = "<a class=\"group relative flex flex-col\"";
    let mut starts: Vec<usize> = Vec::new();
    let mut from = 0usize;
    while let Some(i) = page[from..].find(marker) {
        starts.push(from + i);
        from += i + marker.len();
    }
    if starts.is_empty() {
        return items;
    }
    let href_re = Regex::new("href=\"(/962a/watch/([^\"]+))\"").unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, start) in starts.iter().enumerate() {
        let stop = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            (*start + 6000).min(page.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &page[*start..stop];
        let Some(cap) = href_re.captures(chunk) else {
            continue;
        };
        let id = cap[2].to_string();
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let mut title = pick(
            chunk,
            "(?s)class=\"text-secondary[^\"]*\"[^>]*>(.*?)</span>",
        );
        if title.is_empty() {
            title = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]+)\"");
            if let Some(stripped) = title.strip_suffix(&format!(" {id}")) {
                title = stripped.to_string();
            }
            title = title.replace("在线观看", "").trim().to_string();
        }
        if title.is_empty() {
            title = id.clone();
        }
        let mut pic = pick(chunk, "(?i)<img[^>]+data-src=\"([^\"]+)\"");
        if pic.is_empty() {
            pic = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let pic = if pic.contains("placeholder") || pic.is_empty() {
            String::new()
        } else {
            abs_url(&pic)
        };
        let href = abs_url(&cap[1]);
        items.push(item_json(&href, &title, &pic, &id.to_uppercase()));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("/962a/vodtype/guochanchuanmei/", "国产传媒"),
        category_json("/962a/vodtype/ribenyouma/", "日本有码"),
        category_json("/962a/vodtype/zhongwenzimu/", "中文字幕"),
        category_json("/962a/vodtype/ribenwuma/", "日本无码"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let base = if category_id.is_empty() {
        "/962a/vodtype/guochanchuanmei/".to_string()
    } else {
        category_id.to_string()
    };
    let url = if page > 1 {
        let trimmed = base.trim_end_matches('/');
        format!("{HOST}{trimmed}-{page}/")
    } else {
        format!("{HOST}{base}")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        abs_url(series_id)
    };
    let page = get_text(&url).await?;
    let b = blob(&page, "player_aaaa");
    let mut title = pick(&page, "(?s)<h1[^>]*>(.*?)</h1>");
    if title.is_empty() {
        title = pick(&page, "(?s)property=\"og:title\" content=\"([^\"]+)\"");
    }
    if title.is_empty() {
        title = sv(&b, "vod_name");
    }
    if title.is_empty() {
        title = "中文秘密资源".to_string();
    }
    let mut cover = pick(&page, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = sv(&b, "vod_pic");
    }
    let cover = if cover.is_empty() {
        cover
    } else {
        abs_url(&cover)
    };
    let mut episodes: Vec<Value> = Vec::new();
    let ep_re = Regex::new("/962a/vodplay/id/([^/]+)/sid/(\\d+)/nid/(\\d+)/").unwrap();
    let mut seen: Vec<String> = Vec::new();
    for cap in ep_re.captures_iter(&page) {
        let play_path = format!(
            "/962a/vodplay/id/{}/sid/{}/nid/{}/",
            &cap[1], &cap[2], &cap[3]
        );
        if seen.contains(&play_path) {
            continue;
        }
        seen.push(play_path.clone());
        let name = format!("线路 {} · 第 {} 集", &cap[2], &cap[3]);
        episodes.push(episode_json(&format!("{HOST}{play_path}"), &name, &url));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&url, "正片", &url));
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let url = format!("{HOST}/962a/vodsearch/wd/{encoded}/");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：抓播放页，player_aaaa.url 取流，无则裸 m3u8 正则，
/// 再无则回播放页地址（壳侧嗅探）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let page = get_text(video_id).await?;
    let b = blob(&page, "player_aaaa");
    let mut url = sv(&b, "url");
    if url.is_empty() {
        let re = Regex::new("\"url\"\\s*:\\s*\"(https?://[^\"]+\\.m3u8[^\"]*)\"").unwrap();
        if let Some(cap) = re.captures(&page) {
            url = cap[1].replace("\\/", "/");
        }
    }
    if url.is_empty() {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_parse_watch_links() {
        let page = "<a class=\"group relative flex flex-col\" href=\"/962a/watch/abc123\"><img data-src=\"https://img.example.com/1.jpg\" alt=\"标题 abc123\"></a>";
        let items = parse_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["vod_id"],
            "https://cnlovehubx18.xyz/962a/watch/abc123"
        );
        assert_eq!(items[0]["vod_remarks"], "ABC123");
    }

    #[test]
    fn blob_finds_player_aaaa() {
        let page =
            "var player_aaaa={\"vod_name\":\"标题\",\"url\":\"https://cdn.example.com/1.m3u8\"};";
        let b = blob(page, "player_aaaa");
        assert_eq!(sv(&b, "url"), "https://cdn.example.com/1.m3u8");
    }
}
