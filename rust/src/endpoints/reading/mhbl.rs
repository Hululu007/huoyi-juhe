//! mhbl：与火蚁TV 的 mhbl.py 一一对应。
//!
//! 漫画部落：基址为 punycode 域名，路径前缀 /acg/index.php；分类
//! 为固定 3 项（完本/同人志/韩漫）；目录按卡片块切分解析（标题、
//! data-bg 封面、副标题备注）；详情按 sid 分部分（默认第 1 部分
//! 加页内 sid，数字排序）；取流时抓 img.904174.xyz 图床图片（跳
//! 过含 /t/ 的缩略图），拼成 pics:// 交给图片浏览链路。
//!
//! 注意：py 的详情在抓页失败时仍返回一条第 1 部分分集（标题回退
//! 为编号），本模块照搬该行为，不在详情处报错。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://xn--uns.mhbl.buzz";
const PREFIX: &str = "https://xn--uns.mhbl.buzz/acg/index.php";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 3] = [
    ("50", "完本"),
    ("51", "同人志"),
    ("52", "韩漫"),
];

static HTTP: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn client() -> ApiResult<&'static reqwest::Client> {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .ok()
    })
    .as_ref()
    .ok_or_else(|| ApiError::Internal("mhbl client unavailable".into()))
}

fn must_re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|_| Regex::new("$^").unwrap())
}

fn category_json(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

fn item_json(id: &str, title: &str, cover: &str, remark: &str) -> Value {
    json!({"id": id, "title": title, "cover": cover, "remark": remark})
}

fn episode_json(video_id: &str, title: &str, series_id: &str) -> Value {
    json!({"video_id": video_id, "title": title, "series_id": series_id})
}

fn decode_entities(s: &str) -> String {
    let dec = must_re(r"&#(\d+);");
    let mut out = dec
        .replace_all(s, |caps: &regex::Captures| {
            caps[1]
                .parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    let hex = must_re(r"&#x([0-9a-fA-F]+);");
    out = hex
        .replace_all(&out, |caps: &regex::Captures| {
            u32::from_str_radix(&caps[1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    for (from, to) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&amp;", "&"),
    ] {
        out = out.replace(from, to);
    }
    out
}

/// 与 py 的 _clean 对应（去标签、解实体、空白折叠）；本实现另解
/// 数字实体，是 py 的超集，显示效果一致。
fn clean_collapse(raw: &str) -> String {
    let no_tags = must_re(r"<[^>]+>").replace_all(raw, "");
    let decoded = decode_entities(&no_tags);
    let collapsed = must_re(r"\s+").replace_all(&decoded, " ");
    collapsed.replace('\u{a0}', " ").trim().to_string()
}

fn abs_pic(src: &str) -> String {
    if let Some(rest) = src.strip_prefix("//") {
        format!("https://{rest}")
    } else if src.starts_with('/') {
        format!("{BASE_URL}{src}")
    } else {
        src.to_string()
    }
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~'
            | b'/' => out.push(*b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 与 py 的 _fetch 一致：单次请求，失败返回空串（无重试）。
async fn fetch(url: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    let result = c
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE_URL}/"))
        .send()
        .await;
    match result {
        Ok(resp) => resp.text().await.unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn parse_list(page: &str) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for block in page.split("<div class=\"card h-100\">").skip(1) {
        let vid = match must_re(r#"href="/acg/index\.php/book/detail/id/(\d+)\.html""#)
            .captures(block)
        {
            Some(caps) => caps[1].to_string(),
            None => continue,
        };
        if !seen.insert(vid.clone()) {
            continue;
        }
        let cover = match must_re(r#"data-bg="([^"]+)""#).captures(block) {
            Some(caps) => abs_pic(&caps[1]),
            None => String::new(),
        };
        let title = match must_re(r#"<p class="card-text[^>]*>([^<]+)</p>"#).captures(block) {
            Some(caps) => clean_collapse(&caps[1]),
            None => String::new(),
        };
        let title = if title.is_empty() { vid.clone() } else { title };
        let remark = match must_re(r#"<p class="card-subtitle[^>]*>([^<]+)</p>"#).captures(block)
        {
            Some(caps) => clean_collapse(&caps[1]),
            None => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

fn parse_images(page: &str) -> Vec<String> {
    let re = must_re(r#"//img\.904174\.xyz/[^"\s<>]+"#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut imgs = Vec::new();
    for caps in re.captures_iter(page) {
        let url = format!("https:{}", &caps[0]);
        if url.contains("/t/") {
            continue;
        }
        if seen.insert(url.clone()) {
            imgs.push(url);
        }
    }
    imgs
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = if category_id.is_empty() {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        format!("{PREFIX}/book/home/page/1.html")
    } else if page <= 1 {
        format!("{PREFIX}/book/type/id/{category_id}.html")
    } else {
        format!("{PREFIX}/book/type/id/{category_id}/page/{page}.html")
    };
    let items = parse_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.split(',').next().unwrap_or("").trim().to_string();
    let page = fetch(&format!("{PREFIX}/book/detail/id/{vid}.html")).await;
    let mut title = match must_re(r#"<div class="card-header[^>]*>([^<]+)</div>"#).captures(&page)
    {
        Some(caps) => clean_collapse(&caps[1]),
        None => String::new(),
    };
    if title.is_empty() {
        title = match must_re(r"(?s)<title>(.*?)</title>").captures(&page) {
            Some(caps) => clean_collapse(&caps[1])
                .split("-漫画部落")
                .next()
                .unwrap_or("")
                .trim()
                .to_string(),
            None => String::new(),
        };
    }
    if title.is_empty() {
        title = vid.clone();
    }
    let cover = match must_re(r#"data-bg="([^"]+)""#).captures(&page) {
        Some(caps) => abs_pic(&caps[1]),
        None => String::new(),
    };
    let mut parts: Vec<String> = vec!["1".to_string()];
    let sid_re = must_re(&format!(
        r"/book/detail/id/{vid}/sid/(\d+)\.html",
        vid = vid
    ));
    for caps in sid_re.captures_iter(&page) {
        let sid = caps[1].to_string();
        if !parts.contains(&sid) {
            parts.push(sid);
        }
    }
    parts.sort_by_key(|p| p.parse::<i64>().unwrap_or(0));
    let episodes: Vec<Value> = parts
        .iter()
        .map(|p| episode_json(&format!("mhbl:{vid}:{p}"), &format!("第{p}部分"), &vid))
        .collect();
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{PREFIX}/book/search/wd/{}.html",
        pct_encode_query(query)
    );
    let items = parse_list(&fetch(&url).await);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let raw = strip_label(video_id);
    if raw.starts_with("pics://") {
        return Ok(json!({"url": raw}));
    }
    let (mut vid, mut part) = (raw.clone(), "1".to_string());
    if raw.starts_with("mhbl:") {
        let segs: Vec<&str> = raw.split(':').collect();
        if segs.len() >= 3 {
            vid = segs[1].to_string();
            part = segs[2].to_string();
        }
    }
    let url = if part == "1" {
        format!("{PREFIX}/book/detail/id/{vid}.html")
    } else {
        format!("{PREFIX}/book/detail/id/{vid}/sid/{part}.html")
    };
    let imgs = parse_images(&fetch(&url).await);
    if imgs.is_empty() {
        return Err(ApiError::Internal("mhbl未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abs_pic_rules() {
        assert_eq!(abs_pic("//img.x/a.jpg"), "https://img.x/a.jpg");
        assert_eq!(abs_pic("/a/b.jpg"), "https://xn--uns.mhbl.buzz/a/b.jpg");
        assert_eq!(abs_pic("https://x/a.jpg"), "https://x/a.jpg");
    }

    #[test]
    fn parse_list_splits_cards() {
        let page = r#"<div class="card h-100"><a href="/acg/index.php/book/detail/id/42.html"><div data-bg="//img.x/c.jpg"></div><p class="card-text">漫A</p><p class="card-subtitle">完结</p></div>
            <div class="card h-100"><a href="/acg/index.php/book/detail/id/42.html"><div data-bg="//img.x/c.jpg"></div><p class="card-text">漫A</p></div>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "42");
        assert_eq!(items[0]["cover"], "https://img.x/c.jpg");
        assert_eq!(items[0]["remark"], "完结");
    }

    #[test]
    fn parse_images_skips_thumbnails() {
        let page = "x //img.904174.xyz/a/1.jpg y //img.904174.xyz/t/2.jpg z //img.904174.xyz/a/1.jpg";
        let imgs = parse_images(page);
        assert_eq!(imgs, vec!["https://img.904174.xyz/a/1.jpg"]);
    }
}
