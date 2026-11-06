//! 🔞Roshy：roshy.tv 的 WordPress 站（vidmov 主题 + beeteam 播放器）。
//!
//! 列表（article.post-item 卡片解析：a 的 href 取 id、title 取标题、
//! 234x351 缩略图取封面、ENG/DC 标签取备注；30 条/页，翻页
//! `/category/{slug}/page/{N}/`；搜索 `/?s=词`）、详情（og 标题
//! 封面、meta 简介、/stars/ 女优）、取流（详情页 beeteam 播放器
//! 配置里 video_url 是嵌套播放器 iframe，先取 kamehaus 系嵌套页，
//! 再解 Dean Edwards 打包 JS 取 links.hls2 的 master.m3u8，
//! 签名有时效，须现取现用）。
//! 验门（2026-11-06 本机出口实测）：首页导航 8 分类；english-sub
//! 分类 p1 30 条、p2 30 条不重合；搜索 SDDE 30 条；详情 SDDE-479
//! 与 SSNI-799 的嵌套播放器都是 kamehaus.net/e/{id}；解包后
//! hls2 720p 变体 1470 分片/14695.614 秒，与播放器标注时长
//! 14695.68 秒对上（全长 4 小时 5 分），首分片 Range 206 +
//! TS 魔数 0x47。hls4 直链本机回 403，优先用 hls2。
//! 分类与站首页导航 1:1；翻页 `/category/{slug}/page/{N}/`。

use regex::{NoExpand, Regex};
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://roshy.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：首页导航验过的 8 分类。
const CATS: &[(&str, &str)] = &[
    ("english-sub-11", "English Sub"),
    ("decensored-6", "Decensored"),
    ("big-tits-2", "Big Tits"),
    ("creampie", "Creampie"),
    ("cuckold", "Cuckold"),
    ("married-woman-3", "Married Woman"),
    ("mature-woman-2", "Mature Woman"),
    ("solowork", "Solowork"),
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
        return Err(ApiError::Internal(format!("Roshy 请求 HTTP {status}")));
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

/// `<article ... class="post-item ...">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article id=\"post-").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("href=\"https://roshy.tv/video/") {
            Some(p) => {
                let s = p + 6;
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
        // 封面：第一张 wp-content/uploads 图片（234x351 缩略图优先）。
        let mut cover = String::new();
        let mut rest = block;
        while let Some(p) = rest.find("https://roshy.tv/wp-content/uploads/") {
            let after = &rest[p..];
            let end = after
                .find(|c: char| c == '"' || c == '\'' || c == ' ' || c == '<')
                .unwrap_or(after.len());
            let url = &after[..end];
            if url.contains(".jpg") || url.contains(".webp") || url.contains(".png") {
                cover = url.to_string();
                break;
            }
            rest = &rest[p + 1..];
        }
        // 备注：ENG / DC 这类标签。
        let mut labels: Vec<String> = Vec::new();
        let mut rest2 = block;
        while let Some(p) = rest2.find("beeteam368-duration") {
            let after = &rest2[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find('<') {
                    let label = after[s..s + e].trim().to_string();
                    if !label.is_empty() && !labels.contains(&label) {
                        labels.push(label);
                    }
                }
            }
            rest2 = &rest2[p + 1..];
            if labels.len() >= 3 {
                break;
            }
        }
        seen.push(id.clone());
        items.push(item_json(
            &id,
            &truncate(&title, 90),
            &cover,
            &labels.join(" · "),
        ));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let slug = if category_id.is_empty() {
        "english-sub-11"
    } else {
        category_id
    };
    if page <= 1 {
        format!("{HOST}/category/{slug}/")
    } else {
        format!("{HOST}/category/{slug}/page/{page}/")
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

/// 女优：/stars/ 链接文本。
fn extract_actors(html: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = html;
    while let Some(p) = rest.find("href=\"https://roshy.tv/stars/") {
        let after = &rest[p..];
        if let Some(gt) = after.find('>') {
            let s = gt + 1;
            if let Some(e) = after[s..].find("</a>") {
                let name = decode_entities(after[s..s + e].trim());
                if !name.is_empty() && !out.contains(&name) {
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

/// beeteam 播放器配置里 video_url 的嵌套播放器 iframe 地址。
fn extract_embed_url(html: &str) -> String {
    let marker = "video_url\":\"<iframe src=\"";
    let Some(p) = html.find(marker) else {
        return String::new();
    };
    let s = p + marker.len();
    match html[s..].find('"') {
        Some(e) => html[s..s + e].to_string(),
        None => String::new(),
    }
}

/// JS 字符串转义还原（打包 JS 的载荷与字典都是单引号 JS 字符串）。
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

/// 打包器用的 62 进制数字（0-9a-zA-Z）。
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

/// Dean Edwards 打包 JS 解包：按字典从大到小编号做整词替换。
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

/// 解包后的 links 对象取流：优先 hls2（本机验过），再 hls4、hls3。
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
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
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
    if let Some(i) = title.find(" - ROSHY.TV") {
        title = title[..i].trim().to_string();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("Roshy 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let mut desc = meta_content(&html, "name", "description");
    let actors = extract_actors(&html);
    if !actors.is_empty() {
        if !desc.is_empty() {
            desc.push('\n');
        }
        desc.push_str(&format!("女优：{}", actors.join("、")));
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
    let embed = extract_embed_url(&html);
    if embed.is_empty() {
        return Err(ApiError::Internal("Roshy 详情页未找到嵌套播放器".into()));
    }
    let embed_html = fetch(&embed, &page_url).await?;
    let unpacked = unpack_packer(&embed_html).ok_or_else(|| {
        ApiError::Internal("Roshy 嵌套播放器解包失败（站可能改了打包方式）".into())
    })?;
    let url = extract_links(&unpacked);
    if url.is_empty() {
        return Err(ApiError::Internal("Roshy 嵌套播放器未找到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": embed},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?s={}",
        url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unpack_small_packer() {
        let packed = r#"eval(function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\b'+c.toString(a)+'\b','g'),k[c]);return p}('0 1 2',62,3,'a|b|c'.split('|'),0,{}))"#;
        assert_eq!(unpack_packer(packed).unwrap(), "a b c");
        assert!(unpack_packer("no packer here").is_none());
    }

    #[test]
    fn base62_digits() {
        assert_eq!(to_base62(0), "0");
        assert_eq!(to_base62(9), "9");
        assert_eq!(to_base62(10), "a");
        assert_eq!(to_base62(35), "z");
        assert_eq!(to_base62(36), "A");
        assert_eq!(to_base62(61), "Z");
        assert_eq!(to_base62(62), "10");
    }

    #[test]
    fn js_unescape_common() {
        assert_eq!(js_unescape(r#"a\/b\"c\\d"#), "a/b\"c\\d");
        assert_eq!(js_unescape(r"x\ny"), "x\ny");
    }

    #[test]
    fn links_prefer_hls2() {
        let unpacked = r#"var links={"hls4":"/stream/xx/master.m3u8","hls2":"https://wnsa7jyhmnmt12.premilkyway.com/hls2/01/15253/hf9uryjdpsgl_,l,n,h,.urlset/master.m3u8?t=abc","hls3":"https://example.com/hls3/master.txt"};"#;
        assert_eq!(
            extract_links(unpacked),
            "https://wnsa7jyhmnmt12.premilkyway.com/hls2/01/15253/hf9uryjdpsgl_,l,n,h,.urlset/master.m3u8?t=abc"
        );
        let only4 = r#"var links={"hls4":"/stream/xx/master.m3u8"};"#;
        assert_eq!(extract_links(only4), "/stream/xx/master.m3u8");
        assert_eq!(extract_links("nothing"), "");
    }

    #[test]
    fn embed_url_from_player_config() {
        let html = r#"jQuery('#beeteam368_player_1').beeteam368_pro_player({"video_mode":"embed","video_url":"<iframe src="https://kamehaus.net/e/hf9uryjdpsgl" allowfullscreen></iframe>","media_sources":[{"source_formats":"auto"}]});"#;
        assert_eq!(
            extract_embed_url(html),
            "https://kamehaus.net/e/hf9uryjdpsgl"
        );
        assert_eq!(extract_embed_url("no player"), "");
    }

    #[test]
    fn parse_post_card() {
        let html = r#"<article id="post-203800" class="post-item site__col flex-row-control post-203800 vidmov_video type-vidmov_video status-publish has-post-thumbnail hentry">
     <div class="post-item-wrap">
          <div class="post-featured-image" ><div class="beeteam368-bt-to-img"><span class="beeteam368-duration tag-label">ENG</span><span class="beeteam368-duration tag-label">DC</span></div><a data-post-id="203800" data-post-type="vidmov_video" href="https://roshy.tv/video/sdde-479-xxx/" title="[SDDE-479] [ENGLISH SUBTITLES] [DECENSORED] (Back) Handjob Clinic" class="blog-img-link blog-img-link-control"><picture><source srcset="https://roshy.tv/wp-content/uploads/2026/11/sdde-479-dc-eng-234x351.jpg.webp 234w, https://roshy.tv/wp-content/uploads/2026/11/sdde-479-dc-eng-88x132.jpg.webp 88w" sizes='(max-width: 234px) 100vw, 234px' type="image/webp"><img fetchpriority="high" width="234" height="351" src="https://roshy.tv/wp-content/uploads/2026/11/sdde-479-dc-eng-234x351.jpg.webp" alt="[SDDE-479]"></picture></a></div>
     </div>
</article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://roshy.tv/video/sdde-479-xxx/");
        assert!(items[0]["title"]
            .as_str()
            .unwrap()
            .starts_with("[SDDE-479]"));
        assert_eq!(
            items[0]["cover"],
            "https://roshy.tv/wp-content/uploads/2026/11/sdde-479-dc-eng-234x351.jpg.webp"
        );
        assert_eq!(items[0]["remark"], "ENG · DC");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("english-sub-11", 1),
            "https://roshy.tv/category/english-sub-11/"
        );
        assert_eq!(
            catalog_url("english-sub-11", 2),
            "https://roshy.tv/category/english-sub-11/page/2/"
        );
        assert_eq!(
            catalog_url("decensored-6", 3),
            "https://roshy.tv/category/decensored-6/page/3/"
        );
    }
}
