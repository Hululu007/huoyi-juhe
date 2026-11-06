//! 快乐星球：核心里的影视区站点。
//!
//! MacCMS 站（https://klxq1141.lol），与站导航 1:1（19 项）：
//! 国产视频、中文字幕、国产传媒、日本有码、日本无码、欧美无码、
//! 强奸乱伦、制服诱惑、国产主播、激情动漫、明星换脸、抖阴视频、
//! 女优明星、AV解说、SM调教、萝莉少女、极品媚黑、女同性恋、网红头条。
//! 列表 `/index.php/vod/type/id/<n>/`，翻页
//! `/index.php/vod/type/id/<n>/page/<p>.html`；
//! 首页与列表的卡片直链播放页
//! `/index.php/vod/play/id/<id>/sid/1/nid/1.html`；
//! 注意：详情页 `/index.php/vod/detail/id/<id>.html` 实测回空
//! （HTTP 200、0 字节，两次均如此），故 detail() 直接取播放页：
//! h1 为标题、与标题同 alt 的图为封面、player_aaaa JSON 的
//! url 字段为 m3u8（主清单 200、变体清单 200 METHOD=NONE、
//! 首分片 200 带 TS 同步头，实测于 2026-11-05）；
//! 搜索 `/index.php/vod/search/wd/<编码>.html`。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://klxq1141.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("20", "国产视频"),
    ("21", "中文字幕"),
    ("22", "国产传媒"),
    ("23", "日本有码"),
    ("24", "日本无码"),
    ("25", "欧美无码"),
    ("26", "强奸乱伦"),
    ("27", "制服诱惑"),
    ("28", "国产主播"),
    ("29", "激情动漫"),
    ("30", "明星换脸"),
    ("31", "抖阴视频"),
    ("32", "女优明星"),
    ("33", "AV解说"),
    ("34", "SM调教"),
    ("35", "萝莉少女"),
    ("36", "极品媚黑"),
    ("37", "女同性恋"),
    ("38", "网红头条"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("快乐星球请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 地址归一：协议相对补 https，站内相对路径补基址。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

fn unescape(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/");
    // player_aaaa 里 vod_class 等字段用 \uXXXX 转义，在此还原。
    if out.contains("\\u") {
        let re = Regex::new(r"\\u([0-9a-fA-F]{4})").ok();
        if let Some(re) = re {
            let mut result = String::with_capacity(out.len());
            let mut last = 0;
            for cap in re.captures_iter(&out) {
                let m = cap.get(0).unwrap();
                result.push_str(&out[last..m.start()]);
                if let Ok(n) = u32::from_str_radix(&cap[1], 16) {
                    if let Some(ch) = char::from_u32(n) {
                        result.push(ch);
                    }
                }
                last = m.end();
            }
            result.push_str(&out[last..]);
            out = result;
        }
    }
    out
}

/// 路径段编码：中文按 UTF-8 百分号编码（空格成 +，与站内搜索链接一致）。
fn encode_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>()
}

/// 卡片解析：播放页锚点 + img data-src（封面）+ alt（标题），按 id 去重。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a[^>]+href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>\s*<img[^>]+data-src="([^"]+)"[^>]*alt="([^"]+)""#,
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
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[2]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页导航锚点文本，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)<"#) {
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
    match get_text(BASE).await {
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
    let url = if page <= 1 {
        format!("{BASE}/index.php/vod/type/id/{category_id}/")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty()
        && html.contains(&format!(
            "/index.php/vod/type/id/{category_id}/page/{}.html",
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

/// 播放页类型：player_aaaa 里 vod_class 字段（\uXXXX 需还原）。
fn parse_genre(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"vod_class":"([^"]*)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    }
}

/// 播放页标题：h1 原文。
fn parse_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => String::new(),
    }
}

/// 播放页封面：与标题同 alt 的图。
fn parse_cover(html: &str, title: &str) -> String {
    if title.is_empty() {
        return String::new();
    }
    let re = match Regex::new(r#"<img[^>]+(?:data-src|src)="([^"]+)"[^>]*alt="([^"]*)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    for cap in re.captures_iter(html) {
        if cap[2].trim() == title {
            return fix_url(&cap[1]);
        }
    }
    String::new()
}

fn parse_synopsis(html: &str) -> String {
    let re = match Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id
        .strip_prefix("index.php/vod/play/id/")
        .unwrap_or(id)
        .trim_end_matches(".html");
    let id = id.split('/').next().unwrap_or(id);
    // 详情页回空，改取播放页。
    let html = get_text(&format!(
        "{BASE}/index.php/vod/play/id/{id}/sid/1/nid/1.html"
    ))
    .await?;
    let title = parse_title(&html);
    let cover = parse_cover(&html, &title);
    let synopsis = parse_synopsis(&html);
    let genre = parse_genre(&html);
    let m3u8 = parse_player_url(&html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("快乐星球未返回标题或可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("快乐星球该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/index.php/vod/search/wd/{}.html", encode_path(query));
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/template/klxq/statics/image/placeholder-md.jpg"),
            "https://klxq1141.lol/template/klxq/statics/image/placeholder-md.jpg"
        );
        assert_eq!(fix_url("//a.b/c.jpg"), "https://a.b/c.jpg");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="col-6 col-sm-4 col-lg-3"> <div class="video-img-box mb-e-20"> <div class="img-box cover-md"> <a href="/index.php/vod/play/id/204729/sid/1/nid/1.html"> <img class="lazyload" src="/template/klxq/statics/image/placeholder-md.jpg" data-src="https://aoksazysz.com/20261103/jg5KL9H8/1.jpg" alt="精选探花-约操极品校花女神三千块拿下清纯妹子"> <div class="absolute-bottom-right"> <span class="label">11-05</span> </div> </a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "204729");
        assert_eq!(
            items[0]["title"],
            "精选探花-约操极品校花女神三千块拿下清纯妹子"
        );
        assert_eq!(
            items[0]["cover"],
            "https://aoksazysz.com/20261103/jg5KL9H8/1.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/index.php/vod/type/id/38.html">网红头条</a><a href="/index.php/vod/type/id/35.html">萝莉少女</a><a href="/index.php/vod/type/id/38.html">网红头条</a><a href="/index.php/vod/type/id/20.html">国产视频</a><a href="/index.php/vod/type/id/20.html">国产</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["name"], "网红头条");
        assert_eq!(list[2]["name"], "国产视频");
    }

    #[test]
    fn fallback_has_19_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 19);
        assert_eq!(list[0]["name"], "国产视频");
        assert_eq!(list[18]["name"], "网红头条");
    }

    #[test]
    fn parse_player_url_and_genre_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/204735\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"精选探花-约操极品少妇老哥连干两炮居然还不过瘾","vod_actor":"","vod_director":"","vod_class":"\u56fd\u4ea7\u89c6\u9891"},"url":"https:\/\/iuewgnbvk.com\/20261103\/NTTOClwZ\/index.m3u8","url_next":"","from":"aosika","server":"","note":"","id":"204735","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://iuewgnbvk.com/20261103/NTTOClwZ/index.m3u8"
        );
        assert_eq!(parse_genre(html), "国产视频");
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_title_cover_from_play_page() {
        let title = "精选探花-约操极品少妇老哥连干两炮居然还不过瘾";
        let html = format!(
            r#"<h1>{title}</h1><img class="lazyload" src="/template/klxq/statics/image/placeholder-md.jpg" data-src="https://aoksazysz.com/20261103/NTTOClwZ/1.jpg" alt="{title}">"#
        );
        assert_eq!(parse_title(&html), title);
        assert_eq!(
            parse_cover(&html, title),
            "https://aoksazysz.com/20261103/NTTOClwZ/1.jpg"
        );
    }

    #[test]
    fn encode_path_chinese() {
        assert_eq!(encode_path("老师"), "%E8%80%81%E5%B8%88");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://iuewgnbvk.com/20261103/NTTOClwZ/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://iuewgnbvk.com/20261103/NTTOClwZ/index.m3u8"
        );
        assert!(play_check("204735").is_err());
    }
}
