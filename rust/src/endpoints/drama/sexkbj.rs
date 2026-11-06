//! SexKbj（sexkbj.com）：WordPress（retrotube 主题）站。
//! 取流：详情页 `<IFRAME SRC="https://sexkbj.top/embed/<code>">`，
//! 嵌片页是 Dean Edwards 打包脚本，解包后得到
//! `links={"hls4":"/stream/.../master.m3u8","hls2":"https://<cdn>/hls2/.../master.m3u8?t=...&e=129600&..."}`。
//! 优先用 hls2（绝对地址，带 token）；hls4（sexkbj.top 相对路径）
//! 实测 403，仅作回退。
//! 实测 KBJ24101602_baby123123_premium（hls2 720p 变体）：
//! 325 分片、3250.08 秒，与卡片 54:10 精确对上（全长）；
//! 首分片 200 + 0x47。主清单为多清晰度，模块只返回主清单，
//! ExoPlayer 原生可播。
//! 分类与站导航 1:1（KOREAN BJ/PREMIUM/AFREECATV/KOREAN AMATEUR
//! + 首页筛选 最新/最多观看）；分类翻页
//! `/category/<slug>/page/N/`；搜索 `/?s=...`。
//! 注意：翻页 p1/p2 曾出现 4 条重合，是抓取间隔站内新帖顶了
//! 分页所致，非解析问题；卡片解析以 `article.loop-video` 为准。

use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://sexkbj.com";
const EMBED_HOST: &str = "https://sexkbj.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 4 个分类 + 首页筛选。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新"),
    ("most-viewed", "最多观看"),
    ("korean-bj", "KOREAN BJ"),
    ("premium", "PREMIUM"),
    ("afreecatv", "AFREECATV"),
    ("korean-amateur", "KOREAN AMATEUR"),
];

fn word_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\w+").unwrap())
}

fn pack_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?s)\}\('(.*)',(\d+),(\d+),'(.*)'\.split\('\|'\)").unwrap())
}

fn hls_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""hls2":"([^"]+)""#).unwrap())
}

fn hls4_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""hls4":"([^"]+)""#).unwrap())
}

fn embed_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"https://sexkbj\.top/embed/([A-Za-z0-9]+)").unwrap())
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
        return Err(ApiError::Internal(format!("SexKbj 请求 HTTP {status}")));
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
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
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

/// Dean Edwards 打包器的基数字符：0-9a-z，36 以上用 chr(v+29)。
fn encode_base(mut n: u32, base: u32) -> String {
    fn digit(v: u32) -> char {
        if v <= 35 {
            char::from_digit(v, 36).unwrap_or('0')
        } else {
            char::from_u32(v + 29).unwrap_or('?')
        }
    }
    if n < base {
        return digit(n).to_string();
    }
    let mut out = String::new();
    while n >= base {
        out.insert(0, digit(n % base));
        n /= base;
    }
    out.insert(0, digit(n));
    out
}

/// JS 单引号字符串字面量转义还原。
fn js_unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('b') => out.push('\u{0008}'),
            Some('f') => out.push('\u{000C}'),
            Some('v') => out.push('\u{000B}'),
            Some('0') => out.push('\0'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

/// Dean Edwards 打包脚本解包（与 91porna 同款打包器）。
fn dean_unpack(packed: &str) -> Option<String> {
    let cap = pack_re().captures(packed)?;
    let payload = js_unescape(&cap[1]);
    let base: u32 = cap[2].parse().ok()?;
    let count: u32 = cap[3].parse().ok()?;
    let keys: Vec<&str> = cap[4].split('|').collect();
    let mut dict: HashMap<String, String> = HashMap::new();
    for i in 0..count {
        let key = encode_base(i, base);
        let val = keys.get(i as usize).copied().unwrap_or("");
        if val.is_empty() {
            dict.insert(key.clone(), key);
        } else {
            dict.insert(key, val.to_string());
        }
    }
    let re = word_re();
    let out = re.replace_all(&payload, |c: &regex::Captures| {
        dict.get(&c[0]).cloned().unwrap_or_else(|| c[0].to_string())
    });
    Some(out.into_owned())
}

/// 从 HTML 里抠出 Dean Edwards 打包脚本（到下一个 `</script>` 为止）。
fn extract_packed(html: &str) -> Option<String> {
    let start = html.find("eval(function(p,a,c,k,e,d)")?;
    let after = &html[start..];
    let end = after.find("</script>").unwrap_or(after.len());
    Some(after[..end].to_string())
}

/// 解包后取 links.hls2（优先）或 hls4。
fn extract_hls(unpacked: &str) -> Option<String> {
    if let Some(c) = hls_re().captures(unpacked) {
        return Some(c[1].to_string());
    }
    if let Some(c) = hls4_re().captures(unpacked) {
        let p = c[1].to_string();
        if p.starts_with("http") {
            return Some(p);
        }
        return Some(format!("{EMBED_HOST}{p}"));
    }
    None
}

fn attr<'a>(tag: &'a str, name: &str) -> String {
    let marker = format!("{name}=\"");
    let Some(p) = tag.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    tag[s..]
        .find('"')
        .map(|e| decode_entities(&tag[s..s + e]))
        .unwrap_or_default()
}

/// `<article data-video-uid="N" class="loop-video thumb-block ...">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article data-video-uid=").skip(1) {
        let end = block
            .find("<article data-video-uid=")
            .unwrap_or(block.len());
        let block = &block[..end];
        let Some(hp) = block.find("<a href=\"") else {
            continue;
        };
        let s = hp + 9;
        let Some(e) = block[s..].find('"') else {
            continue;
        };
        let href = &block[s..s + e];
        if !href.starts_with("https://sexkbj.com/20") {
            continue;
        }
        if seen.contains(&href.to_string()) {
            continue;
        }
        // 标题：a 标签 title 属性，兜底 entry-header 文本。
        let mut title = String::new();
        if let Some(p) = block.find("title=\"") {
            let s = p + 7;
            if let Some(e) = block[s..].find('"') {
                title = decode_entities(&block[s..s + e]);
            }
        }
        // 封面：img data-src（缩略图是 <name>.mp4.jpg 命名）。
        let mut cover = String::new();
        if let Some(p) = block.find("<img ") {
            let img = &block[p..];
            let ds = attr(img, "data-src");
            let src = attr(img, "src");
            if !ds.is_empty() {
                cover = ds;
            } else if !src.is_empty() {
                cover = src;
            }
            if title.is_empty() {
                title = attr(img, "alt");
            }
        }
        if title.is_empty() {
            continue;
        }
        // 时长：<span class="duration">…01:30:04</span>。
        let mut remark = String::new();
        if let Some(p) = block.find("class=\"duration\"") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</span>") {
                    remark = decode_entities(after[s..s + e].trim());
                    // 去掉 <i> 图标残留。
                    if let Some(gt2) = remark.rfind('>') {
                        remark = remark[gt2 + 1..].trim().to_string();
                    }
                }
            }
        }
        seen.push(href.to_string());
        items.push(item_json(href, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let paged = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}page/{page}/")
        }
    };
    match category_id {
        "latest" => {
            if page <= 1 {
                format!("{HOST}/?filter=latest")
            } else {
                format!("{HOST}/page/{page}/?filter=latest")
            }
        }
        "most-viewed" => {
            if page <= 1 {
                format!("{HOST}/?filter=most-viewed")
            } else {
                format!("{HOST}/page/{page}/?filter=most-viewed")
            }
        }
        _ => paged(format!("{HOST}/category/{category_id}/")),
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
    for sep in [" - SexKBJ", " | SexKBJ"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

/// `itemprop="duration" content="P0DT0H54M10S"` 转“54:10”。
fn parse_iso_duration(raw: &str) -> String {
    let mut h = 0i64;
    let mut m = 0i64;
    let mut s = 0i64;
    let mut num = String::new();
    for c in raw.chars() {
        if c.is_ascii_digit() || c == '.' {
            num.push(c);
        } else {
            let v: f64 = num.parse().unwrap_or(0.0);
            match c {
                'H' => h = v as i64,
                'M' => m = v as i64,
                'S' => s = v as i64,
                _ => {}
            }
            num.clear();
        }
    }
    let total = h * 3600 + m * 60 + s;
    if total <= 0 {
        return String::new();
    }
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
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
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("SexKbj 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let dur = parse_iso_duration(&meta_content(&html, "itemprop", "duration"));
    let desc = if dur.is_empty() {
        String::new()
    } else {
        format!("时长：{dur}")
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
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let cap = embed_re()
        .captures(&html)
        .ok_or_else(|| ApiError::Internal("SexKbj 详情页未找到嵌片地址".into()))?;
    let embed_url = format!("{EMBED_HOST}/embed/{}", &cap[1]);
    let embed_html = fetch(&embed_url, &page_url).await?;
    let packed = extract_packed(&embed_html)
        .ok_or_else(|| ApiError::Internal("SexKbj 嵌片页未找到打包脚本".into()))?;
    let unpacked = dean_unpack(&packed)
        .ok_or_else(|| ApiError::Internal("SexKbj 嵌片页打包脚本解包失败".into()))?;
    let url = extract_hls(&unpacked)
        .ok_or_else(|| ApiError::Internal("SexKbj 未解出 m3u8 地址".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": embed_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 最小 Dean Edwards 包（手造，格式与站内一致）：解出 document.write。
    const PACKED_MINI: &str = r#"eval(function(p,a,c,k,e,d){e=function(c){return(c<a?'':e(parseInt(c/a)))+((c=c%a)>35?String.fromCharCode(c+29):c.toString(36))};if(!''.replace(/^/,String)){while(c--){d[e(c)]=k[c]||e(c)}k=[function(e){return d[e]}];e=function(){return'\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\b'+e(c)+'\b','g'),k[c])}}return p}('1.write("https://example.com/a.m3u8")',62,2,'|document'.split('|'),0,{}))"#;

    #[test]
    fn dean_unpack_mini() {
        let out = dean_unpack(PACKED_MINI).unwrap();
        assert_eq!(out, r#"document.write("https://example.com/a.m3u8")"#);
    }

    #[test]
    fn extract_hls_real_snippet() {
        let unpacked = r#"var links={"hls4":"/stream/0H-wZi6bA-n5NOlXpshlYw/hjkrhuihghfvu/1793973614/12090342/master.m3u8","hls2":"https://HGc0USwxhNN8.acek-cdn.com/hls2/01/02418/jphyfcx80od3_,l,n,h,.urlset/master.m3u8?t=SIh7K7WcyPFlY5atC0FxR8i2CwjOXBZSXsvCpDQ9qcE&s=1793930414&e=129600&f=12090342&srv=mnTs8JVdEBe4&i=0.4&sp=500&p1=mnTs8JVdEBe4&p2=mnTs8JVdEBe4&asn=13335"};"#;
        assert_eq!(
            extract_hls(unpacked).unwrap(),
            "https://HGc0USwxhNN8.acek-cdn.com/hls2/01/02418/jphyfcx80od3_,l,n,h,.urlset/master.m3u8?t=SIh7K7WcyPFlY5atC0FxR8i2CwjOXBZSXsvCpDQ9qcE&s=1793930414&e=129600&f=12090342&srv=mnTs8JVdEBe4&i=0.4&sp=500&p1=mnTs8JVdEBe4&p2=mnTs8JVdEBe4&asn=13335"
        );
        let only4 = r#"var links={"hls4":"/stream/abc/master.m3u8"};"#;
        assert_eq!(
            extract_hls(only4).unwrap(),
            "https://sexkbj.top/stream/abc/master.m3u8"
        );
        assert!(extract_hls("no links here").is_none());
    }

    #[test]
    fn parse_video_card() {
        let html = r#"<article data-video-uid="1" data-post-id="322370" class="loop-video thumb-block post-322370"><a href="https://sexkbj.com/2026/11/05/kbj26103131_qkeksms3bj%ea%b3%a0%ec%9d%b4%eb%82%98na_sexkbj/" title="KBJ26103131_qkeksms3(BJ고이나NA)_sexkbj"><div class="post-thumbnail"><div class="post-thumbnail-container"><img width="300" height="168.75" data-src="https://sexkbj.com/wp-content/uploads/2026/11/31qkeksms3_10292226_sexkbj.mp4.jpg" alt="KBJ26103131_qkeksms3(BJ고이나NA)_sexkbj"></div><span class="views">118</span><span class="duration"><i class="fa fa-clock-o"></i>01:30:04</span></div><header class="entry-header"><span>KBJ26103131_qkeksms3(BJ고이나NA)_sexkbj</span></header></a></article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://sexkbj.com/2026/11/05/kbj26103131_qkeksms3bj%ea%b3%a0%ec%9d%b4%eb%82%98na_sexkbj/"
        );
        assert_eq!(items[0]["title"], "KBJ26103131_qkeksms3(BJ고이나NA)_sexkbj");
        assert_eq!(items[0]["remark"], "01:30:04");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("korean-bj", 1),
            "https://sexkbj.com/category/korean-bj/"
        );
        assert_eq!(
            catalog_url("korean-bj", 2),
            "https://sexkbj.com/category/korean-bj/page/2/"
        );
        assert_eq!(
            catalog_url("latest", 1),
            "https://sexkbj.com/?filter=latest"
        );
    }

    #[test]
    fn parse_iso_duration_spot() {
        assert_eq!(parse_iso_duration("P0DT0H54M10S"), "54:10");
        assert_eq!(parse_iso_duration("P0DT1H30M4S"), "1:30:04");
        assert_eq!(parse_iso_duration(""), "");
    }

    #[test]
    fn embed_code_extract() {
        let html = r#"<div class="responsive-player"><IFRAME SRC="https://sexkbj.top/embed/jphyfcx80od3" FRAMEBORDER=0></IFRAME></div>"#;
        let cap = embed_re().captures(html).unwrap();
        assert_eq!(&cap[1], "jphyfcx80od3");
    }
}
