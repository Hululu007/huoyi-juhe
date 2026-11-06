//! 云梦在线（云梦v）：核心里的影视区站点。
//!
//! 入口 https://y-y.yunmengv.shop/index.php?id=548693 是 JS 跳转页，
//! 实站 https://89-ew-e.yunmengv.shop（MacCMS，yunmengv 模板）。
//! 全站页面加密：外壳页只含 `window.__PAGE_KEY`（Base64 密钥，
//! 解出 `MacEncryptOutput2026K3y@vQxZ9pLm`）与
//! `/static/encrypt/<hash>.js`；该 JS 含 `window.__PAGE_ENC`
//!（Base64 密文），解密 = Base64 解码后逐字节与密钥循环异或，
//! 与站方 page_decrypt.js 同款。与站导航 1:1（31 项）：
//! /vodtype/<n>.html；每页 36 条，翻页 /vodtype/<n>-<页>.html。
//! 卡片 `<a href="/voddetail/<n>.html">` + img src 封面 + alt 标题。
//! 详情 /voddetail/<n>.html（标题、简介、分类），4 条播放地址都
//! 指向 /vodplay/<n>-1-1.html，内有 player_aaaa 的 m3u8
//!（主清单 200、变体清单 200 METHOD=NONE、首分片 200）。
//! 搜索 /vodsearch/-------------.html?wd=。写源照站原样写，不按
//! 站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use base64::engine::{general_purpose::STANDARD, Engine};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://89-ew-e.yunmengv.shop";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("2", "欧美情色"),
    ("6", "精品推荐"),
    ("7", "国产情色"),
    ("8", "日本无码"),
    ("9", "AV明星"),
    ("10", "中文字幕"),
    ("11", "网红主播"),
    ("12", "成人动漫"),
    ("13", "国模私拍"),
    ("14", "长腿丝袜"),
    ("15", "邻家人妻"),
    ("16", "日韩无码"),
    ("17", "国产精品"),
    ("18", "日韩精品"),
    ("20", "欧美精品"),
    ("21", "制服诱惑"),
    ("22", "强奸乱伦"),
    ("23", "自拍偷拍"),
    ("24", "3P合辑"),
    ("25", "巨乳系列"),
    ("26", "颜射系列"),
    ("27", "口交视频"),
    ("28", "自慰系列"),
    ("29", "SM重味"),
    ("30", "教师学生"),
    ("31", "大秀视频"),
    ("32", "重口味"),
    ("33", "传媒系列"),
    ("34", "明星系列"),
    ("35", "热门大瓜"),
    ("36", "人妻系列"),
];

/// 带重试的 GET：站经出口代理较慢，最多试 3 次，每次间隔 2 秒。
async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("云梦在线请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// XOR 解密：Base64 密文解码后与密钥逐字节循环异或。
fn xor_decrypt(cipher_b64: &str, key: &[u8]) -> ApiResult<String> {
    let raw = STANDARD
        .decode(cipher_b64.trim())
        .map_err(|e| ApiError::Internal(format!("云梦在线密文解码失败：{e}")))?;
    if key.is_empty() {
        return Err(ApiError::Internal("云梦在线解密密钥为空".into()));
    }
    let plain: Vec<u8> = raw
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ key[i % key.len()])
        .collect();
    String::from_utf8(plain)
        .map_err(|e| ApiError::Internal(format!("云梦在线解密结果非 UTF-8：{e}")))
}

fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

/// 取解密后的完整页面：外壳页 → 密钥 + 加密 JS 地址 → 密文 → 解密。
async fn get_page(url: &str) -> ApiResult<String> {
    let shell = get_text(url).await?;
    let key_re = Regex::new(r#"window\.__PAGE_KEY="([^"]+)""#)
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let key_b64 = key_re
        .captures(&shell)
        .map(|m| m[1].to_string())
        .unwrap_or_default();
    let key = STANDARD.decode(key_b64.trim()).unwrap_or_default();
    let js_re = Regex::new(r#"src="([^"]*?/static/encrypt/[^"]+\.js)""#)
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let js_url = match js_re.captures(&shell) {
        Some(cap) => fix_url(&cap[1]),
        None => return Err(ApiError::Internal("云梦在线外壳页无加密 JS".into())),
    };
    let js = get_text(&js_url).await?;
    let enc_re = Regex::new(r"window\.__PAGE_ENC='([^']+)'")
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let cipher = match enc_re.captures(&js) {
        Some(cap) => cap[1].to_string(),
        None => return Err(ApiError::Internal("云梦在线加密 JS 无密文".into())),
    };
    xor_decrypt(&cipher, &key)
}

/// 分类解析：首页导航 /vodtype/<n>.html + title 属性，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/vodtype/(\d+)\.html"[^>]*title="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || !seen.insert(id.clone()) {
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

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_page(BASE).await {
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

/// 卡片解析：`<a href="/voddetail/<n>.html">` 内 img src 封面 + alt 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/voddetail/(\d+)\.html"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*alt="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[2]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page <= 1 {
        format!("{BASE}/vodtype/{category_id}.html")
    } else {
        format!("{BASE}/vodtype/{category_id}-{page}.html")
    };
    let html = get_page(&url).await?;
    let items = parse_cards(&html);
    let has_more =
        !items.is_empty() && html.contains(&format!("/vodtype/{category_id}-{}", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 player_aaaa JSON 的 url 字段（m3u8，\/ 转义还原）。
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

fn detail_id(series_id: &str) -> String {
    let s = series_id.trim().trim_start_matches('/');
    let s = s.strip_prefix("voddetail/").unwrap_or(s);
    s.trim_end_matches(".html").to_string()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = detail_id(series_id);
    let url = format!("{BASE}/voddetail/{id}.html");
    let html = get_page(&url).await?;
    let title_re = Regex::new(r"<title>(.*?)</title>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = title.split("免费高清在线观看").next() {
        title = stripped.trim().trim_matches(['《', '》']).to_string();
    }
    let cover_re = Regex::new(r#"(?s)<img[^>]*src="(https?://[^"]*?/upload/vod/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].trim().to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let genre_re = Regex::new(r"在线观看_(.*?)全集_云梦v").ok();
    let genre = match &genre_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("云梦在线详情未返回标题".into()));
    }
    let play_url = format!("{BASE}/vodplay/{id}-1-1.html");
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&play_url, "播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.ends_with(".m3u8") || video_id.ends_with(".mp4") {
        return Ok(json!({"url": video_id}));
    }
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!(
            "{BASE}/vodplay/{}.html",
            video_id
                .trim_start_matches('/')
                .trim_start_matches("vodplay/")
        )
    };
    let html = get_page(&url).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("云梦在线未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/vodsearch/-------------.html"),
        &[("wd", query)],
    );
    let html = get_page(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xor_decrypt_real_vector() {
        let key = STANDARD
            .decode("TWFjRW5jcnlwdE91dHB1dDIwMjZLM3lAdlF4WjlwTG0=")
            .unwrap();
        let plain = xor_decrypt("qdvyo8zFBJ/F/6fa4REXFwMCAQ==", &key).unwrap();
        assert_eq!(plain, "云梦v测试abc123");
    }

    #[test]
    fn parse_categories_real_markup() {
        let html = r#"<li><a href="/vodtype/2.html" onclick="searchOrRedirect('/vodtype/2.html')" title="欧美情色" target="_blank" rel="nofollow" value="liclick">欧美情色</a></li>
                  <li><a href="/vodtype/6.html" onclick="searchOrRedirect('/vodtype/6.html')" title="精品推荐" target="_blank" rel="nofollow" value="liclick">精品推荐</a></li>
                  <li><a href="/vodtype/2.html" onclick="searchOrRedirect('/vodtype/2.html')" title="欧美情色" target="_blank" rel="nofollow" value="liclick">欧美情色</a></li>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "2");
        assert_eq!(list[0]["name"], "欧美情色");
        assert_eq!(list[1]["id"], "6");
    }

    #[test]
    fn fallback_has_31_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 31);
        assert_eq!(list[0]["id"], "2");
        assert_eq!(list[30]["name"], "人妻系列");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="list">
    <a href="/voddetail/1304965.html" target="_blank">
        <div class="cover">
            <img class="lazy" src="https://ki.dadi260522.top/upload/vod/20261104-1/a0ece232fa58b9a20c3e3e02bb76ac93.jpg" data-src="https://ki.dadi260522.top/upload/vod/20261104-1/a0ece232fa58b9a20c3e3e02bb76ac93.jpg" alt="[无码] 极品模特被约炮狂干 艳舞勾魂内射爆浆"/>
            <div class="info"><span class="type"></span><span class="time"></span></div>
        </div>
        <p>[无码] 极品模特被约炮狂干 艳舞勾魂内射爆浆</p>
    </a>
</div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "1304965");
        assert_eq!(
            items[0]["title"],
            "[无码] 极品模特被约炮狂干 艳舞勾魂内射爆浆"
        );
        assert_eq!(
            items[0]["cover"],
            "https://ki.dadi260522.top/upload/vod/20261104-1/a0ece232fa58b9a20c3e3e02bb76ac93.jpg"
        );
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"url":"https:\/\/2609.dadi2026.com\/20261103\/IcTRginx\/index.m3u8","url_next":"","from":"m3u8"}"#;
        assert_eq!(
            parse_player_url(html),
            "https://2609.dadi2026.com/20261103/IcTRginx/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/upload/vod/20261104-1/a0ece232fa58b9a20c3e3e02bb76ac93.jpg"),
            "https://89-ew-e.yunmengv.shop/upload/vod/20261104-1/a0ece232fa58b9a20c3e3e02bb76ac93.jpg"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn detail_id_forms() {
        assert_eq!(detail_id("1304965"), "1304965");
        assert_eq!(detail_id("1304965.html"), "1304965");
        assert_eq!(detail_id("/voddetail/1304965.html"), "1304965");
    }
}
