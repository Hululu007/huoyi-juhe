//! 🔞红裸短剧（成人）：hongluo.co，HONG LUO 紅裸短劇，独立站，
//! 不是字节红果（hongguoduanju.com），也不是黄果 / 黄豆 / 野果任一站。
//!
//! 去重实测（2026-11-06）：
//! - 域名、品牌、技术栈全不同：本站 hongluo.co，Next.js（Vinext）+
//!   自有 JSON 接口 /api/catalog；红果是 hongguoduanju.com；黄果TV
//!   是 Laravel 站 media.huangguotv.com 的 HLS（/video/<id>）；
//!   hgtv.im 是 theme4 模板站；野果是 PWA AES 接口
//!   （analyze.buxefaex.cc）；短剧 one 是 Laravel + B2 直链。
//! - 目录是本站自有 51 部、421 集（sitemap-series 51、
//!   sitemap-episodes 421，与首页卡片 51 部、集数合计 421 自洽）；
//!   剧目代码 ZYB / MANI / SISR / LBSR / LB（如 ZYB-008-2），
//!   与黄果系、黄豆系、野果的剧目、代码、封面 host 全无重合。
//! - 核心与 Dart 里均无 hongluo 键；Dart 侧 hongguo（红果）是另一站，
//!   不动它。
//!
//! 分类（站内导航 1:1：全部 + 9 个类型；卡片上另有末日生存、乡村情感
//! 2 个类型，站内无对应导航页，接口虽认（/api/catalog?category=
//! 末日生存 / 鄉村情感 各回 2 / 1 部），但导航没有就不单独立类，
//! 这 3 部只在“全部”里出现）：
//! - 全部 51、仙侠玄幻 9、都市情感 9、奇幻异能 6、古装宫廷 5、
//!   悬疑犯罪 6、大学校园 4、家庭剧情 3、职场商战 3、灵异惊悚 3。
//! - 接口 category 参数只认繁体名（简体回空），映射表见 CATS。
//! - 列表、搜索、详情都不分页：首页、类型页、搜索页一次给全量。
//!
//! 取流（VIP / 金币墙实测，未找到匿名绕道）：
//! - 免费集：第 1 集（45 部有）页内直接给 SSR <video>，
//!   src 为 https://hongluo.co/api/seo-video/ep_<code>_01.mp4，
//!   JSON-LD VideoObject 的 contentUrl 也是同一地址，视频 sitemap
//!   的 <video:content_loc> 只有这 45 个第 1 集；其余 6 部
//!   （圣坛上的修女、迷奸孕妇拍摄团、水浒淫传、PRISM：魔盗女团、
//!   琼明神女录、女社长的肉偿）第 1 集起就是金币或会员，页内无视频。
//! - 第 2 集是登录后 10 分钟免费窗口（站内 FAQ 原文），匿名拿不到；
//!   第 3 集起金币解锁或 VIP 会员：匿名页内无 <video>、无 mp4、
//!   无 m3u8、无 grant、无 media/v host 地址；播放器走 HLS
//!   master.m3u8，地址由服务端 grant 下发，须登录 + 解锁 +
//!   playback/start 会话；JS 路由表里没有匿名取流接口。
//! - 目录接口每部有 previewUrl（/api/assets/previews/*.mp4），
//!   实测只是 7.2 秒预告片（250724 字节），不是正片，不作取流回退。
//! - 注意：seo-video 直链本机验不了真播——本站点的 HTML、JSON-LD、
//!   视频 sitemap 三处一致给出该地址，但本机出口（urllib / curl /
//!   浏览器抓取三路，桌面 / 移动 / Googlebot 三种 UA，带 / 不带
//!   Referer 与饼干，IPv4 / IPv6，多次复测）一律回 404
//!   {"error":"找不到视频文件","code":"REQUEST_FAILED"}；同机
//!   /api/assets 预告片可正常 Range 206 拉到（ftyp isom），说明
//!   不是整站被挡，只是 seo-video 上游取文件失败。play() 仍按站方
//!   公布的地址回（App 在手机网络下点播才算终验），手机侧须复验。
//! - 付费集 play() 如实报错，不编地址、不拿预告片冒充正片。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, str_of, text_of};

const HOST: &str = "https://hongluo.co";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// （分类 id，简体显示名，接口要的繁体名）。
const CATS: &[(&str, &str, &str)] = &[
    ("all", "全部", ""),
    ("xianxia-fantasy", "仙侠玄幻", "仙俠玄幻"),
    ("urban-romance", "都市情感", "都市情感"),
    ("fantasy-superpowers", "奇幻异能", "奇幻異能"),
    ("costume-palace", "古装宫廷", "古裝宮廷"),
    ("mystery-crime", "悬疑犯罪", "懸疑犯罪"),
    ("college-life", "大学校园", "大學校園"),
    ("family-drama", "家庭剧情", "家庭劇情"),
    ("workplace-business", "职场商战", "職場商戰"),
    ("supernatural-thriller", "灵异惊悚", "靈異驚悚"),
];

fn api_category(category_id: &str) -> &'static str {
    for (id, _, api) in CATS {
        if *id == category_id {
            return api;
        }
    }
    ""
}

fn display_genre(api_genre: &str) -> String {
    for (_, display, api) in CATS {
        if *api == api_genre {
            return display.to_string();
        }
    }
    api_genre.to_string()
}

fn ep_anchor_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"<a href="[^"]*/ep-(\d+)">第\s*\d+\s*集：([^<]+)</a>\s*·\s*<!-- -->([^<]+)<!-- -->\s*·\s*约\s*(\d+)\s*分钟"#,
        )
        .unwrap()
    })
}

fn video_src_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<video[^>]*src="([^"]+)""#).unwrap())
}

fn content_url_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""contentUrl":"([^"]+)""#).unwrap())
}

fn og_image_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"property="og:image" content="([^"]+)""#).unwrap())
}

fn meta_desc_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"name="description" content="([^"]*)""#).unwrap())
}

fn h1_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<h1[^>]*>([^<]+)</h1>"#).unwrap())
}

fn genre_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""genre":"([^"]+)""#).unwrap())
}

async fn fetch_json(url: &str) -> ApiResult<Value> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{HOST}/zh-hans/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("红裸短剧请求 HTTP {status}")));
    }
    resp.json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn fetch_html(url: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/zh-hans/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("红裸短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn abs_url(u: &str) -> String {
    let u = u.trim().replace("&amp;", "&");
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("https://") || u.starts_with("http://") {
        return u;
    }
    if let Some(stripped) = u.strip_prefix('/') {
        return format!("{HOST}/{stripped}");
    }
    format!("{HOST}/{u}")
}

fn cover_of(poster_url: &str) -> String {
    let u = abs_url(poster_url);
    if u.is_empty() {
        return u;
    }
    if u.contains("?") {
        format!("{u}&w=240")
    } else {
        format!("{u}?w=240")
    }
}

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn parse_series_items(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let Some(series) = get(data, "series").and_then(|v| v.as_array()) else {
        return items;
    };
    for s in series {
        let slug = text_of(s, &["slug"]);
        if slug.is_empty() {
            continue;
        }
        let title = text_of(s, &["originalTitle", "title"]);
        if title.is_empty() {
            continue;
        }
        let cover = cover_of(&text_of(s, &["posterUrl"]));
        let genre = display_genre(&text_of(s, &["category"]));
        let total = int_of(s, &["totalEpisodes"]);
        let free = int_of(s, &["freeEpisodes"]);
        let mut bits: Vec<String> = Vec::new();
        if !genre.is_empty() {
            bits.push(genre);
        }
        if total > 0 {
            bits.push(format!("{total}集"));
        }
        if free > 0 {
            bits.push(format!("免费{free}集"));
        }
        items.push(item_json(&slug, &title, &cover, &bits.join(" · ")));
    }
    items
}

fn catalog_url(category_id: &str) -> String {
    let api = api_category(category_id);
    if api.is_empty() {
        format!("{HOST}/api/catalog")
    } else {
        format!(
            "{HOST}/api/catalog?category={}",
            url::form_urlencoded::byte_serialize(api.as_bytes()).collect::<String>()
        )
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (id, name, _) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if page > 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let data = fetch_json(&catalog_url(category_id)).await?;
    let items = parse_series_items(&data);
    Ok(json!({"items": items, "has_more": false}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = format!("{HOST}/zh-hans/series/{series_id}");
    let html = fetch_html(&url).await?;
    let mut title = h1_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| strip_tags(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        if let Some(p) = html.find("<title>") {
            let after = &html[p + 7..];
            if let Some(e) = after.find("</title>") {
                title = strip_tags(&after[..e]);
                for sep in ['｜', '|'] {
                    if let Some(q) = title.find(sep) {
                        title = title[..q].trim().to_string();
                        break;
                    }
                }
            }
        }
    }
    if title.is_empty() {
        return Err(ApiError::Internal("红裸短剧未返回影片资料".into()));
    }
    let cover = og_image_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    let desc = meta_desc_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    let genre = genre_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| display_genre(m.as_str()))
        .unwrap_or_default();
    let mut episodes: Vec<Value> = Vec::new();
    let mut free_count: i64 = 0;
    let mut seen: Vec<i64> = Vec::new();
    for cap in ep_anchor_re().captures_iter(&html) {
        let n: i64 = match cap[1].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        if seen.contains(&n) {
            continue;
        }
        seen.push(n);
        let ep_title = cap[2].trim().to_string();
        let access = cap[3].trim();
        let minutes = cap[4].parse::<i64>().unwrap_or(0);
        let is_free = access.contains("免费");
        if is_free {
            free_count += 1;
        }
        let mut label = format!("第{n}集：{ep_title}");
        if minutes > 0 {
            label.push_str(&format!("·约{minutes}分钟"));
        }
        if !is_free {
            label.push_str("·VIP");
        }
        episodes.push(episode_json(&format!("{series_id}:{n}"), &label, series_id));
    }
    episodes.sort_by_key(|e| {
        str_of(&e["video_id"])
            .rsplit(':')
            .next()
            .unwrap_or("0")
            .parse::<i64>()
            .unwrap_or(0)
    });
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("{series_id}:1"), "第1集", series_id));
    }
    let mut remark_bits: Vec<String> = Vec::new();
    if !genre.is_empty() {
        remark_bits.push(genre);
    }
    remark_bits.push(format!("共 {} 集", episodes.len()));
    if free_count > 0 {
        remark_bits.push(format!("免费 {free_count} 集"));
    }
    let mut extra = serde_json::Map::new();
    extra.insert("remark".to_string(), json!(remark_bits.join(" · ")));
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/api/catalog?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let data = fetch_json(&url).await?;
    let items = parse_series_items(&data);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/zh-hans/")},
        }));
    }
    let (series_id, ep) = match video_id.split_once(':') {
        Some((s, e)) => (s.to_string(), e.parse::<i64>().unwrap_or(1)),
        None => (video_id.to_string(), 1),
    };
    let ep_url = format!("{HOST}/zh-hans/series/{series_id}/ep-{ep}");
    let html = fetch_html(&ep_url).await?;
    let src = video_src_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .or_else(|| {
            content_url_re()
                .captures(&html)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().to_string())
        })
        .unwrap_or_default();
    if src.is_empty() {
        return Err(ApiError::Internal(format!(
            "红裸短剧第{ep}集需金币解锁或VIP会员后观看"
        )));
    }
    Ok(json!({
        "url": abs_url(&src),
        "header": {"User-Agent": UA, "Referer": ep_url},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATALOG_JSON: &str = r#"{"series":[{"id":"series_zyb0082","slug":"mr-crows-coin","title":"烏鴉先生的硬幣","originalTitle":"乌鸦先生的硬币","code":"ZYB-008-2","description":"愛攝影的知晴深夜救下一隻翅膀受傷的烏鴉。","category":"奇幻異能","tags":["奇幻戀曲","烏鴉化身"],"posterUrl":"/api/assets/posters%2Fseries_zyb0082-hand-202610292144.jpg?v=e2bc83171aad","status":"published","totalEpisodes":11,"publishedEpisodes":11,"freeEpisodes":2,"loginEpisodes":1,"memberEpisodes":9},{"id":"series_lb0013","slug":"the-nun-on-the-altar","title":"聖壇上的修女","originalTitle":"圣坛上的修女","code":"LB-001-3","description":"夜宴的款待。","category":"靈異驚悚","tags":[],"posterUrl":"/api/assets/posters%2Fseries_lb0013-zh-Hans-202610291130.jpg?v=007c3d2ccc59","status":"published","totalEpisodes":1,"publishedEpisodes":1,"freeEpisodes":0,"loginEpisodes":0,"memberEpisodes":1}]}"#;

    const SERIES_HTML: &str = r#"<title>乌鸦先生的硬币｜奇幻异能成人短剧，共 11 集 | 红裸短剧</title><meta name="description" content="爱摄影的知晴深夜救下一只翅膀受伤的乌鸦。"><meta property="og:image" content="https://hongluo.co/api/assets/posters%2Fseries_zyb0082-zh-Hans-202610292144.jpg?v=5090719c1041"><h1>乌鸦先生的硬币</h1><script type="application/ld+json">{"@type":"TVSeries","name":"乌鸦先生的硬币","genre":"奇幻異能","numberOfEpisodes":11}</script><ul><li><a href="https://hongluo.co/zh-hans/series/mr-crows-coin/ep-1">第 1 集：夜里的救援</a> · <!-- -->免费<!-- --> · 约 3 分钟<p>深夜，知晴救下一只受伤的乌鸦。</p></li><li><a href="https://hongluo.co/zh-hans/series/mr-crows-coin/ep-2">第 2 集：失去记忆的人</a> · <!-- -->免费<!-- --> · 约 2 分钟<p>阿末住进知晴房间的对面。</p></li><li><a href="https://hongluo.co/zh-hans/series/mr-crows-coin/ep-3">第 3 集：阿末留了下来</a> · <!-- -->金币解锁或VIP 会员<!-- --> · 约 2 分钟<p>男子穿着医院的衣服。</p></li></ul>"#;

    const EP1_HTML: &str = r#"<title>乌鸦先生的硬币 第 1 集：夜里的救援（免费） | 红裸短剧</title><video class="ssr-video" src="https://hongluo.co/api/seo-video/ep_zyb0082_01.mp4" poster="https://hongluo.co/api/assets/thumbs%2Fep_zyb0082_01-clean-ba45a9ff.jpg?v=380a3ecb1349" title="乌鸦先生的硬币 第 1 集：夜里的救援" controls="" preload="none" playsInline=""><script type="application/ld+json">{"@type":"VideoObject","name":"乌鸦先生的硬币 第 1 集：夜里的救援","duration":"PT2M39S","contentUrl":"https://hongluo.co/api/seo-video/ep_zyb0082_01.mp4","isAccessibleForFree":true}</script>"#;

    const EP3_HTML: &str = r#"<title>乌鸦先生的硬币 第 3 集：阿末留了下来（金币或会员） | 红裸短剧</title><meta name="description" content="男子穿着医院的衣服。"><script type="application/ld+json">{"@type":"TVEpisode","name":"阿末留了下来","episodeNumber":3,"duration":"PT2M8S","isAccessibleForFree":false}</script>"#;

    #[test]
    fn parse_catalog_real_snippet() {
        let data: Value = serde_json::from_str(CATALOG_JSON).unwrap();
        let items = parse_series_items(&data);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "mr-crows-coin");
        assert_eq!(items[0]["title"], "乌鸦先生的硬币");
        assert_eq!(
            items[0]["cover"],
            "https://hongluo.co/api/assets/posters%2Fseries_zyb0082-hand-202610292144.jpg?v=e2bc83171aad&w=240"
        );
        assert_eq!(items[0]["remark"], "奇幻异能 · 11集 · 免费2集");
        assert_eq!(items[1]["id"], "the-nun-on-the-altar");
        assert_eq!(items[1]["remark"], "灵异惊悚 · 1集");
    }

    #[test]
    fn categories_count_and_api_names() {
        assert_eq!(CATS.len(), 10);
        assert_eq!(CATS[0], ("all", "全部", ""));
        assert_eq!(CATS[3], ("fantasy-superpowers", "奇幻异能", "奇幻異能"));
        assert_eq!(CATS[6], ("college-life", "大学校园", "大學校園"));
        assert_eq!(api_category("fantasy-superpowers"), "奇幻異能");
        assert_eq!(api_category("all"), "");
        assert_eq!(api_category("nope"), "");
        assert_eq!(display_genre("奇幻異能"), "奇幻异能");
        assert_eq!(display_genre("末日生存"), "末日生存");
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(catalog_url("all"), "https://hongluo.co/api/catalog");
        assert_eq!(
            catalog_url("fantasy-superpowers"),
            "https://hongluo.co/api/catalog?category=%E5%A5%87%E5%B9%BB%E7%95%B0%E8%83%BD"
        );
        assert_eq!(
            catalog_url("college-life"),
            "https://hongluo.co/api/catalog?category=%E5%A4%A7%E5%AD%B8%E6%A0%A1%E5%9C%92"
        );
    }

    #[test]
    fn detail_fields_from_fixture() {
        assert_eq!(
            h1_re()
                .captures(SERIES_HTML)
                .unwrap()
                .get(1)
                .unwrap()
                .as_str(),
            "乌鸦先生的硬币"
        );
        assert_eq!(
            og_image_re().captures(SERIES_HTML).unwrap().get(1).unwrap().as_str(),
            "https://hongluo.co/api/assets/posters%2Fseries_zyb0082-zh-Hans-202610292144.jpg?v=5090719c1041"
        );
        assert_eq!(
            genre_re()
                .captures(SERIES_HTML)
                .unwrap()
                .get(1)
                .unwrap()
                .as_str(),
            "奇幻異能"
        );
        let eps: Vec<(i64, String, bool, i64)> = ep_anchor_re()
            .captures_iter(SERIES_HTML)
            .map(|c| {
                (
                    c[1].parse::<i64>().unwrap(),
                    c[2].trim().to_string(),
                    c[3].contains("免费"),
                    c[4].parse::<i64>().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            eps,
            vec![
                (1, "夜里的救援".to_string(), true, 3),
                (2, "失去记忆的人".to_string(), true, 2),
                (3, "阿末留了下来".to_string(), false, 2),
            ]
        );
    }

    #[test]
    fn play_src_from_free_episode() {
        let src = video_src_re()
            .captures(EP1_HTML)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap();
        assert_eq!(src, "https://hongluo.co/api/seo-video/ep_zyb0082_01.mp4");
        let fallback = content_url_re()
            .captures(EP1_HTML)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap();
        assert_eq!(fallback, src);
    }

    #[test]
    fn play_src_absent_on_paid_episode() {
        assert!(video_src_re().captures(EP3_HTML).is_none());
        assert!(content_url_re().captures(EP3_HTML).is_none());
    }

    #[test]
    fn abs_and_cover_urls() {
        assert_eq!(
            abs_url("/api/assets/posters%2Fx.jpg?v=1"),
            "https://hongluo.co/api/assets/posters%2Fx.jpg?v=1"
        );
        assert_eq!(
            cover_of("/api/assets/posters%2Fx.jpg?v=1"),
            "https://hongluo.co/api/assets/posters%2Fx.jpg?v=1&w=240"
        );
        assert_eq!(abs_url(""), "");
        let _ = arr_of(&json!([1, 2]));
    }
}
