//! 狠狠撸：核心里的影视区站点。
//!
//! 与站导航 1:1（3 项）：视频一区、视频二区、视频三区，每页 12 条；
//! 卡片直链播放页 /index.php/vod/play/id/<id>/sid/1/nid/1.html，
//! 详情路由 /index.php/vod/detail/id/<id>.html 回空体，故详情直接
//! 取播放页；取流为 MacCMS player_aaaa 的 m3u8（主清单 200、变体
//! 清单 2000kb 200、417 分片、首分片 Range 206，前 4 分片明文、
//! 其后 AES-128，密钥 fqts5.top，播放器原生解）；trysee=0、
//! points=0，全站免费无 VIP 墙；搜索 GET /index.php/vod/search.html?wd=。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://hhlu2127.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[("1", "视频一区"), ("2", "视频二区"), ("3", "视频三区")];

/// 带重试的 GET：本机出口偶发超时，最多试 3 次，每次间隔 1 秒。
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
        return Err(ApiError::Internal(format!("狠狠撸请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("狠狠撸返回空体".into()));
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

/// 卡片解析：`<a class="uzimg" href="/index.php/vod/play/id/<id>/sid/1/nid/1.html"
/// title="标题">` + 其后 `<img data-original="封面">`；每卡在页内出现两次，按 id 去重。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="uzimg" href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html" title="([^"]+)">.*?<img[^>]*data-original="([^"]+)""#,
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

/// 分类解析：首页 `<nav class="mynav">` 内的 type 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let nav = match Regex::new(r#"(?s)<nav class="mynav">(.*?)</nav>"#) {
        Ok(re) => re
            .captures(html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        Err(_) => String::new(),
    };
    let scope: &str = if nav.is_empty() { html } else { &nav };
    let re = match Regex::new(r#"href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)<"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(scope) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || name == "首页" || !seen.insert(id.clone()) {
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
        parse_player(&html).ok_or_else(|| ApiError::Internal("狠狠撸未返回播放器数据".into()))?;
    let title = text_of(&player["vod_data"], &["vod_name"]);
    let m3u8 = text_of(&player, &["url"]);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("狠狠撸未返回可播放地址".into()));
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
        Err(ApiError::Internal("狠狠撸该集没有播放地址".into()))
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
            fix_url("/template/hhlu/images/lazyload.gif"),
            "https://hhlu2127.lol/template/hhlu/images/lazyload.gif"
        );
        assert_eq!(
            fix_url("https://fqm3u8.cc/20260506/4iQv0OUT/index.m3u8"),
            "https://fqm3u8.cc/20260506/4iQv0OUT/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<li><a class="uzimg" href="/index.php/vod/play/id/108323/sid/1/nid/1.html" title="✿最佳淫技女神✿ 极品清纯窈窕身材美少女 ▌Cola酱▌特殊压力释放方式 口交足交嫩穴侍奉 狂肏"><img class="lazy" data-original="https://fqjpg12.top/upload/vod/20261104-1/58d01ba483756e0e90356cbf4ee7850c.png" src="/template/hhlu/images/lazyload.gif" alt="✿最佳淫技女神✿"></a><h4><a href="/index.php/vod/play/id/108323/sid/1/nid/1.html" title="✿最佳淫技女神✿ 极品清纯窈窕身材美少女 ▌Cola酱▌特殊压力释放方式 口交足交嫩穴侍奉 狂肏">✿最佳淫技女神✿</a></h4></li><li><a class="uzimg" href="/index.php/vod/play/id/108322/sid/1/nid/1.html" title="chocoletmilkk-韩国极品淫妻巧克力牛奶 酒店与炮友肛塞做爱"><img class="lazy" data-original="https://fqjpg12.top/upload/vod/20261104-1/84c8deb08cf90be29e4543e4bef1e59a.png" src="/template/hhlu/images/lazyload.gif"></a></li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "108323");
        assert_eq!(
            items[0]["title"],
            "✿最佳淫技女神✿ 极品清纯窈窕身材美少女 ▌Cola酱▌特殊压力释放方式 口交足交嫩穴侍奉 狂肏"
        );
        assert_eq!(
            items[0]["cover"],
            "https://fqjpg12.top/upload/vod/20261104-1/58d01ba483756e0e90356cbf4ee7850c.png"
        );
        assert_eq!(items[1]["id"], "108322");
    }

    #[test]
    fn parse_categories_nav() {
        let html = r#"<nav class="mynav"><a href="/" class="on" >首页</a><a href="/index.php/vod/type/id/1.html" >视频一区</a><a href="/index.php/vod/type/id/2.html" >视频二区</a><a href="/index.php/vod/type/id/3.html" >视频三区</a></nav>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[0]["name"], "视频一区");
        assert_eq!(list[2]["id"], "3");
        assert_eq!(list[2]["name"], "视频三区");
    }

    #[test]
    fn fallback_has_3_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 3);
        assert_eq!(list[1]["name"], "视频二区");
    }

    #[test]
    fn parse_player_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/108323\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"\u273f\u6700\u4f73\u6deb\u6280\u5973\u795e\u273f \u6781\u54c1\u6e05\u7eaf\u7a88\u7a95\u8eab\u6750\u7f8e\u5c11\u5973 \u258cCola\u9171\u258c\u7279\u6b8a\u538b\u529b\u91ca\u653e\u65b9\u5f0f \u53e3\u4ea4\u8db3\u4ea4\u5ae9\u7a74\u4f8d\u5949 \u72c2\u808f","vod_actor":"","vod_director":"","vod_class":"\u56fd\u4ea7\u5927\u5236\u4f5c"},"url":"https:\/\/fqm3u8.cc\/20260506\/4iQv0OUT\/index.m3u8","url_next":"","from":"fqm3u8","server":"","note":"","id":"108323","sid":1,"nid":1}</script>"#;
        let player = parse_player(html).expect("player json");
        assert_eq!(
            text_of(&player, &["url"]),
            "https://fqm3u8.cc/20260506/4iQv0OUT/index.m3u8"
        );
        assert_eq!(
            text_of(&player["vod_data"], &["vod_name"]),
            "✿最佳淫技女神✿ 极品清纯窈窕身材美少女 ▌Cola酱▌特殊压力释放方式 口交足交嫩穴侍奉 狂肏"
        );
        assert_eq!(text_of(&player["vod_data"], &["vod_class"]), "国产大制作");
        assert_eq!(player["trysee"].as_i64(), Some(0));
        assert_eq!(player["points"].as_i64(), Some(0));
        assert!(parse_player("<div>no player</div>").is_none());
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            catalog_url("1", 1),
            "https://hhlu2127.lol/index.php/vod/type/id/1.html"
        );
        assert_eq!(
            catalog_url("2", 3),
            "https://hhlu2127.lol/index.php/vod/type/id/2/page/3.html"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://fqm3u8.cc/20260506/4iQv0OUT/index.m3u8").unwrap();
        assert_eq!(ok["url"], "https://fqm3u8.cc/20260506/4iQv0OUT/index.m3u8");
        assert!(play_check("108323").is_err());
    }
}
