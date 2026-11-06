//! 🔞AVHWA：avhwa.com 的 KVS 风格站（get_file 直链 + base64 播放串）。
//!
//! 列表（div.thumb.thumb_rel.item 卡片解析：视频链接取 id、
//! a 的 title 取标题、img data-original 取封面截图、
//! div.time 取时长；分类 30 条/页，翻页 `/categories/{slug}/{N}/`；
//! 搜索 `/search/{词}/`）、详情（og 标题封面、video_url 取流）、
//! 取流（详情页 `video_url: 'base64'` 解出 get_file 直链，再跟随
//! 302 到 tubegifs CDN 的 mp4，verify 签名有时效，须现取现用）。
//! 验门（2026-11-06 本机出口实测）：/categories/ 页 14 分类与站
//! 导航 1:1；jav 分类 p1 30 条、p2（/2/）30 条不重合；搜索 FC2PPV
//! 20 条；详情 FC2PPV 5003438（id 887046）：video_url 解出
//! get_file/11/...mp4/?br=633，跟随 302 到
//! wwww1.tubegifs.com/...mp4?verify=...，Range 206 + ftypisom
//! 魔数，HEAD 200 video/mp4；时长 03:54:05。注意 get_file/1/
//! 的同名直链回的是 1x1 GIF 诱饵，不是正片。
//! 分类与站导航 1:1；翻页 `/categories/{slug}/{N}/`。

use base64::Engine;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://avhwa.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：/categories/ 页验过的 14 分类，显示名照站导航原样。
const CATS: &[(&str, &str)] = &[
    ("vip", "KVIP"),
    ("jvip", "JVIP"),
    ("korean-porn", "Korean Porn"),
    ("korean-bj", "Korean BJ"),
    ("fc2ppv", "FC2PPV"),
    ("jav", "Uncensored"),
    ("ipcam", "IPCAM"),
    ("toilet", "Toilet"),
    ("voyeur-jp", "Voyeur JP"),
    ("china", "CHINA"),
    ("myfans", "myfans"),
    ("asian-leak", "Asian Leak"),
    ("upskirt", "upskirt"),
    ("mib", "MIB"),
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
        return Err(ApiError::Internal(format!("AVHWA 请求 HTTP {status}")));
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

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

fn abs_url(href: &str) -> String {
    let href = href.trim();
    if href.starts_with("//") {
        return format!("https:{href}");
    }
    if href.starts_with("http") {
        return href.to_string();
    }
    if let Some(rest) = href.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{href}")
}

/// `<div class="thumb thumb_rel item">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"thumb thumb_rel item").skip(1) {
        let end = block
            .find("<div class=\"thumb thumb_rel item")
            .unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a href=\"https://avhwa.com/video/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let id = href.to_string();
        if seen.contains(&id) {
            continue;
        }
        let title = match block.find("<div class=\"title\">") {
            Some(p) => {
                let s = p + 19;
                block[s..]
                    .find("</div>")
                    .map(|e| decode_entities(block[s..s + e].trim()))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let title = if title.is_empty() {
            match block.find("title=\"") {
                Some(p) => {
                    let s = p + 7;
                    block[s..]
                        .find('"')
                        .map(|e| decode_entities(&block[s..s + e]))
                        .unwrap_or_default()
                }
                None => String::new(),
            }
        } else {
            title
        };
        if title.is_empty() {
            continue;
        }
        let cover = match block.find("data-original=\"") {
            Some(p) => {
                let s = p + 15;
                block[s..]
                    .find('"')
                    .map(|e| abs_url(&block[s..s + e]))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match block.find("<div class=\"time\">") {
            Some(p) => {
                let s = p + 18;
                block[s..]
                    .find("</div>")
                    .map(|e| block[s..s + e].trim().to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let slug = if category_id.is_empty() {
        "jav"
    } else {
        category_id
    };
    if page <= 1 {
        format!("{HOST}/categories/{slug}/")
    } else {
        format!("{HOST}/categories/{slug}/{page}/")
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

/// 详情页 `video_url: 'base64'` 解出 get_file 直链（get_file/11/）。
/// 注意：页内另有一条 get_file/1/ 同名直链，回的是 1x1 GIF 诱饵，
/// 只能用 video_url 这一条。
fn extract_video_url(html: &str) -> Option<String> {
    let marker = "video_url: '";
    let p = html.find(marker)?;
    let s = p + marker.len();
    let e = html[s..].find('\'')?;
    let b64 = &html[s..s + e];
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .ok()?;
    let url = String::from_utf8(bytes).ok()?;
    if url.contains("/get_file/") && url.contains(".mp4") {
        Some(url)
    } else {
        None
    }
}

/// 跟随跳转拿最终地址（get_file 直链 302 到 tubegifs CDN 的
/// verify 签名地址；同 jable 的 resolve_redirect 写法）。
async fn resolve_redirect(url: &str, referer: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .head(url)
        .header("User-Agent", UA)
        .header("Referer", referer)
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        return Some(final_url);
    }
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
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page_url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{HOST}{}", series_id.trim_start_matches('/'))
    };
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let title = meta_content(&html, "property", "og:title");
    if title.is_empty() {
        return Err(ApiError::Internal("AVHWA 未返回影片资料".into()));
    }
    let cover = abs_url(&meta_content(&html, "property", "og:image"));
    let desc = meta_content(&html, "name", "description");
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": truncate(&desc, 400),
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${page_url}"), "正片", &page_url)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let header = json!({"User-Agent": UA, "Referer": format!("{HOST}/")});
    if video_id.contains(".mp4") {
        let mut url = video_id.to_string();
        if let Some(resolved) = resolve_redirect(&url, &format!("{HOST}/")).await {
            if resolved.len() > 20 {
                url = resolved;
            }
        }
        return Ok(json!({"url": url, "header": header}));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let mut url = extract_video_url(&html)
        .ok_or_else(|| ApiError::Internal("AVHWA 详情页未找到播放串".into()))?;
    if let Some(resolved) = resolve_redirect(&url, &page_url).await {
        if resolved.len() > 20 {
            url = resolved;
        }
    }
    Ok(json!({"url": url, "header": header}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/{}/",
        url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 video_url（FC2PPV 5003438，id 887046）。
    const B64: &str = "aHR0cHM6Ly9hdmh3YS5jb20vZ2V0X2ZpbGUvMTEvYzg5ZjMxNGFhZGNkYjhmNTU4ODY5NzllYzdkNjE3ZjAvODg3MDAwLzg4NzA0Ni84ODcwNDYubXA0Lz9icj02MzM=";

    #[test]
    fn video_url_base64_decodes() {
        assert_eq!(
            extract_video_url(&format!("video_url: '{B64}',")),
            Some(
                "https://avhwa.com/get_file/11/c89f314aadcdb8f55886979ec7d617f0/887000/887046/887046.mp4/?br=633"
                    .to_string()
            )
        );
        assert!(extract_video_url("video_url: '!!!',").is_none());
        assert!(extract_video_url("nothing here").is_none());
    }

    #[test]
    fn parse_thumb_card() {
        let html = r#"<div class="thumb thumb_rel item  ">
                            <a href="https://avhwa.com/video/887046/fc2ppv-5003438-xxx/" title="FC2PPV 5003438 标题" >
                <div class="img-holder">
                                       <img class="lazy-load" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-original="//assets5.cdnhop.com/contents/videos_screenshots/887000/887046/320x180/1.jpg" alt="FC2PPV 5003438 标题" width="320" height="180"/>
                                                         <div class="item-bottom">
                    <div class="qualtiy">HD</div>
                    <div class="time">2:03:03</div>
                   </div>
                                       <div class="item-top">
                   </div>
                               </a>
             </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://avhwa.com/video/887046/fc2ppv-5003438-xxx/"
        );
        assert_eq!(
            items[0]["cover"],
            "https://assets5.cdnhop.com/contents/videos_screenshots/887000/887046/320x180/1.jpg"
        );
        assert_eq!(items[0]["remark"], "2:03:03");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("jav", 1), "https://avhwa.com/categories/jav/");
        assert_eq!(catalog_url("jav", 2), "https://avhwa.com/categories/jav/2/");
        assert_eq!(
            catalog_url("fc2ppv", 3),
            "https://avhwa.com/categories/fc2ppv/3/"
        );
    }
}
