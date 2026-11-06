//! 🔞黄色有声小说（hsvoice31.cfd，成人有声站）。
//!
//! 照搬 py 原文：站名本身就是成人标识（SITE_NAME 带 🔞黄色）；页
//! 面带三层混淆壳（去反斜杠 → 找 \w+('...'。split 的倒序 base64 →
//! /obfuscate/js/t/ 取 js → var h 的 base64），每层失败回退当前层；
//! 卡片文字全是 d('base64')；主播是 folder 项（id 带 author: 前缀，
//! 目录按此前缀下钻）；详情只一条音轨（<source src>），无多集；
//! 搜索 key 是去 padding 的 urlsafe base64；取流 Referer 在
//! /static/downloads/ 地址时改指对应播放页。py init 的 cookie/proxy
//! 核心函数签名里没有 extend 位，省略（无 cookie 也能取公开内容）。
//! 目录的 pagecount=999（有条目即有下一页）译成 has_more=条目非空。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const HOST: &str = "https://evj1istu2k.hsvoice31.cfd";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

const CLASSES: [(&str, &str); 4] = [
    ("home", "首页"),
    ("author", "主播"),
    ("toplist", "榜单"),
    ("latest", "最新"),
];

static SHELL_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)\w+\('(.+?)'\.split").unwrap());
static OBFUSCATE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"/obfuscate/js/t/([0-9a-f]+)").unwrap());
static VARH_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"var h\s*=\s*'([^']+)'").unwrap());
static BOOK_CARD_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r#"(?s)<a href="/play/(\d+)\.html" class="(?:book-card-link|update-item-link)">(.*?)</a>"#,
    )
    .unwrap()
});
static DTEXT_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"d\('([A-Za-z0-9+/=]+)'\)").unwrap());
static AUTHOR_CARD_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<a href="/author/([^"]+)\.html">(.*?)</a>"#).unwrap());
static IMG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"<img[^>]+src="([^"]+)""#).unwrap());
static MAIN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<main class="play-page">(.*?)</main>"#).unwrap());
static H1_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<h1[^>]*>.*?d\('([A-Za-z0-9+/=]+)'\)"#).unwrap());
static AUTHOR_LINK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"href="/author/([^"]+)\.html""#).unwrap());
static SOURCE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"<source src="([^"]+)""#).unwrap());
static DOWNLOADS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"/static/downloads/(\d+)/").unwrap());
static DATE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\d{4}-\d{2}-\d{2}$").unwrap());
static PLAYS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[\d.]+万$").unwrap());

/// py _b64decode：去空白、补 = 至 4 的倍数、标准 base64 解码。
fn b64decode(s: &str) -> Vec<u8> {
    use base64::Engine as _;
    let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if cleaned.is_empty() {
        return Vec::new();
    }
    let padded = format!("{}{}", cleaned, "=".repeat((4 - cleaned.len() % 4) % 4));
    base64::engine::general_purpose::STANDARD
        .decode(padded.as_bytes())
        .unwrap_or_default()
}

/// py _dtext：base64 解出 utf-8（失败为空串）。
fn dtext(s: &str) -> String {
    String::from_utf8_lossy(&b64decode(s)).into_owned()
}

/// py urllib.parse.quote：保留 unreserved 与 safe 里的字符，其余按字节
/// %XX 大写编码。
fn quote_path(s: &str, safe: &str) -> String {
    let mut out = String::new();
    for &b in s.as_bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || "-_.~".contains(c) || safe.contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// py urllib.parse.unquote：%XX 还原字节再按 utf-8 宽容解码（+ 不动）。
fn unquote(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
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
    String::from_utf8_lossy(&out).into_owned()
}

async fn request_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "黄色有声小说请求 HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// py _fetch_page：三层混淆壳，逐层失败回退当前层。
async fn fetch_page(path: &str) -> ApiResult<String> {
    let url = format!("{}{}", HOST, quote_path(path, "/:?&=%"));
    let shell = request_text(&url).await?;
    let plain = shell.replace('\\', "");
    let Some(cap) = SHELL_RE.captures(&plain) else {
        return Ok(shell);
    };
    let reversed: String = cap[1].chars().rev().collect();
    let layer2 = String::from_utf8_lossy(&b64decode(&reversed)).into_owned();
    let Some(ob) = OBFUSCATE_RE.captures(&layer2) else {
        return Ok(layer2);
    };
    let js_url = format!("{HOST}/obfuscate/js/t/{}", &ob[1]);
    let js = match request_text(&js_url).await {
        Ok(js) => js,
        Err(_) => return Ok(layer2),
    };
    let Some(mh) = VARH_RE.captures(&js) else {
        return Ok(js);
    };
    Ok(String::from_utf8_lossy(&b64decode(&mh[1])).into_owned())
}

fn dtexts(block: &str) -> Vec<String> {
    DTEXT_RE
        .captures_iter(block)
        .map(|c| dtext(&c[1]))
        .collect()
}

fn book_cards(html: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in BOOK_CARD_RE.captures_iter(html) {
        let bid = cap[1].to_string();
        if !seen.insert(bid.clone()) {
            continue;
        }
        let parts = dtexts(&cap[2]);
        let title = parts.first().cloned().unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let plays = parts.get(3).cloned().unwrap_or_default();
        out.push(item_json(&bid, &title, "", &plays));
    }
    out
}

fn author_cards(html: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in AUTHOR_CARD_RE.captures_iter(html) {
        let block = &cap[2];
        if !block.contains("host-item") {
            continue;
        }
        let part = unquote(&cap[1]);
        if !seen.insert(part.clone()) {
            continue;
        }
        let img = IMG_RE
            .captures(block)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        let parts = dtexts(block);
        let name = parts.first().cloned().unwrap_or(part.clone());
        let count = parts.get(1).cloned().unwrap_or_default();
        let remarks = if count.is_empty() {
            String::new()
        } else {
            format!("{count}部作品")
        };
        let id = format!("author:{}", quote_path(&part, ""));
        out.push(item_json(&id, &name, &img, &remarks));
    }
    out
}

async fn home_books() -> ApiResult<Vec<Value>> {
    let html = fetch_page("/").await?;
    Ok(book_cards(&html))
}

fn page_path(base: &str, pg: i64) -> String {
    if pg <= 1 {
        base.to_string()
    } else {
        format!("{base}?page={pg}")
    }
}

async fn author_books(part: &str, pg: i64) -> ApiResult<Vec<Value>> {
    let html = fetch_page(&page_path(&format!("/author/{part}.html"), pg)).await?;
    Ok(book_cards(&html))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CLASSES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let pg = if page < 1 { 1 } else { page };
    let items = if let Some(part) = category_id.strip_prefix("author:") {
        author_books(&unquote(part), pg).await?
    } else {
        match category_id {
            "home" => {
                if pg == 1 {
                    home_books().await?
                } else {
                    Vec::new()
                }
            }
            "author" => {
                let html = fetch_page(&page_path("/author.html", pg)).await?;
                author_cards(&html)
            }
            "toplist" => {
                let html = fetch_page(&page_path("/toplist.html", pg)).await?;
                book_cards(&html)
            }
            "latest" => {
                let html = fetch_page(&page_path("/latest.html", pg)).await?;
                book_cards(&html)
            }
            _ => Vec::new(),
        }
    };
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if series_id.is_empty() || !series_id.chars().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::BadRequest("黄色有声小说书 id 无效".into()));
    }
    let html = fetch_page(&format!("/play/{series_id}.html")).await?;
    let block = MAIN_RE
        .captures(&html)
        .map(|c| c[1].to_string())
        .unwrap_or(html);
    let title = H1_RE
        .captures(&block)
        .map(|c| dtext(&c[1]))
        .unwrap_or_default();
    let apart = AUTHOR_LINK_RE
        .captures(&block)
        .map(|c| unquote(&c[1]))
        .unwrap_or_default();
    let params = dtexts(&block);
    let mut author = String::new();
    let mut date = String::new();
    let mut plays = String::new();
    for (i, p) in params.iter().enumerate() {
        if p == "主播：" && i + 1 < params.len() {
            author = params[i + 1].clone();
        }
        if DATE_RE.is_match(p) {
            date = p.clone();
        }
        if PLAYS_RE.is_match(p) {
            plays = p.clone();
        }
    }
    if author.is_empty() && !apart.is_empty() {
        author = apart;
    }
    let mut audio = SOURCE_RE
        .captures(&block)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    if audio.starts_with('/') {
        audio = format!("{HOST}{audio}");
    }
    if title.is_empty() || audio.is_empty() {
        return Err(ApiError::Internal(
            "黄色有声小说未取到书名或音频地址".into(),
        ));
    }
    let mut meta = format!("主播：{author}");
    if !date.is_empty() {
        meta.push_str(&format!(" · {date}"));
    }
    if !plays.is_empty() {
        meta.push_str(&format!(" · {plays}播放"));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": "",
        "synopsis": meta,
        "extra": {"author": author, "date": date, "plays": plays},
        "episodes": [episode_json(&audio, &title, series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    use base64::Engine as _;
    let kw = query.trim();
    if kw.is_empty() {
        return Ok(json!({"items": []}));
    }
    let k = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(kw.as_bytes());
    let html = fetch_page(&format!("/search.html?k={k}")).await?;
    Ok(json!({"items": book_cards(&html)}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let did = video_id.trim();
    let mut url = if let Some((_, after)) = did.rsplit_once('$') {
        after.trim().to_string()
    } else {
        did.to_string()
    };
    if !url.is_empty() && url.chars().all(|c| c.is_ascii_digit()) {
        let html = fetch_page(&format!("/play/{url}.html")).await?;
        url = match SOURCE_RE.captures(&html) {
            Some(c) => {
                let src = c[1].to_string();
                if src.starts_with('/') {
                    format!("{HOST}{src}")
                } else {
                    src
                }
            }
            None => String::new(),
        };
    } else if url.starts_with('/') {
        url = format!("{HOST}{url}");
    }
    let mut referer = format!("{HOST}/");
    if let Some(m) = DOWNLOADS_RE.captures(&url) {
        referer = format!("{HOST}/play/{}.html", &m[1]);
    }
    if url.is_empty() {
        return Err(ApiError::Internal("黄色有声小说未取到音频地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": referer},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn b64_pad_and_dtext() {
        assert_eq!(dtext("aGVsbG8"), "hello");
        assert_eq!(dtext("5L2g5aW9"), "你好");
        assert_eq!(dtext("!!!"), "");
    }

    #[test]
    fn quote_keeps_safe() {
        assert_eq!(
            quote_path("/author/abc def.html", "/:?&=%"),
            "/author/abc%20def.html"
        );
        assert_eq!(quote_path("a/b?c=d&e", ""), "a%2Fb%3Fc%3Dd%26e");
    }

    #[test]
    fn page_path_rules() {
        assert_eq!(page_path("/latest.html", 1), "/latest.html");
        assert_eq!(page_path("/latest.html", 3), "/latest.html?page=3");
    }
}
