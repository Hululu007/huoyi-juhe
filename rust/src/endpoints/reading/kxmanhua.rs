//! kxmanhua：与火蚁TV 的 kxmanhua.py 一一对应。
//!
//! 漫画站：分类为固定 6 项（全部/3D/韩漫/日漫/真人/耽美BL）；目
//! 录走 /manga/library（type/complete/page/orderby 四参，封面恒
//! 为空）；详情先出带“第 N 话”编号的章节（按号排序），再出未编号
//! 章节（页内顺序，跳过开始阅读/公告/停刊/休刊）；搜索只查第 1
//! 页；取流时抓 imh99 图床图片拼成 pics://。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://kxmanhua.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MIN_LEN: usize = 10000;

const CATEGORIES: [(&str, &str); 6] = [
    ("0", "全部漫画"),
    ("1", "3D漫画"),
    ("2", "韩漫"),
    ("3", "日漫"),
    ("4", "真人漫画"),
    ("5", "耽美BL漫画"),
];

static HTTP: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn client() -> ApiResult<&'static reqwest::Client> {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .ok()
    })
    .as_ref()
    .ok_or_else(|| ApiError::Internal("kxmanhua client unavailable".into()))
}

fn must_re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|_| Regex::new("$^").unwrap())
}

fn category_json(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

fn item_json(id: &str, title: &str, cover: &str, remark: &str) -> Value {
    json!({"id": id, "title": title, "cover": cover, "remark": remark})
}

fn episode_json(video_id: &str, title: &str, series_id: &str) -> Value {
    json!({"video_id": video_id, "title": title, "series_id": series_id})
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

fn clean_text(raw: &str) -> String {
    let no_tags = must_re(r"<[^>]+>").replace_all(raw, "");
    let decoded = decode_entities(&no_tags);
    decoded.replace('\u{a0}', " ").trim().to_string()
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 与 py 的 _fetch 一致：最多 3 次，页长不足阈值或请求失败时睡 1 秒
/// 再试；最后一次无论长短都返回（失败返回空串）。
async fn fetch(url: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    for attempt in 0..3 {
        let result = c
            .get(url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE_URL}/"))
            .send()
            .await;
        match result {
            Ok(resp) => {
                let text = resp.text().await.unwrap_or_default();
                if text.chars().count() >= MIN_LEN || attempt == 2 {
                    return text;
                }
            }
            Err(_) => {
                if attempt == 2 {
                    return String::new();
                }
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    String::new()
}

fn parse_list(page: &str) -> Vec<Value> {
    let re = must_re(r#"<a href="/manga/(\d+)"[^>]*>([^<]*)</a>"#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for caps in re.captures_iter(page) {
        let wid = &caps[1];
        if !seen.insert(wid.to_string()) {
            continue;
        }
        let name = clean_text(&caps[2]);
        if name.is_empty() {
            continue;
        }
        items.push(item_json(wid, &name, "", ""));
    }
    items
}

fn first_digits(id: &str) -> String {
    match must_re(r"(\d+)").captures(id) {
        Some(caps) => caps[1].to_string(),
        None => id.to_string(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let tid = if category_id.is_empty() {
        "0"
    } else {
        category_id
    };
    let url = format!("{BASE_URL}/manga/library?type={tid}&complete=1&page={page}&orderby=1");
    let items = parse_list(&fetch(&url).await);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let wid = first_digits(series_id);
    let page = fetch(&format!("{BASE_URL}/manga/{wid}")).await;
    if page.is_empty() {
        return Err(ApiError::Internal("kxmanhua未返回详情".into()));
    }
    let name = match must_re(r"(?s)<title>(.*?)</title>").captures(&page) {
        Some(caps) => clean_text(&caps[1])
            .split("-免费看")
            .next()
            .unwrap_or("")
            .trim()
            .to_string(),
        None => String::new(),
    };
    let name = if name.is_empty() { wid.clone() } else { name };
    let ch_re = must_re(&format!(
        r#"(?s)<a[^>]*href="/manga/{wid}/detail/(\d+)"[^>]*>(.*?)</a>"#,
        wid = wid
    ));
    let num_re = must_re(r"第(\d+)话");
    let mut seen: HashSet<String> = HashSet::new();
    let mut numbered: Vec<(i64, String, String)> = Vec::new();
    let mut others: Vec<(String, String)> = Vec::new();
    for caps in ch_re.captures_iter(&page) {
        let cid = caps[1].to_string();
        let lab = clean_text(&caps[2]);
        if lab.is_empty()
            || lab == "开始阅读"
            || lab.contains("公告")
            || lab.contains("停刊")
            || lab.contains("休刊")
        {
            continue;
        }
        if !seen.insert(cid.clone()) {
            continue;
        }
        match num_re.captures(&lab) {
            Some(ncaps) => {
                let n = ncaps[1].parse::<i64>().unwrap_or(0);
                numbered.push((n, lab, cid));
            }
            None => others.push((lab, cid)),
        }
    }
    numbered.sort_by_key(|(n, _, _)| *n);
    let mut episodes: Vec<Value> = numbered
        .iter()
        .map(|(_, lab, cid)| episode_json(&format!("kxmanhua:{wid}:{cid}"), lab, &wid))
        .collect();
    for (lab, cid) in &others {
        episodes.push(episode_json(&format!("kxmanhua:{wid}:{cid}"), lab, &wid));
    }
    Ok(json!({
        "id": wid,
        "title": name,
        "cover": "",
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{BASE_URL}/manga/search?keyword={}",
        pct_encode_query(query)
    );
    let items = parse_list(&fetch(&url).await);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = strip_label(video_id);
    if url.starts_with("pics://") {
        return Ok(json!({"url": url}));
    }
    let parts: Vec<&str> = url.split(':').collect();
    if parts.len() < 3
        || parts[0] != "kxmanhua"
        || parts[2].is_empty()
        || !parts[2].chars().all(|c| c.is_ascii_digit())
    {
        return Ok(json!({"url": url}));
    }
    let (wid, cid) = (parts[1], parts[2]);
    let page = fetch(&format!("{BASE_URL}/manga/{wid}/detail/{cid}")).await;
    let img_re = must_re(r#"<img[^>]*src="(https://img\.imh99\.top/webtoon/content/[^"]+)""#);
    let mut seen: HashSet<String> = HashSet::new();
    let mut imgs = Vec::new();
    for caps in img_re.captures_iter(&page) {
        let img = caps[1].to_string();
        if seen.insert(img.clone()) {
            imgs.push(img);
        }
    }
    if imgs.is_empty() {
        return Err(ApiError::Internal("kxmanhua未返回图片".into()));
    }
    Ok(json!({"url": format!("pics://{}", imgs.join("&&"))}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_skips_empty_titles() {
        let page =
            r#"<a href="/manga/11">漫A</a><a href="/manga/12"></a><a href="/manga/11">漫A</a>"#;
        let items = parse_list(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "11");
        assert_eq!(items[0]["cover"], "");
    }

    #[test]
    fn chapter_number_sort() {
        let mut numbered: Vec<(i64, String, String)> = vec![
            (10, "第10话".to_string(), "c10".to_string()),
            (2, "第2话".to_string(), "c2".to_string()),
        ];
        numbered.sort_by_key(|(n, _, _)| *n);
        assert_eq!(numbered[0].0, 2);
        assert_eq!(numbered[1].0, 10);
    }
}
