//! 熟女群：核心里的影视区站点。
//!
//! MacCMS 站（/a/index.php/vod/），模板 snq，与本站同批的 🔞黄瓜资源
//!（huangguazy）同属一个资源站体系但不是同站：首页视频 id 与黄瓜
//! 资源零重叠，品牌、模板、分类名（244 55资源、329 库库资源）
//! 均不同；封面走 hg.jqydt1.com 直链 JPEG（img 上 data-aes="true"
//! 只是标记，实测首字节 FF D8 JFIF，可直出）。分类与站导航 1:1
//!（7 项）：黄瓜资源、熟女资源、55资源、不卡资源、兔儿资源、
//! 森林资源、库库资源，每页 12 条；详情页
//! /a/index.php/vod/detail/id/<n>.html，取流为播放页
//! /a/index.php/vod/play/id/<n>/sid/1/nid/<k>.html 里 player_aaaa
//! 的 m3u8（主清单 200、AES-128、首分片 200，无需特殊头）；搜索
//! /a/index.php/vod/search/wd/<词>.html。站有多个镜像域名，
//! wap.snq2.cc 为主、wap.snq3.cc 与 5g.snq3.cc 为备，逐个试。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASES: &[&str] = &[
    "https://wap.snq2.cc",
    "https://wap.snq3.cc",
    "https://5g.snq3.cc",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("386", "黄瓜资源"),
    ("358", "熟女资源"),
    ("244", "55资源"),
    ("119", "不卡资源"),
    ("286", "兔儿资源"),
    ("370", "森林资源"),
    ("329", "库库资源"),
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
        return Err(ApiError::Internal(format!("熟女群请求 HTTP {status}")));
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

fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 卡片解析：`vodlist-item` + detail id + data-original（封面）+
/// listitem-info（标题文本）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="qx" href="/a/index\.php/vod/detail/id/(\d+)\.html".*?<img[^>]+data-original="([^"]+)"[^>]*>.*?<div class="listitem-info">\s*(.*?)\s*</div>"#,
    ) {
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
        let title = collapse_ws(&unescape(cap[3].trim()));
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[2]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页分组锚点带 class="now"（子标签无此 class），
/// 名取锚点文本。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"<a href="/a/index\.php/vod/type/id/(\d+)\.html" class="now"[^>]*>([^<]+)</a>"#,
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

/// 详情封面：详情页首个绝对地址 img 的 src（站 logo 是相对地址）。
fn parse_detail_cover(html: &str) -> String {
    match Regex::new(r#"<img src="(https?://[^"]+)""#) {
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
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| collapse_ws(&unescape(m[1].trim())))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = title.find('<') {
        title.truncate(pos);
        title = title.trim().to_string();
    }
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
            if !seen.insert(href.clone()) {
                continue;
            }
            let name = if name.is_empty() || name == "立即播放" {
                "第1集".to_string()
            } else {
                name
            };
            episodes.push(episode_json(&fix_url(&href), &name, series_id));
        }
    }
    if title.is_empty() || episodes.is_empty() {
        return Err(ApiError::Internal("熟女群未返回可播放剧集".into()));
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
        return Err(ApiError::Internal("熟女群该集没有播放地址".into()));
    }
    let path = match url.find("/a/index.php") {
        Some(pos) => url[pos..].to_string(),
        None => url.clone(),
    };
    let html = get_text(&path).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("熟女群未返回可播放地址".into()));
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
            fix_url("/a/index.php/vod/detail/id/850467.html"),
            "https://wap.snq2.cc/a/index.php/vod/detail/id/850467.html"
        );
        assert_eq!(
            fix_url("https://c10.hs100.top/20261104/5bafdac73dabff57/index.m3u8"),
            "https://c10.hs100.top/20261104/5bafdac73dabff57/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="vodlist-item"><a class="qx" href="/a/index.php/vod/detail/id/850467.html" target="_self"><div class="vodlistitem-img"><div class="new">最新</div><img class="content-img lazy" data-original="https://hg.jqydt1.com/upload/vod/20261105-1/149260a5fe016d030f87f26cd8e5bd7e.jpg" data-prefix="" src="/a/template/snq/static/images/load.jpg" data-aes="true"><div class="time"></div></div><div class="listitem-info"> 草头黄 约操极品长腿骚妹 白丝淫穴骑乘猛夹肉棒骚语连连 </div></a></div><div class="vodlist-item"><a class="qx" href="/a/index.php/vod/detail/id/850467.html"><div class="listitem-info">重复卡片</div></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "850467");
        assert_eq!(
            items[0]["title"],
            "草头黄 约操极品长腿骚妹 白丝淫穴骑乘猛夹肉棒骚语连连"
        );
        assert_eq!(
            items[0]["cover"],
            "https://hg.jqydt1.com/upload/vod/20261105-1/149260a5fe016d030f87f26cd8e5bd7e.jpg"
        );
    }

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<a href="/a/index.php/vod/type/id/386.html" class="now" isok="true">黄瓜资源</a><a href="/a/index.php/vod/type/id/387.html">国产自拍</a><a href="/a/index.php/vod/type/id/358.html" class="now" isok="true">熟女资源</a><a href="/a/index.php/vod/type/id/386.html" class="now" isok="true">黄瓜资源</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "386");
        assert_eq!(list[0]["name"], "黄瓜资源");
        assert_eq!(list[1]["name"], "熟女资源");
    }

    #[test]
    fn fallback_has_7_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 7);
        assert_eq!(list[0]["id"], "386");
        assert_eq!(list[2]["name"], "55资源");
        assert_eq!(list[6]["name"], "库库资源");
    }

    #[test]
    fn parse_detail_cover_real_markup() {
        let html = r#"<img src="/a/template/snq/logo.png" alt=""><img src="https://hg.jqydt1.com/upload/vod/20261105-1/149260a5fe016d030f87f26cd8e5bd7e.jpg" alt="" />"#;
        assert_eq!(
            parse_detail_cover(html),
            "https://hg.jqydt1.com/upload/vod/20261105-1/149260a5fe016d030f87f26cd8e5bd7e.jpg"
        );
        assert_eq!(parse_detail_cover("<div>no cover</div>"), "");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/a\/index.php\/vod\/play\/id\/850467\/sid\/1\/nid\/1.html","vod_data":{"vod_name":"草头黄"},"url":"https:\/\/c10.hs100.top\/20261104\/5bafdac73dabff57\/index.m3u8","url_next":"","from":"jpm3u8","server":"no","note":"","id":"850467","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://c10.hs100.top/20261104/5bafdac73dabff57/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn search_url_encoding() {
        let encoded: String = url::form_urlencoded::byte_serialize("草头黄".as_bytes()).collect();
        assert_eq!(encoded, "%E8%8D%89%E5%A4%B4%E9%BB%84");
    }
}
