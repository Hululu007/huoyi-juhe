//! 九色：核心里的影视区站点。
//!
//! 清单名“母子艹乱伦”只是入口标签，入口 yhl88.cyou/aaa.html 是
//! 伪装落地页（假标题“散文随笔”，按钮 goUrl() 跳转），实站为
//! jiusequ.cyou，站名九色。与站导航 1:1（8 项）：/list/?<n>.html
//!（1 日韩精品、2 欧美成人、3 自拍偷拍、4 成人动漫、25 AI换脸、
//! 26 巨乳尤物、27 学生空姐、28 吃瓜黑料）；每页约 50 条，翻页
//! /list/?<n>-<页>.html。视频 /detail/?<n>.html，播放页
//! /video/?<n>-<源>-<集>.html 里 `var now="...m3u8"`（主清单
//! 200、变体清单 200 METHOD=NONE、首分片 200）。搜索
//! /search.php?searchword=。写源照站原样写，不按站名/分类名/标题
//! 删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://jiusequ.cyou";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("1", "日韩精品"),
    ("2", "欧美成人"),
    ("3", "自拍偷拍"),
    ("4", "成人动漫"),
    ("25", "AI换脸"),
    ("26", "巨乳尤物"),
    ("27", "学生空姐"),
    ("28", "吃瓜黑料"),
];

/// 带重试的 GET：站间歇超时，最多试 3 次，每次间隔 2 秒。
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
        return Err(ApiError::Internal(format!("九色请求 HTTP {status}")));
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
}

fn strip_tags(s: &str) -> String {
    let re = Regex::new(r"<[^>]+>").unwrap();
    re.replace_all(s, "").trim().to_string()
}

/// 卡片解析：`<a href="/detail/?<n>.html" class="myui-vodlist__thumb"`
/// + title 属性（标题）+ style 里 background url（封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/detail/\?(\d+)\.html" class="myui-vodlist__thumb" title="([^"]+)"[^>]*style="background:\s*url\(([^)]+)\);"#,
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

/// 分类解析：导航 /list/?<n>.html 锚点（首页带 ../ 前缀），按站内
/// 顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="(?:\.\./|/)?list/\?(\d+)\.html"[^>]*>([^<]+)</a>"#) {
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
        format!("{BASE}/list/?{category_id}.html")
    } else {
        format!("{BASE}/list/?{category_id}-{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more =
        !items.is_empty() && html.contains(&format!("/list/?{category_id}-{}.html", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 `var now="...m3u8"`。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"var now="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => cap[1].trim().to_string(),
        None => String::new(),
    }
}

/// 详情页播放线路：`<a href="/video/?<n>-<源>-<集>.html">集名</a>`。
fn parse_play_link(html: &str) -> (String, String) {
    let re = match Regex::new(r#"<a[^>]*href="(/video/\?(\d+-\d+-\d+)\.html)"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return (String::new(), String::new()),
    };
    match re.captures(html) {
        Some(cap) => (cap[1].to_string(), unescape(cap[3].trim())),
        None => (String::new(), String::new()),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id.strip_prefix("detail/?").unwrap_or(id);
    let id = id.strip_suffix(".html").unwrap_or(id);
    let url = format!("{BASE}/detail/?{id}.html");
    let html = get_text(&url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(&strip_tags(&m[1])))
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
    let desc_re = Regex::new(r"(?s)剧情介绍</h3>.*?<div[^>]*>(.*?)</div>").ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(&strip_tags(&m[1])))
            .unwrap_or_default(),
        None => String::new(),
    };
    let (play_link, ep_name) = parse_play_link(&html);
    if title.is_empty() || play_link.is_empty() {
        return Err(ApiError::Internal("九色未返回播放线路".into()));
    }
    let play_html = get_text(&format!("{BASE}{play_link}")).await?;
    let m3u8 = parse_play_url(&play_html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("九色未返回可播放地址".into()));
    }
    let ep_title = if ep_name.is_empty() {
        "播放".to_string()
    } else {
        ep_name
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": [episode_json(&m3u8, &ep_title, series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("九色该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search.php"), &[("searchword", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="myui-vodlist__box"><a href="/detail/?2326.html" class="myui-vodlist__thumb" title="GVG-974 ボイン大好きしょう太くんのHなイタズラ 森本亞美 原田千晶" style="background: url(https://2607.xbv2026.com/20260820/qAypRg2h/1.jpg);"><span class="play hidden-xs"></span></a><div class="myui-vodlist__detail"><h4 class="title text-overflow"><a href="/detail/?2326.html" class="text-fff" title="GVG-974 ボイン大好きしょう太くんのHなイタズラ 森本亞美 原田千晶">GVG-974 ボイン大好きしょう太くんのHなイタズラ 森本亞美 原田千晶</a></h4></div></div><div class="myui-vodlist__box"><a href="/detail/?2326.html" class="myui-vodlist__thumb" title="重复" style="background: url(https://2607.xbv2026.com/x.jpg);"></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2326");
        assert_eq!(
            items[0]["title"],
            "GVG-974 ボイン大好きしょう太くんのHなイタズラ 森本亞美 原田千晶"
        );
        assert_eq!(
            items[0]["cover"],
            "https://2607.xbv2026.com/20260820/qAypRg2h/1.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="../list/?1.html">日韩精品</a><a href="../list/?2.html">欧美成人</a><a href="../list/?1.html">日韩精品</a><a href="/list/?25.html">AI换脸</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[2]["name"], "AI换脸");
    }

    #[test]
    fn fallback_has_8_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 8);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[7]["name"], "吃瓜黑料");
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#"<script>var vid="1";var vfrom="0";var vpart="0";var now="https://2607.xbv2026.com/20260818/qTwcTNim/index.m3u8";var pn="s8m3u8";</script>"#;
        assert_eq!(
            parse_play_url(html),
            "https://2607.xbv2026.com/20260818/qTwcTNim/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_play_link_real_markup() {
        let html = r#"<ul class="myui-content__list sort-list clearfix"><li id="00"><a title="HD" href="/video/?1-0-0.html" target="_self">HD</a></li></ul>"#;
        let (link, name) = parse_play_link(html);
        assert_eq!(link, "/video/?1-0-0.html");
        assert_eq!(name, "HD");
        assert_eq!(
            parse_play_link("<div>no link</div>"),
            (String::new(), String::new())
        );
    }

    #[test]
    fn strip_tags_h1() {
        assert_eq!(
            strip_tags("SNOS-357 川越仁子 <font style=\"color:#f1225a;font-size:15px;\"></font>"),
            "SNOS-357 川越仁子"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://2607.xbv2026.com/20260818/qTwcTNim/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://2607.xbv2026.com/20260818/qTwcTNim/index.m3u8"
        );
        assert!(play_check("1").is_err());
    }
}
