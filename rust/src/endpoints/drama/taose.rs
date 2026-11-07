//! AI成人短剧1（taose）：定制模板站，实测于 2026-11-05。
//!
//! 入口 `https://taosemjqx.xyz/tiloq/mavur.html` 301 到
//! `https://taosevfqz.lol/`（另见同站镜像 `https://taosevilo.buzz/`）。
//! 分类与站导航 1:1（44 项）：无码热门/制服乱伦/三级性交/换脸淫梦/
//! 中文精选/卡通动漫/欧美系列/美女主播/国产自拍/熟女有码/萝莉群交/
//! 女同性爱/多人群交/美乳巨乳/强奸调教/抖阴视频/韩国主播/网红头条/
//! 网爆黑料/欧美无码/女优明星/SM调教/AV在线/国产自拍/主播诱惑/
//! 探花约炮/偷拍偷窥/网曝吃瓜/抖阴短片/传媒剧情/日韩主播/日韩无码/
//! 中文字幕/AV解说/换脸明星/强奸乱伦/女优明星/欧美激情/重口激情/
//! 三级伦理/剧情动漫/SM调教/女同性恋/VR视角。
//! 目录 `/type/id/<id>.html`（p1）、`/type/id/<id>/<n>.html`（p>1，
//! 每页 20 条，295 号分类实测 529 页，p1/p2 无重叠）；卡片
//! `/info/id/<N>.html` + 封面 img + 标题 h2。
//! 详情 `/info/id/<N>.html`（h1 标题 + meta description + 播放页
//! `/play/id/<N>.html`）；取流为播放页 JSON-LD `contentUrl` 的
//! m3u8（主清单 200、2000kb 变体清单 200、AES-128、总长 7424.9 秒、
//! 首分片 200）；搜索 `/lookup/<词>.html`（“芦名穗花”实测 20 条；
//! “国产”这类泛词只回分类菜单页、无结果，属站内行为，原样返回）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASES: &[&str] = &["https://taosevfqz.lol", "https://taosevilo.buzz"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

static HOST: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("295", "无码热门"),
    ("297", "制服乱伦"),
    ("298", "三级性交"),
    ("299", "换脸淫梦"),
    ("300", "中文精选"),
    ("301", "卡通动漫"),
    ("302", "欧美系列"),
    ("303", "美女主播"),
    ("304", "国产自拍"),
    ("305", "熟女有码"),
    ("306", "萝莉群交"),
    ("307", "女同性爱"),
    ("308", "多人群交"),
    ("309", "美乳巨乳"),
    ("310", "强奸调教"),
    ("311", "抖阴视频"),
    ("312", "韩国主播"),
    ("313", "网红头条"),
    ("314", "网爆黑料"),
    ("315", "欧美无码"),
    ("316", "女优明星"),
    ("317", "SM调教"),
    ("326", "AV在线"),
    ("702", "国产自拍"),
    ("703", "主播诱惑"),
    ("704", "探花约炮"),
    ("705", "偷拍偷窥"),
    ("706", "网曝吃瓜"),
    ("707", "抖阴短片"),
    ("708", "传媒剧情"),
    ("709", "日韩主播"),
    ("710", "日韩无码"),
    ("711", "中文字幕"),
    ("712", "AV解说"),
    ("713", "换脸明星"),
    ("714", "强奸乱伦"),
    ("715", "女优明星"),
    ("716", "欧美激情"),
    ("717", "重口激情"),
    ("718", "三级伦理"),
    ("719", "剧情动漫"),
    ("720", "SM调教"),
    ("721", "女同性恋"),
    ("722", "VR视角"),
];

/// 基址解析：依次试两个域名，首个回 200 的胜出，缓存 1 小时。
async fn resolve_base() -> String {
    if let Ok(guard) = HOST.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return cached.clone();
            }
        }
    }
    for base in BASES {
        let ok = match client() {
            Ok(c) => c
                .get(*base)
                .header("User-Agent", UA)
                .send()
                .await
                .map(|r| r.status().as_u16() == 200)
                .unwrap_or(false),
            Err(_) => false,
        };
        if ok {
            if let Ok(mut guard) = HOST.lock() {
                *guard = Some((base.to_string(), Instant::now() + Duration::from_secs(3600)));
            }
            return base.to_string();
        }
    }
    BASES[0].to_string()
}

async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
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
        return Err(ApiError::Internal(format!("AI成人短剧1请求 HTTP {status}")));
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

/// 路径段百分号编码（搜索词进 /lookup/<词>.html）。
fn encode_path(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~') {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// 分类解析：首页导航 `/type/id/<N>.html` 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"(?s)<a[^>]*href="/type/id/(\d+)\.html"[^>]*>(.*?)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = Regex::new(r"<[^>]+>")
            .ok()
            .map(|t| t.replace_all(&cap[2], "").trim().to_string())
            .unwrap_or_default();
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
    let base = resolve_base().await;
    match get_text(&base).await {
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

/// 卡片解析：`<a href="/info/id/<N>.html" title="<标题>" class="small-pic">`
/// + 其内第一个 img src（封面）。目录页与搜索页同款。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/info/id/(\d+)\.html"[^>]*title="([^"]+)"[^>]*>.*?<img[^>]*src="([^"]+)""#,
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
        let cover = unescape(cap[3].trim());
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

fn catalog_url(base: &str, category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{base}/type/id/{category_id}.html")
    } else {
        format!("{base}/type/id/{category_id}/{page}.html")
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let base = resolve_base().await;
    let html = get_text(&catalog_url(&base, category_id, page)).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/type/id/{}/{}.html", category_id, page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 详情标题：取最后一个非空 h1（第一个 h1 是站名“AI成人短剧”）。
fn parse_detail_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let mut title = String::new();
    for cap in re.captures_iter(html) {
        let t = Regex::new(r"<[^>]+>")
            .ok()
            .map(|x| x.replace_all(&cap[1], "").trim().to_string())
            .unwrap_or_default();
        if !t.is_empty() && t != "AI成人短剧" {
            title = unescape(&t);
        }
    }
    title
}

/// 详情封面：播放按钮里的 video-img。
fn parse_detail_cover(html: &str) -> String {
    let re = match Regex::new(r#"<img class="video-img[^"]*"[^>]*src="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(cap[1].trim()))
        .unwrap_or_default()
}

fn parse_synopsis(html: &str) -> String {
    let re = match Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(cap[1].trim()))
        .unwrap_or_default()
}

/// 取流：播放页里第一个.m3u8 地址（JSON-LD contentUrl）。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"(https?://[^"'\s]+\.m3u8[^"'\s]*)"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(cap[1].trim()))
        .unwrap_or_default()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.trim();
    let base = resolve_base().await;
    let html = get_text(&format!("{base}/info/id/{vid}.html")).await?;
    let title = parse_detail_title(&html);
    let cover = parse_detail_cover(&html);
    let synopsis = parse_synopsis(&html);
    let play_html = get_text(&format!("{base}/play/id/{vid}.html")).await?;
    let m3u8 = parse_play_url(&play_html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("AI成人短剧1未返回可播放地址".into()));
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
        Err(ApiError::Internal("AI成人短剧1该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = resolve_base().await;
    let url = format!("{base}/lookup/{}.html", encode_path(query.trim()));
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_real_nav() {
        let html = r#"<a href="/type/id/295.html">无码热门</a><a href="/type/id/297.html">制服乱伦</a><a href="/type/id/295.html">无码热门</a><a href="/type/id/722.html">VR视角</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "295");
        assert_eq!(list[0]["name"], "无码热门");
        assert_eq!(list[2]["id"], "722");
    }

    #[test]
    fn fallback_has_44_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 44);
        assert_eq!(list[0]["id"], "295");
        assert_eq!(list[0]["name"], "无码热门");
        assert_eq!(list[43]["id"], "722");
        assert_eq!(list[43]["name"], "VR视角");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/info/id/2960472.html" target="_blank" title="Pacopacomama011625_100.マゾメス性欲処理北島玲" class="small-pic"> <div class="wrap"> <div class="vid_info"> <img class="lazy-load lazy" src="https://155p261028.com/20261104/eQIS3bIC/1.jpg" alt="Pacopacomama011625_100.マゾメス性欲処理北島玲" /> <div class="vlength"> <time> 2026-11-05 08:28:52 </time> </div> </div> <h2>Pacopacomama011625_100.マゾメス性欲処理北島玲 </h2> </div> </a><a href="/info/id/2960472.html" target="_blank" title="重复卡片" class="small-pic"><img src="https://x.y/2.jpg"></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2960472");
        assert_eq!(
            items[0]["title"],
            "Pacopacomama011625_100.マゾメス性欲処理北島玲"
        );
        assert_eq!(
            items[0]["cover"],
            "https://155p261028.com/20261104/eQIS3bIC/1.jpg"
        );
    }

    #[test]
    fn catalog_url_forms() {
        assert_eq!(
            catalog_url("https://taosevfqz.lol", "295", 1),
            "https://taosevfqz.lol/type/id/295.html"
        );
        assert_eq!(
            catalog_url("https://taosevfqz.lol", "295", 2),
            "https://taosevfqz.lol/type/id/295/2.html"
        );
    }

    #[test]
    fn parse_detail_title_skips_site_name() {
        let html = r#"<h1>AI成人短剧</h1><h1>NACR-948不喝老公精液、但出轨对象的精液却喝光光的淫乱妻子~芦名穗花</h1>"#;
        assert_eq!(
            parse_detail_title(html),
            "NACR-948不喝老公精液、但出轨对象的精液却喝光光的淫乱妻子~芦名穗花"
        );
    }

    #[test]
    fn parse_detail_cover_and_synopsis() {
        let html = r#"<meta name="description" content="当前是NACR-948不喝老公精液的详情:芦名穗花-2026-11-05 20:22:21加入大家庭"><a href="/play/id/2960509.html" target="_blank"><img class="video-img img-fluid" src="https://img.uyjthen.com/upload/vod/20261105-1/be453ac003433c3027797e4aa71d8695.jpg"></a>"#;
        assert_eq!(
            parse_detail_cover(html),
            "https://img.uyjthen.com/upload/vod/20261105-1/be453ac003433c3027797e4aa71d8695.jpg"
        );
        assert!(parse_synopsis(html).contains("芦名穗花"));
    }

    #[test]
    fn parse_play_url_content_url() {
        let html = r#"{"@type":"VideoObject","contentUrl": "https://hsm3.hwzcfz.com/a3/20261105/8R4PvkYx/index.m3u8", "description": "NACR-948"}"#;
        assert_eq!(
            parse_play_url(html),
            "https://hsm3.hwzcfz.com/a3/20261105/8R4PvkYx/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no stream</div>"), "");
    }

    #[test]
    fn encode_path_chinese() {
        assert_eq!(
            encode_path("芦名穗花"),
            "%E8%8A%A6%E5%90%8D%E7%A9%97%E8%8A%B1"
        );
        assert_eq!(encode_path("NACR-948"), "NACR-948");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://hsm3.hwzcfz.com/a3/20261105/8R4PvkYx/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://hsm3.hwzcfz.com/a3/20261105/8R4PvkYx/index.m3u8"
        );
        assert!(play_check("2960509").is_err());
    }
    #[tokio::test]
    #[ignore]
    async fn live_avjieshuo_catalog() {
        let start = std::time::Instant::now();
        let r = catalog("712", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE taose av解说 cat=712 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "taose AV解说 catalog empty");
    }
}
