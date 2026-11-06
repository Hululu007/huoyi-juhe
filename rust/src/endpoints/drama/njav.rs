//! nJAV：HTML 站（njav.com），列表与详情走 HTML 解析，取流走
//! /vv/<id> → /jm/<base64> → PLAYER_CONFIG 的 m3u8/hls 两跳。
//! 直连失败时走 tv506.ystv.top 中继兜底。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://www.njav.com";
const REL: &str = "/zh";
const EDGE: &str = "https://tv506.ystv.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：路径，与站导航一致。
const CATS: &[(&str, &str)] = &[
    ("/zh/recent-update/", "最近更新"),
    ("/zh/new-release/", "新上映"),
    ("/zh/censored/", "有码"),
    ("/zh/uncensored/", "无码"),
    ("/zh/uncensored-leaked/", "无码流出"),
    ("/zh/amateur/", "素人"),
    ("/zh/chinese-av/", "中国AV"),
    ("/zh/chinese-live/", "中国直播"),
    ("/zh/korean-live/", "韩国直播"),
    ("/zh/english-subtitle/", "英文字幕"),
];

fn jm_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/jm/([A-Za-z0-9+/=]+)").unwrap())
}

fn m3u8_field_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""m3u8"\s*:\s*"([^"]+)""#).unwrap())
}

fn vid_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?:xvideos|video)/([A-Za-z0-9_-]+)").unwrap())
}

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
        .header("Referer", referer);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("nJAV 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn fetch_with_edge(url: &str) -> ApiResult<String> {
    match fetch(url, &format!("{HOST}/")).await {
        Ok(t) if !t.trim().is_empty() => Ok(t),
        _ => {
            let proxy = format!(
                "{EDGE}/api/v1/proxy?url={}",
                url::form_urlencoded::byte_serialize(url.as_bytes()).collect::<String>()
            );
            let req = client()?
                .get(&proxy)
                .header("User-Agent", UA)
                .header("Accept", "*/*")
                .header("Referer", format!("{EDGE}/"));
            let resp = req
                .send()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))?;
            let status = resp.status().as_u16();
            if status != 200 {
                return Err(ApiError::Internal(format!("nJAV 中继 HTTP {status}")));
            }
            resp.text()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))
        }
    }
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

/// `<a href="...xvideos/<slug>">` 块解析。
/// jar 原文：匹配 `<a href="xvideos/...">...</a>`，封面取 `<a>` 内
/// data-src，标题（detail div 内 `<a>` 文本，无则 img alt，无则
/// slug）与备注（duration）取匹配起点往后 1200 字内。
/// 注意：按 `<a href="` 切分会把 detail 链接切成下一块、标题窗口
/// 跨不过边界，故用整页位置扫描；每条目缩略图与详情两处同 slug
/// 链接，按 vod_id 去重（保留先出现的缩略图块）。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for (pos, _) in html.match_indices("<a href=\"") {
        let href_start = pos + 9;
        let href_end = html[href_start..]
            .find('"')
            .map(|i| href_start + i)
            .unwrap_or(html.len());
        let href = &html[href_start..href_end];
        if !href.contains("xvideos/") {
            continue;
        }
        let slug = href.rsplit('/').next().unwrap_or("");
        if slug.is_empty() {
            continue;
        }
        let vod_id = format!("{HOST}{REL}/xvideos/{slug}");
        if seen.contains(&vod_id) {
            continue;
        }
        seen.push(vod_id.clone());
        let window = match html[pos..].get(..1400) {
            Some(w) => w,
            None => &html[pos..],
        };
        let inner_end = window.find("</a>").unwrap_or(window.len());
        let inner = &window[..inner_end];
        let cover = if let Some(p) = inner.find("data-src=\"") {
            let s = p + 10;
            inner[s..].find('"').map(|e| &inner[s..s + e]).unwrap_or("")
        } else if let Some(p) = inner.find("src=\"") {
            let s = p + 5;
            inner[s..].find('"').map(|e| &inner[s..s + e]).unwrap_or("")
        } else {
            ""
        };
        let mut title = String::new();
        if let Some(p) = window.find("class=\"detail\"") {
            let after = &window[p..];
            if let Some(a) = after.find("<a") {
                let s = after[a..]
                    .find('>')
                    .map(|i| a + i + 1)
                    .unwrap_or(after.len());
                let e = after[s..]
                    .find("</a>")
                    .map(|i| s + i)
                    .unwrap_or(after.len());
                title = strip_tags(&after[s..e]);
            }
        }
        if title.is_empty() {
            if let Some(p) = inner.find("alt=\"") {
                let s = p + 5;
                title = inner[s..]
                    .find('"')
                    .map(|e| inner[s..s + e].to_string())
                    .unwrap_or_default();
            }
        }
        if title.is_empty() {
            title = truncate(slug, 90);
        }
        let mut remark = String::new();
        if let Some(p) = window.find("class=\"duration\"") {
            let after = &window[p..];
            let s = after.find('>').map(|i| i + 1).unwrap_or(0);
            let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
            remark = truncate(strip_tags(&after[s..e]).trim(), 12);
        }
        items.push(item_json(&vod_id, &title, cover, &remark));
    }
    items
}

fn og(html: &str, prop: &str) -> String {
    let marker = format!("property=\"{prop}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let Some(c) = after.find("content=\"") else {
        return String::new();
    };
    let s = c + 9;
    after[s..]
        .find('"')
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(html: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = html.find(&open) else {
        return String::new();
    };
    let after = &html[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page > 1 {
        format!("{HOST}{category_id}?page={page}")
    } else {
        format!("{HOST}{category_id}")
    };
    let html = fetch_with_edge(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch_with_edge(series_id).await?;
    let mut title = tag_text(&html, "h1");
    if title.is_empty() {
        title = tag_text(&html, "title");
    }
    if title.is_empty() {
        return Err(ApiError::Internal("nJAV 未返回影片资料".into()));
    }
    let mut cover = og(&html, "og:image");
    if cover.is_empty() {
        if let Some(p) = html.find("static.javcdn.vip/resize/") {
            let s = html[..p].rfind('"').map(|i| i + 1).unwrap_or(p);
            let e = html[p..].find('"').map(|i| p + i).unwrap_or(html.len());
            cover = html[s..e].to_string();
        }
    }
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${series_id}"), "正片", series_id)],
    }))
}

/// 取流：vod_id → /vv/<id> → /jm/<base64> → PLAYER_CONFIG 的 m3u8/hls。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let vid = vid_re()
        .captures(&page_url)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| ApiError::Internal("nJAV 无法从地址里取出视频 id".into()))?;
    let vv = fetch(&format!("{HOST}/vv/{vid}"), &format!("{HOST}/")).await?;
    let jm = jm_re()
        .captures(&vv)
        .and_then(|c| c.get(0))
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| ApiError::Internal("nJAV 未在 /vv 页找到 /jm 链接".into()))?;
    let jm_html = fetch(&format!("{HOST}{jm}"), &format!("{HOST}/vv/{vid}")).await?;
    let mut url = String::new();
    if let Some(p) = jm_html.find("PLAYER_CONFIG") {
        let after = &jm_html[p..];
        if let Some(s) = after.find('{') {
            if let Some(e) = after[s..].find("};") {
                if let Ok(v) = serde_json::from_str::<Value>(&after[s..s + e + 1]) {
                    url = super::text_of(&v, &["m3u8", "hls"]);
                }
            }
        }
    }
    if url.is_empty() {
        url = m3u8_field_re()
            .captures(&jm_html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }
    if url.is_empty() {
        if let Some(p) = jm_html.find("https://helvid.com/m/") {
            let e = jm_html[p..]
                .find(|c: char| c == '"' || c == '\'' || c.is_whitespace())
                .map(|i| p + i)
                .unwrap_or(jm_html.len());
            url = jm_html[p..e].to_string();
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("nJAV 未取到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}{REL}/search?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch_with_edge(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_card() {
        let html = r#"<a href="/zh/xvideos/abc123"><img data-src="/c.jpg"><div class="detail"><a>片名一</a></div><span class="duration">12:34</span></a>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "片名一");
        assert_eq!(items[0]["remark"], "12:34");
    }

    #[test]
    fn vid_extract() {
        let cap = vid_re()
            .captures("https://www.njav.com/zh/xvideos/abc-123")
            .unwrap();
        assert_eq!(&cap[1], "abc-123");
    }
}
