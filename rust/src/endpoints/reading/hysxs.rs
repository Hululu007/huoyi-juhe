//! H有声小说（hysxs，成人有声站）。
//!
//! 照搬 py 原文：站名自带 H 成人标识；14 个候选域名按序探活
//! （GET /ting/index.php，页里同时含 book/detail/id/ 与 H有声小说
//! 才算活），进程内缓存活域名，取数失败时重新探活；分类只有音声剧
//! 场/同人有声；详情页 const tracks 里的地址是 base64 + AES-CBC
//! 加密（页内 key/iv，缺省用内置 DEF_KEY/DEF_IV，只取前 16 字节，
//! 与 py _expand_key 只取前 4 个字一致），解出 http 地址才算一集；
//! 取流三种形态：直链透传、hysxs:书:序号（现取详情再按序号取轨）、
//! 标题$地址（取 $ 后一段，# 截断）。py init 的 cookie/proxy/域名
//! 钉选核心签名里没有，省略。

use std::sync::Mutex;

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const SITE_KEY: &str = "hysxs";
const DEF_KEY: &[u8] = b"Hz64QG3atyY7lx0e";
const DEF_IV: &[u8] = b"mxuGOKmLNl2fHOl3";

const HOSTS: [&str; 14] = [
    "62.hysxs.work",
    "62.hysxs.sbs",
    "62.hysxs.cc",
    "62.hysxs.biz",
    "62.hysxs.buzz",
    "62.hysxs.pro",
    "62.hysxs.xyz",
    "62.hysxs.lol",
    "62.hysxs.lat",
    "62.hysxs.site",
    "hysxs.work",
    "hysxs.sbs",
    "hysxs.cc",
    "hysxs.biz",
];

const TYPES: [(&str, &str); 2] = [("1", "音声剧场"), ("2", "同人有声")];

static HOST: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

static CARD_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r#"(?s)/ting/index\.php/book/detail/id/(\d+)\.html"[^>]*class="hover-zoom[^>]*>.*?class="text-primary[^>]*>(.*?)</span>.*?class="text-jade[^>]*>(.*?)</small>.*?class="col-md-2[^>]*>\s*([\d:]+)\s*</div>"#,
    )
    .unwrap()
});
static CARD_ID_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"/ting/index\.php/book/detail/id/(\d+)\.html").unwrap());
static CARD_TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)class="text-primary[^>]*>(.*?)</span>"#).unwrap());
static PAGE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"/page/(\d+)\.html").unwrap());
static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
static WS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static TITLE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<title>(.*?)</title>").unwrap());
static MAIN_TITLE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"class="main-title">([^<]+)<"#).unwrap());
static SSTYPE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"var sstypeid\s*=\s*'(\d+)'").unwrap());
static KEY_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"var key\s*=\s*CryptoJS\.enc\.Utf8\.parse\("([^"]+)"\)"#).unwrap());
static IV_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"var iv\s*=\s*CryptoJS\.enc\.Utf8\.parse\("([^"]+)"\)"#).unwrap());
static TRACKS_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)const tracks\s*=\s*\[(.*?)\];").unwrap());
static TRACK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"title:\s*"([^"]+)",\s*url:\s*"([^"]+)""#).unwrap());

/// py _clean：去标签（调用方先做）后再把空白压成单个空格并去首尾。
fn clean(s: &str) -> String {
    WS_RE.replace_all(s.trim(), " ").into_owned()
}

fn strip_tags(s: &str) -> String {
    TAG_RE.replace_all(s, "").into_owned()
}

/// py base64.b64decode 的宽容版：去空白、补 =，标准解码（失败为空）。
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

/// py urllib.parse.quote 默认 safe="/"：保留 unreserved 与 /，其余 %XX。
fn quote(s: &str) -> String {
    let mut out = String::new();
    for &b in s.as_bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || "-_.~/".contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// py _request 的行为：任何失败（网络错、非 200）都返回空串，不抛错。
async fn fetch_raw(url: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    let Ok(resp) = c
        .get(url)
        .header("User-Agent", UA)
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .send()
        .await
    else {
        return String::new();
    };
    if resp.status().as_u16() != 200 {
        return String::new();
    }
    resp.text().await.unwrap_or_default()
}

fn alive(html: &str) -> bool {
    !html.is_empty() && html.contains("book/detail/id/") && html.contains("H有声小说")
}

fn cached_host() -> Option<String> {
    HOST.lock().ok().and_then(|g| g.clone())
}

async fn resolve_host() -> Option<String> {
    for h in HOSTS {
        let html = fetch_raw(&format!("https://{h}/ting/index.php")).await;
        if alive(&html) {
            if let Ok(mut g) = HOST.lock() {
                *g = Some(h.to_string());
            }
            return Some(h.to_string());
        }
    }
    None
}

/// py _fetch：无缓存域名先探活；页不活且不是详情页时重新探活换域名。
async fn fetch(path: &str) -> ApiResult<String> {
    let mut host = match cached_host() {
        Some(h) => h,
        None => match resolve_host().await {
            Some(h) => h,
            None => return Err(ApiError::Internal("H有声小说无可用域名".into())),
        },
    };
    let html = fetch_raw(&format!("https://{host}{path}")).await;
    if alive(&html) || path.starts_with("/ting/index.php/book/detail/") {
        return Ok(html);
    }
    let old = host.clone();
    if let Ok(mut g) = HOST.lock() {
        *g = None;
    }
    if let Some(new_host) = resolve_host().await {
        if new_host != old {
            host = new_host;
            return Ok(fetch_raw(&format!("https://{host}{path}")).await);
        }
    }
    Ok(html)
}

/// py _aes_cbc_decrypt：手写 CBC（AES-128 解块 + 与前一密文块异或，
/// 只解整块），填充只在合法 PKCS7 时去掉，否则保留原数据。
fn aes_cbc_decrypt(data: &[u8], key: &[u8], iv: &[u8]) -> ApiResult<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if key.len() < 16 || iv.len() < 16 {
        return Err(ApiError::Internal("H有声小说密钥长度不足".into()));
    }
    let cipher = aes::Aes128::new(GenericArray::from_slice(&key[..16]));
    let mut out = Vec::with_capacity(data.len());
    let mut prev = iv[..16].to_vec();
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        for i in 0..16 {
            out.push(block[i] ^ prev[i]);
        }
        prev = chunk.to_vec();
    }
    if !out.is_empty() {
        let pad = out[out.len() - 1] as usize;
        if (1..=16).contains(&pad)
            && pad <= out.len()
            && out[out.len() - pad..].iter().all(|&b| b as usize == pad)
        {
            out.truncate(out.len() - pad);
        }
    }
    Ok(out)
}

fn cards(html: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in CARD_RE.captures_iter(html) {
        let bid = cap[1].to_string();
        if !seen.insert(bid.clone()) {
            continue;
        }
        let title = clean(&strip_tags(&cap[2]));
        let _author = clean(&strip_tags(&cap[3]));
        let dur = cap[4].trim().to_string();
        out.push(item_json(&bid, &title, "", &dur));
    }
    if !out.is_empty() {
        return out;
    }
    let ids: Vec<String> = CARD_ID_RE
        .captures_iter(html)
        .map(|c| c[1].to_string())
        .collect();
    let titles: Vec<String> = CARD_TITLE_RE
        .captures_iter(html)
        .map(|c| clean(&strip_tags(&c[1])))
        .collect();
    for (bid, title) in ids.into_iter().zip(titles.into_iter()) {
        if !seen.insert(bid.clone()) {
            continue;
        }
        out.push(item_json(&bid, &title, "", ""));
    }
    out
}

fn pagecount(html: &str, card_len: usize) -> i64 {
    let mut max = 0i64;
    for cap in PAGE_RE.captures_iter(html) {
        if let Ok(n) = cap[1].parse::<i64>() {
            if n > max {
                max = n;
            }
        }
    }
    if max > 0 {
        max
    } else if card_len > 0 {
        1
    } else {
        0
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": TYPES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let pg = if page < 1 { 1 } else { page };
    if !TYPES.iter().any(|(id, _)| *id == category_id) {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let html = fetch(&format!(
        "/ting/index.php/book/type/id/{category_id}/page/{pg}.html"
    ))
    .await?;
    let items = cards(&html);
    let total_pages = pagecount(&html, items.len());
    Ok(json!({"items": items, "has_more": pg < total_pages}))
}

struct AudioDetail {
    title: String,
    typename: String,
    tracks: Vec<(String, String)>,
}

async fn audio_detail(bid: &str) -> ApiResult<AudioDetail> {
    let html = fetch(&format!("/ting/index.php/book/detail/id/{bid}.html")).await?;
    if html.is_empty() {
        return Err(ApiError::Internal("H有声小说详情为空".into()));
    }
    let mut title = TITLE_RE
        .captures(&html)
        .map(|c| clean(&c[1]))
        .unwrap_or_default();
    title = title.trim_end_matches("-H有声小说").trim().to_string();
    if title.is_empty() {
        title = MAIN_TITLE_RE
            .captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_else(|| bid.to_string());
    }
    // py 用 -H有声小说\s*$ 正则去尾缀；上面 trim_end_matches 去掉尾缀
    // 后再 trim，与之等价（尾缀后只剩空白时同样去掉）。
    let typename = SSTYPE_RE
        .captures(&html)
        .and_then(|c| {
            TYPES
                .iter()
                .find(|(id, _)| *id == &c[1])
                .map(|(_, n)| n.to_string())
        })
        .unwrap_or_default();
    let key: Vec<u8> = KEY_RE
        .captures(&html)
        .map(|c| c[1].as_bytes().to_vec())
        .unwrap_or_else(|| DEF_KEY.to_vec());
    let iv: Vec<u8> = IV_RE
        .captures(&html)
        .map(|c| c[1].as_bytes().to_vec())
        .unwrap_or_else(|| DEF_IV.to_vec());
    let mut tracks = Vec::new();
    if let Some(tm) = TRACKS_RE.captures(&html) {
        for t in TRACK_RE.captures_iter(&tm[1]) {
            let raw = b64decode(&t[2]);
            let Ok(dec) = aes_cbc_decrypt(&raw, &key, &iv) else {
                continue;
            };
            let url = String::from_utf8_lossy(&dec).into_owned();
            if url.starts_with("http") {
                tracks.push((t[1].to_string(), url));
            }
        }
    }
    Ok(AudioDetail {
        title,
        typename,
        tracks,
    })
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let first = series_id.split(',').next().unwrap_or("");
    let bid: String = first.chars().filter(|c| c.is_ascii_digit()).collect();
    if bid.is_empty() {
        return Err(ApiError::BadRequest("H有声小说书 id 无效".into()));
    }
    let d = audio_detail(&bid).await?;
    let episodes: Vec<Value> = d
        .tracks
        .iter()
        .map(|(t, u)| episode_json(u, t, &bid))
        .collect();
    let typename = if d.typename.is_empty() {
        "有声".to_string()
    } else {
        d.typename.clone()
    };
    Ok(json!({
        "id": bid,
        "title": d.title,
        "cover": "",
        "synopsis": format!("分类：{typename} · 共{}集", episodes.len()),
        "extra": {"typename": d.typename},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let wd = query.trim();
    if wd.is_empty() {
        return Ok(json!({"items": []}));
    }
    let html = fetch(&format!(
        "/ting/index.php/book/search/wd/{}/page/1.html",
        quote(wd)
    ))
    .await?;
    let items = cards(&html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut pid = video_id.split(',').next().unwrap_or("").trim().to_string();
    if pid.contains('$') && !pid.starts_with("http") {
        pid = pid
            .split_once('$')
            .map(|(_, after)| after.to_string())
            .unwrap_or_default();
    }
    if pid.contains('#') {
        pid = pid.split('#').next().unwrap_or("").to_string();
    }
    let mut url = String::new();
    if pid.starts_with("http") {
        url = pid.clone();
    } else if pid.starts_with(&format!("{SITE_KEY}:")) {
        let parts: Vec<&str> = pid.split(':').collect();
        if parts.len() == 3 {
            let idx: i64 = parts[2].parse().unwrap_or(-1);
            if idx >= 0 {
                let d = audio_detail(parts[1]).await?;
                if (idx as usize) < d.tracks.len() {
                    url = d.tracks[idx as usize].1.clone();
                }
            }
        }
    }
    let host = cached_host().unwrap_or_else(|| HOSTS[0].to_string());
    if url.is_empty() {
        return Err(ApiError::Internal("H有声小说未取到音频地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {
            "User-Agent": UA,
            "Referer": format!("https://{host}/ting/index.php"),
        },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_collapses_ws() {
        assert_eq!(clean("  a\t\n b  "), "a b");
        assert_eq!(strip_tags("<b>你</b>好"), "你好");
    }

    #[test]
    fn pagecount_rules() {
        assert_eq!(pagecount("<a href=\"/page/3.html\">3</a>", 5), 3);
        assert_eq!(pagecount("no pages", 5), 1);
        assert_eq!(pagecount("no pages", 0), 0);
    }

    #[test]
    fn quote_search_word() {
        assert_eq!(quote("你好"), "%E4%BD%A0%E5%A5%BD");
        assert_eq!(quote("a/b"), "a/b");
    }
}
