//! 顶级AI色库：核心里的影视区站点。
//!
//! MacCMS 站（stui 模板，站根路径，无 /a/ 或 /rukou/ 前缀）
//! /vodtype/<n>/、/voddetail/<id>/、/vodplay/<id>-1-1/、
//! /vodsearch/<词>-------------/、/topic/（人气排行 TOP300）。
//! 分类与站导航 1:1（4 个父组）：200 特色仓库、300 黑料精品、
//! 400 热播片库、500 精品资源（各组下另有子分类 201-224、
//! 301-324、401-413、501-521，作子标签不取）；分页形如
//! /vodtype/200-2/（页码在 type id 后用 - 分隔，页标题恒写
//! “第1页”是站内惯例，以实际 id 是否不同为准）；卡片为
//! stui-vodlist__thumb（标题 title 属性、封面 data-original，
//! 标题常为 &#NN; 数字实体须解码）；详情页 h1 为标题、
//! stui-content__thumb 为封面、play-btn 为单集播放链；
//! 取流为播放页 player_aaaa 的 m3u8（主清单 200、变体
//! 200、METHOD=NONE、首分片 200，无需特殊头）；
//! 搜索 /vodsearch/<词>-------------/。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASES: &[&str] = &["https://yxql-imh-nh4d.taoquan26s111.cc"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("200", "特色仓库"),
    ("300", "黑料精品"),
    ("400", "热播片库"),
    ("500", "精品资源"),
];

async fn get_text(path: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for base in BASES {
        let url = format!("{base}{path}");
        for _ in 0..3 {
            match fetch_once(&url).await {
                Ok(text) => return Ok(text),
                Err(e) => {
                    last_err = e.to_string();
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
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
        return Err(ApiError::Internal(format!("顶级AI色库请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 地址归一：站内相对路径补主站基址，协议相对补 https。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{}{u}", BASES[0]);
    }
    u.to_string()
}

/// HTML 实体解码：本站标题常用 &#NN; 十进制与 &#xNN; 十六进制
/// 数字实体（如 &#72;&#79;&#68;&#86; = HODV），另处理常见具名实体。
fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find("&#") {
        out.push_str(&rest[..pos]);
        let tail = &rest[pos + 2..];
        if let Some(semi) = tail.find(';') {
            let code = &tail[..semi];
            let ch = if let Some(hex) = code.strip_prefix('x').or_else(|| code.strip_prefix('X')) {
                u32::from_str_radix(hex, 16).ok().and_then(char::from_u32)
            } else {
                code.parse::<u32>().ok().and_then(char::from_u32)
            };
            match ch {
                Some(c) => out.push(c),
                None => out.push_str(&format!("&#{code};")),
            }
            rest = &tail[semi + 1..];
        } else {
            out.push_str(&rest[pos..]);
            rest = "";
            break;
        }
    }
    out.push_str(rest);
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：stui-vodlist__thumb 锚点（vodplay id + title +
/// data-original 封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"<a class="stui-vodlist__thumb[^"]*" href="/vodplay/(\d+)-1-1/" title="([^"]*)" data-original="([^"]*)""#,
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
        let title = decode_entities(cap[2].trim());
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[3]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：导航里 id 以 00 结尾的父组锚点（200/300/400/500），
/// 子分类（201/202…）不取。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"<a[^>]*href="/vodtype/(\d+)/"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        if !id.ends_with("00") {
            continue;
        }
        let name = decode_entities(cap[2].trim());
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
    match get_text("/").await {
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
    let path = format!("/vodtype/{category_id}-{page}/");
    let html = get_text(&path).await?;
    let items = parse_cards(&html);
    let has_more =
        !items.is_empty() && html.contains(&format!("/vodtype/{category_id}-{}", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 player_aaaa JSON 的 url 字段（m3u8）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => decode_entities(&cap[1]),
        None => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let html = get_text(&format!("/voddetail/{id}/")).await?;
    let title_re = Regex::new(r#"(?s)<h1 class="title">([^<]+)</h1>"#).ok();
    let title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| decode_entities(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re =
        Regex::new(r#"(?s)<div class="stui-content__thumb">.*?<img[^>]+data-original="([^"]+)""#)
            .ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re =
        Regex::new(r#"(?s)<p class="desc detail">.*?<span class="left">简介：(.*?)</span>"#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| decode_entities(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let play_re = Regex::new(r#"<div class="play-btn">\s*<a href="(/vodplay/\d+-1-1/)">"#).ok();
    let mut episodes = Vec::new();
    if let Some(re) = &play_re {
        if let Some(cap) = re.captures(&html) {
            episodes.push(episode_json(&fix_url(&cap[1]), "第1集", series_id));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(
            &format!("{}/vodplay/{id}-1-1/", BASES[0]),
            "第1集",
            series_id,
        ));
    }
    if title.is_empty() {
        return Err(ApiError::Internal("顶级AI色库未返回标题".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        fix_url(video_id)
    };
    if !url.contains("/vodplay/") {
        if url.starts_with("http") && url.ends_with(".m3u8") {
            return Ok(json!({"url": url}));
        }
        return Err(ApiError::Internal("顶级AI色库该集没有播放地址".into()));
    }
    let path = match url.find("/vodplay/") {
        Some(pos) => url[pos..].to_string(),
        None => url.clone(),
    };
    let html = get_text(&path).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("顶级AI色库未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    let html = get_text(&format!("/vodsearch/{encoded}-------------/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_entities_real_markup() {
        assert_eq!(decode_entities("&#72;&#79;&#68;&#86;-22019"), "HODV-22019");
        assert_eq!(
            decode_entities("&#24040;&#20083;&#23273;&#22971;"),
            "巨乳嫩妻"
        );
        assert_eq!(decode_entities("&#x4E2D;&#x6587;"), "中文");
        assert_eq!(decode_entities("a &amp; b"), "a & b");
        assert_eq!(decode_entities("plain"), "plain");
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/voddetail/201527/"),
            "https://yxql-imh-nh4d.taoquan26s111.cc/voddetail/201527/"
        );
        assert_eq!(
            fix_url("https://lsbbf11.com/20261103/13Yl7EeW/index.m3u8"),
            "https://lsbbf11.com/20261103/13Yl7EeW/index.m3u8"
        );
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="stui-vodlist__thumb lazyload" href="/vodplay/201515-1-1/" title="&#72;&#79;&#68;&#86;-22019&#31361;&#30772;&#26497;&#38480;&#30340;&#34987;&#24178;&#24895;&#26395;&#65281;&#65281;&#65281;&#20154;&#22971;&#30340;&#23617;&#32929;&#35825;&#24785;&#104;&#46;&#109;&#46;&#112;&#27801;&#26376;&#12405;&#12415;&#12398;" data-original="https://sbzytpimg11.com/upload/vod/20261104-1/1641edcc74937157af4cf62b7b0d140e.jpg">"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "201515");
        assert_eq!(
            items[0]["title"],
            "HODV-22019突破极限的被干愿望！！！人妻的屁股诱惑h.m.p沙月ふみの"
        );
        assert_eq!(
            items[0]["cover"],
            "https://sbzytpimg11.com/upload/vod/20261104-1/1641edcc74937157af4cf62b7b0d140e.jpg"
        );
    }

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<a href="/vodtype/200/">特色仓库</a><a href="/vodtype/201/">国产视频</a><a href="/vodtype/300/">黑料精品</a><a href="/vodtype/200/">更多</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "200");
        assert_eq!(list[0]["name"], "特色仓库");
        assert_eq!(list[1]["name"], "黑料精品");
    }

    #[test]
    fn fallback_has_4_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["name"], "特色仓库");
        assert_eq!(list[3]["name"], "精品资源");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/201527-1-1\/","link_next":"","link_pre":"","url":"https:\/\/lsbbf11.com\/20261103\/13Yl7EeW\/index.m3u8","url_next":"","from":"ytm3u8","server":"no","note":"","id":"201527","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://lsbbf11.com/20261103/13Yl7EeW/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn search_url_encoding() {
        let encoded: String = url::form_urlencoded::byte_serialize("原味".as_bytes()).collect();
        assert_eq!(encoded, "%E5%8E%9F%E5%91%B3");
    }
}
