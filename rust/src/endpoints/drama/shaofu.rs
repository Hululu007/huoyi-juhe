//! 少妇·短剧AV：核心里的影视区站点。
//!
//! MacCMS 站。给的地址是 IDN 跳转页
//! https://艾3y力绅.sfdjaaaccc.xyz/心想事成-yng/（xn--
//! 3y-yq5c088nb5d.sfdjaaaccc.xyz），500ms 后 JS 跳到
//! https://www.shaofudj.top/aa/?id=yng；模块直连真站
//! https://www.shaofudj.top/aa。
//! 分类与站首页 1:1（4 个资源区）：玉兔资源（type 1）、
//! 网曝系列（type 10）、番茄资源（type 43）、杏吧资源
//! （type 61）；首页每区只有“更多”链到 type 页，区名取
//! type 页标题（“玉兔资源-第1页-少妇短剧…”）。目录
//! /aa/index.php/vod/type/id/<id>.html，翻页
//! /aa/index.php/vod/type/id/<id>/page/<n>.html，总条数
//! 取页内“找到 N 条”。卡片：play 链 id + img
//! data-original 封面 + h3 video-title 里 <text> 标题。
//! 详情 /aa/index.php/vod/play/id/<id>/sid/1/nid/1.html，
//! player_aaaa 的 url 即直链 m3u8（from s8m3u8），
//! vod_data 有 vod_name/vod_class，简介与封面字段为空。
//! 搜索 /aa/index.php/vod/search.html?wd=<词>。
//! 取流已验：详情《极品网红娜娜》player_aaaa 回
//! https://2608.xbv2608.com/20261010/ub0gL6xB/index.m3u8，
//! 主清单 200（720p 变体），变体清单 200（METHOD=NONE，
//! 16304 字节），首分片 200（TS 同步头）；变体清单与分片
//! 须带 Referer（播放页地址），否则连不上。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://www.shaofudj.top/aa";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站首页一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("1", "玉兔资源"),
    ("10", "网曝系列"),
    ("43", "番茄资源"),
    ("61", "杏吧资源"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("少妇短剧请求失败：{e}")))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("少妇短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(format!("少妇短剧响应读取失败：{e}")))
}

fn unescape(s: &str) -> String {
    let s = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/");
    decode_unicode_escapes(&s)
}

/// 把 JSON 里的 \uXXXX 转义（vod_name 常用）还原成字符，含代理对一并拼回。
fn decode_unicode_escapes(s: &str) -> String {
    if !s.contains("\\u") {
        return s.to_string();
    }
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 5 < bytes.len() && bytes[i + 1] == b'u' {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 2..i + 6]) {
                if let Ok(code) = u32::from_str_radix(hex, 16) {
                    if (0xD800..0xDC00).contains(&code)
                        && i + 11 < bytes.len()
                        && bytes[i + 6] == b'\\'
                        && bytes[i + 7] == b'u'
                    {
                        if let Ok(hex2) = std::str::from_utf8(&bytes[i + 8..i + 12]) {
                            if let Ok(low) = u32::from_str_radix(hex2, 16) {
                                if (0xDC00..0xE000).contains(&low) {
                                    let c = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                                    if let Some(ch) = char::from_u32(c) {
                                        out.push(ch);
                                        i += 12;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                    if let Some(ch) = char::from_u32(code) {
                        out.push(ch);
                        i += 6;
                        continue;
                    }
                }
            }
        }
        let ch_len = utf8_len(bytes[i]);
        let end = (i + ch_len).min(bytes.len());
        out.push_str(&s[i..end]);
        i = end;
    }
    out
}

fn utf8_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b >> 5 == 0b110 {
        2
    } else if b >> 4 == 0b1110 {
        3
    } else {
        4
    }
}

/// 卡片解析：逐 <li> 取 play 链 id、img data-original 封面、
///
/// <h3 class="video-title"> 里 <text> 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for block in html.split("<li>") {
        let id = match Regex::new(r#"vod/play/id/(\d+)/sid/1/nid/1\.html"#)
            .ok()
            .and_then(|re| re.captures(block))
        {
            Some(cap) => cap[1].to_string(),
            None => continue,
        };
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = match Regex::new(r#"data-original="([^"]+)""#)
            .ok()
            .and_then(|re| re.captures(block))
        {
            Some(cap) => unescape(cap[1].trim()),
            None => String::new(),
        };
        let title = match Regex::new(r#"(?s)<h3 class="video-title">.*?<text>([^<]+)</text>"#)
            .ok()
            .and_then(|re| re.captures(block))
        {
            Some(cap) => unescape(cap[1].trim()),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 列表总条数：页内“找到 N 条”。
fn page_total(html: &str) -> i64 {
    match Regex::new(r"找到\s*(\d+)\s*条")
        .ok()
        .and_then(|re| re.captures(html))
    {
        Some(cap) => cap[1].parse::<i64>().unwrap_or(0),
        None => 0,
    }
}

/// 分类名：type 页 <title>“玉兔资源-第1页-少妇短剧…”取首段。
fn parse_type_name(html: &str) -> String {
    match Regex::new(r"(?s)<title>(.*?)</title>")
        .ok()
        .and_then(|re| re.captures(html))
    {
        Some(cap) => {
            let title = unescape(cap[1].trim());
            title.split('-').next().unwrap_or("").trim().to_string()
        }
        None => String::new(),
    }
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
    let mut list = Vec::new();
    for (id, name) in CATS {
        let url = format!("{BASE}/index.php/vod/type/id/{id}.html");
        let name = match get_text(&url).await {
            Ok(html) => {
                let live = parse_type_name(&html);
                if live.is_empty() {
                    name.to_string()
                } else {
                    live
                }
            }
            Err(_) => name.to_string(),
        };
        list.push(category_json(id, &name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page <= 1 {
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let total = page_total(&html);
    let has_more = if total > 0 {
        page * (items.len() as i64) < total
    } else {
        items.len() >= 20
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 详情页 player_aaaa 的 url（直链 m3u8）与 vod_name/vod_class。
fn parse_player(html: &str) -> (String, String, String) {
    let url = match Regex::new(r#"player_aaaa=\{.*?"url":"([^"]+)""#)
        .ok()
        .and_then(|re| re.captures(html))
    {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    };
    let name = match Regex::new(r#"vod_name":"((?:[^"\\]|\\.)*)""#)
        .ok()
        .and_then(|re| re.captures(html))
    {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    };
    let class = match Regex::new(r#"vod_class":"((?:[^"\\]|\\.)*)""#)
        .ok()
        .and_then(|re| re.captures(html))
    {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    };
    (url, name, class)
}

fn strip_title_suffix(title: &str) -> String {
    title.trim_end_matches(|c| c == ' ').to_string()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/index.php/vod/play/id/{series_id}/sid/1/nid/1.html");
    let html = get_text(&url).await?;
    let (m3u8, mut title, class) = parse_player(&html);
    if title.is_empty() {
        if let Some(cap) = Regex::new(r"(?s)<title>(.*?)</title>")
            .ok()
            .and_then(|re| re.captures(&html))
        {
            let raw = unescape(cap[1].trim());
            title = raw
                .split("在线播放")
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
        }
    }
    title = strip_title_suffix(&title);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("少妇短剧详情未返回可播放地址".into()));
    }
    Ok(json!({
    "id": series_id,
    "title": title,
    "cover": "",
    "synopsis": "",
    "extra": {"genre": class},
    "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
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

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({"url": video_id}));
    }
    let detail_value = detail(video_id).await?;
    match detail_value["episodes"].as_array() {
        Some(eps) if !eps.is_empty() => Ok(json!({"url": eps[0]["video_id"].clone()})),
        _ => Err(ApiError::Internal("少妇短剧该集没有播放地址".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<ul class="video-list"><li><a href="/aa/index.php/vod/play/id/263419/sid/1/nid/1.html" name="rdmonclick" target="_blank" rel="nofollow"><img class="lazy" data-original="https://xb.malatang10.xyz/mlt/upload/vod/20260902-10/b675e220f9678aa3cdc08b6df214db44.jpg" src="/aa/template/abc/static/loading.svg"></a><div class="video-detail"><a href="/aa/index.php/vod/play/id/263419/sid/1/nid/1.html"></a><h3 class="video-title"><a href="/aa/index.php/vod/play/id/263419/sid/1/nid/1.html"></a><a><text>年度必看专约良家超长一百五十分钟大合集，暴力调教后入爽翻天-</text></a></h3></div></li><li><a href="/aa/index.php/vod/play/id/263419/sid/1/nid/1.html"><img class="lazy" data-original="https://xb.malatang10.xyz/x.jpg" src="/aa/template/abc/static/loading.svg"></a><div class="video-detail"><h3 class="video-title"><a><text>重复卡片</text></a></h3></div></li></ul>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "263419");
        assert_eq!(
            items[0]["title"],
            "年度必看专约良家超长一百五十分钟大合集，暴力调教后入爽翻天-"
        );
        assert_eq!(
items[0]["cover"],
"https://xb.malatang10.xyz/mlt/upload/vod/20260902-10/b675e220f9678aa3cdc08b6df214db44.jpg"
);
    }

    #[test]
    fn unescape_decodes_unicode() {
        assert_eq!(unescape(r"\u3010\u6781\u54c1\u3011"), "【极品】");
        assert_eq!(unescape(r"a\/b"), "a/b");
    }

    #[test]
    fn parse_type_name_and_total() {
        let html = "<title>杏吧资源-第1页-少妇短剧-最新热门资源！</title><a class=\"more-link\">✦ 找到 23367 条</a>";
        assert_eq!(parse_type_name(html), "杏吧资源");
        assert_eq!(page_total(html), 23367);
        assert_eq!(page_total("<div>no total</div>"), 0);
    }

    #[test]
    fn fallback_has_4_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[0]["name"], "玉兔资源");
        assert_eq!(list[3]["id"], "61");
        assert_eq!(list[3]["name"], "杏吧资源");
    }

    #[test]
    fn parse_player_real_sample() {
        let html = r#"var player_data={"flag":"play"};</script><script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/aa\/index.php\/vod\/play\/id\/275510\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"黑丝房产经纪人勾引客户","vod_actor":"","vod_director":"","vod_class":"国产主播"},"url":"https:\/\/2608.xbv2608.com\/20261010\/ub0gL6xB\/index.m3u8","url_next":"","from":"s8m3u8","server":"no","note":"","id":275510,"sid":1,"nid":1}</script>"#;
        let (url, name, class) = parse_player(html);
        assert_eq!(url, "https://2608.xbv2608.com/20261010/ub0gL6xB/index.m3u8");
        assert_eq!(name, "黑丝房产经纪人勾引客户");
        assert_eq!(class, "国产主播");
        assert_eq!(
            parse_player("<div>no player</div"),
            ("".to_string(), "".to_string(), "".to_string())
        );
    }
}
