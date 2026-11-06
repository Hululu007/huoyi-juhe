//! 18禁乐园：核心里的影视区站点。
//!
//! MacCMS 站（https://18jin1109.lol），与站导航 1:1（15 项）：
//! 国产自拍、主播诱惑、探花约炮、偷拍偷窥、网曝吃瓜、抖阴短片、
//! 传媒剧情、日韩无码、中文字幕、换脸明星、强奸乱伦、女优明星、
//! 欧美激情、剧情动漫、SM调教。
//! 列表 `/index.php/vod/type/id/<n>/`，翻页
//! `/index.php/vod/type/id/<n>/page/<p>.html`，每页 20 条；
//! 详情 `/index.php/vod/detail/id/<id>.html`（h1 为标题，
//! 与标题同 alt 的图为封面）；取流在播放页
//! `/index.php/vod/play/id/<id>/sid/1/nid/1.html` 的 player_aaaa
//! JSON 的 url 字段（m3u8，主清单 200、变体清单 200 METHOD=NONE、
//! 首分片 Range 206 带 TS 同步头，实测于 2026-11-05）；
//! 搜索 `/index.php/vod/search.html?wd=`。
//! 与已有站 18AV（av18av，18av.wiki 等镜站）不是同站：域名、
//! 模板、内容库均不同。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://18jin1109.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("1", "国产自拍"),
    ("2", "主播诱惑"),
    ("3", "探花约炮"),
    ("4", "偷拍偷窥"),
    ("5", "网曝吃瓜"),
    ("6", "抖阴短片"),
    ("7", "传媒剧情"),
    ("8", "日韩无码"),
    ("9", "中文字幕"),
    ("10", "换脸明星"),
    ("11", "强奸乱伦"),
    ("12", "女优明星"),
    ("13", "欧美激情"),
    ("14", "剧情动漫"),
    ("15", "SM调教"),
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
        return Err(ApiError::Internal(format!("18禁乐园请求 HTTP {status}")));
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
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：详情锚点 + img src（封面）+ alt（标题）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a[^>]+href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*>.*?<img src="([^"]+)" alt="([^"]+)""#,
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

/// 详情页标题：h1 原文。
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

/// 详情页封面：与标题同 alt 的图；无则取首张非 logo 的外链图。
fn parse_cover(html: &str, title: &str) -> String {
    if !title.is_empty() {
        let re = Regex::new(r#"<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)""#).ok();
        if let Some(re) = re {
            for cap in re.captures_iter(html) {
                if cap[2].trim() == title {
                    return fix_url(&cap[1]);
                }
            }
        }
    }
    let re = match Regex::new(r#"<img[^>]+src="(https?://[^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    for cap in re.captures_iter(html) {
        let src = cap[1].to_string();
        if !src.contains("logo.png") {
            return fix_url(&src);
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
    let id = id.strip_prefix("index.php/vod/detail/id/").unwrap_or(id);
    let id = id.trim_end_matches(".html");
    let html = get_text(&format!("{BASE}/index.php/vod/detail/id/{id}.html")).await?;
    let title = parse_title(&html);
    let cover = parse_cover(&html, &title);
    let synopsis = parse_synopsis(&html);
    let play_re = Regex::new(r#"href="(/index\.php/vod/play/id/\d+/sid/1/nid/1\.html)""#).ok();
    let play_path = match &play_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() || play_path.is_empty() {
        return Err(ApiError::Internal(
            "18禁乐园详情页缺少标题或播放入口".into(),
        ));
    }
    let play_html = get_text(&format!("{BASE}{play_path}")).await?;
    let m3u8 = parse_player_url(&play_html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("18禁乐园未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("18禁乐园该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/index.php/vod/search.html"),
        &[("wd", query)],
    );
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
            fix_url("/template/18jin//images/logo.png"),
            "https://18jin1109.lol/template/18jin//images/logo.png"
        );
        assert_eq!(fix_url("//x.y/z.jpg"), "https://x.y/z.jpg");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/index.php/vod/detail/id/60696.html" target="_blank" title="-情侣自拍流出-太甜了收藏佳作" class="thumbnail"> <div class="video-thumb"> <img src="https://guzwiayz.com/20261103/8GNCO1H2/1.jpg?t=1793750874" alt="-情侣自拍流出-太甜了收藏佳作"> </div> <span class="video-title">-情侣自拍流出-太甜了收藏佳作</span> <span class="video-overlay badge transparent"> 240 </span> <span class="video-time badge transparent"> 2026-11-05 </span> </a><a href="/index.php/vod/detail/id/60696.html" target="_blank" title="重复卡片" class="thumbnail"> <img src="https://guzwiayz.com/x.jpg" alt="重复卡片"> </a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "60696");
        assert_eq!(items[0]["title"], "-情侣自拍流出-太甜了收藏佳作");
        assert_eq!(
            items[0]["cover"],
            "https://guzwiayz.com/20261103/8GNCO1H2/1.jpg?t=1793750874"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/index.php/vod/type/id/1.html">国产自拍</a><a href="/index.php/vod/type/id/2.html">主播诱惑</a><a href="/index.php/vod/type/id/1.html">国产自拍</a><a href="/index.php/vod/type/id/15.html">SM调教</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[2]["name"], "SM调教");
    }

    #[test]
    fn fallback_has_15_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 15);
        assert_eq!(list[0]["name"], "国产自拍");
        assert_eq!(list[14]["name"], "SM调教");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/60734\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"HEZ-894","vod_actor":"","vod_director":"","vod_class":"强奸乱伦"},"url":"https:\/\/vostrely.com\/20261103\/ZdV8YQMY\/index.m3u8","url_next":"","from":"naixx","server":"","note":"","id":"60734","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://vostrely.com/20261103/ZdV8YQMY/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_title_and_cover() {
        let title = "HEZ-894 测试标题";
        let html = format!(
            r#"<h1>{title}</h1><img src="/template/18jin//images/logo.png" alt="18禁乐园"><img src="https://guzwiayz.com/20261103/ZdV8YQMY/1.jpg?t=1793750812" alt="{title}">"#
        );
        assert_eq!(parse_title(&html), title);
        assert_eq!(
            parse_cover(&html, title),
            "https://guzwiayz.com/20261103/ZdV8YQMY/1.jpg?t=1793750812"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://vostrely.com/20261103/ZdV8YQMY/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://vostrely.com/20261103/ZdV8YQMY/index.m3u8"
        );
        assert!(play_check("60734").is_err());
    }
}
