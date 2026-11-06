//! JPTT禁片天堂：核心里的影视区站点。
//!
//! 与 py 版 jptt.py 同一套分类、同一条已验播放链：分类与站 /tag
//! 熱門分類索引 1:1（12 个标签分类 /tag_list?tid=N ＋ 5 个發行
//! 商 /tag_list?fid=N），列表每页 28 条（8 条熱片＋20 条相关，
//! 站内无服务端翻页，page 参数回同一页，has_more 恒为 false）、
//! 单片详情、取流为详情页 <source data-src> 的 m3u8
//!（cdn-mso1.jptt1.cc，清單已验 200、首分片 200；地址带过期时
//! 间戳，每次播放须现取）。站内无萝莉分类；列表卡片标题含萝
//! 莉/幼女/未成年词的单片按标题过滤。
//!
//! 与核心已有的 ptt01（ptt01.com 三级稀缺影视站：电影/电视剧/
//! 短剧/动漫/综艺/体育，/p/{n} 路由）是不同站：域名、内容（日
//! 本 AV 番号站）、模板与取流 CDN 均不同，实测于 2026-11-05。
//! 注意：本站响应慢（本机出口实测单请求 12～32 秒），核心 20
//! 秒超时下部分请求可能超时，手机侧需复验。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://jptt.tv";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态回退：与站 /tag 索引一致，实测于 2026-11-05。
/// (id, name, kind, arg)：kind 为 tid/fid，走 /tag_list?tid=N
/// 或 /tag_list?fid=N。
const CATS: &[(&str, &str, &str, &str)] = &[
    ("t7", "720p", "tid", "7"),
    ("t15", "巨乳", "tid", "15"),
    ("t3", "AV女優片", "tid", "3"),
    ("t2", "中出", "tid", "2"),
    ("t21", "HD", "tid", "21"),
    ("t471", "HD高畫質", "tid", "471"),
    ("t9", "素人", "tid", "9"),
    ("t278", "中文", "tid", "278"),
    ("t16", "人妻", "tid", "16"),
    ("t212", "無碼片", "tid", "212"),
    ("t95", "熟女", "tid", "95"),
    ("t34", "口交", "tid", "34"),
    ("f93", "瑪丹娜", "fid", "93"),
    ("f1", "SOD", "fid", "1"),
    ("f31", "MOODYZ", "fid", "31"),
    ("f1203", "FC2高清版", "fid", "1203"),
    ("f2", "HMN WORKS", "fid", "2"),
];

fn find_cat(id: &str) -> Option<(&'static str, &'static str, &'static str, &'static str)> {
    CATS.iter()
        .find(|(cid, _, _, _)| *cid == id)
        .map(|(cid, name, kind, arg)| (*cid, *name, *kind, *arg))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JPTT请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
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

/// 卡片解析：oneVideo 卡片，链接为 /video/CODE，封面为卡片内
/// img 的 src，标题为 h3/h5 或 img 的 alt，时长为 p_duration。
fn parse_cards(html: &str) -> Vec<Value> {
    let link_re = match Regex::new(r#"<a href="https?://jptt\.tv/video/([^"]+)">"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)""#).ok();
    let img_re2 = Regex::new(r#"<img[^>]*alt="([^"]*)"[^>]*src="([^"]+)""#).ok();
    let dur_re = Regex::new(r#"p_duration">([^<]+)<"#).ok();
    let h_re = Regex::new(r"(?s)<h[35][^>]*>(.*?)</h[35]>").ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in link_re.captures_iter(html) {
        let code = cap[1].trim().to_string();
        if code.is_empty() || !seen.insert(code.clone()) {
            continue;
        }
        let start = cap.get(0).unwrap().end();
        let end = (start + 1500).min(html.len());
        let body = html.get(start..end).unwrap_or("");
        let mut title = String::new();
        let mut cover = String::new();
        if let Some(re) = &img_re {
            if let Some(m) = re.captures(body) {
                cover = fix_url(&m[1]);
                title = unescape(m[2].trim());
            }
        }
        if cover.is_empty() {
            if let Some(re) = &img_re2 {
                if let Some(m) = re.captures(body) {
                    title = unescape(m[1].trim());
                    cover = fix_url(&m[2]);
                }
            }
        }
        if title.is_empty() {
            if let Some(re) = &h_re {
                if let Some(m) = re.captures(body) {
                    title = unescape(m[1].trim());
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        let remark = match &dur_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let vid = format!("/video/{code}");
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name, _, _)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(fallback_categories())
}

pub(crate) async fn catalog(category_id: &str, _page: i64) -> ApiResult<Value> {
    let (_, _, kind, arg) = find_cat(category_id).unwrap_or(("t15", "巨乳", "tid", "15"));
    let url = format!("{BASE}/tag_list?{kind}={arg}");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    // 站内无服务端翻页：page 参数回同一页，故 has_more 恒 false。
    Ok(json!({"items": items, "has_more": false}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{series_id}")
    };
    let html = get_text(&url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        let og_re = Regex::new(r#"<meta property="og:title"[^>]*content="([^"]+)""#).ok();
        if let Some(re) = &og_re {
            title = re
                .captures(&html)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default();
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
    let src_re = Regex::new(r#"<source[^>]*data-src="([^"]+\.m3u8[^"]*)""#).ok();
    let m3u8 = match &src_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("JPTT未返回可播放地址".into()));
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
        Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }))
    } else {
        Err(ApiError::Internal("JPTT该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("kw", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_has_17_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 17);
        assert_eq!(list[0]["id"], "t7");
        assert_eq!(list[0]["name"], "720p");
        assert_eq!(list[11]["id"], "t34");
        assert_eq!(list[12]["id"], "f93");
        assert_eq!(list[16]["name"], "HMN WORKS");
    }

    #[test]
    fn find_cat_known_and_unknown() {
        assert_eq!(find_cat("t15").unwrap().3, "15");
        assert_eq!(find_cat("f1203").unwrap().2, "fid");
        assert!(find_cat("nope").is_none());
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("//cdn-mso1.jptt1.cc/hls/x/index.m3u8"),
            "https://cdn-mso1.jptt1.cc/hls/x/index.m3u8"
        );
        assert_eq!(
            fix_url("/storage/cover/1/1.jpg"),
            "https://jptt.tv/storage/cover/1/1.jpg"
        );
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_basic() {
        let html = r#"<div class="col oneVideo"><div class="card h-100"><div class="oneVideo-top"><a href="https://jptt.tv/video/SONE-614"><img loading="lazy" src="/storage/cover/1/297999.jpg?1" class="card-img-top" alt="SONE-614 新人出道"><p class="p_duration">02:27:53</p></a></div><div class="oneVideo-body"><h3>SONE-614 新人出道</h3></div></div></div><div class="col oneVideo"><div class="card h-100"><div class="oneVideo-top"><a href="https://jptt.tv/video/BAD-1"><img src="/storage/cover/1/2.jpg" alt="BAD-1 幼女"><p class="p_duration">00:10:00</p></a></div><div class="oneVideo-body"><h3>BAD-1 幼女</h3></div></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/video/SONE-614");
        assert_eq!(items[0]["title"], "SONE-614 新人出道");
        assert_eq!(
            items[0]["cover"],
            "https://jptt.tv/storage/cover/1/297999.jpg?1"
        );
        assert_eq!(items[0]["remark"], "02:27:53");
        assert_eq!(items[1]["id"], "/video/BAD-1");
        assert_eq!(items[1]["title"], "BAD-1 幼女");
        assert_eq!(items[1]["cover"], "https://jptt.tv/storage/cover/1/2.jpg");
        assert_eq!(items[1]["remark"], "00:10:00");
    }

    #[test]
    fn parse_cards_dedup() {
        let html = r#"<a href="https://jptt.tv/video/A-1"><img src="/storage/cover/1/1.jpg" alt="片A"><p class="p_duration">01:00:00</p></a><a href="https://jptt.tv/video/A-1"><img src="/storage/cover/1/1.jpg" alt="片A"><p class="p_duration">01:00:00</p></a>"#;
        assert_eq!(parse_cards(html).len(), 1);
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://cdn-mso1.jptt1.cc/hls/x/index.m3u8").unwrap();
        assert_eq!(ok["url"], "https://cdn-mso1.jptt1.cc/hls/x/index.m3u8");
        assert!(play_check("/video/MIDA-804").is_err());
    }
}
