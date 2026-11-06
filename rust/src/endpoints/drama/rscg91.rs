//! 91人兽吃瓜：核心里的影视区站点。
//!
//! 入口 www.plmmttv7y7m.com/放松身心/ 是跳转页（JS 拼出去），实站
//! 在轮换镜像域名上，2026-11-05 实测落点为
//! jcyh-gvz-nigo.obbplmm26y102.cc，首页路径 /mmmm/。与已有站
//! 91成人（chengren91）不是同站：基址不同、分类树不同（本
//! 站 71 个叶子分类挂在 200/300/400/500 四个父分类下；91成
//! 人 63 个分类）、列表走 /vodtype/（91成人走 /show/）、
//! 详情 id 段不同（本处 201xxx，91成人 935xxx）。
//! - 分类 71 个叶子分类，与首页分类墙 1:1（站导航顶栏只列 4
//!   个父分类：300 黑料精品、400 热播片库、200 特色仓库、
//!   500 精品资源）。
//! - 目录：/vodtype/<id>/，翻页 /vodtype/<id>-<n>.html，每页
//!   12 条；卡片标题在 title 属性、封面在 data-original、
//!   备注在 pic-text-top。
//! - 详情：/voddetail/<id>/，标题 h1、封面为
//!   stui-content__thumb 的 data-original、类型/地区/年份/
//!   主演/导演在 p.data、简介在 .desc.detail；单集，
//!   播放入口 /vodplay/<id>-1-1/。
//! - 取流：/vodplay/<id>-1-1/ 页内 player_aaaa JSON 的 url
//!   字段即 m3u8（实测 201000：lsbbf11.com 主清单 200，变体
//!   清单 200、METHOD=NONE、首分片可取）；站间歇回空响应，
//!   属抖动，重试即通。
//! - 搜索：/vodsearch/<词>-------------/，实测“美女”第 1 页
//!   12 条。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://jcyh-gvz-nigo.obbplmm26y102.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页分类墙叶子分类，站内顺序，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("307", "童颜巨乳"),
    ("305", "日本无码"),
    ("306", "中文字幕"),
    ("301", "精品推荐"),
    ("315", "日本片商"),
    ("313", "丝袜OL"),
    ("314", "自拍偷拍"),
    ("312", "卡通动漫"),
    ("311", "三级伦理"),
    ("309", "强奸乱伦"),
    ("308", "性感人妻"),
    ("302", "国产精品"),
    ("317", "网曝系列"),
    ("318", "麻豆传媒"),
    ("304", "日本有码"),
    ("320", "国产乱伦"),
    ("324", "探花嫖娼"),
    ("323", "国产人妻"),
    ("321", "国产丝袜"),
    ("303", "主播秀色"),
    ("401", "AV解说"),
    ("402", "cosplay"),
    ("413", "抖阴视频"),
    ("412", "门事件"),
    ("411", "素人搭讪"),
    ("410", "国产传媒"),
    ("409", "VR视角"),
    ("408", "三级伦理"),
    ("407", "探花系列"),
    ("406", "网红主播"),
    ("405", "激情动漫"),
    ("404", "自拍偷拍"),
    ("403", "SWAG"),
    ("201", "国产视频"),
    ("202", "中文字幕"),
    ("203", "国产传媒"),
    ("204", "日本有码"),
    ("205", "日本无码"),
    ("206", "欧美无码"),
    ("207", "强奸乱伦"),
    ("208", "制服诱惑"),
    ("209", "国产主播"),
    ("210", "激情动漫"),
    ("211", "明星换脸"),
    ("212", "抖阴视频"),
    ("213", "女优明星"),
    ("214", "网曝黑料"),
    ("215", "伦理三级"),
    ("216", "AV解说"),
    ("217", "SM调教"),
    ("218", "萝莉少女"),
    ("221", "网红头条"),
    ("224", "VR视角"),
    ("520", "女同性恋"),
    ("521", "VR视角"),
    ("518", "剧情动漫"),
    ("519", "SM调教"),
    ("516", "重口激情"),
    ("517", "三级伦理"),
    ("514", "女优明星"),
    ("511", "AV解说"),
    ("513", "强奸乱伦"),
    ("510", "中文字幕"),
    ("509", "日韩无码"),
    ("506", "抖阴短片"),
    ("507", "传媒剧情"),
    ("504", "偷拍偷窥"),
    ("505", "网曝吃瓜"),
    ("501", "国产自拍"),
    ("502", "主播诱惑"),
    ("503", "探花约炮"),
];

/// 带重试的 GET：站间歇回空响应，最多试 3 次，每次间隔 2 秒。
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
        .header("Referer", format!("{BASE}/mmmm/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("91人兽吃瓜请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("91人兽吃瓜返回空响应".into()));
    }
    Ok(text)
}

fn unescape(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("\\/", "/");
    let mut rest = String::new();
    let mut chars = out.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '&' && chars.peek() == Some(&'#') {
            let mut num = String::new();
            chars.next();
            while let Some(&d) = chars.peek() {
                if d.is_ascii_digit() {
                    num.push(d);
                    chars.next();
                } else {
                    break;
                }
            }
            if chars.peek() == Some(&';') {
                chars.next();
            }
            if let Ok(n) = num.parse::<u32>() {
                if let Some(ch) = char::from_u32(n) {
                    rest.push(ch);
                    continue;
                }
            }
            rest.push('&');
            rest.push('#');
            rest.push_str(&num);
        } else {
            rest.push(c);
        }
    }
    out = rest;
    out
}

/// 卡片解析：详情锚点的 title 属性（标题）+ data-original（封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/voddetail/(\d+)/" title="([^"]+)" data-original="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let remark_re = Regex::new(r#"pic-text-top[^>]*>([^<]+)<"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[2].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[3].trim().to_string();
        let tail = &html[cap.get(0).map(|m| m.end()).unwrap_or(0)..];
        let window = tail.get(..1500).unwrap_or(tail);
        let remark = match &remark_re {
            Some(re) => re
                .captures(window)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 分类解析：首页分类墙 grid-item 的 /vodtype/<id>/ + title 属性。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/vodtype/(\d+)/" title="([^"]+)""#) {
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

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/mmmm/")).await {
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
        format!("{BASE}/vodtype/{category_id}/")
    } else {
        format!("{BASE}/vodtype/{category_id}-{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/vodtype/{category_id}-{}.html", page + 1)) || items.len() >= 12
    };
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

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/voddetail/")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{BASE}/voddetail/{id}/")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"(?s)stui-content__thumb.*?<img[^>]*data-original="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"(?s)<span class="left">简介：(.*?)</span>"#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let data_re = Regex::new(r#"(?s)<p class="data">(.*?)</p>"#).ok();
    let mut genre = String::new();
    if let Some(re) = &data_re {
        for cap in re.captures_iter(&html) {
            let line = unescape(cap[1].trim());
            if line.starts_with("类型：") {
                genre = line.trim_start_matches("类型：").to_string();
                break;
            }
        }
    }
    if title.is_empty() {
        return Err(ApiError::Internal("91人兽吃瓜详情未返回标题".into()));
    }
    let ep_id = format!("{id}-1-1");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&ep_id, "立即播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id
        .trim()
        .trim_start_matches("/vodplay/")
        .trim_end_matches('/');
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let html = get_text(&format!("{BASE}/vodplay/{vid}/")).await?;
    let stream = parse_player_url(&html);
    if stream.is_empty() {
        return Err(ApiError::Internal("91人兽吃瓜未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{BASE}/vodsearch/{enc}-------------/");
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unescape_numeric_entities() {
        assert_eq!(unescape("&#72;&#79;&#87;&#89;"), "HOWY");
        assert_eq!(unescape("A &amp; B"), "A & B");
        assert_eq!(unescape("&#27599;&#26085;"), "每日");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/voddetail/201012/" title="HOWY-009最后的家族旅行被浴衣姿态大姐迷住…中出做爱的两天一夜h.m.p宫西くるみ" data-original="https://sbzytpimg11.com/upload/vod/20261104-1/e883d50b9f0bd81d36b4c78c76d093cd.jpg"> <span class="play hidden-xs"></span> <span class="pic-text text-right">2026-11-05</span> <span class="pic-text-top text-right">日本片商</span> </a> <div class="stui-vodlist__detail"> <h4 class="title text-overflow"><a href="/voddetail/201012/" title="HOWY-009最后的家族旅行被浴衣姿态大姐迷住…中出做爱的两天一夜h.m.p宫西くるみ" data-original="https://sbzytpimg11.com/upload/vod/20261104-1/e883d50b9f0bd81d36b4c78c76d093cd.jpg">"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "201012");
        assert!(items[0]["title"].as_str().unwrap().starts_with("HOWY-009"));
        assert_eq!(
            items[0]["cover"],
            "https://sbzytpimg11.com/upload/vod/20261104-1/e883d50b9f0bd81d36b4c78c76d093cd.jpg"
        );
        assert_eq!(items[0]["remark"], "日本片商");
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/vodtype/307/" title="童颜巨乳">童颜巨乳</a><a href="/vodtype/305/" title="日本无码">日本无码</a><a href="/vodtype/307/" title="童颜巨乳">童颜巨乳</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "307");
        assert_eq!(list[1]["name"], "日本无码");
    }

    #[test]
    fn fallback_has_71_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 71);
        assert_eq!(list[0]["id"], "307");
        assert_eq!(list[70]["id"], "503");
        assert_eq!(list[70]["name"], "探花约炮");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/201000-1-1\/","link_next":"","link_pre":"","url":"https:\/\/lsbbf11.com\/20261103\/Th8GuCIF\/index.m3u8","url_next":"","from":"ytm3u8","server":"no","note":"","id":"201000","sid":1,"nid":1}"#;
        assert_eq!(
            parse_player_url(html),
            "https://lsbbf11.com/20261103/Th8GuCIF/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            format!("{BASE}/vodtype/{}/", "307"),
            "https://jcyh-gvz-nigo.obbplmm26y102.cc/vodtype/307/"
        );
        assert_eq!(
            format!("{BASE}/vodtype/{}-{}.html", "307", 2),
            "https://jcyh-gvz-nigo.obbplmm26y102.cc/vodtype/307-2.html"
        );
    }
}
