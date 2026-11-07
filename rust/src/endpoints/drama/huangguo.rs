//! 黄果：短剧站（`黄果`）。
//!
//! 来源 jar 类 `ZakaHuangguoAmns`。UA 为 Chrome 126 Android Pixel 7；
//! 基址在 `BASES` 间探测（另有按院校缩写 × 域名拼候选的 `probeBase`，
//! 本模块只保留 `BASES` 两域名 + 失败回退首个，院校拼域名为同款探测
//! 逻辑的穷举分支，探活时若两域名皆死再补）；`probeBase` 逐个 GET `/`，
//! 页面含“黄果”或 `hg-drama-card` 或 `hg-web-detail` 即锁定，失败回
//! 退 `BASES[0]`；`fetch` 失败一次后清 base 重探。
//!
//! 分类写死 6 类（首页 / AI成人短剧 / AI成人漫剧 / AI换脸 / AI魔改 /
//! 排行榜）。首页与排行榜走 HTML（`htmlItems` + `parseList`）；其余
//! 分类走 `/api/videos/category/<分类>?size=21&page=<页>`（要求 JSON
//! `status == 1`）。详情 GET `/video/<id>` 解析标题/简介/封面/集数，
//! 分集为 `第N集$<id>#N`。取流 GET `/api/videos/<id>/play?ep=<集号>`，
//! 取 `data.video_url`，parse 0 + UA + Referer `<base>/`，m3u8 时加
//! `format=application/x-mpegURL`。搜索 GET `/search/video/<编码词>/`。
//! 封面直出原 URL（Java 的 proxy 只作图片中继，不影响核心字段）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";
const BASES: &[&str] = &["https://xjtu.huxrzdjnv.cc", "https://ccaed.h2na6qa39.cc"];

const CATS: &[(&str, &str)] = &[
    ("", "首页"),
    ("/ai-duanju", "AI成人短剧"),
    ("/ai-manju", "AI成人漫剧"),
    ("/ai-huanlian", "AI换脸"),
    ("/ai-mogai", "AI魔改"),
    ("/ranks/hot", "排行榜"),
];

fn strip_tags(s: &str) -> String {
    let re = Regex::new(r"<[^>]+>").unwrap();
    re.replace_all(s, "").trim().to_string()
}

fn first_group(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

async fn get_text(url: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.text().await.ok()
}

/// 探测基址：逐个 GET `/`，页面含“黄果”或 `hg-drama-card` 或
/// `hg-web-detail` 即锁定；皆失败回退 `BASES[0]`。
async fn probe_base() -> String {
    for base in BASES {
        if let Some(text) = get_text(&format!("{base}/")).await {
            if text.contains('黄') && text.contains('果')
                || text.contains("hg-drama-card")
                || text.contains("hg-web-detail")
            {
                return base.to_string();
            }
        }
    }
    BASES[0].to_string()
}

async fn get_json(url: &str) -> Option<Value> {
    let text = get_text(url).await?;
    serde_json::from_str(&text).ok()
}

/// `parseList`：按 `<div class="hg-drama-card">` 切块解析。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let re_block = Regex::new(r#"(?s)<div class="hg-drama-card">"#).unwrap();
    let starts: Vec<usize> = re_block.find_iter(html).map(|m| m.start()).collect();
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(html.len());
        let block = &html[start..end];
        let id_re = Regex::new(r"/video/(\d+)/?").unwrap();
        let Some(id) = id_re
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
        else {
            continue;
        };
        if !seen.insert(id.clone()) {
            continue;
        }
        let img_re = Regex::new(r#"(?s)<img[^>]*?(?:data-src|src)="([^"]+)""#).unwrap();
        let mut cover = String::new();
        if let Some(cap) = img_re.captures(block) {
            let v = cap.get(1).unwrap().as_str();
            if !v.contains("cover-placeholder") {
                cover = v.to_string();
            }
        }
        if cover.is_empty() {
            let src_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).unwrap();
            if let Some(cap) = src_re.captures(block) {
                let v = cap.get(1).unwrap().as_str();
                if !v.contains("cover-placeholder") {
                    cover = v.to_string();
                }
            }
        }
        let title_re =
            Regex::new(r#"(?s)<div class="hg-drama-card__title"><a[^>]*>(.*?)</a>"#).unwrap();
        let mut title = title_re
            .captures(block)
            .map(|c| strip_tags(c.get(1).unwrap().as_str()))
            .unwrap_or_default();
        if title.ends_with("全集在线观看") {
            title = title.trim_end_matches("全集在线观看").trim().to_string();
        }
        if title.is_empty() {
            continue;
        }
        let mut remarks: Vec<String> = Vec::new();
        let score_re = Regex::new(r"(\d+\.\d+分)").unwrap();
        if let Some(c) = score_re.captures(block) {
            remarks.push(c.get(1).unwrap().as_str().to_string());
        }
        let ep_re = Regex::new(r"(更新至\d+集|全\d+集)").unwrap();
        if let Some(c) = ep_re.captures(block) {
            remarks.push(c.get(1).unwrap().as_str().to_string());
        }
        let desc_re = Regex::new(r#"(?s)<p class="hg-drama-card__desc">(.*?)</p>"#).unwrap();
        let desc = desc_re
            .captures(block)
            .map(|c| strip_tags(c.get(1).unwrap().as_str()))
            .unwrap_or_default();
        let tags_re = Regex::new(r#"(?s)<div class="hg-drama-card__tags">(.*?)</div>"#).unwrap();
        let mut tags: Vec<String> = Vec::new();
        if let Some(c) = tags_re.captures(block).and_then(|c| c.get(1)) {
            let tag_re = Regex::new(r#"(?s)<span class="hg-tag">(.*?)<span"#).unwrap();
            for t in tag_re.captures_iter(c.as_str()) {
                let v = strip_tags(t.get(1).unwrap().as_str());
                if !v.is_empty() {
                    tags.push(v);
                }
            }
        }
        let mut remark = remarks.join(" · ");
        if !tags.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&tags.join(" "));
        }
        let _ = desc;
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 首页 / 排行榜的 HTML 解析：先用 JSON-LD 式正则取 id/标题，再用
/// `parseList` 补封面。
fn html_items(html: &str) -> Vec<Value> {
    let ld_re =
        Regex::new(r#""name":"([^"]+)","position":\d+,"url":"[^"]*/video/(\d+)/""#).unwrap();
    let mut by_id: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for cap in ld_re.captures_iter(html) {
        let name = cap.get(1).unwrap().as_str().to_string();
        let id = cap.get(2).unwrap().as_str().to_string();
        by_id.entry(id).or_insert(name);
    }
    let mut items = parse_list(html);
    for it in items.iter_mut() {
        let id = it["id"].as_str().unwrap_or("").to_string();
        if let Some(name) = by_id.get(&id) {
            if it["title"].as_str().unwrap_or("").is_empty() {
                it["title"] = json!(name);
            }
        }
    }
    // JSON-LD 里有但 parseList 没出的，补一条无封面卡片。
    for (id, name) in &by_id {
        if name.contains('黄') && name.contains('果') {
            continue;
        }
        if !items.iter().any(|i| i["id"].as_str() == Some(id.as_str())) {
            items.push(item_json(id, name, "", ""));
        }
    }
    items
}

fn api_card(v: &Value) -> Option<Value> {
    let id = text_of(v, &["id"]);
    let title = text_of(v, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let cover = text_of(v, &["cover"]);
    let mut remarks: Vec<String> = Vec::new();
    let score = get(v, "score").and_then(|s| s.as_f64()).unwrap_or(0.0);
    if score > 0.0 {
        remarks.push(format!("{score:.1}分"));
    }
    let finished = get(v, "is_finished")
        .and_then(|b| b.as_bool())
        .unwrap_or(false);
    let total = int_of(v, &["total_episodes"]);
    let count = int_of(v, &["episode_count"]);
    if finished && total > 0 {
        remarks.push(format!("全{total}集"));
    } else if count > 0 {
        remarks.push(format!("更新至{count}集"));
    }
    let tags = arr_of(get(v, "tags").unwrap_or(&Value::Null))
        .map(|a| {
            a.iter()
                .map(|t| t.as_str().unwrap_or("").to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let mut remark = remarks.join(" · ");
    if !tags.is_empty() {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str(&tags.join(" "));
    }
    Some(item_json(&id, &title, &cover, &remark))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let base = probe_base().await;
    if category_id.is_empty() || category_id == "/ranks/hot" {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let path = if category_id.is_empty() {
            "/"
        } else {
            "/ranks/hot"
        };
        let Some(html) = get_text(&format!("{base}{path}")).await else {
            return Ok(json!({"items": [], "has_more": false}));
        };
        let items = html_items(&html);
        return Ok(json!({"items": items, "has_more": false}));
    }
    let cat = category_id.trim_matches('/');
    let url = format!("{base}/api/videos/category/{cat}?size=21&page={page}");
    let Some(resp) = get_json(&url).await else {
        return Ok(json!({"items": [], "has_more": false}));
    };
    if int_of(&resp, &["status"]) != 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let mut items: Vec<Value> = Vec::new();
    if let Some(arr) = arr_of(get(&data, "items").unwrap_or(&Value::Null)) {
        for v in arr {
            if let Some(card) = api_card(v) {
                items.push(card);
            }
        }
    }
    let has_more = match get(&data, "pagination") {
        Some(p) => {
            let pages = int_of(p, &["pages"]);
            if pages > 0 {
                page < pages
            } else {
                items.len() == 21
            }
        }
        None => items.len() == 21,
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let base = probe_base().await;
    let Some(html) = get_text(&format!("{base}/video/{id}")).await else {
        return Ok(
            json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}),
        );
    };
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let mut title = h1_re
        .captures(&html)
        .map(|c| strip_tags(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        let t_re = Regex::new(r#"data-track-video-title="([^"]+)""#).unwrap();
        title = first_group(&t_re, &html);
    }
    if title.is_empty() {
        let ti_re = Regex::new(r"<title>([^<]+)</title>").unwrap();
        title = first_group(&ti_re, &html)
            .split(" - ")
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
    }
    let mut synopsis = String::new();
    for pat in [
        r#"(?s)hg-web-detail__desc[^>]*>(.*?)</"#,
        r#"(?s)hg-play__panel-desc[^>]*>(.*?)</"#,
        r#"(?s)hg-drama-card__desc[^>]*>(.*?)</p>"#,
    ] {
        let re = Regex::new(pat).unwrap();
        if let Some(c) = re.captures(&html).and_then(|c| c.get(1)) {
            let v = strip_tags(c.as_str());
            if !v.is_empty() {
                synopsis = v;
                break;
            }
        }
    }
    if synopsis.is_empty() {
        let m_re = Regex::new(r#"<meta[^>]*name="description"[^>]*content="([^"]+)""#).unwrap();
        synopsis = first_group(&m_re, &html);
    }
    let pic_re = Regex::new(r#"<img[^>]*src="(https://pic\.drleao\.cn[^"]+)""#).unwrap();
    let mut cover = first_group(&pic_re, &html);
    if cover.is_empty() {
        let og_re = Regex::new(r#"<meta[^>]*property="og:image"[^>]*content="([^"]+)""#).unwrap();
        cover = first_group(&og_re, &html);
    }
    // 集数：取页面中含 data-ep-id / ep-item / ep-grid / /ep- 的 <a> 里的最大集号。
    let mut max_ep: i64 = 0;
    let ep_re =
        Regex::new(r#"(?s)<a[^>]*(?:data-ep-id|ep-item|ep-grid|/ep-)[^>]*>(.*?)</a>"#).unwrap();
    let num_re = Regex::new(r"(\d+)").unwrap();
    for cap in ep_re.captures_iter(&html) {
        let inner = cap.get(1).unwrap().as_str();
        let mut n: i64 = 0;
        if let Some(c) = Regex::new(r"data-ep-id[^0-9]*(\d+)")
            .unwrap()
            .captures(cap.get(0).unwrap().as_str())
        {
            n = c.get(1).unwrap().as_str().parse().unwrap_or(0);
        } else if let Some(c) = Regex::new(r"/ep-(\d+)")
            .unwrap()
            .captures(cap.get(0).unwrap().as_str())
        {
            n = c.get(1).unwrap().as_str().parse().unwrap_or(0);
        } else if let Some(c) = Regex::new(r"第\s*(\d+)\s*集").unwrap().captures(inner) {
            n = c.get(1).unwrap().as_str().parse().unwrap_or(0);
        } else if let Some(c) = num_re.captures(inner.trim()) {
            if inner.trim().chars().all(|ch| ch.is_ascii_digit()) {
                n = c.get(1).unwrap().as_str().parse().unwrap_or(0);
            }
        }
        if n > max_ep {
            max_ep = n;
        }
    }
    if max_ep == 0 {
        let u_re = Regex::new(r"更新至(\d+)集").unwrap();
        let f_re = Regex::new(r"全(\d+)集").unwrap();
        if let Some(c) = u_re.captures(&html).and_then(|c| c.get(1)) {
            max_ep = c.as_str().parse().unwrap_or(0);
        } else if let Some(c) = f_re.captures(&html).and_then(|c| c.get(1)) {
            max_ep = c.as_str().parse().unwrap_or(0);
        }
    }
    if max_ep == 0 {
        max_ep = 1;
    }
    let mut episodes: Vec<Value> = Vec::new();
    for n in 1..=max_ep {
        episodes.push(episode_json(&format!("{id}#{n}"), &format!("第{n}集"), id));
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover, "synopsis": synopsis,
        "extra": {}, "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = probe_base().await;
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let Some(html) = get_text(&format!("{base}/search/video/{enc}/")).await else {
        return Ok(json!({"items": []}));
    };
    // 先取 </header> 之后内容中 <a href="/video/<id>/">…</a>，再用 parseList 补封面。
    let after = html.split("</header>").nth(1).unwrap_or(&html);
    let a_re = Regex::new(r#"(?s)<a href="/video/(\d+)/">\s*(.*?)</a>"#).unwrap();
    let mut items: Vec<Value> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in a_re.captures_iter(after) {
        let id = cap.get(1).unwrap().as_str().to_string();
        let mut title = strip_tags(cap.get(2).unwrap().as_str());
        if title.ends_with("全集在线观看") {
            title = title.trim_end_matches("全集在线观看").trim().to_string();
        }
        if title.is_empty() {
            continue;
        }
        if let Some(cap2) = Regex::new(r"《([^》]+)》").unwrap().captures(&title) {
            title = cap2.get(1).unwrap().as_str().to_string();
        }
        if title.contains('黄') && title.contains('果') {
            continue;
        }
        if seen.insert(id.clone()) {
            items.push(item_json(&id, &title, "", ""));
        }
    }
    let listed = parse_list(&html);
    for it in items.iter_mut() {
        let id = it["id"].as_str().unwrap_or("").to_string();
        if let Some(l) = listed
            .iter()
            .find(|x| x["id"].as_str() == Some(id.as_str()))
        {
            if it["cover"].as_str().unwrap_or("").is_empty() {
                it["cover"] = l["cover"].clone();
            }
            if it["remark"].as_str().unwrap_or("").is_empty() {
                it["remark"] = l["remark"].clone();
            }
        }
    }
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (id, ep) = match video_id.split_once('#') {
        Some((a, b)) => (a, b),
        None => (video_id, "1"),
    };
    let base = probe_base().await;
    let url = format!("{base}/api/videos/{id}/play?ep={ep}");
    let Some(resp) = get_json(&url).await else {
        return Err(ApiError::Internal("huangguo play empty".into()));
    };
    if int_of(&resp, &["status"]) != 1 {
        return Err(ApiError::Internal("huangguo play status != 1".into()));
    }
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let video_url = text_of(&data, &["video_url"]);
    if video_url.is_empty() {
        return Err(ApiError::Internal("huangguo no video_url".into()));
    }
    let mut out = json!({
        "url": video_url,
        "header": {"User-Agent": UA, "Referer": format!("{base}/")},
    });
    if video_url.contains(".m3u8") {
        out["format"] = json!("application/x-mpegURL");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_card() {
        let html = r#"<div class="hg-drama-card"><a href="/video/123/"><img data-src="https://pic.drleao.cn/a.jpg"></a><div class="hg-drama-card__title"><a>测试剧</a></div><p class="hg-drama-card__desc">简介</p></div>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "123");
        assert_eq!(items[0]["title"], "测试剧");
        assert_eq!(items[0]["cover"], "https://pic.drleao.cn/a.jpg");
    }

    #[test]
    fn api_card_score_and_finish() {
        let v: Value = serde_json::from_str(
            r#"{"id":"7","title":"剧","cover":"c","score":8.5,"is_finished":true,"total_episodes":12}"#,
        )
        .unwrap();
        let card = api_card(&v).unwrap();
        assert_eq!(card["remark"], "8.5分 · 全12集");
    }

    #[test]
    fn cats_are_six() {
        assert_eq!(CATS.len(), 6);
    }

    #[tokio::test]
    #[ignore]
    async fn live_categories_and_catalog() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert_eq!(list.len(), 6);
        let home = catalog("", 1).await.unwrap();
        let items = home["items"].as_array().unwrap();
        eprintln!("LIVE huangguo cats=6 home_items={}", items.len());
        assert!(!items.is_empty(), "huangguo home catalog empty");
        assert!(!items[0]["id"].as_str().unwrap_or("").is_empty());
        let ai = catalog("/ai-duanju", 1).await.unwrap();
        assert!(
            !ai["items"].as_array().unwrap().is_empty(),
            "huangguo ai-duanju catalog empty"
        );
        eprintln!(
            "LIVE huangguo ai-duanju items={}",
            ai["items"].as_array().unwrap().len()
        );
    }
}
