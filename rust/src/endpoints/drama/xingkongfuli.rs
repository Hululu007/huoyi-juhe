//! 星空福利视频：核心里的影视区站点。
//!
//! 与站顶栏导航 1:1（5 项）：国产视频、日韩AV、蓝光超清、欧美视频、动漫精选。
//! 目录走筛选页 /index.php/vod/show/id/<id>.html（每页 72 条、共 435 页，
//! 第 2 页 0 重叠；注意 /index.php/vod/type/id/<id>.html 是无分页的全量
//! 落地页，/page/2.html 会原样回同一批 366 条，不能作目录用）；卡片为
//! module-item：详情锚点 + 紧跟的 `<img data-src="封面">`；详情页有真实
//! 标题/封面/分类（h1、首个 data-src、video-class），无 player_aaaa，
//! 详情须再取播放页；取流为 MacCMS player_aaaa 的单级 m3u8
//!（清单 200、1768 分片、AES-128 密钥 200 16 字节、内容分片 200 可取，
//! 分片地址为 .jpg 伪装、首段为广告）；trysee=0、points=0，全站免费无
//! VIP 墙；搜索 GET /index.php/vod/search.html?wd=，卡片图链锚点为播放
//! 链（title="立刻播放<标题>"）。国产视频下另有 76-87 十二个二级分类
//!（强奸迷奸/丝袜制服/国产厂牌/SM调教/乱伦/网曝黑料/主播网红/自拍偷拍/
//! 群交多P/学生萝莉/口交自慰/国产三级），不在顶栏导航内，未列入本模块
//! 的分类表。写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40
//! 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://xksp1359.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站顶栏导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("75", "国产视频"),
    ("88", "日韩AV"),
    ("94", "蓝光超清"),
    ("99", "欧美视频"),
    ("103", "动漫精选"),
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
        return Err(ApiError::Internal(format!(
            "星空福利视频请求 HTTP {status}"
        )));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("星空福利视频返回空体".into()));
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

/// 分类解析：顶栏 nav-link 锚点（图标 `<i>` 后的文字即分类名），按站内
/// 顺序、id 去重；二级分类锚点不在 nav-link 里，天然不进。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"(?s)<a class="nav-link[^"]*"[^>]*href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>(.*?)</a>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let tag_re = Regex::new(r"<[^>]+>").ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let inner = match &tag_re {
            Some(re) => re.replace_all(&cap[2], "").to_string(),
            None => cap[2].to_string(),
        };
        let name = unescape(inner.trim());
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

/// 目录卡片解析：module-item 的详情锚点 + 紧跟的 `<img data-src="封面">`；
/// 标题锚点在后，按 id 去重后天然只取图链那一条。
fn parse_cards(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"(?s)<a href="/index\.php/vod/detail/id/(\d+)\.html" title="([^"]+)"[^>]*>.*?<img[^>]*data-src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[2].trim());
        let cover = fix_url(&cap[3]);
        if title.is_empty() || cover.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 搜索卡片解析：搜索页图链锚点是播放链（title="立刻播放<标题>"），
/// 紧跟 `<img data-src="封面">`；底部“立即播放”按钮同 id，按去重跳过。
fn parse_search_cards(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"(?s)<a href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html" title="立刻播放([^"]+)"[^>]*>.*?<img[^>]*data-src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[2].trim());
        let cover = fix_url(&cap[3]);
        if title.is_empty() || cover.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{BASE}/index.php/vod/show/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/show/id/{category_id}/page/{page}.html")
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = get_text(&catalog_url(category_id, page)).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!(
            "/index.php/vod/show/id/{category_id}/page/{}.html",
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
    let id = id.strip_prefix("index.php/vod/detail/id/").unwrap_or(id);
    let id = id.split('/').next().unwrap_or(id);
    let detail_html = get_text(&format!("{BASE}/index.php/vod/detail/id/{id}.html")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&detail_html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"data-src="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&detail_html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&detail_html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let play_html = get_text(&format!(
        "{BASE}/index.php/vod/play/id/{id}/sid/1/nid/1.html"
    ))
    .await?;
    let player = parse_player(&play_html)
        .ok_or_else(|| ApiError::Internal("星空福利视频未返回播放器数据".into()))?;
    let m3u8 = text_of(&player, &["url"]);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("星空福利视频未返回可播放地址".into()));
    }
    let genre = text_of(&player["vod_data"], &["vod_class"]);
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
        Err(ApiError::Internal("星空福利视频该集没有播放地址".into()))
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
    let items = parse_search_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/template/klxq/static/picture/logo.png"),
            "https://xksp1359.lol/template/klxq/static/picture/logo.png"
        );
        assert_eq!(
            fix_url("https://xjimg.cdn-xj.cc/upload/litpic/2025-03-26/1743006791_526.jpg"),
            "https://xjimg.cdn-xj.cc/upload/litpic/2025-03-26/1743006791_526.jpg"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_categories_nav() {
        let html = r#"<li class="nav-menu-item selected"><a class="nav-link white" href="/index.php/vod/type/id/75.html"><i class="icon-cate-dy"></i> 国产视频 </a></li><li class="nav-menu-item "><a class="nav-link white" href="/index.php/vod/type/id/88.html"><i class="icon-cate-ds"></i> 日韩AV </a></li><li class="nav-menu-item "><a class="nav-link white" href="/index.php/vod/type/id/103.html"><i class="icon-cate-dm"></i> 动漫精选 </a></li>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "75");
        assert_eq!(list[0]["name"], "国产视频");
        assert_eq!(list[1]["name"], "日韩AV");
        assert_eq!(list[2]["id"], "103");
    }

    #[test]
    fn fallback_has_5_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 5);
        assert_eq!(list[0]["name"], "国产视频");
        assert_eq!(list[4]["id"], "103");
        assert_eq!(list[4]["name"], "动漫精选");
    }

    #[test]
    fn parse_cards_show_markup() {
        let html = r#"<div class="module-item"><div class="module-item-cover"><div class="module-item-pic"><a href="/index.php/vod/detail/id/57549.html" title="李宗瑞迷奸-77" ><i class="icon-play"></i></a><img class="lazy lazyloaded" data-src="https://xjimg.cdn-xj.cc/upload/litpic/2025-03-26/1743006791_526.jpg" src="/template/xkfl/static/picture/loading.png" alt="李宗瑞迷奸-77"><div class="loading"></div></div></div><div class="module-item-caption"><span class="video-class">强奸迷奸</span></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "57549");
        assert_eq!(items[0]["title"], "李宗瑞迷奸-77");
        assert_eq!(
            items[0]["cover"],
            "https://xjimg.cdn-xj.cc/upload/litpic/2025-03-26/1743006791_526.jpg"
        );
    }

    #[test]
    fn parse_search_cards_real_markup() {
        let html = r#"<div class="module-search-item"><div class="video-cover"><div class="module-item-cover"><div class="module-item-pic"><a href="/index.php/vod/play/id/63356/sid/1/nid/1.html" title="立刻播放国产老片上古视频早期裸挠大尺度"><i class="icon-play"></i></a><img class="lazy lazyload" data-src="https://xjimg.cdn-xj.cc/upload/litpic/2025-05-07/1746583863_949.jpg" src="/template/klxq/static/picture/loading.png" alt="国产老片上古视频早期裸挠大尺度"><div class="loading"></div></div></div></div><div class="video-info"><div class="video-info-header"><h3><a href="/index.php/vod/detail/id/63356.html" title="国产老片上古视频早期裸挠大尺度">国产老片上古视频早期裸挠大尺度</a></h3></div></div></div>"#;
        let items = parse_search_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "63356");
        assert_eq!(items[0]["title"], "国产老片上古视频早期裸挠大尺度");
        assert_eq!(
            items[0]["cover"],
            "https://xjimg.cdn-xj.cc/upload/litpic/2025-05-07/1746583863_949.jpg"
        );
    }

    #[test]
    fn parse_player_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/6037\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"\u696a\u30ab\u30ec\u30f3\u4e2d\u51fa\u3057\u5927\u4e71\u4ea4\u89e3\u7981SPECIAL--Uncensored-PPPE-198","vod_actor":"","vod_director":"","vod_class":"\u65e5\u97e9\u7cbe\u9009"},"url":"https:\/\/xjzym3u-api.cdn-xj.cc\/mov\/uphls\/2026-02-20\/mlu6vtx7\/hl2dja4z.m3u8","url_next":"","from":"xjplayer","server":"","note":"","id":"6037","sid":1,"nid":1}</script>"#;
        let player = parse_player(html).expect("player json");
        assert_eq!(
            text_of(&player, &["url"]),
            "https://xjzym3u-api.cdn-xj.cc/mov/uphls/2026-02-20/mlu6vtx7/hl2dja4z.m3u8"
        );
        assert_eq!(
            text_of(&player["vod_data"], &["vod_name"]),
            "楪カレン中出し大乱交解禁SPECIAL--Uncensored-PPPE-198"
        );
        assert_eq!(text_of(&player["vod_data"], &["vod_class"]), "日韩精选");
        assert_eq!(player["trysee"].as_i64(), Some(0));
        assert_eq!(player["points"].as_i64(), Some(0));
        assert_eq!(text_of(&player, &["from"]), "xjplayer");
        assert!(parse_player("<div>no player</div>").is_none());
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            catalog_url("75", 1),
            "https://xksp1359.lol/index.php/vod/show/id/75.html"
        );
        assert_eq!(
            catalog_url("103", 2),
            "https://xksp1359.lol/index.php/vod/show/id/103/page/2.html"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok =
            play_check("https://xjzym3u-api.cdn-xj.cc/mov/uphls/2026-02-20/mlu6vtx7/hl2dja4z.m3u8")
                .unwrap();
        assert_eq!(
            ok["url"],
            "https://xjzym3u-api.cdn-xj.cc/mov/uphls/2026-02-20/mlu6vtx7/hl2dja4z.m3u8"
        );
        assert!(play_check("6037").is_err());
    }
}
