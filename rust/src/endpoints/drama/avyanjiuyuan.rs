//! AV研究院：核心里的影视区站点。
//!
//! 与站导航 1:1（15 项）：亚洲情色、国产主播、国产自拍、无码专区、欧美性爱、
//! 熟女人妻、强奸乱伦、巨乳美乳、中文字幕、制服诱惑、女同性恋、卡通动画、
//! 视频伦理、少女萝莉、重口色情，每页 16 条；卡片为 stui 模板
//! `<a class="stui-vodlist__thumb" href="/index.php/vod/play/id/<id>/sid/1/nid/1.html"
//! title="标题" data-original="封面">`；详情路由为空体，详情直接取播放页；
//! 取流为 MacCMS player_aaaa 的 m3u8（主清单 200、变体清单 3375kb 200、
//! 1149 分片、首分片 Range 206、METHOD=NONE、首字节 0x47）；trysee=0、
//! points=0，全站免费无 VIP 墙；搜索 GET /index.php/vod/search.html?wd=。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://avyan2026.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("52", "亚洲情色"),
    ("53", "国产主播"),
    ("54", "国产自拍"),
    ("55", "无码专区"),
    ("56", "欧美性爱"),
    ("57", "熟女人妻"),
    ("58", "强奸乱伦"),
    ("59", "巨乳美乳"),
    ("60", "中文字幕"),
    ("61", "制服诱惑"),
    ("62", "女同性恋"),
    ("63", "卡通动画"),
    ("64", "视频伦理"),
    ("65", "少女萝莉"),
    ("66", "重口色情"),
];

/// 带重试的 GET：本机出口偶发超时/断连，最多试 3 次，每次间隔 1 秒。
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
        .header("Referer", BASE)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("AV研究院请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("AV研究院返回空体".into()));
    }
    Ok(text)
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

/// 卡片解析：stui 模板的图链锚点自带 title 与 data-original（封面）；
/// 文链锚点无 data-original，天然跳过；按 id 去重。
fn parse_cards(html: &str) -> Vec<Value> {
    let anchor_re = match Regex::new(
        r#"<a[^>]*href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let title_re = Regex::new(r#"title="([^"]+)""#).ok();
    let cover_re = Regex::new(r#"data-original="([^"]+)""#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in anchor_re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let tag = &cap[0];
        let title = match &title_re {
            Some(re) => re
                .captures(tag)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        let cover = match &cover_re {
            Some(re) => re.captures(tag).map(|m| fix_url(&m[1])).unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() || cover.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页导航锚点（内文非空、非“更多”），按站内顺序、id 去重。
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
        if name.is_empty() || name == "更多" || !seen.insert(id.clone()) {
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

fn catalog_url(category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = get_text(&catalog_url(category_id, page)).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!(
            "/index.php/vod/type/id/{category_id}/page/{}.html",
            page + 1
        ))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放器 JSON：播放页 `var player_aaaa={...}</script>`，\u 转义由 serde 解码。
fn parse_player(html: &str) -> Option<Value> {
    let re = Regex::new(r"(?s)var player_aaaa=(\{.*?\})\s*</script>").ok()?;
    let cap = re.captures(html)?;
    serde_json::from_str(&cap[1]).ok()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id.strip_prefix("index.php/vod/play/id/").unwrap_or(id);
    let id = id.split('/').next().unwrap_or(id);
    let url = format!("{BASE}/index.php/vod/play/id/{id}/sid/1/nid/1.html");
    let html = get_text(&url).await?;
    let player =
        parse_player(&html).ok_or_else(|| ApiError::Internal("AV研究院未返回播放器数据".into()))?;
    let title = text_of(&player["vod_data"], &["vod_name"]);
    let m3u8 = text_of(&player, &["url"]);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("AV研究院未返回可播放地址".into()));
    }
    let genre = text_of(&player["vod_data"], &["vod_class"]);
    let cover_re = Regex::new(r#"data-original="([^"]+)""#).ok();
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
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("AV研究院该集没有播放地址".into()))
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
            fix_url("/template/avyjy/statics/logo.png"),
            "https://avyan2026.lol/template/avyjy/statics/logo.png"
        );
        assert_eq!(
            fix_url("https://2609.lbsl2026.com/20261103/RtNaQbKy/index.m3u8"),
            "https://2609.lbsl2026.com/20261103/RtNaQbKy/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<li><div class="stui-vodlist__box"><a class="stui-vodlist__thumb lazyload" href="/index.php/vod/play/id/195985/sid/1/nid/1.html" title="FNS-116 巨乳女学生被补习班老师狂干到沦陷，浅野心爱骚穴内射合集" data-original="https://1028.lbp261028.top/upload/vod/20261104-1/08124daf64f20641e31d5a71c6ef9d65.jpg"><span class="play hidden-xs"></span><span class="pic-text text-right">2026/11/05</span></a><div class="stui-vodlist__detail"><h4 class="title text-overflow"><a href="/index.php/vod/play/id/195985/sid/1/nid/1.html" title="FNS-116 巨乳女学生被补习班老师狂干到沦陷，浅野心爱骚穴内射合集">FNS-116</a></h4></div></div></li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "195985");
        assert_eq!(
            items[0]["title"],
            "FNS-116 巨乳女学生被补习班老师狂干到沦陷，浅野心爱骚穴内射合集"
        );
        assert_eq!(
            items[0]["cover"],
            "https://1028.lbp261028.top/upload/vod/20261104-1/08124daf64f20641e31d5a71c6ef9d65.jpg"
        );
    }

    #[test]
    fn parse_categories_nav() {
        let html = r#"<a href="/index.php/vod/type/id/52.html">亚洲情色</a><a href="/index.php/vod/type/id/53.html">国产主播</a><a href="/index.php/vod/type/id/54.html">国产自拍</a><a href="/index.php/vod/type/id/55.html">无码专区</a><a href="/index.php/vod/type/id/55.html">更多</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "52");
        assert_eq!(list[3]["name"], "无码专区");
    }

    #[test]
    fn fallback_has_15_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 15);
        assert_eq!(list[0]["name"], "亚洲情色");
        assert_eq!(list[14]["id"], "66");
        assert_eq!(list[14]["name"], "重口色情");
    }

    #[test]
    fn parse_player_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/195871\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"05052501 \u68ee\u4f18\u5948\u6781\u54c1\u5ae9\u7a74\u7206\u64cd\u5b9e\u6d4b\uff0c\u5929\u7136\u5c11\u5973\u6deb\u8361\u7b11\u5bb9\u5185\u5c04\u989c\u5c04","vod_actor":"","vod_director":"","vod_class":"\u65e0\u7801\u4e13\u533a"},"url":"https:\/\/2609.lbsl2026.com\/20261103\/RtNaQbKy\/index.m3u8","url_next":"","from":"lbm3u8","server":"","note":"","id":"195871","sid":1,"nid":1}</script>"#;
        let player = parse_player(html).expect("player json");
        assert_eq!(
            text_of(&player, &["url"]),
            "https://2609.lbsl2026.com/20261103/RtNaQbKy/index.m3u8"
        );
        assert_eq!(
            text_of(&player["vod_data"], &["vod_name"]),
            "05052501 森优奈极品嫩穴爆操实测，天然少女淫荡笑容内射颜射"
        );
        assert_eq!(text_of(&player["vod_data"], &["vod_class"]), "无码专区");
        assert_eq!(player["trysee"].as_i64(), Some(0));
        assert_eq!(player["points"].as_i64(), Some(0));
        assert!(parse_player("<div>no player</div>").is_none());
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            catalog_url("52", 1),
            "https://avyan2026.lol/index.php/vod/type/id/52.html"
        );
        assert_eq!(
            catalog_url("66", 2),
            "https://avyan2026.lol/index.php/vod/type/id/66/page/2.html"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://2609.lbsl2026.com/20261103/RtNaQbKy/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://2609.lbsl2026.com/20261103/RtNaQbKy/index.m3u8"
        );
        assert!(play_check("195871").is_err());
    }

    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert!(!list.is_empty(), "avyanjiuyuan categories empty");
        let r = catalog("52", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE avyanjiuyuan cats={} cat52_items={}",
            list.len(),
            items.len()
        );
        assert!(!items.is_empty(), "avyanjiuyuan cat 52 catalog empty");
        assert!(!items[0]["id"].as_str().unwrap_or("").is_empty());
        assert!(!items[0]["title"].as_str().unwrap_or("").is_empty());
    }
}
