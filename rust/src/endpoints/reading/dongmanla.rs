//! dongmanla：动漫啦漫画（https://www.dongman.la）。
//!
//! 按 MyComic 接口文档 5.7 节实现，只做免费能看的部分。列表页（搜索与
//! 分类）共用同一套解析：ul.divide-y 下的 li，每条取详情链接 id、
//! data-cover 封面、h2 标题、状态 span 作 remark。详情取 h1 标题、
//! 首张 img.dongman.la 图片作封面、meta description 去站方套话后
//! 作简介；章节是 /manhua/chapter/{漫画id}/{章节id}/ 链接，按 href
//! 去重、排除“开始阅读 →”导航按钮、保持页面原顺序。章节图片取
//! data-src，拼成 pics:// 交给图片浏览链路，图片头 Referer 为基址。
//!
//! 分类为静态表（照文档 5.7 照站原样写；漫画台是别的源，本批不写；
//! 2154 因标题为空跳过不列）：进度 finish/serial、题材 class/{id}、
//! 地区 {japan|guochan|hongkongtaiwan|oumei|hanguo|other}、字母
//! letter/{a-z|90}。分类 id 即 URL 路径段。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://www.dongman.la";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Safari/537.36";

/// 固定分类：进度 2 项 + 题材 59 项 + 地区 6 项（字母 27 项由
/// categories() 另行追加，不进此表）。
const CATEGORIES: [(&str, &str); 67] = [
    ("finish", "完结"),
    ("serial", "连载"),
    ("class/49", "少年"),
    ("class/43", "少女"),
    ("class/24", "爱情"),
    ("class/14", "冒险"),
    ("class/25", "搞笑"),
    ("class/48", "青年"),
    ("class/16", "格斗"),
    ("class/13", "科幻"),
    ("class/18", "校园"),
    ("class/22", "魔法"),
    ("class/17", "竞技"),
    ("class/23", "神鬼"),
    ("class/45", "职场"),
    ("class/46", "侦探"),
    ("class/29", "历史"),
    ("class/27", "耽美"),
    ("class/19", "恐怖"),
    ("class/47", "机战"),
    ("class/33", "后宫"),
    ("class/20", "悬疑"),
    ("class/30", "战争"),
    ("class/35", "美食"),
    ("class/26", "伪娘"),
    ("class/36", "四格"),
    ("class/42", "治愈"),
    ("class/37", "萌系"),
    ("class/32", "热血"),
    ("class/31", "宅腐"),
    ("class/41", "性转换"),
    ("class/38", "百合"),
    ("class/44", "颜艺"),
    ("class/34", "魔幻"),
    ("class/52", "音乐舞蹈"),
    ("class/53", "东方"),
    ("class/115", "异能"),
    ("class/2158", "生存"),
    ("class/2157", "耽美 BL"),
    ("class/2156", "漫威"),
    ("class/2155", "爱情，奇幻"),
    ("class/2153", "战斗"),
    ("class/117", "穿越"),
    ("class/116", "BG"),
    ("class/2163", "宅系"),
    ("class/114", "古风"),
    ("class/113", "ABO"),
    ("class/2159", "励志"),
    ("class/2160", "泛爱"),
    ("class/2161", "TS"),
    ("class/2162", "秀吉"),
    ("class/2168", "福瑞"),
    ("class/2164", "ゆり"),
    ("class/2165", "高清单行"),
    ("class/2166", "其他"),
    ("class/12", "玄幻"),
    ("class/2169", "舰娘"),
    ("class/2167", "西方魔幻"),
    ("class/95", "惊悚"),
    ("class/21", "奇幻"),
    ("class/39", "节操"),
    ("japan", "日本"),
    ("guochan", "国产"),
    ("hongkongtaiwan", "港台"),
    ("oumei", "欧美"),
    ("hanguo", "韩国"),
    ("other", "其他"),
];

fn must_re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|_| Regex::new("$^").unwrap())
}

fn decode_entities(s: &str) -> String {
    let dec = must_re(r"&#(\d+);");
    let mut out = dec
        .replace_all(s, |caps: &regex::Captures| {
            caps[1]
                .parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    let hex = must_re(r"&#x([0-9a-fA-F]+);");
    out = hex
        .replace_all(&out, |caps: &regex::Captures| {
            u32::from_str_radix(&caps[1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    for (from, to) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&amp;", "&"),
    ] {
        out = out.replace(from, to);
    }
    out
}

fn strip_tags(raw: &str) -> String {
    must_re(r"<[^>]+>").replace_all(raw, "").to_string()
}

fn clean_text(raw: &str) -> String {
    let decoded = decode_entities(&strip_tags(raw));
    let collapsed = must_re(r"\s+").replace_all(&decoded, " ");
    collapsed.replace('\u{a0}', " ").trim().to_string()
}

fn pct_encode_segment(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 与 ho5ho 的 fetch 一致：单次请求，失败返回空串（无重试）。
async fn fetch(path: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    let url = format!("{BASE_URL}{path}");
    let result = c
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .header("Referer", format!("{BASE_URL}/"))
        .send()
        .await;
    match result {
        Ok(resp) => resp.text().await.unwrap_or_default(),
        Err(_) => String::new(),
    }
}

/// 列表页解析：ul.divide-y 下的 li，每条取 id/标题/封面/状态。
fn parse_list(page: &str) -> Vec<Value> {
    let Some(ul) = must_re(r"(?s)<ul[^>]*divide-y[^>]*>(.*?)</ul>").captures(page) else {
        return Vec::new();
    };
    let body = ul[1].to_string();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for li in must_re(r"(?s)<li[^>]*>(.*?)</li>").captures_iter(&body) {
        let block = &li[1];
        let Some(href) = must_re(r#"href="/manhua/detail/(\d+)/""#).captures(block) else {
            continue;
        };
        let id = href[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = match must_re(r#"data-cover src="([^"]+)""#).captures(block) {
            Some(caps) => caps[1].to_string(),
            None => match must_re(r#"<img[^>]*src="([^"]+)""#).captures(block) {
                Some(caps) => caps[1].to_string(),
                None => String::new(),
            },
        };
        let title = match must_re(r"(?s)<h2[^>]*>\s*<a[^>]*>([^<]+)</a>").captures(block) {
            Some(caps) => clean_text(&caps[1]),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let remark = match must_re(r"状态：<span[^>]*>([^<]+)</span>").captures(block) {
            Some(caps) => clean_text(&caps[1]),
            None => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 目录页路径：第 1 页 /manhua/{分类}/，第 N>1 页 /manhua/{分类}/{N}.html。
fn catalog_path(category_id: &str, page: i64) -> String {
    if page > 1 {
        format!("/manhua/{category_id}/{page}.html")
    } else {
        format!("/manhua/{category_id}/")
    }
}

/// 有“下一页”链接即还有下一页。
fn has_more(page: &str) -> bool {
    page.contains("下一页</a>")
}

/// 详情标题：h1 文本。
fn detail_title(page: &str) -> String {
    match must_re(r"(?s)<h1[^>]*>([^<]+)</h1>").captures(page) {
        Some(caps) => clean_text(&caps[1]),
        None => String::new(),
    }
}

/// 详情封面：首张 img.dongman.la 图片的 src。
fn detail_cover(page: &str) -> String {
    match must_re(r#"<img[^>]*src="(https://img\.dongman\.la[^"]+)""#).captures(page) {
        Some(caps) => caps[1].to_string(),
        None => String::new(),
    }
}

/// 简介：meta description 去掉末尾站方套话（“免费在线阅读…”起及
/// “动漫啦提供…全集在线观看。”），只留简介本身。
fn detail_synopsis(page: &str) -> String {
    let raw = match must_re(r#"<meta name="description" content="([^"]*)""#).captures(page) {
        Some(caps) => caps[1].to_string(),
        None => {
            match must_re(r#"<meta property="og:description" content="([^"]*)""#).captures(page) {
                Some(caps) => caps[1].to_string(),
                None => String::new(),
            }
        }
    };
    let mut text = clean_text(&raw);
    for marker in ["免费在线阅读", "动漫啦提供"] {
        if let Some(idx) = text.find(marker) {
            text = text[..idx].trim().to_string();
        }
    }
    text
}

/// 章节目录：/manhua/chapter/{漫画id}/{章节id}/ 链接，按 href 去重，
/// 排除文本为“开始阅读 →”的导航按钮，保持页面原顺序。
/// 返回 (漫画 id, 章节 id, 章节标题)。
fn parse_chapters(page: &str) -> Vec<(String, String, String)> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut chapters = Vec::new();
    let re = must_re(
        r#"(?s)<a[^>]*href="(?:https://www\.dongman\.la)?/manhua/chapter/(\d+)/(\d+)/"[^>]*>(.*?)</a>"#,
    );
    for caps in re.captures_iter(page) {
        let title = clean_text(&caps[3]);
        if title.contains("开始阅读") {
            continue;
        }
        let cid = caps[2].to_string();
        if cid.is_empty() || title.is_empty() || !seen.insert(cid.clone()) {
            continue;
        }
        chapters.push((caps[1].to_string(), cid, title));
    }
    chapters
}

/// 章节图片：data-src 全部取到，按页面顺序去重。
fn parse_images(page: &str) -> Vec<String> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut imgs = Vec::new();
    for caps in must_re(r#"data-src="([^"]+)""#).captures_iter(page) {
        let img = caps[1].to_string();
        if seen.insert(img.clone()) {
            imgs.push(img);
        }
    }
    imgs
}

fn category_list() -> Vec<Value> {
    let mut list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    for c in 'a'..='z' {
        let id = format!("letter/{c}");
        let name = c.to_ascii_uppercase().to_string();
        list.push(category_json(&id, &name));
    }
    list.push(category_json("letter/90", "0-9"));
    list
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": category_list()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if category_id.is_empty() {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let path = catalog_path(category_id, page);
    let html = fetch(&path).await;
    let items = parse_list(&html);
    let more = has_more(&html);
    Ok(json!({"items": items, "has_more": more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let mid = series_id.split('/').next().unwrap_or("").trim();
    if mid.is_empty() {
        return Err(ApiError::Internal("dongmanla漫画编号无效".into()));
    }
    let page = fetch(&format!("/manhua/detail/{mid}/")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("dongmanla未返回详情".into()));
    }
    let title = detail_title(&page);
    let title = if title.is_empty() {
        mid.to_string()
    } else {
        title
    };
    let episodes: Vec<Value> = parse_chapters(&page)
        .iter()
        .map(|(m, cid, text)| episode_json(&format!("{m}/{cid}"), text, m))
        .collect();
    Ok(json!({
        "id": mid,
        "title": title,
        "cover": detail_cover(&page),
        "synopsis": detail_synopsis(&page),
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let path = format!("/manhua/so/{}/", pct_encode_segment(query));
    let items = parse_list(&fetch(&path).await);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let id = strip_label(video_id);
    let header = json!({"User-Agent": UA, "Referer": format!("{BASE_URL}/")});
    if let Some(rest) = id.strip_prefix("pics://") {
        let _ = rest;
        return Ok(json!({"url": id, "header": header}));
    }
    let mut parts = id.splitn(2, '/');
    let mid = parts.next().unwrap_or("");
    let cid = parts.next().unwrap_or("");
    if mid.is_empty()
        || cid.is_empty()
        || !mid.chars().all(|c| c.is_ascii_digit())
        || !cid.chars().all(|c| c.is_ascii_digit())
    {
        return Err(ApiError::Internal("dongmanla分集编号无效".into()));
    }
    let page = fetch(&format!("/manhua/chapter/{mid}/{cid}/")).await;
    let imgs = parse_images(&page);
    if imgs.is_empty() {
        return Err(ApiError::Internal("dongmanla未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", imgs.join("&&")), "header": header}))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEARCH_SAMPLE: &str = include_str!("../../../../../mycomic_re/probe/dmla_search.bin");
    const DETAIL_SAMPLE: &str = include_str!("../../../../../mycomic_re/probe/dmla_detail.bin");
    const CHAPTER_SAMPLE: &str = include_str!("../../../../../mycomic_re/probe/dm_chapter.bin");

    #[test]
    fn search_sample_parses_21_items_first_5667() {
        let items = parse_list(SEARCH_SAMPLE);
        assert_eq!(items.len(), 21);
        assert_eq!(items[0]["id"], "5667");
        assert_eq!(items[0]["title"], "斗罗大陆");
        assert_eq!(items[0]["remark"], "连载中");
        assert!(items[0]["cover"]
            .as_str()
            .unwrap_or("")
            .contains("5548838e0ae49.jpg"));
    }

    #[test]
    fn detail_sample_parses_146_chapters_including_first() {
        let chapters = parse_chapters(DETAIL_SAMPLE);
        assert_eq!(chapters.len(), 146);
        assert_eq!(
            chapters[0],
            (
                "5667".to_string(),
                "148522".to_string(),
                "第1话".to_string()
            )
        );
        assert!(chapters
            .iter()
            .any(|(_, cid, title)| cid == "148522" && title == "第1话"));
        assert!(!chapters.iter().any(|(_, _, t)| t.contains("开始阅读")));
    }

    #[test]
    fn detail_sample_title_cover_synopsis() {
        assert_eq!(detail_title(DETAIL_SAMPLE), "斗罗大陆");
        assert!(detail_cover(DETAIL_SAMPLE)
            .starts_with("https://img.dongman.la/uploads/manhua/2015/05/05/5548838e0ae49.jpg"));
        let synopsis = detail_synopsis(DETAIL_SAMPLE);
        assert!(synopsis.starts_with("斗罗大陆漫画"));
        assert!(!synopsis.contains("免费在线阅读"));
        assert!(!synopsis.contains("动漫啦提供"));
        assert!(synopsis.ends_with("名叫斗罗大。"));
    }

    #[test]
    fn chapter_sample_parses_12_images_first_matches() {
        let imgs = parse_images(CHAPTER_SAMPLE);
        assert_eq!(imgs.len(), 12);
        assert_eq!(
            imgs[0],
            "https://img.dongman.la/d/dldl/1/0001.jpg?v=20261016b"
        );
        assert!(imgs
            .iter()
            .all(|u| u.starts_with("https://img.dongman.la/")));
    }

    #[test]
    fn categories_cover_static_table_and_letters() {
        let list = category_list();
        assert_eq!(list.len(), 2 + 59 + 6 + 27);
        assert!(list
            .iter()
            .any(|c| c["id"] == "finish" && c["name"] == "完结"));
        assert!(list
            .iter()
            .any(|c| c["id"] == "serial" && c["name"] == "连载"));
        assert!(list
            .iter()
            .any(|c| c["id"] == "class/49" && c["name"] == "少年"));
        assert!(list
            .iter()
            .any(|c| c["id"] == "class/2155" && c["name"] == "爱情，奇幻"));
        assert!(list
            .iter()
            .any(|c| c["id"] == "guochan" && c["name"] == "国产"));
        assert!(list
            .iter()
            .any(|c| c["id"] == "letter/a" && c["name"] == "A"));
        assert!(list
            .iter()
            .any(|c| c["id"] == "letter/90" && c["name"] == "0-9"));
        assert!(!list.iter().any(|c| c["id"] == "class/2154"));
    }

    #[test]
    fn catalog_path_first_and_later_pages() {
        assert_eq!(catalog_path("class/49", 1), "/manhua/class/49/");
        assert_eq!(catalog_path("class/49", 2), "/manhua/class/49/2.html");
        assert_eq!(catalog_path("finish", 1), "/manhua/finish/");
        assert_eq!(catalog_path("letter/a", 3), "/manhua/letter/a/3.html");
    }

    #[test]
    fn has_more_detects_next_page_link() {
        assert!(has_more(r#"<a href="2.html">下一页</a>"#));
        assert!(!has_more(r#"<a href="1.html">上一页</a>"#));
    }

    #[test]
    fn pct_encode_segment_encodes_chinese() {
        assert_eq!(
            pct_encode_segment("斗罗大陆"),
            "%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86"
        );
        assert_eq!(pct_encode_segment("class/49"), "class%2F49");
    }

    #[test]
    fn parse_chapters_dedups_and_skips_start_reading() {
        let page = r#"<a href="/manhua/chapter/5667/51377/">开始阅读 →</a>
            <a href="/manhua/chapter/5667/148522/">第1话</a>
            <a href="/manhua/chapter/5667/148522/">第1话</a>
            <a href="/manhua/chapter/5667/145917/">第145话</a>"#;
        let chapters = parse_chapters(page);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].1, "148522");
        assert_eq!(chapters[1].1, "145917");
    }

    #[test]
    fn parse_images_dedups_in_order() {
        let page = r#"data-src="https://img.dongman.la/a/1.jpg" data-src="https://img.dongman.la/a/2.jpg" data-src="https://img.dongman.la/a/1.jpg""#;
        assert_eq!(
            parse_images(page),
            vec![
                "https://img.dongman.la/a/1.jpg".to_string(),
                "https://img.dongman.la/a/2.jpg".to_string(),
            ]
        );
    }

    #[test]
    fn strip_label_keeps_plain_id() {
        assert_eq!(strip_label("第1话$5667/148522"), "5667/148522");
        assert_eq!(strip_label("5667/148522"), "5667/148522");
    }
}
