//! 古装AI：核心里的影视区站点。
//!
//! 清单入口 https://可想媸.guqmtd3.xyz/可好看/?matomo=yng 是多级
//! 跳转：先 302 到另一中文域名跳转页（“正在打開最新地址”），再
//! 按脚本随机跳 guzhuangai 系入口（5g.guzhuangai2 / ai.guzhuangai3
//! / web.guzhuangai4 等），实站为 5g.guzhuangai8.cc/rukou/（标题
//! 古装AI，guzhuangai 域名轮换）。实站为 MacCMS。与站导航 1:1
//!（9 项）：/rukou/index.php/vod/type/id/<n>.html（119 斯卡资源、
//! 244 51资源、386 黄瓜资源、358 番茄资源、286 兔兔资源、370 森
//! 林资源、329 库库资源、127 制服诱惑、390 AI短剧）；每页 12 条，
//! 翻页 /vod/type/id/<n>/page/<页>.html。视频
//! /vod/detail/id/<n>.html（多集：nid 1..N），播放页
//! /vod/play/id/<n>/sid/1/nid/<集>.html 里 player_aaaa 的 url 为
//! m3u8（直接媒体清单 200、AES-128 密钥 200/16B、首分片 200）。
//! 搜索 /vod/search/wd/<词>.html。站间歇截断/超时，get_text 内
//! 重试 3 次、间隔 2 秒。写源照站原样写，不按站名/分类名/标题删
//! 任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://5g.guzhuangai8.cc/rukou";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("119", "斯卡资源"),
    ("244", "51资源"),
    ("386", "黄瓜资源"),
    ("358", "番茄资源"),
    ("286", "兔兔资源"),
    ("370", "森林资源"),
    ("329", "库库资源"),
    ("127", "制服诱惑"),
    ("390", "AI短剧"),
];

/// 带重试的 GET：站间歇截断/超时，最多试 3 次，每次间隔 2 秒。
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
        return Err(ApiError::Internal(format!("古装AI请求 HTTP {status}")));
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
        .replace("\\/", "/")
}

/// 卡片解析：`<a href=".../vod/detail/id/<n>.html" class="group-item ...">`
/// + img data-original（封面）+ `<p>` 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="[^"]*/vod/detail/id/(\d+)\.html" class="group-item[^"]*">\s*<img[^>]*data-original="([^"]+)"[^>]*>\s*<p[^>]*>(.*?)</p>"#,
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
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[2].trim().to_string();
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：导航 /vod/type/id/<n>.html 锚点，按站内顺序、id 去重
///（“更多>”重复锚点会被去重）。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="[^"]*/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>"#) {
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
    match get_text(&format!("{BASE}/")).await {
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
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty()
        && html.contains(&format!(
            "/vod/type/id/{category_id}/page/{}.html",
            page + 1
        ));
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

/// 详情页集数：/vod/play/id/<n>/sid/1/nid/<集>.html，去重后按集号排序。
fn parse_episodes(html: &str, series_id: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="([^"]*/vod/play/id/\d+/sid/1/nid/(\d+)\.html)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut eps: Vec<(i64, String)> = Vec::new();
    for cap in re.captures_iter(html) {
        let nid = cap[2].to_string();
        if !seen.insert(nid.clone()) {
            continue;
        }
        if let Ok(n) = nid.parse::<i64>() {
            eps.push((n, cap[1].to_string()));
        }
    }
    eps.sort_by_key(|(n, _)| *n);
    eps.iter()
        .map(|(n, link)| {
            let full = if link.starts_with("http") {
                link.clone()
            } else {
                format!("https://5g.guzhuangai8.cc{link}")
            };
            episode_json(&full, &format!("第{n}集"), series_id)
        })
        .collect()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id
        .rsplit("/vod/detail/id/")
        .next()
        .unwrap_or(id)
        .trim_start_matches('/');
    let id = id.strip_suffix(".html").unwrap_or(id);
    let url = format!("{BASE}/index.php/vod/detail/id/{id}.html");
    let html = get_text(&url).await?;
    let title_re = Regex::new(r#"<p class="group-title">(.*?)</p>"#).ok();
    let title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
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
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]*)""#).ok();
    let mut synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = synopsis.strip_suffix("-古装AI") {
        synopsis = stripped.to_string();
    }
    let episodes = parse_episodes(&html, series_id);
    if title.is_empty() || episodes.is_empty() {
        return Err(ApiError::Internal("古装AI未返回播放线路".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains("/vod/play/") {
        let html = get_text(video_id).await?;
        let m3u8 = parse_player_url(&html);
        if m3u8.is_empty() {
            return Err(ApiError::Internal("古装AI该集没有播放地址".into()));
        }
        return Ok(json!({"url": m3u8}));
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("古装AI该集没有播放地址".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/index.php/vod/search/wd/{query}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/rukou/index.php/vod/detail/id/845485.html" class="group-item layui-col-md3 m-md6 "> <img class="content-img lazy" data-original="https://hg.jqydt1.com/upload/vod/20261022-1/e03e181a635c62889f2be8fc6544b5c3.jpg" data-prefix="" src="/rukou/template/gzai/load.png" data-aes="true"> <p style="">《无限尾行》</p> </a> <a href="/rukou/index.php/vod/detail/id/845485.html" class="group-item layui-col-md3 m-md6 "> <img class="content-img lazy" data-original="https://hg.jqydt1.com/x.jpg"> <p>重复卡片</p> </a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "845485");
        assert_eq!(items[0]["title"], "《无限尾行》");
        assert_eq!(
            items[0]["cover"],
            "https://hg.jqydt1.com/upload/vod/20261022-1/e03e181a635c62889f2be8fc6544b5c3.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/rukou/index.php/vod/type/id/119.html">斯卡资源</a><a href="/rukou/index.php/vod/type/id/244.html">51资源</a><a href="/rukou/index.php/vod/type/id/119.html">更多></a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "119");
        assert_eq!(list[1]["name"], "51资源");
    }

    #[test]
    fn fallback_has_9_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 9);
        assert_eq!(list[0]["id"], "119");
        assert_eq!(list[8]["name"], "AI短剧");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"vod_data":{"vod_name":"《无限尾行》","vod_class":"短剧,AI短剧,AI短,ai短-98"},"url":"https:\/\/c10.hs100.top\/20261021\/30fd5ce3f5c0b9c0\/index.m3u8","url_next":"https:\/\/c10.hs100.top\/20261022\/2622eef33a3c286f\/index.m3u8","from":"jpm3u8","id":"845485","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://c10.hs100.top/20261021/30fd5ce3f5c0b9c0/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_episodes_sorted_dedup() {
        let html = r#"<a href="/rukou/index.php/vod/play/id/845485/sid/1/nid/1.html">高清线路</a><a href="/rukou/index.php/vod/play/id/845485/sid/1/nid/3.html">第3集</a><a href="/rukou/index.php/vod/play/id/845485/sid/1/nid/2.html">第2集</a><a href="/rukou/index.php/vod/play/id/845485/sid/1/nid/1.html">高清线路</a>"#;
        let eps = parse_episodes(html, "845485");
        assert_eq!(eps.len(), 3);
        assert_eq!(eps[0]["title"], "第1集");
        assert_eq!(eps[2]["title"], "第3集");
        assert_eq!(
            eps[1]["video_id"],
            "https://5g.guzhuangai8.cc/rukou/index.php/vod/play/id/845485/sid/1/nid/2.html"
        );
    }

    #[test]
    fn unescape_slashes() {
        assert_eq!(
            unescape("https:\\/\\/c10.hs100.top\\/20261021\\/30fd5ce3f5c0b9c0\\/index.m3u8"),
            "https://c10.hs100.top/20261021/30fd5ce3f5c0b9c0/index.m3u8"
        );
    }
}
