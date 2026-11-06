//! XX01：`https://xx01.com`。
//!
//! jar 内 ZakaXx01Amns 的移植。分类：38 个路径分类 + 37 个
//! /genres/ 标签分类（jar 的 homeContent 第二个循环）。列表走
//! `{路径}?page={页}&sort=&filters=`，有下一页以 `rel="next"` 判。
//! 详情取 og: meta；取流解包页面里的 Dean Edwards 打包 JS 再扫
//! m3u8（base36 字典，与 mmtv7/zggjav 同款算法，见 unpack）。
//! 注意：解出的流在 surrit.com 上，本机出口四种头组合均回 403
//!（Cloudflare 挑战页），首分片验不了，取流须手机侧复验；
//! 列表/详情/搜索本机已验通。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://xx01.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 38 个路径分类（路径，中文名；jar 的 CATS 原文，emoji 前缀在
/// dex 里已是 U+FFFD 无法恢复，取干净中文名）。
const CATS: &[(&str, &str)] = &[
    ("/new", "最近更新"),
    ("/uncensored-leak", "无码流出"),
    ("/chinese-subtitle", "中文字幕"),
    ("/VR", "VR专区"),
    ("/anime", "成人动漫"),
    ("/madou", "麻豆传媒"),
    ("/fc2", "FC2"),
    ("/heyzo", "HEYZO"),
    ("/tokyohot", "东京热"),
    ("/1pondo", "一本道"),
    ("/caribbeancom", "加勒比"),
    ("/caribbeancompr", "加勒比PR"),
    ("/10musume", "10musume"),
    ("/pacopacomama", "pacopacomama"),
    ("/gachinco", "Gachinco"),
    ("/xxxav", "XXX-AV"),
    ("/marriedslash", "人妻斩"),
    ("/naughty4610", "顽皮4610"),
    ("/naughty0930", "顽皮0930"),
    ("/siro", "SIRO"),
    ("/luxu", "LUXU"),
    ("/maan", "PRESTIGE"),
    ("/scute", "S-CUTE"),
    ("/ara", "ARA"),
    ("/kinostream", "kinostream"),
    ("/TIMESTUDIO", "时间工作室"),
    ("/tiktok", "抖阴视频"),
    ("/starface", "明星换脸"),
    ("/cnlive", "主播直播"),
    ("/cmedia", "国产传媒"),
    ("/playgirl", "玩偶姐姐"),
    ("/netdoor", "网曝黑门"),
    ("/klive", "韩国直播"),
    ("/clive", "中国直播"),
    ("/twav", "TWAV"),
    ("/furuke", "Furuke"),
    ("/avtalk", "AV解说"),
];

/// 37 个 /genres/ 标签（jar 的 GENRES 原文）。
const GENRES: &[&str] = &[
    "纪录片",
    "外国女优",
    "独家",
    "中出",
    "单体作品",
    "巨乳",
    "人妻",
    "熟女",
    "素人",
    "美少女",
    "口交",
    "薄格",
    "多人运动",
    "骑乘",
    "痴女",
    "4小时以上",
    "女高中生",
    "潮吹",
    "合集",
    "自拍",
    "乳交",
    "苗条",
    "恋物癖",
    "企划",
    "美乳",
    "乱伦",
    "搭讪",
    "NTR",
    "偷拍",
    "颜射",
    "淫乱",
    "自慰",
    "剧情",
    "手淫",
    "姐姐",
    "羞辱",
    "拘束",
];

/// 清晰度标签的排序（jar 的 mainList 顺序）。
const LABEL_ORDER: &[&str] = &[
    "高清主清单",
    "超清1080",
    "超清1280",
    "高清842",
    "标清720",
    "流畅480",
];

/// 带头取页（jar 的 ZakaHttp.get 同款头）。
async fn fetch_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("XX01 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("XX01 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!("XX01 请求失败：HTTP {status}")));
    }
    Ok(text)
}

fn unesc(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#x2F;", "/")
        .replace("&#x3D;", "=")
        .replace("&nbsp;", " ")
}

/// 相对地址补成绝对地址（jar 的 abs）。
fn abs_url(u: &str) -> String {
    let u = unesc(u.trim());
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u;
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https:{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{u}")
}

/// jar 的 hms：秒数写成 HH:MM:SS。
fn hms(secs: i64) -> String {
    let secs = secs.max(0);
    format!(
        "{:02}:{:02}:{:02}",
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

/// og: meta 取值（property/content 两种顺序都认）。
fn meta(html: &str, prop: &str) -> String {
    let re = Regex::new(&format!(
        r#"<meta[^>]*property="{prop}"[^>]*content="([^"]*)""#
    ))
    .unwrap();
    if let Some(cap) = re.captures(html) {
        return unesc(cap.get(1).unwrap().as_str());
    }
    let re2 = Regex::new(&format!(
        r#"<meta[^>]*content="([^"]*)"[^>]*property="{prop}""#
    ))
    .unwrap();
    re2.captures(html)
        .map(|c| unesc(c.get(1).unwrap().as_str()))
        .unwrap_or_default()
}

/// 列表解析：`class="item-wrapper"` 块；标题取 truncate 里的 a 文本，
/// 封面取 img data-src，时长取右下角，标签取左下角（空则“XX01”）。
fn parse_cards(html: &str, limit: usize) -> Vec<Value> {
    let block_re = Regex::new(r#"class="item-wrapper">[\s\S]{0,4000}?href="(/[^"?#]+)""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]*data-src="([^"]+)"[^>]*alt="([^"]*)""#).unwrap();
    let dur_re =
        Regex::new(r"bottom-1 right-1[^>]*>\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)").unwrap();
    let tag_re = Regex::new(r"bottom-1 left-1[^>]*>\s*([^<]{1,24})").unwrap();
    let title_re = Regex::new(r#"truncate">\s*<a[^>]*>\s*([^<]{1,200})"#).unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for cap in block_re.captures_iter(html) {
        let path = cap.get(1).unwrap().as_str();
        if !seen.insert(path.to_string()) {
            continue;
        }
        let whole = cap.get(0).unwrap();
        let seg_end = (whole.start() + 4000).min(html.len());
        let seg = &html[whole.start()..seg_end];
        let title = title_re
            .captures(seg)
            .map(|c| unesc(c.get(1).unwrap().as_str()).trim().to_string())
            .filter(|t| !t.is_empty())
            .or_else(|| {
                img_re
                    .captures(seg)
                    .map(|c| unesc(c.get(2).unwrap().as_str()).trim().to_string())
                    .filter(|t| !t.is_empty())
            })
            .unwrap_or_else(|| "XX01 影片".to_string());
        let pic = img_re
            .captures(seg)
            .map(|c| abs_url(c.get(1).unwrap().as_str()))
            .unwrap_or_default();
        let remark = dur_re
            .captures(seg)
            .map(|c| c.get(1).unwrap().as_str().to_string())
            .or_else(|| {
                tag_re
                    .captures(seg)
                    .map(|c| unesc(c.get(1).unwrap().as_str()).trim().to_string())
                    .filter(|t| !t.is_empty())
            })
            .unwrap_or_else(|| "XX01".to_string());
        out.push(item_json(&format!("{HOST}{path}"), &title, &pic, &remark));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// Dean Edwards 打包 JS 解包（jar 的 unpack 同款，base36 字典）。
fn unpack(html: &str) -> String {
    let re = Regex::new(r"\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)").unwrap();
    let Some(cap) = re.captures(html) else {
        return String::new();
    };
    let packed = cap.get(1).unwrap().as_str();
    let radix: u32 = cap.get(2).unwrap().as_str().parse().unwrap_or(36);
    let count: usize = cap.get(3).unwrap().as_str().parse().unwrap_or(0);
    let words: Vec<&str> = cap.get(4).unwrap().as_str().split('|').collect();
    let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let to_radix = |mut n: usize| -> String {
        if n == 0 {
            return "0".to_string();
        }
        let mut out = String::new();
        while n > 0 {
            out.insert(0, alphabet[(n % radix as usize)] as char);
            n /= radix as usize;
        }
        out
    };
    let mut dict = std::collections::HashMap::new();
    for i in 0..count {
        let key = to_radix(i);
        let val = words.get(i).copied().unwrap_or("");
        dict.insert(key, val.to_string());
    }
    let word_re = Regex::new(r"[A-Za-z0-9_]+").unwrap();
    let unpacked = word_re.replace_all(packed, |c: &regex::Captures| {
        dict.get(c.get(0).unwrap().as_str())
            .cloned()
            .unwrap_or_else(|| c.get(0).unwrap().as_str().to_string())
    });
    unpacked.replace("\\'", "'").replace("\\\"", "\"")
}

/// jar 的 label：按地址里的清晰度数字定标签。
fn label(url: &str) -> &'static str {
    if url.contains("1080") {
        "超清1080"
    } else if url.contains("1280") {
        "超清1280"
    } else if url.contains("842") {
        "高清842"
    } else if url.contains("720") {
        "标清720"
    } else if url.contains("480") {
        "流畅480"
    } else {
        "高清主清单"
    }
}

/// 详情页取流：先解包再扫 m3u8，跳预告/预告片，按标签顺序排。
fn streams(html: &str) -> Vec<(String, String)> {
    let text = unpack(html);
    let re = Regex::new(r#"https?://[^\s'"\\<>]{6,300}?\.m3u8"#).unwrap();
    let mut seen = HashSet::new();
    let mut found: Vec<(String, String)> = Vec::new();
    for cap in re.captures_iter(&text) {
        let url = cap.get(0).unwrap().as_str().replace("\\/", "/");
        if url.contains("preview") || url.contains("trailer") {
            continue;
        }
        if !seen.insert(url.clone()) {
            continue;
        }
        found.push((url.clone(), label(&url).to_string()));
    }
    let rank = |lab: &str| {
        LABEL_ORDER
            .iter()
            .position(|l| *l == lab)
            .unwrap_or(LABEL_ORDER.len())
    };
    found.sort_by_key(|(_, lab)| rank(lab));
    found
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = CATS
        .iter()
        .map(|(path, name)| category_json(path, name))
        .collect();
    for genre in GENRES {
        let enc = percent_encoding::utf8_percent_encode(genre, percent_encoding::NON_ALPHANUMERIC)
            .to_string();
        list.push(category_json(&format!("/genres/{enc}"), genre));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let url = format!("{HOST}{category_id}?page={page}&sort=&filters=",);
    let html = fetch_text(&url).await?;
    let items = parse_cards(&html, 20);
    let has_more = html.contains("rel=\"next\"");
    let total = if has_more { 9999 } else { items.len() as i64 };
    Ok(json!({
        "page": page,
        "pagecount": if has_more { 9999 } else { 1 },
        "limit": 20,
        "total": total,
        "has_more": has_more,
        "list": items,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    let path = video_id.split('@').next().unwrap_or(video_id);
    let url = if path.starts_with("http") {
        path.to_string()
    } else {
        format!("{HOST}{path}")
    };
    let html = fetch_text(&url).await?;
    let title = meta(&html, "og:title");
    let title = if title.is_empty() {
        let re = Regex::new(r"<title>([^<]+)</title>").unwrap();
        re.captures(&html)
            .map(|c| {
                unesc(c.get(1).unwrap().as_str())
                    .split('|')
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string()
            })
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| "XX01 影片".to_string())
    } else {
        title
    };
    let cover = abs_url(&meta(&html, "og:image"));
    let cover = if cover.starts_with("data:") {
        String::new()
    } else {
        cover
    };
    let duration: i64 = meta(&html, "og:video:duration").parse().unwrap_or(0);
    let actor = meta(&html, "og:video:actor");
    let director = meta(&html, "og:video:director");
    let desc = meta(&html, "og:description");
    let mut synopsis = String::new();
    if !actor.is_empty() && actor != "未知" {
        synopsis.push_str(&format!("女优: {actor}\n"));
    }
    if !director.is_empty() {
        synopsis.push_str(&format!("导演: {director}\n"));
    }
    if duration > 0 {
        synopsis.push_str(&format!("时长: {}\n", hms(duration)));
    }
    synopsis.push_str(&desc);
    let mut episodes = Vec::new();
    for (stream_url, lab) in streams(&html) {
        episodes.push(episode_json(&stream_url, &format!("XX01·{lab}"), &url));
    }
    if episodes.is_empty() {
        // jar 原文：无流时给一条“嗅探$”集，壳去详情页嗅探。
        episodes.push(episode_json(&format!("嗅探${url}$0"), "XX01·嗅探", &url));
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim(),
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let url = format!("{HOST}/search/{enc}?page=1");
    let html = fetch_text(&url).await?;
    let items = parse_cards(&html, 40);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(rest) = video_id.strip_prefix("嗅探$") {
        // 格式：嗅探${详情地址}$${序号}，回详情页取对应流。
        let mut parts = rest.split('$');
        let detail_url = parts.next().unwrap_or("");
        let idx: usize = parts.next().unwrap_or("0").parse().unwrap_or(0);
        let d = detail(detail_url).await?;
        if let Some(eps) = d.get("episodes").and_then(|e| e.as_array()) {
            if let Some(ep) = eps.get(idx) {
                let id = ep["video_id"].as_str().unwrap_or("");
                if id.starts_with("http") {
                    return Ok(json!({"url": id}));
                }
            }
        }
        return Err(ApiError::Internal("XX01 该集没有播放地址".into()));
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("XX01 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unpack_restores_m3u8() {
        let packed = r#"eval(function(p,a,c,k,e,d){}('0 1',36,2,'https://surrit.com/x/playlist.m3u8|720p/video.m3u8'.split('|')))"#;
        let out = unpack(packed);
        assert!(out.contains("https://surrit.com/x/playlist.m3u8"));
    }

    #[test]
    fn label_picks_quality() {
        assert_eq!(label("https://s/x/720p/video.m3u8"), "标清720");
        assert_eq!(label("https://s/x/playlist.m3u8"), "高清主清单");
        assert_eq!(label("https://s/x/1080p/video.m3u8"), "超清1080");
    }

    #[test]
    fn hms_formats_seconds() {
        assert_eq!(hms(5965), "01:39:25");
        assert_eq!(hms(65), "00:01:05");
    }
}
