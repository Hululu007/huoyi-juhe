//! 🔞51X（51xz.vip）：Next.js 中文成人视频站。
//!
//! 列表走页内 Next.js flight 数据里的 video 记录
//!（id/slug/titleZh/duration 秒/coverUrl/hlsUrl），详情取
//! 页内 m3u8（优先 xvideoapi 的 media/hls 清单），搜索
//! /search?q=。取流（详情页 m3u8，本机实测清单 66 分片、
//! 总时长 655.0 秒，与 JSON-LD 时长 PT654S 对上；首分片
//! 200 + 2024768B，AES-128 加密分片首字节非 0x47 属正常，
//! 同 jable 加密源先例；密钥 200/16B）。
//! 验门（2026-11-06 本机出口实测）：详情
//! cmw0kw8ph1udo3s0jmfgk4fhn《深喉小妹妹硬要往里插》；
//! 分类 日本无码 p1/p2 各 24 条 0 重合；搜索 探访 60 条。
//! 注意：首页 ?page=2 与首页内容相同（首页不分页），
//! 首页分类只取 p1；/m/ 分类按 ?page=N 翻页；列表卡片
//! 静态 HTML 里无 <img>，封面只能从 flight 数据的 coverUrl 取。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://51xz.vip";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 /m/ 视频分类（小说三类不进视频站）。
const CATS: &[(&str, &str)] = &[
    ("home", "每日精选"),
    ("m:真实自拍", "真实自拍"),
    ("m:网红女神", "网红女神"),
    ("m:国产精品", "精品国产"),
    ("m:爱好男同", "爱好男同"),
    ("m:情感剧场", "情感剧场"),
    ("m:古装历史", "古装剧场"),
    ("m:年代农村", "年代农村"),
    ("m:穿越重生", "穿越重生"),
    ("m:今日吃瓜", "今日吃瓜"),
    ("m:海外吃瓜", "海外吃瓜"),
    ("m:娱乐吃瓜", "娱乐吃瓜"),
    ("m:网红黑料", "网红黑料"),
    ("m:日本无码", "日本AV"),
    ("m:国产av", "国产AV"),
    ("m:欧美av", "欧美AV"),
    ("m:动漫av", "动漫AV"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("51X 请求 HTTP {status}")));
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
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
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

/// 秒数 → H:MM:SS / M:SS。
fn fmt_duration(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// ISO 时长 PT654S → 654 秒。
fn iso_seconds(s: &str) -> i64 {
    let re = Regex::new(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?").unwrap();
    let Some(cap) = re.captures(s) else {
        return 0;
    };
    let h: i64 = cap
        .get(1)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let m: i64 = cap
        .get(2)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let sec: i64 = cap
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    h * 3600 + m * 60 + sec
}

/// flight 数据里的 video 记录：字段在页内以 \" 转义形式出现，
/// 正则允许引号前带可选反斜杠。
fn field<'a>(block: &'a str, key: &str) -> String {
    let pat = format!(r#"\\?"{key}\\"?:\\?"([^"\\]*)"#);
    let Ok(re) = Regex::new(&pat) else {
        return String::new();
    };
    match re.captures(block) {
        Some(c) => decode_entities(&c[1]),
        None => String::new(),
    }
}

fn parse_records(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    // flight 数据：\"video\":{\"id\":\"...\"...}；JSON-LD 里没有
    // video 记录，不会误命中。
    for block in html.split("\\\"video\\\":{").skip(1) {
        let end = block.find("\\\"},\\\"").unwrap_or(block.len().min(3000));
        let block = &block[..end];
        let id = field(block, "id");
        if id.is_empty() || seen.contains(&id) {
            continue;
        }
        let slug = field(block, "slug");
        let title = field(block, "titleZh");
        if title.is_empty() {
            continue;
        }
        let cover = field(block, "coverUrl");
        let secs: i64 = field(block, "duration").parse().unwrap_or(0);
        let remark = fmt_duration(secs);
        seen.push(id.clone());
        let url = if slug.is_empty() {
            format!("{HOST}/video/{id}/")
        } else {
            format!("{HOST}/video/{id}/{slug}")
        };
        items.push(item_json(&url, &truncate(&title, 90), &cover, &remark));
    }
    // 兜底：JSON-LD ItemList（只有 id 与标题，无封面/时长）。
    if items.is_empty() {
        let re = Regex::new(r#""item":"(https://51xz\.vip/video/[^"]+)","#).unwrap();
        let name_re = Regex::new(r#""name":"([^"]+)","#).unwrap();
        let names: Vec<String> = name_re
            .captures_iter(html)
            .map(|c| decode_entities(&c[1]))
            .collect();
        for (i, cap) in re.captures_iter(html).enumerate() {
            let url = cap[1].to_string();
            if seen.contains(&url) {
                continue;
            }
            seen.push(url.clone());
            let title = names.get(i + 1).cloned().unwrap_or_default();
            if title.is_empty() {
                continue;
            }
            items.push(item_json(&url, &truncate(&title, 90), "", ""));
        }
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if category_id == "home" {
        return HOST.to_string();
    }
    let name = category_id.strip_prefix("m:").unwrap_or(category_id);
    let enc: String = url::form_urlencoded::byte_serialize(name.as_bytes()).collect();
    if page <= 1 {
        format!("{HOST}/m/{enc}")
    } else {
        format!("{HOST}/m/{enc}?page={page}")
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

fn json_ld_field(html: &str, key: &str) -> String {
    let marker = format!("\"{key}\":");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let rest = html[p + marker.len()..].trim_start();
    if !rest.starts_with('"') {
        return String::new();
    }
    let rest = &rest[1..];
    rest.find('"')
        .map(|e| decode_entities(&rest[..e]))
        .unwrap_or_default()
}

/// 详情页 m3u8：优先 xvideoapi 的 media/hls 清单，否则取第一个。
fn extract_m3u8(html: &str) -> String {
    let re = Regex::new(r#"https?://[^\s"\\]+\.m3u8"#).unwrap();
    let mut first = String::new();
    for cap in re.captures_iter(html) {
        let u = cap[0].to_string();
        if first.is_empty() {
            first = u.clone();
        }
        if u.contains("xvideoapi") {
            return u;
        }
    }
    first
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    // 首页站侧不分页：p1 之后直接返回空。
    if category_id == "home" && page > 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_records(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = meta_content(&html, "property", "og:title");
    if title.is_empty() {
        return Err(ApiError::Internal("51X 未返回影片资料".into()));
    }
    let title = title.trim_end_matches(" · 51X").trim().to_string();
    let cover = meta_content(&html, "property", "og:image");
    let desc = json_ld_field(&html, "description");
    let secs = iso_seconds(&json_ld_field(&html, "duration"));
    let synopsis = if secs > 0 {
        format!("时长：{}", fmt_duration(secs))
    } else {
        truncate(&desc, 400)
    };
    let synopsis = if desc.is_empty() {
        synopsis
    } else if secs > 0 {
        format!("{desc}\n时长：{}", fmt_duration(secs))
    } else {
        truncate(&desc, 400)
    };
    let stream = extract_m3u8(&html);
    let episodes = if stream.is_empty() {
        vec![episode_json(series_id, "正片", series_id)]
    } else {
        vec![episode_json(&stream, "正片", series_id)]
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": truncate(&synopsis, 400),
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let url = extract_m3u8(&html);
    if url.is_empty() {
        return Err(ApiError::Internal("51X 未取到播放地址".into()));
    }
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
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_records(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_parse_flight_data() {
        let html = r#"self.__next_f.push([1,"x:[\"$\",\"$L30\",\"cmw3gx26e42fw3s0j0bokics9\",{\"video\":{\"id\":\"cmw3gx26e42fw3s0j0bokics9\",\"slug\":\"in-she-078\",\"titleZh\":\"上流社会素人人妻中出搭讪 SHE-078\",\"titleEn\":\"\",\"descriptionZh\":\"简介\",\"duration\":\"8652\",\"coverUrl\":\"https://source.datashubcenter.com/images/372780602961bf8c/cover7f6be145.jpg\",\"hlsUrl\":\"https://source.datashubcenter.com/videos/372780602961bf8c/372780602961bf8c/index.m3u8\"},\"extra\":1}]"#;
        let items = parse_records(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://51xz.vip/video/cmw3gx26e42fw3s0j0bokics9/in-she-078"
        );
        assert_eq!(items[0]["title"], "上流社会素人人妻中出搭讪 SHE-078");
        assert_eq!(
            items[0]["cover"],
            "https://source.datashubcenter.com/images/372780602961bf8c/cover7f6be145.jpg"
        );
        assert_eq!(items[0]["remark"], "2:24:12");
    }

    #[test]
    fn fmt_duration_cases() {
        assert_eq!(fmt_duration(8652), "2:24:12");
        assert_eq!(fmt_duration(654), "10:54");
        assert_eq!(fmt_duration(0), "");
    }

    #[test]
    fn iso_seconds_cases() {
        assert_eq!(iso_seconds("PT654S"), 654);
        assert_eq!(iso_seconds("PT2H12M43S"), 7963);
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("home", 1), "https://51xz.vip");
        assert_eq!(
            catalog_url("m:日本无码", 1),
            "https://51xz.vip/m/%E6%97%A5%E6%9C%AC%E6%97%A0%E7%A0%81"
        );
        assert_eq!(
            catalog_url("m:日本无码", 2),
            "https://51xz.vip/m/%E6%97%A5%E6%9C%AC%E6%97%A0%E7%A0%81?page=2"
        );
    }

    #[test]
    fn extract_m3u8_prefers_xvideoapi() {
        let html = "var a=\"https://source.datashubcenter.com/videos/aa/aa/index.m3u8\"; var b=\"https://xvideoapi.datashubcenter.com/media/hls/cmw0kw8ph1udo3s0jmfgk4fhn/index.m3u8\";";
        assert_eq!(
            extract_m3u8(html),
            "https://xvideoapi.datashubcenter.com/media/hls/cmw0kw8ph1udo3s0jmfgk4fhn/index.m3u8"
        );
    }
}
