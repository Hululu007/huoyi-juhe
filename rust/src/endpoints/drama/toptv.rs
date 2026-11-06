//! TOPTV：核心里的影视区站点。
//!
//! MacCMS 站（https://toptv1504.lol），与站导航 1:1（12 项）：
//! 国产自拍、国产传媒、探花系列、人妻熟女、日本无码、美乳巨乳、
//! 强制侵犯、制服诱惑、绝色佳人、家庭乱伦、绝顶潮吹、网红主播。
//! 列表 `/index.php/vod/type/id/<n>/`，翻页
//! `/index.php/vod/type/id/<n>/page/<p>.html`，每页 20 条；
//! 详情 `/index.php/vod/detail/id/<id>.html`（h1 为“资源名称：标题”，
//! 首张 /upload/vod/ 图为封面）；取流在播放页
//! `/index.php/vod/play/id/<id>/sid/1/nid/1.html` 的 player_aaaa
//! JSON 的 url 字段（m3u8，主清单 200、变体清单 200 AES-128、
//! 首分片字节可达，实测于 2026-11-05）；
//! 搜索 `/index.php/vod/search.html?wd=`。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://toptv1504.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("1", "国产自拍"),
    ("2", "国产传媒"),
    ("3", "探花系列"),
    ("4", "人妻熟女"),
    ("5", "日本无码"),
    ("6", "美乳巨乳"),
    ("7", "强制侵犯"),
    ("8", "制服诱惑"),
    ("9", "绝色佳人"),
    ("10", "家庭乱伦"),
    ("11", "绝顶潮吹"),
    ("12", "网红主播"),
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
        return Err(ApiError::Internal(format!("TOPTV 请求 HTTP {status}")));
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

/// 卡片解析：详情锚点 + img alt（标题）+ data-original（封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a[^>]+href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*>.*?<img[^>]*alt="([^"]+)"[^>]*data-original="([^"]+)""#,
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
        let cover = fix_url(&cap[3]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页导航锚点的 title 属性，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/index\.php/vod/type/id/(\d+)\.html" title="([^"]+)""#) {
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

/// 详情页标题：h1“资源名称：标题”去前缀。
fn parse_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let raw = match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => return String::new(),
    };
    match raw.strip_prefix("资源名称：") {
        Some(stripped) => stripped.trim().to_string(),
        None => raw,
    }
}

/// 详情页封面：首张 /upload/vod/ 图。
fn parse_cover(html: &str) -> String {
    let re = match Regex::new(r#"<img[^>]+src="([^"]*\/upload\/vod\/[^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => fix_url(&cap[1]),
        None => String::new(),
    }
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
    let cover = parse_cover(&html);
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
        return Err(ApiError::Internal("TOPTV 详情页缺少标题或播放入口".into()));
    }
    let play_html = get_text(&format!("{BASE}{play_path}")).await?;
    let m3u8 = parse_player_url(&play_html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("TOPTV 未返回可播放地址".into()));
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
        Err(ApiError::Internal("TOPTV 该集没有播放地址".into()))
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
            fix_url("/upload/vod/20261104-1/6404bfbf579b69c6e80ed2b7f20094f8.jpg"),
            "https://toptv1504.lol/upload/vod/20261104-1/6404bfbf579b69c6e80ed2b7f20094f8.jpg"
        );
        assert_eq!(fix_url("//img.x/y.jpg"), "https://img.x/y.jpg");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="column is-half-mobile is-one-quarter-desktop vod-item-box is-half-touch"> <a target="_blank" href="/index.php/vod/detail/id/25403.html"> <figure class="image is-16by9"> <img src="https://img.uyjthen.com/upload/vod/20261104-1/1750b35f82c3a052a9d5e4d74e224b72.jpg" onerror="javascript:this.src='/static/template/cangku/image/loading.jpg';" alt="云盘高质露脸泄密！又骚又浪母狗少妇【姬美】不雅自拍完整版流出，口活无敌各种性爱露出，全程高能" class="lazy" data-original="https://img.uyjthen.com/upload/vod/20261104-1/1750b35f82c3a052a9d5e4d74e224b72.jpg"> </figure> <p class="vod-name is-size-7 has-text-dark has-te"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "25403");
        assert_eq!(
            items[0]["title"],
            "云盘高质露脸泄密！又骚又浪母狗少妇【姬美】不雅自拍完整版流出，口活无敌各种性爱露出，全程高能"
        );
        assert_eq!(
            items[0]["cover"],
            "https://img.uyjthen.com/upload/vod/20261104-1/1750b35f82c3a052a9d5e4d74e224b72.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/index.php/vod/type/id/1.html" title="国产自拍"> <div class="button is-small is-danger has-text-weight-bold type-item"> <span class="is-size-7">国产自拍</span></a><a href="/index.php/vod/type/id/2.html" title="国产传媒"> <span>国产传媒</span></a><a href="/index.php/vod/type/id/1.html" title="国产自拍"> <span>国产自拍</span></a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[1]["name"], "国产传媒");
    }

    #[test]
    fn fallback_has_12_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 12);
        assert_eq!(list[0]["name"], "国产自拍");
        assert_eq!(list[11]["name"], "网红主播");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/25412\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"声优美女小姐姐","vod_actor":"","vod_director":"","vod_class":"国产自拍"},"url":"https:\/\/hsm3.hwzcfz.com\/a3\/20261104\/nS6GSVKA\/index.m3u8","url_next":"","from":"hwzcfz","server":"no","note":"","id":"25412","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://hsm3.hwzcfz.com/a3/20261104/nS6GSVKA/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_title_strips_prefix() {
        let html = r#"<h1>资源名称： 声优美女小姐姐！给你不一样的体验！</h1>"#;
        assert_eq!(parse_title(html), "声优美女小姐姐！给你不一样的体验！");
        assert_eq!(parse_title("<div>no h1</div>"), "");
    }

    #[test]
    fn parse_cover_first_upload_img() {
        let html = r#"<img src="/template/x/logo.png" alt="TOPTV"><img src="https://img.uyjthen.com/upload/vod/20261104-1/6404bfbf579b69c6e80ed2b7f20094f8.jpg" alt="声优美女小姐姐">"#;
        assert_eq!(
            parse_cover(html),
            "https://img.uyjthen.com/upload/vod/20261104-1/6404bfbf579b69c6e80ed2b7f20094f8.jpg"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://hsm3.hwzcfz.com/a3/20261104/nS6GSVKA/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://hsm3.hwzcfz.com/a3/20261104/nS6GSVKA/index.m3u8"
        );
        assert!(play_check("25412").is_err());
    }
}
