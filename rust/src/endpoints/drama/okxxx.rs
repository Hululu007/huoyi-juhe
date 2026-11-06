//! OKXXX：KVS 模板站，列表为 thumb-video 卡片，详情取 HLS/mp4。
//!
//! 与 Dart 的 ZakaKvsAmns（ext site=okxxx）一一对应。分类：jar 静态表里
//! 没有 okxxx 的分类三元组，站内 /categories/ 页回空体、列表页也不含分类
//! 链接，故本文件只出最新更新 + 搜索热榜（hot，搜 anal）两项，不编造分类。
//! 列表模板 `/videos/<页>/`（第 1 页即 /videos/1/，已实测），搜索模板
//! `/search/?q=<词>&page=<页>`。详情：标题取 <title>（去 ` - ` 后缀与站名），
//! 封面 og:image；streams() 先找 HLS，再找 <source> mp4，再全页扫 mp4
//!（跳过 preview/海报图），按清晰度降序；无源时取 `/embed/<数字id>` 页
//! 再扫。分集每档一集，video_id 即直链，play() 原样回。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://okxxx.life";
const HOSTS: &[&str] = &[
    "https://okxxx.life",
    "https://okxxx.ws",
    "https://okxxx.one",
    "https://okxxx.win",
    "https://okxxx.men",
    "https://okxxx.icu",
    "https://okx18.vip",
    "https://okx18.cc",
    "https://okx18.icu",
];
const SITE_NAME: &str = "OKXXX";
const LIST_TPL: &str = "/videos/%d/";
const CAT_TPL: &str = "/categories/%s/%d/";
const SEARCH_TPL: &str = "/search/?q=%s&page=%d";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/// 分类：[slug, 名]，与站内导航 1:1，type_id 为 c:<slug>。
const CATS: &[(&str, &str)] = &[];

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
    let mut last_err = ApiError::Internal("OKXXX 请求失败".into());
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
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .header("Referer", format!("{host}/"))
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
            last_err = ApiError::Internal(format!("OKXXX HTTP {}", resp.status().as_u16()));
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
            last_err = ApiError::Internal("OKXXX 返回内容不可用".into());
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

/// 绝对地址取路径部分，站内地址原样返回。
fn to_path(href: &str) -> String {
    let s = href.trim();
    if let Some(rest) = s.strip_prefix("http://") {
        if let Some(idx) = rest.find('/') {
            return rest[idx..].to_string();
        }
        return "/".to_string();
    }
    if let Some(rest) = s.strip_prefix("https://") {
        if let Some(idx) = rest.find('/') {
            return rest[idx..].to_string();
        }
        return "/".to_string();
    }
    s.to_string()
}

/// 清晰度数值：按 URL 里的 2160/1080/720/480/360 或 4K 标。
fn quality_rank(url: &str) -> u32 {
    let lower = url.to_lowercase();
    // HLS 自适应流排最前，与 streams()“先找 HLS”一致；m3u8
    // 本身无档位数字，原先得 0 分会被 720P 等 mp4 压到后面。
    if lower.contains(".m3u8") {
        return 9999;
    }
    for (pat, rank) in [
        ("2160", 2160),
        ("4k", 2160),
        ("1080", 1080),
        ("720", 720),
        ("480", 480),
        ("360", 360),
    ] {
        if lower.contains(pat) {
            return rank;
        }
    }
    0
}

/// 清晰度档名：m3u8 为 HLS，mp4 按档标，无档标为 Auto。
fn quality_label(url: &str) -> String {
    if url.contains(".m3u8") {
        return "HLS".to_string();
    }
    match quality_rank(url) {
        2160 => "4K".to_string(),
        1080 => "1080P".to_string(),
        720 => "720P".to_string(),
        480 => "480P".to_string(),
        360 => "360P".to_string(),
        _ => "Auto".to_string(),
    }
}

/// 视频卡片：按 thumb-video 切块，块内取视频链接、标题、封面、时长。
fn parse_cards(html: &str) -> Vec<Value> {
    let href_re = Regex::new(r#"href="([^"]+)""#).unwrap();
    let video_re = Regex::new(r#"/video/\d+/"#).unwrap();
    let title_attr = Regex::new(r#"title="([^"]+)""#).unwrap();
    let title_div = Regex::new(r#"(?s)<div class="title"[^>]*>(.*?)</div>"#).unwrap();
    let alt_re = Regex::new(r#"alt="([^"]+)""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+(?:data-src|data-original|src)="([^"]+)""#).unwrap();
    let dur_re = Regex::new(r#"class="dur(?:acion|ation)"[^>]*>([^<]*)<"#).unwrap();
    let dur_num = Regex::new(r"[0-9:]{3,10}").unwrap();
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"thumb thumb-video\">").skip(1) {
        let mut href = String::new();
        for cap in href_re.captures_iter(block) {
            let cand = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            if video_re.is_match(cand) {
                href = cand.to_string();
                break;
            }
        }
        if href.is_empty() {
            continue;
        }
        let id = to_path(&href);
        if seen.contains(&id) {
            continue;
        }
        let title = title_attr
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(m.as_str()))
            .or_else(|| {
                title_div
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| unesc(tag_re.replace_all(m.as_str(), "").as_ref()))
            })
            .or_else(|| {
                alt_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| unesc(m.as_str()))
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        let cover = img_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .and_then(|m| dur_num.find(m.as_str()))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 取流：先找 HLS，再找 <source> mp4，再全页扫 mp4（跳过 preview/海报图）。
fn streams(html: &str) -> Vec<(String, String)> {
    let mut urls: Vec<String> = Vec::new();
    let m3u8_re = Regex::new(r#"https?://[^"'\s<>]+\.m3u8[^"'\s<>]*"#).unwrap();
    for m in m3u8_re.find_iter(html) {
        let u = m.as_str();
        if u.ends_with(".jpg") || u.ends_with(".png") || u.ends_with(".webp") {
            continue;
        }
        if !urls.contains(&u.to_string()) {
            urls.push(u.to_string());
        }
    }
    let src_re = Regex::new(r#"<source[^>]+src="([^"]+)""#).unwrap();
    for cap in src_re.captures_iter(html) {
        let raw = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if raw.contains("preview") || raw.len() < 12 {
            continue;
        }
        let full = if raw.starts_with("http") {
            raw.to_string()
        } else if let Some(rest) = raw.strip_prefix("//") {
            format!("https://{rest}")
        } else if let Some(rest) = raw.strip_prefix('/') {
            format!("{HOST}{rest}")
        } else {
            format!("{HOST}/{raw}")
        };
        if !full.contains(".mp4") {
            continue;
        }
        if !urls.contains(&full) {
            urls.push(full);
        }
    }
    if urls.is_empty() {
        let any = Regex::new(r#"https?://[^"'\s<>]+\.mp4[^"'\s<>]*"#).unwrap();
        for m in any.find_iter(html) {
            let u = m.as_str();
            if u.contains("preview") || u.contains("/tmb/") || u.contains("poster") {
                continue;
            }
            if !urls.contains(&u.to_string()) {
                urls.push(u.to_string());
            }
        }
    }
    urls.sort_by(|a, b| quality_rank(b).cmp(&quality_rank(a)));
    urls.into_iter()
        .map(|u| {
            let label = quality_label(&u);
            (label, u)
        })
        .collect()
}

/// 取 <title>，去 ` - ` 后缀与站名。
fn extract_title(html: &str) -> String {
    let title = Regex::new(r"(?s)<title>\s*(.*?)\s*</title>").unwrap();
    title
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| {
            let mut t = unesc(m.as_str());
            if let Some(idx) = t.find(" - ") {
                t.truncate(idx);
            }
            t = t.replace(SITE_NAME, "");
            t.trim().to_string()
        })
        .unwrap_or_default()
}

/// 取 og:image / og:description / video:duration。
fn meta_content(html: &str, property: &str) -> String {
    let pattern = format!(r#"<meta[^>]+property="{}"[^>]+content="([^"]+)""#, property);
    let re = Regex::new(&pattern).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

fn list_url(page: i64) -> String {
    LIST_TPL.replace("%d", &page.to_string())
}

fn cat_url(slug: &str, page: i64) -> String {
    CAT_TPL
        .replacen("%s", slug, 1)
        .replace("%d", &page.to_string())
}

fn search_url(query: &str, page: i64) -> String {
    let q = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    SEARCH_TPL
        .replacen("%s", &q, 1)
        .replace("%d", &page.to_string())
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = vec![category_json("new", "最新更新")];
    for (slug, name) in CATS {
        list.push(category_json(&format!("c:{slug}"), name));
    }
    list.push(category_json("hot", "搜索热榜"));
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.trim();
    let page = if page < 1 { 1 } else { page };
    let path = if tid.is_empty() || tid == "new" {
        list_url(page)
    } else if tid == "hot" {
        search_url("anal", page)
    } else if let Some(slug) = tid.strip_prefix("c:") {
        cat_url(slug, page)
    } else {
        list_url(page)
    };
    let (_host, html) = fetch(&path).await?;
    let cards = parse_cards(&html);
    let has_more = cards.len() >= 20;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let path = to_path(sid);
    let (_host, html) = fetch(&path).await?;
    let title = extract_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("OKXXX 未返回影片标题".into()));
    }
    let cover = meta_content(&html, "og:image");
    let desc = meta_content(&html, "og:description");
    let dur = meta_content(&html, "video:duration");
    let mut synopsis = String::new();
    if let Ok(secs) = dur.parse::<u64>() {
        if secs > 0 {
            synopsis.push_str(&format!("时长：{}分钟\n", secs / 60));
        }
    }
    if !desc.is_empty() {
        synopsis.push_str(&desc);
    }
    let mut found = streams(&html);
    if found.is_empty() {
        let embed_re = Regex::new(r"/embed/(\d+)").unwrap();
        if let Some(c) = embed_re.captures(&html) {
            let eid = c.get(1).map(|m| m.as_str()).unwrap_or("");
            if !eid.is_empty() {
                if let Ok((_h2, embed_html)) = fetch(&format!("/embed/{eid}")).await {
                    found = streams(&embed_html);
                }
            }
        }
    }
    if found.is_empty() {
        return Err(ApiError::Internal("OKXXX 本条未取到播放地址".into()));
    }
    let episodes: Vec<Value> = found
        .iter()
        .map(|(label, url)| episode_json(url, label, sid))
        .collect();
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
    let path = search_url(query.trim(), 1);
    let (_host, html) = fetch(&path).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        Ok(json!({"url": vid}))
    } else {
        Err(ApiError::Internal("OKXXX 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_empty() {
        assert_eq!(CATS.len(), 0);
    }

    #[test]
    fn url_templates() {
        assert_eq!(list_url(1), "/videos/1/");

        assert_eq!(search_url("test", 1), "/search/?q=test&page=1");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<div class="thumb thumb-video"><a href="/video/802063/" title="Sample Title"><img data-src="https://pic/c.jpg"></a><span class="duration">12:34</span></div>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/video/802063/");
        assert_eq!(cards[0]["title"], "Sample Title");
        assert_eq!(cards[0]["remark"], "12:34");
    }

    #[test]
    fn streams_prefers_hls() {
        let html = r##"<video><source src="https://x/v_720p.mp4"></video><a href="https://x/master.m3u8">x</a>"##;
        let list = streams(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].0, "HLS");
        assert_eq!(list[1].0, "720P");
    }
}
