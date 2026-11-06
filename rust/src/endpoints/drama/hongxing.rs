//! 红杏：核心里的影视区站点。
//!
//! 入口是中文域名 https://星v视频.hongxingav.xyz/index.php?id=731544
//! （IDN punycode 为 xn--v-uq6b466h2mm.hongxingav.xyz），
//! 该页 JS 跳转到实站 7p-r5-n.hongxingav.xyz（MacCMS 站）。
//! 全站页面是加密壳：壳里只有 __PAGE_KEY 与一个
//! /static/encrypt/<hash>.js，真实 HTML 在该 JS 的
//! __PAGE_ENC 里，经 Base64 解码后按字节与密钥循环异或
//! 还原（密钥取壳内 __PAGE_KEY 的 Base64 解码值，
//! 2026-11-05 实测为 MacEncryptOutput2026K3y@vQxJ8pLm；
//! 解码失败时回退内置默认密钥
//! MacEncryptOutput2026K3y@vQxZ9pLm）。本模块在 Rust 里
//! 复现同一解密流程，解密后再按正常 MacCMS 解析。
//! - 分类 30 个，与首页导航 1:1。
//! - 目录：/index.php/vod/type/id/<id>.html，翻页
//!   /index.php/vod/type/id/<id>/page/<n>.html，
//!   国产情色类实测 48 条/页、1127 页。
//! - 详情：/index.php/vod/detail/id/<id>.html，标题 h1、
//!   封面为首张 /upload/vod/ 图、简介取 meta description；
//!   播放入口 /index.php/vod/play/id/<id>/sid/1/nid/1.html。
//! - 取流：播放页 player_aaaa JSON 的 url 字段即 m3u8
//!   （实测 1279873：2609.sysl2026.com 主清单 200）。
//! - 搜索：/index.php/vod/search.html?wd=<词>，实测“美女”
//!   30 条。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://7p-r5-n.hongxingav.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
/// 解密内置默认密钥（页面注入的 __PAGE_KEY 优先）。
const DEFAULT_KEY: &str = "MacEncryptOutput2026K3y@vQxZ9pLm";

/// 分类静态回退：首页导航，站内顺序，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("6", "精品推荐"),
    ("7", "国产情色"),
    ("9", "AV明星"),
    ("13", "国模私拍"),
    ("17", "国产精品"),
    ("23", "自拍偷拍"),
    ("33", "传媒系列"),
    ("35", "热门大瓜"),
    ("8", "日本无码"),
    ("10", "中文字幕"),
    ("12", "成人动漫"),
    ("15", "邻家人妻"),
    ("16", "日韩无码"),
    ("18", "日韩精品"),
    ("21", "制服诱惑"),
    ("22", "强奸乱伦"),
    ("2", "欧美情色"),
    ("11", "网红主播"),
    ("14", "长腿丝袜"),
    ("20", "欧美精品"),
    ("24", "3P合辑"),
    ("25", "巨乳系列"),
    ("26", "颜射系列"),
    ("27", "口交视频"),
    ("28", "自慰系列"),
    ("29", "SM重味"),
    ("30", "教师学生"),
    ("31", "大秀视频"),
    ("32", "重口味"),
    ("34", "明星系列"),
];

async fn fetch_raw(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("红杏请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// Base64 解码：标准解码失败时先剔除字母表外字符再试一次。
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    if let Ok(b) = STANDARD.decode(s) {
        return Some(b);
    }
    let cleaned: String = s
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '+' || *c == '/' || *c == '=')
        .collect();
    STANDARD.decode(cleaned).ok()
}

/// XOR 解密：密文字节与密钥字节循环异或后按 UTF-8 还原。
fn xor_decrypt(cipher: &[u8], key: &[u8]) -> String {
    if key.is_empty() {
        return String::new();
    }
    let plain: Vec<u8> = cipher
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ key[i % key.len()])
        .collect();
    String::from_utf8_lossy(&plain).into_owned()
}

/// 取页：加密壳先解密，普通页原样回。
async fn get_text(url: &str) -> ApiResult<String> {
    let shell = fetch_raw(url).await?;
    if !shell.contains("__PAGE_KEY") || !shell.contains("/static/encrypt/") {
        return Ok(shell);
    }
    let key_re = Regex::new(r#"__PAGE_KEY="([^"]+)""#).unwrap();
    let mut key_bytes = DEFAULT_KEY.as_bytes().to_vec();
    if let Some(cap) = key_re.captures(&shell) {
        if let Some(decoded) = b64_decode(&cap[1]) {
            if let Ok(k) = String::from_utf8(decoded) {
                if !k.is_empty() {
                    key_bytes = k.into_bytes();
                }
            }
        }
    }
    let js_re = Regex::new(r#"src="([^"]*?/static/encrypt/[a-z0-9]+\.js)""#).unwrap();
    let js_url = match js_re.captures(&shell) {
        Some(cap) => {
            let u = cap[1].to_string();
            if u.starts_with("http") {
                u
            } else if let Some(rest) = u.strip_prefix("//") {
                format!("https://{rest}")
            } else if u.starts_with('/') {
                format!("{BASE}{u}")
            } else {
                format!("{BASE}/{u}")
            }
        }
        None => return Err(ApiError::Internal("红杏加密页未找到密文脚本".into())),
    };
    let js = fetch_raw(&js_url).await?;
    let enc_re = Regex::new(r#"__PAGE_ENC='([^']+)'"#).unwrap();
    let enc = match enc_re.captures(&js) {
        Some(cap) => cap[1].to_string(),
        None => return Err(ApiError::Internal("红杏密文脚本未找到密文".into())),
    };
    let cipher =
        b64_decode(&enc).ok_or_else(|| ApiError::Internal("红杏密文 Base64 解码失败".into()))?;
    Ok(xor_decrypt(&cipher, &key_bytes))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：详情锚点 + img src 封面 + 随后 <h3> 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*><img[^>]*src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let title_re = Regex::new(r#"<h3>([^<]+)</h3>"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = cap[2].trim().to_string();
        let tail = &html[cap.get(0).map(|m| m.end()).unwrap_or(0)..];
        let window = tail.get(..3000).unwrap_or(tail);
        let title = match &title_re {
            Some(re) => re
                .captures(window)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：/index.php/vod/type/id/<id>.html 锚点。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]{1,16})<"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = unescape(cap[2].trim());
        if name.is_empty() || name == "更多" || !seen.insert(id.clone()) {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

/// 播放地址：播放页 player_aaaa JSON 的 url 字段（m3u8）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(BASE).await {
        Ok(html) => {
            let list = parse_categories(&html);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = if page <= 1 {
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!(
            "/index.php/vod/type/id/{category_id}/page/{}.html",
            page + 1
        ))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/index.php/vod/detail/id/")
        .trim_end_matches(".html")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{BASE}/index.php/vod/detail/id/{id}.html")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover_re = Regex::new(r#"<img[^>]*src="([^"]*?/upload/vod/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description" content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("红杏详情未返回标题".into()));
    }
    let ep_id = format!("{id}-1-1");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&ep_id, "播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let parts: Vec<&str> = vid.split('-').collect();
    if parts.len() != 3 {
        return Err(ApiError::Internal("红杏播放地址格式错误".into()));
    }
    let url = format!(
        "{BASE}/index.php/vod/play/id/{}/sid/{}/nid/{}.html",
        parts[0], parts[1], parts[2]
    );
    let html = get_text(&url).await?;
    let stream = parse_player_url(&html);
    if stream.is_empty() {
        return Err(ApiError::Internal("红杏未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/index.php/vod/search.html"),
        &[("wd", query)],
    );
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn xor_encrypt(plain: &str, key: &str) -> String {
        let kb = key.as_bytes();
        let cipher: Vec<u8> = plain
            .as_bytes()
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ kb[i % kb.len()])
            .collect();
        STANDARD.encode(cipher)
    }

    #[test]
    fn xor_decrypt_roundtrip_real_key() {
        let plain = "<html><title>红杏 - 在线观看</title><a href=\"/index.php/vod/detail/id/1279873.html\">片名</a></html>";
        let key = "MacEncryptOutput2026K3y@vQxJ8pLm";
        let enc = xor_encrypt(plain, key);
        let cipher = b64_decode(&enc).unwrap();
        assert_eq!(xor_decrypt(&cipher, key.as_bytes()), plain);
        assert_eq!(b64_decode("a"), None);
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="row col5 clearfix"> <dl> <dt class="preview-item"><a href="/index.php/vod/detail/id/1286916.html" target="_blank"><img class="nature" src="https://un.shayu260522.top/upload/vod/20261021-1/d005d6f0de4ea7beaab1008e8c59c25c.jpg" data-original="https://un.shayu260522.top/upload/vod/20261021-1/d005d6f0de4ea7beaab1008e8c59c25c.jpg"/><i></i> <div class="preview-div"></div> </a></dt> <dd><a href="/index.php/vod/detail/id/1286916.html" target="_blank"><h3>小乔吃不饱04 极品颜值女神被蒙面小哥爆操到沦陷</h3></a></dd> </dl>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "1286916");
        assert!(items[0]["title"]
            .as_str()
            .unwrap()
            .starts_with("小乔吃不饱04"));
        assert_eq!(
            items[0]["cover"],
            "https://un.shayu260522.top/upload/vod/20261021-1/d005d6f0de4ea7beaab1008e8c59c25c.jpg"
        );
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/index.php/vod/type/id/6.html">精品推荐</a><a href="/index.php/vod/type/id/7.html">国产情色</a><a href="/index.php/vod/type/id/7.html">更多</a><a href="/index.php/vod/type/id/6.html">精品推荐</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "6");
        assert_eq!(list[1]["name"], "国产情色");
    }

    #[test]
    fn fallback_has_30_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 30);
        assert_eq!(list[0]["id"], "6");
        assert_eq!(list[29]["id"], "34");
        assert_eq!(list[29]["name"], "明星系列");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/1279873\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"TMW-227"},"url":"https:\/\/2609.sysl2026.com\/20260829\/bJbr1bpA\/index.m3u8","url_next":"","from":"sym3u8","server":"no","note":"","id":"1279873"}"#;
        assert_eq!(
            parse_player_url(html),
            "https://2609.sysl2026.com/20260829/bJbr1bpA/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }
}
