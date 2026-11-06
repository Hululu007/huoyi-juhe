//! 520AV影城：`https://www.520avtv.com`（备 `https://520avtv.com`）。
//!
//! 来源 jar 类 `Zaka520avAmns`。列表卡片正则取
//! `/video/watch/<id>/<slug>` + alt 标题，封面
//! `https://imgs.520avtv.com/pic/<id>.jpg`；详情取 h1 标题、
//! meta description 简介、首个日期年份、演员徽章链接、m3u8
//!（`"url": "<...m3u8>"`）；分集为正片（m3u8 直链）与原頁
//!（`pc:<id>:<slug>`，核心自行抓 watch 页提 m3u8，不走壳嗅探）；
//! 搜索先取首页 csrf token 再 POST `/video/search`。
//!
//! 对照 jar 原文修的两处（2026-11-05 实测）：
//! 1. `t:new` 最新上映的地址不是 jar 字节码里的旧路径，实测
//!    `/video/newest/<页>` 才 200（`/video/new/` 404、
//!    `/video/category/new/1` 500、`/video/latest/1` 404），
//!    故写 `/video/newest/{page}`。
//! 2. 女优列表 `a:hot`：`/avactress/type/hot/<页>` 本机 200 但
//!    0 个演员链接（疑似站改版/JS 加载），而
//!    `/avactress/type/new/<页>` 同结构有 71 个演员链接；
//!    核心先取 hot 页，无结果时回退 new 页。
//! 3. 详情演员：jar 的 `P_ACTOR_NAME`（font-size-14 链接）
//!    在当前详情页命中 0，演员实际在
//!    `<a href=".../video/actor/<名>" class="badge badge-primary">`
//!    里，故按徽章链接提取。
//! 情色文学 `e:1` 为文章（无分集，详情回正文）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const SITES: &[&str] = &["https://www.520avtv.com", "https://520avtv.com"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATEGORIES: &[(&str, &str)] = &[
    ("t:new", "最新上映"),
    ("c:1", "中文字幕"),
    ("c:9", "無碼AV"),
    ("c:3", "人妻熟女"),
    ("c:242", "國產自拍"),
    ("c:7", "成人卡通"),
    ("a:hot", "★女優專區"),
    ("e:1", "★情色文學"),
];

/// 去 HTML 标签与空白。
fn strip_tags(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let out = tag_re.replace_all(s, " ");
    let out = out
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ");
    ws_re.replace_all(out.trim(), " ").to_string()
}

fn headers(base: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        (
            "Accept-Language".to_string(),
            "zh-TW,zh;q=0.9,en;q=0.8".to_string(),
        ),
        ("Referer".to_string(), format!("{base}/")),
    ]
}

async fn fetch_with(base: &str, path: &str) -> ApiResult<String> {
    let url = format!("{base}{path}");
    let mut req = client()?.get(&url);
    for (k, v) in headers(base) {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("520AV 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 抓页：先 www 域名，失败换裸域名。
async fn fetch_page(path: &str) -> ApiResult<(String, String)> {
    match fetch_with(SITES[0], path).await {
        Ok(body) => Ok((SITES[0].to_string(), body)),
        Err(e) => match fetch_with(SITES[1], path).await {
            Ok(body) => Ok((SITES[1].to_string(), body)),
            Err(_) => Err(e),
        },
    }
}

/// 视频卡片解析（jar `cards`）：id/slug/标题，封面按 id 拼。
fn parse_cards(html: &str, limit: usize) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let re = Regex::new(
        r#"href="https?://[A-Za-z0-9.]*520avtv\.com/video/watch/(\d+)/([^"/]+)"[^>]*>\s*<img[^>]*?alt="([^"]*)""#,
    )
    .unwrap();
    for c in re.captures_iter(html) {
        if limit > 0 && items.len() >= limit {
            break;
        }
        let (id, slug) = (c[1].to_string(), c[2].to_string());
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let title = strip_tags(&c[3]);
        if title.is_empty() {
            continue;
        }
        let cover = format!("https://imgs.520avtv.com/pic/{id}.jpg");
        items.push(item_json(&format!("w:{id}:{slug}"), &title, &cover, ""));
    }
    items
}

/// 女优列表解析：`/video/actor/<名>` 链接 + 链接文本为名。
fn parse_actors(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let re =
        Regex::new(r#"<a[^>]+href="[^"]*/video/actor/([^"']+)"[^>]*>([^<]{1,40})</a>"#).unwrap();
    for c in re.captures_iter(html) {
        let slug = c[1].trim().to_string();
        let name = strip_tags(&c[2]);
        if slug.is_empty() || name.is_empty() || seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        items.push(item_json(&format!("act:{slug}"), &name, "", ""));
    }
    items
}

/// 情色文学列表解析（jar `articles`）。
fn parse_articles(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let re =
        Regex::new(r#"href="(https?://[^"]*/article/content/erotica/(\d+))"[^>]*>\s*([^<]{2,80})"#)
            .unwrap();
    for c in re.captures_iter(html) {
        let id = c[2].to_string();
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let title = strip_tags(&c[3]);
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&format!("e:{id}"), &title, "", ""));
    }
    items
}

/// 详情页 m3u8（jar `P_M3U8`）。
fn find_m3u8(html: &str) -> String {
    let re = Regex::new(r#""url"\s*:\s*"(https?://[^"]+\.m3u8[^"]*)""#).unwrap();
    re.captures(html)
        .map(|c| c[1].to_string())
        .unwrap_or_default()
}

/// 详情解析：h1/简介/日期/演员徽章/分类/分集。
fn parse_video(html: &str, id: &str, slug: &str) -> Value {
    let h1_re =
        Regex::new(r#"(?s)<h1[^>]*class="[^"]*font-size-22[^"]*"[^>]*>\s*([^<]{1,120}?)\s*</h1>"#)
            .unwrap();
    let mut title = h1_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title>(.*?)</title>").unwrap();
        title = t_re
            .captures(html)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
        if let Some(pos) = title.find(" - ") {
            title = title[..pos].trim().to_string();
        }
    }
    let desc_re = Regex::new(r#"<meta[^>]*name="description"[^>]*content="([^"]*)""#).unwrap();
    let synopsis = desc_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    let date_re = Regex::new(r"(\d{4}-\d{2}-\d{2})").unwrap();
    let date = date_re
        .captures(html)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let actor_re = Regex::new(
        r#"<a[^>]+href="[^"]*/video/actor/([^"']+)"[^>]*class="[^"]*badge[^"]*"[^>]*>([^<]+)</a>"#,
    )
    .unwrap();
    let mut actors: Vec<String> = Vec::new();
    for c in actor_re.captures_iter(html) {
        let name = strip_tags(&c[2]);
        if !name.is_empty() && !actors.contains(&name) {
            actors.push(name);
        }
    }
    let cat_re = Regex::new(r#"/video/category/(\d+)"[^>]*>\s*([^<]{1,20}?)\s*<"#).unwrap();
    let mut cats: Vec<String> = Vec::new();
    for c in cat_re.captures_iter(html) {
        let name = strip_tags(&c[2]);
        if !name.is_empty() && !cats.contains(&name) {
            cats.push(name);
        }
    }
    let cover = format!("https://imgs.520avtv.com/pic/{id}.jpg");
    let m3u8 = find_m3u8(html);
    let mut episodes = Vec::new();
    if !m3u8.is_empty() {
        episodes.push(episode_json(&m3u8, "正片", &format!("w:{id}:{slug}")));
    }
    episodes.push(episode_json(
        &format!("pc:{id}:{slug}"),
        "原頁",
        &format!("w:{id}:{slug}"),
    ));
    let mut extra = serde_json::Map::new();
    if !date.is_empty() {
        extra.insert("date".to_string(), json!(date));
    }
    if !actors.is_empty() {
        extra.insert("actors".to_string(), json!(actors.join(", ")));
    }
    if !cats.is_empty() {
        extra.insert("area".to_string(), json!(cats.join(" / ")));
    }
    json!({
        "id": format!("w:{id}:{slug}"),
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    })
}

/// 文章详情：标题 + 正文（无分集）。
fn parse_article(html: &str, id: &str) -> Value {
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let mut title = h1_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title>(.*?)</title>").unwrap();
        title = t_re
            .captures(html)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
    }
    let body_re =
        Regex::new(r#"(?s)<div[^>]*class="[^"]*article-content[^"]*"[^>]*>(.*?)</div>"#).unwrap();
    let mut synopsis = body_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    if synopsis.is_empty() {
        let desc_re = Regex::new(r#"<meta[^>]*name="description"[^>]*content="([^"]*)""#).unwrap();
        synopsis = desc_re
            .captures(html)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
    }
    json!({
        "id": format!("e:{id}"),
        "title": title,
        "cover": "",
        "synopsis": synopsis,
        "extra": {},
        "episodes": [],
    })
}

/// 搜索：取首页 csrf → POST /video/search；无果则 GET 搜索页，
// 再无果则试演员页。
async fn search_items(query: &str) -> ApiResult<Vec<Value>> {
    let (base, home) = fetch_page("/").await?;
    let csrf_re = Regex::new(r#"name="csrf_520"\s+value="([^"]+)""#).unwrap();
    let token = csrf_re
        .captures(&home)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    if !token.is_empty() {
        let body = format!(
            "search={}&csrf_520={}",
            url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>(),
            url::form_urlencoded::byte_serialize(token.as_bytes()).collect::<String>(),
        );
        let mut req = client()?
            .post(format!("{base}/video/search"))
            .header("User-Agent", UA)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("Origin", base.clone())
            .header("Referer", format!("{base}/video/search"))
            .header("Cookie", format!("csrf_cookie_520={token}"))
            .body(body);
        let _ = &mut req;
        if let Ok(resp) = req.send().await {
            if resp.status().is_success() {
                if let Ok(text) = resp.text().await {
                    let items = parse_cards(&text, 0);
                    if !items.is_empty() {
                        return Ok(items);
                    }
                }
            }
        }
    }
    let enc: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    if let Ok((_, html)) = fetch_page(&format!("/video/search?search={enc}")).await {
        let items = parse_cards(&html, 0);
        if !items.is_empty() {
            return Ok(items);
        }
    }
    if let Ok((_, html)) = fetch_page(&format!("/video/actor/{enc}")).await {
        let items = parse_cards(&html, 0);
        if !items.is_empty() {
            return Ok(items);
        }
    }
    Ok(Vec::new())
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATEGORIES
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (items, has_more) = if category_id == "t:new" {
        let (_, html) = fetch_page(&format!("/video/newest/{page}")).await?;
        let items = parse_cards(&html, 0);
        (items, true)
    } else if let Some(cid) = category_id.strip_prefix("c:") {
        let (_, html) = fetch_page(&format!("/video/category/{cid}/{page}")).await?;
        let items = parse_cards(&html, 0);
        (items, true)
    } else if category_id == "a:hot" {
        let (_, html) = fetch_page(&format!("/avactress/type/hot/{page}")).await?;
        let mut items = parse_actors(&html);
        if items.is_empty() {
            // hot 页无演员链接时回退 new 页（站改版，见文件头）。
            let (_, html2) = fetch_page(&format!("/avactress/type/new/{page}")).await?;
            items = parse_actors(&html2);
        }
        (items, true)
    } else if let Some(name) = category_id.strip_prefix("act:") {
        let enc: String = url::form_urlencoded::byte_serialize(name.as_bytes()).collect();
        let (_, html) = fetch_page(&format!("/video/actor/{enc}/{page}")).await?;
        let items = parse_cards(&html, 0);
        (items, true)
    } else if category_id == "e:1" {
        let (_, html) = fetch_page(&format!("/article/erotica/{page}")).await?;
        let items = parse_articles(&html);
        (items, true)
    } else {
        (Vec::new(), false)
    };
    let has_more = has_more && !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(rest) = id.strip_prefix("w:") {
        let mut parts = rest.splitn(2, ':');
        let vid = parts.next().unwrap_or("");
        let slug = parts.next().unwrap_or("");
        if vid.is_empty() {
            return Err(ApiError::Internal("520AV 详情缺少编号".into()));
        }
        let (_, html) = fetch_page(&format!("/video/watch/{vid}/{slug}")).await?;
        return Ok(parse_video(&html, vid, slug));
    }
    if let Some(name) = id.strip_prefix("act:") {
        return Ok(json!({
            "id": id,
            "title": name,
            "cover": "",
            "synopsis": "女優作品集",
            "extra": {},
            "episodes": [],
        }));
    }
    if let Some(eid) = id.strip_prefix("e:") {
        let (_, html) = fetch_page(&format!("/article/content/erotica/{eid}")).await?;
        return Ok(parse_article(&html, eid));
    }
    Err(ApiError::Internal("520AV 详情编号格式错误".into()))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let items = search_items(query).await?;
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    if let Some(rest) = video_id.strip_prefix("pc:") {
        let mut parts = rest.splitn(2, ':');
        let vid = parts.next().unwrap_or("");
        let slug = parts.next().unwrap_or("");
        let (_, html) = fetch_page(&format!("/video/watch/{vid}/{slug}")).await?;
        let m3u8 = find_m3u8(&html);
        if m3u8.is_empty() {
            return Err(ApiError::Internal("520AV 未找到播放地址".into()));
        }
        return Ok(json!({"url": m3u8}));
    }
    Err(ApiError::Internal("520AV 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_dedup() {
        let html = r#"<a href="https://www.520avtv.com/video/watch/6788463/MTALL-105"><img alt="测试标题"></a><a href="https://www.520avtv.com/video/watch/6788463/MTALL-105"><img alt="测试标题"></a><a href="https://520avtv.com/video/watch/123/ABC-1"><img alt="第二条"></a>"#;
        let items = parse_cards(html, 0);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "w:6788463:MTALL-105");
        assert_eq!(
            items[0]["cover"],
            "https://imgs.520avtv.com/pic/6788463.jpg"
        );
    }

    #[test]
    fn find_m3u8_url() {
        let html = r#"{"url": "https://lovebb.520avtv.com/freevideo/abc123.m3u8?x=1"}"#;
        assert_eq!(
            find_m3u8(html),
            "https://lovebb.520avtv.com/freevideo/abc123.m3u8?x=1"
        );
    }

    #[test]
    fn parse_video_fields() {
        let html = r#"<h1 class="font-size-22">G罩杯测试标题</h1><meta name="description" content="简介文字"><a href="https://www.520avtv.com/video/actor/五日市芽依" class="badge badge-primary">五日市芽依</a><a href="/video/category/3">人妻熟女</a><span>2024-03-18</span>{"url": "https://lovebb.520avtv.com/freevideo/abc.m3u8"}"#;
        let detail_value = parse_video(html, "6788463", "MTALL-105");
        assert_eq!(detail_value["title"], "G罩杯测试标题");
        assert_eq!(detail_value["synopsis"], "简介文字");
        let eps = detail_value["episodes"].as_array().unwrap();
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0]["title"], "正片");
        assert_eq!(eps[1]["video_id"], "pc:6788463:MTALL-105");
    }

    #[test]
    fn parse_actors_links() {
        let html = r#"<a href="https://www.520avtv.com/video/actor/五日市芽依">五日市芽依</a><a href="/video/actor/松本流佳">松本流佳</a>"#;
        let items = parse_actors(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "act:五日市芽依");
    }
}
