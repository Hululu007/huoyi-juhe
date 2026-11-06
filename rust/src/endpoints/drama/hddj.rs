//! 🔞黄豆短剧┃AI短剧+漫剧：aihuangdou.com 的 HTML 站。
//!
//! 与 jar 的 ZakaHddjAmns 一一对应：分类（站内 5 个导航：AI短剧、
//! AI漫剧、成人小说、短剧社区、排行榜）、目录（ZakaCard 卡片解析）、
//! 详情（视频走 playbackEndpoint 取集、小说走章节、社区帖走播放
//! 源）、搜索、取流（播放页 blob 取 bestSrc，无则 playbackEndpoint
//! 模板换 __EP__ 再请求，取 data.src 签名 m3u8）。
//! 修：站内翻页已由 jar 的 page/<N>/ 改为 <N>/（旧地址 404，
//! 新地址 /ai-duanju/2/ 实测 200 且与第 1 页无重叠）；blob 按 jar
//! 原算法实现（向回找 {、括号配对、JSON 校验、最多 8 次）；小说与
//! 社区帖的阅读链路原走本地代理，核心里没有该代理，只列章节与
//! 播放集，阅读播放会明说需阅读核心。
//! 验门（2026-11-05 请求复现）：分类首页 66 条带真封面、翻页 22
//! 条、详情（标题/封面/简介/2 集）、搜索 33 条、取流签名 m3u8 首
//! 分片 200 全过；其余 4 分类均出卡片。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const HOST: &str = "https://aihuangdou.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const BODIES: &[&str] = &[
    "nineListBody",
    "rank-runners",
    "id=\"main\"",
    "id=\"listBody\"",
    "class=\"grid\"",
];
const BLOCKS: &[&str] = &[
    "<article class=\"drama-card\"",
    "novel-card",
    "post-card",
    "rank-lead",
    "rank-runner",
    "<li class=\"rank-row\"",
];

/// 与 Java 的 ZakaHttp.get 一致：桌面 UA，200 才算成功。
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
        return Err(ApiError::Internal(format!("黄豆短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 ZakaDrama.unesc 一致：解 \\u0026/\\/ 与常见实体。
fn unesc(raw: &str) -> String {
    raw.replace("\\u0026", "&")
        .replace("\\u003d", "=")
        .replace("\\u003f", "?")
        .replace("\\/", "/")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// 与 Java 的 ZakaDrama.strip 一致：去标签、解实体、压空白。
fn strip(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let un = unesc(&no_tag);
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&un, " ").trim().to_string()
}

/// 与 Java 的 ZakaDrama.clean 一致：解实体去空白，// 补 https:。
fn clean(raw: &str) -> String {
    let s = unesc(raw).trim().to_string();
    if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else {
        s
    }
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

fn between(page: &str, start: &str, end: &str) -> String {
    let Some(i) = page.find(start) else {
        return String::new();
    };
    let from = i + start.len();
    let Some(j) = page[from..].find(end) else {
        return String::new();
    };
    page[from..from + j].trim().to_string()
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

/// 与 Java 的 ZakaDrama.blob 一致：找含 key 的 JSON 对象（向回
/// 找 {、括号配对、能解析成 JSON 才算，最多找 8 处 key）。
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
            pos = pos.saturating_sub(1);
            // rfind 下一次从 pos 之前找，循环开头再 rfind
            let Some(prev) = page[..pos].rfind('{') else {
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
        Some(cap) => unesc(&cap[1]),
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

/// 与 Java 的 ZakaDrama.bestSrc 一致：current.src/srcHevc →
/// videoSrc → epPlaySrcs 里最大集号的地址。
fn best_src(blob_json: &str) -> String {
    if blob_json.is_empty() {
        return String::new();
    }
    if let Ok(body) = serde_json::from_str::<Value>(blob_json) {
        if let Some(cur) = get(&body, "current") {
            let s = text_of(cur, &["src", "srcHevc"]);
            if !s.is_empty() {
                return clean(&s);
            }
        }
        let s = text_of(&body, &["videoSrc"]);
        if !s.is_empty() {
            return clean(&s);
        }
        if let Some(eps) = get(&body, "epPlaySrcs") {
            if let Some(map) = eps.as_object() {
                let mut best_key: i64 = -1;
                let mut best_val = String::new();
                for (k, v) in map {
                    if let Ok(n) = k.trim().parse::<i64>() {
                        if n > best_key {
                            best_key = n;
                            best_val = match v {
                                Value::String(s) => s.clone(),
                                _ => String::new(),
                            };
                        }
                    }
                }
                if !best_val.is_empty() {
                    return clean(&best_val);
                }
            }
        }
    }
    String::new()
}

/// 与 Java 的 ZakaDrama.epsOf 一致：blob.eps[] 取 (集号, 集名)。
fn eps_of(blob_json: &str) -> Vec<(i64, String)> {
    let mut out = Vec::new();
    if blob_json.is_empty() {
        return out;
    }
    if let Ok(body) = serde_json::from_str::<Value>(blob_json) {
        if let Some(rows) = get(&body, "eps").and_then(arr_of) {
            for (i, entry) in rows.iter().enumerate() {
                let n = match get(entry, "n") {
                    Some(Value::Number(n)) => n.as_i64().unwrap_or(i as i64 + 1),
                    _ => i as i64 + 1,
                };
                let mut title = text_of(entry, &["fact", "title"]);
                if title.is_empty() {
                    title = format!("第 {n} 集");
                }
                out.push((n, title.trim().to_string()));
            }
        }
    }
    out
}

/// 与 Java 的 ZakaDrama.nums 一致：正则取 group(1)，去重后按
/// 数字升序。
fn nums(page: &str, pattern: &str) -> Vec<String> {
    let Ok(re) = Regex::new(pattern) else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::new();
    for cap in re.captures_iter(page) {
        let g = cap[1].to_string();
        if !out.contains(&g) {
            out.push(g);
        }
    }
    out.sort_by_key(|s| s.parse::<i64>().unwrap_or(i64::MAX));
    out
}

fn tidy(raw: &str) -> String {
    let s = Regex::new("\\s+")
        .unwrap()
        .replace_all(raw, " ")
        .trim()
        .to_string();
    let s = s.trim_start_matches(['《', '<']).trim().to_string();
    let s = match s.find('》') {
        Some(i) if i > 0 => s[..i].trim().to_string(),
        _ => s,
    };
    s.trim_end_matches(['》', '>']).trim().to_string()
}

fn ok_pic(s: &str) -> bool {
    let t = s.trim();
    if t.len() < 8
        || t.starts_with("data:")
        || t.contains("loading")
        || t.contains("placeholder")
        || t.contains("no_preview")
        || t.contains("drama-loading")
    {
        return false;
    }
    if t.contains("/static/") && !t.contains("/upload") {
        return false;
    }
    let lower = t.to_lowercase();
    lower.contains(".jpg")
        || lower.contains(".jpeg")
        || lower.contains(".png")
        || lower.contains(".webp")
        || lower.contains(".avif")
        || lower.contains("img")
}

fn card_image(block: &str) -> String {
    for attr in ["data-src", "data-original", "data-lazy-src"] {
        let pattern = format!("{attr}=\"([^\"]{{6,600}})\"");
        if let Ok(re) = Regex::new(&pattern) {
            if let Some(cap) = re.captures(block) {
                let v = clean(&cap[1]);
                if ok_pic(&v) {
                    return abs_url(&v);
                }
            }
        }
    }
    if let Ok(re) = Regex::new("<img[^>]+src=\"([^\"]+)\"") {
        for cap in re.captures_iter(block) {
            let v = clean(&cap[1]);
            if ok_pic(&v) {
                return abs_url(&v);
            }
        }
    }
    String::new()
}

fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip(&cap[1]),
        None => String::new(),
    }
}

fn card_remark(block: &str) -> String {
    for pattern in [
        "hg-drama-card__episode\"[^>]*>(.{0,60}?)</span>",
        "class=\"eps-flag\"[^>]*>([^<]{1,40})<",
        "class=\"[a-z0-9_\\-]*score[a-z0-9_\\-]*\"[^>]*>(.{1,40}?)<",
        "<small[^>]*>(.{1,60}?)</small>",
        "class=\"badge[^\"]*\"[^>]*>([^<]{1,20})<",
    ] {
        let full = format!("(?s){pattern}");
        let v = pick(block, &full);
        if !v.is_empty() {
            return tidy(&v);
        }
    }
    "影视".to_string()
}

/// 与 Java 的 ZakaCard.parse 一致：按 bodies 切正文、按 blocks
/// 切卡片，逐块取链接/标题/封面/备注。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    if page.len() < 400 {
        return items;
    }
    let mut start = 0usize;
    let mut best: Option<usize> = None;
    for body in BODIES {
        if let Some(i) = page.find(body) {
            if i > 0 && (best.is_none() || i < best.unwrap()) {
                best = Some(i);
            }
        }
    }
    if let Some(i) = best {
        start = i;
    }
    let body = &page[start..];
    let mut cuts: Vec<usize> = Vec::new();
    for block in BLOCKS {
        let mut from = 0usize;
        while let Some(i) = body[from..].find(block) {
            cuts.push(from + i);
            from += i + block.len();
        }
    }
    if cuts.is_empty() {
        return items;
    }
    cuts.sort_unstable();
    let href_re = Regex::new(
        "(?i)href=\"([^\"'#\\s]*(?:/(?:drama|novel|novels|posts|post|detail|duanju|manju|zhenrenju|shipin|manhua|xiaoshuo|video)/[0-9][^\"'#?\\s]*))\"",
    )
    .unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, cut) in cuts.iter().enumerate() {
        let end = if i + 1 < cuts.len() {
            cuts[i + 1]
        } else {
            (*cut + 4000).min(body.len())
        };
        if end <= *cut {
            continue;
        }
        let chunk = &body[*cut..end];
        let Some(cap) = href_re.captures(chunk) else {
            continue;
        };
        let href = abs_url(&cap[1]);
        if href.is_empty() {
            continue;
        }
        let key = href.trim_end_matches('/').to_string();
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        let mut title = pick(chunk, "(?s)data-track-item-name=\"([^\"]{1,200})\"");
        if title.is_empty() {
            title = pick(chunk, "(?s)<h3[^>]*>(.{1,200}?)</h3>");
        }
        if title.is_empty() {
            title = pick(chunk, "(?s)<h2[^>]*>(.{1,200}?)</h2>");
        }
        if title.is_empty() {
            title = pick(chunk, "(?s)class=\"sr-only\"[^>]*>(.{1,200}?)</span>");
        }
        if title.is_empty() {
            title = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]{2,200})\"");
        }
        let mut name = tidy(&title);
        if name.is_empty() {
            let slug = href.trim_end_matches('/').rsplit('/').next().unwrap_or("");
            let digits: String = slug.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
            name = format!("作品 {digits}");
        }
        let pic = card_image(chunk);
        let remark = card_remark(chunk);
        let content = pick(chunk, "(?s)<p[^>]*>(.{1,300}?)</p>");
        let mut item = item_json(&href, &name, &pic, &remark);
        if content.len() > 8 {
            if let Some(obj) = item.as_object_mut() {
                obj.insert("content".to_string(), Value::String(content));
            }
        }
        items.push(item);
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("https://aihuangdou.com/ai-duanju/", "AI短剧"),
        category_json("https://aihuangdou.com/ai-manju/", "AI漫剧"),
        category_json("https://aihuangdou.com/novels/", "成人小说"),
        category_json("https://aihuangdou.com/posts/", "短剧社区"),
        category_json("https://aihuangdou.com/rankings/", "排行榜"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let base = if category_id.is_empty() {
        "https://aihuangdou.com/ai-duanju/".to_string()
    } else {
        category_id.to_string()
    };
    // 修：站内翻页是 <分类><N>/，jar 的 page/<N>/ 已 404。
    let url = if page > 1 {
        let trimmed = base.trim_end_matches('/');
        format!("{trimmed}/{page}/")
    } else {
        base
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = html.contains("rel=\"next\"");
    Ok(json!({"items": items, "has_more": has_more}))
}

fn detail_meta(page: &str) -> (String, String, String) {
    let mut title = Regex::new("(?s)<h1[^>]*>(.*?)</h1>")
        .ok()
        .and_then(|re| re.captures(page))
        .map(|cap| strip(&cap[1]))
        .unwrap_or_default();
    if title.is_empty() {
        title = strip(&between(page, "property=\"og:title\" content=\"", "\""));
    }
    if let Some(rest) = title.strip_prefix("黄豆短剧 ") {
        title = rest.to_string();
    }
    if title.is_empty() {
        title = "黄豆短剧".to_string();
    }
    let mut pic = between(page, "property=\"og:image\" content=\"", "\"");
    if pic.is_empty() {
        if let Ok(re) = Regex::new("<img[^>]+data-src=\"([^\"]+\\.(?:jpg|jpeg|png|webp))\"") {
            if let Some(cap) = re.captures(page) {
                pic = cap[1].to_string();
            }
        }
    }
    let pic = clean(&pic);
    let pic = if pic.is_empty() { pic } else { abs_url(&pic) };
    let mut desc = between(page, "property=\"og:description\" content=\"", "\"");
    if desc.is_empty() {
        desc = between(page, "name=\"description\" content=\"", "\"");
    }
    let desc = unesc(&desc).trim().to_string();
    (title, pic, desc)
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = series_id.trim_start_matches("folder@").trim().to_string();
    let url = if url.starts_with("http") {
        url
    } else {
        abs_url(&url)
    };
    let page = get_text(&url).await?;
    let (title, pic, desc) = detail_meta(&page);
    let id_num = Regex::new("/(?:drama|video|novel|posts?)/(\\d{1,9})")
        .ok()
        .and_then(|re| re.captures(&url))
        .map(|cap| cap[1].to_string())
        .unwrap_or_default();
    let mut episodes: Vec<Value> = Vec::new();
    let mut remark = String::new();
    if url.contains("/novel/") {
        // 小说：章节按 /novel/<id>/<n>/ 列出；正文走本地代理，
        // 核心里没有该代理，取流时明说需阅读核心。
        let pattern = format!("/novel/{}/(\\d{{1,4}})/", regex::escape(&id_num));
        let chapters = nums(&page, &pattern);
        for n in chapters {
            let ep_url = format!("{HOST}/novel/{id_num}/{n}/");
            episodes.push(episode_json(&ep_url, &format!("第 {n} 章"), &url));
        }
        if episodes.is_empty() {
            episodes.push(episode_json(
                &format!("{HOST}/novel/{id_num}/1/"),
                "第 1 章",
                &url,
            ));
        }
        remark = "小说".to_string();
    } else if Regex::new(".*/posts?/\\d{1,9}/?.*")
        .ok()
        .map(|re| re.is_match(&url))
        .unwrap_or(false)
    {
        // 社区帖：blob 取 bestSrc，无则取 videoSrc。
        let b = blob(&page, "playbackEndpoint");
        let mut src = best_src(&b);
        if src.is_empty() {
            src = sv_raw(&page, "videoSrc");
            src = clean(&src);
        }
        if !src.is_empty() {
            episodes.push(episode_json(&src, "播放", &url));
        } else {
            episodes.push(episode_json(&url, "播放", &url));
        }
        remark = "社区帖".to_string();
    } else {
        // 视频：先 /1/ 页 blob 的 eps，再调 /videos/<id>/episodes，
        // 最后数详情页内的 /video/<id>/<n>/。
        let mut eps: Vec<(i64, String)> = Vec::new();
        let mut play_base = String::new();
        if !id_num.is_empty() {
            let p1 = get_text(&format!("{}/1/", url.trim_end_matches('/')))
                .await
                .unwrap_or_default();
            let b = blob(&p1, "playbackEndpoint");
            eps = eps_of(&b);
            play_base = sv(&b, "playBase");
            if eps.is_empty() {
                let ep_resp = get_text(&format!("{HOST}/videos/{id_num}/episodes")).await;
                if let Ok(ep_page) = ep_resp {
                    let eb = blob(&ep_page, "eps");
                    eps = eps_of(&eb);
                    if let Ok(body) = serde_json::from_str::<Value>(&eb) {
                        let total = text_of(&body, &["epTotal"]);
                        if !total.is_empty() {
                            remark = format!("共 {total} 集");
                        }
                    }
                }
            }
            if eps.is_empty() {
                let pattern = format!("/video/{}/(\\d{{1,4}})/", regex::escape(&id_num));
                for n in nums(&page, &pattern) {
                    let num: i64 = n.parse().unwrap_or(0);
                    eps.push((num, format!("第 {n} 集")));
                }
            }
            if play_base.is_empty() {
                play_base = format!("{HOST}/video/{id_num}/");
            }
            // playBase 站内是相对路径（/video/<id>/），分集地址必须拼
            // 成绝对地址，否则取流侧收到的相对地址无法请求。
            let play_base = abs_url(&play_base);
            if remark.is_empty() {
                if !eps.is_empty() {
                    remark = format!("共 {} 集", eps.len());
                } else {
                    remark = "AI短剧".to_string();
                }
            }
        }
        if eps.is_empty() {
            episodes.push(episode_json(&format!("{url}/1/"), "第 1 集", &url));
        } else {
            for (n, name) in eps {
                let ep_url = format!("{play_base}{n}/");
                episodes.push(episode_json(&ep_url, &name, &url));
            }
        }
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("黄豆短剧未返回可播放分集".into()));
    }
    let mut extra = serde_json::Map::new();
    if !remark.is_empty() {
        extra.insert("remark".to_string(), Value::String(remark));
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": pic,
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let url = format!("{HOST}/search/?keyword={encoded}");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：.m3u8 直传；否则抓播放页，blob 取 bestSrc，无则
/// POST playbackEndpoint 模板换 __EP__ 再请求，取 data.src。
/// 注意：站方 2026-11-05 改版后该接口只接受 POST（JSON 空体），
/// GET 直接回 404 页面；回包 data.src 即签名 m3u8，无则取
/// data.streams.main。
/// 取流接口只接受 POST：按站方现行 nine-play.js 的 services/playback
/// 做法，JSON 空体 POST 到 playbackEndpoint，200 才算成功。
async fn post_playback(url: &str) -> ApiResult<String> {
    let resp = client()?
        .post(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", format!("{HOST}/"))
        .header("Content-Type", "application/json")
        .json(&json!({}))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄豆短剧取流 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 取流回包取地址：data.src → data.streams.main → data.srcHevc →
/// 正则兜底；回包是 {"data": {...}, "status": 1} 的包壳。
fn playback_src(resp: &str) -> String {
    if let Ok(body) = serde_json::from_str::<Value>(resp) {
        let data = get(&body, "data").cloned().unwrap_or(Value::Null);
        let s = text_of(&data, &["src"]);
        if !s.is_empty() {
            return clean(&s);
        }
        if let Some(streams) = get(&data, "streams") {
            let s = text_of(streams, &["main"]);
            if !s.is_empty() {
                return clean(&s);
            }
        }
        let s = text_of(&data, &["srcHevc"]);
        if !s.is_empty() {
            return clean(&s);
        }
    }
    clean(&sv_raw(resp, "src"))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    if video_id.contains("/novel/") {
        return Err(ApiError::Internal(
            "黄豆短剧小说章节需阅读核心打开，影视区无法播放".into(),
        ));
    }
    let video_id = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        abs_url(video_id)
    };
    let page = get_text(&video_id).await?;
    let b = blob(&page, "playbackEndpoint");
    let mut src = best_src(&b);
    if src.is_empty() {
        src = sv(&b, "videoSrc");
        src = clean(&src);
    }
    if src.is_empty() {
        let ep = Regex::new("/video/\\d+/(\\d{1,4})/")
            .ok()
            .and_then(|re| re.captures(&video_id))
            .map(|cap| cap[1].to_string())
            .unwrap_or_else(|| "1".to_string());
        let template = sv_raw(&page, "playbackEndpoint");
        if !template.is_empty() {
            let api = format!("{}{}", HOST, template.replace("__EP__", &ep));
            if let Ok(resp) = post_playback(&api).await {
                src = playback_src(&resp);
            }
        }
    }
    if src.is_empty() {
        return Err(ApiError::Internal("黄豆短剧未取到播放地址".into()));
    }
    Ok(json!({
        "url": src,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_finds_parent_object() {
        let page = "{\"eps\":[{\"n\":1,\"fact\":\"第 1 集\"}],\"id\":\"27522\",\"playBase\":\"/video/27522/\",\"playbackEndpoint\":\"/videos/27522/episodes/__EP__/playback\"}";
        let b = blob(page, "playbackEndpoint");
        assert!(!b.is_empty());
        assert_eq!(sv(&b, "playBase"), "/video/27522/");
        let eps = eps_of(&b);
        assert_eq!(eps.len(), 1);
        assert_eq!(eps[0], (1, "第 1 集".to_string()));
    }

    #[test]
    fn blob_skips_nested_item() {
        let page =
            "{\"eps\":[{\"chunk\":0,\"fact\":\"第 1 集\"}],\"playbackEndpoint\":\"/x/__EP__/y\"}";
        let b = blob(page, "playbackEndpoint");
        assert!(b.contains("playbackEndpoint"));
    }

    #[test]
    fn best_src_prefers_current() {
        let b = "{\"current\":{\"src\":\"https://cdn.example.com/1.m3u8\"},\"videoSrc\":\"https://cdn.example.com/2.m3u8\"}";
        assert_eq!(best_src(b), "https://cdn.example.com/1.m3u8");
        let b2 = "{\"videoSrc\":\"//cdn.example.com/2.m3u8\"}";
        assert_eq!(best_src(b2), "https://cdn.example.com/2.m3u8");
    }

    #[test]
    fn nums_sorted_unique() {
        let page = "/video/27522/2/ x /video/27522/10/ y /video/27522/2/";
        assert_eq!(
            nums(page, "/video/27522/(\\d{1,4})/"),
            vec!["2".to_string(), "10".to_string()]
        );
    }

    #[test]
    fn playback_src_prefers_data_src() {
        let resp = "{\"data\":{\"mode\":1,\"manifest_method\":\"GET\",\"cdn\":{\"m3u8Enabled\":true},\"streams\":{\"main\":\"https://cdn.example.com/main.m3u8\",\"hevc\":\"\"},\"src\":\"https://cdn.example.com/1.m3u8\",\"srcHevc\":\"\"},\"status\":1}";
        assert_eq!(playback_src(resp), "https://cdn.example.com/1.m3u8");
    }

    #[test]
    fn playback_src_falls_back_to_streams_main() {
        let resp = "{\"data\":{\"streams\":{\"main\":\"https://cdn.example.com/main.m3u8\"},\"src\":\"\",\"srcHevc\":\"\"},\"status\":1}";
        assert_eq!(playback_src(resp), "https://cdn.example.com/main.m3u8");
    }

    #[test]
    fn tidy_strips() {
        assert_eq!(tidy("《妈妈的秘密》"), "妈妈的秘密");
        assert_eq!(tidy("  淫蛇传  "), "淫蛇传");
    }
}
