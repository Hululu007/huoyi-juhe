//! 🔞JAV目錄：javmenu.com 的 HTML 站。
//!
//! 与 jar 的 ZakaJmAmns 一一对应：8 分类（有码/无码/欧美/FC2/
//! 中文在线、有码/无码系列、有码排行）、目录（番号卡片解析，
//! ?page=N 翻页）、详情（og 标题封面、data-m3u8 等属性取流、
//! 逐条探活后按活线排前）、搜索、取流（按 ?ln=N 取第 N 条线、
//! 取 master 清单里码率最大的 variant、无流时找非广告 iframe
//! 再取流、最后兜底详情页）。
//! 验门（2026-11-05 请求复现）：/censored/online 23 条带真封面、
//! 翻页 15 条、详情 CAWD-958、取流 3 条 m3u8 首条首分片 200、
//! 搜索 23 条全过。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javmenu.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
}

fn abs_url(href: &str) -> String {
    let href = href.trim();
    if href.starts_with("//") {
        return format!("https:{href}");
    }
    if href.starts_with("http") {
        return href.to_string();
    }
    if let Some(rest) = href.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{href}")
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAV目錄请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 与 Java 的 parseCards 一致：按番号链接分块，逐块取标题、
/// 副标题、封面、日期、标签。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let Ok(href_re) = Regex::new("href=\"(https?://javmenu\\.com/([A-Za-z0-9]+-\\d{2,6}))\"")
    else {
        return items;
    };
    let matches: Vec<(usize, usize, String)> = href_re
        .captures_iter(page)
        .map(|cap| {
            let m = cap.get(0).unwrap();
            (m.start(), m.end(), cap[2].to_string())
        })
        .collect();
    let mut seen: Vec<String> = Vec::new();
    for (i, (start, _end, code)) in matches.iter().enumerate() {
        if seen.contains(code) {
            continue;
        }
        seen.push(code.clone());
        let stop = if i + 1 < matches.len() {
            matches[i + 1].0
        } else {
            (*start + 6000).min(page.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &page[*start..stop];
        let mut title = pick(chunk, "(?s)<h5[^>]*>(.*?)</h5>");
        let sub = pick(chunk, "(?s)<p class=\"card-text\"[^>]*>(.*?)</p>");
        if title.is_empty() {
            title = code.clone();
        } else if !sub.is_empty() && !title.contains(&sub) {
            title = format!("{title} {sub}");
        }
        let mut pic = pick(chunk, "(?i)<img[^>]+data-src=\"([^\"]+)\"");
        if pic.is_empty() {
            pic = pick(chunk, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let pic = if pic.starts_with("http") || pic.starts_with("//") {
            abs_url(&pic)
        } else {
            String::new()
        };
        let date = pick(chunk, "(?s)<span class=\"text-muted\"[^>]*>(.*?)</span>");
        let mut remark = date.clone();
        let badge_re = Regex::new("(?s)class=\"badge[^\"]*\"[^>]*>([^<]{1,30})<").unwrap();
        let mut badges: Vec<String> = Vec::new();
        for cap in badge_re.captures_iter(chunk) {
            let b = strip_tags(&cap[1]);
            if b.is_empty()
                || b.contains("在線看")
                || b.contains("歡迎查詢")
                || b.contains("安全")
                || b.contains("可靠")
            {
                continue;
            }
            if !badges.contains(&b) {
                badges.push(b);
            }
            if badges.len() >= 5 {
                break;
            }
        }
        if remark.is_empty() && !badges.is_empty() {
            remark = badges.join(" ");
        }
        let href = format!("{HOST}/{code}");
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

/// 与 Java 的 pickStreams 一致：从 data-m3u8/data-src/data-video/
/// data-url/data-file/data-source 属性、键名与裸 .m3u8 地址里取流。
fn pick_streams(page: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let attrs = [
        "data-m3u8",
        "data-src",
        "data-video",
        "data-url",
        "data-file",
        "data-source",
    ];
    for attr in attrs {
        let pattern = format!("{attr}=\"([^\"]+\\.m3u8[^\"]*)\"");
        if let Ok(re) = Regex::new(&pattern) {
            for cap in re.captures_iter(page) {
                let u = abs_url(&cap[1]);
                if !out.contains(&u) {
                    out.push(u);
                }
            }
        }
    }
    let keys = [
        "file", "url", "src", "source", "video", "m3u8", "videoUrl", "playUrl", "play_url",
    ];
    for key in keys {
        let pattern = format!("\"{key}\"\\s*:\\s*\"([^\"]+\\.m3u8[^\"]*)\"");
        if let Ok(re) = Regex::new(&pattern) {
            for cap in re.captures_iter(page) {
                let u = abs_url(&cap[1]);
                if !out.contains(&u) {
                    out.push(u);
                }
            }
        }
    }
    if let Ok(re) = Regex::new("(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)") {
        for cap in re.captures_iter(page) {
            let u = cap[1].to_string();
            if !out.contains(&u) {
                out.push(u);
            }
        }
    }
    out
}

/// 与 Java 的 liveSort 一致：逐条探活（GET 5 秒，看 #EXTM3U
/// 或 #EXTINF），活线排前，死线留后。
async fn live_sort(streams: Vec<String>) -> (Vec<String>, Vec<bool>) {
    let probe = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());
    let mut alive: Vec<String> = Vec::new();
    let mut dead: Vec<String> = Vec::new();
    for url in streams.iter().take(8) {
        let ok = match probe.get(url).send().await {
            Ok(resp) => {
                if resp.status().as_u16() >= 400 {
                    false
                } else {
                    match resp.text().await {
                        Ok(text) => text.contains("#EXTM3U") || text.contains("#EXTINF"),
                        Err(_) => false,
                    }
                }
            }
            Err(_) => false,
        };
        if ok {
            alive.push(url.clone());
        } else {
            dead.push(url.clone());
        }
    }
    let mut sorted = alive.clone();
    sorted.extend(dead.iter().cloned());
    let mut flags = vec![true; alive.len()];
    flags.extend(vec![false; dead.len()]);
    (sorted, flags)
}

/// 与 Java 的 topVariant 一致：master 清单里取 BANDWIDTH 最大
/// 的分流地址。
async fn top_variant(master: &str) -> String {
    let Ok(c) = client() else {
        return master.to_string();
    };
    let Ok(resp) = c.get(master).header("User-Agent", UA).send().await else {
        return master.to_string();
    };
    let Ok(text) = resp.text().await else {
        return master.to_string();
    };
    if !text.contains("#EXT-X-STREAM-INF") {
        return master.to_string();
    }
    let bw_re = Regex::new("BANDWIDTH=(\\d+)").unwrap();
    let mut best_bw: i64 = -1;
    let mut best_uri: Option<String> = None;
    let lines: Vec<&str> = text.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        if line.contains("#EXT-X-STREAM-INF") {
            if let Some(cap) = bw_re.captures(line) {
                let bw: i64 = cap[1].parse().unwrap_or(0);
                if bw > best_bw {
                    if let Some(uri) = lines.get(i + 1) {
                        let uri = uri.trim();
                        if !uri.is_empty() && !uri.starts_with('#') {
                            best_bw = bw;
                            best_uri = Some(uri.to_string());
                        }
                    }
                }
            }
        }
    }
    match best_uri {
        Some(uri) => {
            if uri.starts_with("http") {
                uri
            } else if uri.starts_with('/') {
                let base = Regex::new("^(https?://[^/]+)")
                    .unwrap()
                    .captures(master)
                    .map(|c| c[1].to_string())
                    .unwrap_or_default();
                format!("{base}{uri}")
            } else {
                let base = master
                    .rsplit('/')
                    .next()
                    .map(|_| &master[..master.rfind('/').unwrap_or(0)])
                    .unwrap_or(master);
                format!("{base}/{uri}")
            }
        }
        None => master.to_string(),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("/censored/online", "有码在线"),
        category_json("/uncensored/online", "无码在线"),
        category_json("/western/online", "欧美在线"),
        category_json("/fc2/online", "FC2在线"),
        category_json("/chinese/online", "中文在线"),
        category_json("/series/censored", "有码系列"),
        category_json("/series/uncensored", "无码系列"),
        category_json("/rank/censored/day", "有码排行"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = if category_id.is_empty() {
        "/censored/online".to_string()
    } else {
        category_id.to_string()
    };
    let mut url = format!("{HOST}{path}");
    if page > 1 {
        url = format!("{url}?page={page}");
    }
    // 失败逐级回退：去参→根目录。
    let html = match get_text(&url).await {
        Ok(h) => h,
        Err(_) => match get_text(&format!("{HOST}{path}")).await {
            Ok(h) => h,
            Err(_) => get_text(&format!("{HOST}/")).await?,
        },
    };
    let items = parse_cards(&html);
    let has_more = html.contains("?page=") && !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        abs_url(series_id)
    };
    let page = get_text(&url).await?;
    let mut title = pick(&page, "(?s)property=\"og:title\" content=\"([^\"]+)\"");
    if title.is_empty() {
        title = pick(&page, "(?s)<title[^>]*>(.*?)</title>");
    }
    if title.is_empty() {
        title = url.rsplit('/').next().unwrap_or("JAV目錄").to_string();
    }
    let mut cover = pick(&page, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = pick(&page, "(?i)<img[^>]+data-src=\"([^\"]+)\"");
    }
    let cover = if cover.is_empty() {
        cover
    } else {
        abs_url(&cover)
    };
    let streams = pick_streams(&page);
    let (sorted, flags) = live_sort(streams).await;
    let mut episodes: Vec<Value> = Vec::new();
    for (i, _u) in sorted.iter().enumerate() {
        let mut name = format!("線路 {}", i + 1);
        if flags.get(i).copied().unwrap_or(false) {
            name = format!("{name} ✓");
        }
        episodes.push(episode_json(&format!("{url}?ln={}", i + 1), &name, &url));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&url, "正片", &url));
    }
    Ok(json!({
        "id": url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let url = format!("{HOST}/search?wd={encoded}");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：video_id 为详情 URL + ?ln=N；取第 N 条流并换最大 variant；
/// 无流时找第一个非广告 iframe 再取流；最后兜底详情页地址。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (detail_url, ln) = match video_id.split_once("?ln=") {
        Some((u, n)) => (u.to_string(), n.parse::<usize>().unwrap_or(1)),
        None => (video_id.to_string(), 1),
    };
    let page = get_text(&detail_url).await?;
    let streams = pick_streams(&page);
    let (sorted, _) = live_sort(streams).await;
    if let Some(master) = sorted.get(ln.saturating_sub(1)) {
        let url = top_variant(master).await;
        return Ok(json!({
            "url": url,
            "header": {"User-Agent": UA, "Referer": detail_url},
        }));
    }
    // 无流：找第一个非广告 iframe。
    let iframe_re = Regex::new("(?i)<iframe[^>]+src=\"([^\"]+)\"").unwrap();
    for cap in iframe_re.captures_iter(&page) {
        let src = cap[1].to_string();
        let lower = src.to_lowercase();
        if lower.contains("ads")
            || lower.contains("doubleclick")
            || lower.contains("mnaspm")
            || lower.contains("promptsgod")
            || lower.contains("googletagmanager")
        {
            continue;
        }
        let iframe_url = abs_url(&src);
        if let Ok(inner) = get_text(&iframe_url).await {
            let inner_streams = pick_streams(&inner);
            if let Some(first) = inner_streams.first() {
                let url = top_variant(first).await;
                return Ok(json!({
                    "url": url,
                    "header": {"User-Agent": UA, "Referer": detail_url},
                }));
            }
        }
        break;
    }
    Ok(json!({
        "url": detail_url,
        "header": {"User-Agent": UA, "Referer": detail_url},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_parse_code_links() {
        let page = "<a href=\"https://javmenu.com/CAWD-958\"><h5>标题</h5><p class=\"card-text\">副标题</p><img data-src=\"https://img.example.com/1.jpg\"><span class=\"text-muted\">2026-01-01</span></a>";
        let items = parse_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://javmenu.com/CAWD-958");
        assert_eq!(items[0]["title"], "标题 副标题");
        assert_eq!(items[0]["cover"], "https://img.example.com/1.jpg");
    }

    #[test]
    fn streams_from_attrs() {
        let page = "<video data-m3u8=\"https://cdn.example.com/a.m3u8\"></video> \"file\":\"https://cdn.example.com/b.m3u8\"";
        let streams = pick_streams(page);
        assert_eq!(streams.len(), 2);
    }
}
