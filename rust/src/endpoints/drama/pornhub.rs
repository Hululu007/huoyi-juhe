//! Pornhub 镜像站：列表按 `data-video-vkey` 切卡，详情取
//! mediaDefinitions 的 HLS 多档（按清晰度降序）与 og:video 直连。
//!
//! 与 Dart 的 ZakaPornhubAmns 一一对应。分类与站内导航 1:1（8 项）。
//! 分页：路径含 `page=\d+` 时替换，否则按有无 `?` 补 `?page=N` 或
//! `&page=N`。列表卡双版式：旧版式标题取 title 属性、封面取
//! data-image、时长取 `<var class="duration">`；新版式标题取
//! `<div class="title">` 内链接文本（或 videoThumb 的 alt）、封面取
//! data-poster（或 videoThumb 的 src）、时长取 `<span class="time">`。
//! 详情：标题取 og:title（无则 <title>），封面取 og:image，时长取
//! video:duration（秒转分钟），简介取 og:description；分集为 HLS
//! 各档（`<档>P`）加 `MP4直连` 一集；无源时报错，不出死分集。
//! 注意：Java 的 solveKey（KEY cookie 解谜）在本机多次实测均未触发
//! （列表/详情多次 200），故未移植；翻页偶发 JS 饼干挑战页（置
//! document.cookie 后 reload），遇上即换下一镜站重试。
//! 实测（2026-11-06）：cn.pornhub365.com 列表 31 条、翻页 47 条、
//! 搜索 30 条、分类 teen 30 条；详情 HLS 4 档，1080P 清单 98 分片
//! 总 1001.6 秒对卡片 16:41，首分片 200 + TS 魔数 0x47。
//! master m3u8 须跟 302 跳转（reqwest 默认跟）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

/// 镜站池：先 cn.pornhub365.com（本机实测 200、新版式 31 条），再其余。
const HOSTS: &[&str] = &[
    "https://cn.pornhub365.com",
    "https://cn.pornhub666.cc",
    "https://cn.pornhub163.com",
    "https://cn.pornhub666.com",
    "https://cn.pornhub365.mom",
    "https://cn.pornhub365.sbs",
    "https://cn.pornhub365.top",
    "https://cn.pornhub1.icu",
    "https://cn.pornhub1.cc",
    "https://cn.pornhub1.mom",
];

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[名, 路径]，与站内导航 1:1。“青少年 Teen”为 Pornhub
/// 正常分类（成年演员），triage 未列为萝莉旗标，保留。
const CATEGORIES: &[(&str, &str)] = &[
    ("最新上传", "/video?page=1"),
    ("最多观看", "/video?o=mv&t=m"),
    ("最高评分", "/video?o=tr&t=m"),
    ("青少年 Teen", "/categories/teen"),
    ("动漫里番 Hentai", "/categories/hentai"),
    ("校园 College", "/categories/college"),
    ("明星 Pornstar", "/categories/pornstar"),
    ("辣妹 Babe", "/categories/babe"),
];

/// 是否像 Cloudflare 拦截页或 JS 饼干挑战页。
fn is_challenge(body: &str) -> bool {
    let lower = body.to_lowercase();
    lower.contains("just a moment")
        || lower.contains("cf_chl")
        || lower.contains("challenge-form")
        || lower.contains("attention required")
        || (body.contains("document.cookie") && body.contains("document.location.reload"))
}

/// 取页：按镜站顺序试，首个 200 且无 CF 挑战标记的正文即用。
/// 返回（正文，实际用到的 host）。
async fn fetch(path: &str) -> ApiResult<(String, String)> {
    let mut last_err = String::new();
    for host in HOSTS {
        let url = format!("{host}{path}");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .header("Referer", format!("{host}/"))
            .send()
            .await;
        match resp {
            Ok(r) if r.status().as_u16() == 200 => {
                let text = r.text().await.unwrap_or_default();
                if !is_challenge(&text) {
                    return Ok((text, host.to_string()));
                }
                last_err = "CF 挑战页".into();
            }
            Ok(r) => last_err = format!("HTTP {}", r.status().as_u16()),
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!(
        "Pornhub 各镜站均不可用：{last_err}"
    )))
}

/// 分页地址：含 `page=\d+` 则替换，否则按有无 `?` 补参数。
fn page_url(path: &str, page: i64) -> String {
    let re = Regex::new(r"page=\d+").unwrap();
    if re.is_match(path) {
        re.replace(path, format!("page={page}")).to_string()
    } else if path.contains('?') {
        format!("{path}&page={page}")
    } else {
        format!("{path}?page={page}")
    }
}

/// 解常见 HTML 实体。
fn unesc(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 列表卡：按 `data-video-vkey="` 切块；旧版式与新版式各取一遍。
fn parse_cards(html: &str) -> Vec<Value> {
    let title_re =
        Regex::new(r#"href="/view_video\.php\?viewkey=[0-9a-f]+"\s+title="([^"]{1,300})""#)
            .unwrap();
    let title_new_re =
        Regex::new(r#"(?s)<div class="title">\s*<a[^>]*>\s*([^<]{2,300}?)\s*</a>"#).unwrap();
    let alt_re = Regex::new(r#"<img[^>]*class="videoThumb[^>]*alt="([^"]{2,300})""#).unwrap();
    let cover_re = Regex::new(r#"data-image="([^"]+)""#).unwrap();
    let poster_re = Regex::new(r#"data-poster="(https?://[^"]+)""#).unwrap();
    let thumb_re = Regex::new(r#"(?s)<img[^>]*class="videoThumb[^>]*src="([^"]+)""#).unwrap();
    let dur_re = Regex::new(r#"<var class="duration">\s*([^<]{1,20}?)\s*</var>"#).unwrap();
    let time_re = Regex::new(r#"<span class="time">\s*([^<]{1,20}?)\s*</span>"#).unwrap();
    let vkey_re = Regex::new(r"^([0-9a-zA-Z]{6,})").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("data-video-vkey=\"").skip(1) {
        let vkey = match vkey_re.captures(block) {
            Some(c) => c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
            None => continue,
        };
        if vkey.is_empty() || seen.contains(&vkey) {
            continue;
        }
        let title = title_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| unesc(m.as_str()))
            .or_else(|| {
                title_new_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| unesc(m.as_str()))
            })
            .or_else(|| {
                alt_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| unesc(m.as_str()))
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        seen.push(vkey.clone());
        let cover = cover_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .or_else(|| {
                poster_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
            .or_else(|| {
                thumb_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
            .map(|u| {
                if let Some(rest) = u.strip_prefix("//") {
                    format!("https://{rest}")
                } else {
                    u
                }
            })
            .unwrap_or_default();
        let remark = dur_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .or_else(|| {
                time_re
                    .captures(block)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().trim().to_string())
            })
            .unwrap_or_default();
        let id = format!("/view_video.php?viewkey={vkey}");
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 取 og 标签（property=... content="..."）。
fn og(html: &str, prop: &str) -> String {
    let re = Regex::new(&format!(
        r#"<meta[^>]+property="{prop}"[^>]+content="([^"]*)""#
    ))
    .unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

/// 从 id 里取 viewkey（`viewkey=` 后到 `&` 或末尾）。
fn viewkey_of(id: &str) -> String {
    if let Some(pos) = id.find("viewkey=") {
        let rest = &id[pos + 8..];
        let end = rest.find('&').unwrap_or(rest.len());
        rest[..end].to_string()
    } else {
        id.trim().to_string()
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(name, path)| category_json(path, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = category_id.trim();
    let path = if path.is_empty() {
        "/video?page=1"
    } else {
        path
    };
    let url = page_url(path, page);
    let (html, _host) = fetch(&url).await?;
    let cards = parse_cards(&html);
    let has_more = cards.len() >= 20;
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let key = viewkey_of(series_id);
    if key.is_empty() {
        return Err(ApiError::Internal("Pornhub 未指定影片".into()));
    }
    let path = format!("/view_video.php?viewkey={key}");
    let (html, _host) = fetch(&path).await?;
    let mut title = og(&html, "og:title");
    if title.is_empty() {
        let re = Regex::new(r"(?s)<title>(.*?)</title>").unwrap();
        title = re
            .captures(&html)
            .and_then(|c| c.get(1))
            .map(|m| unesc(m.as_str()))
            .unwrap_or_default();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("Pornhub 未返回影片标题".into()));
    }
    let cover = og(&html, "og:image");
    let mut synopsis = og(&html, "og:description");
    let dur = og(&html, "video:duration");
    if let Ok(secs) = dur.parse::<i64>() {
        if secs > 0 {
            let mins = secs / 60;
            let sec = secs % 60;
            synopsis.push_str(&format!("\n时长：{mins:02}:{sec:02}"));
        }
    }
    // mediaDefinitions：按 `"format":"hls"` 切段，取 videoUrl 与档位。
    let mut grades: Vec<(i64, String)> = Vec::new();
    if let Some(start) = html.find("mediaDefinitions") {
        let tail = &html[start..];
        for seg in tail.split("\"format\":\"hls\"").skip(1) {
            let end = seg.find("\"format\"").unwrap_or(seg.len());
            let seg = &seg[..end];
            let url_re = Regex::new(r#""videoUrl":"([^"]+)""#).unwrap();
            let url = url_re
                .captures(seg)
                .and_then(|c| c.get(1))
                .map(|m| {
                    m.as_str()
                        .replace("\\/", "/")
                        .replace("\\u0026", "&")
                        .trim()
                        .to_string()
                })
                .unwrap_or_default();
            if url.is_empty() {
                continue;
            }
            let q_re = Regex::new(r#""quality":"(\d+)""#).unwrap();
            let h_re = Regex::new(r#""height":(\d+)"#).unwrap();
            let grade = q_re
                .captures(seg)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().parse::<i64>().unwrap_or(0))
                .or_else(|| {
                    h_re.captures(seg)
                        .and_then(|c| c.get(1))
                        .map(|m| m.as_str().parse::<i64>().unwrap_or(0))
                })
                .unwrap_or(0);
            if !grades.iter().any(|(_, u)| *u == url) {
                grades.push((grade, url));
            }
        }
    }
    grades.sort_by(|a, b| b.0.cmp(&a.0));
    let mp4 = og(&html, "og:video:secure_url");
    let mp4 = if mp4.is_empty() {
        og(&html, "og:video")
    } else {
        mp4
    };
    let mut episodes: Vec<Value> = Vec::new();
    for (grade, url) in &grades {
        let name = if *grade > 0 {
            format!("{grade}P")
        } else {
            "自动".to_string()
        };
        episodes.push(episode_json(url, &name, series_id));
    }
    if !mp4.is_empty() {
        episodes.push(episode_json(&mp4, "MP4直连", series_id));
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("Pornhub 本条未取到播放清单".into()));
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

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = query.trim();
    let enc: String = {
        let mut out = String::with_capacity(q.len());
        for b in q.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char)
                }
                b' ' => out.push('+'),
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    };
    let path = format!("/video/search?search={enc}&page=1");
    let (html, _host) = fetch(&path).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id.trim();
    if url.starts_with("http") {
        Ok(json!({"url": url}))
    } else {
        Err(ApiError::Internal("Pornhub 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_8() {
        assert_eq!(CATEGORIES.len(), 8);
        assert_eq!(CATEGORIES[0], ("最新上传", "/video?page=1"));
    }

    #[test]
    fn page_url_forms() {
        assert_eq!(page_url("/video?page=1", 3), "/video?page=3");
        assert_eq!(page_url("/video?o=mv&t=m", 2), "/video?o=mv&t=m&page=2");
        assert_eq!(page_url("/categories/teen", 2), "/categories/teen?page=2");
    }

    #[test]
    fn viewkey_extract() {
        assert_eq!(
            viewkey_of("/view_video.php?viewkey=6ac68343c39ae&x=1"),
            "6ac68343c39ae"
        );
        assert_eq!(viewkey_of("6ac68343c39ae"), "6ac68343c39ae");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<li data-video-vkey="6ac68343c39ae"><a href="/view_video.php?viewkey=6ac68343c39ae" title="Sample Video"><img data-image="//ci.phncdn.com/videos/sample.jpg"></a><var class="duration">12:34</var></li>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/view_video.php?viewkey=6ac68343c39ae");
        assert_eq!(cards[0]["cover"], "https://ci.phncdn.com/videos/sample.jpg");
        assert_eq!(cards[0]["remark"], "12:34");
    }

    #[test]
    fn cards_parse_new_layout() {
        let html = r##"<li data-video-vkey="6ae9db5a2d16a"><div class="singleVideo"><a href="/view_video.php?viewkey=6ae9db5a2d16a" data-poster="https://cdn.example.com/poster.jpg"><img class="videoThumb js-videoThumb" src="https://cdn.example.com/thumb.jpg" alt="Rough anal ends with a huge cumshot"></a><div class="duration thumbOverlay"><span class="time">16:41</span></div></div><div class="title"><a href="/view_video.php?viewkey=6ae9db5a2d16a">Rough anal ends with a huge cumshot</a></div></li>"##;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/view_video.php?viewkey=6ae9db5a2d16a");
        assert_eq!(cards[0]["title"], "Rough anal ends with a huge cumshot");
        assert_eq!(cards[0]["cover"], "https://cdn.example.com/poster.jpg");
        assert_eq!(cards[0]["remark"], "16:41");
    }

    #[test]
    fn js_challenge_detected() {
        assert!(is_challenge(
            "<script>document.cookie=\"k=\"+n;document.location.reload(true);</script>"
        ));
        assert!(!is_challenge("<html><body>normal page</body></html>"));
    }
}
