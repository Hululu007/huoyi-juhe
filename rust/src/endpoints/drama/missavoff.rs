//! 🔞MissAV官方┃原生：MissAV 直连站（多域名 + 中继 + jina 兜底）。
//!
//! 与 jar 的 ZakaMissavOffAmns 一一对应：4 个域名按序试取
//! （直连→dm1/ 前缀变体→tv506 中继→jina.ai 兜底；FlareSolverr
//! 与 WebView 在核心里无法实现，不写）、6 分类（列表类与目录类
//! 分开解析）、详情（Dean Edwards packer 解出三档 m3u8）、
//! 搜索（cn/search，空结果回退按番号直取）、取流（m3u8 直接回，
//! 无流回详情页由壳嗅探）。
//! 验门（2026-11-05 请求复现）：直连本机出口 chunked 断连、
//! 中继 504，jina 200 正常；列表 18 条真视频、翻页 18 条、详情
//! nhdtc-266、三档 m3u8 首分片全部 200 全过。注意 packer 解出
//! 的地址尾部带反斜杠，须 strip 后再请求。

use std::sync::Mutex;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const RELAY: &str = "https://tv506.ystv.top";
const HOSTS: &[&str] = &[
    "https://missav.live",
    "https://missav.ai",
    "https://missav123.com",
    "https://missav.ws",
];
const LANGS: &[&str] = &[
    "cn", "ja", "en", "ko", "fil", "th", "vi", "de", "fr", "ms", "tw",
];
const EXCLUDE_SEGS: &[&str] = &[
    "genres",
    "makers",
    "actresses",
    "labels",
    "series",
    "new",
    "release",
    "uncensored-leak",
    "search",
    "ranking",
    "vip",
    "today-hot",
    "weekly-hot",
    "monthly-hot",
];
const BANNED_SLUGS: &[&str] = &[
    "klive",
    "clive",
    "saved",
    "playlists",
    "history",
    "login",
    "register",
];

static BEST: Mutex<Option<String>> = Mutex::new(None);

fn best_host() -> String {
    if let Ok(guard) = BEST.lock() {
        if let Some(h) = guard.as_ref() {
            return h.clone();
        }
    }
    HOSTS[0].to_string()
}

fn looks_ok(html: &str) -> bool {
    if html.len() < 1200 {
        return false;
    }
    let lower = html.to_lowercase();
    if lower.contains("just a moment")
        || lower.contains("cf_chl_opt")
        || lower.contains("cf_chl")
        || lower.contains("cf-please-wait")
        || lower.contains("challenge-form")
        || lower.contains("enable javascript and cookies")
        || lower.contains("请稍候")
        || lower.contains("attention required")
    {
        return false;
    }
    lower.contains("missav")
}

async fn try_get(url: &str, extra_headers: &[(&str, &str)]) -> Option<String> {
    let mut req = client().ok()?.get(url).header("User-Agent", UA);
    for (k, v) in extra_headers {
        req = req.header(*k, *v);
    }
    let resp = req.send().await.ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let text = resp.text().await.ok()?;
    if looks_ok(&text) {
        Some(text)
    } else {
        None
    }
}

/// 取页：先 BEST 域名直取；失败试各域名 × dm1/ 前缀；再走
/// tv506 中继；最后走 jina.ai 兜底。返回（所用域名，正文）。
async fn fetch_page(path: &str) -> ApiResult<(String, String)> {
    let mut hosts: Vec<String> = Vec::new();
    if let Ok(guard) = BEST.lock() {
        if let Some(h) = guard.as_ref() {
            hosts.push(h.clone());
        }
    }
    for h in HOSTS {
        if !hosts.contains(&h.to_string()) {
            hosts.push(h.to_string());
        }
    }
    // 1. 直取
    for host in &hosts {
        let url = format!("{host}{path}");
        if let Some(html) = try_get(&url, &[("Referer", &format!("{host}/"))]).await {
            if let Ok(mut guard) = BEST.lock() {
                *guard = Some(host.clone());
            }
            return Ok((host.clone(), html));
        }
    }
    // 2. dm1/ 前缀变体
    for host in &hosts {
        let url = format!("{host}/dm1{path}");
        if let Some(html) = try_get(&url, &[("Referer", &format!("{host}/"))]).await {
            if let Ok(mut guard) = BEST.lock() {
                *guard = Some(host.clone());
            }
            return Ok((host.clone(), html));
        }
    }
    // 3. tv506 中继
    for host in &hosts {
        let target = format!("{host}{path}");
        let encoded: String = url::form_urlencoded::byte_serialize(target.as_bytes()).collect();
        let url = format!("{RELAY}/p?u={encoded}");
        if let Some(html) = try_get(&url, &[("Referer", &format!("{host}/"))]).await {
            if let Ok(mut guard) = BEST.lock() {
                *guard = Some(host.clone());
            }
            return Ok((host.clone(), html));
        }
    }
    // 4. jina.ai 兜底
    for host in &hosts {
        let url = format!("https://r.jina.ai/{host}{path}");
        if let Some(html) = try_get(
            &url,
            &[
                ("X-Return-Format", "html"),
                ("X-No-Cache", "true"),
                ("Referer", &format!("{host}/")),
            ],
        )
        .await
        {
            if let Ok(mut guard) = BEST.lock() {
                *guard = Some(host.clone());
            }
            return Ok((host.clone(), html));
        }
    }
    Err(ApiError::Internal("MissAV原生没有取到页面".into()))
}

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
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

/// 与 Java 的 isVideoPath 一致：路径 2–4 段、末段 3–60 字、
/// 倒数第 2 段须为语言码，排除分区与 BANNED。
fn is_video_path(href: &str) -> bool {
    let path = href.split('?').next().unwrap_or(href);
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if segs.len() < 2 || segs.len() > 4 {
        return false;
    }
    let last = segs[segs.len() - 1];
    if last.len() < 3 || last.len() > 60 {
        return false;
    }
    if !last
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '%' || c == '.')
    {
        return false;
    }
    let lang = segs[segs.len() - 2];
    if !LANGS.contains(&lang) {
        return false;
    }
    for seg in &segs {
        if EXCLUDE_SEGS.contains(seg) || BANNED_SLUGS.contains(seg) {
            return false;
        }
    }
    true
}

fn slug_of(href: &str) -> String {
    let path = href.split('?').next().unwrap_or(href);
    path.split('/')
        .filter(|s| !s.is_empty())
        .next_back()
        .unwrap_or("")
        .to_string()
}

/// 与 Java 的 list 解析一致：取 text-secondary 链接或首个视频
/// 路径链接，标题取链接文本或 img alt 或 slug 大写，封面取
/// img data-src/src，备注取右下角时长。
fn parse_list(page: &str, host: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let Ok(href_re) = Regex::new("href=\"(https?://[^\"#]+|/[^\"#]*)\"") else {
        return items;
    };
    let matches: Vec<(usize, String)> = href_re
        .captures_iter(page)
        .filter_map(|cap| {
            let href = cap[1].to_string();
            let m = cap.get(0)?;
            if is_video_path(&href) {
                Some((m.start(), href))
            } else {
                None
            }
        })
        .collect();
    let mut seen: Vec<String> = Vec::new();
    for (i, (start, href)) in matches.iter().enumerate() {
        let slug = slug_of(href);
        if slug.is_empty() || seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        let chunk_start = start.saturating_sub(2000);
        let chunk_end = if i + 1 < matches.len() {
            matches[i + 1].0.min(page.len())
        } else {
            (*start + 3000).min(page.len())
        };
        let chunk = if chunk_end > chunk_start {
            &page[chunk_start..chunk_end]
        } else {
            ""
        };
        // 标题：本链接的文本（text-secondary 链接优先）
        let mut title = String::new();
        let anchor_re = Regex::new(&format!(
            "(?s)<a[^>]*href=\"{}\"[^>]*>(.*?)</a>",
            regex::escape(href)
        ))
        .unwrap();
        if let Some(cap) = anchor_re.captures(chunk) {
            title = strip_tags(&cap[1]);
        }
        if title.is_empty() {
            title = pick(
                chunk,
                "(?s)class=\"[^\"]*text-secondary[^\"]*\"[^>]*>(.*?)</a>",
            );
        }
        if title.is_empty() {
            title = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]+)\"");
        }
        if title.is_empty() {
            title = slug.to_uppercase();
        }
        let mut cover = pick(chunk, "(?i)<img[^>]+data-src=\"([^\"]+)\"");
        if cover.is_empty() {
            cover = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let cover = if cover.starts_with("http") {
            cover
        } else if cover.starts_with("//") {
            format!("https:{cover}")
        } else if cover.starts_with('/') {
            format!("{host}{cover}")
        } else {
            String::new()
        };
        let remark = pick(
            chunk,
            "(?s)class=\"[^\"]*bottom-1[^\"]*right-1[^\"]*\"[^>]*>([^<]*)<",
        );
        let full = if href.starts_with("http") {
            href.clone()
        } else {
            format!("{host}{href}")
        };
        items.push(item_json(&full, &title, &cover, &remark));
    }
    items
}

/// 目录页（女优/类型/发行商）：folder 卡，名取 h4 或 img alt，
/// 排除“数字+条影片”一类的计数行。
fn parse_folders(page: &str, host: &str, kind: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let pattern = format!("href=\"([^\"]*/cn/{}/([^\"?#]+))\"", regex::escape(kind));
    let Ok(href_re) = Regex::new(&pattern) else {
        return items;
    };
    let matches: Vec<(usize, String)> = href_re
        .captures_iter(page)
        .map(|cap| {
            let m = cap.get(0).unwrap();
            (m.start(), cap[1].to_string())
        })
        .collect();
    let count_re = Regex::new("^\\d+.*条影片.*$").unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, (start, href)) in matches.iter().enumerate() {
        if seen.contains(href) {
            continue;
        }
        seen.push(href.clone());
        let chunk_start = start.saturating_sub(1500);
        let chunk_end = if i + 1 < matches.len() {
            matches[i + 1].0.min(page.len())
        } else {
            (*start + 1500).min(page.len())
        };
        let chunk = if chunk_end > chunk_start {
            &page[chunk_start..chunk_end]
        } else {
            ""
        };
        let mut name = pick(chunk, "(?s)<h4[^>]*>(.*?)</h4>");
        if name.is_empty() {
            name = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]+)\"");
        }
        if name.is_empty() || count_re.is_match(&name) {
            continue;
        }
        let mut cover = pick(chunk, "(?i)<img[^>]+data-src=\"([^\"]+)\"");
        if cover.is_empty() {
            cover = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let cover = if cover.starts_with("http") {
            cover
        } else if cover.starts_with("//") {
            format!("https:{cover}")
        } else if cover.starts_with('/') {
            format!("{host}{cover}")
        } else {
            String::new()
        };
        let full = if href.starts_with("http") {
            href.clone()
        } else {
            format!("{host}{href}")
        };
        let mut item = item_json(&format!("folder@{full}"), &name, &cover, "");
        if let Some(obj) = item.as_object_mut() {
            obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
        }
        items.push(item);
    }
    items
}

/// Dean Edwards packer 解码：正则取 payload/进制/词数/词表，
/// 按进制还原词后找 .m3u8 地址（尾部反斜杠须 strip）。
fn unpack_m3u8(page: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let Ok(packer_re) = Regex::new("(?s)\\}\\(\"(.*?)',(\\d+),(\\d+),'(.*?)'\\.split\\('\\|'\\)")
    else {
        return out;
    };
    let Some(cap) = packer_re.captures(page) else {
        return out;
    };
    let payload = cap[1].to_string();
    let radix: u32 = cap[2].parse().unwrap_or(36);
    let words: Vec<&str> = cap[4].split('|').collect();
    let word_re = Regex::new("\\b[0-9a-zA-Z]+\\b").unwrap();
    let decoded = word_re.replace_all(&payload, |caps: &regex::Captures| {
        let token = &caps[0];
        match u64::from_str_radix(token, radix) {
            Ok(n) if (n as usize) < words.len() => words[n as usize].to_string(),
            _ => token.to_string(),
        }
    });
    let m3u8_re = Regex::new("(https?://[^\\s\"'\\\\]+\\.m3u8[^\\s\"'\\\\]*)").unwrap();
    for cap in m3u8_re.captures_iter(&decoded) {
        let url = cap[1].trim_end_matches('\\').to_string();
        if !out.contains(&url) {
            out.push(url);
        }
    }
    out
}

fn quality_name(url: &str) -> String {
    if url.contains("1080p") {
        "1080P".to_string()
    } else if url.contains("720p") {
        "720P".to_string()
    } else if url.contains("480p") {
        "480P".to_string()
    } else {
        "高清".to_string()
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("cn/new", "最近更新"),
        category_json("cn/release", "新作上市"),
        category_json("cn/uncensored-leak", "无码流出"),
        category_json("cn/actresses", "女优一览"),
        category_json("cn/genres", "类型"),
        category_json("cn/makers", "发行商"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let cat = if category_id.is_empty() {
        "cn/new".to_string()
    } else {
        category_id.to_string()
    };
    let mut path = format!("/{cat}");
    if page > 1 {
        path = format!("{path}?page={page}");
    }
    let (host, html) = fetch_page(&path).await?;
    let items =
        if cat.ends_with("/actresses") || cat.ends_with("/genres") || cat.ends_with("/makers") {
            let kind = cat.rsplit('/').next().unwrap_or("");
            parse_folders(&html, &host, kind)
        } else {
            parse_list(&html, &host)
        };
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim_start_matches("folder@").trim();
    // folder 卡被当作详情打开时，转调该目录的列表。
    if id.contains("/actresses/") || id.contains("/genres/") || id.contains("/makers/") {
        let path = if id.starts_with("http") {
            let host = best_host();
            id.strip_prefix(&host).unwrap_or(id).to_string()
        } else {
            id.to_string()
        };
        let (host, html) = fetch_page(&path).await?;
        let kind = if path.contains("/actresses/") {
            "actresses"
        } else if path.contains("/genres/") {
            "genres"
        } else {
            "makers"
        };
        let folders = parse_folders(&html, &host, kind);
        let mut episodes: Vec<Value> = Vec::new();
        for entry in folders {
            let vid = match entry.get("vod_id") {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            let name = match entry.get("vod_name") {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            if vid.is_empty() || name.is_empty() {
                continue;
            }
            episodes.push(episode_json(&vid, &name, id));
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("MissAV原生该目录为空".into()));
        }
        return Ok(json!({
            "id": id,
            "title": "目录",
            "cover": "",
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let path = if id.starts_with("http") {
        let host = best_host();
        id.strip_prefix(&host).unwrap_or(id).to_string()
    } else if id.starts_with("/cn/") || id.starts_with("cn/") {
        format!("/{}", id.trim_start_matches('/'))
    } else {
        format!("/cn/{id}")
    };
    let (host, html) = fetch_page(&path).await?;
    let mut title = pick(&html, "(?s)property=\"og:title\" content=\"([^\"]+)\"");
    if title.is_empty() {
        title = pick(&html, "(?s)<title[^>]*>(.*?)</title>");
        if let Some(i) = title.find('|') {
            title = title[..i].trim().to_string();
        }
    }
    if title.is_empty() {
        title = slug_of(&path).to_uppercase();
    }
    let mut cover = pick(&html, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = pick(&html, "(?s)name=\"twitter:image\" content=\"([^\"]+)\"");
    }
    let mut streams = unpack_m3u8(&html);
    if streams.is_empty() {
        let re = Regex::new("(https?://[^\\s\"'\\\\]+\\.m3u8[^\\s\"'\\\\]*)").unwrap();
        for cap in re.captures_iter(&html) {
            let url = cap[1].trim_end_matches('\\').to_string();
            if !streams.contains(&url) {
                streams.push(url);
            }
        }
    }
    let page_url = format!("{host}{path}");
    let mut episodes: Vec<Value> = Vec::new();
    if streams.is_empty() {
        episodes.push(episode_json(&page_url, "嗅探", &page_url));
    } else {
        for url in streams {
            let name = quality_name(&url);
            episodes.push(episode_json(&url, &name, &page_url));
        }
    }
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let path = format!("/cn/search/{encoded}");
    let (host, html) = fetch_page(&path).await?;
    let mut items = parse_list(&html, &host);
    if items.is_empty() {
        // 空结果回退：按番号直取 cn/<小写词>。
        let slug = query.trim().to_lowercase();
        if let Ok((host2, html2)) = fetch_page(&format!("/cn/{slug}")).await {
            items = parse_list(&html2, &host2);
        }
    }
    Ok(json!({"items": items}))
}

/// 取流：去“嗅探$”/“高清$”前缀；含 .m3u8 直接回，否则回页面
/// 地址（壳侧嗅探）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id
        .trim_start_matches("嗅探$")
        .trim_start_matches("高清$")
        .trim()
        .to_string();
    let host = best_host();
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{host}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_path_rules() {
        assert!(is_video_path("/cn/wawa-045"));
        assert!(is_video_path("/dm278/cn/wawa-045"));
        assert!(!is_video_path("/cn/new"));
        assert!(!is_video_path("/cn/klive"));
        assert!(!is_video_path("/cn/genres"));
        assert!(!is_video_path("/cn/ab"));
    }

    #[test]
    fn quality_names() {
        assert_eq!(quality_name("https://x/720p/video.m3u8"), "720P");
        assert_eq!(quality_name("https://x/playlist.m3u8"), "高清");
    }
}
