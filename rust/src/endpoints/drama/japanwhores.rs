//! 🔞Japan Whores（japan-whores.com）：KVS 引擎日本 tube 站。
//!
//! 列表（/videos/{id}/{slug}/ 卡片：data-original 取封面、
//! span.time 取时长）、详情（og 标题封面、JSON-LD 时长、
//! flashvars video_url 取流）、搜索（/search/videos/?q=）。
//! 取流（详情页 video_url 直链 get_file：本机实测 302 跳到
//! nvms4-b.cdn.privatehost.com 签名 mp4，Range 206 + ftypisom 魔数）。
//! 验门（2026-11-06 本机出口实测）：详情 342652《Hot Mommy Bends
//! Over with Full Anal Pleasure!》时长 PT2H12M43S；分类
//! /c/anal-penetration/ p1 32 条；/latest-updates/2/ 50 条与首页
//! 0 重合；搜索 teen 33 条。注意：分类页无翻页链接（/c/{slug}/2/
//! 与 /page/2/ 均 404、?page=2 返回与 p1 相同内容），分类只取 p1；
//! latest/most-popular/top-rated 三路按 /{route}/{N}/ 翻页。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://japan-whores.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 3 路排序 + 首页导航里的热门 /c/ 分类。
/// /c/ 分类只取 p1（站侧无翻页）；三路排序按 /{route}/{N}/ 翻页。
const CATS: &[(&str, &str)] = &[
    ("latest-updates", "最新"),
    ("most-popular", "最热"),
    ("top-rated", "好评"),
    ("c:anal-penetration", "Anal"),
    ("c:blowjob", "Blowjob"),
    ("c:group-sex", "Group Sex"),
    ("c:creampie-eating", "Creampie"),
    ("c:hot-mature", "Hot Mature"),
    ("c:kimono", "Kimono"),
    ("c:school-girl", "School Uniform 18+"),
    ("c:shemale", "Shemale"),
    ("c:blonde", "Blonde"),
    ("c:cum-swallow", "Cum Swallow"),
    ("c:boob-fuck", "Boob Fuck"),
    ("c:dildo-riding", "Dildo Riding"),
    ("c:defloration", "Defloration"),
    ("c:transparent-lingerie", "Transparent Lingerie"),
    ("c:red-pantie", "Red Pantie"),
    ("c:foot-sucking", "Foot Sucking"),
    ("c:puffy-nipples", "Puffy Nipples"),
    ("c:micro", "Micro"),
    ("c:reporter", "Reporter"),
    ("c:forest", "Forest"),
    ("c:naked", "Naked"),
    ("c:mmmf", "MMMF"),
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
            "JapanWhores 请求 HTTP {status}"
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
        .replace("&#180;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
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

/// `<div class="item thumb">` 卡片解析：链接、标题、封面、时长。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"item thumb\">").skip(1) {
        let end = block
            .find("<div class=\"item thumb\">")
            .unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a href=\"https://japan-whores.com/videos/") {
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
        let title = match block.find("title=\"") {
            Some(p) => {
                let s = p + 7;
                block[s..]
                    .find('"')
                    .map(|e| decode_entities(&block[s..s + e]))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let cover = match block.find("data-original=\"") {
            Some(p) => {
                let s = p + 15;
                block[s..]
                    .find('"')
                    .map(|e| block[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match block.find("<span class=\"time\">") {
            Some(p) => {
                let s = p + 19;
                block[s..]
                    .find("</span>")
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
    if let Some(slug) = category_id.strip_prefix("c:") {
        return format!("{HOST}/c/{slug}/");
    }
    if page <= 1 {
        format!("{HOST}/{category_id}/")
    } else {
        format!("{HOST}/{category_id}/{page}/")
    }
}

/// JSON-LD 时长 PT2H12M43S → 2:12:43。
fn iso_duration(s: &str) -> String {
    let re = Regex::new(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?").unwrap();
    let Some(cap) = re.captures(s) else {
        return String::new();
    };
    let h: i64 = cap
        .get(1)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let m: i64 = cap
        .get(2)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let sec: i64 = cap
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    if h > 0 {
        format!("{h}:{m:02}:{sec:02}")
    } else {
        format!("{m}:{sec:02}")
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

fn flashvar(html: &str, key: &str) -> String {
    let marker = format!("{key}: '");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    html[s..]
        .find('\'')
        .map(|e| html[s..s + e].to_string())
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
    for sep in [" ▪ ", " - ", " | "] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    // /c/ 分类站侧无翻页：p1 之后直接返回空。
    if category_id.starts_with("c:") && page > 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty() && !category_id.starts_with("c:");
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("JapanWhores 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let desc = meta_content(&html, "name", "description");
    let duration = iso_duration(&flashvar(&html, "duration"));
    let cats = flashvar(&html, "video_categories");
    let mut lines: Vec<String> = Vec::new();
    if !cats.is_empty() {
        lines.push(format!("分类：{cats}"));
    }
    if !duration.is_empty() {
        lines.push(format!("时长：{duration}"));
    }
    let mut synopsis = desc;
    if !lines.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push('\n');
        }
        synopsis.push_str(&lines.join("\n"));
    }
    let synopsis = truncate(&synopsis, 400);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let url = flashvar(&html, "video_url");
    if url.is_empty() {
        return Err(ApiError::Internal("JapanWhores 未取到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/videos/?q={}",
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
    fn cards_parse_kvs_thumb() {
        let html = r#"<div class="thumbs" id="list_videos_common_videos_list_items">
        <div class="item thumb">
            <a href="https://japan-whores.com/videos/381667/misaki-shiraishi-180-s-first-threesome-with-a-guy-and-a-girl/" title="Misaki Shiraishi&#180;s First Threesome With A Guy And A Girl" class="th">
                <span class="wrap_image th img">
                    <img class="lazy-load" src="data:image/gif;base64,xxx" data-original="https://japan-whores.com/contents/videos_screenshots/381000/381667/644x362/2.jpg" alt="Misaki Shiraishi&#180;s First Threesome With A Guy And A Girl" width="644" height="362"/>
                    <span class="time">7:02</span>
                    <span class="quality">hd</span>
                </span>
            </a>
        </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://japan-whores.com/videos/381667/misaki-shiraishi-180-s-first-threesome-with-a-guy-and-a-girl/"
        );
        assert_eq!(
            items[0]["title"],
            "Misaki Shiraishi's First Threesome With A Guy And A Girl"
        );
        assert_eq!(
            items[0]["cover"],
            "https://japan-whores.com/contents/videos_screenshots/381000/381667/644x362/2.jpg"
        );
        assert_eq!(items[0]["remark"], "7:02");
    }

    #[test]
    fn iso_duration_formats() {
        assert_eq!(iso_duration("PT2H12M43S"), "2:12:43");
        assert_eq!(iso_duration("PT7M2S"), "7:02");
        assert_eq!(iso_duration("PT31M12S"), "31:12");
        assert_eq!(iso_duration(""), "");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest-updates", 1),
            "https://japan-whores.com/latest-updates/"
        );
        assert_eq!(
            catalog_url("latest-updates", 2),
            "https://japan-whores.com/latest-updates/2/"
        );
        assert_eq!(
            catalog_url("c:anal-penetration", 1),
            "https://japan-whores.com/c/anal-penetration/"
        );
        assert_eq!(
            catalog_url("c:anal-penetration", 5),
            "https://japan-whores.com/c/anal-penetration/"
        );
    }

    #[test]
    fn flashvar_video_url() {
        let html = "flashvars = {\n video_id: '342652',\n video_url: 'https://japan-whores.com/get_file/3/9be0c706b717c9ee6a1d66d683e11579/342000/342652/342652.mp4/?v-acctoken=MTAzMXwxMTh8MHwxYmEyYjQ3MGJkMGUyMDE4NzVkZTNmNTM2YWI5NTgyNw',\n video_categories: 'Anal',";
        assert!(flashvar(html, "video_url").starts_with("https://japan-whores.com/get_file/3/"));
        assert_eq!(flashvar(html, "video_categories"), "Anal");
    }

    #[test]
    fn tag_title_strips_site_name() {
        let html =
            "<title>Hot Mommy Bends Over with Full Anal Pleasure! ▪ Japan-Whores.com</title>";
        assert_eq!(
            tag_title(html),
            "Hot Mommy Bends Over with Full Anal Pleasure!"
        );
    }
}
