//! AirAV：`https://airav.io`。
//!
//! jar 内 ZakaAiravAmns 的移植。分类：n| 最新發行、s| 热门（今日/
//! 本周/本月）、t| 标签、f| 厂商、a| 女優一覽。列表走 /list、/tag、
//! /actors；女优详情（/actor?id=）取前 3 页作品做分集。详情取
//! JSON-LD 的 contentUrl 直给 m3u8（parse=0 透传，带 UA + Referer）。
//! 注意：jar 的 page() 还有盾/中继兜底（ext relay py.fzcrym.link），
//! 其具体路径在 dex 里找不全；直连本机已验通，核心只用直连。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://airav.io";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类（jar 原文 id，中文名）。
const CATS: &[(&str, &str)] = &[
    ("n|2", "最新發行"),
    ("s|3", "今日熱門"),
    ("s|4", "本周熱門"),
    ("s|5", "本月熱門"),
    ("t|1", "巨乳"),
    ("t|9", "人妻"),
    ("t|12", "熟女"),
    ("t|4", "姐姐系"),
    ("t|11", "角色扮演"),
    ("t|10", "泳裝"),
    ("t|3", "女同志"),
    ("t|7", "潤滑液"),
    ("t|8", "AV女優片"),
    ("t|2", "紀錄片"),
    ("t|6", "HD高畫質"),
    ("t|5", "720p"),
    ("t|81", "VR"),
    ("f|1", "U＆K"),
    ("f|2", "RUBY"),
    ("f|3", "加勒比"),
    ("f|4", "一本道"),
    ("f|5", "HEYZO"),
    ("f|6", "PACOPACO MAMA"),
    ("f|7", "10musume"),
    ("f|8", "SOD"),
    ("f|9", "黒船"),
    ("f|10", "溜池五郎"),
    ("f|11", "Porn Pros"),
    ("f|12", "Spizoo"),
    ("a|", "女優一覽"),
];

/// 带头取页（jar 的 ZakaHttp.get 同款头）。
async fn fetch_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{HOST}/"))
        .header("Upgrade-Insecure-Requests", "1")
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("AirAV 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("AirAV 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!("AirAV 请求失败：HTTP {status}")));
    }
    Ok(text)
}

fn unesc(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// 相对地址补成绝对地址（jar 的 abs）。
fn abs_url(u: &str) -> String {
    let u = unesc(u.trim());
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u;
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{u}")
}

/// jar 的 clean：去标签、去 \u{a0}、去首尾空白。
fn clean(s: &str) -> String {
    let tag = Regex::new(r"<[^>]+>").unwrap();
    tag.replace_all(s, "")
        .replace('\u{a0}', " ")
        .trim()
        .to_string()
}

/// jar 的 dur：把 PT10M0S 这类时长写成“10 分 0 秒”。
fn dur_str(pt: &str) -> String {
    let re = Regex::new(r"([0-9]+)([HMS])").unwrap();
    let mut out = String::new();
    for cap in re.captures_iter(pt) {
        let n: i64 = cap[1].parse().unwrap_or(0);
        let unit = match &cap[2] {
            "H" => " 小时 ",
            "M" => " 分 ",
            _ => " 秒",
        };
        out.push_str(&format!("{n}{unit}"));
    }
    out.trim().to_string()
}

/// jar 的 catUrl：分类 id 拼列表地址。
fn cat_url(tid: &str, page: i64) -> String {
    let (kind, value) = match tid.split_once('|') {
        Some((k, v)) => (k, v),
        None => ("n", "2"),
    };
    match kind {
        "t" => format!("{HOST}/tag?id={value}&idx={page}"),
        "f" => format!("{HOST}/tag?fid={value}&idx={page}"),
        "a" => format!("{HOST}/actors?idx={page}"),
        _ => format!("{HOST}/list?idx={page}&sort={value}"),
    }
}

/// 列表解析：`<div class="col oneVideo">` 块；标题取 h5，封面取
/// img src（jar 另按 cover id 重拼 /storage/cover/big/{id}.jpg，
/// 与页内 img src 一致），备注取 fa-eye 后浏览数。
/// Rust 的 regex 不支持前瞻，块按标记起止手工切分。
fn parse_list(html: &str, limit: usize) -> Vec<Value> {
    let marker = "<div class=\"col oneVideo\">";
    let mut starts: Vec<usize> = Vec::new();
    let mut pos = 0;
    while let Some(i) = html[pos..].find(marker) {
        starts.push(pos + i + marker.len());
        pos += i + marker.len();
    }
    let link_re = Regex::new(r#"<a\s+href="(/video\?hid=[^"]+)""#).unwrap();
    let title_re = Regex::new(r"<h5[^>]*>(.*?)</h5>").unwrap();
    let img_re = Regex::new(r#"<img[^>]+src="([^"]+)""#).unwrap();
    let views_re = Regex::new(r#"fa-eye"></i>\s*([0-9]+)"#).unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for (k, &bstart) in starts.iter().enumerate() {
        let bend = starts
            .get(k + 1)
            .map(|&n| n - marker.len())
            .unwrap_or(html.len());
        let mut block = &html[bstart..bend];
        if let Some(i) = block.find("</body>") {
            block = &block[..i];
        }
        let Some(lk) = link_re.captures(block) else {
            continue;
        };
        let hid = lk.get(1).unwrap().as_str();
        if !seen.insert(hid.to_string()) {
            continue;
        }
        let title = title_re
            .captures(block)
            .map(|c| clean(c.get(1).unwrap().as_str()))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| "AirAV 影片".to_string());
        let pic = img_re
            .captures(block)
            .map(|c| abs_url(c.get(1).unwrap().as_str()))
            .unwrap_or_default();
        let remark = views_re
            .captures(block)
            .map(|c| format!("▶ {}", c.get(1).unwrap().as_str()))
            .unwrap_or_else(|| "AirAV".to_string());
        out.push(item_json(&format!("{HOST}{hid}"), &title, &pic, &remark));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// 女优索引解析：每位女优一块，id 取 /actor?id=，封面按 jar 原文
/// 拼 /storage//actor_photo/{id}.jpg。
fn parse_idols(html: &str, limit: usize) -> Vec<Value> {
    let re = Regex::new(
r#"<a\s+href="/actor\?id=([0-9]+)">\s*<div class="idol-img[^"]*"[^>]*>\s*<img[^>]*>\s*</div>\s*<div class="idol-info[^"]*">\s*<h5[^>]*>([^<]*)</h5>"#,
)
.unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for cap in re.captures_iter(html) {
        let id = cap.get(1).unwrap().as_str();
        if !seen.insert(id.to_string()) {
            continue;
        }
        let name = clean(cap.get(2).unwrap().as_str());
        let pic = format!("{HOST}/storage//actor_photo/{id}.jpg");
        out.push(item_json(
            &format!("{HOST}/actor?id={id}"),
            &format!("女優 #{name}"),
            &pic,
            "女優",
        ));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// 页内 `max="N"`（总页数），没有则回 1。
fn max_page(html: &str) -> i64 {
    let re = Regex::new(r#"max="([0-9]+)""#).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1).unwrap().as_str().parse().ok())
        .unwrap_or(1)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let url = cat_url(category_id, page);
    let html = fetch_text(&url).await?;
    let total = max_page(&html);
    let (items, limit) = if category_id.starts_with("a|") {
        (parse_idols(&html, 24), 24)
    } else {
        (parse_list(&html, 60), 60)
    };
    Ok(json!({
    "page": page,
    "pagecount": total.max(1),
    "limit": limit,
    "total": total,
    "has_more": page < total,
    // Dart 侧只认 "items"，原先只返 "list" 时应用层判“核心未返回
    // 目录”直接跳过本站；"list" 留着兼容旧调用（照 xx01 修法）。
    "items": items.clone(),
    "list": items,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    if video_id.contains("/actor") {
        return actor_detail(video_id).await;
    }
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{HOST}{video_id}")
    };
    let html = fetch_text(&url).await?;
    let h1_re = Regex::new(r"<h1[^>]*>(.*?)</h1>").unwrap();
    let title_re = Regex::new(r"<title>(.*?)</title>").unwrap();
    let title = h1_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .filter(|t| !t.is_empty())
        .or_else(|| {
            title_re
                .captures(&html)
                .map(|c| clean(c.get(1).unwrap().as_str()))
                .filter(|t| !t.is_empty())
        })
        .unwrap_or_else(|| "AirAV 影片".to_string());
    let content_re = Regex::new(r#""contentUrl"\s*:\s*"([^"]+)""#).unwrap();
    let thumb_re = Regex::new(r#""thumbnailUrl"\s*:\s*\[\s*"([^"]+)""#).unwrap();
    let dur_re = Regex::new(r#""duration"\s*:\s*"PT([0-9HMS]+)""#).unwrap();
    let code_re = Regex::new(r"番號：\s*<span[^>]*>([^<]+)</span>").unwrap();
    let tags_re = Regex::new(r#"<li class="my-2">標籤：(.{0,1200}?)</li>"#).unwrap();
    let desc_re = Regex::new(r#""description"\s*:\s*"([^"]{10,600})""#).unwrap();
    let stream = content_re
        .captures(&html)
        .map(|c| unesc(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let cover = thumb_re
        .captures(&html)
        .map(|c| abs_url(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let code = code_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let date = Regex::new(r#"fa-clock[^>]*></i>\s*([0-9\-:]{10,20})"#)
        .unwrap()
        .captures(&html)
        .map(|c| c.get(1).unwrap().as_str().trim().to_string())
        .unwrap_or_default();
    let length = dur_re
        .captures(&html)
        .map(|c| dur_str(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let tags = tags_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let content = desc_re
        .captures(&html)
        .map(|c| unesc(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let mut synopsis = String::from("\n");
    if !code.is_empty() {
        synopsis.push_str(&format!("番號：{code}\n"));
    }
    if !date.is_empty() {
        synopsis.push_str(&format!("日期：{date}\n"));
    }
    if !length.is_empty() {
        synopsis.push_str(&format!("片長：{length}\n"));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("標籤：{tags}\n"));
    }
    synopsis.push_str(&content);
    let mut episodes = Vec::new();
    if !stream.is_empty() {
        episodes.push(episode_json(&format!("m|{stream}"), "AirAV·HLS", &url));
    }
    Ok(json!({
    "id": url,
    "title": title,
    "cover": cover,
    "synopsis": synopsis.trim(),
    "episodes": episodes,
    }))
}

/// 女优详情：取前 3 页作品做分集（jar 的 actorDetail 同款）。
async fn actor_detail(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{HOST}{video_id}")
    };
    let html = fetch_text(&url).await?;
    let h1_re = Regex::new(r"<h1[^>]*>(.*?)</h1>").unwrap();
    let name = h1_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .map(|t| {
            let re = Regex::new(r"\s*[-|｜].*$").unwrap();
            re.replace(&t, "").trim().to_string()
        })
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "AirAV 女優".to_string());
    let img_re =
        Regex::new(r#"<div class="idol-img[^"]*"[^>]*>\s*<img[^>]+src="([^"]+)""#).unwrap();
    let pic = img_re
        .captures(&html)
        .map(|c| abs_url(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let mut episodes = Vec::new();
    let mut seen = HashSet::new();
    let total = max_page(&html).min(3).max(1);
    for p in 1..=total {
        let page_html = if p == 1 {
            html.clone()
        } else {
            let sep = if url.contains('?') { "&idx=" } else { "?idx=" };
            match fetch_text(&format!("{url}{sep}{p}")).await {
                Ok(t) => t,
                Err(_) => break,
            }
        };
        for item in parse_list(&page_html, 100) {
            let id = item["vod_id"].as_str().unwrap_or("").to_string();
            if !seen.insert(id.clone()) {
                continue;
            }
            let title = item["vod_name"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&id, &title, &url));
        }
    }
    let synopsis = format!("女優：{name}\n作品数：{}\n來源：AirAV", episodes.len());
    Ok(json!({
    "id": url,
    "title": format!("女優 {name}"),
    "cover": pic,
    "synopsis": synopsis,
    "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let url = format!("{HOST}/search_result?kw={enc}");
    let html = fetch_text(&url).await?;
    let items = parse_list(&html, 40);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(stream) = video_id.strip_prefix("m|") {
        if stream.starts_with("http") {
            return Ok(json!({"url": stream}));
        }
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    if video_id.contains("/video?hid=") {
        let d = detail(video_id).await?;
        if let Some(eps) = d.get("episodes").and_then(|e| e.as_array()) {
            if let Some(first) = eps.first() {
                let id = first["video_id"].as_str().unwrap_or("");
                if let Some(stream) = id.strip_prefix("m|") {
                    return Ok(json!({"url": stream}));
                }
            }
        }
        return Err(ApiError::Internal("AirAV 该视频没有播放地址".into()));
    }
    Err(ApiError::Internal("AirAV 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cat_url_builds_list_and_tag() {
        assert_eq!(cat_url("n|2", 1), "https://airav.io/list?idx=1&sort=2");
        assert_eq!(cat_url("t|1", 3), "https://airav.io/tag?id=1&idx=3");
        assert_eq!(cat_url("f|3", 2), "https://airav.io/tag?fid=3&idx=2");
        assert_eq!(cat_url("a|", 1), "https://airav.io/actors?idx=1");
    }

    #[test]
    fn dur_str_formats_iso8601() {
        assert_eq!(dur_str("10M0S"), "10 分 0 秒");
        assert_eq!(dur_str("1H2M3S"), "1 小时 2 分 3 秒");
    }

    #[test]
    fn parse_list_reads_cards() {
        let html = r#"<div class="col oneVideo"><a href="/video?hid=QC-BT-1"><h5>DLDSS-578 影片</h5><img src="https://airav.io/storage/cover/big/QC-BT-1.jpg"></a><i class="fa-eye"></i> 6162</div>"#;
        let items = parse_list(html, 24);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "DLDSS-578 影片");
        assert_eq!(items[0]["remark"], "▶ 6162");
    }

    #[tokio::test]
    #[ignore]
    async fn live_catalog_returns_items() {
        let r = catalog("n|2", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        let list = r["list"].as_array().unwrap();
        eprintln!("LIVE airav n|2 items={} list={}", items.len(), list.len());
        assert!(!items.is_empty(), "airav catalog empty");
        assert_eq!(items.len(), list.len());
    }
}
