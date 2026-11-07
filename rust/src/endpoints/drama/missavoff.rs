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
//! 2026-11-07 修（FJIN-172）：packer 载荷是单引号 `}('…`，旧正
//! 则只认 `}("`，解出 0 条、详情只剩“嗅探”一集；parse 切片按字
//! 节窗口切中文页会在字符中间 panic，改走 safe_slice 收敛边界。

use std::sync::Mutex;
use std::time::Duration;

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

fn set_best(host: &str) {
    if let Ok(mut guard) = BEST.lock() {
        *guard = Some(host.to_string());
    }
}

/// 单次取页超时：共享客户端默认 20 秒，实测中继层每次都顶满
/// 20 秒才失败，4 个域名顺序试光中继一层就烧 80 秒；各层按
/// 实测成功耗时给短超时（直连失败 2–9 秒、jina 成功约 6–7 秒），
/// RequestBuilder::timeout 覆盖共享值。
const DIRECT_TIMEOUT: Duration = Duration::from_secs(3);
const DM1_TIMEOUT: Duration = Duration::from_secs(3);
const RELAY_TIMEOUT: Duration = Duration::from_secs(5);
const JINA_TIMEOUT: Duration = Duration::from_secs(8);

async fn try_get(url: &str, extra_headers: &[(&str, &str)], timeout: Duration) -> Option<String> {
    let mut req = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .timeout(timeout);
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

/// 一层候选顺序试：逐个来、先成功者胜。必须逐个——实测并行
/// 会反噬：4 路并行抢 jina 全灭（12 秒超时），直连/dm1 并行层
/// 也全被拖到超时上限；逐个试 jina missav.live 6 秒就通。
/// （2026-11-07 实测：并行层耗时 = 超时上限，顺序探针才通。）
async fn try_tier_seq(
    cands: Vec<(String, String, Vec<(String, String)>)>,
    timeout: Duration,
) -> Option<(String, String)> {
    for (host, url, headers) in cands {
        let hs: Vec<(&str, &str)> = headers
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        if let Some(html) = try_get(&url, &hs, timeout).await {
            return Some((host, html));
        }
    }
    None
}

fn referer_headers(host: &str) -> Vec<(String, String)> {
    vec![("Referer".to_string(), format!("{host}/"))]
}

/// 取页总兜底：各层超时加起来最坏约 8+12+32+6+5=63 秒，超 Dart
/// 45 秒详情超时；40 秒处直接断、回干净报错，不拖到 Dart 超时。
async fn fetch_page(path: &str) -> ApiResult<(String, String)> {
    match tokio::time::timeout(Duration::from_secs(40), fetch_page_inner(path)).await {
        Ok(r) => r,
        Err(_) => Err(ApiError::Internal("MissAV原生取页超时".into())),
    }
}

/// 取页：直取→dm1/ 前缀→tv506 中继→jina.ai 兜底，全程逐个试
/// （并行 burst 会把出口连接拖垮，见 try_tier_seq）。各层超时
/// 3/3/5/8 秒；直连/dm1/中继三层实测全部失败、只烧时间，所以
/// dm1 只试前 2 个域名、中继只试 BEST 域名 1 次；jina 是唯一
/// 实测能通的路（3/3 次顺序成功），BEST 域名有记录时先走一次
/// jina 快路。外层 40 秒总超时兜底，在 Dart 45 秒超时内。
/// 返回（所用域名，正文）。
async fn fetch_page_inner(path: &str) -> ApiResult<(String, String)> {
    // 0. 快路：上次成功的域名走 jina 先试一次（稳态约 8 秒回）。
    if let Some(best) = BEST.lock().ok().and_then(|g| g.clone()) {
        let url = format!("https://r.jina.ai/{best}{path}");
        let referer = format!("{best}/");
        let headers = vec![
            ("X-Return-Format", "html"),
            ("X-No-Cache", "true"),
            ("Referer", referer.as_str()),
        ];
        if let Some(html) = try_get(&url, &headers, JINA_TIMEOUT).await {
            return Ok((best, html));
        }
    }
    // 1. 直取（4 域名逐个，3 秒）
    let direct: Vec<(String, String, Vec<(String, String)>)> = HOSTS
        .iter()
        .map(|h| (h.to_string(), format!("{h}{path}"), referer_headers(h)))
        .collect();
    if let Some((host, html)) = try_tier_seq(direct, DIRECT_TIMEOUT).await {
        set_best(&host);
        return Ok((host, html));
    }
    // 2. jina.ai 兜底（4 域名逐个，8 秒；唯一实测能通的路，放前面）
    let jina: Vec<(String, String, Vec<(String, String)>)> = HOSTS
        .iter()
        .map(|h| {
            (
                h.to_string(),
                format!("https://r.jina.ai/{h}{path}"),
                vec![
                    ("X-Return-Format".to_string(), "html".to_string()),
                    ("X-No-Cache".to_string(), "true".to_string()),
                    ("Referer".to_string(), format!("{h}/")),
                ],
            )
        })
        .collect();
    if let Some((host, html)) = try_tier_seq(jina, JINA_TIMEOUT).await {
        set_best(&host);
        return Ok((host, html));
    }
    // 3. dm1/ 前缀变体（只试前 2 个域名；8/8 次探针全失败，省时间）
    let dm1: Vec<(String, String, Vec<(String, String)>)> = HOSTS[..2]
        .iter()
        .map(|h| (h.to_string(), format!("{h}/dm1{path}"), referer_headers(h)))
        .collect();
    if let Some((host, html)) = try_tier_seq(dm1, DM1_TIMEOUT).await {
        set_best(&host);
        return Ok((host, html));
    }
    // 4. tv506 中继（只试 BEST 域名 1 次；8/8 次探针全挂 20 秒超时）
    let relay_host = best_host();
    let target = format!("{relay_host}{path}");
    let encoded: String = url::form_urlencoded::byte_serialize(target.as_bytes()).collect();
    let relay_url = format!("{RELAY}/p?u={encoded}");
    if let Some(html) = try_get(
        &relay_url,
        &[("Referer", &format!("{relay_host}/"))],
        RELAY_TIMEOUT,
    )
    .await
    {
        set_best(&relay_host);
        return Ok((relay_host, html));
    }
    Err(ApiError::Internal("MissAV原生没有取到页面".into()))
}

/// 字节窗口切 UTF-8 文本：窗口边界落在多字节字符中间时
/// 直接切片会 panic（实测 FJIN-172 搜索页在字节 96836 的“期”
/// 字中间炸掉）；向内收敛到最近的字符边界。
fn safe_slice(s: &str, start: usize, end: usize) -> &str {
    let len = s.len();
    let mut start = start.min(len);
    let mut end = end.min(len);
    while start < len && !s.is_char_boundary(start) {
        start += 1;
    }
    while end > start && !s.is_char_boundary(end) {
        end -= 1;
    }
    if end <= start {
        return "";
    }
    &s[start..end]
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
            safe_slice(page, chunk_start, chunk_end)
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
            safe_slice(page, chunk_start, chunk_end)
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
    let Ok(packer_re) = Regex::new(
        "(?s)\\}\\(['\"](.*?)',(\\d+),(\\d+),['\"](.*?)['\"]\\.split\\(['\"]\\|['\"]\\)",
    ) else {
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
    fn unpack_single_quote_packer() {
        // FJIN-172 详情页实测：打包器是单引号 `}('…'，旧正则只认
        // `}("`，解出 0 条、详情只剩“嗅探”一集。词表/载荷取自真页。
        let html = r#"eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\b'+e(c)+'\b','g'),k[c])}}return p}('f=\'8://7.6/5-4-3-2-1/e.0\';d=\'8://7.6/5-4-3-2-1/c/9.0\';b=\'8://7.6/5-4-3-2-1/a/9.0\';',16,16,'m3u8|e8a23d2b9404|aad7|4c77|d8a8|9b88e28b|com|surrit|https|video|1080p|source1280|720p|source842|playlist|source'.split('|'),0,{}))"#;
        let urls = unpack_m3u8(html);
        assert_eq!(urls.len(), 3);
        assert!(urls.iter().any(|u| u.contains("/1080p/video.m3u8")));
        assert!(urls.iter().any(|u| u.contains("/720p/video.m3u8")));
        assert!(urls.iter().any(|u| u.ends_with("/playlist.m3u8")));
    }

    #[test]
    fn safe_slice_never_panics_mid_char() {
        // "ab期cd"：a=0 b=1 期=2..5 c=5 d=6
        let s = "ab期cd";
        assert_eq!(safe_slice(s, 2, 5), "期");
        assert_eq!(safe_slice(s, 3, 6), "c");
        assert_eq!(safe_slice(s, 0, 100), s);
        assert_eq!(safe_slice(s, 5, 2), "");
    }

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

    /// 基线探针：逐个计时取页候选（直连→dm1→中继→jina），定位
    /// detail("fjin-172") 149 秒慢在哪一层。只看日志，不断言。
    #[tokio::test]
    #[ignore]
    async fn probe_fetch_candidates_fjin172() {
        use std::time::{Duration, Instant};
        let path = "/cn/fjin-172";
        let mut cands: Vec<(String, String, Vec<(String, String)>)> = Vec::new();
        for h in HOSTS {
            cands.push((
                format!("direct {h}"),
                format!("{h}{path}"),
                vec![("Referer".to_string(), format!("{h}/"))],
            ));
        }
        for h in HOSTS {
            cands.push((
                format!("dm1 {h}"),
                format!("{h}/dm1{path}"),
                vec![("Referer".to_string(), format!("{h}/"))],
            ));
        }
        for h in HOSTS {
            let target = format!("{h}{path}");
            let encoded: String = url::form_urlencoded::byte_serialize(target.as_bytes()).collect();
            cands.push((
                format!("relay {h}"),
                format!("{RELAY}/p?u={encoded}"),
                vec![("Referer".to_string(), format!("{h}/"))],
            ));
        }
        for h in HOSTS {
            cands.push((
                format!("jina {h}"),
                format!("https://r.jina.ai/{h}{path}"),
                vec![
                    ("X-Return-Format".to_string(), "html".to_string()),
                    ("X-No-Cache".to_string(), "true".to_string()),
                    ("Referer".to_string(), format!("{h}/")),
                ],
            ));
        }
        let total = Instant::now();
        for (label, url, headers) in &cands {
            let t = Instant::now();
            let headers: Vec<(&str, &str)> = headers
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();
            let got = try_get(url, &headers, Duration::from_secs(20)).await;
            eprintln!(
                "PROBE {label} elapsed={:?} ok={}",
                t.elapsed(),
                got.is_some()
            );
            if got.is_some() {
                break;
            }
        }
        eprintln!("PROBE total elapsed={:?}", total.elapsed());
    }

    /// 探针：按 fetch_page_inner 的顺序逐层计时（直连逐个→jina 逐个→
    /// dm1 前 2 个→中继 1 次），看各层耗时。只看日志。
    #[tokio::test]
    #[ignore]
    async fn probe_tier_sequence() {
        use std::time::Instant;
        let path = "/cn/fjin-172";
        let mk = |prefix: &str, jina: bool| -> Vec<(String, String, Vec<(String, String)>)> {
            HOSTS
                .iter()
                .map(|h| {
                    let url = if jina {
                        format!("https://r.jina.ai/{h}{path}")
                    } else if prefix.is_empty() {
                        format!("{h}{path}")
                    } else {
                        format!("{h}{prefix}{path}")
                    };
                    let headers = if jina {
                        vec![
                            ("X-Return-Format".to_string(), "html".to_string()),
                            ("X-No-Cache".to_string(), "true".to_string()),
                            ("Referer".to_string(), format!("{h}/")),
                        ]
                    } else {
                        referer_headers(h)
                    };
                    (h.to_string(), url, headers)
                })
                .collect()
        };
        let total = Instant::now();
        let t = Instant::now();
        let r = try_tier_seq(mk("", false), DIRECT_TIMEOUT).await;
        eprintln!(
            "PROBE tier direct elapsed={:?} ok={}",
            t.elapsed(),
            r.is_some()
        );
        let t = Instant::now();
        let r = try_tier_seq(mk("", true), JINA_TIMEOUT).await;
        eprintln!(
            "PROBE tier jina-seq elapsed={:?} ok={} host={}",
            t.elapsed(),
            r.is_some(),
            r.as_ref().map(|(h, _)| h.as_str()).unwrap_or("")
        );
        let t = Instant::now();
        let dm1: Vec<(String, String, Vec<(String, String)>)> =
            mk("/dm1", false).into_iter().take(2).collect();
        let r = try_tier_seq(dm1, DM1_TIMEOUT).await;
        eprintln!(
            "PROBE tier dm1 elapsed={:?} ok={}",
            t.elapsed(),
            r.is_some()
        );
        let t = Instant::now();
        let host = best_host();
        let target = format!("{host}{path}");
        let encoded: String = url::form_urlencoded::byte_serialize(target.as_bytes()).collect();
        let r = try_get(
            &format!("{RELAY}/p?u={encoded}"),
            &[("Referer", &format!("{host}/"))],
            RELAY_TIMEOUT,
        )
        .await;
        eprintln!(
            "PROBE tier relay elapsed={:?} ok={}",
            t.elapsed(),
            r.is_some()
        );
        eprintln!("PROBE tier-sequence total={:?}", total.elapsed());
    }

    /// 探针：只试 jina missav.live 一次（顺序、20 秒超时），看 jina
    /// 当前是否还通——并行探针后它可能被限流。
    #[tokio::test]
    #[ignore]
    async fn probe_jina_single() {
        use std::time::Instant;
        let t = Instant::now();
        let got = try_get(
            "https://r.jina.ai/https://missav.live/cn/fjin-172",
            &[
                ("X-Return-Format", "html"),
                ("X-No-Cache", "true"),
                ("Referer", "https://missav.live/"),
            ],
            Duration::from_secs(20),
        )
        .await;
        eprintln!(
            "PROBE jina-single elapsed={:?} ok={} len={}",
            t.elapsed(),
            got.is_some(),
            got.as_ref().map(|s| s.len()).unwrap_or(0)
        );
    }

    /// 探针：只用 Rust 客户端拉 surrit 清单，把 403 正文存 /tmp 看
    /// 拦的是什么（curl 同地址同头回 200 真清单）。
    #[tokio::test]
    #[ignore]
    async fn probe_surrit_403_body() {
        let resp = client()
            .unwrap()
            .get("https://surrit.com/9b88e28b-d8a8-4c77-aad7-e8a23d2b9404/playlist.m3u8")
            .header("User-Agent", UA)
            .header("Referer", "https://missav.live/")
            .send()
            .await
            .expect("发请求");
        let status = resp.status().as_u16();
        let body = resp.text().await.unwrap_or_default();
        std::fs::write("/tmp/rust403.html", &body).ok();
        let head: String = body.chars().take(600).collect();
        eprintln!(
            "PROBE surrit rust status={status} len={} head={head}",
            body.len()
        );
    }

    /// 探针：detail("fjin-172") 出 3 集后，逐集用不同 Referer 拉 m3u8，
    /// 看哪种头能拿到真清单（上次计时测到 HTML+403）。只看日志。
    #[tokio::test]
    #[ignore]
    async fn probe_play_fjin172() {
        let d = detail("fjin-172").await.expect("detail fjin-172");
        let eps = d["episodes"].as_array().cloned().unwrap_or_default();
        let page_url = d["id"].as_str().unwrap_or("").to_string();
        let root = page_url
            .splitn(4, '/')
            .take(3)
            .collect::<Vec<_>>()
            .join("/");
        eprintln!(
            "PROBE page_url={page_url} root={root} episodes={}",
            eps.len()
        );
        for (i, ep) in eps.iter().enumerate() {
            let u = ep["video_id"].as_str().unwrap_or("");
            eprintln!("PROBE ep{i} {} {}", ep["title"].as_str().unwrap_or(""), u);
            for (label, referer) in [
                ("root", root.as_str()),
                ("page", page_url.as_str()),
                ("none", ""),
            ] {
                let mut req = client().unwrap().get(u).header("User-Agent", UA);
                if !referer.is_empty() {
                    req = req.header("Referer", referer);
                }
                match req.send().await {
                    Ok(resp) => {
                        let status = resp.status().as_u16();
                        let ct = resp
                            .headers()
                            .get("content-type")
                            .and_then(|v| v.to_str().ok())
                            .unwrap_or("")
                            .to_string();
                        let body = resp.text().await.unwrap_or_default();
                        let first = body
                            .lines()
                            .next()
                            .unwrap_or("")
                            .chars()
                            .take(80)
                            .collect::<String>();
                        eprintln!(
                            "PROBE ep{i} referer={label} status={status} ct={ct} len={} first={first}",
                            body.len()
                        );
                    }
                    Err(e) => eprintln!("PROBE ep{i} referer={label} err={e}"),
                }
            }
        }
    }

    /// 计时：detail("fjin-172") 全程 + 3 集 + 首集 m3u8 首分片
    /// Range 206。目标 45 秒内回。
    #[tokio::test]
    #[ignore]
    async fn timing_detail_fjin172() {
        use std::time::{Duration, Instant};
        let t = Instant::now();
        let d = detail("fjin-172").await.expect("detail fjin-172");
        let elapsed = t.elapsed();
        let eps = d["episodes"].as_array().cloned().unwrap_or_default();
        eprintln!(
            "TIMING detail fjin-172 elapsed={:?} title={} episodes={}",
            elapsed,
            d["title"].as_str().unwrap_or(""),
            eps.len()
        );
        assert!(
            elapsed < Duration::from_secs(45),
            "detail 超过 45 秒：{elapsed:?}"
        );
        assert_eq!(eps.len(), 3, "期望 3 集，实际 {}", eps.len());
        for ep in &eps {
            let u = ep["video_id"].as_str().unwrap_or("");
            assert!(u.contains(".m3u8"), "分集不是 m3u8：{u}");
        }
        // 注意：首分片 Range 206 不在进程内断言——2026-11-07 实测，
        // Rust 客户端（reqwest/rustls）拉 surrit 清单 9/9 次回 403，
        // 而 curl 同地址同头回 200 真清单（主清单 707 字节→1080p
        // 分档 60360 字节 VOD→首分片 Range 206、首字节 0x47）。
        // 这是客户端指纹被 surrit 拦，不是流本身假；修它要动共享
        // 客户端 TLS 栈（全站影响），不在本次三项范围内，见回报。
    }
}
