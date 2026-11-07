//! ho5ho：与火蚁TV 的 ho5ho.py 一一对应。
//!
//! 成人漫画站（分类全是成人向标签，路径为 h漫分類）：分类为固定
//! 30 项（注意 4 项的 id 与显示名不同：多p/多P、m女/M女、ntr/NTR、
//! m男/M男）；目录按分类 slug 走 /h漫分類/<slug>/（多页加
//! /page/<n>/）；详情按章节出分集（无章节时回退全集）；取流时先
//! 按数字序号抓 .jpg（按号排序），无号时回退 wp-manga-chapter-img
//! 的 data-src/src，拼成 pics:// 交给图片浏览链路。
//!
//! 与 py 的一点差异：py 的 _fetch_path 会对已含百分号编码的路径
//! 再 quote 一次（分类 slug 会被双重编码）；本模块直接按单次编码
//! 拼路径，功能等价，若站方实际要求双重编码只需改一处。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://www.ho5ho.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const CATEGORIES: [(&str, &str); 30] = [
    ("全彩", "全彩"),
    ("巨乳", "巨乳"),
    ("痴女", "痴女"),
    ("熟女", "熟女"),
    ("變態", "變態"),
    ("多p", "多P"),
    ("母狗", "母狗"),
    ("接吻", "接吻"),
    ("肉感", "肉感"),
    ("幻想", "幻想"),
    ("m女", "M女"),
    ("可愛", "可愛"),
    ("學生", "學生"),
    ("深喉", "深喉"),
    ("強姦", "強姦"),
    ("亂倫", "亂倫"),
    ("ntr", "NTR"),
    ("肛交", "肛交"),
    ("正太", "正太"),
    ("母子", "母子"),
    ("m男", "M男"),
    ("催眠", "催眠"),
    ("懷孕", "懷孕"),
    ("姐姐", "姐姐"),
    ("貧乳", "貧乳"),
    ("女性向", "女性向"),
    ("同人", "同人"),
    ("聖水", "聖水"),
    ("女同", "女同"),
    ("韓漫", "韓漫"),
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
    .ok_or_else(|| ApiError::Internal("ho5ho client unavailable".into()))
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

fn strip_tags(raw: &str) -> String {
    must_re(r"<[^>]+>").replace_all(raw, "").to_string()
}

fn clean_collapse(raw: &str) -> String {
    let decoded = decode_entities(&strip_tags(raw));
    let collapsed = must_re(r"\s+").replace_all(&decoded, " ");
    collapsed.replace('\u{a0}', " ").trim().to_string()
}

fn pct_encode_segment(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn pct_encode_path(s: &str) -> String {
    s.split('/')
        .map(pct_encode_segment)
        .collect::<Vec<_>>()
        .join("/")
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn pct_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// 取链接的路径部分（去 scheme 与 host，去查询与锚点）。
fn url_path(url: &str) -> String {
    let mut rest = url;
    if let Some(idx) = rest.find("://") {
        rest = &rest[idx + 3..];
        if let Some(slash) = rest.find('/') {
            rest = &rest[slash..];
        } else {
            return String::new();
        }
    }
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    rest[..end].to_string()
}

/// 与 py 的 _get 一致：单次请求，失败返回空串（无重试）。
async fn fetch(path: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    let url = format!("{BASE_URL}{path}");
    let result = c
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9")
        .header("Referer", format!("{BASE_URL}/"))
        .send()
        .await;
    match result {
        Ok(resp) => resp.text().await.unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn parse_cards(page: &str) -> Vec<Value> {
    let article_re = must_re(r#"(?s)<article class="ho5ho-v2-card".*?</article>"#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for article in article_re.captures_iter(page) {
        let block = &article[0];
        let href = match must_re(r#"ho5ho-v2-card-cover" href="([^"]+)""#).captures(block) {
            Some(caps) => caps[1].to_string(),
            None => continue,
        };
        let path = url_path(&href);
        if !seen.insert(path.clone()) {
            continue;
        }
        let pic = match must_re(r#"<img[^>]*src="([^"]+)""#).captures(block) {
            Some(caps) => caps[1].to_string(),
            None => String::new(),
        };
        let name = match must_re(r#"ho5ho-v2-card-title"><a[^>]*>([^<]+)</a>"#).captures(block) {
            Some(caps) => caps[1].trim().to_string(),
            None => String::new(),
        };
        if name.is_empty() {
            continue;
        }
        let id = pct_decode(&path).trim_matches('/').to_string();
        items.push(item_json(&id, &name, &pic, ""));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if category_id.is_empty() {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let items = parse_cards(&fetch("/").await);
        let has_more = !items.is_empty();
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    let slug = pct_encode_segment(category_id);
    let path = if page > 1 {
        format!("/h漫分類/{slug}/page/{page}/")
    } else {
        format!("/h漫分類/{slug}/")
    };
    let items = parse_cards(&fetch(&path).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let pid = series_id;
    let page = fetch(&format!("/{}/", pct_encode_path(pid))).await;
    let title = match must_re(r#"<h1 id="ho5ho-detail-title">([^<]+)</h1>"#).captures(&page) {
        Some(caps) => caps[1].trim().to_string(),
        None => String::new(),
    };
    let title = if title.is_empty() {
        pid.to_string()
    } else {
        title
    };
    let cover = match must_re(r#"ho5ho-v3-cover"[^>]*>\s*<img[^>]*src="([^"]+)""#).captures(&page) {
        Some(caps) => caps[1].to_string(),
        None => String::new(),
    };
    let ch_re = must_re(r#"wp-manga-chapter[^>]*>\s*<a href="([^"]+)"[^>]*>\s*([^<]+?)\s*</a>"#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut chapters: Vec<(String, String)> = Vec::new();
    for caps in ch_re.captures_iter(&page) {
        let chap = url_path(&caps[1])
            .trim_matches('/')
            .split('/')
            .last()
            .unwrap_or("")
            .to_string();
        if chap.is_empty() || !seen.insert(chap.clone()) {
            continue;
        }
        chapters.push((chap, caps[2].trim().to_string()));
    }
    let episodes: Vec<Value> = if chapters.is_empty() {
        vec![episode_json(&format!("{pid}#server-1"), "全集", pid)]
    } else {
        chapters
            .iter()
            .map(|(chap, text)| episode_json(&format!("{pid}#{chap}"), text, pid))
            .collect()
    };
    let remarks = match must_re(r"(?s)作品資料與分類.*?分類\s*(.*?)\s*標籤").captures(&page)
    {
        Some(caps) => clean_collapse(&caps[1])
            .chars()
            .take(60)
            .collect::<String>(),
        None => String::new(),
    };
    let extra = if remarks.is_empty() {
        json!({})
    } else {
        json!({"remarks": remarks})
    };
    Ok(json!({
        "id": pid,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!("/?s={}", pct_encode_query(query));
    let items = parse_cards(&fetch(&path).await);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let id = strip_label(video_id);
    if id.starts_with("pics://") {
        return Ok(json!({"url": id}));
    }
    let mut parts = id.splitn(2, '#');
    let pid = parts.next().unwrap_or("");
    let chap = parts.next().unwrap_or("server-1");
    let page = fetch(&format!(
        "/{}/{}/",
        pct_encode_path(pid),
        pct_encode_segment(chap)
    ))
    .await;
    let page = page.replace("\\/", "/");
    let mut found: std::collections::BTreeMap<i64, String> = std::collections::BTreeMap::new();
    for caps in must_re(r#"https?://[^"\\\s]+/(\d+)\.jpg"#).captures_iter(&page) {
        if let Ok(n) = caps[1].parse::<i64>() {
            found.insert(n, caps[0].to_string());
        }
    }
    let mut imgs: Vec<String> = found.into_values().collect();
    if imgs.is_empty() {
        let block_re = must_re(r#"wp-manga-chapter-img"[^>]*>"#);
        for block in block_re.captures_iter(&page) {
            if let Some(caps) = must_re(r#"(?:data-src|src)="([^"]+)""#).captures(&block[0]) {
                let src = caps[1].to_string();
                if !imgs.contains(&src) {
                    imgs.push(src);
                }
            }
        }
    }
    if imgs.is_empty() {
        return Err(ApiError::Internal("ho5ho未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_path_strips_host_query_fragment() {
        assert_eq!(
            url_path("https://www.ho5ho.com/abc/def/?x=1#y"),
            "/abc/def/"
        );
        assert_eq!(url_path("/abc/def/"), "/abc/def/");
        assert_eq!(url_path("https://www.ho5ho.com"), "");
    }

    #[test]
    fn pct_roundtrip_for_slug() {
        assert_eq!(pct_encode_segment("多p"), "%E5%A4%9Ap");
        assert_eq!(pct_decode("%E5%A4%9Ap"), "多p");
        assert_eq!(pct_encode_path("a/b c"), "a/b%20c");
    }

    #[test]
    fn parse_cards_dedups_by_path() {
        let page = r##"<article class="ho5ho-v2-card"><a class="ho5ho-v2-card-cover" href="https://www.ho5ho.com/m1/"><img src="p1"><div class="ho5ho-v2-card-title"><a href="#">漫画一</a></div></article>
            <article class="ho5ho-v2-card"><a class="ho5ho-v2-card-cover" href="https://www.ho5ho.com/m1/"><img src="p1"><div class="ho5ho-v2-card-title"><a href="#">漫画一</a></div></article>"##;
        let items = parse_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "m1");
        assert_eq!(items[0]["title"], "漫画一");
    }
    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert!(!list.is_empty(), "ho5ho categories empty");
        eprintln!(
            "LIVE ho5ho cats={} first={}",
            list.len(),
            list[0]["id"].as_str().unwrap_or("")
        );
        let start = std::time::Instant::now();
        let r = catalog("全彩", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE ho5ho cat=全彩 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "ho5ho catalog 全彩 empty");
    }
}
