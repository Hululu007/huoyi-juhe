//! 肉视频（rou.video）：Next.js + TanStack Router 站，卡片为服务端直出 HTML。
//! 取流：详情页 SSR 数据含 `ev:$R[N]={d:"...",k:N}`，解码 = base64
//! 解码后每字节减 k，再 JSON 解析，得 `{"videoUrl":"/api/hls/<id>"}`；
//! `GET /api/hls/<id>` 302 到 CDN 的 `index.png?v=...&auth=...`。
//! 实测 cmw40jx7z0004s6bfnwwx08k1：清单解包后 27 分片、196.2 秒，
//! 与卡片时长 196.209 秒精确对上（全长）；首分片 C-000.png 200，
//! 解包后 1114840 字节，首字节 0x47 TS 魔数。
//! 注意：`index.png` 是 PNG 包装的清单（PNG 内自定义 `roUd` 块，
//! 内容为 `0x01 + zlib(m3u8)`；分片 `C-XXX.png` 同样是 PNG 包装
//! 的 TS，roUd 块 flag 0 = 原始 TS、flag 1 = deflate 压缩）；
//! 站内 JS 用 shaka response filter 自动解包，App 的 ExoPlayer
//! 无法直接播 PNG 包装的流，须播放器侧加解包支持，手机端须复验。
//! `GET /api/v/<id>` 回 `{}`，不要用它，取流走详情页 ev。
//! 分类与站导航 1:1（主分類 6 個 + 视频库）；列表
//! `/t/<slug>?order=createdAt&page=N`，每页 26 条；
//! 搜索 `/search?q=...`。

use base64::Engine;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://rou.video";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航主分類 6 個 + 视频库。
/// 注意：國產AV 用繁体“國產” U+7522 的 slug，须照 /cat 页 href 原样。
const CATS: &[(&str, &str)] = &[
    ("%E8%87%AA%E6%8B%8D%E6%B5%81%E5%87%BA", "自拍流出"),
    ("%E5%9C%8B%E7%94%A2AV", "國產AV"),
    ("%E6%8E%A2%E8%8A%B1", "探花"),
    ("%E6%97%A5%E6%9C%AC", "日本"),
    ("%E9%BA%BB%E8%B1%86%E5%82%B3%E5%AA%92", "麻豆傳媒"),
    ("OnlyFans", "OnlyFans"),
    ("vlib", "视频库"),
];

fn ev_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"ev:\$R\[\d+\]=\{d:"([^"]+)",k:(\d+)\}"#).unwrap())
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
        return Err(ApiError::Internal(format!("肉视频 请求 HTTP {status}")));
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

/// `<a href="/v/<id>" class="group block min-w-0">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a href=\"/v/").skip(1) {
        let end = block.find("<a href=\"/v/").unwrap_or(block.len());
        let block = &block[..end];
        let Some(q) = block.find('"') else {
            continue;
        };
        let vid = &block[..q];
        if vid.is_empty() || vid.contains('/') || vid.contains('?') {
            continue;
        }
        let id = format!("{HOST}/v/{vid}");
        if seen.contains(&id) {
            continue;
        }
        // 标题：卡片 <h3>，无则取 img alt。
        let mut title = String::new();
        if let Some(p) = block.find("<h3") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</h3>") {
                    title = decode_entities(after[s..s + e].trim());
                }
            }
        }
        // 封面：第二张 img（第一张是 blur 占位），alt 非空的那张。
        let mut cover = String::new();
        for img in block.split("<img ").skip(1) {
            let alt = img.find("alt=\"").map(|a| {
                let s = a + 5;
                img[s..].find('"').map(|e| &img[s..s + e]).unwrap_or("")
            });
            if let Some(a) = alt {
                if !a.is_empty() {
                    title = decode_entities(a);
                }
            }
            if let Some(s) = img.find("src=\"") {
                let s = s + 5;
                if let Some(e) = img[s..].find('"') {
                    cover = img[s..s + e].to_string();
                }
            }
            if !cover.is_empty() {
                break;
            }
        }
        if title.is_empty() {
            continue;
        }
        // 时长徽章：如“41分6秒”。
        let mut remark = String::new();
        if let Some(p) = block.find("ml-auto shrink-0") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</span>") {
                    remark = after[s..s + e].trim().to_string();
                }
            }
        }
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if category_id == "vlib" {
        if page <= 1 {
            format!("{HOST}/v")
        } else {
            format!("{HOST}/v?page={page}")
        }
    } else {
        format!("{HOST}/t/{category_id}?order=createdAt&page={page}")
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
    for sep in [" - 肉視頻,您的私人AV影院", " - 肉视频"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

/// JSON-LD `duration":"PT2890S"` 转“48分10秒”。
fn json_ld_duration(html: &str) -> String {
    let Some(p) = html.find("\"duration\":\"PT") else {
        return String::new();
    };
    let s = p + 14;
    let Some(e) = html[s..].find('"') else {
        return String::new();
    };
    let raw = &html[s..s + e];
    let secs: f64 = raw.trim_end_matches('S').parse().unwrap_or(0.0);
    if secs <= 0.0 {
        return String::new();
    }
    let total = secs as i64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let sec = total % 60;
    if h > 0 {
        format!("{h}小时{m}分{sec}秒")
    } else {
        format!("{m}分{sec}秒")
    }
}

/// ev 解码：base64 解码后每字节减 k，再 JSON 解析。
fn decode_ev(html: &str) -> Option<String> {
    let cap = ev_re().captures(html)?;
    let k: u8 = cap[2].parse().ok()?;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(cap[1].as_bytes())
        .ok()?;
    let dec: Vec<u8> = raw.iter().map(|b| b.wrapping_sub(k)).collect();
    let v: Value = serde_json::from_slice(&dec).ok()?;
    v.get("videoUrl")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
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
    let html = fetch(&url, &format!("{HOST}/home")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/home")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("肉视频 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let dur = json_ld_duration(&html);
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
    if video_id.starts_with("http") && video_id.contains("/api/hls/") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/home")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/home")).await?;
    let path = decode_ev(&html)
        .ok_or_else(|| ApiError::Internal("肉视频 详情页未找到 ev 取流数据".into()))?;
    let url = if path.starts_with("http") {
        path
    } else {
        format!("{HOST}{path}")
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/home")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 ev 样本：k=37，解出 {"videoUrl":"/api/hls/test123"}。
    const EV_HTML: &str = r#"ev:$R[92]={d:"oEebjomKlHqXkUdfR1SGlY5UjZGYVJmKmJlWV1hHog==",k:37}"#;

    #[test]
    fn decode_ev_known() {
        assert_eq!(decode_ev(EV_HTML).unwrap(), "/api/hls/test123");
        assert!(decode_ev("no ev here").is_none());
    }

    #[test]
    fn parse_video_card() {
        let html = r#"<a href="/v/cmw2eacxs0000s6axs1w2xdeu" class="group block min-w-0"><div class="relative aspect-16/10 overflow-hidden rounded-[10px]"><img src="https://v.rn252.xyz/m/xxx/cover.jpg" alt="" class="absolute blur-sm"/><img src="https://v.rn252.xyz/m/xxx/cover.jpg" alt="綠荼秘書的騷穴怎麼操都覺得不夠 91情深叉喔" loading="lazy" class="relative"/><span class="absolute top-2.5 left-2.5">720<!-- -->P</span><div class="absolute left-2.5 right-2.5 bottom-[9px]"><span class="ml-auto shrink-0 bg-[#071015bd] text-white text-xs px-1.5 py-0.5 rounded">46分37秒</span></div></div><h3 class="mt-2.5 mb-1">綠荼秘書的騷穴怎麼操都覺得不夠 91情深叉喔</h3></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://rou.video/v/cmw2eacxs0000s6axs1w2xdeu"
        );
        assert_eq!(
            items[0]["title"],
            "綠荼秘書的騷穴怎麼操都覺得不夠 91情深叉喔"
        );
        assert_eq!(items[0]["remark"], "46分37秒");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("%E6%8E%A2%E8%8A%B1", 1),
            "https://rou.video/t/%E6%8E%A2%E8%8A%B1?order=createdAt&page=1"
        );
        assert_eq!(
            catalog_url("%E5%9C%8B%E7%94%A2AV", 2),
            "https://rou.video/t/%E5%9C%8B%E7%94%A2AV?order=createdAt&page=2"
        );
        assert_eq!(catalog_url("vlib", 1), "https://rou.video/v");
    }

    #[test]
    fn json_ld_duration_parse() {
        let html = r#"{"@context":"https://schema.org","duration":"PT2890S"}"#;
        assert_eq!(json_ld_duration(html), "48分10秒");
        assert_eq!(json_ld_duration("nothing"), "");
    }

    #[test]
    fn tag_title_strips_suffix() {
        let html = "<title>約啪巨乳妹 無套高潮抽搐女 2020-10-23 - 肉視頻,您的私人AV影院</title>";
        assert_eq!(tag_title(html), "約啪巨乳妹 無套高潮抽搐女 2020-10-23");
    }
}
