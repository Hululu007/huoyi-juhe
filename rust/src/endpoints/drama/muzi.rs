//! 母子视频：核心里的影视区站点。
//!
//! 清单入口 https://伿媸廓.dgrf-2.xyz/zip-yng/ 是跳转页（假百
//! 度页“母子视频（Ⅱ秒后跳转）”），按脚本随机跳 mzsp 系入口
//!（web.mzsp13 / wap.mzsp14 / vip.mzsp15 等），实站为
//! web.mzsp1.cc/a/（标题母子视频，mzsp 域名轮换）。实站为
//! MacCMS（stui 模板）。与站导航 1:1（7 项）：
//! /a/index.php/vod/type/id/<n>.html（386 黄瓜短剧、244 55资
//! 源、119 不卡资源、286 兔儿资源、370 森林资源、358 母子资源、
//! 329 库库资源）；每页 12 条，翻页
//! /vod/type/id/<n>/page/<页>.html。视频
//! /vod/detail/id/<n>.html，播放页
//! /vod/play/id/<n>/sid/1/nid/1.html 里 player_aaaa 的 url 为
//! m3u8（主清单 200、变体清单 200 METHOD=NONE、首分片 200）。
//! 搜索 /vod/search/wd/<词>.html。站间歇截断/超时，get_text 内
//! 重试 3 次、间隔 2 秒。写源照站原样写，不按站名/分类名/标题删
//! 任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://web.mzsp1.cc/a";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("386", "黄瓜短剧"),
    ("244", "55资源"),
    ("119", "不卡资源"),
    ("286", "兔儿资源"),
    ("370", "森林资源"),
    ("358", "母子资源"),
    ("329", "库库资源"),
];

/// 带重试的 GET：站间歇截断/超时，最多试 3 次，每次间隔 2 秒。
async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
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
        return Err(ApiError::Internal(format!("母子视频请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：`<a class="stui-vodlist__thumb lazyload" href=".../vod/play/id/<n>/sid/1/nid/1.html">`
/// + title 属性（标题）+ data-original（封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="stui-vodlist__thumb lazyload" href="[^"]*/vod/play/id/(\d+)/sid/\d+/nid/\d+\.html"[^>]*title="([^"]+)"[^>]*data-original="([^"]+)""#,
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
        let title = unescape(cap[2].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[3].trim().to_string();
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：导航 /vod/type/id/<n>.html 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="[^"]*/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>"#) {
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
    match get_text(&format!("{BASE}/")).await {
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
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty()
        && html.contains(&format!(
            "/vod/type/id/{category_id}/page/{}.html",
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

/// 详情页本片播放线路：/vod/play/id/<本片 id>/sid/<源>/nid/1.html。
fn parse_play_link(html: &str, id: &str) -> String {
    let re = match Regex::new(&format!(
        r#"href="([^"]*/vod/play/id/{}/sid/\d+/nid/1\.html)""#,
        regex::escape(id)
    )) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => cap[1].to_string(),
        None => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id
        .rsplit("/vod/detail/id/")
        .next()
        .unwrap_or(id)
        .trim_start_matches('/');
    let id = id.strip_suffix(".html").unwrap_or(id);
    let url = format!("{BASE}/index.php/vod/detail/id/{id}.html");
    let html = get_text(&url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"data-original="(https?://[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let play_link = parse_play_link(&html, id);
    if title.is_empty() || play_link.is_empty() {
        return Err(ApiError::Internal("母子视频未返回播放线路".into()));
    }
    let play_html = get_text(&format!("https://web.mzsp1.cc{play_link}")).await?;
    let m3u8 = parse_player_url(&play_html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("母子视频未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("母子视频该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/index.php/vod/search/wd/{query}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="stui-vodlist__thumb lazyload" href="/a/index.php/vod/play/id/853317/sid/1/nid/1.html" name="admonclick" target="_blank" title="GVH-783母子乱伦WakanaReikaグローリークエスト春花幸男若菜れいか" data-original="https://sbzytpimg11.com/upload/vod/20261102-1/b57fec0320426523ca90052b61a3a3de.jpg"><span class="play hidden-xs"></span></a><a class="stui-vodlist__thumb lazyload" href="/a/index.php/vod/play/id/853317/sid/1/nid/1.html" title="重复" data-original="https://sbzytpimg11.com/x.jpg"></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "853317");
        assert_eq!(
            items[0]["title"],
            "GVH-783母子乱伦WakanaReikaグローリークエスト春花幸男若菜れいか"
        );
        assert_eq!(
            items[0]["cover"],
            "https://sbzytpimg11.com/upload/vod/20261102-1/b57fec0320426523ca90052b61a3a3de.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/a/index.php/vod/type/id/386.html">黄瓜短剧</a><a href="/a/index.php/vod/type/id/244.html">55资源</a><a href="/a/index.php/vod/type/id/386.html">黄瓜短剧</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "386");
        assert_eq!(list[1]["name"], "55资源");
    }

    #[test]
    fn fallback_has_7_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 7);
        assert_eq!(list[0]["id"], "386");
        assert_eq!(list[6]["name"], "库库资源");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"vod_data":{"vod_name":"GVH-783","vod_class":"强奸乱伦"},"url":"https:\/\/lsbbf11.com\/20261101\/JSANemjT\/index.m3u8","url_next":"","from":"ytm3u8","id":"853317","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://lsbbf11.com/20261101/JSANemjT/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_play_link_scoped_to_id() {
        let html = r#"<a href="/a/index.php/vod/play/id/853317/sid/1/nid/1.html">播放</a><a href="/a/index.php/vod/play/id/853865/sid/1/nid/1.html">相关</a>"#;
        assert_eq!(
            parse_play_link(html, "853317"),
            "/a/index.php/vod/play/id/853317/sid/1/nid/1.html"
        );
        assert_eq!(parse_play_link(html, "999999"), "");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://lsbbf11.com/20261101/JSANemjT/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://lsbbf11.com/20261101/JSANemjT/index.m3u8"
        );
        assert!(play_check("853317").is_err());
    }

    #[test]
    fn unescape_slashes() {
        assert_eq!(
            unescape("https:\\/\\/lsbbf11.com\\/20261101\\/JSANemjT\\/index.m3u8"),
            "https://lsbbf11.com/20261101/JSANemjT/index.m3u8"
        );
    }
}
