//! 18AV：列表为 post 卡片，详情用 mvarr + decodeId 解出真实 id。
//!
//! 与 Dart 的 Zaka18avAmns 一一对应。分类与站内导航 1:1（11 项，
//! slug 形态）。列表：`/zh/<slug>_list/all/<页>.html`；最近更新
//! 走新闻页 `/zh/content_news/all/<当天日期>.html`。搜索：
//! `/zh/fc_search/all/<编码词>/1.html`。详情：标题取 h1，封面取
//! og:image（无则取含 stimg/18avmmcg 的 img），信息取
//! posts-headline/posts-message 成对行（`N/A` 跳过，拼 ` · `）；
//! 分集来自 `mvarr['<键>']=[['<品牌>','<编码>']`：每项先从该项后
//! 的窗口里找 `numresolution=<档位>`，再用 decodeId 把编码解成
//! 真实 id（分隔符为 radix+97 对应字符、每段按 radix 转数后异或、
//! 拼 base64、AES 解密、只留合法字符）；档位 0 叫“正片”，否则
//! “18AV·<档位>P”。取流：分集 video_id 为 `av18:<真实id>:<档位>`，
//! play() 现取 `/js/player/play.php?numresolution=<档位>&id=<真实id>`，
//! 用 pickSource 挑与档位相符的 m3u8（无则取首个 m3u8），`//` 开头
//! 补 `https:`。分片 Referer 要求为站 host + `/zh/`。

use aes::Aes128;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::{
    cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit},
    Decryptor,
};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

/// 镜站池：先 18av.wiki（本机实测 200），再其余。
const HOSTS: &[&str] = &[
    "https://18av.wiki",
    "https://18av.pw",
    "https://18av.ws",
    "https://18av.nl",
    "https://18av01.net",
    "https://18av.online",
    "https://www.18av.ws",
    "https://www.18av.pw",
    "https://www.18av01.net",
    "https://www.18av.nl",
];

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[slug, 名]，与站内导航 1:1。
const CATEGORIES: &[(&str, &str)] = &[
    ("news", "最近更新"),
    ("chinese", "中文字幕AV"),
    ("censored", "有碼AV"),
    ("uncensored", "無碼AV"),
    ("amateurjav", "素人AV"),
    ("reducing-mosaic", "無碼破解"),
    ("animation", "H動畫"),
    ("CensoredAnimation", "H有碼動畫"),
    ("UncensoredAnimation", "H無碼動畫"),
    ("tdAnimation", "H_3D動畫"),
    ("dt", "國產自拍"),
];

/// 是否像 Cloudflare 拦截页。
fn is_challenge(body: &str) -> bool {
    let lower = body.to_lowercase();
    lower.contains("just a moment")
        || lower.contains("cf_chl")
        || lower.contains("challenge-form")
        || lower.contains("attention required")
}

/// 取页：按镜站顺序试，首个 200 且无 CF 挑战标记的正文即用。
async fn fetch(path: &str) -> ApiResult<(String, String)> {
    let mut last_err = String::new();
    for host in HOSTS {
        let url = format!("{host}{path}");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,zh-TW;q=0.8,en;q=0.7")
            .header("Referer", format!("{host}/zh/"))
            .send()
            .await;
        match resp {
            Ok(r) if r.status().as_u16() == 200 => {
                let text = r.text().await.unwrap_or_default();
                if !is_challenge(&text) {
                    return Ok((text, host.to_string()));
                }
                last_err = "CF 挑战页".into();
            }
            Ok(r) => last_err = format!("HTTP {}", r.status().as_u16()),
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(format!(
        "18AV 各镜站均不可用：{last_err}"
    )))
}

/// 当天日期（UTC，YYYY-MM-DD）。
fn today() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86400) as i64;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

/// 分类列表地址。
fn list_path(slug: &str, page: i64) -> String {
    if slug == "news" {
        format!("/zh/content_news/all/{}.html", today())
    } else {
        format!("/zh/{slug}_list/all/{page}.html")
    }
}

/// 解常见 HTML 实体。
fn unesc(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 去标签后取纯文本。
fn plain(raw: &str) -> String {
    let tag = Regex::new(r"<[^>]+>").unwrap();
    unesc(tag.replace_all(raw, "").as_ref())
}

/// 列表卡：按 `<div class='post...'>` 切块。
/// 手工切块：Rust regex 不支持 `(?=...)` 前瞻，原写法
/// `Regex::new(...).unwrap()` 会在调用时 panic。
fn parse_cards(html: &str) -> Vec<Value> {
    const MARKER: &str = "<div class='post";
    let mut starts: Vec<usize> = Vec::new();
    let mut off = 0;
    while let Some(pos) = html[off..].find(MARKER) {
        starts.push(off + pos);
        off += pos + MARKER.len();
    }
    let link_re = Regex::new(
        r#"href=["'](?:https?://[^"']*?)?(/zh/[a-zA-Z-]+_content/\d+/[^"']+?\.html)["']"#,
    )
    .unwrap();
    let title_re = Regex::new(r#"itemprop=["']name headline["']><a[^>]*>(.*?)</a>"#).unwrap();
    let cover_re = Regex::new(r#"<img src=["']([^'"]+)["']"#).unwrap();
    let remark_re = Regex::new(r"(?s)<div class='meta'>([^<]*)</div>").unwrap();
    let mut out: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(html.len());
        let block = &html[start..end];
        let id = match link_re.captures(block) {
            Some(c) => c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
            None => continue,
        };
        if id.is_empty() || seen.contains(&id) {
            continue;
        }
        let title = title_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| plain(m.as_str()))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        let cover = cover_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let remark = remark_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        out.push(item_json(&id, &title, &cover, &remark));
    }
    out
}

/// 从列表页找末页号（用于 has_more）。
fn max_page(html: &str) -> Option<i64> {
    let re = Regex::new(r#"/(?:list|search)/all/(?:[^/"']*/)?(\d{1,6})\.html"#).unwrap();
    re.captures_iter(html)
        .filter_map(|c| c.get(1).and_then(|m| m.as_str().parse::<i64>().ok()))
        .max()
}

/// 解码参数：radix、xor、AES key、AES iv。
struct Dec {
    radix: i64,
    xor: i64,
    key: String,
    iv: String,
}

/// 从详情页解析 decoder 参数。
fn decoder(html: &str) -> Option<Dec> {
    let radix_re = Regex::new(r"hcdeedg252\s*=\s*(\d+)").unwrap();
    let xor_re = Regex::new(r"hadeedg252\s*=\s*(\d+)").unwrap();
    let key_re = Regex::new(r#"argdeqweqweqwe\s*=\s*['"]([^'"]+)['"]"#).unwrap();
    let iv_re = Regex::new(r#"hdddedg252\s*=\s*['"]([^'"]+)['"]"#).unwrap();
    let mut radix = radix_re
        .captures(html)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .unwrap_or(15);
    if radix < 2 || radix > 36 {
        radix = 15;
    }
    if radix > 25 {
        radix %= 25;
    }
    if radix < 2 {
        radix = 15;
    }
    let xor = xor_re
        .captures(html)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .unwrap_or(0);
    let key = key_re
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    let iv = iv_re
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    if key.len() != 16 || iv.len() != 16 {
        return None;
    }
    Some(Dec {
        radix,
        xor,
        key,
        iv,
    })
}

/// 单字符按 radix 转数值（Java Character.digit 语义）。
fn digit_value(c: char, radix: i64) -> i64 {
    let d = if c.is_ascii_digit() {
        (c as i64) - ('0' as i64)
    } else if ('a'..='z').contains(&c) {
        (c as i64) - ('a' as i64) + 10
    } else if ('A'..='Z').contains(&c) {
        (c as i64) - ('A' as i64) + 10
    } else {
        -1
    };
    if d >= 0 && d < radix {
        d
    } else {
        -1
    }
}

/// decodeId：编码串按分隔符切段、每段转数后异或，拼 base64、AES 解密。
fn decode_id(enc: &str, dec: &Dec) -> String {
    if enc.is_empty() {
        return String::new();
    }
    let sep = char::from_u32((dec.radix + 97) as u32).unwrap_or('a');
    let mut b64bytes: Vec<u8> = Vec::new();
    for part in enc.split(sep) {
        if part.is_empty() {
            continue;
        }
        let mut v: i64 = match i64::from_str_radix(part, dec.radix as u32) {
            Ok(n) => n,
            Err(_) => {
                let mut acc: i64 = 0;
                for c in part.chars() {
                    let d = digit_value(c, dec.radix);
                    if d < 0 {
                        break;
                    }
                    acc = acc * dec.radix + d;
                }
                acc
            }
        };
        v ^= dec.xor;
        v &= 0xff;
        b64bytes.push(v as u8);
    }
    let b64str = String::from_utf8_lossy(&b64bytes).to_string();
    let raw = match STANDARD.decode(&b64str) {
        Ok(b) => b,
        Err(_) => match base64::engine::general_purpose::URL_SAFE.decode(&b64str) {
            Ok(b) => b,
            Err(_) => return String::new(),
        },
    };
    if raw.is_empty() || raw.len() % 16 != 0 {
        return String::new();
    }
    let plain = match Decryptor::<Aes128>::new_from_slices(dec.key.as_bytes(), dec.iv.as_bytes())
        .ok()
        .and_then(|c| c.decrypt_padded_vec_mut::<Pkcs7>(&raw).ok())
    {
        Some(p) => p,
        None => return String::new(),
    };
    let text = String::from_utf8_lossy(&plain).trim().to_string();
    if text.is_empty()
        || !text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '=')
    {
        return String::new();
    }
    text
}

/// pickSource：优先取 size 与档位相符的 m3u8，否则取首个 m3u8。
fn pick_source(html: &str, q: &str) -> String {
    let sized_re = Regex::new(r"src:\s*'([^']+)'[^}]*?size:\s*(\d+)").unwrap();
    let mut first_m3u8 = String::new();
    for cap in sized_re.captures_iter(html) {
        let src = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let size = cap.get(2).map(|m| m.as_str()).unwrap_or("");
        if src.contains(".m3u8") {
            if first_m3u8.is_empty() {
                first_m3u8 = src.to_string();
            }
            if size == q {
                return src.to_string();
            }
        }
    }
    if !first_m3u8.is_empty() {
        return first_m3u8;
    }
    let m3u8_re = Regex::new(r"src:\s*'([^']+\.m3u8[^']*)'").unwrap();
    m3u8_re
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

/// 取 og 标签（property=... content="..."）。
fn og(html: &str, prop: &str) -> String {
    let re = Regex::new(&format!(
        r#"<meta[^>]+property="{prop}"[^>]+content="([^"]*)""#
    ))
    .unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
        .unwrap_or_default()
}

/// URLEncoder 式编码：空格成 %20。
fn url_enc(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(slug, name)| category_json(slug, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let slug = category_id.trim();
    let slug = if slug.is_empty() { "news" } else { slug };
    let path = list_path(slug, page);
    let (html, _host) = fetch(&path).await?;
    let cards = parse_cards(&html);
    let has_more = match max_page(&html) {
        Some(max) => page < max,
        None => cards.len() >= 24,
    };
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let sid = series_id.trim();
    let path = if sid.starts_with("http") {
        sid.trim_start_matches("https://")
            .trim_start_matches("http://")
            .split_once('/')
            .map(|(_, rest)| format!("/{rest}"))
            .unwrap_or_else(|| sid.to_string())
    } else if sid.starts_with('/') {
        sid.to_string()
    } else {
        format!("/{sid}")
    };
    let (html, _host) = fetch(&path).await?;
    let title = {
        let re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
        re.captures(&html)
            .and_then(|c| c.get(1))
            .map(|m| plain(m.as_str()))
            .unwrap_or_default()
    };
    if title.is_empty() {
        return Err(ApiError::Internal("18AV 未返回影片标题".into()));
    }
    let mut cover = og(&html, "og:image");
    if cover.is_empty() {
        let re = Regex::new(r#"<img[^>]+src=['"]([^'"]*(?:stimg|18avmmcg)[^'"]*)['"]"#).unwrap();
        cover = re
            .captures(&html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }
    let mut info = String::new();
    let info_re = Regex::new(
        r"(?s)<li class='posts-headline'>(.*?)</li>\s*<li class='posts-message'>(.*?)</li>",
    )
    .unwrap();
    for cap in info_re.captures_iter(&html) {
        let k = cap
            .get(1)
            .map(|m| plain(m.as_str()).replace([':', '：'], ""))
            .unwrap_or_default();
        let v = cap.get(2).map(|m| plain(m.as_str())).unwrap_or_default();
        if k.is_empty() || v.is_empty() || v.eq_ignore_ascii_case("N/A") {
            continue;
        }
        if !info.is_empty() {
            info.push_str(" · ");
        }
        info.push_str(&format!("{k}: {v}"));
    }
    let mut synopsis = format!("片名: {title}\n");
    if !info.is_empty() {
        synopsis.push_str(&format!("信息: {info}\n"));
    }
    synopsis.push_str("来源: 18AV");
    let dec = decoder(&html);
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(dec) = dec {
        let mv_re = Regex::new(r#"mvarr\['(\d+_\d+)'\]=\[\['([^']*)','([^']+)'"#).unwrap();
        let q_re = Regex::new(r"numresolution=(\d+)").unwrap();
        let caps: Vec<_> = mv_re.captures_iter(&html).collect();
        for (idx, cap) in caps.iter().enumerate() {
            let enc = cap.get(3).map(|m| m.as_str()).unwrap_or("");
            if enc.is_empty() {
                continue;
            }
            let match_end = cap.get(0).map(|m| m.end()).unwrap_or(0);
            let window_end = if idx + 1 < caps.len() {
                caps[idx + 1]
                    .get(0)
                    .map(|m| m.start())
                    .unwrap_or(html.len())
            } else {
                (match_end + 2000).min(html.len())
            };
            let window = &html[match_end..window_end];
            let q = q_re
                .captures(window)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().to_string())
                .unwrap_or_else(|| "1080".to_string());
            let real = decode_id(enc, &dec);
            if real.is_empty() {
                continue;
            }
            let name = if q == "0" {
                "18AV·正片".to_string()
            } else {
                format!("18AV·{q}P")
            };
            let vid = format!("av18:{real}:{q}");
            episodes.push(episode_json(&vid, &name, sid));
        }
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("18AV 本条未取到播放线路".into()));
    }
    Ok(json!({
        "id": sid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = url_enc(query.trim());
    let path = format!("/zh/fc_search/all/{q}/1.html");
    let (html, _host) = fetch(&path).await?;
    let cards = parse_cards(&html);
    Ok(json!({"items": cards}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") && vid.contains(".m3u8") {
        return Ok(json!({"url": vid}));
    }
    let parts: Vec<&str> = vid.split(':').collect();
    if parts.len() < 3 || parts[0] != "av18" {
        return Err(ApiError::Internal("18AV 该集没有播放地址".into()));
    }
    let real = parts[1];
    let q = parts[2];
    let mut last_err = String::new();
    for host in HOSTS {
        let url = format!("{host}/js/player/play.php?numresolution={q}&id={real}");
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "*/*")
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .header("Referer", format!("{host}/zh/"))
            .send()
            .await;
        let text = match resp {
            Ok(r) if r.status().as_u16() == 200 => r.text().await.unwrap_or_default(),
            Ok(r) => {
                last_err = format!("HTTP {}", r.status().as_u16());
                continue;
            }
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let mut src = pick_source(&text, q);
        if src.is_empty() {
            last_err = "播放页未返回 m3u8".into();
            continue;
        }
        if let Some(rest) = src.strip_prefix("//") {
            src = format!("https:{rest}");
        }
        if src.contains(".m3u8") {
            return Ok(json!({"url": src}));
        }
        last_err = "播放页未返回 m3u8".into();
    }
    Err(ApiError::Internal(format!("18AV 取流失败：{last_err}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_11() {
        assert_eq!(CATEGORIES.len(), 11);
        assert_eq!(CATEGORIES[0], ("news", "最近更新"));
        assert_eq!(CATEGORIES[10], ("dt", "國產自拍"));
    }

    #[test]
    fn list_paths() {
        assert_eq!(list_path("chinese", 2), "/zh/chinese_list/all/2.html");
        assert!(list_path("news", 1).starts_with("/zh/content_news/all/20"));
    }

    #[test]
    fn decode_id_roundtrip() {
        let dec = Dec {
            radix: 14,
            xor: 5,
            key: "5756b7c2cae381ff".into(),
            iv: "d0844dde00f5e19d".into(),
        };
        let enc = "5ao61o7do37o36o68o5do3co6co52o78o48o54o75o87o62o50o59o55o86o52o5do44o8co68o6bo51o80o51o6co85o60o7co84o48o7co5co4co62o49o54o5ao5do53o71o7ao56o7do75o52o5co6do8co70o84o5co55o7do6do3do38o51o87o7bo68o80o75o8co83o5do34o74o5ao3bo53o55o48o6do34o79o38o3co4ao38o54o6do4bo5ao84o5bo63o82o76o53o81o30o4bo80o78o50o38o56o72o81o60o3co86o40";
        let real = decode_id(enc, &dec);
        assert!(!real.is_empty(), "decodeId 应解出真实 id");
        assert!(real
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '='));
    }

    #[test]
    fn pick_source_prefers_q() {
        let html = "src: 'https://cdn.example.com/a_720.m3u8' size: 720, src: 'https://cdn.example.com/a_1080.m3u8' size: 1080";
        assert_eq!(
            pick_source(html, "720"),
            "https://cdn.example.com/a_720.m3u8"
        );
        assert_eq!(
            pick_source(html, "480"),
            "https://cdn.example.com/a_720.m3u8"
        );
    }

    #[test]
    fn parse_cards_sample() {
        let html = r#"<div class='post'><a href="/zh/censored_content/340538/SDNM-546.html"><img src="https://cdn.example.com/c.jpg"></a><div itemprop="name headline"><a href="/zh/censored_content/340538/SDNM-546.html">片A</a></div><div class='meta'>2026-11-05</div></div><div class='post'><a href="/zh/censored_content/340539/ABCD-123.html"><img src="https://cdn.example.com/d.jpg"></a><div itemprop="name headline"><a href="/zh/censored_content/340539/ABCD-123.html">片B</a></div><div class='meta'>2026-11-04</div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/zh/censored_content/340538/SDNM-546.html");
        assert_eq!(items[0]["title"], "片A");
        assert_eq!(items[0]["cover"], "https://cdn.example.com/c.jpg");
        assert_eq!(items[0]["remark"], "2026-11-05");
        assert_eq!(items[1]["title"], "片B");
    }
}
