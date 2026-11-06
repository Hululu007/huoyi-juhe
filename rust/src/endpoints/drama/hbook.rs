//! 小黄书 hbook.tv：日本 AV 站，11 分类与站导航 1:1。
//!
//! 与 py 版 hbook.py 同一套分类、同一条已验播放链。
//! 分类：最新视频 /video、免费试看 /free、中文字幕 /genre/9、
//! 女优 /actress、痴女 /genre/1、恋足 /genre/2、高清 /genre/7、
//! 独家 /genre/8、后宫 /genre/14、4K /genre/17、人妻 /genre/37。
//! 列表卡片：封面 https://hd.skylines.pro/<slug>/cover-t.jpg，
//! 时长备注；女优页卡片带女优名与影片数。
//! 详情页 `const source`：线路 1（cloudfront）
//! `https://hd.skylines.pro/videos/<id>/<uuid>/preview_manifest.m3u8`
//! 为 60 秒预览（15 分片 x 4 秒，分片名 videoN.jpeg 但实为 MPEG-TS，
//! 首字节 0x47）；/free 里个别影片的 source 是直接 .m3u8 全长
//! （2026-11-06 实测 gesy-033 清单 2328.8 秒 = 卡片 0:38:49，
//! 其余 3 部 /free 当日均为 60 秒预览；是否全长按详情 source
//! 动态判断，不写死）。线路 2（bunny）：点按钮设 cookie
//! `video_cdn_preference=bunny` 后刷新，source 变
//! `https://hd-b.skylines.pro/...?bcdn_token=<签名>`；本机出口
//! 连试 8 次均为 403（2026-11-01 同样 403），模块现取现试，
//! 取不到时只出线路 1，不硬编地址。完整版直链假设已死：同路径
//! 去 preview_ 前缀的 manifest.m3u8 连试 5 次 404；VIP 全片
//! 匿名拿不到，未找到绕道，不编造。
//! 注意：详情页偶尔返回缺播放器脚本的半页（const source 缺失，
//! 服务端抖动），detail/play 取页时无 source 会重试 3 次。
//! VIP 定价（2026-11-06）：7 天 $3、30 天 $6、90 天 $12、365 天 $30。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://hbook.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const BUNNY_COOKIE: &str = "video_cdn_preference=bunny";

/// 分类：与站导航 1:1（tid、显示名、路径），实测于 2026-11-06。
const CATS: &[(&str, &str, &str)] = &[
    ("latest", "最新视频", "/video"),
    ("free", "免费试看", "/free"),
    ("genre9", "中文字幕", "/genre/9"),
    ("actress", "女优", "/actress"),
    ("genre1", "痴女", "/genre/1"),
    ("genre2", "恋足", "/genre/2"),
    ("genre7", "高清", "/genre/7"),
    ("genre8", "独家", "/genre/8"),
    ("genre14", "后宫", "/genre/14"),
    ("genre17", "4K", "/genre/17"),
    ("genre37", "人妻", "/genre/37"),
];

fn cat_path(tid: &str) -> &str {
    for (id, _, path) in CATS {
        if *id == tid {
            return path;
        }
    }
    "/video"
}

async fn fetch_once(url: &str, cookie: Option<&str>) -> ApiResult<String> {
    let mut req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"));
    if let Some(c) = cookie {
        req = req.header("Cookie", c);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("hbook 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 带重试的取页：出口时通时断，每次最多试 3 次。
async fn get_page(path: &str, cookie: Option<&str>) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(&url, cookie).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

fn unescape(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

fn strip_tags(s: &str) -> String {
    let re = Regex::new(r"<[^>]+>").unwrap();
    unescape(&re.replace_all(s, "").trim().to_string())
}

fn fix_url(raw: &str) -> String {
    let u = unescape(raw.trim());
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") || u.starts_with("data:") {
        return u;
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{BASE}/{rest}");
    }
    u
}

/// 视频卡片：href="https://hbook.tv/v/<slug>"，data-src 封面，alt 标题，
/// bottom-1 right-1 处的时长备注。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let re_pic = Regex::new(r#"data-src="([^"]+)""#).unwrap();
    let re_alt = Regex::new(r#"alt="([^"]*)""#).unwrap();
    let re_dur = Regex::new(r"bottom-1 right-1[^>]*>\s*([\d:]+)\s*<").unwrap();
    for part in html.split("href=\"https://hbook.tv/v/").skip(1) {
        let slug = part.split('"').next().unwrap_or("").trim().to_string();
        if slug.is_empty() || !seen.insert(slug.clone()) {
            continue;
        }
        let block = &part[..part.len().min(4000)];
        let pic = re_pic
            .captures(block)
            .map(|c| fix_url(&c[1]))
            .unwrap_or_default();
        let name = re_alt
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| slug.clone());
        let remark = re_dur
            .captures(block)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        out.push(item_json(&slug, &name, &pic, &remark));
    }
    out
}

/// 女优卡片：href="https://hbook.tv/actress/<id>" title="<名>"，附影片数。
fn parse_actresses(html: &str) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let re = Regex::new(r#"href="https://hbook\.tv/actress/(\d+)" title="([^"]+)""#).unwrap();
    let re_pic = Regex::new(r#"<img[^>]+src="([^"]+)""#).unwrap();
    let re_cnt = Regex::new(r"(\d+)部影片").unwrap();
    for cap in re.captures_iter(html) {
        let aid = cap[1].to_string();
        if !seen.insert(aid.clone()) {
            continue;
        }
        let start = cap.get(0).unwrap().start();
        let block = &html[start..(start + 2500).min(html.len())];
        let pic = re_pic
            .captures(block)
            .map(|c| fix_url(&c[1]))
            .unwrap_or_default();
        let remark = re_cnt
            .captures(block)
            .map(|c| format!("{}部影片", &c[1]))
            .unwrap_or_default();
        let name = strip_tags(&cap[2]);
        out.push(item_json(&format!("actress:{aid}"), &name, &pic, &remark));
    }
    out
}

/// 详情页 `const source = "..."`（\/ 转义还原）。
fn detail_source(html: &str) -> String {
    let re = Regex::new(r#"const source = "([^"]+)""#).unwrap();
    re.captures(html)
        .map(|c| unescape(&c[1]))
        .unwrap_or_default()
}

/// 是否为 60 秒预览清单（preview_manifest），否则为全长直链。
fn is_preview(source: &str) -> bool {
    source.contains("preview_manifest")
}

struct Detail {
    title: String,
    poster: String,
    synopsis: String,
    actors: String,
    remarks: String,
    source: String,
    stills: Vec<String>,
}

fn parse_detail(html: &str) -> Detail {
    let re_h1 = Regex::new(r"<h1[^>]*>(.*?)</h1>").unwrap();
    let re_poster = Regex::new(r#"data-poster="([^"]+)""#).unwrap();
    let re_h2 = Regex::new(r"<h2[^>]*>(.*?)</h2>").unwrap();
    // 简介取第一条长度 >= 20 的 h2；站内无简介的影片首条 h2 是
    // “报告错误”（举报弹窗标题），须跳过，缺简介时用标题兜底。
    let re_dur = Regex::new(r#"title="视频时长".*?</svg>\s*([\d:]+)"#).unwrap();
    let re_views = Regex::new(r#"title="观看次数".*?</svg>\s*([\d,]+)"#).unwrap();
    let re_actor = Regex::new(r#"href="https://hbook\.tv/actress/(\d+)"[^>]*>([^<]+)<"#).unwrap();
    let title = re_h1
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    let poster = re_poster
        .captures(html)
        .map(|c| fix_url(&c[1]))
        .unwrap_or_default();
    let synopsis = re_h2
        .captures_iter(html)
        .map(|c| strip_tags(&c[1]))
        .find(|t| t.chars().count() >= 20)
        .unwrap_or_default();
    let mut actors: Vec<String> = Vec::new();
    for cap in re_actor.captures_iter(html) {
        let name = strip_tags(&cap[2]);
        if !name.is_empty() && !actors.contains(&name) {
            actors.push(name);
        }
        if actors.len() >= 5 {
            break;
        }
    }
    let mut remarks = String::new();
    if let Some(c) = re_dur.captures(html) {
        remarks = c[1].to_string();
    }
    if let Some(c) = re_views.captures(html) {
        if !remarks.is_empty() {
            remarks.push_str(" | ");
        }
        remarks.push_str(&c[1]);
    }
    // 本片剧照：站内详情页无剧照集，只有本片海报（data-poster），
    // 其余图均为关联影片封面；剧照行只用本片海报。
    let stills = if poster.is_empty() {
        Vec::new()
    } else {
        vec![poster.clone()]
    };
    Detail {
        title,
        poster,
        synopsis,
        actors: actors.join(", "),
        remarks,
        source: detail_source(html),
        stills,
    }
}

/// 详情页取流：无 source 时重试（服务端偶发半页），最多 3 次。
async fn detail_source_live(slug: &str, cookie: Option<&str>) -> String {
    for _ in 0..3 {
        match get_page(&format!("/v/{slug}"), cookie).await {
            Ok(html) => {
                let src = detail_source(&html);
                if !src.is_empty() {
                    return src;
                }
            }
            Err(_) => {}
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    String::new()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let cats: Vec<Value> = CATS
        .iter()
        .map(|(id, name, _)| category_json(id, name))
        .collect();
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if category_id == "actress" {
        let html = get_page(&format!("/actress?page={page}"), None).await?;
        let items = parse_actresses(&html);
        let has_more = items.len() >= 15;
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    if category_id == "free" {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let html = get_page("/free", None).await?;
        let items = parse_cards(&html);
        return Ok(json!({"items": items, "has_more": false}));
    }
    let path = cat_path(category_id);
    let html = get_page(&format!("{path}?page={page}"), None).await?;
    let items = parse_cards(&html);
    let has_more = items.len() >= 16;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(aid) = id.strip_prefix("actress:") {
        let html = get_page(&format!("/actress/{aid}"), None).await?;
        let re_title = Regex::new(r"<title>(.*?)</title>").unwrap();
        let name = re_title
            .captures(&html)
            .map(|c| {
                strip_tags(&c[1])
                    .replace("日本av女优 - 小黄书 hbook.tv", "")
                    .trim()
                    .to_string()
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("女优 {aid}"));
        let works = parse_cards(&html);
        let pic = works
            .get(0)
            .and_then(|w| w.get("cover"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let episodes: Vec<Value> = works
            .iter()
            .map(|w| {
                let vid = w.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let t = w.get("title").and_then(|v| v.as_str()).unwrap_or("");
                episode_json(vid, t, id)
            })
            .collect();
        return Ok(json!({
            "id": id, "title": name, "cover": pic, "synopsis": "",
            "extra": {"actor": name}, "episodes": episodes,
        }));
    }
    let slug = id;
    let html = get_page(&format!("/v/{slug}"), None).await?;
    let d = parse_detail(&html);
    let mut episodes: Vec<Value> = Vec::new();
    if !d.source.is_empty() {
        let label = if is_preview(&d.source) {
            "预览"
        } else {
            "在线播放"
        };
        episodes.push(episode_json(slug, label, slug));
    }
    // 线路 2（bunny）：现取现试，403/取不到时不加选集。
    let src2 = detail_source_live(slug, Some(BUNNY_COOKIE)).await;
    if !src2.is_empty() && src2 != d.source {
        episodes.push(episode_json(&format!("bunny:{slug}"), "线路2", slug));
    }
    let title = if d.title.is_empty() {
        slug.to_string()
    } else {
        d.title.clone()
    };
    let synopsis = if d.synopsis.is_empty() {
        title.clone()
    } else {
        d.synopsis.clone()
    };
    Ok(json!({
        "id": slug,
        "title": title,
        "cover": d.poster,
        "synopsis": synopsis,
        "extra": {"actor": d.actors, "remarks": d.remarks, "stills": d.stills},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let html = get_page(&format!("/search?q={enc}"), None).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (slug, cookie) = if let Some(rest) = video_id.strip_prefix("bunny:") {
        (rest, Some(BUNNY_COOKIE))
    } else {
        (video_id, None)
    };
    if slug.is_empty() {
        return Err(ApiError::Internal("hbook 空 video_id".into()));
    }
    let source = detail_source_live(slug, cookie).await;
    if source.is_empty() {
        return Err(ApiError::Internal("hbook 该集没有播放地址".into()));
    }
    Ok(json!({"url": source, "header": {"User-Agent": UA, "Referer": format!("{BASE}/")}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_len_11() {
        assert_eq!(CATS.len(), 11);
        assert_eq!(CATS[0].0, "latest");
        assert_eq!(CATS[2].0, "genre9");
        assert_eq!(CATS[3].0, "actress");
    }

    #[test]
    fn parse_cards_real_snippet() {
        let html = r#"<a href="https://hbook.tv/v/mfyd-159"><img data-src="https://hd.skylines.pro/mfyd-159/cover-t.jpg" alt="MFYD-159 标题"><span class="bottom-1 right-1">2:03:41</span></a><a href="https://hbook.tv/v/gesy-033"><img data-src="https://hd.skylines.pro/gesy-033/cover-t.jpg" alt="GESY-033 标题"><span class="bottom-1 right-1">0:38:49</span></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0].get("id").and_then(|v| v.as_str()),
            Some("mfyd-159")
        );
        assert_eq!(
            items[0].get("cover").and_then(|v| v.as_str()),
            Some("https://hd.skylines.pro/mfyd-159/cover-t.jpg")
        );
        assert_eq!(
            items[0].get("remark").and_then(|v| v.as_str()),
            Some("2:03:41")
        );
    }

    #[test]
    fn parse_actresses_real_snippet() {
        let html = r#"<a href="https://hbook.tv/actress/123" title="梦美香奈惠"><img src="https://hbook.tv/actress/123.jpg"><span>12部影片</span></a>"#;
        let items = parse_actresses(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0].get("id").and_then(|v| v.as_str()),
            Some("actress:123")
        );
        assert_eq!(
            items[0].get("remark").and_then(|v| v.as_str()),
            Some("12部影片")
        );
    }

    #[test]
    fn detail_source_unescapes() {
        let html = r#"const source = "https:\/\/hd.skylines.pro\/videos\/43069\/x\/preview_manifest.m3u8";"#;
        assert_eq!(
            detail_source(html),
            "https://hd.skylines.pro/videos/43069/x/preview_manifest.m3u8"
        );
        assert!(is_preview(&detail_source(html)));
        assert!(!is_preview(
            "https://hd.skylines.pro/videos/7190/x/1486e2bf.m3u8"
        ));
    }

    #[test]
    fn parse_detail_fields() {
        let html = r#"<h1>MFYD-159 标题</h1><video data-poster="https://fourhoi.com/mfyd-159/cover-n.jpg"></video><h2>报告错误</h2><h2>这是一段超过二十个字的剧情简介文字内容啊</h2><a href="https://hbook.tv/actress/1">梦美香奈惠</a>const source = "https://hd.skylines.pro/videos/1/x/preview_manifest.m3u8";"#;
        let d = parse_detail(html);
        assert_eq!(d.title, "MFYD-159 标题");
        assert_eq!(d.poster, "https://fourhoi.com/mfyd-159/cover-n.jpg");
        assert_eq!(d.synopsis, "这是一段超过二十个字的剧情简介文字内容啊");
        assert_eq!(d.actors, "梦美香奈惠");
        assert_eq!(d.stills.len(), 1);
        assert!(is_preview(&d.source));
    }
}
