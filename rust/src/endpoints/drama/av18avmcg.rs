//! 18AV主站：列表为 post 卡片，详情用 mvarr + decodeId 解出真实 id。
//!
//! 与 Dart 的 Zaka18avMcgAmns 一一对应（同站 av18av 的姊妹站，同一套
//! 模板与取流链）。分类与 jar 的 _classes 1:1，共 55 项：最近更新
//! news + L 大类 10 项 + M 厂商 12 项 + G 标签 32 项（jar 的精选子集；
//! 站上标签共 397 个，jar 只列 32 个；所列 32 个名字里无萝莉/幼女/
//! 未成年相关词——站上的 G:129「蘿莉塔」与 G:35「正太控」不在 jar
//! 清单里，本模块也不收）。
//! 列表：L 走 `/zh/<slug>_list/all/<页>.html`；M 走
//! `/zh/uncensored_makersr/<n>/x/<页>.html`；G 走
//! `/zh/censored_category/<n>/x/<页>.html`；最近更新走新闻页
//! `/zh/content_news/all/<当天日期>.html`。搜索：
//! `/zh/fc_search/all/<编码词>/1.html`。详情：标题取 h1，封面取
//! JSON-LD 的 thumbnailUrl（本站无 og:image；`<img>` 兜底会误取
//! 搜索图标与侧栏图，故不用），信息取 posts-headline/posts-message
//! 成对行（`N/A` 跳过，拼 ` · `），女优取 _avperformer 链接文本；
//! 分集来自 `mvarr['<键>']=[['<品牌>','<编码>']`：每项先从该项后
//! 的窗口里找 `numresolution=<档位>`，再用 decodeId 把编码解成
//! 真实 id（分隔符为 radix+97 对应字符、每段按 radix 转数后异或、
//! 拼 base64、AES 解密、只留合法字符）；档位 0 叫“正片”，否则
//! “<档位>P”。取流：分集 video_id 为 `av18mcg:<真实id>:<档位>`，
//! play() 现取 `/js/player/play.php?numresolution=<档位>&id=<真实id>`，
//! 用 pickSource 挑与档位相符的 m3u8（无则取首个 m3u8），`//` 开头
//! 补 `https:`。分片 Referer 要求为站 host + `/zh/`。
//! 镜站池：18av.pw、18av.ws、18av01.cc 等（2026-11-05 实测均含
//! mvarr）；主站 18av.mm-cg.com 的详情页不含 mvarr（播放数据缺
//! 失），故排除在池外。注意：play.php 返回的 m3u8 实测为 10 秒
//! tip.ts 预告（两部片同款），即本站免费流只有预告，全片不在
//! 该链上；模块按 jar 与 av18av 同款逻辑返回该地址，注册时按
//! 预告站定夺。

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

/// 镜站池：先 18av.pw（本机实测详情含 mvarr），再其余；主站
/// 18av.mm-cg.com 详情页无 mvarr，已排除。
const HOSTS: &[&str] = &[
    "https://18av.pw",
    "https://18av.ws",
    "https://18av01.cc",
    "https://18av01.net",
    "https://18av.online",
    "https://18av.nl",
    "https://18av.wiki",
    "https://www.18av.ws",
    "https://www.18av.pw",
    "https://www.18av01.net",
    "https://www.18av.nl",
];

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类：[id, 名]，与 jar 的 _classes 1:1（news + L 10 + M 12 + G 32）。
const CATEGORIES: &[(&str, &str)] = &[
    ("news", "最近更新"),
    ("L:chinese", "中文字幕AV"),
    ("L:censored", "有碼AV"),
    ("L:uncensored", "無碼AV"),
    ("L:amateurjav", "素人AV"),
    ("L:reducing-mosaic", "無碼破解"),
    ("L:animation", "H動畫"),
    ("L:CensoredAnimation", "H有碼動畫"),
    ("L:UncensoredAnimation", "H無碼動畫"),
    ("L:tdAnimation", "H_3D動畫"),
    ("L:dt", "國產自拍"),
    ("M:17", "HEYZO"),
    ("M:29", "東京熱(Tokyo Hot)"),
    ("M:30", "カリビアンコム(Caribbeancom)"),
    ("M:31", "天然むすめ(10musume)"),
    ("M:32", "一本道(1pondo)"),
    ("M:34", "エッチな4610"),
    ("M:35", "ガチん娘！(Gachinco)"),
    ("M:36", "パコパコママ(pacopacomama)"),
    ("M:38", "人妻斬り0930"),
    ("M:39", "エッチな0930"),
    ("M:40", "カリビアンコム PPV(Caribbeancompr)"),
    ("M:126", "トリプルエックス (XXX-AV)"),
    ("G:2", "女同性戀"),
    ("G:4", "野外・露出"),
    ("G:5", "偶像藝人"),
    ("G:7", "近親相姦"),
    ("G:12", "偷窥"),
    ("G:15", "癡漢"),
    ("G:17", "奴隷"),
    ("G:21", "通姦"),
    ("G:22", "鬼畜"),
    ("G:23", "學校作品"),
    ("G:32", "運動"),
    ("G:34", "出軌"),
    ("G:38", "觸手"),
    ("G:40", "拷問"),
    ("G:44", "M男"),
    ("G:47", "デカチン・巨根"),
    ("G:50", "巨尻"),
    ("G:51", "ハーレム"),
    ("G:58", "女主播"),
    ("G:63", "家庭教師"),
    ("G:70", "各種職業"),
    ("G:80", "美少女"),
    ("G:95", "眼鏡"),
    ("G:100", "旗袍"),
    ("G:127", "巨乳"),
    ("G:142", "中出"),
    ("G:151", "口交"),
    ("G:161", "騎乗位"),
    ("G:169", "多P"),
    ("G:195", "DMM獨家"),
    ("G:207", "4小時以上作品"),
    ("G:210", "高畫質"),
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
        "18AV主站各镜站均不可用：{last_err}"
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
fn list_path(category_id: &str, page: i64) -> String {
    if category_id == "news" {
        return format!("/zh/content_news/all/{}.html", today());
    }
    if let Some(slug) = category_id.strip_prefix("L:") {
        return format!("/zh/{slug}_list/all/{page}.html");
    }
    if let Some(n) = category_id.strip_prefix("M:") {
        return format!("/zh/uncensored_makersr/{n}/x/{page}.html");
    }
    if let Some(n) = category_id.strip_prefix("G:") {
        return format!("/zh/censored_category/{n}/x/{page}.html");
    }
    format!("/zh/censored_list/all/{page}.html")
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

/// 列表卡：按 `<div class='post...'>` 开头切块（regex 不支持前瞻，
/// 不用 av18av 同款含 `(?=...)` 的写法，那写法运行时会 panic）。
fn parse_cards(html: &str) -> Vec<Value> {
    let start_re = Regex::new(r"<div class='post[^']*'>").unwrap();
    let starts: Vec<usize> = start_re.find_iter(html).map(|m| m.start()).collect();
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

/// 取 JSON-LD 的 thumbnailUrl（本站无 og:image）。
fn json_ld_thumb(html: &str) -> String {
    let re = Regex::new(r#""thumbnailUrl"\s*:\s*"([^"]+)""#).unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unesc(m.as_str()))
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
        .map(|(id, name)| category_json(id, name))
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
        return Err(ApiError::Internal("18AV主站未返回影片标题".into()));
    }
    let mut cover = og(&html, "og:image");
    if cover.is_empty() {
        cover = json_ld_thumb(&html);
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
    let mut performers: Vec<String> = Vec::new();
    let perf_re = Regex::new(
        "/zh/[a-z0-9-]+_avperformer/\\d+/[^'\"]+['\"]\\s*>(.*?)</a>",
    )
    .unwrap();
    for cap in perf_re.captures_iter(&html) {
        let name = cap
            .get(1)
            .map(|m| plain(m.as_str()))
            .unwrap_or_default();
        if name.is_empty() || performers.contains(&name) {
            continue;
        }
        performers.push(name);
    }
    let mut synopsis = format!("片名: {title}\n");
    if !performers.is_empty() {
        synopsis.push_str(&format!("女优: {}\n", performers.join("、")));
    }
    if !info.is_empty() {
        synopsis.push_str(&format!("信息: {info}\n"));
    }
    synopsis.push_str("来源: 18AV主站");
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
                "正片".to_string()
            } else {
                format!("{q}P")
            };
            let vid = format!("av18mcg:{real}:{q}");
            episodes.push(episode_json(&vid, &name, sid));
        }
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("18AV主站本条未取到播放线路".into()));
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
    if parts.len() < 3 || parts[0] != "av18mcg" {
        return Err(ApiError::Internal("18AV主站该集没有播放地址".into()));
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
            return Ok(json!({"url": src, "header": {"User-Agent": UA, "Referer": format!("{host}/zh/")}}));
        }
        last_err = "播放页未返回 m3u8".into();
    }
    Err(ApiError::Internal(format!("18AV主站取流失败：{last_err}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_55() {
        assert_eq!(CATEGORIES.len(), 55);
        assert_eq!(CATEGORIES[0], ("news", "最近更新"));
        assert_eq!(CATEGORIES[1], ("L:chinese", "中文字幕AV"));
        assert_eq!(CATEGORIES[11], ("M:17", "HEYZO"));
        assert_eq!(CATEGORIES[22], ("M:126", "トリプルエックス (XXX-AV)"));
        assert_eq!(CATEGORIES[23], ("G:2", "女同性戀"));
        assert_eq!(CATEGORIES[54], ("G:210", "高畫質"));
    }

    #[test]
    fn list_paths() {
        assert_eq!(list_path("L:chinese", 2), "/zh/chinese_list/all/2.html");
        assert_eq!(list_path("M:17", 1), "/zh/uncensored_makersr/17/x/1.html");
        assert_eq!(list_path("G:207", 3), "/zh/censored_category/207/x/3.html");
        assert!(list_path("news", 1).starts_with("/zh/content_news/all/20"));
    }

    #[test]
    fn decode_id_real_sample() {
        // 2026-11-05 实测：18av.pw 详情 SDNM-546 的 mvarr['10_1'] 编码串。
        let dec = Dec {
            radix: 20,
            xor: 5,
            key: "ff7c26a5b09927cd".into(),
            iv: "d30200611228d17b".into(),
        };
        let enc = "28u5du41u40u38u28u3hu5bu3bu57u3fu3gu28u3fu31u5au35u42u30u3fu52u59u3ju2bu5au5ju5du4ju4du26u5au46u34u2du45u3iu28u3bu3bu50u2du5du55u36u56u5ju5bu3cu41u22u38u4ju57u4iu4hu57u67u5du35u4du4fu5du5ju2au59u3hu2eu58u55u5au43u3au65u41u44u29u5ju4fu4du2eu5bu34u22u50u3eu52u34u3iu54u2au4fu2bu65u5hu3eu5cu2fu65u35u2cu4hu3gu3du3iu56u5eu3gu2g";
        let real = decode_id(enc, &dec);
        assert_eq!(
            real,
            "Tnn0yzBlZQ-WxFr6Frhi1_wt63jwzNxRL8zn_qi9KTtnTA8-s_8wRCBQKTWGbPLx"
        );
    }

    #[test]
    fn pick_source_prefers_q() {
        let html = "src: '//cdn.example.com/a_720.m3u8' size: 720, src: '//cdn.example.com/a_1080.m3u8' size: 1080";
        assert_eq!(
            pick_source(html, "1080"),
            "//cdn.example.com/a_1080.m3u8"
        );
        assert_eq!(
            pick_source(html, "480"),
            "//cdn.example.com/a_720.m3u8"
        );
    }

    #[test]
    fn json_ld_thumb_found() {
        let html = r#"<script type="application/ld+json">{"@type":"VideoObject","thumbnailUrl":"https://stimg1.vcwinford.cc/27,xxx/18avmmcg/b/censored/425218_SDNM-546.jpg"}</script>"#;
        assert_eq!(
            json_ld_thumb(html),
            "https://stimg1.vcwinford.cc/27,xxx/18avmmcg/b/censored/425218_SDNM-546.jpg"
        );
        assert_eq!(json_ld_thumb("<html></html>"), "");
    }

    #[test]
    fn parse_cards_fixture() {
        let html = r#"<div class='post'><a href="/zh/censored_content/340538/SDNM-546.html"><img src="https://stimg1.example.com/s/censored/425218_SDNM-546.jpg"></a><div itemprop="name headline"><a href="/zh/censored_content/340538/SDNM-546.html">SDNM-546 玉井晴香</a></div><div class='meta'>2026-11-05</div></div></div></div>"#;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0]["id"], "/zh/censored_content/340538/SDNM-546.html");
        assert_eq!(cards[0]["title"], "SDNM-546 玉井晴香");
        assert_eq!(cards[0]["cover"], "https://stimg1.example.com/s/censored/425218_SDNM-546.jpg");
        assert_eq!(cards[0]["remark"], "2026-11-05");
    }
}

