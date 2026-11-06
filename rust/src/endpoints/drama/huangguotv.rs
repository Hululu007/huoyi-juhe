//! 🔞黄果TV短剧：huangguotv.com，独立站，不与黄果短剧 hgdj、
//! 黄果短剧V hgdjv、新黄果短剧 aimove、黄果 huangguo 合并。
//!
//! 去重实测（2026-11-06）：本站为 SSR（seo-fallback-grid 卡片，
//! 导航 /category/33、/videos/ai|latest|popular、详情
//! /video/<id>），页内无 hg-drama-card；huangguo 系的
//! /api/videos/category 在本站回 404；封面与流均走
//! media.huangguotv.com；JSON-LD 标 1341 部。列表 24 条/页，
//! 其中少数卡片封面为站内默认图（/static/images/resource/…，
//! 详情页 og:image 才是真封面），列表原样返回。
//! 取流（VIP 墙绕行，实测）：会员锁只在前端 JS 层
//! （episode-vip-inline-membership 弹锁层“本剧需要会员后观看”，
//! 以 preview_episode 控第几集起锁），CDN 流地址按
//! https://media.huangguotv.com/hls/<id>/epNNN/master.m3u8
//! 规律排布、匿名直取：1654747 的 ep001/002/008 与 222234 的
//! ep002/006 清单均为 200、无 EXT-X-KEY、全长（168.3 / 191.8 /
//! 267.1 / 255.3 秒），首分片 200 + TS 魔数 0x47。play() 先取
//! 详情页 JSON-LD 的 contentUrl 再改集号，取不到时直接拼
//! 规律地址。
//! 搜索走 SPA 接口 /api/search（bundle 内参数 keyword/page/
//! pageSize/sortBy/sortOrder，code==1 时取 data.list；本站出口
//! 间歇超时，失败时如实报错）。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, str_of, text_of};

const HOST: &str = "https://huangguotv.com";
const MEDIA: &str = "https://media.huangguotv.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 24;

/// 5 个一级分类：站导航 1:1。
const CATS: &[(&str, &str)] = &[
    ("home", "首页"),
    ("33", "成人短剧"),
    ("ai", "AI短剧"),
    ("latest", "最新短剧"),
    ("popular", "热门短剧"),
];

fn card_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"href="/video/(\d+)""#).unwrap())
}

fn ep_link_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"href="/video/(\d+)\?ep=(\d+)""#).unwrap())
}

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https?://[^\s"'<>]+\.m3u8"#).unwrap())
}

async fn fetch(url: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("黄果TV短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
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
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn attr(block: &str, name: &str) -> String {
    let marker = format!("{name}=\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    block[s..]
        .find('"')
        .map(|e| block[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(block: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = block.find(&open) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

fn clean_title(t: &str) -> String {
    let mut s = t.trim().to_string();
    if let Some(p) = s.find('｜') {
        s = s[..p].trim().to_string();
    }
    if let Some(p) = s.find('|') {
        s = s[..p].trim().to_string();
    }
    s
}

/// seo-fallback-card 卡片解析：标题取 h2 文本（干净），alt 兜底；
/// 封面取 img src；备注取 span 文本（“N 集 · M 次播放”）。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for block in html.split("<article class=\"seo-fallback-card\"").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let Some(cap) = card_re().captures(block) else {
            continue;
        };
        let id = cap[1].to_string();
        let mut title = tag_text(block, "h2");
        if title.is_empty() {
            title = clean_title(&attr(block, "alt"));
        } else {
            title = clean_title(&title);
        }
        if title.is_empty() {
            continue;
        }
        let cover = attr(block, "src");
        let remark = tag_text(block, "span");
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn og(html: &str, prop: &str) -> String {
    let marker = format!("property=\"{prop}\"");
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
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn meta_name(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\"");
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
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

/// 集号 → 规律流地址：/hls/<id>/epNNN/master.m3u8。
fn hls_url(series_id: &str, ep: i64) -> String {
    format!("{MEDIA}/hls/{series_id}/ep{:03}/master.m3u8", ep.max(1))
}

/// 详情页 JSON-LD 的 contentUrl（第 1 集地址）改集号；改不动
/// 时返回原地址。
fn reep(content_url: &str, ep: i64) -> String {
    if content_url.is_empty() {
        return String::new();
    }
    let re = Regex::new(r"/ep\d{3}/").unwrap();
    if re.is_match(content_url) {
        return re
            .replace(content_url, format!("/ep{:03}/", ep.max(1)))
            .to_string();
    }
    content_url.to_string()
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let base = match category_id {
        "home" | "" => HOST.to_string(),
        "33" => format!("{HOST}/category/33"),
        "ai" | "latest" | "popular" => format!("{HOST}/videos/{category_id}"),
        _ => HOST.to_string(),
    };
    if page > 1 {
        format!("{base}?page={page}")
    } else {
        base
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url).await?;
    let items = parse_cards(&html);
    let has_more = items.len() >= PAGE_SIZE as usize;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = format!("{HOST}/video/{series_id}");
    let html = fetch(&url).await?;
    let mut title = tag_text(&html, "h1");
    if title.is_empty() {
        title = clean_title(&og(&html, "og:title"));
    }
    if title.is_empty() {
        title = clean_title(&tag_text(&html, "title"));
    }
    if title.is_empty() {
        return Err(ApiError::Internal("黄果TV短剧未返回影片资料".into()));
    }
    let cover = og(&html, "og:image");
    let mut desc = meta_name(&html, "description");
    if desc.is_empty() {
        desc = og(&html, "og:description");
    }
    let mut eps: Vec<i64> = ep_link_re()
        .captures_iter(&html)
        .filter(|c| c.get(1).map(|m| m.as_str()) == Some(series_id))
        .filter_map(|c| c[2].parse::<i64>().ok())
        .collect();
    eps.sort_unstable();
    eps.dedup();
    if eps.is_empty() {
        eps.push(1);
    }
    let mut episodes: Vec<Value> = Vec::new();
    for n in &eps {
        episodes.push(episode_json(
            &format!("{series_id}:{n}"),
            &format!("第{n}集"),
            series_id,
        ));
    }
    let remark = format!("共 {} 集", eps.len());
    let mut extra = serde_json::Map::new();
    extra.insert("remark".to_string(), json!(remark));
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

fn search_card(v: &Value) -> Option<Value> {
    let id = int_of(v, &["id", "videoId"]);
    if id == 0 {
        return None;
    }
    let title = clean_title(&text_of(v, &["title", "name"]));
    if title.is_empty() {
        return None;
    }
    let cover = text_of(v, &["coverUrl", "cover", "image", "pic"]);
    let total = int_of(v, &["episodeCount", "totalEpisodes", "episodes"]);
    let views = int_of(v, &["viewsCount", "viewCount", "plays"]);
    let remark = if total > 0 && views > 0 {
        format!("{total}集 · {views}播放")
    } else if total > 0 {
        format!("{total}集")
    } else {
        String::new()
    };
    Some(item_json(&id.to_string(), &title, &cover, &remark))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/api/search?keyword={}&page=1&pageSize=24&sortBy=created_at&sortOrder=desc",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let req = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "黄果TV短剧搜索请求 HTTP {status}"
        )));
    }
    let value: Value = serde_json::from_str(&text)
        .map_err(|_| ApiError::Internal("黄果TV短剧搜索返回非 JSON".into()))?;
    if get(&value, "code").and_then(|v| v.as_i64()) != Some(1) {
        return Err(ApiError::Internal("黄果TV短剧搜索接口未返回成功".into()));
    }
    let data = get(&value, "data").cloned().unwrap_or(Value::Null);
    let list: &[Value] = if let Some(a) = get(&data, "list").and_then(arr_of) {
        a
    } else if let Some(a) = data.as_array() {
        a
    } else {
        &[]
    };
    let items: Vec<Value> = list.iter().filter_map(search_card).collect();
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let (series_id, ep) = match video_id.split_once(':') {
        Some((s, e)) => (s.to_string(), e.parse::<i64>().unwrap_or(1)),
        None => (video_id.to_string(), 1),
    };
    // 先取详情页 JSON-LD 的 contentUrl 再改集号；详情页取不到
    // 时直接拼规律地址（该地址匿名可取，已实测）。
    let mut url = String::new();
    if let Ok(html) = fetch(&format!("{HOST}/video/{series_id}")).await {
        if let Some(cap) = m3u8_re().captures(&html) {
            url = reep(cap.get(0).map(|m| m.as_str()).unwrap_or(""), ep);
        }
    }
    if url.is_empty() {
        url = hls_url(&series_id, ep);
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD_HTML: &str = r#"<div class="seo-fallback-grid"><article class="seo-fallback-card"><img src="https://media.huangguotv.com/5b0d0b492d3641e9b89068ee7d7c65c1-auto-cover.jpg" alt="《爸爸出差那几天》1-8 妈妈阿姨妹妹操了个遍" width="240" height="135" loading="lazy" decoding="async"><div class="seo-fallback-card__body"><h2><a href="/video/1654747">《爸爸出差那几天》1-8 妈妈阿姨妹妹操了个遍</a></h2><p>全剧在线播放</p><span>8 集 · 1,564 次播放</span></div></article><article class="seo-fallback-card"><img src="https://media.huangguotv.com/fddd4225a8884957af58c1119693a589-auto-cover.jpg" alt="《禁忌的刺激》第1-7集" width="240" height="135" loading="lazy" decoding="async"><div class="seo-fallback-card__body"><h2><a href="/video/1654737">《禁忌的刺激》第1-7集</a></h2><p>简介</p><span>7 集 · 305 次播放</span></div></article></div>"#;

    const SEARCH_JSON: &str = r#"{"code":1,"data":{"total":2,"list":[{"id":1654747,"title":"《爸爸出差那几天》1-8 妈妈阿姨妹妹操了个遍","coverUrl":"https://media.huangguotv.com/5b0d0b492d3641e9b89068ee7d7c65c1-auto-cover.jpg","episodeCount":8,"viewsCount":1564},{"id":222234,"title":"滴滴代操","coverUrl":"https://media.huangguotv.com/x.jpg","episodeCount":6,"viewsCount":99000}]}}"#;

    #[test]
    fn parse_cards_real_snippet() {
        let items = parse_cards(CARD_HTML);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "1654747");
        assert_eq!(
            items[0]["title"],
            "《爸爸出差那几天》1-8 妈妈阿姨妹妹操了个遍"
        );
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://media.huangguotv.com/"));
        assert_eq!(items[0]["remark"], "8 集 · 1,564 次播放");
        assert_eq!(items[1]["id"], "1654737");
    }

    #[test]
    fn hls_url_pads_episode() {
        assert_eq!(
            hls_url("1654747", 2),
            "https://media.huangguotv.com/hls/1654747/ep002/master.m3u8"
        );
        assert_eq!(
            hls_url("222234", 8),
            "https://media.huangguotv.com/hls/222234/ep008/master.m3u8"
        );
    }

    #[test]
    fn reep_rewrites_first_episode_url() {
        let u = "https://media.huangguotv.com/hls/1654747/ep001/master.m3u8";
        assert_eq!(
            reep(u, 8),
            "https://media.huangguotv.com/hls/1654747/ep008/master.m3u8"
        );
        assert_eq!(reep("", 2), "");
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(catalog_url("home", 1), "https://huangguotv.com");
        assert_eq!(catalog_url("home", 2), "https://huangguotv.com?page=2");
        assert_eq!(catalog_url("33", 1), "https://huangguotv.com/category/33");
        assert_eq!(
            catalog_url("ai", 3),
            "https://huangguotv.com/videos/ai?page=3"
        );
    }

    #[test]
    fn search_cards_from_bundle_shape() {
        let v: Value = serde_json::from_str(SEARCH_JSON).unwrap();
        let data = get(&v, "data").unwrap();
        let list = get(data, "list").and_then(arr_of).unwrap();
        let items: Vec<Value> = list.iter().filter_map(search_card).collect();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "1654747");
        assert_eq!(items[0]["remark"], "8集 · 1564播放");
        assert_eq!(items[1]["title"], "滴滴代操");
    }

    #[test]
    fn episode_links_dedupe() {
        let html = r#"<a href="/video/1654747?ep=1">第1集</a><a href="/video/1654747?ep=2">第2集</a><a href="/video/1654747?ep=1">第1集</a><a href="/video/222234?ep=1">别剧</a>"#;
        let mut eps: Vec<i64> = ep_link_re()
            .captures_iter(html)
            .filter(|c| c.get(1).map(|m| m.as_str()) == Some("1654747"))
            .filter_map(|c| c[2].parse::<i64>().ok())
            .collect();
        eps.sort_unstable();
        eps.dedup();
        assert_eq!(eps, vec![1, 2]);
    }
}
