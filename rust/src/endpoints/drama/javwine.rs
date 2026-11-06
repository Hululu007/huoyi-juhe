//! JAV.WINE：WordPress 站（jav.wine），列表与详情走 HTML 解析，
//! 取流：详情页 embedURL（secure-iframe，v 参数为 base64 的
//! player_secure.php 地址）→ 解出 `src` 参数即直链 m3u8；
//! 无 src 参数时取 player 页 `src = '...m3u8'`；再无则走旧
//! Dean Edwards packer / links 兜底。直连失败时走
//! tv506.ystv.top 中继兜底。
//! （2026-11-06 复验：旧链路 m3u8 正则会把 player_secure.php
//! 地址截断在编码后的 `.m3u8` 处、丢 token 致 403 Invalid
//! token；src 直链两片实测 200、首分片 0x47、时长对卡片。）

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of};

const HOST: &str = "https://jav.wine";
const EDGE: &str = "https://tv506.ystv.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：type_id 为完整 URL，与站导航一致。
const CATS: &[(&str, &str)] = &[
    ("https://jav.wine/?filter=latest", "最新更新"),
    ("https://jav.wine/?filter=popular", "最多观看"),
    ("https://jav.wine/?filter=longest", "时长最长"),
    ("https://jav.wine/jav-movies/", "全部影片"),
    ("https://jav.wine/jav-uncensored/", "无码专区"),
    ("https://jav.wine/actress/", "女优列表"),
];

fn packer_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\}\('(.*)',(\d+),(\d+),'(.*)'\.split\('\|'\)\)").unwrap())
}

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"https?://[^\s"'<>]+(?:master\.m3u8|master\.txt|\.m3u8)"#).unwrap()
    })
}

fn embed_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"itemprop="embedURL"[^>]*content="([^"]+)""#).unwrap())
}

fn iframe_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<iframe[^>]+src="([^"]*/embed/[^"]*)""#).unwrap())
}

fn b64_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[?&]v=([A-Za-z0-9+/=]+)").unwrap())
}

/// player 页 `src = '...m3u8'`。
fn player_src_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"src\s*=\s*'([^']+\.m3u8[^']*)'"#).unwrap())
}

/// 取 URL 查询参数（百分号解码）；无 `?` 或无该键时回 None。
fn query_param(url: &str, key: &str) -> Option<String> {
    let query = url.split_once('?')?.1;
    url::form_urlencoded::parse(query.as_bytes())
        .find(|(k, _)| k.as_ref() == key)
        .map(|(_, v)| v.into_owned())
}

/// base64 解码（v 参数常缺 `=` 填充，先补齐）。
fn b64_decode_padded(s: &str) -> Option<String> {
    let mut padded = s.to_string();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &padded).ok()?;
    String::from_utf8(bytes).ok()
}

/// 取首个 m3u8 地址；player_secure.php 地址常被截断在编码后
/// 的 `.m3u8` 处（丢 token，取之必 403），直接跳过。
fn first_m3u8(text: &str) -> Option<String> {
    m3u8_re()
        .captures_iter(text)
        .map(|c| c[0].to_string())
        .find(|u| !u.contains("player_secure.php"))
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
        return Err(ApiError::Internal(format!("JAV.WINE 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 直连失败或空时走中继兜底。
async fn fetch_with_edge(url: &str) -> ApiResult<String> {
    match fetch(url, &format!("{HOST}/")).await {
        Ok(t) if !t.trim().is_empty() => Ok(t),
        _ => {
            let proxy = format!(
                "{EDGE}/api/v1/proxy?url={}",
                url::form_urlencoded::byte_serialize(url.as_bytes()).collect::<String>()
            );
            let req = client()?
                .get(&proxy)
                .header("User-Agent", UA)
                .header("Accept", "*/*")
                .header("Referer", format!("{EDGE}/"));
            let resp = req
                .send()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))?;
            let status = resp.status().as_u16();
            if status != 200 {
                return Err(ApiError::Internal(format!("JAV.WINE 中继 HTTP {status}")));
            }
            resp.text()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))
        }
    }
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

/// 取 URL 的 scheme://host 部分；links 里常给相对地址，需按 embed 源补全。
fn origin_of(url: &str) -> String {
    match url.find("://") {
        Some(p) => {
            let rest = &url[p + 3..];
            let end = rest.find('/').unwrap_or(rest.len());
            format!("{}{}", &url[..p + 3], &rest[..end])
        }
        None => String::new(),
    }
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
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
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

/// `<article ... wc-card ...>` 块解析。
/// `<article ... wc-card ...>` 块解析；站点换主题后筛选页改用
/// `loop-video` 卡片（/jav-movies/ 与 /jav-uncensored/ 仍为
/// wc-card），两套一并解析（修：jar 的 parseList 只认 wc-card，
/// 筛选页 4 个分类会返回空）。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for block in html.split("<article").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let is_wc = block.contains("wc-card");
        let is_loop = block.contains("loop-video");
        if !is_wc && !is_loop {
            continue;
        }
        let href = match block.find("<a href=\"") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let cover = if let Some(p) = block.find("data-src=\"") {
            let s = p + 10;
            block[s..].find('"').map(|e| &block[s..s + e]).unwrap_or("")
        } else if let Some(p) = block.find("data-main-thumb=\"") {
            let s = p + 17;
            block[s..].find('"').map(|e| &block[s..s + e]).unwrap_or("")
        } else if let Some(p) = block.find("<img src=\"") {
            let s = p + 10;
            block[s..].find('"').map(|e| &block[s..s + e]).unwrap_or("")
        } else {
            ""
        };
        let title = if is_loop {
            // loop-video：<header class="entry-header"><span>标题</span>
            // 或 <a title="...">。
            let mut t = String::new();
            if let Some(p) = block.find("entry-header") {
                let after = &block[p..];
                if let Some(s) = after.find("<span") {
                    let s2 = after[s..]
                        .find('>')
                        .map(|i| s + i + 1)
                        .unwrap_or(after.len());
                    let e = after[s2..]
                        .find("</span>")
                        .map(|i| s2 + i)
                        .unwrap_or(after.len());
                    t = strip_tags(&after[s2..e]);
                }
            }
            if t.is_empty() {
                if let Some(p) = block.find("title=\"") {
                    let s = p + 7;
                    t = block[s..]
                        .find('"')
                        .map(|e| block[s..s + e].to_string())
                        .unwrap_or_default();
                }
            }
            t
        } else if let Some(p) = block.find("<h2") {
            let after = &block[p..];
            let s = after.find('>').map(|i| i + 1).unwrap_or(0);
            let e = after[s..].find("</h2>").unwrap_or(after.len() - s);
            truncate(&strip_tags(&after[s..s + e]), 90)
        } else {
            String::new()
        };
        if title.is_empty() {
            continue;
        }
        let mut remark = String::new();
        if is_loop {
            if let Some(p) = block.find("class=\"duration\"") {
                let after = &block[p..];
                let s = after.find('>').map(|i| i + 1).unwrap_or(0);
                let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
                remark = truncate(strip_tags(&after[s..e]).trim(), 18);
            }
        } else if let Some(p) = block.find("wc-meta") {
            let after = &block[p..];
            let s = after.find('>').map(|i| i + 1).unwrap_or(0);
            let e = after[s..].find("</div>").unwrap_or(after.len() - s);
            remark = truncate(&strip_tags(&after[s..s + e]), 18);
        }
        items.push(item_json(&abs_url(href), &title, &abs_url(cover), &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if page <= 1 {
        return category_id.to_string();
    }
    if category_id.contains('?') {
        format!("{category_id}&page={page}")
    } else {
        let base = category_id.trim_end_matches('/');
        format!("{base}/page/{page}/")
    }
}

fn meta_content(html: &str, attr: &str) -> String {
    let marker = format!("itemprop=\"{attr}\"");
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
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn og(html: &str, prop: &str) -> String {
    let marker = format!("property=\"{prop}\"");
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
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(html: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = html.find(&open) else {
        return String::new();
    };
    let after = &html[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

fn div_class_text(html: &str, class: &str) -> String {
    let marker = format!("class=\"{class}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let e = after[s..].find("</div>").unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

/// 数字转 a 进制字符串（Dean Edwards packer 的 e 函数）。
fn to_base(mut n: usize, radix: usize) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    if n == 0 {
        return "0".to_string();
    }
    let mut out = Vec::new();
    while n > 0 {
        out.push(DIGITS[n % radix]);
        n /= radix;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

/// 解 Dean Edwards packer：按进制把 k[c] 换回原文。
fn unpack_packer(packed: &str) -> String {
    let Some(cap) = packer_re().captures(packed) else {
        return packed.to_string();
    };
    let payload = cap[1].to_string();
    let radix: usize = cap[2].parse().unwrap_or(36);
    let count: usize = cap[3].parse().unwrap_or(0);
    let words: Vec<String> = cap[4].split('|').map(|s| s.to_string()).collect();
    let mut p = payload;
    for c in (0..count).rev() {
        if c >= words.len() || words[c].is_empty() {
            continue;
        }
        let word = to_base(c, radix);
        let re = Regex::new(&format!(r"\b{}\b", regex::escape(&word))).unwrap();
        p = re.replace_all(&p, words[c].as_str()).to_string();
    }
    p
}

/// 从 embed 页解出播放地址，返回 (url, origin)。
fn resolve_embed(embed_html: &str) -> Option<(String, String)> {
    let unpacked = unpack_packer(embed_html);
    if let Some(p) = unpacked.find("links") {
        let after = &unpacked[p..];
        if let Some(s) = after.find('{') {
            if let Some(e) = after[s..].find('}') {
                if let Ok(v) = serde_json::from_str::<Value>(&after[s..s + e + 1]) {
                    for k in ["hls4", "hls3", "hls2", "hls1", "hls"] {
                        let u = text_of(&v, &[k]);
                        if !u.is_empty() {
                            return Some((u, String::new()));
                        }
                    }
                }
            }
        }
    }
    if let Some(u) = first_m3u8(&unpacked) {
        return Some((u, String::new()));
    }
    if let Some(u) = first_m3u8(embed_html) {
        return Some((u, String::new()));
    }
    None
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
    let html = fetch_with_edge(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch_with_edge(series_id).await?;
    let mut title = meta_content(&html, "name");
    if title.is_empty() {
        title = tag_text(&html, "h1");
    }
    if title.is_empty() {
        title = tag_text(&html, "title");
    }
    if title.is_empty() {
        return Err(ApiError::Internal("JAV.WINE 未返回影片资料".into()));
    }
    let mut cover = meta_content(&html, "thumbnailUrl");
    if cover.is_empty() {
        cover = og(&html, "og:image");
    }
    let mut desc = meta_content(&html, "description");
    if desc.is_empty() {
        desc = div_class_text(&html, "entry-content");
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
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch_with_edge(&page_url).await?;
    let mut embed = embed_re()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    if embed.is_empty() {
        embed = iframe_re()
            .captures(&html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }
    if embed.is_empty() {
        return Err(ApiError::Internal(
            "JAV.WINE 详情页未找到 embed 地址".into(),
        ));
    }
    if let Some(cap) = b64_re().captures(&embed) {
        if let Some(s) = b64_decode_padded(&cap[1]) {
            if s.starts_with("http") {
                embed = s;
            }
        }
    }
    let embed = abs_url(&embed);
    // 新链路：player_secure.php 的 src 参数即直链 m3u8。
    if let Some(src) = query_param(&embed, "src") {
        if src.contains(".m3u8") {
            return Ok(json!({
                "url": src,
                "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
            }));
        }
    }
    // 次选：取 player 页，从 `src = '...m3u8'` 提直链。
    if embed.contains("player_secure.php") {
        if let Ok(player_html) = fetch(&embed, &format!("{HOST}/")).await {
            if let Some(cap) = player_src_re().captures(&player_html) {
                let url = cap[1].to_string();
                if url.contains(".m3u8") {
                    return Ok(json!({
                        "url": url,
                        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
                    }));
                }
            }
        }
    }
    let embed_html = fetch(&embed, &format!("{HOST}/")).await?;
    let (url, origin) = resolve_embed(&embed_html)
        .ok_or_else(|| ApiError::Internal("JAV.WINE 未从 embed 页解出播放地址".into()))?;
    // links 里常给相对地址（/stream/...），按 embed 源补全。
    let url = if url.starts_with('/') {
        format!("{}{}", origin_of(&embed), url)
    } else {
        url
    };
    let referer = if origin.is_empty() {
        embed.clone()
    } else {
        origin
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": referer},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch_with_edge(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unpacker_roundtrip() {
        // p,a,c,k 形式：'0 1' 中 0->hello 1->world（36 进制下 0/1 不变）。
        let packed = "eval(function(p,a,c,k,e,d){}('0 1',36,2,'hello|world'.split('|')))";
        let out = unpack_packer(packed);
        assert!(out.contains("hello world"), "{out}");
    }

    #[test]
    fn parse_list_card() {
        let html = r#"<article class="post wc-card"><a href="/v/1/"><img data-src="/c.jpg"><h2>片名一</h2><div class="wc-meta">10:00</div></article>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "片名一");
        assert_eq!(items[0]["remark"], "10:00");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("https://jav.wine/?filter=latest", 2),
            "https://jav.wine/?filter=latest&page=2"
        );
        assert_eq!(
            catalog_url("https://jav.wine/jav-movies/", 2),
            "https://jav.wine/jav-movies/page/2/"
        );
    }

    #[test]
    fn player_secure_src_param() {
        let url = "https://jav.wine/player_secure.php?src=https%3A%2F%2Fpic7.sex8sex866.com%2F20260426%2F3oydS4n0%2Findex.m3u8&token=abc";
        assert_eq!(
            query_param(url, "src").unwrap(),
            "https://pic7.sex8sex866.com/20260426/3oydS4n0/index.m3u8"
        );
        assert!(query_param(url, "nope").is_none());
    }

    #[test]
    fn b64_decode_missing_padding() {
        // v 参数末尾常缺 `=` 填充（实测 23502 的 v 即如此）。
        let v = "aHR0cHM6Ly9qYXYud2luZS9wbGF5ZXJfc2VjdXJlLnBocD9zcmM9eA";
        let out = b64_decode_padded(v).unwrap();
        assert!(out.starts_with("https://jav.wine/player_secure.php?src=x"));
    }

    #[test]
    fn first_m3u8_skips_player_secure() {
        let html = "src=\"https://jav.wine/player_secure.php?src=https%3A%2F%2Fpic7.sex8sex866.com%2F20260426%2F3oydS4n0%2Findex.m3u8&token=abc\" src = 'https://pic7.sex8sex866.com/20260426/3oydS4n0/index.m3u8'";
        assert_eq!(
            first_m3u8(html).unwrap(),
            "https://pic7.sex8sex866.com/20260426/3oydS4n0/index.m3u8"
        );
    }

    #[test]
    fn player_src_regex() {
        let html = "jwplayer(\"p\").setup({file: \"x\", src = 'https://pic7.sex8sex866.com/a/index.m3u8'});";
        let cap = player_src_re().captures(html).unwrap();
        assert_eq!(&cap[1], "https://pic7.sex8sex866.com/a/index.m3u8");
    }
}
