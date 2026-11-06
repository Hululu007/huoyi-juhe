//! Javtiful（javtiful.com）：视频卡片站，列表与详情走 HTML 解析。
//! 取流：详情页 watch-config JSON 里的 playback ticket →
//! POST /video/{id}/playback，取 sources 里尺寸最大的 mp4 直链
//! （匿名可取，无需登录；实测 720p 直链 Range 206 + ftyp）。
//! 站内有 /premium 付费入口，只做免费部分，不绕付费墙。
//! 分类与站导航 1:1（最新/有码/无码/减码 + 21 个站内分类 +
//! 女优索引）；翻页 `?page=N`。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javtiful.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 + /categories 页 21 个分类 + 热门女优前 10。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新影片"),
    ("censored", "有码"),
    ("uncensored", "无码"),
    ("reducing-mosaic", "减码"),
    ("actresses", "女优"),
    ("cat:female-investigator", "Female Investigator"),
    ("cat:chinese-av", "Chinese AV"),
    ("cat:female-boss", "Female Boss"),
    ("cat:mature-woman", "Mature Woman"),
    ("cat:cosplay", "Cosplay"),
    ("cat:amateur", "Amateur"),
    ("cat:housekeeper", "Housekeeper"),
    ("cat:nurse", "Nurse"),
    ("cat:female-student", "Female Student"),
    ("cat:school-girls", "School Girls"),
    ("cat:office-lady", "Office Lady"),
    ("cat:sister-in-law", "Sister-in-law"),
    ("cat:hypnosis", "Hypnosis"),
    ("cat:beautiful-girl", "Beautiful Girl"),
    ("cat:bbw", "BBW"),
    ("cat:drama", "Drama"),
    ("cat:married-woman", "Married Woman"),
    ("cat:milf", "Milf"),
    ("cat:female-teacher", "Female Teacher"),
    ("cat:affair", "Affair"),
    ("cat:big-tits", "Big Tits"),
    ("actress:hatano-yui", "Hatano Yui"),
    ("actress:iioka-kanako", "Iioka Kanako"),
    ("actress:misono-waka", "Misono Waka"),
    ("actress:yayoi-mizuki", "Yayoi Mizuki"),
    ("actress:minatsuki-hikaru", "Minatsuki Hikaru"),
    ("actress:hanazawa-himari", "Hanazawa Himari"),
    ("actress:kuramoto-sumire", "Kuramoto Sumire"),
    ("actress:tenma-yui", "Tenma Yui"),
    ("actress:shinoda-yuu", "Shinoda Yuu"),
    ("actress:kitano-mina", "Kitano Mina"),
];

fn playback_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#""playback":\{"endpoint":"([^"]+)","ticket":"([^"]+)""#).unwrap()
    })
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
        return Err(ApiError::Internal(format!("Javtiful 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
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

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
        .trim()
        .to_string()
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
    decode_entities(&out)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// `<article class="video-card">` 卡片解析；广告卡（无 /video/ 链接）跳过。
fn parse_video_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        if !block.contains("video-card") {
            continue;
        }
        let href = match block.find("<a href=\"/video/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let id = abs_url(href);
        if seen.contains(&id) {
            continue;
        }
        let title = if let Some(p) = block.find("video-card__title\" title=\"") {
            let s = p + "video-card__title\" title=\"".len();
            block[s..]
                .find('"')
                .map(|e| decode_entities(&block[s..s + e]))
                .unwrap_or_default()
        } else if let Some(p) = block.find("alt=\"Thumbnail for ") {
            let s = p + 19;
            block[s..]
                .find('"')
                .map(|e| decode_entities(&block[s..s + e]))
                .unwrap_or_default()
        } else {
            String::new()
        };
        if title.is_empty() {
            continue;
        }
        let cover = if let Some(p) = block.find("data-front-lazy-src=\"") {
            let s = p + 21;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        let mut remark = String::new();
        if let Some(p) = block.find("video-card__details") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                let e = after[s..]
                    .find("</span>")
                    .map(|i| s + i)
                    .unwrap_or(after.len());
                let raw = strip_tags(&after[s..e]);
                remark = raw
                    .trim_start_matches(|c: char| c.is_ascii_alphabetic())
                    .trim()
                    .to_string();
            }
        }
        seen.push(id.clone());
        items.push(item_json(
            &id,
            &truncate(&title, 90),
            &abs_url(&cover),
            &remark,
        ));
    }
    items
}

/// `<article class="directory-card directory-card--actress">` 女优卡解析。
fn parse_actress_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for block in html.split("<article").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        if !block.contains("directory-card--actress") {
            continue;
        }
        let slug = match block.find("<a class=\"directory-card__link\" href=\"/actress/") {
            Some(p) => {
                let s = p + "<a class=\"directory-card__link\" href=\"/actress/".len();
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let name = if let Some(p) = block.find("directory-card__name\">") {
            let s = p + 22;
            block[s..]
                .find('<')
                .map(|e| decode_entities(&block[s..s + e]))
                .unwrap_or_default()
        } else {
            String::new()
        };
        if name.is_empty() {
            continue;
        }
        let cover = if let Some(p) = block.find("<img src=\"") {
            let s = p + 10;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        let count = if let Some(p) = block.find("directory-card__count\">") {
            let s = p + 23;
            block[s..]
                .find('<')
                .map(|e| block[s..s + e].trim().to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        items.push(item_json(
            &format!("actress:{slug}"),
            &name,
            &abs_url(&cover),
            &count,
        ));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let with_page = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}?page={page}")
        }
    };
    match category_id {
        "latest" => with_page(format!("{HOST}/videos")),
        "censored" | "uncensored" | "reducing-mosaic" => with_page(format!("{HOST}/{category_id}")),
        "actresses" => with_page(format!("{HOST}/actresses")),
        _ => {
            if let Some(v) = category_id.strip_prefix("cat:") {
                with_page(format!("{HOST}/category/{v}"))
            } else if let Some(v) = category_id.strip_prefix("actress:") {
                with_page(format!("{HOST}/actress/{v}"))
            } else {
                with_page(format!("{HOST}/videos"))
            }
        }
    }
}

fn meta_content(html: &str, attr: &str, key: &str) -> String {
    let marker = format!("{attr}=\"{key}\"");
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
        .map(|e| decode_entities(&after[s..s + e]))
        .unwrap_or_default()
}

fn tag_title(html: &str) -> String {
    let Some(p) = html.find("<title>") else {
        return String::new();
    };
    let s = p + 7;
    let e = html[s..]
        .find("</title>")
        .map(|i| s + i)
        .unwrap_or(html.len());
    let t = decode_entities(&html[s..e]);
    match t.rsplit_once(" | ") {
        Some((head, _)) => head.trim().to_string(),
        None => t,
    }
}

/// 从详情页 watch-config 取 (endpoint, ticket)。
fn extract_playback(html: &str) -> Option<(String, String)> {
    let cap = playback_re().captures(html)?;
    Some((cap[1].to_string(), cap[2].to_string()))
}

/// 从 playback 响应 JSON 取尺寸最大的直链。
fn pick_source(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body).ok()?;
    let sources = v.get("sources")?.as_array()?;
    let mut best: Option<(i64, String)> = None;
    for s in sources {
        let src = s
            .get("src")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if src.is_empty() {
            continue;
        }
        let size = s.get("size").and_then(|x| x.as_i64()).unwrap_or(0);
        if best.as_ref().map(|(b, _)| size > *b).unwrap_or(true) {
            best = Some((size, src));
        }
    }
    best.map(|(_, src)| src)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = if category_id == "actresses" {
        parse_actress_cards(&html)
    } else {
        parse_video_cards(&html)
    };
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("Javtiful 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let mut desc = meta_content(&html, "name", "description");
    let mut actresses: Vec<String> = Vec::new();
    let mut rest = html.as_str();
    while let Some(p) = rest.find("<a href=\"/actress/") {
        let after = &rest[p..];
        if let Some(gt) = after.find('>') {
            let s = gt + 1;
            if let Some(e) = after[s..].find("</a>") {
                let name = strip_tags(&after[s..s + e]);
                if !name.is_empty() && !actresses.contains(&name) {
                    actresses.push(name);
                }
            }
        }
        rest = &rest[p + 1..];
        if actresses.len() >= 6 {
            break;
        }
    }
    if !actresses.is_empty() {
        if !desc.is_empty() {
            desc.push('\n');
        }
        desc.push_str(&format!("女优：{}", actresses.join("、")));
    }
    let desc = truncate(&desc, 400);
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": abs_url(&cover),
        "synopsis": desc,
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${series_id}"), "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && (video_id.contains(".mp4") || video_id.contains(".m3u8")) {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let (endpoint, ticket) = extract_playback(&html)
        .ok_or_else(|| ApiError::Internal("Javtiful 详情页未找到 playback 票据".into()))?;
    let body = format!(
        "ticket={}",
        url::form_urlencoded::byte_serialize(ticket.as_bytes()).collect::<String>()
    );
    let resp = client()?
        .post(abs_url(&endpoint))
        .header("User-Agent", UA)
        .header("Accept", "application/json, */*")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Referer", &page_url)
        .body(body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "Javtiful playback HTTP {status}"
        )));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let src = pick_source(&text)
        .ok_or_else(|| ApiError::Internal("Javtiful 未从 playback 响应解出直链".into()))?;
    Ok(json!({
        "url": abs_url(&src),
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_video_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_video_card() {
        let html = r#"<article class="video-card">
    <a href="/video/115520/sodah-006" class="video-card__thumbnail">
        <img src="/assets/front/media/video-thumb-placeholder.svg" data-front-lazy-src="/uploads/uploads/videos/thumbs/2026/11/06/abc.jpg" alt="Thumbnail for SODAH-006 Test" decoding="async">
        <span class="video-card__details"><strong>FHD</strong>02:36:02</span>
    </a>
    <div class="video-card__copy">
        <a href="/video/115520/sodah-006" class="video-card__title" title="SODAH-006 A Sleepover Test">SODAH-006 A Sleepover Test</a>
        <div class="video-card__meta">5.4K views</div>
    </div>
</article>"#;
        let items = parse_video_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "SODAH-006 A Sleepover Test");
        assert_eq!(items[0]["remark"], "02:36:02");
        assert!(items[0]["cover"].as_str().unwrap().contains("abc.jpg"));
    }

    #[test]
    fn parse_actress_card() {
        let html = r#"<article class="directory-card directory-card--actress">
    <a class="directory-card__link" href="/actress/hatano-yui">
        <span class="directory-card__media">
            <img src="/uploads/uploads/collections/actresses/2026/04/27/f78.jpg" alt="Hatano Yui">
        </span>
        <span class="directory-card__copy">
            <strong class="directory-card__name">Hatano Yui</strong>
            <span class="directory-card__count">715 Videos</span>
        </span>
    </a>
</article>"#;
        let items = parse_actress_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "actress:hatano-yui");
        assert_eq!(items[0]["title"], "Hatano Yui");
        assert_eq!(items[0]["remark"], "715 Videos");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("latest", 1), "https://javtiful.com/videos");
        assert_eq!(
            catalog_url("latest", 2),
            "https://javtiful.com/videos?page=2"
        );
        assert_eq!(
            catalog_url("cat:cosplay", 2),
            "https://javtiful.com/category/cosplay?page=2"
        );
        assert_eq!(
            catalog_url("actress:hatano-yui", 1),
            "https://javtiful.com/actress/hatano-yui"
        );
        assert_eq!(
            catalog_url("actresses", 1),
            "https://javtiful.com/actresses"
        );
    }

    #[test]
    fn playback_extract_and_pick() {
        let html = r#"<script id="watch-config" type="application/json">{"playback":{"endpoint":"/video/69520/playback","ticket":"p1.69520.0.1793917392.abc"}}</script>"#;
        let (ep, tk) = extract_playback(html).unwrap();
        assert_eq!(ep, "/video/69520/playback");
        assert_eq!(tk, "p1.69520.0.1793917392.abc");
        let body = r#"{"success":true,"sources":[{"src":"/media/video/69520/480p?x=1","type":"video/mp4","size":480},{"src":"/media/video/69520/720p?x=2","type":"video/mp4","size":720}],"defaultQuality":720}"#;
        assert_eq!(pick_source(body).unwrap(), "/media/video/69520/720p?x=2");
    }

    #[test]
    fn tag_title_strips_suffix() {
        let html = "<title>230OREMO-255 Rino-chan | Javtiful</title>";
        assert_eq!(tag_title(html), "230OREMO-255 Rino-chan");
    }
}
