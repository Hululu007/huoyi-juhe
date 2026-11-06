//! AI短剧网：核心里的影视区站点。
//!
//! MacCMS 站（/rukou/index.php/vod/），与本站同批的 🔞黄瓜资源
//!（huangguazy）同属一个资源站体系、共享上架流，但不是同站：
//! 本站视频 id 自成体系（如《原味拍卖》本站 648472、黄瓜资源
//! 873576），分类、品牌、模板均不同，详情页只列第 1 集（同片在
//! 黄瓜资源列 3 集，各站分集数据不同，以本站为准）。分类与站
//! 导航 1:1（6 个去重后分组）：推荐、黄瓜资源、仓房资源、玉兔资源、
//! 番茄资源、155资源（站内 119 号分组有两个标签“推荐”与
//! “斯卡资源”，去重后取首个“推荐”），每页 12 条；详情页
//! /rukou/index.php/vod/detail/id/<n>.html，取流为播放页
//! /rukou/index.php/vod/play/id/<n>/sid/1/nid/<k>.html 里
//! player_aaaa 的 m3u8（主清单 200、AES-128、首分片 200，
//! 无需特殊头）；搜索 /rukou/index.php/vod/search/wd/<词>.html。
//! 站有两个镜像域名，ai.aiduanjuwang8.cc 为主、
//! wap.aiduanjuwang6.cc 为备，逐个试。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASES: &[&str] = &[
    "https://ai.aiduanjuwang8.cc",
    "https://wap.aiduanjuwang6.cc",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("119", "推荐"),
    ("370", "黄瓜资源"),
    ("329", "仓房资源"),
    ("286", "玉兔资源"),
    ("358", "番茄资源"),
    ("244", "155资源"),
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
        return Err(ApiError::Internal(format!("AI短剧网请求 HTTP {status}")));
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

/// 卡片解析：`vod` 块 + data-original（封面）+ vod-txt 锚点
///（detail id + 标题）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<div class="vod">.*?<img[^>]+data-original="([^"]+)"[^>]*>.*?<div class="vod-txt"[^>]*>\s*<a href="/rukou/index\.php/vod/detail/id/(\d+)\.html"[^>]*>([^<]+)</a>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[2].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[1]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：导航 `<dl class="first">` 的 `<dt>` 分组锚点
///（`<dd>` 是子标签，不取），id 去重取首个标签。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"<dt><a href="/rukou/index\.php/vod/type/id/(\d+)\.html"><b>([^<]+)</b></a></dt>"#,
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
    match get_text("/rukou/").await {
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
        format!("/rukou/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("/rukou/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&path).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty()
        && html.contains(&format!(
            "/rukou/index.php/vod/type/id/{category_id}/page/{}.html",
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

/// 详情封面：海报 img（带 title 属性、与片名一致）的 src；
/// 取不到时退到首个 /upload/vod/ 绝对地址图。
fn parse_detail_cover(html: &str, title: &str) -> String {
    if let Ok(re) = Regex::new(r#"<img src="([^"]+)" title="([^"]*)""#) {
        for cap in re.captures_iter(html) {
            if cap[2].trim() == title {
                return fix_url(&cap[1]);
            }
        }
    }
    match Regex::new(r#"<img[^>]+src="(https?://[^"]+/upload/vod/[^"]+)""#) {
        Ok(re) => re
            .captures(html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        Err(_) => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let html = get_text(&format!("/rukou/index.php/vod/detail/id/{id}.html")).await?;
    let title_re = Regex::new(r#"(?s)<div class="title"><h3>([^<]+)</h3></div>"#).ok();
    let title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover = parse_detail_cover(&html, &title);
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let ep_re = Regex::new(r#"/rukou/index\.php/vod/play/id/\d+/sid/1/nid/(\d+)\.html"#).ok();
    let mut episodes = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Some(re) = &ep_re {
        for cap in re.captures_iter(&html) {
            let nid = cap[1].to_string();
            if !seen.insert(nid.clone()) {
                continue;
            }
            let href = format!("/rukou/index.php/vod/play/id/{id}/sid/1/nid/{nid}.html");
            episodes.push(episode_json(
                &fix_url(&href),
                &format!("第{nid}集"),
                series_id,
            ));
        }
    }
    if episodes.is_empty() {
        let href = format!("/rukou/index.php/vod/play/id/{id}/sid/1/nid/1.html");
        episodes.push(episode_json(&fix_url(&href), "第1集", series_id));
    }
    if title.is_empty() {
        return Err(ApiError::Internal("AI短剧网未返回标题".into()));
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
        return Err(ApiError::Internal("AI短剧网该集没有播放地址".into()));
    }
    let path = match url.find("/rukou/index.php") {
        Some(pos) => url[pos..].to_string(),
        None => url.clone(),
    };
    let html = get_text(&path).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("AI短剧网未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    let html = get_text(&format!("/rukou/index.php/vod/search/wd/{encoded}.html")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/rukou/index.php/vod/detail/id/648472.html"),
            "https://ai.aiduanjuwang8.cc/rukou/index.php/vod/detail/id/648472.html"
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
        let html = r#"<div class="vod"><div class="vod-img" id="content12"><a href="/rukou/index.php/vod/detail/id/648472.html" name="admonclick" target="_blank"><img class="lazy" data-original="https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg" data-prefix="" src="/rukou/template/aiduanju/static/images/load_x1.jpg" data-aes="true"></a></div><div class="vod-txt" id="sui12"><a href="/rukou/index.php/vod/detail/id/648472.html" name="admonclick" target="_blank">《原味拍卖》</a></div></div><div class="vod"><div class="vod-txt"><a href="/rukou/index.php/vod/detail/id/648472.html">《原味拍卖》</a></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "648472");
        assert_eq!(items[0]["title"], "《原味拍卖》");
        assert_eq!(
            items[0]["cover"],
            "https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg"
        );
    }

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<dl class="first"><dt><a href="/rukou/index.php/vod/type/id/119.html"><b>推荐</b></a></dt><dd><a href="/rukou/index.php/vod/type/id/372.html">AI短剧</a></dd></dl><dl class="first"><dt><a href="/rukou/index.php/vod/type/id/370.html"><b>黄瓜资源</b></a></dt><dd><a href="/rukou/index.php/vod/type/id/372.html">AI短剧</a></dd></dl><dl class="first"><dt><a href="/rukou/index.php/vod/type/id/119.html"><b>斯卡资源</b></a></dt></dl>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "119");
        assert_eq!(list[0]["name"], "推荐");
        assert_eq!(list[1]["name"], "黄瓜资源");
    }

    #[test]
    fn fallback_has_6_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 6);
        assert_eq!(list[0]["id"], "119");
        assert_eq!(list[0]["name"], "推荐");
        assert_eq!(list[5]["name"], "155资源");
    }

    #[test]
    fn parse_detail_cover_real_markup() {
        let html = r#"<div style="text-align: center;"><a target="_self" href="/rukou/index.php/vod/play/id/648472/sid/1/nid/1.html"><img src="https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg" title="《原味拍卖》" width="80%" height="80%" alt="《原味拍卖》"></a></div>"#;
        assert_eq!(
            parse_detail_cover(html, "《原味拍卖》"),
            "https://hg.jqydt1.com/upload/vod/20261101-1/4cb3c39ecb0fa25f5f47e285148bb0b8.jpg"
        );
        assert_eq!(
            parse_detail_cover("<div>no cover</div>", "《原味拍卖》"),
            ""
        );
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/rukou\/index.php\/vod\/play\/id\/648472\/sid\/1\/nid\/1.html","vod_data":{"vod_name":"《原味拍卖》"},"url":"https:\/\/c10.hs100.top\/20261031\/19f9b7e0d61f49fb\/index.m3u8","url_next":"","from":"jpm3u8","server":"no","note":"","id":"648472","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://c10.hs100.top/20261031/19f9b7e0d61f49fb/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn search_url_encoding() {
        let encoded: String = url::form_urlencoded::byte_serialize("原味".as_bytes()).collect();
        assert_eq!(encoded, "%E5%8E%9F%E5%91%B3");
    }
}
