//! 低端影视（ddys.io）：免费高清电影/剧集/综艺/动漫站。
//! 列表走 HTML 解析（海报锚点卡片）；详情页 switchSource(...) 内嵌
//! `标题$地址#标题$地址` 多集串或单条 m3u8 直链；搜索走
//! /api/search-suggest JSON；首页走 /api/hot-movies JSON。
//! 取流：详情先验第一个可用源（首集 m3u8 拉到 #EXTM3U 才采用，
//! 死链跳下一个源）。只做免费在线播放；站内网盘下载（夸克/
//! 百度/迅雷）不走播放链，不碰登录/收藏。
//! （2026-11-06 实测：电影 fengbao13 源 1428 分片/1444 秒、首分片
//! 200 + 0x47；剧集 hn.bfvvs 源第 1 集 452 分片/1354 秒、首分片
//! 200，AES-128 加密故首字节非 0x47，属正常；个别源死链
//! fengbao12/lzcdn31 404，detail 验活跳过。）

use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const HOST: &str = "https://ddys.io";
const IMG: &str = "https://img.ddys.io";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 站导航 1:1：首页/电影/剧集/综艺/动漫（片单、收藏不是内容分类）。
const CATS: &[(&str, &str)] = &[
    ("home", "首页"),
    ("movie", "电影"),
    ("series", "剧集"),
    ("variety", "综艺"),
    ("anime", "动漫"),
];

fn poster_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<a href="/movie/([a-z0-9-]+)"[^>]*>\s*<img[^>]*src="([^"]+)"#).unwrap()
    })
}

fn title_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<h3[^>]*>\s*<a[^>]*>([^<]+)</a>"#).unwrap())
}

fn meta_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(\d{4})\s*·\s*(电影|剧集|综艺|动漫)").unwrap())
}

fn rating_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"badge-top-right">\s*([\d.]+)"#).unwrap())
}

fn source_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"switchSource\(\d+,\s*'([^']+)',\s*'([^']+)'\)"#).unwrap())
}

fn cover_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<img src="(https://img\.ddys\.io/[^"]+)""#).unwrap())
}

fn meta_desc_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<meta name="description" content="([^"]*)""#).unwrap())
}

fn title_tag_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<title>([^<]+)</title>").unwrap())
}

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("DDYS 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .trim()
        .to_string()
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

fn abs_url(path: &str) -> String {
    if path.starts_with("http") {
        path.to_string()
    } else if path.starts_with('/') {
        format!("{HOST}{path}")
    } else {
        format!("{HOST}/{path}")
    }
}

fn cover_of_slug(slug: &str) -> String {
    format!("{IMG}/movies/{slug}.webp")
}

fn slug_of_url(url: &str) -> String {
    url.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

/// 列表页海报卡片解析：海报锚点取 slug 与封面，其后 h3 取标题，
/// `年份 · 类型` 与右上角评分拼 remark。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in poster_re().captures_iter(html) {
        let slug = cap[1].to_string();
        if !seen.insert(slug.clone()) {
            continue;
        }
        let cover = cap[2].to_string();
        let m = cap.get(0).unwrap();
        let end = m.end();
        let window_end = (end + 2000).min(html.len());
        let window = &html[end..window_end];
        let title = title_re()
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|x| strip_tags(x.as_str()))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let mut remark = meta_re()
            .captures(window)
            .map(|c| format!("{} · {}", &c[1], &c[2]))
            .unwrap_or_default();
        if let Some(r) = rating_re()
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|x| x.as_str().to_string())
        {
            if !r.is_empty() && r != "0.0" {
                if remark.is_empty() {
                    remark = r;
                } else {
                    remark = format!("{remark} {r}");
                }
            }
        }
        items.push(item_json(
            &abs_url(&format!("/movie/{slug}")),
            &title,
            &cover,
            &remark,
        ));
    }
    items
}

/// /api/hot-movies 与 /api/search-suggest 的 data 数组解析。
fn parse_api_items(v: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let Some(arr) = v.get("data").and_then(|d| d.as_array()) else {
        return items;
    };
    for it in arr {
        let title = it
            .get("title")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        let url = it
            .get("url")
            .and_then(|u| u.as_str())
            .unwrap_or("")
            .to_string();
        if title.is_empty() || url.is_empty() {
            continue;
        }
        let slug = it
            .get("slug")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string();
        let slug = if slug.is_empty() {
            slug_of_url(&url)
        } else {
            slug
        };
        let year = it.get("year").map(|y| y.to_string()).unwrap_or_default();
        let typ = it
            .get("type")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        let rating = it
            .get("rating")
            .and_then(|r| r.as_str())
            .unwrap_or("")
            .to_string();
        let mut remark = String::new();
        if !year.is_empty() && year != "0" {
            remark.push_str(&year);
        }
        if !typ.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&typ);
        }
        if !rating.is_empty() && rating != "0.0" {
            if !remark.is_empty() {
                remark.push(' ');
            }
            remark.push_str(&rating);
        }
        items.push(item_json(
            &abs_url(&url),
            &title,
            &cover_of_slug(&slug),
            &remark,
        ));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{HOST}/{category_id}")
    } else {
        format!("{HOST}/{category_id}/page/{page}")
    }
}

/// 详情标题去后缀：`兽王武神丹帝拜恩免费在线观看_高清网盘下载 - 低端影视`
/// → `兽王武神丹帝拜恩`。
fn clean_detail_title(raw: &str) -> String {
    let mut t = raw.trim().to_string();
    if let Some(p) = t.find("免费在线观看") {
        t = t[..p].trim().to_string();
    }
    if let Some(p) = t.find(" - 低端影视") {
        t = t[..p].trim().to_string();
    }
    t
}

/// switchSource 载荷解析：`第1集$地址#第2集$地址` → 多集；
/// 裸 m3u8 地址 → 单集“正片”。载荷里偶有字面 `\t`，先清掉。
fn parse_source_payload(payload: &str, kind: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if kind != "m3u8" || !payload.contains(".m3u8") {
        return out;
    }
    let clean = payload.replace("\\t", "");
    if !clean.contains('$') {
        let url = clean.trim().to_string();
        if url.contains(".m3u8") {
            out.push(("正片".to_string(), url));
        }
        return out;
    }
    for part in clean.split('#') {
        let Some((title, url)) = part.split_once('$') else {
            continue;
        };
        let title = title.trim().to_string();
        let url = url.trim().to_string();
        if title.is_empty() || !url.contains(".m3u8") {
            continue;
        }
        out.push((title, url));
    }
    out
}

/// 详情页全部播放源（按站内顺序），每源一组（标题，地址）。
fn parse_sources(html: &str) -> Vec<Vec<(String, String)>> {
    let mut sources = Vec::new();
    for cap in source_re().captures_iter(html) {
        let eps = parse_source_payload(&cap[1], &cap[2]);
        if !eps.is_empty() {
            sources.push(eps);
        }
    }
    sources
}

/// 首集 m3u8 是否拉得到清单（死链源跳过用）；网络抖动时回 false，
/// 调用方回退到首个源，不因此报错。
async fn m3u8_live(url: &str, referer: &str) -> bool {
    let Ok(c) = client() else {
        return false;
    };
    let Ok(resp) = c
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Referer", referer)
        .send()
        .await
    else {
        return false;
    };
    if resp.status().as_u16() != 200 {
        return false;
    }
    match resp.text().await {
        Ok(t) => t.contains("#EXTM3U"),
        Err(_) => false,
    }
}

/// 在多个源里选第一个首集能拉到清单的源；都不通时回首个源。
async fn pick_source(sources: Vec<Vec<(String, String)>>, referer: &str) -> Vec<(String, String)> {
    if sources.is_empty() {
        return Vec::new();
    }
    for eps in &sources {
        if let Some((_, url)) = eps.first() {
            if m3u8_live(url, referer).await {
                return eps.clone();
            }
        }
    }
    sources.into_iter().next().unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if category_id == "home" {
        let url = format!("{HOST}/api/hot-movies");
        let text = fetch(&url, &format!("{HOST}/")).await?;
        let v: Value = serde_json::from_str(&text)
            .map_err(|e| ApiError::Internal(format!("DDYS 首页 JSON 解析失败：{e}")))?;
        let items = parse_api_items(&v);
        return Ok(json!({"items": items, "has_more": false}));
    }
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let raw_title = title_tag_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    let title = clean_detail_title(&raw_title);
    if title.is_empty() {
        return Err(ApiError::Internal("DDYS 未返回影片资料".into()));
    }
    let slug = slug_of_url(series_id);
    let cover = cover_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| cover_of_slug(&slug));
    let desc = meta_desc_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| truncate(&strip_tags(m.as_str()), 400))
        .unwrap_or_default();
    let sources = parse_sources(&html);
    if sources.is_empty() {
        return Err(ApiError::Internal("DDYS 详情页未找到播放源".into()));
    }
    let eps = pick_source(sources, series_id).await;
    let episodes: Vec<Value> = eps
        .iter()
        .map(|(t, u)| episode_json(&format!("{t}${u}"), t, series_id))
        .collect();
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": {},
        "episodes": episodes,
    }))
}

/// 从 `标题$地址` 或裸地址里取出 m3u8 直链；不是直链回 None。
fn direct_url(video_id: &str) -> Option<String> {
    if !video_id.contains(".m3u8") {
        return None;
    }
    Some(
        video_id
            .rsplit_once('$')
            .map(|(_, u)| u.to_string())
            .unwrap_or_else(|| video_id.to_string()),
    )
}

fn play_json(url: String) -> Value {
    json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    })
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    // 形如 `第1集$https://...m3u8` 或裸 m3u8 直链。
    if let Some(url) = direct_url(video_id) {
        return Ok(play_json(url));
    }
    // 退化：传来的是详情页地址，现取详情首集。
    if video_id.starts_with("http") {
        let d = detail(video_id).await?;
        if let Some(ep) = d
            .get("episodes")
            .and_then(|e| e.as_array())
            .and_then(|a| a.first())
        {
            let vid = ep
                .get("video_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if let Some(url) = direct_url(&vid) {
                return Ok(play_json(url));
            }
        }
    }
    Err(ApiError::Internal("DDYS 未从 video_id 解出播放地址".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{HOST}/api/search-suggest"), &[("q", query)]);
    let text = fetch(&url, &format!("{HOST}/")).await?;
    let v: Value = serde_json::from_str(&text)
        .map_err(|e| ApiError::Internal(format!("DDYS 搜索 JSON 解析失败：{e}")))?;
    let items = parse_api_items(&v);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_card() {
        let html = r#"<a href="/movie/good-fortune"><img src="https://img.ddys.io/movies/good-fortune.webp" class="x" loading="lazy"></a><div class="p-4"><h3 class="t"><a href="/movie/good-fortune" target="_blank">好运</a></h3><div class="text-xs">2025 · 电影</div><div class="poster-badge badge-top-right">6.2</div></div><a href="/movie/honor"><img src="https://img.ddys.io/movies/honor.webp"></a><div class="p-4"><h3><a href="/movie/honor">荣耀</a></h3><div>2026 · 剧集</div></div>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["title"], "好运");
        assert_eq!(items[0]["remark"], "2025 · 电影 6.2");
        assert_eq!(
            items[0]["cover"],
            "https://img.ddys.io/movies/good-fortune.webp"
        );
        assert_eq!(items[1]["title"], "荣耀");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("movie", 1), "https://ddys.io/movie");
        assert_eq!(catalog_url("series", 2), "https://ddys.io/series/page/2");
        assert_eq!(catalog_url("anime", 174), "https://ddys.io/anime/page/174");
    }

    #[test]
    fn clean_title_strips_suffix() {
        assert_eq!(
            clean_detail_title("兽王武神丹帝拜恩免费在线观看_高清网盘下载 - 低端影视"),
            "兽王武神丹帝拜恩"
        );
        assert_eq!(
            clean_detail_title("怪人录像带 第三季免费在线观看_高清网盘下载 - 低端影视"),
            "怪人录像带 第三季"
        );
    }

    #[test]
    fn parse_source_payload_multi() {
        let p = "第1集$https://hn.bfvvs.com/play/av2Z81Va/index.m3u8#第2集$https://hn.bfvvs.com/play/bmZyY5pd/index.m3u8";
        let eps = parse_source_payload(p, "m3u8");
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].0, "第1集");
        assert!(eps[1].1.ends_with("bmZyY5pd/index.m3u8"));
    }

    #[test]
    fn parse_source_payload_bare_and_tab() {
        let bare = parse_source_payload("https://hn.bfvvs.com/play/e5yWRMRe/index.m3u8", "m3u8");
        assert_eq!(bare.len(), 1);
        assert_eq!(bare[0].0, "正片");
        let tabbed = parse_source_payload(
            "第3集\\t$https://hn.bfvvs.com/play/dPNQJDwa/index.m3u8",
            "m3u8",
        );
        assert_eq!(tabbed.len(), 1);
        assert_eq!(tabbed[0].0, "第3集");
        assert!(parse_source_payload("第1集$https://x/1.mp4", "mp4").is_empty());
    }

    #[test]
    fn parse_api_items_shape() {
        let v: Value = serde_json::from_str(
            r#"{"success":true,"data":[{"title":"好运","slug":"good-fortune","year":2025,"rating":"6.2","type":"电影","url":"/movie/good-fortune"}]}"#,
        )
        .unwrap();
        let items = parse_api_items(&v);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://ddys.io/movie/good-fortune");
        assert_eq!(
            items[0]["cover"],
            "https://img.ddys.io/movies/good-fortune.webp"
        );
        assert_eq!(items[0]["remark"], "2025 · 电影 6.2");
    }
}
