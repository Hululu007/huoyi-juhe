//! 🔞JavDino：javdino.com 的 JAV 站（多嵌套播放器线路）。
//!
//! 列表（div.v-items 卡片解析：video-link 取 id、img 取封面、
//! alt 取标题；20 条/页，p1 为服务端直出，p>1 走无限滚动
//! POST /ajax/genre_ajax.php（keyword={slug}/&page=N&sortBy=latest）；
//! 搜索 `/search/{词}`）、详情（og 标题封面、meta 简介、女优与
//! 类型链接）、取流（详情页 data-embed 按钮是 base64url 编码的
//! 嵌套播放器地址，按线路依次试：hohoj.tv 优先，其次 morencius
//! 系打包 JS 的 links.hls2；其余线路本机不通）。
//! 验门（2026-11-06 本机出口实测）：/genre/ 页 22 类型 + 首页
//! 导航的 mature-woman，共 23 分类；big-tits 类型 p1 20 条、
//! ajax p2 20 条不重合；搜索 NSFS 20 条；详情 NSFS-096：hohoj
//! 嵌套页直出 m3u8，1906 分片/7622.464 秒，首分片 Range 206 +
//! TS 魔数 0x47（全长 127 分钟）；SPRD-933 的 morencius 线路
//! 解包后 hls2 清单两次回 502（本机出口不通，未验过，作备选）；
//! 其余线路：hgcloud/hglink 为 JS 等待页、upload18.org 被 CF
//! 拦 403、voe.sx 要 localStorage、javdino 自有 player.php 走
//! 的 xxxfoxy 清单分片是 PNG 图片不是视频、sv9 嵌套的
//! sadie-shop 未验。
//! 分类与站 /genre/ 页 1:1；翻页走 POST /ajax/genre_ajax.php。

use base64::Engine;
use regex::{NoExpand, Regex};
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javdino.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：/genre/ 页验过的 23 类型。
const CATS: &[(&str, &str)] = &[
    ("big-tits", "Big-Tits"),
    ("creampie", "Creampie"),
    ("mature-woman", "Mature Woman"),
    ("female-teacher", "Female Teacher"),
    ("ntr", "NTR"),
    ("mother-daughter", "Mother-Daughter"),
    ("milf", "MILF"),
    ("cheating-wife", "Cheating Wife"),
    ("schoolgirl", "Schoolgirl"),
    ("black-man", "Black Man"),
    ("massage", "Massage"),
    ("deep-throat", "Deep-throat"),
    ("anal-sex", "Anal Sex"),
    ("female-boss", "Female Boss"),
    ("married-woman", "Married Woman"),
    ("bondage", "Bondage"),
    ("lesbian", "Lesbian"),
    ("widow", "Widow"),
    ("auntie", "Auntie"),
    ("chubby", "Chubby"),
    ("female-detective", "Female Detective"),
    ("private-tutor", "Private Tutor"),
    ("threesome-foursome", "Threesome-Foursome"),
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
        return Err(ApiError::Internal(format!("JavDino 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn fetch_post_form(url: &str, referer: &str, body: &str) -> ApiResult<String> {
    let resp = client()?
        .post(url)
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Referer", referer)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JavDino 请求 HTTP {status}")));
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

/// `<div class="v-items ...">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"v-items ").skip(1) {
        let end = block.find("<div class=\"v-items ").unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a href=\"/video/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let id = format!("{HOST}{href}");
        if seen.contains(&id) {
            continue;
        }
        let title = match block.find("alt=\"") {
            Some(p) => {
                let s = p + 5;
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
        let cover = match block.find("<img src=\"") {
            Some(p) => {
                let s = p + 10;
                block[s..]
                    .find('"')
                    .map(|e| block[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        // 备注：卡片里的时长（形如 127:00），没有则空。
        let remark = match Regex::new(r"(\d{1,3}:\d{2}(?::\d{2})?)") {
            Ok(re) => re
                .captures(block)
                .map(|c| c[1].to_string())
                .unwrap_or_default(),
            Err(_) => String::new(),
        };
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
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

/// 详情页链接文本：`<a href="/{kind}/...">NAME</a>`。
fn page_links(html: &str, kind: &str) -> Vec<String> {
    let marker = format!("href=\"/{kind}/");
    let mut out: Vec<String> = Vec::new();
    let mut rest = html;
    while let Some(p) = rest.find(&marker) {
        let after = &rest[p..];
        if let Some(gt) = after.find('>') {
            let s = gt + 1;
            if let Some(e) = after[s..].find("</a>") {
                let name = decode_entities(after[s..s + e].trim());
                if !name.is_empty()
                    && !name.starts_with('+')
                    && !name.starts_with("View All")
                    && !out.contains(&name)
                {
                    out.push(name);
                }
            }
        }
        rest = &rest[p + 1..];
        if out.len() >= 8 {
            break;
        }
    }
    out
}

/// data-embed 的 base64url 解码（无填充）。
fn decode_b64url(s: &str) -> Option<String> {
    let mut norm: String = s.replace('-', "+").replace('_', "/");
    while norm.len() % 4 != 0 {
        norm.push('=');
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(norm.as_bytes())
        .ok()?;
    String::from_utf8(bytes).ok()
}

/// 详情页全部嵌套播放器地址（按按钮顺序）。
fn extract_embeds(html: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = html;
    while let Some(p) = rest.find("data-embed='") {
        let s = p + 12;
        if let Some(e) = rest[s..].find('\'') {
            if let Some(url) = decode_b64url(&rest[s..s + e]) {
                if url.starts_with("http") && !out.contains(&url) {
                    out.push(url);
                }
            }
        }
        rest = &rest[p + 1..];
    }
    out
}

/// 页内第一个 .m3u8 直链（hohoj 嵌套页直出）。
fn first_m3u8(html: &str) -> String {
    let Some(p) = html.find(".m3u8") else {
        return String::new();
    };
    let start = html[..p].rfind("https://").unwrap_or(0);
    let rest = &html[start..];
    let end = rest
        .find(|c: char| c == '"' || c == '\'' || c == '<' || c == ' ' || c == '\n')
        .unwrap_or(rest.len());
    let url = &rest[..end];
    if url.contains(".m3u8") {
        url.to_string()
    } else {
        String::new()
    }
}

fn js_unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('\\') => out.push('\\'),
            Some('\'') => out.push('\''),
            Some('"') => out.push('"'),
            Some('/') => out.push('/'),
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('b') => out.push('\u{0008}'),
            Some('f') => out.push('\u{000C}'),
            Some('v') => out.push('\u{000B}'),
            Some('0') => out.push('\0'),
            Some('x') => {
                let hex: String = chars.by_ref().take(2).collect();
                if let Ok(n) = u32::from_str_radix(&hex, 16) {
                    if let Some(ch) = char::from_u32(n) {
                        out.push(ch);
                    }
                }
            }
            Some('u') => {
                let hex: String = chars.by_ref().take(4).collect();
                if let Ok(n) = u32::from_str_radix(&hex, 16) {
                    if let Some(ch) = char::from_u32(n) {
                        out.push(ch);
                    }
                }
            }
            Some(other) => out.push(other),
            None => break,
        }
    }
    out
}

fn to_base62(mut n: usize) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    if n == 0 {
        return "0".to_string();
    }
    let mut out = Vec::new();
    while n > 0 {
        out.push(DIGITS[n % 62]);
        n /= 62;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

fn packer_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"eval\(function\(p,a,c,k,e,d\)[^}]*\}\('((?:[^'\\]|\\.)*)',(\d+),(\d+),'((?:[^'\\]|\\.)*)'\.split\('\|'\)").unwrap()
    })
}

/// Dean Edwards 打包 JS 解包（与 roshy 同款写法）。
fn unpack_packer(html: &str) -> Option<String> {
    let cap = packer_re().captures(html)?;
    let payload = js_unescape(cap.get(1)?.as_str());
    let radix: usize = cap.get(2)?.as_str().parse().ok()?;
    let count: usize = cap.get(3)?.as_str().parse().ok()?;
    let dict_raw = js_unescape(cap.get(4)?.as_str());
    let dict: Vec<&str> = dict_raw.split('|').collect();
    if radix != 62 || count == 0 || dict.len() < count {
        return None;
    }
    let mut out = payload;
    for c in (0..count).rev() {
        let word = dict[c];
        if word.is_empty() {
            continue;
        }
        let key = to_base62(c);
        let re = Regex::new(&format!(r"\b{}\b", regex::escape(&key))).ok()?;
        out = re.replace_all(&out, NoExpand(word)).to_string();
    }
    Some(out)
}

/// 解包后的 links 对象取流：优先 hls2，再 hls4、hls3。
fn extract_links(unpacked: &str) -> String {
    for key in ["hls2", "hls4", "hls3"] {
        let marker = format!("\"{key}\":\"");
        if let Some(p) = unpacked.find(&marker) {
            let s = p + marker.len();
            if let Some(e) = unpacked[s..].find('"') {
                let url = &unpacked[s..s + e];
                if url.contains(".m3u8") || url.contains("master") {
                    return url.to_string();
                }
            }
        }
    }
    String::new()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let slug = if category_id.is_empty() {
        "big-tits"
    } else {
        category_id
    };
    let genre_url = format!("{HOST}/genre/{slug}/");
    if page <= 1 {
        let html = fetch(&genre_url, &format!("{HOST}/")).await?;
        let items = parse_cards(&html);
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    let body = format!(
        "keyword={}%2F&page={page}&sortBy=latest",
        url::form_urlencoded::byte_serialize(slug.as_bytes()).collect::<String>()
    );
    let html = fetch_post_form(&format!("{HOST}/ajax/genre_ajax.php"), &genre_url, &body).await?;
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
    let mut title = meta_content(&html, "property", "og:title");
    if let Some(stripped) = title.strip_prefix("Watch ") {
        title = stripped.to_string();
    }
    if let Some(i) = title.find(" At Javdino") {
        title = title[..i].trim().to_string();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("JavDino 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let mut desc = meta_content(&html, "name", "description");
    let actresses = page_links(&html, "actress");
    let genres = page_links(&html, "genre");
    let mut lines: Vec<String> = Vec::new();
    if !actresses.is_empty() {
        lines.push(format!("女优：{}", actresses.join("、")));
    }
    if !genres.is_empty() {
        lines.push(format!("类型：{}", genres.join("、")));
    }
    if !lines.is_empty() {
        if !desc.is_empty() {
            desc.push('\n');
        }
        desc.push_str(&lines.join("\n"));
    }
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
    if video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let embeds = extract_embeds(&html);
    if embeds.is_empty() {
        return Err(ApiError::Internal("JavDino 详情页未找到播放线路".into()));
    }
    // 优先 hohoj.tv：嵌套页直出 m3u8（NSFS-096 实测通）。
    for embed in &embeds {
        if embed.contains("hohoj.tv") {
            let embed_html = fetch(embed, &page_url).await?;
            let url = first_m3u8(&embed_html);
            if !url.is_empty() {
                return Ok(json!({
                    "url": url,
                    "header": {"User-Agent": UA, "Referer": embed},
                }));
            }
        }
    }
    // 其次 morencius 系打包 JS：解包取 links.hls2（SPRD-933 本机
    // 验到 hls2 清单回 502 未通，手机侧须复验）。
    for embed in &embeds {
        if embed.contains("morencius.com") || embed.contains("sadie-shop.site") {
            let embed_html = fetch(embed, &page_url).await?;
            if let Some(unpacked) = unpack_packer(&embed_html) {
                let url = extract_links(&unpacked);
                if !url.is_empty() {
                    return Ok(json!({
                        "url": url,
                        "header": {"User-Agent": UA, "Referer": embed},
                    }));
                }
            }
        }
    }
    Err(ApiError::Internal(
        "JavDino 各线路均未取到播放地址（hohoj/morencius 未通）".into(),
    ))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/{}",
        url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 data-embed（NSFS-096 的 hohoj 线路）。
    const EMBED_HOHOJ: &str = "aHR0cHM6Ly9ob2hvai50di9lbWJlZD9pZD04NTE2";
    const EMBED_HGCLOUD: &str = "aHR0cHM6Ly9oZ2Nsb3VkLnRvL2UvMjIwaGFya3JubnJ5";

    #[test]
    fn b64url_decodes_embeds() {
        assert_eq!(
            decode_b64url(EMBED_HOHOJ).unwrap(),
            "https://hohoj.tv/embed?id=8516"
        );
        assert_eq!(
            decode_b64url(EMBED_HGCLOUD).unwrap(),
            "https://hgcloud.to/e/220harkrnnry"
        );
        assert!(decode_b64url("!!!").is_none());
    }

    #[test]
    fn unpack_small_packer() {
        let packed = r#"eval(function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\b'+c.toString(a)+'\b','g'),k[c]);return p}('0 1 2',62,3,'a|b|c'.split('|'),0,{}))"#;
        assert_eq!(unpack_packer(packed).unwrap(), "a b c");
    }

    #[test]
    fn first_m3u8_from_hohoj_page() {
        let html = "var src = \"https://video-5.ggjav.com/video_1/59402-NSFS-096.mp4/index.m3u8\";";
        assert_eq!(
            first_m3u8(html),
            "https://video-5.ggjav.com/video_1/59402-NSFS-096.mp4/index.m3u8"
        );
        assert_eq!(first_m3u8("no stream"), "");
    }

    #[test]
    fn parse_video_card() {
        let html = r#"<div class="row" id="result-container">
			<div class="v-items col-sm-6 col-lg-3 p-1 mb-4">
						<a href="/video/332889/fway-101" class="video-link">
							<div class="card border-secondary rounded-4 rounded-bottom-0 shadow-sm">
								<div class="thumb-wrap">
									<img src="https://cdn.javdino.com/fway-101/thumb.jpg" class="img-card-top img-fluid rounded-4 rounded-bottom-0 thumb_preload" loading="lazy" alt="FWAY-101 Konoha Mitsu Slender JAV">
									<div class="overlay-code d-flex align-items-start h-25"></div>
								</div>
							</div>
						</a>
			</div>
		</div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://javdino.com/video/332889/fway-101");
        assert_eq!(items[0]["title"], "FWAY-101 Konoha Mitsu Slender JAV");
        assert_eq!(
            items[0]["cover"],
            "https://cdn.javdino.com/fway-101/thumb.jpg"
        );
    }

    #[test]
    fn page_links_actress() {
        let html = r#"<a href="/actress/3423/misaki-sugisaki">Misaki Sugisaki</a> <a href="/genre/big-tits">+  BigTits JAV</a>"#;
        assert_eq!(
            page_links(html, "actress"),
            vec!["Misaki Sugisaki".to_string()]
        );
        assert!(page_links(html, "genre").is_empty());
    }
}
