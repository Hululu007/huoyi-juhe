//! 黄果短剧：HTML 站（huangguoai.com），列表走 ZakaCard 解析
//! （hg-drama-card 块），详情走 /video/<id>/，取流走集页的
//! epPlaySrcs JSON blob（current.src/srcHevc → videoSrc →
//! 编号最大的分集地址），封面字节可能为 AES 加密（jar 的
//! ZakaDrama.picOpen），核心返回原地址，待手机侧验证。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of};

const HOST: &str = "https://huangguoai.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 4 个一级分类：路径。
const CLASSES: &[(&str, &str)] = &[
    ("/ai-duanju/", "AI成人短剧"),
    ("/ai-manju/", "AI漫剧"),
    ("/ai-huanlian/", "AI换脸"),
    ("/ai-mogai/", "AI魔改"),
];

/// 22 个题材 filter：slug → /tag/<slug>/，核心里做成分类以便到达。
const TAGS: &[(&str, &str)] = &[
    ("dushi", "都市"),
    ("xiaoyuan", "校园"),
    ("xuanyi", "悬疑"),
    ("gufeng", "古风"),
    ("gongting", "宫廷"),
    ("quanmou", "权谋"),
    ("qingchun", "青春"),
    ("xiandai", "现代"),
    ("shunv", "熟女"),
    ("lvmao", "绿帽"),
    ("danvzhu", "单女主"),
    ("dananzhu", "单男主"),
    ("muzi", "母子"),
    ("nianxia", "年下"),
    ("hougong", "后宫"),
    ("sangshi", "丧尸"),
    ("naodong", "脑洞"),
    ("nuelian", "虐恋"),
    ("zhichang", "职场"),
    ("xitong", "系统"),
    ("youxi", "游戏"),
    ("haomen", "豪门"),
];

fn ep_id_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"data-ep-id="(\d{1,4})""#).unwrap())
}

fn ep_url_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/video/(\d+)/ep-(\d{1,4})/").unwrap())
}

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https?://[^\s"'<>]+\.m3u8"#).unwrap())
}

fn href_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"href="((?:/drama/|/novel/|/video/|https?://[^"]*/(?:drama|novel|video)/)[0-9][^"]*)""#).unwrap()
    })
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
        return Err(ApiError::Internal(format!("黄果短剧请求 HTTP {status}")));
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

fn class_text(block: &str, class: &str) -> String {
    let marker = format!("class=\"{class}\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
    strip_tags(&after[s..e])
}

/// 封面：按优先级取，排除占位图。
fn pick_cover(block: &str) -> String {
    for key in ["data-src", "data-original", "data-lazy-src"] {
        let v = attr(block, key);
        if valid_cover(&v) {
            return v;
        }
    }
    if let Some(p) = block.find("<img") {
        let after = &block[p..];
        if let Some(s) = after.find("src=\"") {
            let s = s + 5;
            if let Some(e) = after[s..].find('"') {
                let v = &after[s..s + e];
                if valid_cover(v) {
                    return v.to_string();
                }
            }
        }
    }
    String::new()
}

fn valid_cover(v: &str) -> bool {
    if v.is_empty() || v.starts_with("data:") {
        return false;
    }
    let low = v.to_lowercase();
    if low.contains("loading")
        || low.contains("placeholder")
        || low.contains("no_preview")
        || low.contains("drama-loading")
    {
        return false;
    }
    if low.contains("/static/") && !low.contains("/upload") {
        return false;
    }
    low.contains(".jpg")
        || low.contains(".jpeg")
        || low.contains(".png")
        || low.contains(".webp")
        || low.contains(".avif")
        || low.contains("img")
}

/// ZakaCard.parse：hg-drama-card 块解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    // 按 `hg-drama-card"` 切块：卡片内还有 hg-drama-card__episode /
    // __body 等子类名，裸切 "hg-drama-card" 会把一张卡切碎、备注
    // 丢失；带右引号只命中外层 div 的 class="hg-drama-card"。
    for block in html.split("hg-drama-card\"").skip(1) {
        let href = href_re()
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        if href.is_empty() {
            continue;
        }
        let mut title = attr(block, "data-track-item-name");
        if title.is_empty() {
            title = tag_text(block, "h3");
        }
        if title.is_empty() {
            title = tag_text(block, "h2");
        }
        if title.is_empty() {
            title = class_text(block, "sr-only");
        }
        if title.is_empty() {
            title = attr(block, "alt");
        }
        if title.is_empty() {
            continue;
        }
        let cover = pick_cover(block);
        let mut remark = class_text(block, "hg-drama-card__episode");
        if remark.is_empty() {
            remark = class_text(block, "eps-flag");
        }
        if remark.is_empty() {
            remark = class_text(block, "score");
        }
        if remark.is_empty() {
            remark = class_text(block, "small");
        }
        if remark.is_empty() {
            remark = class_text(block, "badge");
        }
        if remark.is_empty() {
            remark = "AI短剧".to_string();
        }
        let id = if href.starts_with("http") {
            href.clone()
        } else {
            href.clone()
        };
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

/// 找含 key 的最近 {...} 对象并解析。
fn blob(html: &str, key: &str) -> Option<Value> {
    let pos = html.find(key)?;
    let bytes = html.as_bytes();
    let mut i = pos;
    while i > 0 {
        i -= 1;
        if bytes[i] != b'{' {
            continue;
        }
        // 从该 { 起找匹配的 }（处理字符串与转义）。
        let mut depth = 0;
        let mut j = i;
        let mut in_str = false;
        let mut esc = false;
        let mut end = None;
        while j < bytes.len() {
            let b = bytes[j];
            if in_str {
                if esc {
                    esc = false;
                } else if b == b'\\' {
                    esc = true;
                } else if b == b'"' {
                    in_str = false;
                }
            } else if b == b'"' {
                in_str = true;
            } else if b == b'{' {
                depth += 1;
            } else if b == b'}' {
                depth -= 1;
                if depth == 0 {
                    end = Some(j);
                    break;
                }
            }
            j += 1;
        }
        let Some(e) = end else { continue };
        if let Ok(v) = serde_json::from_str::<Value>(&html[i..=e]) {
            if html[i..=e].contains(key) {
                return Some(v);
            }
        }
    }
    None
}

/// epPlaySrcs blob 里取最佳播放地址。
fn best_src(obj: &Value) -> String {
    if let Some(cur) = get(obj, "current") {
        let s = text_of(cur, &["src", "srcHevc"]);
        if !s.is_empty() {
            return s;
        }
    }
    let v = text_of(obj, &["videoSrc"]);
    if !v.is_empty() {
        return v;
    }
    if let Some(eps) = get(obj, "epPlaySrcs") {
        let mut best_n = -1i64;
        let mut best = String::new();
        if let Some(m) = eps.as_object() {
            // epPlaySrcs 里也可能有 "current" 对象（current.src /
            // srcHevc），先取它，再按当前集号、最后按最大编号兜底。
            if let Some(cur) = m.get("current") {
                let s = text_of(cur, &["src", "srcHevc"]);
                if !s.is_empty() {
                    return s;
                }
            }
            // 当前集优先：blob 同对象里的 "ep" 即当前集号；无该号时
            // 再取编号最大的分集（旧兜底）。
            let want = obj.get("ep").and_then(|v| v.as_i64());
            if let Some(n) = want {
                if let Some(val) = m.get(&n.to_string()) {
                    let s = super::str_of(val);
                    if !s.is_empty() {
                        return s;
                    }
                }
            }
            for (k, val) in m {
                if let Ok(n) = k.parse::<i64>() {
                    let s = super::str_of(val);
                    if n > best_n && !s.is_empty() {
                        best_n = n;
                        best = s;
                    }
                }
            }
        }
        if !best.is_empty() {
            return best;
        }
    }
    String::new()
}

fn abs_url(path: &str) -> String {
    if path.starts_with("http") {
        path.to_string()
    } else if path.starts_with('/') {
        format!("{HOST}{path}")
    } else {
        format!("{HOST}/{path}")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (path, name) in CLASSES {
        list.push(category_json(path, name));
    }
    for (slug, name) in TAGS {
        list.push(category_json(&format!("t:{slug}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = if let Some(slug) = category_id.strip_prefix("t:") {
        format!("/tag/{slug}/")
    } else {
        category_id.to_string()
    };
    let url = if page > 1 {
        format!("{}{}{}/", HOST, path.trim_end_matches('/'), page)
    } else {
        format!("{HOST}{path}")
    };
    let html = fetch(&url).await?;
    let items = parse_cards(&html);
    let has_more = items.len() >= 18;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = abs_url(series_id);
    let html = fetch(&url).await?;
    let mut title = tag_text(&html, "h1");
    if title.is_empty() {
        title = og(&html, "og:title");
    }
    if let Some(p) = title.find('《') {
        if let Some(e) = title[p..].find('》') {
            title = title[p + 3..p + e].to_string();
        }
    }
    if let Some(p) = title.find('|') {
        title = title[..p].trim().to_string();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("黄果短剧未返回影片资料".into()));
    }
    let mut cover = String::new();
    for key in ["posterSrc", "coverSrc"] {
        let marker = format!("\"{key}\":\"");
        if let Some(p) = html.find(&marker) {
            let s = p + marker.len();
            if let Some(e) = html[s..].find('"') {
                cover = html[s..s + e].to_string();
                break;
            }
        }
    }
    if cover.is_empty() {
        cover = og(&html, "og:image");
    }
    if cover.contains("cover-placeholder") {
        cover.clear();
    }
    let mut desc = String::new();
    if let Some(p) = html.find("description") {
        let after = &html[p..];
        if let Some(c) = after.find("content=\"") {
            let s = c + 9;
            if let Some(e) = after[s..].find('"') {
                desc = after[s..s + e].to_string();
            }
        }
    }
    if desc.is_empty() {
        desc = og(&html, "og:description");
    }
    let vid = series_id
        .trim_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(series_id)
        .to_string();
    let mut eps: Vec<i64> = ep_id_re()
        .captures_iter(&html)
        .filter_map(|c| c[1].parse::<i64>().ok())
        .collect();
    if eps.is_empty() {
        eps = ep_url_re()
            .captures_iter(&html)
            .filter_map(|c| c[2].parse::<i64>().ok())
            .collect();
    }
    eps.sort_unstable();
    eps.dedup();
    if eps.is_empty() {
        eps.push(1);
    }
    let mut episodes: Vec<Value> = Vec::new();
    for n in &eps {
        let ep_url = if *n == 1 {
            format!("{HOST}/video/{vid}/")
        } else {
            format!("{HOST}/video/{vid}/ep-{n}/")
        };
        episodes.push(episode_json(&ep_url, &format!("第{n}集"), series_id));
    }
    let mut remark = format!("共 {} 集", eps.len());
    if html.contains("已更新至") {
        if let Some(p) = html.find("已更新至") {
            let after = &html[p..p + 40.min(html.len() - p)];
            let e = after.find('<').unwrap_or(after.len());
            remark = strip_tags(&after[..e]);
        }
    }
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

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let html = fetch(video_id).await?;
    let mut url = String::new();
    if let Some(obj) = blob(&html, "epPlaySrcs") {
        url = best_src(&obj);
    }
    if url.is_empty() {
        if let Some(p) = html.find("videoSrc") {
            let after = &html[p..];
            let marker = "\"videoSrc\":\"";
            if let Some(q) = after.find(marker) {
                let s = q + marker.len();
                if let Some(e) = after[s..].find('"') {
                    url = after[s..s + e].to_string();
                }
            }
        }
    }
    if url.is_empty() {
        url = m3u8_re()
            .captures(&html)
            .and_then(|c| c.get(0))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }
    if url.is_empty() {
        return Err(ApiError::Internal("黄果短剧未取到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": video_id},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/?keyword={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_finds_object() {
        let html = r#"xx {"a":1,"epPlaySrcs":{"current":{"src":"https://x/1.m3u8"}}} yy"#;
        let obj = blob(html, "epPlaySrcs").unwrap();
        assert_eq!(best_src(&obj), "https://x/1.m3u8");
    }

    #[test]
    fn best_src_prefers_current_ep() {
        let obj = json!({"ep": 2, "epPlaySrcs": {"1": "https://x/1.m3u8", "3": "https://x/3.m3u8", "2": "https://x/2.m3u8"}});
        assert_eq!(best_src(&obj), "https://x/2.m3u8");
    }

    #[test]
    fn best_src_max_numbered() {
        let obj = json!({"epPlaySrcs": {"1": "https://x/1.m3u8", "3": "https://x/3.m3u8", "2": "https://x/2.m3u8"}});
        assert_eq!(best_src(&obj), "https://x/3.m3u8");
    }

    #[test]
    fn parse_cards_block() {
        let html = r#"<div class="hg-drama-card"><a href="/video/123/"><img data-src="/c.jpg"><h3>剧名一</h3><span class="hg-drama-card__episode">共10集</span></a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "剧名一");
        assert_eq!(items[0]["remark"], "共10集");
    }
}
