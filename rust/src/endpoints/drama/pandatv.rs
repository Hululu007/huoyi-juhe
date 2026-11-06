//! PANDATV：核心里的影视区站点。
//!
//! 与站导航 1:1（3 项）：国产、高清无码、中文字幕，每页 20 条；
//! 卡片直链播放页 /index.php/vod/play/id/<id>/sid/1/nid/1.html，
//! 详情路由 /index.php/vod/detail/id/<id>.html 回空体，故详情直接
//! 取播放页；取流为 MacCMS player_aaaa 的 m3u8（主清单 200、变体
//! 清单 2000kb 200、2710 分片、首分片 Range 206、METHOD=NONE、
//! 首字节 0x47）；trysee=0、points=0，全站免费无 VIP 墙（VIP 入口
//! 在首页源码里已被注释掉）；搜索须 POST /index.php/vod/search.html
//!（表单 wd=，GET 搜索回体中断不可用）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://pandatv1346.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[("75", "国产"), ("83", "高清无码"), ("84", "中文字幕")];

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
        return Err(ApiError::Internal(format!("PANDATV 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("PANDATV 返回空体".into()));
    }
    Ok(text)
}

/// 带重试的 POST 搜索：表单 wd=<query>。
async fn post_search(query: &str) -> ApiResult<String> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    let body = format!("wd={encoded}");
    let mut last_err = String::new();
    for _ in 0..3 {
        match client()?
            .post(format!("{BASE}/index.php/vod/search.html"))
            .header("User-Agent", UA)
            .header("Referer", BASE)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(body.clone())
            .send()
            .await
        {
            Ok(resp) => {
                let status = resp.status().as_u16();
                if status != 200 {
                    last_err = format!("PANDATV 搜索 HTTP {status}");
                } else {
                    match resp.text().await {
                        Ok(text) if !text.trim().is_empty() => return Ok(text),
                        Ok(_) => last_err = "PANDATV 搜索返回空体".into(),
                        Err(e) => last_err = e.to_string(),
                    }
                }
            }
            Err(e) => last_err = e.to_string(),
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Err(ApiError::Internal(last_err))
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

/// 卡片解析：`<a href="/index.php/vod/play/id/<id>/sid/1/nid/1.html"
/// title="标题" class="img-box ...">` + 其后 `<img src="封面">`；每卡在页内
/// 出现两次（图链 + 文链），图链在前，按 id 去重。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html" title="([^"]+)"[^>]*>.*?<img src="([^"]+)""#,
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
        let cover = fix_url(&cap[3]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页导航锚点（内文非空、非“+更多”），按站内顺序、id 去重。
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
        if name.is_empty() || name == "+更多" || !seen.insert(id.clone()) {
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
        parse_player(&html).ok_or_else(|| ApiError::Internal("PANDATV 未返回播放器数据".into()))?;
    let title = text_of(&player["vod_data"], &["vod_name"]);
    let m3u8 = text_of(&player, &["url"]);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("PANDATV 未返回可播放地址".into()));
    }
    let genre = text_of(&player["vod_data"], &["vod_class"]);
    let cover_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures_iter(&html)
            .filter_map(|m| {
                let src = fix_url(&m[1]);
                if src.contains("/template/") || src.is_empty() {
                    None
                } else {
                    Some(src)
                }
            })
            .next()
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
        Err(ApiError::Internal("PANDATV 该集没有播放地址".into()))
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
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/template/panda/logo.png"),
            "https://pandatv1346.lol/template/panda/logo.png"
        );
        assert_eq!(
            fix_url("https://vostrely.com/20261103/ZdV8YQMY/index.m3u8"),
            "https://vostrely.com/20261103/ZdV8YQMY/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<li class="col-25 col-m-12 mb20"><section class="item-box"><a href="/index.php/vod/play/id/151955/sid/1/nid/1.html" title="HEZ-894 ボクのチ○ポに満足していない妻を、デカチンの甥に寝取ってもらった！ 超ビンカン嫁×巨根NTR 夏川あゆみ" class="img-box bo-r5" data-ratio="75"><img src="https://guzwiayz.com/20261103/ZdV8YQMY/1.jpg?t=1793750812" onerror="this.onerror=null;this.src='/template/panda/dancing.gif';" alt="HEZ-894 ボクのチ○ポに満足していない妻を、デカチンの甥に寝取ってもらった！ 超ビンカン嫁×巨根NTR 夏川あゆみ"></a></section></li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "151955");
        assert_eq!(
            items[0]["title"],
            "HEZ-894 ボクのチ○ポに満足していない妻を、デカチンの甥に寝取ってもらった！ 超ビンカン嫁×巨根NTR 夏川あゆみ"
        );
        assert_eq!(
            items[0]["cover"],
            "https://guzwiayz.com/20261103/ZdV8YQMY/1.jpg?t=1793750812"
        );
    }

    #[test]
    fn parse_categories_nav() {
        let html = r#"<a href="/index.php/vod/type/id/75.html">国产</a><a href="/index.php/vod/type/id/83.html">高清无码</a><a href="/index.php/vod/type/id/84.html">中文字幕</a><a href="/index.php/vod/type/id/75.html" class="more-a f-12">+更多</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "75");
        assert_eq!(list[0]["name"], "国产");
        assert_eq!(list[1]["name"], "高清无码");
        assert_eq!(list[2]["id"], "84");
    }

    #[test]
    fn fallback_has_3_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 3);
        assert_eq!(list[2]["name"], "中文字幕");
    }

    #[test]
    fn parse_player_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/151955\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"HEZ-894 ボクのチ○ポに満足していない妻を、デカチンの甥に寝取ってもらった！ 超ビンカン嫁×巨根NTR 夏川あゆみ","vod_actor":"","vod_director":"","vod_class":"\u5f3a\u5978\u4e71\u4f26"},"url":"https:\/\/vostrely.com\/20261103\/ZdV8YQMY\/index.m3u8","url_next":"","from":"naixx","server":"","note":"","id":"151955","sid":1,"nid":1}</script>"#;
        let player = parse_player(html).expect("player json");
        assert_eq!(
            text_of(&player, &["url"]),
            "https://vostrely.com/20261103/ZdV8YQMY/index.m3u8"
        );
        assert_eq!(
            text_of(&player["vod_data"], &["vod_name"]),
            "HEZ-894 ボクのチ○ポに満足していない妻を、デカチンの甥に寝取ってもらった！ 超ビンカン嫁×巨根NTR 夏川あゆみ"
        );
        assert_eq!(text_of(&player["vod_data"], &["vod_class"]), "强奸乱伦");
        assert_eq!(player["trysee"].as_i64(), Some(0));
        assert_eq!(player["points"].as_i64(), Some(0));
        assert!(parse_player("<div>no player</div>").is_none());
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            catalog_url("75", 1),
            "https://pandatv1346.lol/index.php/vod/type/id/75.html"
        );
        assert_eq!(
            catalog_url("83", 2),
            "https://pandatv1346.lol/index.php/vod/type/id/83/page/2.html"
        );
    }

    #[test]
    fn search_body_encoding() {
        let encoded: String = url::form_urlencoded::byte_serialize("国产".as_bytes()).collect();
        assert_eq!(encoded, "%E5%9B%BD%E4%BA%A7");
        assert_eq!(format!("wd={encoded}"), "wd=%E5%9B%BD%E4%BA%A7");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://vostrely.com/20261103/ZdV8YQMY/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://vostrely.com/20261103/ZdV8YQMY/index.m3u8"
        );
        assert!(play_check("151955").is_err());
    }
}
