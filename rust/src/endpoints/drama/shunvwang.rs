//! 熟女网：核心里的影视区站点。
//!
//! MacCMS 站（/a/index.php/vod/），与本站同批的 🔞黄瓜资源（huangguazy）
//! 同属一个资源站体系但不是同站：首页 44 条与黄瓜资源首页 19 条
//! 零重叠，模板（snw）、品牌、分类名（358 熟女资源、286 兔儿资源）
//! 与内容组织均不同。分类与站导航 1:1（7 项）：163资源、黄瓜资源、
//! 熟女资源、裤子资源、不卡资源、兔儿资源、森林资源，每页 12 条；
//! 详情页 /a/index.php/vod/detail/id/<n>.html，取流为播放页
//! /a/index.php/vod/play/id/<n>/sid/1/nid/<k>.html 里 player_aaaa
//! 的 m3u8（主清单 200、变体清单 200 METHOD=NONE、首分片 200，
//! 无需特殊头）；搜索 /a/index.php/vod/search/wd/<词>.html。
//! 站有三个镜像域名，tv.shunvwang7.cc 为主、ap.shunvwang8.cc 与
//! web.shunvwang9.cc 为备，逐个试。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASES: &[&str] = &[
    "https://tv.shunvwang7.cc",
    "https://ap.shunvwang8.cc",
    "https://web.shunvwang9.cc",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("244", "163资源"),
    ("386", "黄瓜资源"),
    ("358", "熟女资源"),
    ("329", "裤子资源"),
    ("119", "不卡资源"),
    ("286", "兔儿资源"),
    ("370", "森林资源"),
];

/// 带镜像回退的 GET：主站不通时试备站，各站内重试 2 次。
async fn get_text(path: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for base in BASES {
        let url = format!("{base}{path}");
        for _ in 0..2 {
            match fetch_once(&url).await {
                Ok(text) => return Ok(text),
                Err(e) => {
                    last_err = e.to_string();
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("熟女网请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 地址归一：站内相对路径补主站基址，协议相对补 https。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{}{u}", BASES[0]);
    }
    u.to_string()
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：`vod-item` + detail id + vod-name（标题）+ data-original
///（封面）+ vod-remarks（清晰度，常为空）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="vod-item" href="/a/index\.php/vod/detail/id/(\d+)\.html".*?<div class="vod-name">(.*?)</div>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let cover_re = match Regex::new(r#"data-original="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let remark_re = match Regex::new(r#"<span class="vod-remarks">([^<]*)</span>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[2].trim());
        if title.is_empty() {
            continue;
        }
        let seg = &cap[0];
        let cover = cover_re
            .captures(seg)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default();
        let remark = remark_re
            .captures(seg)
            .map(|m| m[1].trim().to_string())
            .unwrap_or_default();
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 分类解析：首个 nav-row（nav-subs 宽 100% 的那行）里的 type 锚点，
/// 后面各行的分组子标签不取。
fn parse_categories(html: &str) -> Vec<Value> {
    let row_re =
        match Regex::new(r#"(?s)<div class="nav-subs" style="width: 100%[^>]*>(.*?)</div>"#) {
            Ok(re) => re,
            Err(_) => return Vec::new(),
        };
    let row = match row_re.captures(html) {
        Some(cap) => cap[1].to_string(),
        None => return Vec::new(),
    };
    let re = match Regex::new(r#"<a href="/a/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>"#)
    {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(&row) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || name == "首页" || !seen.insert(id.clone()) {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text("/a/").await {
        Ok(html) => {
            let list = parse_categories(&html);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

/// 分页总数：JS 分页器 num-page-<n> 里最大的 n。
fn page_total(html: &str) -> Option<i64> {
    let re = Regex::new(r#"id="num-page-(\d+)""#).ok()?;
    let mut max: Option<i64> = None;
    for cap in re.captures_iter(html) {
        if let Ok(n) = cap[1].parse::<i64>() {
            max = Some(max.map_or(n, |m: i64| m.max(n)));
        }
    }
    max
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = if page <= 1 {
        format!("/a/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("/a/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&path).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html) {
        page < total
    } else {
        false
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 player_aaaa JSON 的 url 字段（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    }
}

/// 详情封面：detail-cover-wrapper 里海报 img 的 src。
fn parse_detail_cover(html: &str) -> String {
    match Regex::new(r#"(?s)detail-cover-wrapper".*?<img[^>]+src="([^"]+)""#) {
        Ok(re) => re
            .captures(html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        Err(_) => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let html = get_text(&format!("/a/index.php/vod/detail/id/{id}.html")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover = parse_detail_cover(&html);
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let ep_re = Regex::new(
        r#"<a[^>]*href="(/a/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"[^>]*>([^<]*)</a>"#,
    )
    .ok();
    let mut episodes = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Some(re) = &ep_re {
        for cap in re.captures_iter(&html) {
            let href = cap[1].trim().to_string();
            let name = cap[2].trim().to_string();
            if name.is_empty() || name.contains("立即") || !seen.insert(href.clone()) {
                continue;
            }
            episodes.push(episode_json(&fix_url(&href), &name, series_id));
        }
    }
    if title.is_empty() || episodes.is_empty() {
        return Err(ApiError::Internal("熟女网未返回可播放剧集".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        fix_url(video_id)
    };
    if !url.contains("/vod/play/") {
        if url.starts_with("http") && url.ends_with(".m3u8") {
            return Ok(json!({"url": url}));
        }
        return Err(ApiError::Internal("熟女网该集没有播放地址".into()));
    }
    let path = match url.find("/a/index.php") {
        Some(pos) => url[pos..].to_string(),
        None => url.clone(),
    };
    let html = get_text(&path).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("熟女网未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    let html = get_text(&format!("/a/index.php/vod/search/wd/{encoded}.html")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/a/index.php/vod/detail/id/859457.html"),
            "https://tv.shunvwang7.cc/a/index.php/vod/detail/id/859457.html"
        );
        assert_eq!(
            fix_url("https://iuewgnbvk.com/20261103/rk851JjB/index.m3u8"),
            "https://iuewgnbvk.com/20261103/rk851JjB/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="vod-item" href="/a/index.php/vod/detail/id/859457.html"><div class="vod-thumb"><img class="lazyload" src="/a/template/snw/static/images/load.png" data-original="https://aoksazysz.com/20261103/rk851JjB/1.jpg" alt="HEZ-886 美熟女口淫全集"><span class="vod-remarks">高清</span></div><div class="vod-meta"><div class="vod-name">HEZ-886 美熟女口淫全集</div></div></a><a class="vod-item" href="/a/index.php/vod/detail/id/859457.html"><div class="vod-name">HEZ-886 美熟女口淫全集</div></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "859457");
        assert_eq!(items[0]["title"], "HEZ-886 美熟女口淫全集");
        assert_eq!(
            items[0]["cover"],
            "https://aoksazysz.com/20261103/rk851JjB/1.jpg"
        );
        assert_eq!(items[0]["remark"], "高清");
    }

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<nav class="nav-section"><div class="nav-row"><div class="nav-subs" style="width: 100% !important;"><a href="/a/" class="sub-item active">首页</a><a href="/a/index.php/vod/type/id/244.html" class="sub-item ">163资源</a><a href="/a/index.php/vod/type/id/386.html" class="sub-item ">黄瓜资源</a><a href="/a/index.php/vod/type/id/358.html" class="sub-item ">熟女资源</a></div></div><div class="nav-row"><a href="/a/index.php/vod/type/id/370.html" class="nav-primary">森林资源</a><div class="nav-subs"><a href="/a/index.php/vod/type/id/371.html" class="sub-item">精品推荐</a></div></div></nav>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "244");
        assert_eq!(list[0]["name"], "163资源");
        assert_eq!(list[2]["name"], "熟女资源");
    }

    #[test]
    fn fallback_has_7_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 7);
        assert_eq!(list[0]["id"], "244");
        assert_eq!(list[2]["name"], "熟女资源");
        assert_eq!(list[6]["name"], "森林资源");
    }

    #[test]
    fn page_total_reads_max_pager() {
        let html = r##"<li class="yt-page-item" id="num-page-1"><a href="#">1</a></li><li class="yt-page-item" id="num-page-2"><a href="#">2</a></li><li class="yt-page-item" id="num-page-4"><a href="#">4</a></li>"##;
        assert_eq!(page_total(html), Some(4));
        assert_eq!(page_total("<div>no pager</div>"), None);
    }

    #[test]
    fn parse_detail_cover_real_markup() {
        let html = r#"<a class="vod-item detail-cover-wrapper" href="/a/index.php/vod/play/id/859457/sid/1/nid/1.html"><div class="vod-thumb"><img src="https://aoksazysz.com/20261103/rk851JjB/1.jpg" alt="HEZ-886"></div></a>"#;
        assert_eq!(
            parse_detail_cover(html),
            "https://aoksazysz.com/20261103/rk851JjB/1.jpg"
        );
        assert_eq!(parse_detail_cover("<div>no cover</div>"), "");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/a\/index.php\/vod\/play\/id\/859457\/sid\/1\/nid\/1.html","vod_data":{"vod_name":"HEZ-886"},"url":"https:\/\/iuewgnbvk.com\/20261103\/rk851JjB\/index.m3u8","url_next":"","from":"jpm3u8","server":"no","note":"","id":"859457","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://iuewgnbvk.com/20261103/rk851JjB/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn search_url_encoding() {
        let encoded: String = url::form_urlencoded::byte_serialize("熟女".as_bytes()).collect();
        assert_eq!(encoded, "%E7%86%9F%E5%A5%B3");
    }
}
