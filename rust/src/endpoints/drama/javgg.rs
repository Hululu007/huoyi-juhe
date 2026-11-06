//! JavGG（javgg.net）：WordPress DooPlay 站，列表与详情走 HTML 解析。
//! 取流：详情页的播放器 iframe（VidHide 系 embed，如 earnvid /
//! javhdz）→ 页内 Dean Edwards packer 解出 links.hls2 即直链
//! m3u8（实测：变体清单 938 分片、总时长 9379.72 秒、首分片
//! HTTP 206 且首字节 0x47）。默认 iframe 源常已过期（如
//! sexjavhd.online 提示文件已删除），按文档顺序逐个 embed 试到
//! 通为止；f4 系 /api/play 回 403（广告拦截检测），不走；
//! 站内换源 AJAX（admin-ajax.php）被 CF 拦截/超时，不走。
//! 匿名免费可播，无需登录；只做免费部分，不绕付费墙。
//! 分类与站导航 1:1（最新/热门/无码泄露/减码/有码/英字/中字 +
//! 类型与女优索引 + 热门类型与女优）；翻页 `/page/N/`。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javgg.net";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 + 热门类型与女优（首页榜单）。
const CATS: &[(&str, &str)] = &[
    ("new-post", "最新发布"),
    ("trending", "热门趋势"),
    ("tag:uncensored-leak", "无码泄露"),
    ("tag:reduce-mosaic", "减码"),
    ("tag:censored", "有码"),
    ("tag:english-subtitle", "英文字幕"),
    ("tag:chinese-subtitle", "中文字幕"),
    ("genre", "类型"),
    ("star", "女优"),
    ("genre:creampie", "Creampie"),
    ("genre:featured-actress", "Featured Actress"),
    ("genre:exclusive-distribution", "Exclusive Distribution"),
    ("genre:big-tits", "Big Tits"),
    ("genre:hi-def", "Hi-Def"),
    ("genre:married-woman", "Married Woman"),
    ("genre:beautiful-girl", "Beautiful Girl"),
    ("genre:solowork", "Solowork"),
    ("genre:mature-woman", "Mature Woman"),
    ("genre:4k", "4K"),
    ("star:yui-hatano", "Yui Hatano"),
    ("star:yayoi-mizuki", "Yayoi Mizuki"),
    ("star:morisawa-kana", "Morisawa Kana"),
    ("star:matsumoto-ichika", "Matsumoto Ichika"),
    ("star:hamasaki-mao", "Hamasaki Mao"),
    ("star:shinoda-yuu", "Shinoda Yuu"),
];

fn packer_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\}\('(.*)',(\d+),(\d+),'(.*)'\.split\('\|'\)\)").unwrap())
}

fn hls_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#""hls[234]"\s*:\s*"(https?://[^"]+\.(?:m3u8|txt)[^"]*)""#).unwrap()
    })
}

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https?://[^\s"'<>]+(?:\.m3u8|master\.txt)[^\s"'<>]*"#).unwrap())
}

fn iframe_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<iframe[^>]+src=['"]([^'"]+)['"]"#).unwrap())
}

fn embed_url_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"itemprop="embedURL"[^>]*content="([^"]+)""#).unwrap())
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
        return Err(ApiError::Internal(format!("JavGG 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
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

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
        .trim()
        .to_string()
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
    decode_entities(&out)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
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

/// 从一段文本取 links.hls2/hls3/hls4 直链：优先 .m3u8，次之 master.txt。
fn pick_hls(text: &str) -> Option<String> {
    let mut txt: Option<String> = None;
    for cap in hls_re().captures_iter(text) {
        let u = cap[1].to_string();
        if u.contains(".m3u8") {
            return Some(u);
        }
        if txt.is_none() {
            txt = Some(u);
        }
    }
    txt
}

/// 从 embed 页解出 m3u8：先直接找，再解 packer 后取 links.hls2
///（优先 .m3u8，master.txt 次之）。
fn extract_hls(embed_html: &str) -> Option<String> {
    if let Some(u) = pick_hls(embed_html) {
        return Some(u);
    }
    if let Some(u) = m3u8_re()
        .captures_iter(embed_html)
        .map(|c| c[0].to_string())
        .find(|u| !u.contains("player_secure.php"))
    {
        return Some(u);
    }
    let unpacked = unpack_packer(embed_html);
    if unpacked != embed_html {
        if let Some(u) = pick_hls(&unpacked) {
            return Some(u);
        }
        if let Some(u) = m3u8_re().captures(&unpacked).map(|c| c[0].to_string()) {
            return Some(u);
        }
    }
    None
}

/// `<article class="item movies">` 卡片解析（首页/分类/类型/女优页通用）。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        if !block.contains("item movies") && !block.contains("item ") {
            continue;
        }
        let href = match block.find("<a href=\"https://javgg.net/jav/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        if seen.contains(&href.to_string()) {
            continue;
        }
        let code = if let Some(p) = block.find("<h3><a href=") {
            let after = &block[p..];
            let s = after.find('>').map(|i| i + 1).unwrap_or(0);
            let e = after[s..].find("</a>").unwrap_or(after.len() - s);
            strip_tags(&after[s..s + e])
        } else if let Some(p) = block.find("alt=\"") {
            let s = p + 5;
            block[s..]
                .find('"')
                .map(|e| decode_entities(&block[s..s + e]))
                .unwrap_or_default()
        } else {
            String::new()
        };
        if code.is_empty() {
            continue;
        }
        let sub = if let Some(p) = block.find("titlecontent\">") {
            let s = p + 14;
            block[s..]
                .find("</div>")
                .map(|e| strip_tags(&block[s..s + e]))
                .unwrap_or_default()
        } else {
            String::new()
        };
        let title = if sub.is_empty() {
            code.clone()
        } else {
            format!("{code} {sub}")
        };
        let cover = if let Some(p) = block.find("data-src=\"") {
            let s = p + 10;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else if let Some(p) = block.find("<img src=\"") {
            let s = p + 10;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        seen.push(href.to_string());
        items.push(item_json(href, &truncate(&title, 90), &cover, ""));
    }
    items
}

/// 类型/女优索引页：`<li><a href=".../genre|star/{slug}/">名 (数)</a></li>`。
fn parse_tax_index(html: &str, kind: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let marker = format!("https://javgg.net/{kind}/");
    let mut rest = html;
    while let Some(p) = rest.find(&marker) {
        let after = &rest[p..];
        let slug_end = after[marker.len()..]
            .find('/')
            .map(|i| marker.len() + i)
            .unwrap_or(after.len());
        let slug = &after[marker.len()..slug_end];
        if slug.is_empty() || slug.contains('"') || slug.contains('<') {
            rest = &rest[p + marker.len()..];
            continue;
        }
        let gt = after.find('>').map(|i| i + 1).unwrap_or(after.len());
        let e = after[gt..]
            .find("</a>")
            .map(|i| gt + i)
            .unwrap_or(after.len());
        let label = strip_tags(&after[gt..e]);
        let (name, count) = match label.rfind(" (") {
            Some(i) if label.ends_with(')') => (
                label[..i].trim_start_matches('(').trim().to_string(),
                label[i + 2..label.len() - 1].trim().to_string(),
            ),
            _ => (
                label.trim_start_matches('(').trim().to_string(),
                String::new(),
            ),
        };
        if !name.is_empty() {
            items.push(item_json(&format!("{kind}:{slug}"), &name, "", &count));
        }
        rest = &after[gt..];
    }
    items
}

/// 搜索结果页：`<div class="result-item"><article>…`。
fn parse_search(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("result-item").skip(1) {
        let href = match block.find("<a href=\"https://javgg.net/jav/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        if seen.contains(&href.to_string()) {
            continue;
        }
        let title = if let Some(p) = block.find("<div class=\"title\"><a href=") {
            let after = &block[p..];
            let s = after.find('>').map(|i| i + 1).unwrap_or(0);
            let e = after[s..].find("</a>").unwrap_or(after.len() - s);
            strip_tags(&after[s..s + e])
        } else if let Some(p) = block.find("alt=\"") {
            let s = p + 5;
            block[s..]
                .find('"')
                .map(|e| decode_entities(&block[s..s + e]))
                .unwrap_or_default()
        } else {
            String::new()
        };
        if title.is_empty() {
            continue;
        }
        let cover = if let Some(p) = block.find("<img src=\"") {
            let s = p + 10;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        let remark = if let Some(p) = block.find("<span class=\"year\">") {
            let s = p + 19;
            block[s..]
                .find('<')
                .map(|e| block[s..s + e].trim().to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        seen.push(href.to_string());
        items.push(item_json(href, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn list_url(category_id: &str, page: i64) -> String {
    let paged = |base: &str| -> String {
        if page <= 1 {
            base.to_string()
        } else {
            format!("{}/page/{page}/", base.trim_end_matches('/'))
        }
    };
    match category_id {
        "new-post" => paged(&format!("{HOST}/new-post/")),
        "trending" => paged(&format!("{HOST}/trending/")),
        "genre" => format!("{HOST}/genre/"),
        "star" => format!("{HOST}/star/"),
        _ => {
            if let Some(v) = category_id.strip_prefix("tag:") {
                paged(&format!("{HOST}/tag/{v}/"))
            } else if let Some(v) = category_id.strip_prefix("genre:") {
                paged(&format!("{HOST}/genre/{v}/"))
            } else if let Some(v) = category_id.strip_prefix("star:") {
                paged(&format!("{HOST}/star/{v}/"))
            } else {
                paged(&format!("{HOST}/new-post/"))
            }
        }
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
    match t.rsplit_once(" | ") {
        Some((head, _)) => head.trim().to_string(),
        None => t,
    }
}

/// 详情页播放候选 embed 地址（文档顺序）：embedURL meta 在前，
/// 其后是全部非广告 iframe。
fn embed_candidates(html: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Some(cap) = embed_url_re().captures(html) {
        let u = cap[1].to_string();
        if u.starts_with("http") {
            out.push(u);
        }
    }
    for cap in iframe_re().captures_iter(html) {
        let u = cap[1].to_string();
        if !u.starts_with("http") {
            continue;
        }
        let low = u.to_lowercase();
        if low.contains("creative.")
            || low.contains("googletagmanager")
            || low.contains("facebook.com")
            || low.contains("twitter.com")
            || low.contains("x.com/intent")
            || low.contains("reddit.com")
            || low.contains("t.me/share")
            || low.contains("bsky.app")
        {
            continue;
        }
        if !out.contains(&u) {
            out.push(u);
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = list_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = match category_id {
        "genre" => parse_tax_index(&html, "genre"),
        "star" => parse_tax_index(&html, "star"),
        _ => parse_cards(&html),
    };
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("JavGG 未返回影片资料".into()));
    }
    let mut cover = meta_content(&html, "itemprop", "thumbnailUrl");
    if cover.is_empty() {
        cover = meta_content(&html, "property", "og:image");
    }
    let mut desc = meta_content(&html, "itemprop", "description");
    if desc.is_empty() {
        desc = meta_content(&html, "name", "description");
    }
    let desc = truncate(&desc, 400);
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
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let candidates = embed_candidates(&html);
    if candidates.is_empty() {
        return Err(ApiError::Internal("JavGG 详情页未找到播放器地址".into()));
    }
    for embed in candidates {
        let embed_html = match fetch(&embed, &page_url).await {
            Ok(t) => t,
            Err(_) => continue,
        };
        if let Some(url) = extract_hls(&embed_html) {
            return Ok(json!({
                "url": url,
                "header": {"User-Agent": UA, "Referer": embed},
            }));
        }
    }
    Err(ApiError::Internal("JavGG 未从 embed 页解出播放地址".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_search(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_basic() {
        let html = r#"<article id="post-1" class="item movies"><div class="poster"><img data-src="https://javcode.net/wp-content/uploads/2026/11/JUR-892-380x538.webp" loading="lazy" class="lazyload" alt="JUR-892"><div class="titlecontent">Ichika - Forbidden Love and Blackmail</div><a href="https://javgg.net/jav/jur-892/"><div class="see play1"></div></a></div><div class="data dfeatur"><h3><a href="https://javgg.net/jav/jur-892/">JUR-892</a></h3></div></article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["title"],
            "JUR-892 Ichika - Forbidden Love and Blackmail"
        );
        assert!(items[0]["cover"].as_str().unwrap().contains("JUR-892"));
    }

    #[test]
    fn parse_tax_index_basic() {
        let html = r#"<ul><li><a href="https://javgg.net/genre/creampie/">Creampie (98926)</a></li><li><a href="https://javgg.net/genre/big-tits/">Big Tits (57024)</a></li></ul>"#;
        let items = parse_tax_index(html, "genre");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "genre:creampie");
        assert_eq!(items[0]["title"], "Creampie");
        assert_eq!(items[0]["remark"], "98926");
    }

    #[test]
    fn parse_search_basic() {
        let html = r#"<div class="result-item"><article><div class="image"><div class="thumbnail animation-2"><a href="https://javgg.net/jav/ipzz-002-javggco/"><img src="https://javcode.net/wp-content/uploads/2024/02/IPZZ-002.jpg" alt="IPZZ-002" /></a></div></div><div class="details"><div class="title"><a href="https://javgg.net/jav/ipzz-002-javggco/">IPZZ-002</a></div><div class="meta"><span class="year">IDEA POCKET</span></div></div></article></div>"#;
        let items = parse_search(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "IPZZ-002");
        assert_eq!(items[0]["remark"], "IDEA POCKET");
    }

    #[test]
    fn list_url_rules() {
        assert_eq!(
            list_url("new-post", 2),
            "https://javgg.net/new-post/page/2/"
        );
        assert_eq!(
            list_url("tag:uncensored-leak", 1),
            "https://javgg.net/tag/uncensored-leak/"
        );
        assert_eq!(
            list_url("genre:creampie", 3),
            "https://javgg.net/genre/creampie/page/3/"
        );
        assert_eq!(list_url("genre", 2), "https://javgg.net/genre/");
    }

    #[test]
    fn unpacker_roundtrip() {
        // p,a,c,k 形式：'0 1' 中 0->hello 1->world（36 进制下 0/1 不变）。
        let packed = "eval(function(p,a,c,k,e,d){}('0 1',36,2,'hello|world'.split('|')))";
        let out = unpack_packer(packed);
        assert!(out.contains("hello world"), "{out}");
    }

    #[test]
    fn extract_hls_from_unpacked_links() {
        let unpacked = r#"var links={"hls3":"https://x.shop/a/hls3/01/1/id_,l,n,h,.urlset/master.txt","hls2":"https://x.cdn.com/hls2/01/1/id_,l,n,h,.urlset/master.m3u8?t=abc&s=1"};jwplayer("vplayer").setup({sources:[{file:links.hls4||links.hls3||links.hls2,type:"hls"}]});"#;
        let url = extract_hls(unpacked).unwrap();
        assert!(url.contains("master.m3u8"), "{url}");
    }

    #[test]
    fn embed_candidates_skip_ads() {
        let html = r#"<meta itemprop="embedURL" content="https://javhdz.site/e/a51s1xpzr4hu" /><iframe src='https://sexjavhd.online/v/ykzzcwiivbk6'></iframe><iframe src="https://creative.sexjavhd.site/widgets/v4/Universal?userId=1"></iframe>"#;
        let c = embed_candidates(html);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0], "https://javhdz.site/e/a51s1xpzr4hu");
        assert_eq!(c[1], "https://sexjavhd.online/v/ykzzcwiivbk6");
    }
}
