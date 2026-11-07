//! 久久热：KVS 静态站。
//!
//! 来源 jar 类 `Zaka99jjAmns`（`https://www.99jj25.com`）。
//! 分类是写死的 hash 串 + 最新；列表页用卡片正则解析；详情页取
//! `video_url` / `video_alt_url` 两个字段；取流时 `/get_file/` 与
//! `/hd.php` 链接要跟随跳转拿真实地址。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://www.99jj25.com";
const MEDIA_REF: &str = "https://www.99jj25.com/";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("cb186ba8ba160b86eb97025b94353cac", "高清"),
    ("ffc7a71b8aae8ddd42031cea42f5bb7c", "欧美"),
    ("2f3d48fda20378cbdaaa099069a4af1e", "日本有码"),
    ("5a4e793520c46cbaee2b67760e5aea28", "东京热"),
    ("0c3d3255db00e2d3b27db08661096b23", "肛交"),
    ("281b22d3c2f5255ed57e7a09bee253f1", "韩国女主播系列"),
    ("f8789a0bf37c07c754c8e6fe27daf5f6", "成人动漫"),
    ("5d915fafb4889f0b225f2b80cc975332", "小格式综合"),
    ("251e96ab3240ae3fb3dc8bc854061957", "会员认证作品"),
    ("b8e26987b0bae1d56a00de631e4d1a68", "李宗瑞全集"),
    ("sm", "SM性虐"),
];

static P_CARD: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<div\s+class="item[^"]*"[^>]*>\s*<a[^>]*href="(https?://[^"]*?/videos/(\d+)/[^"]*)"[^>]*title="([^"]*)""#).unwrap()
});
static P_IMG: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<img[^>]*(?:data-original|data-src|src)="([^"]+)""#).unwrap());
static P_DUR: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"<div class="duration">\s*([0-9:]+)"#).unwrap());

fn unescape(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ");
    let re = Regex::new(r"&#(x?)([0-9a-fA-F]+);").unwrap();
    while let Some(cap) = re.captures(&out.clone()) {
        let full = cap.get(0).unwrap().as_str().to_string();
        let num = cap.get(2).unwrap().as_str();
        let parsed = if cap.get(1).unwrap().as_str() == "x" {
            i64::from_str_radix(num, 16).ok()
        } else {
            num.parse::<i64>().ok()
        };
        let replacement = parsed
            .and_then(|n| char::from_u32(n as u32))
            .map(|c| c.to_string())
            .unwrap_or_default();
        out = out.replacen(&full, &replacement, 1);
    }
    out
}

fn abs_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{BASE}{u}")
    } else {
        u.to_string()
    }
}

async fn html(path: &str, needle: &str) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", MEDIA_REF)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("久久热请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 800 || (!needle.is_empty() && !text.contains(needle)) {
        return Err(ApiError::Internal("久久热页面内容不符合预期".into()));
    }
    Ok(text)
}

fn cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in P_CARD.captures_iter(page) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let vid = cap.get(2).map(|m| m.as_str()).unwrap_or("");
        let title = unescape(cap.get(3).map(|m| m.as_str()).unwrap_or(""));
        if vid.is_empty() || !seen.insert(vid.to_string()) {
            continue;
        }
        let start = cap.get(0).unwrap().start();
        // 按字节切 1600 窗口会切在中文字符中间导致 panic（Java 原版
        // substring 按字符下标切，不会炸）；把末尾退到字符边界再切。
        let mut end = page.len().min(start + 1600);
        while end > start && !page.is_char_boundary(end) {
            end -= 1;
        }
        let window = &page[start..end];
        let cover = P_IMG
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(m.as_str()))
            .unwrap_or_default();
        let dur = P_DUR
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let path = match href.find('/').map(|_| href) {
            Some(_) => {
                let re = Regex::new(r"^https?://[^/]+(/.*)$").unwrap();
                re.captures(href)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_else(|| href.to_string())
            }
            None => href.to_string(),
        };
        let name = if title.is_empty() { vid } else { &title };
        items.push(item_json(&path, name, &cover, &dur));
    }
    items
}

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![category_json("new", "最新")];
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let path = if category_id.is_empty() || category_id == "new" {
        format!("/videos_list_vip.php?page={page}")
    } else {
        let tail = if page > 1 {
            format!("{page}/")
        } else {
            String::new()
        };
        format!("/categories/{category_id}/{tail}")
    };
    let page_html = html(&path, "/videos/").await?;
    let items = cards(&page_html);
    Ok(json!({"items": items, "has_more": true}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = if series_id.starts_with("http") {
        let re = Regex::new(r"^https?://[^/]+(/.*)$").unwrap();
        re.captures(series_id)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_else(|| series_id.to_string())
    } else if series_id.starts_with('/') {
        series_id.to_string()
    } else {
        format!("/videos/{series_id}/")
    };
    let page_html = match html(&path, "video_url").await {
        Ok(t) => t,
        Err(_) => html(&path, "<title>").await?,
    };
    let re_url = Regex::new(r#"video_url:\s*'([^']+)'"#).unwrap();
    let re_url2 = Regex::new(r#"video_url:\s*"([^"]+)""#).unwrap();
    let re_alt = Regex::new(r#"video_alt_url:\s*'([^']+)'"#).unwrap();
    let re_img = Regex::new(r#"og:image"\s+content="([^"]+)""#).unwrap();
    let re_thumb = Regex::new(r#"class="thumb[^"]*"[^>]*src="([^"]+)""#).unwrap();
    let re_h1 = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let re_title = Regex::new(r#"og:title"\s+content="([^"]+)""#).unwrap();
    let mut video_url = cap1(&re_url, &page_html);
    if video_url.is_empty() {
        video_url = cap1(&re_url2, &page_html);
    }
    let alt_url = cap1(&re_alt, &page_html);
    let mut cover = cap1(&re_img, &page_html);
    if cover.is_empty() {
        cover = cap1(&re_thumb, &page_html);
    }
    let cover = abs_url(&cover);
    let mut title = re_h1
        .captures(&page_html)
        .and_then(|c| c.get(1))
        .map(|m| unescape(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        title = unescape(&cap1(&re_title, &page_html));
    }
    let vid = Regex::new(r"/videos/(\d+)")
        .unwrap()
        .captures(&path)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    if title.is_empty() {
        title = format!("久久热 {vid}");
    }
    let mut episodes = Vec::new();
    if video_url.len() > 20 {
        episodes.push(episode_json(&abs_url(&video_url), "正片", series_id));
    }
    if alt_url.len() > 20 && alt_url.contains("/get_file/") {
        episodes.push(episode_json(&abs_url(&alt_url), "高清", series_id));
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("久久热详情未取到播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "来源：久久热",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Ok(json!({"items": []}));
    }
    let mut paths: Vec<String> = vec![
        "/".to_string(),
        "/videos_list_vip.php?page=1".to_string(),
        "/videos_list_vip.php?page=2".to_string(),
    ];
    for (id, _) in CATS {
        paths.push(format!("/categories/{id}/"));
    }
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for path in paths {
        let Ok(page_html) = html(&path, "/videos/").await else {
            continue;
        };
        for item in cards(&page_html) {
            let title = item["title"].as_str().unwrap_or("").to_lowercase();
            let id = item["id"].as_str().unwrap_or("").to_string();
            if title.contains(&needle) && !id.is_empty() && seen.insert(id) {
                items.push(item);
            }
        }
    }
    Ok(json!({"items": items}))
}

/// 跟随跳转拿真实地址：先 HEAD，失败再 GET（不读 body）。
async fn resolve_redirect(url: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .head(url)
        .header("User-Agent", UA)
        .header("Referer", MEDIA_REF)
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
        .header("Referer", MEDIA_REF)
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

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut url = video_id.to_string();
    if url.contains("/get_file/") || url.contains("/hd.php") {
        if let Some(resolved) = resolve_redirect(&url).await {
            if resolved.len() > 20 {
                url = resolved;
            }
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("久久热没有播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unescape_entities() {
        assert_eq!(unescape("a &amp; b &#20013; &#x4e2d;"), "a & b 中 中");
    }

    #[test]
    fn abs_url_variants() {
        assert_eq!(abs_url("//x/1.jpg"), "https://x/1.jpg");
        assert_eq!(abs_url("/a/b"), "https://www.99jj25.com/a/b");
        assert_eq!(abs_url("https://x/1"), "https://x/1");
    }

    #[test]
    fn cards_window_does_not_panic_on_multibyte_boundary() {
        // 窗口末尾 start+1600 若落在中文字符中间，旧代码按字节切会 panic。
        for pad in 0..3 {
            let mut html = String::from(
                r#"<div class="item"><a href="https://www.99jj25.com/videos/12345/test-title/" title="Test Title"><img data-original="//cdn.example.com/1.jpg"><div class="duration">12:34</div>"#,
            );
            html.push_str(&"x".repeat(pad));
            html.push_str(&"】".repeat(600));
            html.push_str("</a></div>");
            let items = cards(&html);
            assert_eq!(items.len(), 1);
            assert_eq!(items[0]["title"], "Test Title");
        }
    }

    #[test]
    fn cards_parse_sample() {
        let html = r#"<div class="item"><a href="https://www.99jj25.com/videos/12345/test-title/" title="Test Title"><img data-original="//cdn.example.com/1.jpg"><div class="duration">12:34</div></a></div>"#;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/videos/12345/test-title/");
        assert_eq!(items[0]["title"], "Test Title");
        assert_eq!(items[0]["cover"], "https://cdn.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "12:34");
    }

    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert_eq!(list.len(), 12);
        let r = catalog("new", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!("LIVE 99jj cats=12 new_items={}", items.len());
        assert!(!items.is_empty(), "99jj new catalog empty");
        assert!(!items[0]["id"].as_str().unwrap_or("").is_empty());
        assert!(!items[0]["title"].as_str().unwrap_or("").is_empty());
    }
}
