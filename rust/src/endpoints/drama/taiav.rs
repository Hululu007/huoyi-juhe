//! TaiAV（taiav.com）：AV 视频站，列表与详情走 HTML 解析。
//! 取流：详情页 JS 调 `GET /api/getmovie?type=1280&id=<id>`，
//! 回 JSON `{"m3u8":"/videos/.../index.m3u8?random=...&key=..."}`，
//! 相对路径，拼站前缀现取现用。
//! 实测 6ae95f9f76692e4a54e32a7c（FC2PPV 4981127）：m3u8 200、
//! 835 分片、3338.84 秒；AES-128（ts.key 拉取 200/16B）；
//! 首分片 200（AES-128 加密分片，首字节非 0x47 属正常）。
//! 注意：站内卡片与详情页均不显示时长，无法做时长对表。
//! 分类与站导航 1:1（无码/有码/国产AV/网红主播 + 热门视频/随机）；
//! 分类列表 `?page=N`；搜索 `/cn/search?q=...`。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://taiav.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 4 大分类 + 热门视频 + 随机。
const CATS: &[(&str, &str)] = &[
    ("uncensored", "无码"),
    ("censored", "有码"),
    ("domestic", "国产AV"),
    ("influencer", "网红主播"),
    ("hots", "热门视频"),
    ("random", "随机"),
];

fn id_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"/cn/movie/([0-9a-f]{24})"#).unwrap())
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
        return Err(ApiError::Internal(format!("TaiAV 请求 HTTP {status}")));
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

/// `<div data-id='"<id>"' class="movie-card">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("class=\"movie-card\"").skip(1) {
        let end = block.find("class=\"movie-card\"").unwrap_or(block.len());
        let block = &block[..end];
        let cap = match id_re().captures(block) {
            Some(c) => c,
            None => continue,
        };
        let vid = cap[1].to_string();
        let id = format!("{HOST}/cn/movie/{vid}");
        if seen.contains(&id) {
            continue;
        }
        // 封面：poster2.webp，alt 即标题。
        let (mut cover, mut title) = (String::new(), String::new());
        if let Some(p) = block.find("poster2.webp") {
            let head = &block[..p];
            if let Some(a) = head.rfind("<img ") {
                let img = &block[a..];
                if let Some(s) = img.find("src=\"") {
                    let s = s + 5;
                    if let Some(e) = img[s..].find('"') {
                        cover = img[s..s + e].to_string();
                    }
                }
                if let Some(s) = img.find("alt=\"") {
                    let s = s + 5;
                    if let Some(e) = img[s..].find('"') {
                        title = decode_entities(&img[s..s + e]);
                    }
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, ""));
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
        "uncensored" => with_page(format!("{HOST}/cn/category/无码")),
        "censored" => with_page(format!("{HOST}/cn/category/有码")),
        "domestic" => with_page(format!("{HOST}/cn/category/国产AV")),
        "influencer" => with_page(format!("{HOST}/cn/category/网红主播")),
        "hots" => with_page(format!("{HOST}/hots")),
        "random" => format!("{HOST}/random"),
        _ => with_page(format!("{HOST}/cn/category/无码")),
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
    for sep in [" 在线观看,免费高清 - Taiav.com", " - Taiav.com"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

fn movie_id(series_id: &str) -> Option<String> {
    id_re().captures(series_id).map(|c| c[1].to_string())
}

/// `/api/getmovie` 返回的 m3u8 相对路径拼成绝对地址。
fn join_m3u8(path: &str) -> Option<String> {
    if path.starts_with("http") {
        Some(path.to_string())
    } else if path.starts_with('/') {
        Some(format!("{HOST}{path}"))
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
    let html = fetch(&url, &format!("{HOST}/cn/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/cn/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("TaiAV 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let desc = truncate(&meta_content(&html, "name", "description"), 400);
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
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/cn/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let vid =
        movie_id(&page_url).ok_or_else(|| ApiError::Internal("TaiAV 取流需要视频 id".into()))?;
    let api = format!("{HOST}/api/getmovie?type=1280&id={vid}");
    let body = fetch(&api, &page_url).await?;
    let v: Value = serde_json::from_str(&body)
        .map_err(|_| ApiError::Internal("TaiAV getmovie 返回不是 JSON".into()))?;
    let path = v
        .get("m3u8")
        .and_then(|x| x.as_str())
        .ok_or_else(|| ApiError::Internal("TaiAV getmovie 未返回 m3u8".into()))?;
    let url = join_m3u8(path).ok_or_else(|| ApiError::Internal("TaiAV m3u8 地址异常".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/cn/search?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/cn/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_movie_card() {
        let html = r#"<div data-id='"6ae1aab976e3ea4a1d29829a"' data-date="no" class="movie-card"><div class="uk-card rounded uk-card-hover uk-card-secondary uk-card-small tm-border"><div class="uk-card-media-top"><a href="/cn/movie/6ae1aab976e3ea4a1d29829a"><div class="uk-cover-container image-container uk-flex uk-flex-middle uk-flex-center movie-poster"><canvas width="1920" height="1080"></canvas><img src="https://img.storyofthepast.xyz/videos/202610/28/6ae1aab976e3ea4a1d29829a/poster2.webp" alt="FC2PPV 4979802 金发白晢正妹因被发现拍黄片被迫退出地下偶像" uk-cover=""/></div></a></div></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://taiav.com/cn/movie/6ae1aab976e3ea4a1d29829a"
        );
        assert_eq!(
            items[0]["title"],
            "FC2PPV 4979802 金发白晢正妹因被发现拍黄片被迫退出地下偶像"
        );
        assert_eq!(
            items[0]["cover"],
            "https://img.storyofthepast.xyz/videos/202610/28/6ae1aab976e3ea4a1d29829a/poster2.webp"
        );
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("uncensored", 1),
            "https://taiav.com/cn/category/无码"
        );
        assert_eq!(
            catalog_url("domestic", 2),
            "https://taiav.com/cn/category/国产AV?page=2"
        );
        assert_eq!(catalog_url("hots", 1), "https://taiav.com/hots");
        assert_eq!(catalog_url("hots", 3), "https://taiav.com/hots?page=3");
        assert_eq!(catalog_url("random", 1), "https://taiav.com/random");
    }

    #[test]
    fn getmovie_response_parse() {
        let body = r#"{"m3u8":"/videos/202611/03/6ae95f9f76692e4a54e32a7c/8fb6ee/index.m3u8?random=abc&counts=5&timestamp=1793920000&key=xyz"}"#;
        let v: Value = serde_json::from_str(body).unwrap();
        let path = v.get("m3u8").unwrap().as_str().unwrap();
        assert_eq!(
            join_m3u8(path).unwrap(),
            "https://taiav.com/videos/202611/03/6ae95f9f76692e4a54e32a7c/8fb6ee/index.m3u8?random=abc&counts=5&timestamp=1793920000&key=xyz"
        );
        assert!(join_m3u8("not-a-path").is_none());
    }

    #[test]
    fn tag_title_strips_suffix() {
        let html =
            "<title>FC2PPV 4981127 地方偶像真实性爱中出 在线观看,免费高清 - Taiav.com</title>";
        assert_eq!(tag_title(html), "FC2PPV 4981127 地方偶像真实性爱中出");
    }

    #[test]
    fn movie_id_from_url() {
        assert_eq!(
            movie_id("https://taiav.com/cn/movie/6ae95f9f76692e4a54e32a7c").unwrap(),
            "6ae95f9f76692e4a54e32a7c"
        );
        assert!(movie_id("https://taiav.com/cn/category/无码").is_none());
    }
}
