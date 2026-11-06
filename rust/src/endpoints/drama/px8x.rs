//! Px8x：核心里的影视区站点。
//!
//! 品牌 Px8x.Com（免费在线成人福利网站）：入口域名 px8x.vip 只做
//! 跳转（/tz/index.html 再跳 8xx6.lol），实站是 https://8xx6.lol，
//! 本模块以实站为基址。站内标题全部用 document.write(d('base64'))
//! 混淆：d() 即 atob 后按 UTF-8 还原，可见字在 span 外、干扰字
//! 在 display:none 的 span 里，解码后去掉隐藏 span 再去标签即
//! 得原文。分类与站顶导航 1:1（8 项）；列表 20 条一页；详情页
//! 无封面无简介（详情 cover 与 synopsis 为空，以目录封面为准）；
//! 取流为详情页 hls.loadSource 的 play.php 地址，本身就是
//! m3u8（AES-128 清单，密钥 200/16B、首分片 200，已验）；搜索
//! 走 /search.php?content=，302 跳到 /list/<搜索号>-1.html。
//! 磁力种子是磁力链接、无可播视频，不进分类。

use base64::Engine as _;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://8xx6.lol";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态表：与站顶导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("901179", "国产"),
    ("911179", "有码"),
    ("921179", "无码"),
    ("931179", "欧美"),
    ("941179", "传媒"),
    ("951179", "探花"),
    ("961179", "中文"),
    ("971179", "动漫"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Px8x 请求 HTTP {status}")));
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
}

/// 站内 d() 解码：base64 解出 HTML，去掉 display:none 的干扰
/// span，再去标签、压空白。base64 缺填充时补齐。
fn decode_obfuscated(payload: &str) -> String {
    let mut padded = payload.trim().to_string();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let bytes = match base64::engine::general_purpose::STANDARD.decode(&padded) {
        Ok(b) => b,
        Err(_) => return String::new(),
    };
    let html = String::from_utf8_lossy(&bytes).into_owned();
    let hidden = match Regex::new(r"(?s)<span[^>]*display\s*:\s*none[^>]*>.*?</span>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let no_hidden = hidden.replace_all(&html, "");
    let tags = match Regex::new("<[^>]+>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let plain = tags.replace_all(&no_hidden, "");
    let ws = match Regex::new("\\s+") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    unescape(ws.replace_all(&plain, " ").trim())
}

/// 卡片解析：thumbnail 块里的 /video/<id>.html 链接，封面为
/// lozad 图，标题为其后的 d('...') 解码；标题含萝莉/幼女/
/// 未成年词的单片跳过。
fn parse_cards(html: &str) -> Vec<Value> {
    let link_re = match Regex::new(r#"href="/video/(\d+)\.html""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).ok();
    let payload_re = Regex::new(r#"d\('([^']+)'\)"#).ok();
    let mut seen = std::collections::HashSet::new();
    let mut items = Vec::new();
    for cap in link_re.captures_iter(html) {
        let vid = format!("/video/{}.html", &cap[1]);
        if !seen.insert(vid.clone()) {
            continue;
        }
        let start = match cap.get(0) {
            Some(m) => m.start(),
            None => continue,
        };
        let end = (start + 4000).min(html.len());
        let window = &html[start..end];
        let cover = match &img_re {
            Some(re) => re
                .captures(window)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let title = match &payload_re {
            Some(re) => re
                .captures(window)
                .map(|m| decode_obfuscated(&m[1]))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        if title.contains("萝莉") || title.contains("幼女") || title.contains("未成年") {
            continue;
        }
        items.push(item_json(&vid, &title, &cover, ""));
    }
    items
}

fn extract_play_url(html: &str) -> String {
    let re = match Regex::new(r#"hls\.loadSource\('([^']+)'\)"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => cap[1].to_string(),
        None => String::new(),
    }
}

fn detail_url(series_id: &str) -> String {
    let id = series_id.trim();
    if id.starts_with("http") {
        id.to_string()
    } else if let Some(rest) = id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else if id.chars().all(|c| c.is_ascii_digit()) {
        format!("{BASE}/video/{id}.html")
    } else {
        format!("{BASE}/{id}")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let url = format!("{BASE}/list/{category_id}-{page}.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = html.contains(&format!("/list/{category_id}-{}.html", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = detail_url(series_id);
    let html = get_text(&url).await?;
    let title = match Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>") {
        Ok(re) => match re.captures(&html) {
            Some(cap) => {
                let inner = &cap[1];
                match Regex::new(r#"d\('([^']+)'\)"#) {
                    Ok(pre) => match pre.captures(inner) {
                        Some(p) => decode_obfuscated(&p[1]),
                        None => String::new(),
                    },
                    Err(_) => String::new(),
                }
            }
            None => String::new(),
        },
        Err(_) => String::new(),
    };
    let play_url = extract_play_url(&html);
    if title.is_empty() || play_url.is_empty() {
        return Err(ApiError::Internal("Px8x 未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": "",
        "synopsis": "",
        "extra": {},
        "episodes": [episode_json(&play_url, "播放", series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search.php"), &[("content", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        let html = get_text(&detail_url(video_id)).await?;
        let found = extract_play_url(&html);
        if found.is_empty() {
            return Err(ApiError::Internal("Px8x 未取到播放地址".into()));
        }
        found
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_obfuscated_strips_hidden_spans() {
        let raw = "国<span style=\"display: none;font-size: 11;\">干扰</span>产";
        let payload = base64::engine::general_purpose::STANDARD.encode(raw);
        assert_eq!(decode_obfuscated(&payload), "国产");
        assert_eq!(decode_obfuscated("!!!"), "");
    }

    #[test]
    fn parse_cards_decodes_titles_and_filters_loli() {
        let good = base64::engine::general_purpose::STANDARD.encode("麻豆传媒实战教学");
        let bad = base64::engine::general_purpose::STANDARD.encode("萝莉标题测试片");
        let html = format!(
            r#"<div class="thumbnail group"><div><a href="/video/111.html"><img class="lozad" src="https://img.example.com/1.jpg"></a></div><div><a href="/video/111.html"><script>document.write(d('{good}'));</script></a></div></div><div class="thumbnail group"><div><a href="/video/222.html"><img class="lozad" src="https://img.example.com/2.jpg"></a></div><div><a href="/video/222.html"><script>document.write(d('{bad}'));</script></a></div></div>"#
        );
        let items = parse_cards(&html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/video/111.html");
        assert_eq!(items[0]["title"], "麻豆传媒实战教学");
        assert_eq!(items[0]["cover"], "https://img.example.com/1.jpg");
    }

    #[test]
    fn categories_has_8() {
        let value = json!({
            "categories": CATS
                .iter()
                .map(|(id, name)| category_json(id, name))
                .collect::<Vec<Value>>(),
        });
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 8);
        assert_eq!(list[0]["id"], "901179");
        assert_eq!(list[0]["name"], "国产");
        assert_eq!(list[7]["id"], "971179");
    }

    #[test]
    fn extract_play_url_reads_hls_source() {
        let html = "hls.loadSource('https://m.892539.xyz/play.php?site_id=13&source_id=104676');";
        assert_eq!(
            extract_play_url(html),
            "https://m.892539.xyz/play.php?site_id=13&source_id=104676"
        );
        assert_eq!(extract_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn detail_url_forms() {
        assert_eq!(
            detail_url("1105557201"),
            "https://8xx6.lol/video/1105557201.html"
        );
        assert_eq!(
            detail_url("/video/1105557201.html"),
            "https://8xx6.lol/video/1105557201.html"
        );
    }
}
