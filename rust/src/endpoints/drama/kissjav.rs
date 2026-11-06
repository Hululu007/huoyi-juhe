//! KissJAV（kissjav.li）：KVS（Kernel Video Sharing）模板站。
//! 取流：详情页 flashvars 的 `video_url` 是 base64 编码的
//! `https://kissjav.li/get_file/11/<hash>/<id000>/<id>/<id>.mp4/?br=<n>`，
//! 解码后即直链（现取现解）。
//! 实测 887553：mp4 全文件 109048542 字节，ffprobe 时长 386.41 秒，
//! 与卡片 6:26 精确对上（全长）；Range 请求 206 + ftyp 魔数。
//! 注意：站内多为韩 BJ 短片，卡片时长多在 1 分钟以内，6:26 已是
//! 首页最长；video_url_hd 只是标志位（'MQ==' 即 "1"），不用它。
//! 分类与站导航 1:1（最新/最多观看/今日热门/播放列表 + 14 个分类）；
//! 列表翻页 `/latest-updates/N/`、分类 `/categories/<slug>/N/`；
//! 搜索 `/search/?q=...`。

use base64::Engine;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://kissjav.li";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 + /categories/ 页验过的 14 个分类。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新"),
    ("popular", "最多观看"),
    ("hot", "今日热门"),
    ("playlists", "播放列表"),
    ("cat:vip", "KVIP"),
    ("cat:jvip", "JVIP"),
    ("cat:korean-porn", "Korean Porn"),
    ("cat:korean-bj", "Korean BJ"),
    ("cat:fc2ppv", "FC2PPV"),
    ("cat:jav", "JAV"),
    ("cat:myfans", "MyFans"),
    ("cat:ipcam", "IPCAM"),
    ("cat:toilet", "Toilet"),
    ("cat:voyeur-jp", "Voyeur JP"),
    ("cat:asian-leak", "Asian Leak"),
    ("cat:china", "China"),
    ("cat:mib", "MIB"),
    ("cat:upskirt", "Upskirt"),
];

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
        return Err(ApiError::Internal(format!("KissJAV 请求 HTTP {status}")));
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

/// KVS 卡片：`<a href="https://kissjav.li/video/<id>/<slug>/">`，
/// 封面 `data-original`，时长 `<div class="time">`。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("href=\"https://kissjav.li/video/").skip(1) {
        let end = block
            .find("href=\"https://kissjav.li/video/")
            .unwrap_or(block.len());
        let block = &block[..end];
        let Some(q) = block.find('"') else {
            continue;
        };
        let path = &block[..q];
        let mut it = path.split('/');
        let Some(vid) = it.next() else {
            continue;
        };
        if vid.is_empty() || !vid.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let id = format!("{HOST}/video/{path}");
        if seen.contains(&id) {
            continue;
        }
        // 标题：a 标签的 title 属性，兜底 img alt。
        let mut title = String::new();
        if let Some(p) = block.find("title=\"") {
            let s = p + 7;
            if let Some(e) = block[s..].find('"') {
                title = decode_entities(&block[s..s + e]);
            }
        }
        // 封面：data-original（// 开头补 https）。
        let mut cover = String::new();
        if let Some(p) = block.find("data-original=\"") {
            let s = p + 15;
            if let Some(e) = block[s..].find('"') {
                let src = &block[s..s + e];
                cover = if src.starts_with("//") {
                    format!("https:{src}")
                } else if src.starts_with("http") {
                    src.to_string()
                } else {
                    format!("{HOST}{src}")
                };
            }
        }
        if title.is_empty() {
            if let Some(p) = block.find("alt=\"") {
                let s = p + 5;
                if let Some(e) = block[s..].find('"') {
                    title = decode_entities(&block[s..s + e]);
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        let mut remark = String::new();
        if let Some(p) = block.find("<div class=\"time\">") {
            let s = p + 18;
            if let Some(e) = block[s..].find("</div>") {
                remark = block[s..s + e].trim().to_string();
            }
        }
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let paged = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}{page}/")
        }
    };
    match category_id {
        "latest" => paged(format!("{HOST}/latest-updates/")),
        "popular" => {
            if page <= 1 {
                format!("{HOST}/most-popular/?sort_by=video_viewed")
            } else {
                format!("{HOST}/most-popular/{page}/?sort_by=video_viewed")
            }
        }
        "hot" => {
            if page <= 1 {
                format!("{HOST}/most-popular/?sort_by=video_viewed_today")
            } else {
                format!("{HOST}/most-popular/{page}/?sort_by=video_viewed_today")
            }
        }
        "playlists" => paged(format!("{HOST}/playlists/")),
        _ => {
            if let Some(v) = category_id.strip_prefix("cat:") {
                paged(format!("{HOST}/categories/{v}/"))
            } else {
                paged(format!("{HOST}/latest-updates/"))
            }
        }
    }
}

/// flashvars 单引号字段。
fn flashvar(html: &str, name: &str) -> String {
    let marker = format!("{name}: '");
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
    for sep in [" - KissJAV", " | KissJAV"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

/// flashvars video_url：base64 解码后即 mp4 直链。
fn decode_video_url(b64: &str) -> Option<String> {
    let mut s = b64.trim().to_string();
    while s.len() % 4 != 0 {
        s.push('=');
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes())
        .ok()?;
    let url = String::from_utf8(bytes).ok()?;
    if url.starts_with("http") && url.contains(".mp4") {
        Some(url)
    } else {
        None
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
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let mut title = flashvar(&html, "video_title");
    if title.is_empty() {
        title = tag_title(&html);
    }
    if title.is_empty() {
        return Err(ApiError::Internal("KissJAV 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let cats = flashvar(&html, "video_categories");
    let desc = if cats.is_empty() {
        String::new()
    } else {
        format!("分类：{cats}")
    };
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${series_id}"), "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let b64 = flashvar(&html, "video_url");
    let url = decode_video_url(&b64)
        .ok_or_else(|| ApiError::Internal("KissJAV 详情页未找到 video_url".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 flashvars：视频 887553 的 video_url，解出 get_file 直链。
    const VIDEO_URL_B64: &str = "aHR0cHM6Ly9raXNzamF2LmxpL2dldF9maWxlLzExL2YwNzE2OTRiNWJlODM4OTY2MWM1MWMwNzViODQxZmUzLzg4NzAwMC84ODc1NTMvODg3NTUzLm1wNC8/YnI9MjIwNw==";

    #[test]
    fn decode_video_url_known() {
        assert_eq!(
            decode_video_url(VIDEO_URL_B64).unwrap(),
            "https://kissjav.li/get_file/11/f071694b5be8389661c51c075b841fe3/887000/887553/887553.mp4/?br=2207"
        );
        assert!(decode_video_url("@@@not-base64@@@").is_none());
        assert!(decode_video_url("aHR0cHM6Ly9leGFtcGxlLmNvbS9hLm1wNA").is_some());
    }

    #[test]
    fn parse_video_card() {
        let html = r#"<div class="thumbs"><div class="thumb thumb_rel item"><a href="https://kissjav.li/video/887553/얼공빨통지리는녀-ㅅㅅ-인생도박-welcome-to-dobaklife/" title="얼공빨통지리는녀 ㅅㅅ - 인생도박 - Welcome to dobaklife"><div class="img-holder"><img class="lazy-load" src="data:image/gif;base64,xxx" data-original="//assets6.cdnhop.com/contents/videos_screenshots/887000/887553/320x180/1.jpg" alt="얼공빨통지리는녀 ㅅㅅ - 인생도박 - Welcome to dobaklife"/><div class="item-bottom"><div class="qualtiy">HD</div><div class="time">6:26</div></div></div></a></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://kissjav.li/video/887553/얼공빨통지리는녀-ㅅㅅ-인생도박-welcome-to-dobaklife/"
        );
        assert_eq!(
            items[0]["cover"],
            "https://assets6.cdnhop.com/contents/videos_screenshots/887000/887553/320x180/1.jpg"
        );
        assert_eq!(items[0]["remark"], "6:26");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest", 1),
            "https://kissjav.li/latest-updates/"
        );
        assert_eq!(
            catalog_url("latest", 2),
            "https://kissjav.li/latest-updates/2/"
        );
        assert_eq!(
            catalog_url("cat:korean-bj", 1),
            "https://kissjav.li/categories/korean-bj/"
        );
        assert_eq!(
            catalog_url("popular", 1),
            "https://kissjav.li/most-popular/?sort_by=video_viewed"
        );
    }

    #[test]
    fn flashvar_extract() {
        let html =
            "flashvars = {\n video_id: '887553', video_title: 'test title', video_url: 'aGVsbG8=',";
        assert_eq!(flashvar(html, "video_title"), "test title");
        assert_eq!(flashvar(html, "video_url"), "aGVsbG8=");
        assert_eq!(flashvar(html, "nope"), "");
    }
}
