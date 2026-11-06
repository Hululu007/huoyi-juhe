//! 麻豆傳媒：`https://Madaoavmodv026.xyz`（站内品牌 51Hub）。
//!
//! 不是核心 md 站：md 是麻豆 App 接口站（`ZakaMdAmns`，API 在
//! spi.d5c4a712.com，AES-256 + MD5 签名 POST，60 分类，封面走
//! mdimg.ystv.top）；本站是 MacCMS 网页站，首页品牌“51Hub - 免费
//! 在线成人影片”，封面走 xing.sex8sex833.com、sbzytpimg*.com:3519
//! 与本站 /upload/vod/，详情页嵌 player_aaaa 直出 m3u8。品牌、形
//! 态、封面 CDN 三路都不同。
//!
//! 本站域名即 51hubvod.com 的镜像：首页 canonical 与详情页 og:url
//! 均指 https://51hubvod.com，robots.txt 的 Sitemap 也指向
//! tanhuaav.com（同套 CMS 多域名镜像）；51hubvod.com（hub51 候选）
//! 与本站是同一站，不要重复注册。
//!
//! 分类：本站前台导航不挂分类链接，实测于 2026-11-05 的可浏览视频
//! 清单为 5 个 vodshow 类型 + 1 个 AI 标签页，共 6 类（静态表，
//! 与站内 /vodshow/<slug>--------<页>---/ 分页锚点 1:1）：
//! domestic-media 国产传媒（type 21，80 页）、guochanshipin 国
//! 产视频（type 22，88 页）、japanese-av 日本有码（type 23）、
//! chinese-subtitles 中文字幕（type 24）、ribenwuma 无码视频
//! （type 27，48 页）、AI（/avt/AI/，83 页）。type id 与导航的
//! 对应由 sitemap-vod-21/22/23 与各页下一頁锚点逐条核对；
//! /vodtype/<slug>/ 只在 tanhuaav.com 镜像上存在，在本站域名上
//! 全是 404，故目录统一走 /vodshow/。sitemap 里的 5 个 type id
//! （21/22/23/24/27）比 tanhuaav 导航的 4 个 vodtype 多 1 个，
//! 多出的就是 guochanshipin（国产视频）。
//!
//! 目录：/vodshow/<slug>--------<页>---/，每页 36 条，卡片为
//! /av/<slug> + aria-label 标题 + 封面 img + 时长角标；/av/app
//! 是下载 App 的假卡，已排除。详情：/av/<slug>，player_aaaa 的
//! url 即 m3u8（主清单 200，变体清单 200，首分片 206 且为 MPEG-TS，
//! 清单 METHOD=NONE 无加密；清单前 9 个分片是站方插播的广告拼接，
//! 随后 DISCONTINUITY 回正片）。搜索：POST /avsearch/，表单
//! wd=<词>，第 1 页 28 条，翻页 /avsearch/page/<n>/wd/<编码>/。
//!
//! 过滤：6 个分类名都不含禁词，全留；实测抓到的首页、目录、详情、
//! 搜索页全文 7 个禁词（萝莉/幼女/未成年/小学生/初中生/小女孩/
//! 呦呦）出现 0 次；卡片只按标签（/avt/ 链接文字）与详情 vod_class
//! 过滤禁词，不按标题过滤（站长标题多为博眼球的假标题）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://Madaoavmodv026.xyz";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态表：实测于 2026-11-05。id 为站内 /vodshow/ 分页锚点
/// 用的 slug，AI 为标签页 slug。
const CATS: &[(&str, &str)] = &[
    ("domestic-media", "国产传媒"),
    ("guochanshipin", "国产视频"),
    ("japanese-av", "日本有码"),
    ("chinese-subtitles", "中文字幕"),
    ("ribenwuma", "无码视频"),
    ("AI", "AI"),
];

/// 禁词：只删站内实际含这些词的分类、只过滤带这些词标签的单片；
/// 高中、大学视为成年人，不作过滤。
const BLOCKED: &[&str] = &[
    "萝莉",
    "幼女",
    "未成年",
    "小学生",
    "初中生",
    "小女孩",
    "呦呦",
];

fn blocked_tag(tag: &str) -> bool {
    BLOCKED.iter().any(|w| tag.contains(w))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("麻豆傳媒请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn post_search(query: &str) -> ApiResult<String> {
    let form = format!("wd={}", urlenc(query));
    let resp = client()?
        .post(format!("{BASE}/avsearch/"))
        .header("User-Agent", UA)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(form)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("麻豆傳媒搜索 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn urlenc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// 地址归一：站内 `https:/` 单斜杠补成 `https://`，协议相对补
/// https，站内相对路径补基址。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("https:/") {
        if !rest.starts_with('/') {
            return format!("https://{rest}");
        }
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("http:/") {
        if !rest.starts_with('/') {
            return format!("http://{rest}");
        }
        return u.to_string();
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
}

/// 目录地址：/vodshow/<slug>--------<页>---/，第 1 页亦然。
fn catalog_url(slug: &str, page: i64) -> String {
    format!("{BASE}/vodshow/{slug}--------{page}---/")
}

/// 卡片解析：锚点 /av/<slug> + aria-label 标题，窗内取封面 img、
/// 时长角标与 /avt/ 标签；标签含禁词的卡片跳过，/av/app 假卡跳过。
fn parse_cards(html: &str) -> Vec<Value> {
    let anchor_re = match Regex::new(r#"<a href="/av/([^"]+)" aria-label="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).ok();
    let dur_re = Regex::new(r">(\d{1,2}:\d{2})<").ok();
    let tag_re = Regex::new(r#"<a href="/avt/[^"]+"[^>]*>([^<]+)<"#).ok();
    let anchors: Vec<(usize, usize, String, String)> = anchor_re
        .captures_iter(html)
        .map(|cap| {
            let m = cap.get(0).unwrap();
            (
                m.start(),
                m.end(),
                cap[1].to_string(),
                unescape(cap[2].trim()),
            )
        })
        .collect();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for (i, (_, end, slug, title)) in anchors.iter().enumerate() {
        if slug == "app" || title.is_empty() {
            continue;
        }
        let id = format!("/av/{slug}");
        if !seen.insert(id.clone()) {
            continue;
        }
        let win_end = if i + 1 < anchors.len() {
            anchors[i + 1].0.min(end + 4000)
        } else {
            (end + 4000).min(html.len())
        };
        if win_end <= *end {
            continue;
        }
        let win = &html[*end..win_end];
        let cover = match &img_re {
            Some(re) => re
                .captures(&win[..win.len().min(1500)])
                .map(|m| fix_url(&m[1]))
                .unwrap_or_default(),
            None => String::new(),
        };
        if cover.is_empty() || cover.contains("/template/") {
            continue;
        }
        let tag = match &tag_re {
            Some(re) => re
                .captures(win)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        if blocked_tag(&tag) {
            continue;
        }
        let remark = match &dur_re {
            Some(re) => re
                .captures(win)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&id, title, &cover, &remark));
    }
    items
}

/// 分页总数：分页锚点 /vodshow/<slug>--------<n>---/ 的最大 n。
fn page_total(html: &str) -> Option<i64> {
    let re = Regex::new(r"/vodshow/[A-Za-z0-9_-]+--------(\d+)---/").ok()?;
    re.captures_iter(html)
        .filter_map(|cap| cap[1].parse::<i64>().ok())
        .max()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let slug = if CATS.iter().any(|(id, _)| *id == category_id) {
        category_id
    } else {
        CATS[0].0
    };
    let html = get_text(&catalog_url(slug, page)).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html) {
        page < total
    } else {
        html.contains(&format!("--------{}---/", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 详情页 player_aaaa：{"url": "<m3u8>", "vod_data": {...}}。
fn parse_player(html: &str) -> Option<Value> {
    let re = Regex::new(r"(?s)var player_aaaa=(\{.*?\})</script>").ok()?;
    let cap = re.captures(html)?;
    serde_json::from_str(&cap[1]).ok()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix("/av/") {
        format!("{BASE}/av/{rest}")
    } else if let Some(rest) = series_id.strip_prefix("av/") {
        format!("{BASE}/av/{rest}")
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/av/{series_id}")
    };
    let html = get_text(&url).await?;
    let player = parse_player(&html);
    let m3u8 = match &player {
        Some(p) => text_of(p, &["url"]),
        None => String::new(),
    };
    let vod = player.as_ref().and_then(|p| get(p, "vod_data"));
    let title_re = Regex::new(r"<h1[^>]*>([^<]+)<").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        if let Some(v) = vod {
            title = text_of(v, &["vod_name"]);
        }
    }
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        if let Some(re) = &t_re {
            if let Some(cap) = re.captures(&html) {
                let mut t = unescape(cap[1].trim());
                if let Some(pos) = t.find(" 高清線上播放") {
                    t.truncate(pos);
                }
                title = t;
            }
        }
    }
    let cover_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let (actor, class) = match vod {
        Some(v) => (text_of(v, &["vod_actor"]), text_of(v, &["vod_class"])),
        None => (String::new(), String::new()),
    };
    if blocked_tag(&class) {
        return Err(ApiError::Internal("麻豆傳媒该片分类不可用".into()));
    }
    let views_re = Regex::new(r"(\d+)\s*次观看").ok();
    let views = match &views_re {
        Some(re) => re
            .captures(&html)
            .and_then(|m| m[1].parse::<i64>().ok())
            .unwrap_or(0),
        None => 0,
    };
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("麻豆傳媒未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"actor": actor, "class": class, "views": views},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }))
    } else {
        Err(ApiError::Internal("麻豆傳媒该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let html = post_search(query).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_six_in_order() {
        assert_eq!(CATS.len(), 6);
        assert_eq!(CATS[0], ("domestic-media", "国产传媒"));
        assert_eq!(CATS[1], ("guochanshipin", "国产视频"));
        assert_eq!(CATS[5], ("AI", "AI"));
        assert!(!CATS.iter().any(|(_, name)| blocked_tag(name)));
    }

    #[test]
    fn catalog_url_shape() {
        assert_eq!(
            catalog_url("domestic-media", 2),
            "https://Madaoavmodv026.xyz/vodshow/domestic-media--------2---/"
        );
        assert_eq!(
            catalog_url("AI", 1),
            "https://Madaoavmodv026.xyz/vodshow/AI--------1---/"
        );
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/upload/vod/20260521-1/bec52653d852a229296f2ebc5a2e5db4.jpg"),
            "https://Madaoavmodv026.xyz/upload/vod/20260521-1/bec52653d852a229296f2ebc5a2e5db4.jpg"
        );
        assert_eq!(
            fix_url("https://xing.sex8sex833.com/20251023/uWsteflW/1.jpg"),
            "https://xing.sex8sex833.com/20251023/uWsteflW/1.jpg"
        );
        assert_eq!(
            fix_url("https:/sbzytpimg1.com:3519/x.jpg"),
            "https://sbzytpimg1.com:3519/x.jpg"
        );
        assert_eq!(fix_url("//x.y/z.jpg"), "https://x.y/z.jpg");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn blocked_tag_words() {
        assert!(blocked_tag("萝莉"));
        assert!(blocked_tag("小学生"));
        assert!(blocked_tag("呦呦"));
        assert!(!blocked_tag("国产"));
        assert!(!blocked_tag("高中"));
        assert!(!blocked_tag("大学"));
    }

    #[test]
    fn parse_cards_filters_blocked_tag_and_app() {
        let html = r#"<div class="min-w-0"><div class="group"><a href="/av/madou-648484" aria-label="片A" class="absolute inset-0 z-20"></a><div><img src="/upload/vod/20260521-1/x.jpg" alt="片A"><span>42:22</span></div><p>片A</p><div><a href="/avt/domestic-media/">国产</a></div></div></div><div class="min-w-0"><div class="group"><a href="/av/dilirebazimo" aria-label="片B" class="absolute inset-0 z-20"></a><div><img src="https://xing.sex8sex833.com/20251023/uWsteflW/1.jpg" alt="片B"><span>06:29</span></div><p>片B</p><div><a href="/avt/AI/">AI</a></div></div></div><div class="min-w-0"><div class="group"><a href="/av/bad1" aria-label="片C" class="absolute inset-0 z-20"></a><div><img src="/upload/vod/20260521-1/y.jpg" alt="片C"><span>10:00</span></div><p>片C</p><div><a href="/avt/loli/">萝莉</a></div></div></div><div class="min-w-0"><div class="group"><a href="/av/app" aria-label="下载App" class="absolute inset-0 z-20"></a><div><img src="/upload/vod/app.jpg" alt="下载App"></div></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/av/madou-648484");
        assert_eq!(items[0]["title"], "片A");
        assert_eq!(
            items[0]["cover"],
            "https://Madaoavmodv026.xyz/upload/vod/20260521-1/x.jpg"
        );
        assert_eq!(items[0]["remark"], "42:22");
        assert_eq!(items[1]["id"], "/av/dilirebazimo");
        assert_eq!(items[1]["remark"], "06:29");
    }

    #[test]
    fn parse_player_reads_url_and_vod_data() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"vod_data":{"vod_name":"李娜娜日本冈山性爱之旅","vod_actor":"李娜娜","vod_director":"","vod_class":"麻豆传媒"},"url":"https:\/\/2605.v155p.com\/20260516\/mHJgPfL7\/index.m3u8","from":"155m3u8","id":"madou-648484","sid":1,"nid":1}</script>"#;
        let player = parse_player(html).unwrap();
        assert_eq!(
            text_of(&player, &["url"]),
            "https://2605.v155p.com/20260516/mHJgPfL7/index.m3u8"
        );
        let vod = get(&player, "vod_data").unwrap();
        assert_eq!(text_of(vod, &["vod_name"]), "李娜娜日本冈山性爱之旅");
        assert_eq!(text_of(vod, &["vod_actor"]), "李娜娜");
        assert_eq!(text_of(vod, &["vod_class"]), "麻豆传媒");
        assert!(parse_player("<html>no player</html>").is_none());
    }

    #[test]
    fn page_total_reads_max() {
        let html = r#"<a href="/vodshow/domestic-media--------2---/">下一頁</a><a href="/vodshow/domestic-media--------80---/">80</a>"#;
        assert_eq!(page_total(html), Some(80));
        assert_eq!(page_total("<div>no pager</div>"), None);
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://2605.v155p.com/20260516/mHJgPfL7/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://2605.v155p.com/20260516/mHJgPfL7/index.m3u8"
        );
        assert!(play_check("/av/madou-648484").is_err());
    }
}
