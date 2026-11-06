//! H-短剧：核心里的影视区站点。
//!
//! 入口 https://xiaonver.xyz/tevu/kox.html 301 到实站
//! https://xiaonverjtx.click。与黄.短剧同模板系、不同站（不同
//! 域名、不同视频集）。首页导航 /type/id/<n>.html 共 39 项；
//! 每页 20 条，翻页 /type/id/<n>/<页>.html。卡片
//! `<a href="/info/id/<n>.html" class="video-unit">` + img src
//! 封面 + video-unit__caption 标题。详情 /info/id/<n>.html
//!（h2#pagetitle 标题、播放链接内 img 封面、aria-current 面包屑
//! 为所属分类），播放页 /play/id/<n>.html 内有
//! `var playUrl = '…m3u8'`（另有 JSON-LD contentUrl 兜底）；
//! 主清单 200、变体清单 200 METHOD=NONE、首分片 Range 206。
//! 搜索走 lookup() 跳转的 /lookup/<编码词>.html（表单 action
//! /search 只是幌子，/search?q= 回 404）。写源照站原样写，
//! 不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://xiaonverjtx.click";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("21", "无码专区"),
    ("25", "制服诱惑"),
    ("27", "三级伦理"),
    ("29", "AI换脸"),
    ("30", "中文字幕"),
    ("32", "卡通动漫"),
    ("35", "欧美系列"),
    ("36", "美女主播"),
    ("38", "国产自拍"),
    ("40", "熟女人妻"),
    ("42", "萝莉少女"),
    ("44", "女同性爱"),
    ("46", "多人群交"),
    ("48", "美乳巨乳"),
    ("49", "强奸乱伦"),
    ("50", "抖阴视频"),
    ("51", "韩国主播"),
    ("52", "网红头条"),
    ("53", "网爆黑料"),
    ("54", "欧美无码"),
    ("55", "女优明星"),
    ("56", "SM调教"),
    ("57", "AV解说"),
    ("285", "生活都市"),
    ("286", "不偷恋情"),
    ("287", "学生校园"),
    ("288", "人妻熟女"),
    ("289", "暴力虐待"),
    ("290", "明星偶像"),
    ("291", "玄幻仙侠"),
    ("292", "科学幻想"),
    ("293", "街拍偷拍"),
    ("294", "丝袜美腿"),
    ("295", "欧美风情"),
    ("296", "网友自拍"),
    ("297", "卡通漫画"),
    ("298", "露出激情"),
    ("299", "唯美写真"),
    ("300", "女优情报"),
];

/// 带重试的 GET：站经出口代理较慢，最多试 3 次，每次间隔 2 秒。
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
        return Err(ApiError::Internal(format!("H-短剧请求 HTTP {status}")));
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
        .replace("&nbsp;", " ")
}

/// 分类解析：导航锚点 `href="/type/id/<n>.html">名<`，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/type/id/(\d+)\.html"[^>]*>([^<]+)<"#) {
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

/// 卡片解析：`<a href="/info/id/<n>.html" class="video-unit">` 内
/// img src 封面 + video-unit__caption 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a[^>]*href="/info/id/(\d+)\.html"[^>]*class="video-unit"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<div class="video-unit__caption">\s*(.*?)\s*</div>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[2].trim().to_string();
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page <= 1 {
        format!("{BASE}/type/id/{category_id}.html")
    } else {
        format!("{BASE}/type/id/{category_id}/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more =
        !items.is_empty() && html.contains(&format!("/type/id/{category_id}/{}.html", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 `var playUrl = '…m3u8'`，兜底 JSON-LD contentUrl。
fn parse_play_url(html: &str) -> String {
    let re = Regex::new(r"var playUrl\s*=\s*'([^']+)'").ok();
    if let Some(re) = re {
        if let Some(cap) = re.captures(html) {
            return cap[1].trim().to_string();
        }
    }
    let ld_re = Regex::new(r#""contentUrl":\s*"([^"]+)""#).ok();
    if let Some(re) = ld_re {
        if let Some(cap) = re.captures(html) {
            return cap[1].trim().to_string();
        }
    }
    String::new()
}

fn detail_id(series_id: &str) -> String {
    let s = series_id.trim().trim_start_matches('/');
    let s = s.strip_prefix("info/id/").unwrap_or(s);
    s.trim_end_matches(".html").to_string()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = detail_id(series_id);
    let url = format!("{BASE}/info/id/{id}.html");
    let html = get_text(&url).await?;
    let h2_re = Regex::new(r#"(?s)<h2 id="pagetitle">(.*?)</h2>"#).ok();
    let title = match &h2_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re =
        Regex::new(r#"(?s)<a href="/play/id/\d+\.html"[^>]*><img[^>]*src="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].trim().to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let cat_re =
        Regex::new(r#"aria-current="page"[^>]*href="/type/id/\d+\.html"[^>]*>([^<]+)<"#).ok();
    let genre = match &cat_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
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
    if title.is_empty() {
        return Err(ApiError::Internal("H-短剧详情未返回标题".into()));
    }
    let play_url = format!("{BASE}/play/id/{id}.html");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&play_url, "播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.ends_with(".m3u8") || video_id.ends_with(".mp4") {
        return Ok(json!({"url": video_id}));
    }
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{BASE}/play/id/{}.html", detail_id(video_id))
    };
    let html = get_text(&url).await?;
    let m3u8 = parse_play_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("H-短剧未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let url = format!("{BASE}/lookup/{enc}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<a href="/type/id/21.html" title="无码专区">无码专区</a><a href="/type/id/25.html">制服诱惑</a><a href="/type/id/21.html">无码专区</a><a href="/type/id/27.html">三级伦理</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "21");
        assert_eq!(list[0]["name"], "无码专区");
        assert_eq!(list[2]["id"], "27");
    }

    #[test]
    fn fallback_has_39_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 39);
        assert_eq!(list[0]["id"], "21");
        assert_eq!(list[38]["name"], "女优情报");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="main__ct-item">
<a name="rdmonclick" href="/info/id/3095038.html" target="_blank"
class="video-unit">
<div class="video-unit__pic objectfit">
<img src="https://un.shayu260522.top/upload/vod/20261031-1/2d9bd1c7bf9ee2dc1057ff240722a23b.jpg"
class="lazyload thumb b-error" />
</div>
<div class="video-unit__caption">
DVAJ-709 姐夫夜夜揉奶，人妻静河沦陷内射骚穴
</div>
</a>
</div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "3095038");
        assert_eq!(
            items[0]["title"],
            "DVAJ-709 姐夫夜夜揉奶，人妻静河沦陷内射骚穴"
        );
        assert_eq!(
            items[0]["cover"],
            "https://un.shayu260522.top/upload/vod/20261031-1/2d9bd1c7bf9ee2dc1057ff240722a23b.jpg"
        );
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#"var playUrl = 'https://2609.sysl2026.com/20261030/MkHzjrSa/index.m3u8'; var player = new Aliplayer({"#;
        assert_eq!(
            parse_play_url(html),
            "https://2609.sysl2026.com/20261030/MkHzjrSa/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn detail_id_forms() {
        assert_eq!(detail_id("3095038"), "3095038");
        assert_eq!(detail_id("3095038.html"), "3095038");
        assert_eq!(detail_id("/info/id/3095038.html"), "3095038");
    }
}
