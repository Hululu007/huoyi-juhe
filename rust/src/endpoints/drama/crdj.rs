//! 91 成人短剧（91crdjai.com）：核心里的影视区站点。
//!
//! 来源 py：~/workspace/your_files/91crdjai.py（py-25 批已批 25 个之一，
//! App 内置种子，播放链已验通）。只做免费部分，不写绕 VIP 的代码；
//! VIP 墙如实报。写源照站原样写，不按站名/分类名/标题删任何内容
//! （用户 22:40 铁律）。
//! - 分类 4 个固定频道：duanju 成人短剧、manju 成人漫剧、
//!   zhenrenju 真人剧、shipin 成人视频。
//! - 列表：/{频道}/（第 1 页），/{频道}/page/{n}/（翻页）；卡片为
//!   /{频道}/{数字}-{slug}/ 锚点，标题取 img 的 alt、封面取 data-src。
//! - 详情：卡片链接本身就是详情页；标题取 img.p-img 的 alt（无则
//!   <title> 去 " - " 后缀），简介取 meta description（去站内固定
//!   引导句），备注取 <dt>状态</dt>/<dt>集数</dt> 的 <dd>；选集为
//!   详情页内 {详情路径}{数字}/ 的数字锚点，按集号升序。
//! - 搜索：/search/{词}/，只第 1 页。
//! - 取流：选集页 HTML 里找 .m3u8，优先含 hls 或 videos 的那条，
//!   否则取第一条；parse=0 直链 + UA 头，不靠壳解析兜底。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://91crdjai.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 4 个固定频道，与 py 的 CHANNELS 一致。
const CHANNELS: &[(&str, &str)] = &[
    ("duanju", "成人短剧"),
    ("manju", "成人漫剧"),
    ("zhenrenju", "真人剧"),
    ("shipin", "成人视频"),
];

/// 站内固定引导句：简介里出现时去掉（py 同款处理）。
const DESC_BOILERPLATE: &str = "本页提供剧情简介、作品资料、标签与完整选集，点击选集进入播放页。";

fn is_channel(tid: &str) -> bool {
    CHANNELS.iter().any(|(id, _)| *id == tid)
}

fn clean(text: &str) -> String {
    let no_tags = Regex::new(r"<[^>]+>")
        .map(|re| re.replace_all(text, " ").into_owned())
        .unwrap_or_else(|_| text.to_string());
    let unescaped = no_tags
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ");
    let squashed = Regex::new(r"\s+")
        .map(|re| re.replace_all(&unescaped, " ").into_owned())
        .unwrap_or(unescaped);
    squashed.trim().to_string()
}

/// 还原 JSON 转义与 // 开头、/ 开头的相对地址（py 的 _fix_url + _abs）。
fn fix_url(raw: &str) -> String {
    let u = raw
        .replace("\\u0026", "&")
        .replace("\\u002F", "/")
        .replace("&amp;", "&");
    let u = u.trim();
    if u.starts_with("//") {
        format!("https:{u}")
    } else if let Some(rest) = u.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        u.to_string()
    }
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("91成人短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 卡片解析：/{频道}/{数字}-{slug}/ 锚点，标题取 img 的 alt，
/// 封面取 data-src（py 的 _cards 同款）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a[^>]*href="(/(?:duanju|manju|zhenrenju|shipin)/\d+-[^"/]+/)"[^>]*>(.*?)</a>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let alt_re = Regex::new(r#"alt="([^"]+)""#).ok();
    let pic_re = Regex::new(r#" data-src="([^"]+)""#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let path = cap[1].to_string();
        if !seen.insert(path.clone()) {
            continue;
        }
        let body = &cap[2];
        let name = match &alt_re {
            Some(re) => re.captures(body).map(|m| clean(&m[1])).unwrap_or_default(),
            None => String::new(),
        };
        if name.is_empty() {
            continue;
        }
        let pic = match &pic_re {
            Some(re) => re
                .captures(body)
                .map(|m| fix_url(&m[1]))
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&path, &name, &pic, ""));
    }
    items
}

/// 详情解析（纯函数，便于单测）：标题/封面/简介/备注/选集。
fn parse_detail(html: &str, path: &str) -> Option<Value> {
    let img_re = Regex::new(r#"(?s)<img[^>]*class="p-img"[^>]*>"#).ok();
    let alt_re = Regex::new(r#"alt="([^"]+)""#).ok();
    let pic_re = Regex::new(r#" data-src="([^"]+)""#).ok();
    let mut name = String::new();
    let mut pic = String::new();
    if let Some(re) = &img_re {
        if let Some(cap) = re.captures(html) {
            let tag = &cap[0];
            if let Some(are) = &alt_re {
                name = are.captures(tag).map(|m| clean(&m[1])).unwrap_or_default();
            }
            if let Some(pre) = &pic_re {
                pic = pre
                    .captures(tag)
                    .map(|m| fix_url(&m[1]))
                    .unwrap_or_default();
            }
        }
    }
    if name.is_empty() {
        let title_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        if let Some(re) = title_re {
            name = re
                .captures(html)
                .map(|m| {
                    let t = clean(&m[1]);
                    t.split(" - ").next().unwrap_or("").trim().to_string()
                })
                .unwrap_or_default();
        }
    }
    if name.is_empty() {
        return None;
    }
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let mut content = match &desc_re {
        Some(re) => re.captures(html).map(|m| clean(&m[1])).unwrap_or_default(),
        None => String::new(),
    };
    content = content.replace(DESC_BOILERPLATE, "").trim().to_string();
    let status_re = Regex::new(r#"(?s)<dt>状态</dt>\s*<dd>(.*?)</dd>"#).ok();
    let count_re = Regex::new(r#"(?s)<dt>集数</dt>\s*<dd>(.*?)</dd>"#).ok();
    let mut bits: Vec<String> = Vec::new();
    if let Some(re) = &status_re {
        if let Some(cap) = re.captures(html) {
            let s = clean(&cap[1]);
            if !s.is_empty() {
                bits.push(s);
            }
        }
    }
    if let Some(re) = &count_re {
        if let Some(cap) = re.captures(html) {
            let s = clean(&cap[1]);
            if !s.is_empty() {
                bits.push(s);
            }
        }
    }
    let remarks = bits.join(" ");
    let base_path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let base_path = if base_path.ends_with('/') {
        base_path
    } else {
        format!("{base_path}/")
    };
    let ep_re = match Regex::new(&format!(
        r#"(?s)<a[^>]*href="({}\d+/)"[^>]*>(.*?)</a>"#,
        regex::escape(&base_path)
    )) {
        Ok(re) => re,
        Err(_) => return None,
    };
    let mut eps: Vec<(u32, String)> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in ep_re.captures_iter(html) {
        let ep_url = cap[1].to_string();
        let txt = clean(&cap[2]);
        let Ok(num) = txt.parse::<u32>() else {
            continue;
        };
        if !seen.insert(ep_url.clone()) {
            continue;
        }
        eps.push((num, ep_url));
    }
    eps.sort_by_key(|(n, _)| *n);
    let episodes: Vec<Value> = eps
        .iter()
        .map(|(n, url)| episode_json(url, &format!("第{n}集"), path))
        .collect();
    Some(json!({
        "id": path,
        "title": name,
        "cover": pic,
        "synopsis": content,
        "remark": remarks,
        "extra": {},
        "episodes": episodes,
    }))
}

/// 取流解析：HTML 里找 .m3u8，优先含 hls 或 videos 的那条，
/// 否则取第一条（py 的 playerContent 同款）。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"https?://[^\s"'<>]*\.m3u8[^\s"'<>]*"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let mut first = String::new();
    for cap in re.captures_iter(html) {
        let cand = fix_url(&cap[0]);
        if first.is_empty() {
            first = cand.clone();
        }
        if cand.contains("hls") || cand.contains("videos") {
            return cand;
        }
    }
    first
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CHANNELS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = if is_channel(category_id) {
        category_id
    } else {
        "duanju"
    };
    let page = if page < 1 { 1 } else { page };
    let url = if page <= 1 {
        format!("{BASE}/{tid}/")
    } else {
        format!("{BASE}/{tid}/page/{page}/")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/{tid}/page/{}/", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = series_id.trim();
    let url = if path.starts_with("http") {
        path.to_string()
    } else if let Some(rest) = path.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{path}")
    };
    let html = get_text(&url).await?;
    parse_detail(&html, path).ok_or_else(|| ApiError::Internal("91成人短剧详情未返回标题".into()))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let url = if let Some(rest) = vid.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{vid}")
    };
    let html = get_text(&url).await?;
    let stream = parse_play_url(&html);
    if stream.is_empty() {
        return Err(ApiError::Internal("91成人短剧未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let html = get_text(&format!("{BASE}/search/{enc}/")).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_four_channels() {
        assert_eq!(CHANNELS.len(), 4);
        assert_eq!(CHANNELS[0], ("duanju", "成人短剧"));
        assert_eq!(CHANNELS[1], ("manju", "成人漫剧"));
        assert_eq!(CHANNELS[2], ("zhenrenju", "真人剧"));
        assert_eq!(CHANNELS[3], ("shipin", "成人视频"));
        assert!(is_channel("duanju"));
        assert!(!is_channel("bogus"));
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="item"><a href="/duanju/12345-test-title/" title="xx"><img data-src="https://cdn.example.com/pic.jpg" alt="测试短剧第一集"></a></div><div class="item"><a href="/manju/67890-abc/" title="yy"><img data-src="//cdn.example.com/p2.jpg" alt="漫剧第二部"></a></div><div class="item"><a href="/duanju/12345-test-title/" title="xx"><img data-src="https://cdn.example.com/pic.jpg" alt="测试短剧第一集"></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "/duanju/12345-test-title/");
        assert_eq!(items[0]["title"], "测试短剧第一集");
        assert_eq!(items[0]["cover"], "https://cdn.example.com/pic.jpg");
        assert_eq!(items[1]["id"], "/manju/67890-abc/");
        assert_eq!(items[1]["cover"], "https://cdn.example.com/p2.jpg");
    }

    #[test]
    fn parse_detail_real_markup() {
        let html = r#"<html><head><title>测试短剧 - 91成人短剧</title><meta name="description" content="这是一部测试短剧的简介。本页提供剧情简介、作品资料、标签与完整选集，点击选集进入播放页。"></head><body><img class="p-img" data-src="https://cdn.example.com/cover.jpg" alt="测试短剧"><dl><dt>状态</dt><dd>已完结</dd><dt>集数</dt><dd>共12集</dd></dl><a href="/duanju/12345-test-title/3/">3</a><a href="/duanju/12345-test-title/1/">1</a><a href="/duanju/12345-test-title/2/">2</a><a href="/duanju/12345-test-title/10/">10</a></body></html>"#;
        let v = parse_detail(html, "/duanju/12345-test-title/").expect("detail parsed");
        assert_eq!(v["title"], "测试短剧");
        assert_eq!(v["cover"], "https://cdn.example.com/cover.jpg");
        assert_eq!(v["synopsis"], "这是一部测试短剧的简介。");
        assert_eq!(v["remark"], "已完结 共12集");
        let eps = v["episodes"].as_array().unwrap();
        assert_eq!(eps.len(), 4);
        assert_eq!(eps[0]["title"], "第1集");
        assert_eq!(eps[0]["video_id"], "/duanju/12345-test-title/1/");
        assert_eq!(eps[3]["title"], "第10集");
    }

    #[test]
    fn parse_play_url_prefers_hls() {
        let html = r#"var a = "https://cdn.example.com/other/index.m3u8"; var b = "https://hls.example.com/videos/abc/index.m3u8";"#;
        assert_eq!(
            parse_play_url(html),
            "https://hls.example.com/videos/abc/index.m3u8"
        );
        let html2 = r#"src="https://cdn.example.com/only.m3u8?token=1""#;
        assert_eq!(
            parse_play_url(html2),
            "https://cdn.example.com/only.m3u8?token=1"
        );
        assert_eq!(parse_play_url("<div>no stream</div>"), "");
    }

    #[test]
    fn catalog_and_search_url_shapes() {
        assert_eq!(
            format!("{BASE}/{}/", "duanju"),
            "https://91crdjai.com/duanju/"
        );
        assert_eq!(
            format!("{BASE}/{}/page/{}/", "manju", 2),
            "https://91crdjai.com/manju/page/2/"
        );
        let enc: String = url::form_urlencoded::byte_serialize("美女".as_bytes())
            .collect::<String>()
            .replace('+', "%20");
        assert_eq!(
            format!("{BASE}/search/{enc}/"),
            "https://91crdjai.com/search/%E7%BE%8E%E5%A5%B3/"
        );
    }

    #[test]
    fn fix_url_handles_escapes() {
        assert_eq!(
            fix_url("https:\\u002F\\u002Fcdn.example.com\\u002Fa.m3u8?x=1\\u0026y=2"),
            "https://cdn.example.com/a.m3u8?x=1&y=2"
        );
        assert_eq!(
            fix_url("//cdn.example.com/p.jpg"),
            "https://cdn.example.com/p.jpg"
        );
        assert_eq!(
            fix_url("/duanju/1-abc/"),
            "https://91crdjai.com/duanju/1-abc/"
        );
    }
}
