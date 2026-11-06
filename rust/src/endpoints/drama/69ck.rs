//! 👑帝皇影视┃黄色仓库：MacCMS 站的 HTML 新版。
//!
//! 与 jar 的 Zaka69ckAmns 一一对应，但 API 已死、地址已变：
//! jar 的 8 个入口候选 /api.php/provide/vod/ 全不回 API（回
//! 首页 HTML 或 500），活站是 111.9967hsck.cc（2026-11-06
//! 实测：444.9966hsck.cc 301 跳转至此，首页 200）。新版 URL：类型页 /vodtype/<id>.html、翻页
//! /vodtype/<id>-<N>.html、视频页 /v5/<id>-1-1.html、搜索
//! /vodsearch/<词>-------------.html（13 横线）。旧
//! /index.php/vod/... 路径全部 404。
//! 取流（站内真实链路）：详情页含 6 秒倒计时 + 点击取流的 JS：
//! POST /static/count.php（表单 id/sid/nid/tk/g/x/y/dt/sw/sh/
//! tz/t，tk 为页内 AK），回 {ok: true, u: base64(地址)}。
//! 旧的“封面 vod.jpg → 同目录 index.m3u8”推断已证伪：
//! 2026-11-06 实测 index.m3u8 回 404，且页内第一个 vod.jpg
//! 是别的视频（相关推荐）的封面。count.php 本机四次 POST 均
//! 无响应（60/90/120/180 秒超时，0 字节），未验通，须手机复验。
//! 验门（2026-11-05 请求复现）：8 类各 40 卡、翻页 40 卡、
//! 详情（标题/封面/时长齐）、搜索 36 卡全过；取流未验。
//! 2026-11-06 复验：活站改 111.9967hsck.cc（444 301 跳转
//! 至此）；分类页 40 卡、翻页 40 卡、搜索 36 卡仍通；详情
//! 封面/时长改取本视频自己的相关卡（旧逻辑取到别的视频的
//! 封面）；取流改走站内 count.php（见 play），本机 POST 四
//! 次均无响应未验通，须手机复验。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const BASE_TTL: Duration = Duration::from_secs(30 * 60);
const CANDIDATES: &[&str] = &[
    "https://111.9967hsck.cc",
    "https://444.9966hsck.cc",
    "https://333.0qck.cc",
    "https://666.0qck.cc",
    "https://777.0qck.cc",
    "https://111.aauck.cc",
    "https://hsck.tv",
    "https://69ck.net",
    "https://69ck.com",
    "https://www.69ck.nl",
];

static LIVE_BASE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 活站发现：按序试候选域名，跟随跳转，取最终含 stui 的站，
/// 缓存 30 分钟。jar 的 API 探测逻辑已作废。
async fn live_base() -> ApiResult<String> {
    if let Ok(guard) = LIVE_BASE.lock() {
        if let Some((base, exp)) = guard.as_ref() {
            if Instant::now() < *exp {
                return Ok(base.clone());
            }
        }
    }
    for cand in CANDIDATES {
        if let Ok(resp) = client()?.get(*cand).send().await {
            let final_url = resp.url().to_string();
            if let Ok(text) = resp.text().await {
                if text.contains("stui") || text.contains("vodtype") {
                    let base = final_url.trim_end_matches('/').to_string();
                    if let Ok(mut guard) = LIVE_BASE.lock() {
                        *guard = Some((base.clone(), Instant::now() + BASE_TTL));
                    }
                    return Ok(base);
                }
            }
        }
    }
    Err(ApiError::Internal("黄色仓库没有找到可用的入口站".into()))
}

async fn get_text(path: &str) -> ApiResult<String> {
    let base = live_base().await?;
    let url = format!("{base}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{base}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄色仓库请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
}

fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 与新版站一致：只取 /v5/ 链接的 stui 卡片，排除外链广告卡。
fn parse_cards(page: &str, base: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let marker = "stui-vodlist__thumb";
    let mut starts: Vec<usize> = Vec::new();
    let mut from = 0usize;
    while let Some(i) = page[from..].find(marker) {
        starts.push(from + i);
        from += i + marker.len();
    }
    if starts.is_empty() {
        return items;
    }
    let href_re = Regex::new("href=\"(/v5/(\\d+)-1-1\\.html)\"").unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, start) in starts.iter().enumerate() {
        let stop = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            (*start + 6000).min(page.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &page[*start..stop];
        let Some(cap) = href_re.captures(chunk) else {
            continue;
        };
        let id = cap[2].to_string();
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let mut title = pick(chunk, "(?i)title=\"([^\"]{1,200})\"");
        if title.is_empty() {
            title = pick(chunk, "(?s)<h4[^>]*>(.*?)</h4>");
        }
        if title.is_empty() {
            title = format!("影片 {id}");
        }
        let mut pic = pick(chunk, "(?i)data-original=\"([^\"]+)\"");
        if pic.is_empty() {
            pic = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let pic = if pic.starts_with("http") {
            pic
        } else if pic.starts_with("//") {
            format!("https:{pic}")
        } else if pic.starts_with('/') {
            format!("{base}{pic}")
        } else {
            String::new()
        };
        let mut remark = pick(chunk, "(?s)<p class=\"sub\"[^>]*>(.*?)</p>");
        if remark.is_empty() {
            remark = pick(chunk, "(?s)class=\"pic-text[^\\\"]*\"[^>]*>(.*?)</");
        }
        let href = format!("{base}/v5/{id}-1-1.html");
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

fn search_url(word: &str) -> String {
    let encoded: String = url::form_urlencoded::byte_serialize(word.trim().as_bytes()).collect();
    format!("/vodsearch/{encoded}-------------.html")
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("home", "🏠最近更新"),
        category_json("hot", "🔥最近更新"),
        category_json("1", "日韩AV"),
        category_json("2", "国产系列"),
        category_json("3", "欧美"),
        category_json("4", "成人动漫"),
        category_json("7", "日本有码"),
        category_json("8", "无码中文字幕"),
        category_json("9", "有码中文字幕"),
        category_json("10", "日本无码"),
        category_json("15", "国产视频"),
        category_json("21", "欧美高清"),
        category_json("22", "动漫剧情"),
        category_json("26", "骑兵破解"),
    ];
    for brand in [
        "麻豆",
        "91制片厂",
        "蜜桃影像",
        "果冻传媒",
        "天美传媒",
        "精东影业",
        "爱豆传媒",
        "性视界",
        "SA国际传媒",
        "玩偶姐姐",
        "皇家华人",
        "69传媒",
        "乌托邦",
        "杏吧",
        "大象传媒",
        "乌鸦传媒",
        "香蕉视频",
        "扣扣传媒",
    ] {
        list.push(category_json(&format!("s:{brand}"), brand));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let base = live_base().await?;
    if category_id == "home" || category_id == "hot" {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let html = get_text("/").await?;
        let items = parse_cards(&html, &base);
        return Ok(json!({"items": items, "has_more": false}));
    }
    if let Some(brand) = category_id.strip_prefix("s:") {
        let mut path = search_url(brand);
        if page > 1 {
            path = path.replace(".html", &format!("-{page}.html"));
        }
        let html = match get_text(&path).await {
            Ok(h) => h,
            Err(_) => return Ok(json!({"items": [], "has_more": false})),
        };
        let items = parse_cards(&html, &base);
        return Ok(json!({"items": items, "has_more": items.len() >= 40}));
    }
    let path = if page > 1 {
        format!("/vodtype/{category_id}-{page}.html")
    } else {
        format!("/vodtype/{category_id}.html")
    };
    let html = get_text(&path).await?;
    let items = parse_cards(&html, &base);
    Ok(json!({"items": items, "has_more": items.len() >= 40}))
}

/// 详情页封面与时长：当前视频在“精选内容”相关列表里也有自己
/// 的卡片（链向自身），以该卡为准；页内第一个 data-original /
/// pic-text 是别的视频（或“精选”栏目标题），直接取第一个会取
/// 错视频（2026-11-06 实测：286655 页首条是 286705 的封面）。
fn self_cover_remark(page: &str, vid: &str) -> (String, String) {
    let mut cover = String::new();
    let mut remark = String::new();
    if !vid.is_empty() {
        if let Ok(re) = Regex::new(&format!(
            "href=\"/v5/{vid}-1-1\\.html\"[^>]*data-original=\"([^\"]+)\""
        )) {
            if let Some(cap) = re.captures(page) {
                cover = cap[1].to_string();
            }
        }
        if let Ok(re) = Regex::new(&format!(
            "(?s)href=\"/v5/{vid}-1-1\\.html\".{{0,1200}}?class=\"pic-text[^\"]*\"[^>]*>([^<]*)<"
        )) {
            if let Some(cap) = re.captures(page) {
                remark = strip_tags(&cap[1]);
            }
        }
    }
    (cover, remark)
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let base = live_base().await?;
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{base}{series_id}")
    };
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Referer", format!("{base}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "黄色仓库请求 HTTP {}",
            resp.status().as_u16()
        )));
    }
    let page = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let mut title = pick(&page, "(?s)<title[^>]*>(.*?)</title>");
    if let Ok(re) = Regex::new("^(.*?) - (?:黄色仓库|hsck)[^<]*$") {
        if let Some(cap) = re.captures(&title) {
            title = strip_tags(&cap[1]);
        }
    }
    if title.is_empty() {
        title = "黄色仓库".to_string();
    }
    let vid = Regex::new(r"/v5/(\d+)-1-1\.html")
        .ok()
        .and_then(|re| re.captures(&url))
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let (mut cover, mut remark) = self_cover_remark(&page, &vid);
    if cover.is_empty() {
        if let Ok(re) =
            Regex::new("(?i)data-original=\"(https?://[^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"")
        {
            if let Some(cap) = re.captures(&page) {
                cover = cap[1].to_string();
            }
        }
    }
    if remark.is_empty() {
        remark = pick(&page, "(?s)<p class=\"sub\"[^>]*>(.*?)</p>");
    }
    if remark.is_empty() {
        remark = pick(&page, "(?s)class=\"pic-text[^\\\"]*\"[^>]*>(.*?)</");
    }
    let mut extra = serde_json::Map::new();
    if !remark.is_empty() {
        extra.insert("remark".to_string(), Value::String(remark));
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": [episode_json(&url, "正片", &url)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = live_base().await?;
    let html = get_text(&search_url(query)).await?;
    let items = parse_cards(&html, &base);
    Ok(json!({"items": items}))
}

/// 取流参数：详情页 JS 里的 AID/ASID/ANID/AK。
fn extract_count_params(page: &str) -> Option<(String, String, String, String)> {
    let re = Regex::new(r"var AID='(\d+)', ASID='(\d+)', ANID='(\d+)', AK='([0-9a-f]+)'").ok()?;
    let cap = re.captures(page)?;
    Some((
        cap[1].to_string(),
        cap[2].to_string(),
        cap[3].to_string(),
        cap[4].to_string(),
    ))
}

/// 取流（站内真实链路）：详情页取 AID/ASID/ANID/AK → 按站内
/// 6 秒倒计时等 6 秒 → POST /static/count.php → {ok, u}，
/// u 为 base64 编码的真实地址。reqwest 未开 cookies 特性，
/// 详情页的会话饼干需手动从 Set-Cookie 取出，随 POST 带上。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let base = live_base().await?;
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{base}{video_id}")
    };
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Referer", format!("{base}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "黄色仓库请求 HTTP {}",
            resp.status().as_u16()
        )));
    }
    let cookies: Vec<String> = resp
        .headers()
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .filter_map(|s| s.split(';').next())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    let page = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let Some((aid, asid, anid, ak)) = extract_count_params(&page) else {
        return Err(ApiError::Internal(
            "黄色仓库未取到播放参数（详情页无 AID/AK，须手机复验）".into(),
        ));
    };
    tokio::time::sleep(Duration::from_secs(6)).await;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let form = format!(
        "id={aid}&sid={asid}&nid={anid}&tk={ak}&g=1&x=512&y=384&dt=200&sw=1920&sh=1080&tz=-480&t={now_ms}"
    );
    let mut req = client()?
        .post(format!("{base}/static/count.php"))
        .header(
            "Content-Type",
            "application/x-www-form-urlencoded; charset=UTF-8",
        )
        .header("X-Requested-With", "XMLHttpRequest")
        .header("Referer", &url)
        .header("Origin", &base)
        .header("Accept", "application/json, text/javascript, */*; q=0.01")
        .body(form);
    if !cookies.is_empty() {
        req = req.header("Cookie", cookies.join("; "));
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if resp.status().as_u16() != 200 {
        return Err(ApiError::Internal(format!(
            "黄色仓库取流 HTTP {}",
            resp.status().as_u16()
        )));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let ok = body.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
    let encoded = body.get("u").and_then(|v| v.as_str()).unwrap_or("");
    if !ok || encoded.is_empty() {
        let err = body.get("err").and_then(|v| v.as_str()).unwrap_or("");
        return Err(ApiError::Internal(format!(
            "黄色仓库未取到播放地址{err}，须手机复验"
        )));
    }
    let decoded = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
        .map_err(|_| ApiError::Internal("黄色仓库播放地址解码失败".into()))?;
    let stream = String::from_utf8_lossy(&decoded).trim().to_string();
    if !stream.starts_with("http") {
        return Err(ApiError::Internal("黄色仓库未取到有效地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{base}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn count_params_real_snippet() {
        let page = "var AID='286655', ASID='1', ANID='1', AK='75f636d942d0bfe4c7a223d40b537a2cd6c9e032ce704e9a953c8a5a53832e62';";
        let (aid, asid, anid, ak) = extract_count_params(page).unwrap();
        assert_eq!(aid, "286655");
        assert_eq!(asid, "1");
        assert_eq!(anid, "1");
        assert_eq!(ak.len(), 64);
        assert!(extract_count_params("no params here").is_none());
    }

    #[test]
    fn self_cover_remark_real_snippet() {
        // 2026-11-06 实测 286655 详情页片段：首条是 286705 的封面，
        // 当前视频自己的卡在后面（封面 1405bc65、时长 1:58:44）。
        let page = "<a class=\"stui-vodlist__thumb lazyload\" href=\"/v5/286705-1-1.html\" data-original=\"https://23.225.11.173:8443/video/m3u8/2026/11/05/e0505ca8/vod.jpg\"><span class=\"pic-text text-right\">1:50:33</span></a><a class=\"stui-vodlist__thumb lazyload\" href=\"/v5/286655-1-1.html\" data-original=\"https://23.225.11.173:8443/video/m3u8/2026/11/05/1405bc65/vod.jpg\"><span class=\"pic-text text-right\">1:58:44</span></a>";
        let (cover, remark) = self_cover_remark(page, "286655");
        assert_eq!(
            cover,
            "https://23.225.11.173:8443/video/m3u8/2026/11/05/1405bc65/vod.jpg"
        );
        assert_eq!(remark, "1:58:44");
        let (cover2, _) = self_cover_remark(page, "999999");
        assert_eq!(cover2, "");
    }

    #[test]
    fn search_url_has_13_dashes() {
        let url = search_url("麻豆");
        assert!(url.contains("-------------.html"));
        assert_eq!(url.matches('-').count(), 13);
    }

    #[test]
    fn cards_only_v5_links() {
        let page = "<div class=\"stui-vodlist__thumb\"><a href=\"/v5/123-1-1.html\" title=\"标题\"><img data-original=\"https://img.example.com/1.jpg\"></a></div><div class=\"stui-vodlist__thumb\"><a href=\"https://ad.example.com/x.html\" title=\"广告\"></a></div>";
        let items = parse_cards(page, "https://444.9966hsck.cc");
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["vod_id"],
            "https://444.9966hsck.cc/v5/123-1-1.html"
        );
    }
}
