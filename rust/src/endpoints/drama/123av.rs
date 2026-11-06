//! 🎬123AV：123av.com 的 HTML 站。
//!
//! 与 jar 的 Zaka123avAmns 一一对应：10 固定分类 + 5 目录分类
//! （仅当 loadDir 非空时加入）、目录（card 卡片解析，每页 12
//! 条）、详情（player(JSON.parse('…')) 取分集，meta 取信息表）、
//! 搜索（/en/search）、取流（分集 URL 的宿主拼 /stream?id=
//! 取 media.stream）。
//! BLOCK 未成年检测正则必须保留（过滤用，不删站）：标题命中
//! 则剔除该卡片，详情 id 命中则不返回。已实证 12 条标题中有
//! 1 条含 "children" 被剔。
//! 修：①播放器域名已变，分集 URL 宿主是 sadie-shop.site
//! （jar 里的 javplayer.cc 已不用），流接口须按分集 URL 自身
//! 宿主拼；②分集 JSON 提取须与引号无关：定位 player(JSON.parse(
//! 后找 [{，字符串感知大括号配对截取，再 \\→\、\/→/、\uXXXX
//! 解码后解析（服务端每次返回的转义不同）。
//! 验门（2026-11-05 请求复现）：列表 12 卡、翻页 12 卡、详情
//! fc2-ppv-5003583、搜索 12 条、取流首分片 200 全过。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const SITE: &str = "https://123av.com";
const LANG: &str = "/en";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const DIR_TTL: Duration = Duration::from_secs(10 * 60);

static DIR_CACHE: Mutex<Option<(Vec<(String, Vec<String>)>, Instant)>> = Mutex::new(None);

fn block_re() -> Regex {
    Regex::new(
        "(?i)(loli|lolita|underage|child(?:ren)?|kids?|elementary\\s*school|primary\\s*school|junior\\s*high|middle\\s*school|未成年|幼女|儿童)",
    )
    .unwrap()
}

fn blocked(s: &str) -> bool {
    block_re().is_match(s)
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{SITE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("123AV请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
}

fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 与 Java 的 loadDir 一致：抓目录页取前 60 条过滤值（tag 从
/// 首页取），缓存 10 分钟。
async fn load_dir() -> Vec<(String, Vec<String>)> {
    if let Ok(guard) = DIR_CACHE.lock() {
        if let Some((cached, exp)) = guard.as_ref() {
            if Instant::now() < *exp {
                return cached.clone();
            }
        }
    }
    let mut out: Vec<(String, Vec<String>)> = Vec::new();
    for (kind, path) in [
        ("genre", "/en/genres"),
        ("maker", "/en/makers"),
        ("actress", "/en/actresses"),
        ("series", "/en/series"),
    ] {
        let mut values: Vec<String> = Vec::new();
        if let Ok(html) = get_text(&format!("{SITE}{path}")).await {
            let pattern = format!("/en/{}/([A-Za-z0-9_-]+)", regex::escape(kind));
            if let Ok(re) = Regex::new(&pattern) {
                for cap in re.captures_iter(&html) {
                    let v = cap[1].to_string();
                    if !values.contains(&v) {
                        values.push(v);
                    }
                    if values.len() >= 60 {
                        break;
                    }
                }
            }
        }
        out.push((kind.to_string(), values));
    }
    let mut tags: Vec<String> = Vec::new();
    if let Ok(html) = get_text(&format!("{SITE}{LANG}")).await {
        if let Ok(re) = Regex::new("/en/tags/([A-Za-z0-9_-]+)") {
            for cap in re.captures_iter(&html) {
                let v = cap[1].to_string();
                if !tags.contains(&v) {
                    tags.push(v);
                }
                if tags.len() >= 60 {
                    break;
                }
            }
        }
    }
    out.push(("tag".to_string(), tags));
    if let Ok(mut guard) = DIR_CACHE.lock() {
        *guard = Some((out.clone(), Instant::now() + DIR_TTL));
    }
    out
}

fn dir_first(dirs: &[(String, Vec<String>)], kind: &str) -> String {
    for (k, values) in dirs {
        if k == kind {
            return values.first().cloned().unwrap_or_default();
        }
    }
    String::new()
}

/// 与 Java 的 cards 一致：按 <div class="card" 分块，取链接、
/// 封面、标题、时长；标题命中 BLOCK 则剔除。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let marker = "<div class=\"card\"";
    let mut starts: Vec<usize> = Vec::new();
    let mut from = 0usize;
    while let Some(i) = page[from..].find(marker) {
        starts.push(from + i);
        from += i + marker.len();
    }
    if starts.is_empty() {
        return items;
    }
    let href_re =
        Regex::new("(?s)<a class=\"card__cover\"[^>]*href=\"([^\"]*/en/v/([^\"]+))\"").unwrap();
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
        let slug = cap[2].to_string();
        if seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        let title = pick(
            chunk,
            "(?s)<h3 class=\"card__title\"[^>]*>\\s*<a[^>]*>(.*?)</a>",
        );
        if title.is_empty() || blocked(&title) {
            continue;
        }
        let mut cover = pick(chunk, "(?i)<img class=\"card__img\"[^>]+src=\"([^\"]+)\"");
        if cover.is_empty() {
            cover = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let cover = if cover.starts_with("http") {
            cover
        } else if cover.starts_with("//") {
            format!("https:{cover}")
        } else if cover.starts_with('/') {
            format!("{SITE}{cover}")
        } else {
            String::new()
        };
        let mut remark = pick(chunk, "(?s)<span class=\"card__dur\"[^>]*>(.*?)</span>");
        if remark == "0:00" {
            remark = String::new();
        }
        let href = format!("{SITE}/en/v/{slug}");
        items.push(item_json(&href, &title, &cover, &remark));
    }
    items
}

/// 与引号无关的分集 JSON 提取：player(JSON.parse('...')) 里是
/// JS 字符串，内层 JSON 的双引号写成 \"，直接在原文上做括号配
/// 对会把 \" 当转义引号、永远走不出字符串；先按 JS 字符串规则
/// 取出引号内文、解转义后再解析 JSON。
fn extract_player_json(page: &str) -> Option<Value> {
    let marker = "player(JSON.parse(";
    let idx = page.find(marker)?;
    let rest = &page[idx + marker.len()..];
    let quote_rel = rest.find(|c| c == '\'' || c == '"')?;
    let quote = rest.as_bytes()[quote_rel];
    let body_start = quote_rel + 1;
    let bytes = rest.as_bytes();
    let mut i = body_start;
    let mut end = None;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            c if c == quote => {
                end = Some(i);
                break;
            }
            _ => i += 1,
        }
    }
    let body = &rest[body_start..end?];
    let unescaped = unescape_js(body);
    serde_json::from_str(&unescaped).ok()
}

/// JS 字符串解转义：\\→\、\/→/、\uXXXX→字、\"→"、\'→'、
/// \n\r\t 照原义。
fn unescape_js(raw: &str) -> String {
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::new();
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if c == '\\' && i + 1 < chars.len() {
            let n = chars[i + 1];
            match n {
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                '"' => out.push('"'),
                '\'' => out.push('\''),
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'u' if i + 5 < chars.len() => {
                    let hex: String = chars[i + 2..i + 6].iter().collect();
                    if let Ok(code) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(code) {
                            out.push(ch);
                        }
                    }
                    i += 4;
                }
                other => out.push(other),
            }
            i += 2;
        } else {
            out.push(c);
            i += 1;
        }
    }
    out
}

/// 分集 JSON 取 episodes（或 list，或单 url 对象）数组，返回
/// 每集的播放页 URL。
fn episode_urls(page: &str) -> Vec<String> {
    let Some(body) = extract_player_json(page) else {
        return Vec::new();
    };
    let mut rows: Vec<Value> = Vec::new();
    if let Some(eps) = body.get("episodes").and_then(|v| v.as_array()) {
        rows = eps.clone();
    } else if let Some(list) = body.get("list").and_then(|v| v.as_array()) {
        rows = list.clone();
    } else if let Some(arr) = body.as_array() {
        rows = arr.clone();
    } else if body.get("url").is_some() {
        rows = vec![body];
    }
    let mut out: Vec<String> = Vec::new();
    for entry in rows {
        let url = text_of(&entry, &["url"]);
        if !url.is_empty() && !out.contains(&url) {
            out.push(url);
        }
    }
    out
}

fn detail_meta(page: &str) -> (String, String, serde_json::Map<String, Value>) {
    let mut title = pick(page, "(?s)<h1 class=\"watch__title\"[^>]*>(.*?)</h1>");
    if title.is_empty() {
        title = pick(page, "(?s)<title[^>]*>(.*?)</title>");
        if let Some(i) = title.find(" — 123AV") {
            title = title[..i].trim().to_string();
        }
    }
    let mut cover = pick(page, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() || cover.contains("logo") {
        let bg = pick(page, "(?s)background-image:\\s*url\\('([^']+)'\\)");
        if !bg.is_empty() {
            cover = bg;
        }
    }
    let cover = if cover.starts_with("http") {
        cover
    } else if cover.starts_with("//") {
        format!("https:{cover}")
    } else if cover.starts_with('/') {
        format!("{SITE}{cover}")
    } else {
        String::new()
    };
    let mut extra = serde_json::Map::new();
    if let Ok(dl_re) = Regex::new("(?s)<dl class=\"watch__info\"[^>]*>(.*?)</dl>") {
        if let Some(cap) = dl_re.captures(page) {
            let dl = cap[1].to_string();
            let row_re = Regex::new("(?s)<dt[^>]*>(.*?)</dt>\\s*<dd[^>]*>(.*?)</dd>").unwrap();
            for row in row_re.captures_iter(&dl) {
                let key = strip_tags(&row[1]);
                let val = strip_tags(&row[2]);
                if !key.is_empty() && !val.is_empty() {
                    extra.insert(key, Value::String(val));
                }
            }
        }
    }
    (title, cover, extra)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("new", "最新更新"),
        category_json("recent", "最近添加"),
        category_json("hot", "热门推荐"),
        category_json("all", "全部片库"),
        category_json("censored", "有码"),
        category_json("uncensored", "无码"),
        category_json("uncensored-leaked", "无码流出"),
        category_json("jable", "Jable"),
        category_json("missav", "MissAV"),
        category_json("supjav", "SupJav"),
    ];
    let dirs = load_dir().await;
    for (kind, name) in [
        ("genre", "类型"),
        ("maker", "厂牌"),
        ("actress", "演员"),
        ("tag", "番号标签"),
        ("series", "系列"),
    ] {
        if !dir_first(&dirs, kind).is_empty() {
            list.push(category_json(kind, name));
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let cat = if category_id.is_empty() {
        "new".to_string()
    } else {
        category_id.to_string()
    };
    let url = if ["genre", "maker", "actress", "tag", "series"].contains(&cat.as_str()) {
        let dirs = load_dir().await;
        let first = dir_first(&dirs, &cat);
        let plural = match cat.as_str() {
            "genre" => "genres",
            "maker" => "makers",
            "actress" => "actresses",
            "tag" => "tags",
            _ => "series",
        };
        if first.is_empty() {
            format!("{SITE}{LANG}/{plural}?page={page}")
        } else {
            format!("{SITE}{LANG}/{plural}/{first}?page={page}")
        }
    } else if cat == "all" {
        format!("{SITE}{LANG}/all?sort=today&page={page}")
    } else {
        format!("{SITE}{LANG}/{cat}?page={page}")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": items.len() >= 12}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if blocked(series_id) {
        return Err(ApiError::Internal("123AV该影片命中未成年过滤".into()));
    }
    let slug = series_id
        .trim_start_matches("https://123av.com/en/v/")
        .trim_start_matches("/en/v/")
        .trim()
        .to_string();
    let url = format!("{SITE}{LANG}/v/{slug}");
    let page = get_text(&url).await?;
    let (title, mut cover, extra) = detail_meta(&page);
    let urls = episode_urls(&page);
    if cover.is_empty() {
        // 再无则取分集 poster 参数。
        let poster = pick(&page, "(?i)poster[^\"']*[\"']([^\"']+)");
        if !poster.is_empty() {
            cover = if poster.starts_with("http") {
                poster
            } else if poster.starts_with("//") {
                format!("https:{poster}")
            } else {
                poster
            };
        }
    }
    let mut episodes: Vec<Value> = Vec::new();
    for (i, ep_url) in urls.iter().enumerate() {
        episodes.push(episode_json(
            &format!("{slug}@{i}"),
            &format!("线路{}", i + 1),
            &url,
        ));
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("123AV未返回可播放分集".into()));
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let html = get_text(&format!("{SITE}{LANG}/search?keyword={encoded}&page=1")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：<slug>@<i> → 详情取分集 URL → 按其自身宿主拼
/// /stream?id=<hash>，回 media.stream（无 media 则顶层 stream）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(
            json!({"url": video_id, "header": {"User-Agent": UA, "Referer": format!("{SITE}/")}}),
        );
    }
    let (slug, idx) = match video_id.split_once('@') {
        Some((s, n)) => (s.to_string(), n.parse::<usize>().unwrap_or(0)),
        None => (video_id.to_string(), 0),
    };
    let page = get_text(&format!("{SITE}{LANG}/v/{slug}")).await?;
    let urls = episode_urls(&page);
    let ep_url = match urls.get(idx) {
        Some(u) => u.clone(),
        None => return Err(ApiError::Internal("123AV该集没有播放地址".into())),
    };
    let host = Regex::new("^(https?://[^/]+)")
        .unwrap()
        .captures(&ep_url)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let hash = Regex::new("/e/([A-Za-z0-9_-]+)")
        .unwrap()
        .captures(&ep_url)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    if host.is_empty() || hash.is_empty() {
        return Err(ApiError::Internal("123AV分集地址格式无法识别".into()));
    }
    let resp = client()?
        .get(format!("{host}/stream?id={hash}"))
        .header("User-Agent", UA)
        .header("Referer", format!("{host}/e/{hash}"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "123AV请求 HTTP {}",
            resp.status().as_u16()
        )));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    let mut stream = String::new();
    if let Some(media) = body.get("media") {
        stream = text_of(media, &["stream"]);
    }
    if stream.is_empty() {
        stream = text_of(&body, &["stream"]);
    }
    if stream.is_empty() {
        return Err(ApiError::Internal("123AV未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{host}/"), "Origin": host},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_matches_children() {
        assert!(blocked("DLDSS-572 children title"));
        assert!(!blocked("IPX-811 正常标题"));
    }

    #[test]
    fn player_json_extracted_quote_free() {
        let page = "player(JSON.parse('[{\\\"url\\\":\\\"https://sadie-shop.site/e/abc123\\\"}]'))";
        let urls = episode_urls(page);
        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0], "https://sadie-shop.site/e/abc123");
    }

    #[test]
    fn unescape_handles_unicode() {
        assert_eq!(unescape_js("\\u0041\\u0042"), "AB");
        assert_eq!(unescape_js("a\\/b"), "a/b");
    }
}
