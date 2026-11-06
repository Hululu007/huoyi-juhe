//! 小黄鸭（MacCMS 站，帝皇影视）。
//!
//! 与 jar 的 ZakaXhyAmns 一一对应：分类（24 个，id 44-67）、
//! 目录（/index.php/vod/type/id/{id}/page/{页}.html）、详情
//! （播放页 player_aaaa JSON 的 vod_data 取名/海报/分类/演员/导演，
//! 为空则取详情页 content-info 与 detail-pic；单集“正片”）、
//! 搜索（/index.php/vod/search/wd/{词}/page/1.html）、取流
//! （播放页 player_aaaa 的 url 直给 m3u8，parse=0）。
//! 注意：列表页与播放页均是 document.write(decodeURIComponent(
//! atob("..."))) 包壳，须先解包再解析；第 1 页为空时按 jar 原文
//! 换镜像 xhy.one 重试（该镜像当前回 404，主站正常）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://www.xhy11.cc";
const MIRROR: &str = "https://xhy.one";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("44", "全部视频"),
    ("45", "自拍偷拍"),
    ("46", "伦理禁忌"),
    ("47", "网爆黑料"),
    ("48", "绿帽淫妻"),
    ("49", "制服诱惑"),
    ("50", "国产制作"),
    ("51", "国产直播"),
    ("52", "韩国直播"),
    ("53", "会所技师"),
    ("54", "淫乱学生"),
    ("55", "主播网红"),
    ("56", "国产推荐"),
    ("57", "探花大神"),
    ("58", "中文字幕"),
    ("59", "高清无码"),
    ("60", "高清有码"),
    ("61", "日本素人"),
    ("62", "无码流出"),
    ("63", "FC2"),
    ("64", "东京热"),
    ("65", "一本道"),
    ("66", "欧美精品"),
    ("67", "重口猎奇"),
];

/// 与 Java 的 headers 一致（Referer 用当前站址）。
fn headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
        ("Referer".to_string(), format!("{HOST}/")),
    ]
}

async fn fetch_raw(url: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("小黄鸭请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 与 Java 的 deobf 一致：取 atob("...")，base64 解码后再 URL 解码。
fn deobf(raw: &str) -> String {
    use base64::Engine;
    let re = Regex::new("atob\\(\\s*\"([^\"]+)\"\\s*\\)").unwrap();
    let Some(cap) = re.captures(raw) else {
        return raw.to_string();
    };
    let b64 = cap.get(1).map(|m| m.as_str()).unwrap_or("");
    if b64.is_empty() {
        return raw.to_string();
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .unwrap_or_default();
    if decoded.is_empty() {
        return raw.to_string();
    }
    let unescaped = percent_encoding::percent_decode_str(&decoded)
        .decode_utf8_lossy()
        .to_string();
    if unescaped.is_empty() {
        decoded
    } else {
        unescaped
    }
}

async fn fetch_page(url: &str) -> ApiResult<String> {
    Ok(deobf(&fetch_raw(url).await?))
}

/// 与 Java 的 ZakaHttp.clean 一致：去标签、解实体、去空白。
fn clean(raw: &str) -> String {
    let re = Regex::new("<[^>]+>").unwrap();
    re.replace_all(raw, "")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

/// 与 Java 的 u/abs 一致：// 补 https:，/ 开头补站址。
fn abs_url(raw: &str) -> String {
    let s = raw.trim().to_string();
    if let Some(rest) = s.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = s.strip_prefix('/') {
        format!("{HOST}{rest}")
    } else {
        s
    }
}

fn first(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

/// 与 Java 的 parseList 一致。
fn parse_list(html: &str) -> Vec<Value> {
    let re_item = Regex::new(
        "<li>\\s*<a\\s+href=\"(/index\\.php/vod/detail/id/(\\d+)\\.html)\"[^>]*>(.*?)</a>\\s*</li>",
    )
    .unwrap();
    let re_txt = Regex::new("<p class=\"txt-ov\">(.*?)</p>").unwrap();
    let re_h2 = Regex::new("<h2[^>]*>(.*?)</h2>").unwrap();
    let re_orig = Regex::new("data-original=\"([^\"]+)\"").unwrap();
    let re_img = Regex::new("<img[^>]*?src=\"([^\"]+)\"").unwrap();
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for cap in re_item.captures_iter(html) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let vid = cap.get(2).map(|m| m.as_str()).unwrap_or("");
        let body = cap.get(3).map(|m| m.as_str()).unwrap_or("");
        if vid.is_empty() || seen.contains(&vid.to_string()) {
            continue;
        }
        let mut title = clean(&first(&re_txt, body));
        if title.is_empty() {
            title = clean(&first(&re_h2, body));
        }
        if title.is_empty() {
            continue;
        }
        let mut pic = first(&re_orig, body);
        if pic.is_empty() {
            pic = first(&re_img, body);
        }
        let pic = if pic.is_empty() {
            String::new()
        } else {
            abs_url(&pic)
        };
        seen.push(vid.to_string());
        items.push(item_json(
            &format!("{HOST}{href}"),
            &title,
            &pic,
            &format!("影片 {vid}"),
        ));
    }
    items
}

/// 与 Java 的 pageCount 一致：取“尾页”链接里的总页数。
fn page_count(html: &str) -> i64 {
    let re = Regex::new("/page/(\\d+)\\.html\"[^>]*>\\s*尾页").unwrap();
    first(&re, html).parse::<i64>().unwrap_or(1).max(1)
}

/// 与 Java 的 swapHost 一致：把站址原点换成镜像原点。
fn swap_host(url: &str) -> Option<String> {
    if url.len() < 6 || !url.starts_with(HOST) {
        return None;
    }
    Some(format!("{MIRROR}{}", &url[HOST.len()..]))
}

/// 与 Java 的 listPage 一致：取页解析；第 1 页为空换镜像重试。
async fn list_page(url: &str, page: i64) -> ApiResult<Value> {
    let html = fetch_page(url).await?;
    let mut items = parse_list(&html);
    if items.is_empty() && page == 1 {
        if let Some(mirror_url) = swap_host(url) {
            if let Ok(mirror_html) = fetch_page(&mirror_url).await {
                let mirror_items = parse_list(&mirror_html);
                if !mirror_items.is_empty() {
                    items = mirror_items;
                }
            }
        }
    }
    if items.is_empty() && page > 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let total = page_count(&html);
    let has_more = page < total;
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 与 Java 的 playerAaaa 一致：取 player_aaaa = {...} 的 JSON。
fn player_aaaa(html: &str) -> Option<Value> {
    let re = Regex::new("player_aaaa\\s*=\\s*(\\{)").unwrap();
    let cap = re.captures(html)?;
    // 括号扫描要从 { 开始，不是变量名 player_aaaa 的开头。
    let start = cap.get(1)?.start();
    let bytes = html.as_bytes();
    let mut depth = 0_i64;
    let mut i = start;
    while i < bytes.len() {
        match bytes[i] {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    let raw = &html[start..=i];
                    return serde_json::from_str::<Value>(raw).ok();
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

fn play_page_url(vid: &str, sid: &str, nid: &str) -> String {
    format!("{HOST}/index.php/vod/play/id/{vid}/sid/{sid}/nid/{nid}.html")
}

/// 与 Java 的 fetchPlay 一致：取播放页，解包后取 player_aaaa。
async fn fetch_play(vid: &str, sid: &str, nid: &str) -> ApiResult<Value> {
    let html = fetch_page(&play_page_url(vid, sid, nid)).await?;
    player_aaaa(&html).ok_or_else(|| ApiError::Internal("小黄鸭未取到 player_aaaa".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let tid = if category_id.trim().is_empty() {
        "44"
    } else {
        category_id.trim()
    };
    let url = format!("{HOST}/index.php/vod/type/id/{tid}/page/{page}.html");
    list_page(&url, page).await
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let re_digits = Regex::new("(\\d+)").unwrap();
    let vid = first(&re_digits, series_id);
    if vid.is_empty() {
        return Err(ApiError::Internal("小黄鸭影片 id 为空".into()));
    }
    // 先走播放页的 vod_data（jar 的 detailContent 首选）。
    let mut title = String::new();
    let mut cover = String::new();
    let mut vod_class = String::new();
    let mut actor = String::new();
    let mut director = String::new();
    let mut sid = "1".to_string();
    let mut nid = "1".to_string();
    if let Ok(play) = fetch_play(&vid, "1", "1").await {
        if let Some(data) = play.get("vod_data") {
            title = data
                .get("vod_name")
                .and_then(|v| v.as_str())
                .map(clean)
                .unwrap_or_default();
            cover = data
                .get("poster")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            vod_class = data
                .get("vod_class")
                .and_then(|v| v.as_str())
                .map(clean)
                .unwrap_or_default();
            actor = data
                .get("vod_actor")
                .and_then(|v| v.as_str())
                .map(clean)
                .unwrap_or_default();
            director = data
                .get("vod_director")
                .and_then(|v| v.as_str())
                .map(clean)
                .unwrap_or_default();
            sid = data
                .get("sid")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "1".to_string());
            nid = data
                .get("nid")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "1".to_string());
        }
    }
    // vod_data 为空时取详情页（jar 的回退）。
    if title.is_empty() {
        let url = format!("{HOST}/index.php/vod/detail/id/{vid}.html");
        if let Ok(html) = fetch_page(&url).await {
            let re_info = Regex::new("class=\"content-info[^\"]*\"[^>]*>(.*?)</div>").unwrap();
            let info = first(&re_info, &html);
            let re_h2 = Regex::new("<h2[^>]*>(.*?)</h2>").unwrap();
            title = clean(&first(&re_h2, &info));
            if title.is_empty() {
                title = clean(&first(&re_h2, &html));
            }
            let re_pic =
                Regex::new("class=\"detail-pic[^\"]*\"[^>]*>\\s*<img[^>]*?src=\"([^\"]+)\"")
                    .unwrap();
            let pic = first(&re_pic, &html);
            if !pic.is_empty() {
                cover = abs_url(&pic);
            }
        }
    }
    if title.is_empty() {
        title = format!("影片 {vid}");
    }
    if !cover.is_empty() {
        cover = abs_url(&cover);
    }
    let flag = play_page_url(&vid, &sid, &nid);
    let mut synopsis = String::new();
    if !vod_class.is_empty() {
        synopsis.push_str(&format!("\n分类：{vod_class}"));
    }
    if !actor.is_empty() {
        synopsis.push_str(&format!("\n演员：{actor}"));
    }
    if !director.is_empty() {
        synopsis.push_str(&format!("\n导演：{director}"));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim().to_string(),
        "extra": {"vod_type": vod_class},
        "episodes": [episode_json(&flag, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let re = Regex::new("/vod/play/id/(\\d+)/sid/(\\d+)/nid/(\\d+)").unwrap();
    let Some(cap) = re.captures(video_id) else {
        return Err(ApiError::Internal("小黄鸭播放标识无法解析".into()));
    };
    let vid = cap.get(1).map(|m| m.as_str()).unwrap_or("");
    let sid = cap.get(2).map(|m| m.as_str()).unwrap_or("1");
    let nid = cap.get(3).map(|m| m.as_str()).unwrap_or("1");
    let html = fetch_page(&play_page_url(vid, sid, nid)).await?;
    let mut url = player_aaaa(&html)
        .and_then(|j| j.get("url").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .unwrap_or_default();
    url = url.replace("\\/", "/");
    if url.starts_with("http") {
        return Ok(json!({"url": url}));
    }
    // url 非直链时扫页内 m3u8（jar 的 playerContent 回退）。
    let re_m3u8 = Regex::new("https?://[^\"'\\s<>\\\\]+\\.m3u8[^\"'\\s<>\\\\]*").unwrap();
    let found = re_m3u8
        .find(&html)
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    if found.starts_with("http") {
        Ok(json!({"url": found}))
    } else {
        Err(ApiError::Internal("小黄鸭未取到播放地址".into()))
    }
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    let url = format!("{HOST}/index.php/vod/search/wd/{enc}/page/1.html");
    list_page(&url, 1).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deobf_unpacks_atob() {
        use base64::Engine;
        let inner = "<li><a href=\"/x\">t</a></li>";
        let packed = format!(
            "document.write(decodeURIComponent(atob(\"{}\")))",
            base64::engine::general_purpose::STANDARD.encode(
                percent_encoding::utf8_percent_encode(inner, percent_encoding::NON_ALPHANUMERIC)
                    .to_string()
            )
        );
        assert!(deobf(&packed).contains("<li>"));
        assert_eq!(deobf("plain html"), "plain html");
    }

    #[test]
    fn player_aaaa_brace_match() {
        let html = "var player_aaaa={\"url\":\"https://x/y.m3u8\",\"from\":\"x\"};";
        let j = player_aaaa(html).unwrap();
        assert_eq!(
            j.get("url").and_then(|v| v.as_str()),
            Some("https://x/y.m3u8")
        );
    }

    #[test]
    fn parse_list_reads_items() {
        let html = "<li><a href=\"/index.php/vod/detail/id/123.html\"><p class=\"txt-ov\">T</p><img data-original=\"//cdn/p.jpg\"></a></li>";
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
    }
}
