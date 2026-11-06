//! AI短剧AV：核心里的影视区站点。
//!
//! 入口 https://kao.aisee9w.buzz/neural/ 是 JS 跳转页，目标为
//! https://<随机前缀><日期码>.aisee10w29.buzz/network/?utm_source=kao.aisee9w.buzz；
//! 10 个候选前缀与裸域 https://aisee10w29.buzz/network/
//! 均返回同一份首页，故本模块直接用裸域作 BASE。
//! - 分类 4 个，与首页 vod-category-menu 1:1：
//!   AI成人短剧 /aidj/25/、AI成人漫剧 /aidj/26/、
//!   AI换脸 /aidj/27/、AI魔改 /aidj/28/。
//!   首页另有“色色本”漫画菜单（/detail-<id>/ 图集页），
//!   不是视频分类，不进分类。
//! - 目录：/aidj/<id>/，每页 24 条，翻页
//!   /aidj/<id>/page/<n>/（共 64 页，p2 已实测 121KB）。
//! - 详情：/detail/<id>/，h1 标题、首张
//!   media.hgpicimg.cc//upload/huangguo/ 图为封面、
//!   meta description 作简介；播放入口 /play/<id>-1-1/。
//!   注意 /detail-<id>/ 是漫画/图集页，不是视频详情，
//!   模块只用 /detail/<id>/。
//! - 取流：播放页 player_data 的 url 字段为“<id>|<集>”
//!   （from=huangguo），再调
//!   /huangguo.php?ac=play&id=<id>&ep=<集>，
//!   JSON {code:1, url:"/hgmedia.php?e=..."} 即代理清单
//!   （实测 11602 第 1 集：代理清单 200，14.8KB，
//!   AES-128 加密分片，.ts 同样走 /hgmedia.php?e=...）。
//!   代理地址含站内签名参数，模块只按运行时返回值
//!   透传，不在代码里写死任何签名值。
//! - 搜索：/search/<词>-------------/，实测“美女”24 条。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://aisee10w29.buzz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页 vod-category-menu，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("25", "AI成人短剧"),
    ("26", "AI成人漫剧"),
    ("27", "AI换脸"),
    ("28", "AI魔改"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match client()?
            .get(url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE}/network/"))
            .send()
            .await
        {
            Ok(resp) => {
                if resp.status().as_u16() == 200 {
                    match resp.text().await {
                        Ok(text) if !text.trim().is_empty() => return Ok(text),
                        Ok(_) => last_err = "空响应".into(),
                        Err(e) => last_err = e.to_string(),
                    }
                } else {
                    last_err = format!("HTTP {}", resp.status().as_u16());
                }
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!(
        "AI短剧AV请求失败 {url}: {last_err}"
    )))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 分类解析：只取第一个 vod-category-menu 块（视频分类），
// 其后的“色色本”漫画菜单不取。
fn parse_categories(html: &str) -> Vec<Value> {
    let menu = match html.find("vod-category-menu") {
        Some(pos) => {
            let rest = &html[pos..];
            let end = rest.find("色色本").unwrap_or(rest.len());
            &rest[..end]
        }
        None => return Vec::new(),
    };
    let re = match Regex::new(r#"(?s)<a href="/aidj/(\d+)/"[^>]*>.*?</i>\s*([^<]+?)\s*</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(menu) {
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

/// 卡片解析：video-element 块内的 /detail/<id>/ 锚点、
// 封面 img 与 h4 标题；备注取“浏览”数。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/detail/(\d+)/"[^>]*class="video-cover"[^>]*>\s*<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let title_re = Regex::new(r#"(?s)<h4 class="video-title">\s*<a[^>]*>\s*([^<]+?)\s*</a>"#).ok();
    let view_re = Regex::new(r#"<div class="video-view">\s*([\d,]+)\s*浏览"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = cap[2].trim().to_string();
        let tail = &html[cap.get(0).map(|m| m.end()).unwrap_or(0)..];
        let window = tail.get(..2000).unwrap_or(tail);
        let title = match &title_re {
            Some(re) => re
                .captures(window)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_else(|| unescape(cap[3].trim())),
            None => unescape(cap[3].trim()),
        };
        if title.is_empty() {
            continue;
        }
        let remark = match &view_re {
            Some(re) => re
                .captures(window)
                .map(|m| format!("{}浏览", m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 播放页 player_data 的 url 与 from 字段。
fn parse_player_data(html: &str) -> (String, String) {
    let url_re = Regex::new(r#"player_data=\{"flag":"[^"]*","encrypt":\d+,"trysee":\d+,"points":\d+,"link":"[^"]*","link_next":"[^"]*","link_pre":"[^"]*","vod_data":\{[^}]*\},"url":"([^"]+)""#)
        .ok();
    let from_re = Regex::new(r#""from":"([^"]+)""#).ok();
    let url = match &url_re {
        Some(re) => re
            .captures(html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let from = match &from_re {
        Some(re) => re
            .captures(html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    (url, from)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/network/")).await {
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
        format!("{BASE}/aidj/{category_id}/")
    } else {
        format!("{BASE}/aidj/{category_id}/page/{page}/")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/aidj/{category_id}/page/{}/", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/detail/")
        .trim_end_matches(".html")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{BASE}/detail/{id}/")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"<img[^>]*src="([^"]*?/upload/huangguo/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description" content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("AI短剧AV详情未返回标题".into()));
    }
    let ep_re = Regex::new(&format!(r#"href="/play/{id}-1-(\d+)/""#)).ok();
    let mut episodes = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Some(re) = &ep_re {
        for cap in re.captures_iter(&html) {
            let ep = cap[1].to_string();
            if !seen.insert(ep.clone()) {
                continue;
            }
            episodes.push(episode_json(
                &format!("{id}-1-{ep}"),
                &format!("第{ep}集"),
                series_id,
            ));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("{id}-1-1"), "第1集", series_id));
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
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let parts: Vec<&str> = vid.split('-').collect();
    if parts.len() != 3 {
        return Err(ApiError::Internal("AI短剧AV播放地址格式错误".into()));
    }
    let page_url = format!("{BASE}/play/{}-{}-{}/", parts[0], parts[1], parts[2]);
    let html = get_text(&page_url).await?;
    let (play_url, from) = parse_player_data(&html);
    if play_url.is_empty() {
        return Err(ApiError::Internal("AI短剧AV未取到播放地址".into()));
    }
    if play_url.contains(".m3u8") || play_url.contains(".mp4") {
        return Ok(json!({
            "url": play_url,
            "header": {"User-Agent": UA, "Referer": page_url},
        }));
    }
    let (id, ep) = match play_url.split_once('|') {
        Some((a, b)) => (a.to_string(), b.to_string()),
        None => {
            return Err(ApiError::Internal("AI短剧AV播放地址格式错误".into()));
        }
    };
    if from != "huangguo" {
        return Err(ApiError::Internal(format!(
            "AI短剧AV未支持的播放来源 {from}"
        )));
    }
    let api = format!("{BASE}/huangguo.php?ac=play&id={id}&ep={ep}");
    let body = get_text(&api).await?;
    let parsed: Value = serde_json::from_str(&body)
        .map_err(|e| ApiError::Internal(format!("AI短剧AV取流解析失败 {e}")))?;
    let code = parsed.get("code").and_then(|v| v.as_i64()).unwrap_or(0);
    let proxy = parsed
        .get("url")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if code != 1 || proxy.is_empty() || !proxy.starts_with("/hgmedia.php?e=") {
        return Err(ApiError::Internal("AI短剧AV取流接口未返回代理地址".into()));
    }
    Ok(json!({
        "url": format!("{BASE}{proxy}"),
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{BASE}/search/{enc}-------------/");
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_first_menu_only() {
        let html = r#"<div id="vod-category-menu"> <a href="/aidj/25/" target="_blank" class="25=0 active" > <i class="fa random-cat-icon"></i> AI成人短剧 </a> <a href="/aidj/26/" target="_blank" class="26=0" > <i class="fa random-cat-icon"></i> AI成人漫剧 </a> <a href="/aidj/27/" target="_blank" class="27=0" > <i class="fa random-cat-icon"></i> AI换脸 </a> <a href="/aidj/28/" target="_blank" class="28=0" > <i class="fa random-cat-icon"></i> AI魔改 </a> </div> <b>色色本</b> <div id="vod-category-menu"> <a href="/detail-1/" >漫画一</a> </div>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "25");
        assert_eq!(list[0]["name"], "AI成人短剧");
        assert_eq!(list[3]["id"], "28");
        assert_eq!(list[3]["name"], "AI魔改");
    }

    #[test]
    fn fallback_has_4_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 4);
        assert_eq!(list[1]["name"], "AI成人漫剧");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="col-xs-6 col-md-2-4 video-element"> <a href="/detail/4961/" target="_blank" class="video-cover"> <img class="video-cover-img" src="https://media.hgpicimg.cc//upload/huangguo/7628.jpg" alt="时停手表" /> </a> <h4 class="video-title"> <a href="/detail/4961/" target="_blank"> 时停手表 </a> </h4> <div class="video-publish"> 2小时前 </div> <div class="video-view"> 49975 浏览 </div> </div> <div class="col-xs-6 col-md-2-4 video-element"> <a href="/detail/2533/" target="_blank" class="video-cover"> <img class="video-cover-img" src="https://media.hgpicimg.cc//upload/huangguo/1244.jpg" alt="大雄一家的快乐生活" /> </a> <h4 class="video-title"> <a href="/detail/2533/" target="_blank"> 大雄一家的快乐生活 </a> </h4> <div class="video-publish"> 2小时前 </div> <div class="video-view"> 54827 浏览 </div> </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "4961");
        assert_eq!(items[0]["title"], "时停手表");
        assert_eq!(
            items[0]["cover"],
            "https://media.hgpicimg.cc//upload/huangguo/7628.jpg"
        );
        assert_eq!(items[0]["remark"], "49975浏览");
        assert_eq!(items[1]["title"], "大雄一家的快乐生活");
    }

    #[test]
    fn parse_player_data_real_markup() {
        let html = r#"var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"/play/5594-1-1/","link_next":"/play/5594-1-2/","link_pre":"","vod_data":{"vod_name":"驯养篮球犬"},"url":"11602|1","url_next":"11602|2","from":"huangguo","server":"no","note":"","id":"5594","sid":1,"nid":1};"#;
        let (url, from) = parse_player_data(html);
        assert_eq!(url, "11602|1");
        assert_eq!(from, "huangguo");
    }

    #[test]
    fn parse_player_data_empty() {
        let (url, from) = parse_player_data("<div>no player</div>");
        assert_eq!(url, "");
        assert_eq!(from, "");
    }
}
