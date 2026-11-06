//! 🔞Jable：jable.tv 的 HTML 站。
//!
//! 目录（video-img-box 卡片解析，h6.title 取标题、
//! data-src 取封面、span.label 取时长；路径后拼 <N>/ 翻页；
//! 主题/女优/标签页出 folder 卡）、详情（og 标题封面、女优、
//! 上市日期、时长、hlsUrl 取流）、搜索（/search/<词>/）、取流
//! （详情页 URL 重新抓页取 hlsUrl；hlsUrl 为带过期签名的
//! mushroomtrack m3u8，须现取现用）。
//! 验门（2026-11-06 本机出口实测）：首页 200；最新页 24 条/页，
//! 第 2 页不重合；/categories/ 12 主题与站导航 1:1；女优索引
//! 有真名；搜索 start-652 首条即本片；详情 START-652 的 hlsUrl
//! 清单 2014 分片/8057 秒（134.3 分钟全长），首分片 200 +
//! 375440B，AES-128 密钥拉取 200/16B（加密分片首字节非 0x47
//! 属正常，同 ddys 加密源先例）。jable1.nl 旧域 2026-11-05
//! 本机出口超时未验，改走 jable.tv。
//! 分类与站导航 1:1（新片优先/热度优先/新作 + 12 主题 +
//! 女优列表/标签库）；翻页 `路径<N>/`。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://jable.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn looks_ok(html: &str) -> bool {
    if html.len() < 2000 {
        return false;
    }
    let lower = html.to_lowercase();
    if lower.contains("just a moment")
        || lower.contains("cf_chl")
        || lower.contains("challenge-form")
        || lower.contains("enable javascript and cookies")
        || lower.contains("attention required")
    {
        return false;
    }
    if html.contains("继续访问") && !html.contains("video-img-box") {
        return false;
    }
    true
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Referer", format!("{HOST}/"))
        .header("Cookie", "x-index-auth=authed")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Jable请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if !looks_ok(&text) {
        return Err(ApiError::Internal("Jable页面被拦截或不完整".into()));
    }
    Ok(text)
}

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
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

/// 去站名后缀（实测标题形如
/// `START-652 … 七瀨温 - Jable.TV | 免費高清AV在線看 | J片 AV看到飽`），
/// 超 96 字截断加 …。
fn clean_title(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if let Some(i) = s.find(" - Jable.TV") {
        s = s[..i].trim().to_string();
    }
    for suffix in [
        "| 免費高清AV在線看 | J片 AV看到飽",
        "免費高清AV在線看",
        "J片 AV看到飽",
        "| 免费在线高清 | JAD MISS AV",
        "免费在线高清",
        "JAD MISS AV",
    ] {
        while let Some(stripped) = s.strip_suffix(suffix) {
            s = stripped.trim().trim_end_matches('|').trim().to_string();
        }
    }
    if s.chars().count() > 96 {
        let truncated: String = s.chars().take(96).collect();
        s = format!("{truncated}…");
    }
    s
}

/// 与 Java 的 codeOf 一致：slug 里的番号形，转大写。
fn code_of(slug: &str) -> String {
    let re = Regex::new("([A-Za-z]+-\\d{2,6})").unwrap();
    match re.captures(slug) {
        Some(cap) => cap[1].to_uppercase(),
        None => slug.to_uppercase(),
    }
}

/// 与 Java 的 parseCards 一致：按 video-img-box 分块，取
/// 链接、标题、封面、时长或番号备注。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let marker = "class=\"video-img-box";
    let mut starts: Vec<usize> = Vec::new();
    let mut from = 0usize;
    while let Some(i) = page[from..].find(marker) {
        starts.push(from + i);
        from += i + marker.len();
    }
    if starts.is_empty() {
        return items;
    }
    let href_re = Regex::new("href=\"(?:https?://[^\"]*?)?(/videos/([A-Za-z0-9._-]+)/)\"").unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, start) in starts.iter().enumerate() {
        let stop = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            (*start + 6000).min(page.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &page[*start..stop];
        let Some(cap) = href_re.captures(chunk) else {
            continue;
        };
        let slug = cap[2].to_string();
        if seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        let mut title = pick(chunk, "(?s)<h6 class=\"title\"[^>]*>\\s*<a[^>]*>(.*?)</a>");
        if title.is_empty() {
            title = pick(chunk, "(?s)<h6[^>]*>(.*?)</h6>");
        }
        if title.is_empty() {
            title = code_of(&slug);
        }
        let mut cover = pick(
            chunk,
            "(?i)data-src=\"(https?://[^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"",
        );
        if cover.is_empty() {
            cover = pick(
                chunk,
                "(?i)data-original=\"(https?://[^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"",
            );
        }
        if cover.is_empty() {
            cover = pick(
                chunk,
                "(?i)data-lazy-src=\"(https?://[^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"",
            );
        }
        let mut remark = pick(chunk, "(?s)<span class=\"label\"[^>]*>(.*?)</span>");
        if remark.is_empty() {
            remark = code_of(&slug);
        }
        if remark.is_empty() {
            remark = "Jable·免代理".to_string();
        }
        items.push(item_json(&abs_url(&cap[1]), &title, &cover, &remark));
    }
    items
}

/// 与 Java 的 parseFolders 一致：主题/女优/标签页出 folder 卡。
fn parse_folders(page: &str, kind: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let (prefix, label) = match kind {
        "models" => ("/models/", "女优"),
        "tags" => ("/tags/", "标签"),
        _ => ("/categories/", "主题"),
    };
    let pattern = format!("href=\"({}([A-Za-z0-9._-]+)/)\"", regex::escape(prefix));
    let Ok(href_re) = Regex::new(&pattern) else {
        return items;
    };
    let matches: Vec<(usize, String, String)> = href_re
        .captures_iter(page)
        .map(|cap| {
            let m = cap.get(0).unwrap();
            (m.start(), cap[1].to_string(), cap[2].to_string())
        })
        .collect();
    let mut seen: Vec<String> = Vec::new();
    for (i, (start, href, _slug)) in matches.iter().enumerate() {
        if seen.contains(href) {
            continue;
        }
        seen.push(href.clone());
        let chunk_start = start.saturating_sub(1500);
        let chunk_end = if i + 1 < matches.len() {
            matches[i + 1].0.min(page.len())
        } else {
            (*start + 1500).min(page.len())
        };
        let chunk = if chunk_end > chunk_start {
            &page[chunk_start..chunk_end]
        } else {
            ""
        };
        let mut name = pick(chunk, "(?s)<h[2-6][^>]*>(.*?)</h[2-6]>");
        if name.is_empty() {
            name = pick(chunk, "(?s)<a[^>]*href=\"[^\"]*\"[^>]*>([^<]{1,80})</a>");
        }
        if name.is_empty() {
            continue;
        }
        let mut remark = pick(chunk, "(\\d[\\d,]*) 部影片");
        if remark.is_empty() {
            remark = label.to_string();
        }
        let mut item = item_json(&format!("folder@{href}"), &name, "", &remark);
        if let Some(obj) = item.as_object_mut() {
            obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
        }
        items.push(item);
    }
    items
}

/// 女优名在 model 锚点内 span 的 title 属性里（span 文本只有首字）。
fn extract_actors(page: &str) -> Vec<String> {
    let mut actors: Vec<String> = Vec::new();
    let Ok(re) = Regex::new("(?s)<a class=\"model\"[^>]*>.*?title=\"([^\"]+)\"") else {
        return actors;
    };
    for cap in re.captures_iter(page) {
        let name = strip_tags(&cap[1]);
        if !name.is_empty() && !actors.contains(&name) {
            actors.push(name);
        }
    }
    actors
}

/// 与 Java 的 extractHls 一致：hlsUrl='…m3u8…'（单/双引号）。
fn extract_hls(page: &str) -> String {
    if let Ok(re) = Regex::new("hlsUrl\\s*=\\s*'([^']+\\.m3u8[^']*)'") {
        if let Some(cap) = re.captures(page) {
            return cap[1].to_string();
        }
    }
    if let Ok(re) = Regex::new("hlsUrl\\s*=\\s*\"([^\"]+\\.m3u8[^\"]*)\"") {
        if let Some(cap) = re.captures(page) {
            return cap[1].to_string();
        }
    }
    String::new()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("/latest-updates/", "新片优先"),
        category_json("/hot/", "热度优先"),
        category_json("/new-release/", "新作"),
        category_json("/categories/bdsm/", "主奴調教"),
        category_json("/categories/chinese-subtitle/", "中文字幕"),
        category_json("/categories/groupsex/", "多P群交"),
        category_json("/categories/insult/", "凌辱快感"),
        category_json("/categories/lesbian/", "女同歡愉"),
        category_json("/categories/pantyhose/", "絲襪美腿"),
        category_json("/categories/pov/", "男友視角"),
        category_json("/categories/private-cam/", "盜攝偷拍"),
        category_json("/categories/roleplay/", "角色劇情"),
        category_json("/categories/sex-only/", "直接開啪"),
        category_json("/categories/uncensored/", "無碼解放"),
        category_json("/categories/uniform/", "制服誘惑"),
        category_json("/categories/", "影片主题"),
        category_json("/models/", "女优列表"),
        category_json("/tags/", "标签库"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let cat = if category_id.is_empty() {
        "/latest-updates/".to_string()
    } else {
        category_id.to_string()
    };
    // folder 卡：取该文件夹页作列表。
    if let Some(folder_path) = cat.strip_prefix("folder@") {
        let html = get_text(&abs_url(folder_path)).await?;
        let items = parse_cards(&html);
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    let mut path = cat.clone();
    if page > 1 {
        path = format!("{path}{page}/");
    }
    let html = get_text(&abs_url(&path)).await?;
    let mut items = parse_cards(&html);
    if items.is_empty() {
        if cat == "/categories/" {
            items = parse_folders(&html, "categories");
        } else if cat == "/models/" {
            items = parse_folders(&html, "models");
        } else if cat == "/tags/" {
            items = parse_folders(&html, "tags");
        }
    }
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim_start_matches("folder@").trim();
    // folder 卡被当作详情打开时：该文件夹的视频当成分集。
    if id.starts_with("/models/") || id.starts_with("/tags/") || id.starts_with("/categories/") {
        if !id.starts_with("/videos/") {
            let html = get_text(&abs_url(id)).await?;
            let cards = parse_cards(&html);
            let mut episodes: Vec<Value> = Vec::new();
            for entry in cards {
                let vid = text_of(&entry, &["id"]);
                let name = text_of(&entry, &["title"]);
                if vid.is_empty() || name.is_empty() {
                    continue;
                }
                episodes.push(episode_json(&vid, &name, id));
            }
            if episodes.is_empty() {
                return Err(ApiError::Internal("Jable该目录为空".into()));
            }
            return Ok(json!({
                "id": id,
                "title": "目录",
                "cover": "",
                "synopsis": "",
                "extra": {},
                "episodes": episodes,
            }));
        }
    }
    let path = if id.starts_with("http") {
        id.strip_prefix(HOST).unwrap_or(id).to_string()
    } else if id.starts_with("/videos/") {
        id.to_string()
    } else {
        format!("/videos/{id}/")
    };
    let page_url = format!("{HOST}{path}");
    let page = get_text(&page_url).await?;
    let mut title = pick(&page, "(?s)property=\"og:title\" content=\"([^\"]+)\"");
    if title.is_empty() {
        title = pick(&page, "(?s)<title[^>]*>(.*?)</title>");
    }
    let title = clean_title(&title);
    let title = if title.is_empty() {
        "Jable".to_string()
    } else {
        title
    };
    let mut cover = pick(&page, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = pick(&page, "(?i)data-poster=\"([^\"]+)\"");
    }
    let cover = if cover.is_empty() {
        cover
    } else {
        abs_url(&cover)
    };
    let mut extra = serde_json::Map::new();
    let actors = extract_actors(&page);
    if !actors.is_empty() {
        extra.insert("actors".to_string(), Value::String(actors.join(" / ")));
    }
    let date = pick(&page, "上市[于於]\\s*(\\d{4}-\\d{2}-\\d{2})");
    if !date.is_empty() {
        extra.insert("date".to_string(), Value::String(date));
    }
    let mut duration = String::new();
    if let Some(sec_start) = page.find("class=\"video-img-box") {
        let sec_end = page[sec_start..]
            .find("</section>")
            .map(|i| sec_start + i)
            .unwrap_or(page.len());
        let section = &page[sec_start..sec_end];
        duration = pick(section, "(\\d{1,2}:\\d{2}:\\d{2})");
        if duration.is_empty() {
            duration = pick(section, "(?s)<span class=\"label\"[^>]*>(.*?)</span>");
        }
    }
    if !duration.is_empty() {
        extra.insert("duration".to_string(), Value::String(duration));
    }
    let hls = extract_hls(&page);
    let mut episodes: Vec<Value> = Vec::new();
    episodes.push(episode_json(&page_url, "正片", &page_url));
    if !hls.is_empty() {
        episodes.push(episode_json(&hls, "备用", &page_url));
    }
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let html = get_text(&format!("{HOST}/search/{encoded}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：直链直接回；详情页 URL 重新抓页取 hlsUrl；取不到
/// 时报错（不回空地址）。
/// 302 修掉：hlsUrl 常为无 .m3u8 后缀的 pumpres 跳转地址，
/// 探针/播放器不跟跳转时只拿到跳转 stub；这里先跟随跳转
/// 拿最终清单地址再返回（同 99jj/dayday 的 resolve_redirect
/// 写法：先 HEAD，失败再 GET，不读 body）。
async fn resolve_redirect(url: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .head(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        return Some(final_url);
    }
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        Some(final_url)
    } else {
        None
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let header = json!({"User-Agent": UA, "Referer": format!("{HOST}/"), "Origin": HOST});
    if video_id.contains(".m3u8") {
        let mut url = video_id.to_string();
        if let Some(resolved) = resolve_redirect(&url).await {
            if resolved.len() > 20 {
                url = resolved;
            }
        }
        return Ok(json!({"url": url, "header": header}));
    }
    let page = get_text(video_id).await?;
    let hls = extract_hls(&page);
    if hls.is_empty() {
        return Err(ApiError::Internal("Jable未取到播放地址".into()));
    }
    let mut url = hls;
    if let Some(resolved) = resolve_redirect(&url).await {
        if resolved.len() > 20 {
            url = resolved;
        }
    }
    Ok(json!({"url": url, "header": header}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_title_strips_suffix() {
        assert_eq!(
            clean_title("START-652 全裸業務 七瀨温 - Jable.TV | 免費高清AV在線看 | J片 AV看到飽"),
            "START-652 全裸業務 七瀨温"
        );
        assert_eq!(clean_title("标题 | 免费在线高清 | JAD MISS AV"), "标题");
    }

    #[test]
    fn code_of_reads() {
        assert_eq!(code_of("ipx-811-uncensored"), "IPX-811");
    }

    #[test]
    fn cards_parse_video_boxes() {
        let page = "<div class=\"video-img-box\"><a href=\"https://jable.tv/videos/ipx-811/\"><img data-src=\"https://img.example.com/1.jpg\"></a><h6 class=\"title\"><a>标题</a></h6><span class=\"label\">12:34</span></div>";
        let items = parse_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://jable.tv/videos/ipx-811/");
        assert_eq!(items[0]["title"], "标题");
        assert_eq!(items[0]["remark"], "12:34");
    }

    #[test]
    fn actors_from_span_title_and_date() {
        let page = "<a class=\"model\" href=\"https://jable.tv/models/91126956c8847ee1d85f452d212d6ec1/\"><span class=\"placeholder rounded-circle\" title=\"七瀬温\">七</span></a>上市於 2026-11-02";
        let actors = extract_actors(page);
        assert_eq!(actors, vec!["七瀬温".to_string()]);
        assert_eq!(
            pick(page, "上市[于於]\\s*(\\d{4}-\\d{2}-\\d{2})"),
            "2026-11-02"
        );
    }

    #[test]
    fn hls_extracted() {
        let page = "var hlsUrl = 'https://cdn.example.com/hls/1.m3u8';";
        assert_eq!(extract_hls(page), "https://cdn.example.com/hls/1.m3u8");
    }
}
