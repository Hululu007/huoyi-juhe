//! 🔞TokyoMotion：www.tokyomotion.net，日本用户上传 tube（素人为主）。
//!
//! 列表走 HTML 解析（`thumb-popu` 卡片：封面 cdn.tokyo-motion.net
//! tmb224、`<div class="duration">`、标题 span）；详情页 video-js
//! 的 `<source src="https://www.tokyomotion.net/vsrc/sd/{hash}">`
//! 301 到 www46.tokyomotion.net 的签名 mp4（md5 + expires 参数，
//! 现取现用，play 里跟跳转拿最终地址）。
//! 验门（2026-11-06 本机出口实测）：tokyomotion.net 301 到 www；
//! /videos 20 条/页，jav 分类 p1/p2 各 20 条不重合（`?page=N`）；
//! 搜索 JAV 20 条；详情 German Amateur Creampied（id 7174861，
//! 卡片 08:52，meta video:duration 531.96 秒）；vsrc 取到的签名
//! mp4 Range 206 + ftypisom（1000B）。
//! 分类与站导航 1:1（最新视频 + /categories 页的 9 个分类）；
//! Tags 页无分类链接，不单列；Albums 为图片区，不含。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://www.tokyomotion.net";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 站内 9 分类（/categories 页实测，显示名即站内原名）。
const CATS: &[(&str, &str)] = &[
    ("amateur", "Amateur"),
    ("asian", "Asian"),
    ("euro", "Euro"),
    ("hentai", "HENTAI"),
    ("homemade", "Homemade"),
    ("jav", "JAV"),
    ("pissing", "Pissing"),
    ("voyeur", "Voyeur"),
    ("webcam", "WebCam"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "TokyoMotion 请求 HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
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

/// `<a href="/video/{id}/{slug}" class="thumb-popu">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a href=\"/video/").skip(1) {
        let Some(e) = block.find('"') else {
            continue;
        };
        let path = &block[..e];
        if !path.contains('/') {
            continue;
        }
        // 只认带 thumb-popu 类的视频卡（排除相关推荐外的杂链接）。
        // 注意：卡片含日文多字节字符，切片须落在字符边界上。
        let card_end = block.find("</a>").unwrap_or(block.len());
        let card = &block[..card_end];
        if !block.get(..200).unwrap_or(block).contains("thumb-popu")
            && !card.contains("thumb-overlay")
        {
            continue;
        }
        let id = format!("{HOST}/video/{path}");
        if seen.contains(&id) {
            continue;
        }
        let cover = match card.find("<img src=\"") {
            Some(p) => {
                let s = p + 10;
                card[s..]
                    .find('"')
                    .map(|e| card[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match card.find("<div class=\"duration\">") {
            Some(p) => {
                let s = p + 22;
                card[s..]
                    .find("</div>")
                    .map(|e| strip_tags(&card[s..s + e]))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let title = match card.find("video-title") {
            Some(p) => {
                let after = &card[p..];
                match after.find('>') {
                    Some(gt) => {
                        let s = gt + 1;
                        after[s..]
                            .find("</span>")
                            .map(|e| strip_tags(&after[s..s + e]))
                            .unwrap_or_default()
                    }
                    None => String::new(),
                }
            }
            None => String::new(),
        };
        let title = truncate(&title, 90);
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        items.push(item_json(&id, &title, &cover, &remark));
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
        _ => {
            if let Some(v) = category_id.strip_prefix("cat:") {
                with_page(format!("{HOST}/videos/{v}"))
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
    match t.rsplit_once(" - TOKYO Motion") {
        Some((head, _)) => head.trim().to_string(),
        None => t,
    }
}

/// 详情页 `<source src="...vsrc...">` 取流地址。
fn extract_vsrc(html: &str) -> String {
    if let Some(p) = html.find("<source src=\"") {
        let s = p + 13;
        if let Some(e) = html[s..].find('"') {
            return html[s..s + e].to_string();
        }
    }
    String::new()
}

/// 跟随跳转拿最终地址（vsrc 301 到签名 mp4）：直接 GET 取最终
/// URL，不读 body；不用 HEAD——部分 CDN 对 HEAD 的跳转与 GET 不一致。
async fn resolve_redirect(url: &str, referer: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", referer)
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        Some(final_url)
    } else {
        None
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = vec![category_json("latest", "最新视频")];
    for (slug, name) in CATS {
        list.push(category_json(&format!("cat:{slug}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page_url = series_id.split('$').last().unwrap_or(series_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("TokyoMotion 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let duration = meta_content(&html, "property", "video:duration");
    let mut synopsis = String::new();
    if let Ok(secs) = duration.parse::<f64>() {
        let total = secs as u64;
        synopsis.push_str(&format!(
            "时长：{:02}:{:02}:{:02}",
            total / 3600,
            (total / 60) % 60,
            total % 60
        ));
    }
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&page_url, "正片", &page_url)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.ends_with(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let vsrc = extract_vsrc(&html);
    if vsrc.is_empty() {
        return Err(ApiError::Internal(
            "TokyoMotion 详情页未找到播放地址".into(),
        ));
    }
    // vsrc 301 到带签名的 mp4，跟跳转拿最终地址再返回。
    let url = resolve_redirect(&vsrc, &page_url).await.unwrap_or(vsrc);
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search?search_query={}&search_type=videos&type=public",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_video_card() {
        let html = r#"<a href="/video/7174861/german-amateur-creampied"  class="thumb-popu">
            <div class="thumb-overlay">
                <img src="https://cdn.tokyo-motion.net/media/videos/tmb224/7174861/1.jpg" title="German Amateur Creampied" alt="German Amateur Creampied" class="img-responsive "/>
                <div class="duration">
                    08:52
                </div>
            </div>
            <span class="video-title title-truncate m-t-5">German Amateur Creampied</span></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://www.tokyomotion.net/video/7174861/german-amateur-creampied"
        );
        assert_eq!(items[0]["title"], "German Amateur Creampied");
        assert_eq!(
            items[0]["cover"],
            "https://cdn.tokyo-motion.net/media/videos/tmb224/7174861/1.jpg"
        );
        assert_eq!(items[0]["remark"], "08:52");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest", 1),
            "https://www.tokyomotion.net/videos"
        );
        assert_eq!(
            catalog_url("latest", 2),
            "https://www.tokyomotion.net/videos?page=2"
        );
        assert_eq!(
            catalog_url("cat:jav", 3),
            "https://www.tokyomotion.net/videos/jav?page=3"
        );
    }

    #[test]
    fn tag_title_strips_site_name() {
        let html = "<title>German Amateur Creampied - TOKYO Motion</title>";
        assert_eq!(tag_title(html), "German Amateur Creampied");
    }

    #[test]
    fn vsrc_extracted() {
        let html = r#"<source src="https://www.tokyomotion.net/vsrc/sd/41373f505c1fb8cca87d" default title="SD" type="video/mp4">"#;
        assert_eq!(
            extract_vsrc(html),
            "https://www.tokyomotion.net/vsrc/sd/41373f505c1fb8cca87d"
        );
        assert!(extract_vsrc("<html></html>").is_empty());
    }

    #[test]
    fn duration_meta_parses() {
        let html = r#"<meta property="video:duration" content="531.96">"#;
        assert_eq!(meta_content(html, "property", "video:duration"), "531.96");
    }
}
