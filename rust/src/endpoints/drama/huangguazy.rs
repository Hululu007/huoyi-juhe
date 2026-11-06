//! 黄瓜资源：核心里的影视区站点。
//!
//! MacCMS 站（/a/index.php/vod/），与已有站 🔞黄瓜视频（cucumber）不是
//! 同站：后者走 App API（api66.capcom.work 等签名接口），本站是 Web 站
//!（huangguazy7/8.cc，模板 hgzy，图床 hg.jqydt1.com），域名、后端、
//! 内容组织均不同。分类与站导航 1:1（7 项）：黄瓜资源、番号资源、
//! 不卡资源、玉兔资源、裤子资源、森林资源、163资源，每页 12 条；
//! 详情页 /a/index.php/vod/detail/id/<n>.html，取流为播放页
//! /a/index.php/vod/play/id/<n>/sid/1/nid/<k>.html 里 player_aaaa
//! 的 m3u8（主清单 200、AES-128、首分片 200，无需特殊头）；搜索
//! /a/index.php/vod/search/wd/<词>.html。站有两个镜像域名，
//! wap.huangguazy7.cc 为主、gua.huangguazy8.cc 为备，逐个试。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASES: &[&str] = &["https://wap.huangguazy7.cc", "https://gua.huangguazy8.cc"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("386", "黄瓜资源"),
    ("358", "番号资源"),
    ("119", "不卡资源"),
    ("286", "玉兔资源"),
    ("329", "裤子资源"),
    ("370", "森林资源"),
    ("244", "163资源"),
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
        return Err(ApiError::Internal(format!("黄瓜资源请求 HTTP {status}")));
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

/// 卡片解析：`vod-card-item` + detail id + vod-card-name（标题）+
/// data-original（封面）+ vod-card-remarks（更新集数）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="vod-card-item" href="/a/index\.php/vod/detail/id/(\d+)\.html".*?<div class="vod-card-name">(.*?)</div>.*?<span class="vod-card-remarks">([^<]*)</span>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let cover_re = match Regex::new(r#"data-original="([^"]+)""#) {
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
        let remark = cap[3].trim().to_string();
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 分类解析：首页 `cat-icon-item` 锚点（子标签是 sub-tag-item，不取），
/// 名取锚点内 span 文本，首页（/a/）不在此列。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"(?s)<a href="/a/index\.php/vod/type/id/(\d+)\.html" class="cat-icon-item"[^>]*>.*?<span[^>]*>([^<]+)</span>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || !seen.insert(id.clone()) {
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

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = if page <= 1 {
        format!("/a/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("/a/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&path).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty()
        && html.contains(&format!(
            "/a/index.php/vod/type/id/{category_id}/page/{}.html",
            page + 1
        ));
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

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let html = get_text(&format!("/a/index.php/vod/detail/id/{id}.html")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = title.find('<') {
        title.truncate(pos);
        title = title.trim().to_string();
    }
    let cover_re = Regex::new(r#"<img class="main-img" src="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover = if cover.is_empty() {
        let data_re = Regex::new(r#"data-original="([^"]+)""#).ok();
        match &data_re {
            Some(re) => re
                .captures(&html)
                .map(|m| fix_url(&m[1]))
                .unwrap_or_default(),
            None => String::new(),
        }
    } else {
        cover
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let ep_re = Regex::new(
        r#"<a[^>]*href="(/a/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"[^>]*>([^<]+)</a>"#,
    )
    .ok();
    let mut episodes = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Some(re) = &ep_re {
        for cap in re.captures_iter(&html) {
            let href = cap[1].trim().to_string();
            let name = cap[2].trim().to_string();
            if name == "▶ 立即播放" || !seen.insert(href.clone()) {
                continue;
            }
            episodes.push(episode_json(&fix_url(&href), &name, series_id));
        }
    }
    if title.is_empty() || episodes.is_empty() {
        return Err(ApiError::Internal("黄瓜资源未返回可播放剧集".into()));
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
        return Err(ApiError::Internal("黄瓜资源该集没有播放地址".into()));
    }
    let path = match url.find("/a/index.php") {
        Some(pos) => url[pos..].to_string(),
        None => url.clone(),
    };
    let html = get_text(&path).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("黄瓜资源未返回可播放地址".into()));
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
            fix_url("/a/index.php/vod/detail/id/873576.html"),
            "https://wap.huangguazy7.cc/a/index.php/vod/detail/id/873576.html"
        );
        assert_eq!(
            fix_url("https://c10.hs100.top/20261031/19f9b7e0d61f49fb/index.m3u8"),
            "https://c10.hs100.top/20261031/19f9b7e0d61f49fb/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="vod-card-item" href="/a/index.php/vod/detail/id/873576.html" name="admonclick" target="_blank"><div class="vod-card-thumb"><img class="lazyload bg-blur-img" src="/a/template/hgzy/static/images/load.png" data-original="https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg" alt=""><img class="lazyload main-img" src="/a/template/hgzy/static/images/load.png" data-original="https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg" alt="《原味拍卖》"><span class="vod-card-remarks">更新至01集</span><span class="vod-card-date">11-05</span><div class="vod-card-mask"></div></div><div class="vod-card-meta"><div class="vod-card-name">《原味拍卖》</div></div></a><a class="vod-card-item" href="/a/index.php/vod/detail/id/873576.html"><div class="vod-card-name">《原味拍卖》</div><span class="vod-card-remarks">更新至01集</span></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "873576");
        assert_eq!(items[0]["title"], "《原味拍卖》");
        assert_eq!(
            items[0]["cover"],
            "https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg"
        );
        assert_eq!(items[0]["remark"], "更新至01集");
    }

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<a href="/a/" class="cat-icon-item"><div class="icon-square">首</div><span>首页</span></a><a href="/a/index.php/vod/type/id/386.html" class="cat-icon-item"><div class="icon-square">黄</div><span style="font-size: 12px !important;">黄瓜资源</span></a><a href="/a/index.php/vod/type/id/358.html" class="cat-icon-item"><div class="icon-square">番</div><span>番号资源</span></a><a href="/a/index.php/vod/type/id/417.html" class="sub-tag-item">日本无码</a><a href="/a/index.php/vod/type/id/386.html" class="cat-icon-item"><div class="icon-square">黄</div><span>黄瓜资源</span></a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "386");
        assert_eq!(list[0]["name"], "黄瓜资源");
        assert_eq!(list[1]["name"], "番号资源");
    }

    #[test]
    fn fallback_has_7_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 7);
        assert_eq!(list[0]["id"], "386");
        assert_eq!(list[6]["name"], "163资源");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/a\/index.php\/vod\/play\/id\/873576\/sid\/1\/nid\/1.html","vod_data":{"vod_name":"《原味拍卖》"},"url":"https:\/\/c10.hs100.top\/20261031\/19f9b7e0d61f49fb\/index.m3u8","url_next":"https:\/\/c10.hs100.top\/20261102\/be7cfd9f25bccc1f\/index.m3u8","from":"jpm3u8","server":"no","note":"","id":"873576","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://c10.hs100.top/20261031/19f9b7e0d61f49fb/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn search_url_encoding() {
        let encoded: String = url::form_urlencoded::byte_serialize("牛仔裤".as_bytes()).collect();
        assert_eq!(encoded, "%E7%89%9B%E4%BB%94%E8%A3%A4");
    }
}
