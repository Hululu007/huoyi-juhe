//! TikTok成人版（tiktvod01.xyz）：苹果 CMS 风格视频站，列表与详情走 HTML 解析。
//! 取流：播放页 `/vodplay/{slug}` 内 `var player_aaaa={"url":"...m3u8",...}`
//! 直接给变体清单地址（`\/` 与 `\uXXXX` 转义须还原），现取现用。
//! 实测麻豆片：变体清单 200 → 720p 变体 535 分片、1603.3 秒；
//! 首分片 Range 206 + TS 魔数 0x47。
//! 分类与站导航 1:1（国产传媒/日本AV/无码视频/中文字幕 + 首页最近更新）；
//! 分类翻页 `/vodtype/{slug}-{N}/`；搜索 `/vodsearch/?wd=...`。
//! 分类/搜索页用页内 JSON-LD VideoObject 解析（32 条/页，
//! href 方式会漏 3 条）；首页无 JSON-LD，用卡片 HTML 解析。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://tiktvod01.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 4 个 + 首页最近更新。
const CATS: &[(&str, &str)] = &[
    ("latest", "最近更新"),
    ("domestic-media", "国产传媒"),
    ("japanese-av", "日本AV"),
    ("uncensored-video", "无码视频"),
    ("chinese-subtitles", "中文字幕"),
];

fn player_url_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""url":"((?:\\.|[^"\\])*)""#).unwrap())
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
        return Err(ApiError::Internal(format!(
            "TikTok成人版 请求 HTTP {status}"
        )));
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

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    decode_entities(&out)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// JSON 字符串字面量原文（含 `\/` 与 `\uXXXX` 转义）还原为普通字符串。
fn json_unescape(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let quoted = format!("\"{raw}\"");
    match serde_json::from_str::<String>(&quoted) {
        Ok(v) => v,
        Err(_) => raw.replace("\\/", "/"),
    }
}

/// 在文本里找 `"key": "value"`（冒号后空格可有可无），取第一个
/// 字符串值并做 JSON 转义还原。找不到返回空串。
fn json_string_field(text: &str, key: &str) -> String {
    let marker = format!("\"{key}\"");
    let Some(p) = text.find(&marker) else {
        return String::new();
    };
    let after = &text[p + marker.len()..];
    let after = after.trim_start();
    let Some(rest) = after.strip_prefix(':') else {
        return String::new();
    };
    let rest = rest.trim_start();
    let Some(rest) = rest.strip_prefix('"') else {
        return String::new();
    };
    let mut out = String::with_capacity(rest.len());
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('u') => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Ok(n) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(n) {
                            out.push(ch);
                        }
                    }
                }
                Some(e) => out.push(e),
                None => break,
            },
            '"' => break,
            _ => out.push(c),
        }
    }
    out
}

/// 分类/搜索页 JSON-LD VideoObject 解析：每个对象取 name、
/// thumbnailUrl、contentUrl（内含 /vodplay/{slug}）、genre。
fn parse_jsonld_items(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("\"@type\": \"VideoObject\"").skip(1) {
        let name = json_string_field(block, "name");
        if name.is_empty() {
            continue;
        }
        let content = json_string_field(block, "contentUrl");
        let slug = match content.find("/vodplay/") {
            Some(p) => {
                let s = p + 9;
                let e = content[s..]
                    .find('"')
                    .map(|i| s + i)
                    .unwrap_or(content.len());
                content[s..e].to_string()
            }
            None => continue,
        };
        if slug.is_empty() || seen.contains(&slug) {
            continue;
        }
        let cover = json_string_field(block, "thumbnailUrl");
        let genre = json_string_field(block, "genre");
        seen.push(slug.clone());
        items.push(item_json(
            &format!("{HOST}/vodplay/{slug}"),
            &truncate(&name, 90),
            &cover,
            &genre,
        ));
    }
    items
}

/// 首页卡片解析：`<div class="thumbnail group">`（跳过
/// `style="display: none;"` 的占位卡），slug 取第一个
/// /vodplay/ 链接，封面取 img 的 data-src，标题取
/// text-secondary 锚文本，备注取左下角徽标（中文字幕/无码等）。
fn parse_home_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"thumbnail group\"").skip(1) {
        if block.len() > 40 && block[..40].contains("display: none") {
            continue;
        }
        let slug = match block.find("/vodplay/") {
            Some(p) => {
                let s = p + 9;
                let e = block[s..]
                    .find(|c: char| !c.is_ascii_alphanumeric() && c != '-' && c != '_')
                    .map(|i| s + i)
                    .unwrap_or(block.len());
                block[s..e].to_string()
            }
            None => continue,
        };
        if slug.is_empty() || seen.contains(&slug) {
            continue;
        }
        let cover = if let Some(p) = block.find("data-src=\"http") {
            let s = p + 10;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else if let Some(p) = block.find("src=\"http") {
            let s = p + 5;
            block[s..]
                .find('"')
                .map(|e| block[s..s + e].to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };
        let title = match block.find("class=\"text-secondary") {
            Some(p) => {
                let after = &block[p..];
                match after.find('>') {
                    Some(gt) => {
                        let s = gt + 1;
                        after[s..]
                            .find("</a>")
                            .map(|e| decode_entities(after[s..s + e].trim()))
                            .unwrap_or_default()
                    }
                    None => String::new(),
                }
            }
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let mut badges: Vec<String> = Vec::new();
        let mut rest = block;
        while let Some(p) = rest.find("<span class=\"absolute bottom-1") {
            let after = &rest[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</span>") {
                    let t = after[s..s + e].trim().to_string();
                    if !t.is_empty() && !badges.contains(&t) {
                        badges.push(t);
                    }
                }
            }
            rest = &rest[p + 1..];
        }
        seen.push(slug.clone());
        items.push(item_json(
            &format!("{HOST}/vodplay/{slug}"),
            &truncate(&title, 90),
            &cover,
            &badges.join("·"),
        ));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    if category_id == "latest" {
        return format!("{HOST}/");
    }
    if page <= 1 {
        format!("{HOST}/vodtype/{category_id}/")
    } else {
        format!("{HOST}/vodtype/{category_id}-{page}/")
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
    match t.rsplit_once(" | ") {
        Some((head, _)) => head.trim().to_string(),
        None => t,
    }
}

/// 从播放页 `player_aaaa` 里取第一个含 m3u8 的 url 字段并还原转义。
fn extract_player_url(html: &str) -> Option<String> {
    for cap in player_url_re().captures_iter(html) {
        let raw = &cap[1];
        if raw.contains("m3u8") {
            let url = json_unescape(raw);
            if url.starts_with("http") {
                return Some(url);
            }
        }
    }
    None
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if category_id == "latest" && page > 1 {
        // 首页最近更新只有一页，无翻页。
        return Ok(json!({"items": [], "has_more": false}));
    }
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = if category_id == "latest" {
        parse_home_cards(&html)
    } else {
        parse_jsonld_items(&html)
    };
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("TikTok成人版 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let vod_name = json_string_field(&html, "vod_name");
    let vod_actor = json_string_field(&html, "vod_actor");
    let vod_class = json_string_field(&html, "vod_class");
    let title = if vod_name.is_empty() { title } else { vod_name };
    let mut lines: Vec<String> = Vec::new();
    if !vod_class.is_empty() {
        lines.push(format!("分类：{vod_class}"));
    }
    if !vod_actor.is_empty() {
        lines.push(format!("演员：{vod_actor}"));
    }
    let desc = truncate(&lines.join("\n"), 400);
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
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let url = extract_player_url(&html)
        .ok_or_else(|| ApiError::Internal("TikTok成人版 播放页未找到 m3u8 地址".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/vodsearch/?wd={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_jsonld_items(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_jsonld_items_real() {
        let html = r#"<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "ItemList",
  "itemListElement": [
    {
      "@type": "ListItem",
      "position": 1,
      "item": {
        "@type": "VideoObject",
        "name": "麻豆-同学的发情妈妈美熟女姿态让人抓狂-苏语棠",
        "description": "",
        "thumbnailUrl": "https://sbzytpimg1.com:3519/upload/vod/20251009-1/2acd93588b94b773e569bf57552cd326.jpg",
        "uploadDate": "2025-12-21T04:43:19+08:00",
        "contentUrl": "ttiktokcrb.top/vodplay/madoutongxuedefaqingmamameishunvzitairangrenzhuakuangsuyutang",
        "embedUrl": "第1集$https://b.v155p.com/20251207/uUEJ6TqY/index.m3u8",
        "duration": "PT0S",
        "genre": "国产传媒"
      }
    },
    {
      "@type": "ListItem",
      "position": 2,
      "item": {
        "@type": "VideoObject",
        "name": "麻豆-停电后特别寂寞-项子甯",
        "thumbnailUrl": "https://sbzytpimg1.com:3519/upload/vod/20251009-1/abcdef.jpg",
        "contentUrl": "ttiktokcrb.top/vodplay/madoutingdianhoutebiejimoxiangzining",
        "embedUrl": "第1集$https://b.v155p.com/20251207/yig7OMpG/index.m3u8",
        "genre": "国产传媒"
      }
    }
  ]
}
</script>"#;
        let items = parse_jsonld_items(html);
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0]["title"],
            "麻豆-同学的发情妈妈美熟女姿态让人抓狂-苏语棠"
        );
        assert_eq!(
            items[0]["id"],
            "https://tiktvod01.xyz/vodplay/madoutongxuedefaqingmamameishunvzitairangrenzhuakuangsuyutang"
        );
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .contains("2acd93588b94b773e569bf57552cd326.jpg"));
        assert_eq!(items[0]["remark"], "国产传媒");
        assert_eq!(items[1]["title"], "麻豆-停电后特别寂寞-项子甯");
    }

    #[test]
    fn parse_home_card_real() {
        let html = r#"<div class="thumbnail group">
    <div class="relative aspect-w-16 aspect-h-9 overflow-hidden shadow-lg">
        <a href="/vodplay/madoutongxuedefaqingmamameishunvzitairangrenzhuakuangsuyutang">
            <img alt="" class="w-full" data-loaded="true" data-src="https://sbzytpimg1.com:3519/upload/vod/20251009-1/2acd93588b94b773e569bf57552cd326.jpg" src="https://sbzytpimg1.com:3519/upload/vod/20251009-1/2acd93588b94b773e569bf57552cd326.jpg" loading="lazy" decoding="async">
        </a>
        <a href="/vodplay/madoutongxuedefaqingmamameishunvzitairangrenzhuakuangsuyutang" style="display: none;">
            <span class="absolute bottom-1 left-1 rounded-lg px-2 py-1 text-xs text-nord5 bg-red-800 bg-opacity-75">中文字幕</span>
        </a>
        <a href="/vodplay/madoutongxuedefaqingmamameishunvzitairangrenzhuakuangsuyutang" style="display: none;">
            <span class="absolute bottom-1 left-1 rounded-lg px-2 py-1 text-xs text-nord5 bg-blue-800 bg-opacity-75">无码</span>
        </a>
    </div>
    <div class="mx-2 my-2 text-sm  truncate">
        <a class="text-secondary group-hover:text-primary" href="/vodtype/domestic-media/">麻豆-停电后特别寂寞-项子甯</a>
    </div>
</div>"#;
        let items = parse_home_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "麻豆-停电后特别寂寞-项子甯");
        assert_eq!(items[0]["remark"], "中文字幕·无码");
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .contains("2acd93588b94b773e569bf57552cd326.jpg"));
    }

    #[test]
    fn parse_home_card_skips_placeholder() {
        let html = r##"<div class="thumbnail group" style="display: none;">
    <div class="aspect-w-16 aspect-h-9"></div>
    <div class="my-2 text-sm  truncate">
        <a class="text-secondary group-hover:text-primary" href="#">&nbsp;</a>
    </div>
</div>"##;
        assert!(parse_home_cards(html).is_empty());
    }

    #[test]
    fn extract_player_url_unescapes() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/id\/x\/sid\/1\/nid\/1\/","url":"","vod_data":{"vod_name":"\u9ebb\u8c46-\u540c\u5b66","vod_actor":"","vod_class":"\u56fd\u4ea7\u4f20\u5a92"},"url":"https:\/\/b.v155p.com\/20251207\/uUEJ6TqY\/index.m3u8","from":"155m3u8"};"#;
        assert_eq!(
            extract_player_url(html).unwrap(),
            "https://b.v155p.com/20251207/uUEJ6TqY/index.m3u8"
        );
    }

    #[test]
    fn json_string_field_unicode() {
        let html = r#"{"vod_name":"\u9ebb\u8c46-\u540c\u5b66\u7684\u53d1\u60c5\u5988\u5988","vod_actor":"","vod_class":"\u56fd\u4ea7\u4f20\u5a92,\u9ebb\u8c46\u4f20\u5a92"}"#;
        assert_eq!(json_string_field(html, "vod_name"), "麻豆-同学的发情妈妈");
        assert_eq!(json_string_field(html, "vod_class"), "国产传媒,麻豆传媒");
        assert_eq!(json_string_field(html, "vod_actor"), "");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("latest", 1), "https://tiktvod01.xyz/");
        assert_eq!(
            catalog_url("domestic-media", 1),
            "https://tiktvod01.xyz/vodtype/domestic-media/"
        );
        assert_eq!(
            catalog_url("domestic-media", 2),
            "https://tiktvod01.xyz/vodtype/domestic-media-2/"
        );
        assert_eq!(
            catalog_url("japanese-av", 5),
            "https://tiktvod01.xyz/vodtype/japanese-av-5/"
        );
    }

    #[test]
    fn tag_title_strips_site_name() {
        let html = "<title>麻豆-同学的发情妈妈美熟女姿态让人抓狂-苏语棠 | tiktok成人版</title>";
        assert_eq!(
            tag_title(html),
            "麻豆-同学的发情妈妈美熟女姿态让人抓狂-苏语棠"
        );
    }
}
