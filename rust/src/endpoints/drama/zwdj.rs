//! 中文短剧网：核心里的影视区站点。
//!
//! 入口 gczwmira.xyz/borqem/vutax.html?f=yngd 是跳转页，
//! 实站落在 gczwfrusk.forum（与短剧窝同模板、不同库：
//! 分类 id 段 7-99、详情走 /display/id/、搜索走 /search/，
//! 视频 id 段也不同，不是同站）。
//! - 分类 64 个，与首页分类行 /type/id/ 链接 1:1
//!   （id 7-99，不连续；“伦理三级”一名出现两次，
//!   id 26 与 69，照站原样都留）。
//! - 目录：/type/id/<id>.html，翻页 /type/id/<id>/<n>.html，
//!   每页 20 条；卡片标题在 h3.video-title 的 <text> 里、
//!   封面在 img.lazy 的 src。
//! - 详情：/display/id/<id>.html，标题取 h1.title 的
//!   <text>（去尾“详情页”）、封面为唯一一张
//!   /upload/vod/ 图、简介取 meta description；
//!   播放入口 /detail/id/<id>.html，单集。
//! - 取流：播放页 `var playUrl = '...m3u8'`（Aliplayer
//!   source 即 playUrl），实测 3137141：
//!   hsm3.hwzcfz.com 主清单 200、变体清单 200（19.5KB，
//!   AES-128）、首分片 200、511KB；分片无需 Referer，
//!   play() 只带 User-Agent。
//! - 搜索：/search/<词>.html，实测“美女”20 条。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://gczwfrusk.forum";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页分类行，站内顺序，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("7", "中文字幕"),
    ("8", "国产传媒"),
    ("9", "日本有码"),
    ("10", "日本无码"),
    ("11", "欧美无码"),
    ("12", "强奸乱伦"),
    ("13", "制服诱惑"),
    ("14", "国产主播"),
    ("15", "激情动漫"),
    ("16", "明星换脸"),
    ("17", "抖阴视频"),
    ("18", "女优明星"),
    ("22", "网曝黑料"),
    ("26", "伦理三级"),
    ("28", "AV解说"),
    ("31", "SM调教"),
    ("33", "萝莉少女"),
    ("34", "极品媚黑"),
    ("37", "女同性恋"),
    ("39", "网红头条"),
    ("43", "人妖系列"),
    ("45", "韩国主播"),
    ("47", "VR视角"),
    ("59", "国产色情"),
    ("60", "主播直播"),
    ("61", "亚洲无码"),
    ("62", "亚洲有码"),
    ("63", "国产中文"),
    ("64", "美乳汁水"),
    ("65", "熟女自慰"),
    ("66", "人兽乱伦"),
    ("67", "欧美精品"),
    ("68", "萝莉岛"),
    ("69", "伦理三级"),
    ("70", "成人动漫"),
    ("71", "手机偷拍"),
    ("72", "制服丝袜"),
    ("73", "口交颜射"),
    ("74", "日本精品"),
    ("75", "Cosplay"),
    ("76", "素人自拍"),
    ("77", "台湾辣妹"),
    ("78", "韩国御姐"),
    ("79", "唯美港姐"),
    ("80", "东南亚AV"),
    ("81", "欺辱凌辱"),
    ("82", "剧情介绍"),
    ("83", "多人多P"),
    ("84", "91探花"),
    ("85", "网红流出"),
    ("86", "野外露出"),
    ("87", "古装扮演"),
    ("88", "女优系列"),
    ("89", "可爱学生"),
    ("90", "风情旗袍"),
    ("91", "兽耳系列"),
    ("92", "瑜伽裤"),
    ("93", "闷骚护士"),
    ("94", "过膝袜"),
    ("95", "网曝门"),
    ("96", "传媒出品"),
    ("97", "女同3p"),
    ("98", "男同性恋"),
    ("99", "恋腿狂魔"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match client()?
            .get(url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE}/"))
            .send()
            .await
        {
            Ok(resp) => {
                if resp.status().as_u16() == 200 {
                    match resp.text().await {
                        Ok(text) if !text.trim().is_empty() => return Ok(text),
                        Ok(_) => last_err = "空响应".into(),
                        Err(e) => last_err = e.to_string(),
                    }
                } else {
                    last_err = format!("HTTP {}", resp.status().as_u16());
                }
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!(
        "中文短剧网请求失败 {url}: {last_err}"
    )))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 分类解析：/type/id/<id>.html 锚点的 title 属性。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/type/id/(\d+)\.html" title="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = unescape(cap[2].trim());
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

/// 卡片解析：/display/id/<id>.html 锚点 + img.lazy 封面 +
/// 随后 h3.video-title 内的 <text> 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re =
        match Regex::new(r#"(?s)<a href="/display/id/(\d+)\.html"[^>]*>\s*<img[^>]*src="([^"]+)""#)
        {
            Ok(re) => re,
            Err(_) => return Vec::new(),
        };
    let title_re = Regex::new(r#"(?s)<h3 class="video-title">.*?<text>([^<]+)</text>"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = cap[2].trim().to_string();
        let tail = &html[cap.get(0).map(|m| m.end()).unwrap_or(0)..];
        let window = tail.get(..3000).unwrap_or(tail);
        let title = match &title_re {
            Some(re) => re
                .captures(window)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 播放地址：播放页 `var playUrl = '...m3u8'`。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"var playUrl = '([^']+)'"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => cap[1].trim().to_string(),
        None => String::new(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/type/id/7.html")).await {
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
    let page = if page < 1 { 1 } else { page };
    let url = if page <= 1 {
        format!("{BASE}/type/id/{category_id}.html")
    } else {
        format!("{BASE}/type/id/{category_id}/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/type/id/{category_id}/{}.html", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/display/id/")
        .trim_end_matches(".html")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{BASE}/display/id/{id}.html")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>.*?<text>([^<]+)</text>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| {
                let t = unescape(m[1].trim());
                t.strip_suffix("详情页").unwrap_or(&t).to_string()
            })
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"<img[^>]*src="([^"]*?/upload/vod/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description" content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("中文短剧网详情未返回标题".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&id, "播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let id = vid
        .trim_start_matches("/detail/id/")
        .trim_end_matches(".html")
        .trim_end_matches('/');
    let page_url = format!("{BASE}/detail/id/{id}.html");
    let html = get_text(&page_url).await?;
    let stream = parse_play_url(&html);
    if stream.is_empty() {
        return Err(ApiError::Internal("中文短剧网未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{BASE}/search/{enc}.html");
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_title_attr() {
        let html = r#"<a class="enable-random-category-item" href="/type/id/59.html" title="国产色情" target="_blank"><text>国产色情</text></a> <a class="enable-random-category-item" href="/type/id/60.html" title="主播直播" target="_blank"><text>主播直播</text></a> <a class="enable-random-category-item" href="/type/id/59.html" title="国产色情" target="_blank"><text>国产色情</text></a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "59");
        assert_eq!(list[0]["name"], "国产色情");
        assert_eq!(list[1]["name"], "主播直播");
    }

    #[test]
    fn fallback_has_64_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 64);
        assert_eq!(list[0]["id"], "7");
        assert_eq!(list[0]["name"], "中文字幕");
        assert_eq!(list[63]["id"], "99");
        assert_eq!(list[63]["name"], "恋腿狂魔");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<li> <a href="/display/id/3145640.html" name="rdmonclick" target="_blank" class="enable-random-friend-link" rel="nofollow"> <img class="lazy" src="https://aoksazysz.com/20261104/9YHQ4Acn/1.jpg"> </a> <div class="video-detail"><a href="/display/id/3145640.html" name="rdmonclick" target="_blank" rel="nofollow"></a> <h3 class="video-title"><a href="/display/id/3145640.html" name="rdmonclick" target="_blank" rel="nofollow"></a><a><text>PPPE-248-C 彼女が家族旅行で一週間留守にしたので彼女の巨乳女友達に中出ししまくりました。</text></a> </h3> </div> </li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "3145640");
        assert!(items[0]["title"]
            .as_str()
            .unwrap()
            .starts_with("PPPE-248-C"));
        assert_eq!(
            items[0]["cover"],
            "https://aoksazysz.com/20261104/9YHQ4Acn/1.jpg"
        );
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#"var playUrl = 'https://hsm3.hwzcfz.com/a3/20261012/r3Asf51P/index.m3u8'; var player = new Aliplayer({ "id": "video", "source": playUrl, "width": "100%" });"#;
        assert_eq!(
            parse_play_url(html),
            "https://hsm3.hwzcfz.com/a3/20261012/r3Asf51P/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no url</div>"), "");
    }
    #[tokio::test]
    #[ignore]
    async fn live_avjieshuo_catalog() {
        let start = std::time::Instant::now();
        let r = catalog("28", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE zwdj av解说 cat=28 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "zwdj AV解说 catalog empty");
    }
}
