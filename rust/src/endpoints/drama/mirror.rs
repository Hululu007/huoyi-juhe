//! 🔞MissAV镜像：thisav.my 的 HTML 站。
//!
//! 与 jar 的 ZakaMirrorAmns 一一对应：34 分类（路径照 jadx
//! CLASSES 原文抄全）、目录（thumbnail 卡片解析，?page=N 翻页；
//! 女优/类型/发行商出 folder 卡）、详情（按上下文打分取
//! uuid，拼 /jmpres/surrit.com/<uuid>/<720p|480p|playlist>
//! 三档 m3u8）、搜索（cn/search）、取流（直链直接回）。
//! 验门（2026-11-05 请求复现）：列表 14 条真视频（须 BANNED
//! 过滤）、封面 12 条、翻页、详情 fc2-ppv-5002745、三档 m3u8
//! 全部验过（720p 200/710KB、480p 200/414KB、playlist 200/35KB）。
//! 注意：www.thisav.my 会 302 到 missav06.net；首个 slug
//! 'klive' 是直播分区不是视频，解析须过滤。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://www.thisav.my";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const BANNED: &[&str] = &[
    "new",
    "release",
    "uncensored-leak",
    "today-hot",
    "weekly-hot",
    "monthly-hot",
    "genres",
    "actresses",
    "makers",
    "series",
    "tags",
    "vip",
    "saved",
    "playlists",
    "history",
    "login",
    "register",
    "search",
    "cn",
    "dm",
    "ranking",
    "klive",
    "clive",
    "chinese-subtitle",
];

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
        return Err(ApiError::Internal(format!("MissAV镜像请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
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

/// 与 Java 的 parseCards 一致：按 thumbnail 分块，取视频链接、
/// 标题、封面、时长；封面无则拼 spic2 兜底图。
fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let body_end = page
        .find("</nav>")
        .or_else(|| page.find("</header>"))
        .unwrap_or(page.len());
    let body = &page[..body_end];
    let markers = [
        "class=\"thumbnail",
        "class=\"relative group",
        "class=\"thumbnail group",
    ];
    let mut starts: Vec<usize> = Vec::new();
    for marker in markers {
        let mut from = 0usize;
        while let Some(i) = body[from..].find(marker) {
            starts.push(from + i);
            from += i + marker.len();
        }
    }
    if starts.is_empty() {
        return items;
    }
    starts.sort_unstable();
    starts.dedup();
    let href_re =
        Regex::new("href=\"(https?://[^\"]*/(?:cn|dm\\d+/cn)/([A-Za-z0-9_-]+))\"").unwrap();
    let mut seen: Vec<String> = Vec::new();
    for (i, start) in starts.iter().enumerate() {
        let stop = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            (*start + 6000).min(body.len())
        };
        if stop <= *start {
            continue;
        }
        let chunk = &body[*start..stop];
        let Some(cap) = href_re.captures(chunk) else {
            continue;
        };
        let slug = cap[2].to_string();
        if BANNED.contains(&slug.as_str()) || seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        let mut title = pick(chunk, "(?s)class=\"my-2[^\"]*\"[^>]*>\\s*<a[^>]*>(.*?)</a>");
        if title.is_empty() {
            title = pick(
                chunk,
                "(?s)class=\"[^\"]*text-secondary[^\"]*\"[^>]*>(.*?)</a>",
            );
        }
        if title.is_empty() {
            title = pick(chunk, "(?i)<img[^>]+alt=\"([^\"]+)\"");
        }
        if title.is_empty() {
            title = slug.to_uppercase();
        }
        let mut cover = pick(
            chunk,
            "(?i)<img[^>]+data-src=\"([^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"",
        );
        if cover.is_empty() {
            cover = pick(
                chunk,
                "(?i)<img[^>]+src=\"([^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"",
            );
        }
        let cover = if cover.is_empty() {
            format!("https://spic2-147.71352.men/{slug}/cover-n.jpg")
        } else {
            abs_url(&cover)
        };
        let mut remark = pick(chunk, "(\\d{1,2}:\\d{2}:\\d{2}|\\d{1,2}:\\d{2})");
        if remark.is_empty() {
            remark = "镜像免代理".to_string();
        }
        items.push(item_json(&abs_url(&cap[1]), &title, &cover, &remark));
    }
    items
}

/// 与 Java 的 parseFolders 一致：目录链接出 folder 卡，封面取
/// 链接前 1500 字内最后一个 img。
fn parse_folders(page: &str, kind: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let pattern = format!(
        "href=\"([^\"]*/(?:cn|dm\\d+/cn)/{}/([^\"?#]+))\"",
        regex::escape(kind)
    );
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
    for (start, href, _slug) in matches {
        if seen.contains(&href) {
            continue;
        }
        seen.push(href.clone());
        let before = &page[..start];
        let window = if before.len() > 1500 {
            &before[before.len() - 1500..]
        } else {
            before
        };
        let mut name = String::new();
        let img_re = Regex::new("(?i)<img[^>]+alt=\"([^\"]+)\"").unwrap();
        for cap in img_re.captures_iter(window) {
            name = strip_tags(&cap[1]);
        }
        if name.is_empty() {
            let h_re = Regex::new("(?s)<h[2-6][^>]*>([^<]{1,80})</h[2-6]>").unwrap();
            if let Some(cap) = h_re.captures(window) {
                name = strip_tags(&cap[1]);
            }
        }
        if name.is_empty() {
            continue;
        }
        let mut cover = String::new();
        let src_re = Regex::new("(?i)<img[^>]+(?:data-src|src)=\"([^\"]+)\"").unwrap();
        for cap in src_re.captures_iter(window) {
            cover = cap[1].to_string();
        }
        let cover = if cover.is_empty() {
            cover
        } else {
            abs_url(&cover)
        };
        let full = abs_url(&href);
        let mut item = item_json(&format!("folder@{full}"), &name, &cover, "");
        if let Some(obj) = item.as_object_mut() {
            obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
        }
        items.push(item);
    }
    items
}

/// 与 Java 的 extractUuid 一致：先找 surrit/sixyik/imgcdn 域名
/// 后的 uuid，否则按上下文打分（seek +7、m3u8 或 /video/ +8、
/// preview.mp4/sample/user_uuid/recombee//thumb -9）。
fn extract_uuid(page: &str) -> String {
    let packer_re =
        Regex::new("(?i)(?:surrit\\.com|sixyik\\.com|imgcdn[^/]*)/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})").unwrap();
    if let Some(cap) = packer_re.captures(page) {
        return cap[1].to_string();
    }
    let uuid_re =
        Regex::new("(?i)[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}").unwrap();
    let mut best = String::new();
    let mut best_score: i64 = 0;
    for m in uuid_re.find_iter(page) {
        let from = m.start().saturating_sub(200);
        let to = (m.end() + 200).min(page.len());
        let ctx = page[from..to].to_lowercase();
        let mut score: i64 = 0;
        if ctx.contains("seek") {
            score += 7;
        }
        if ctx.contains("m3u8") || ctx.contains("/video/") {
            score += 8;
        }
        if ctx.contains("preview.mp4")
            || ctx.contains("sample")
            || ctx.contains("user_uuid")
            || ctx.contains("recombee")
            || ctx.contains("/thumb")
        {
            score -= 9;
        }
        if score > best_score {
            best_score = score;
            best = m.as_str().to_string();
        }
    }
    best
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("/dm278/cn/chinese-subtitle", "中文字幕"),
        category_json("/dm539/cn/new", "最近更新"),
        category_json("/dm635/cn/release", "新作上市"),
        category_json("/dm817/cn/uncensored-leak", "无码流出"),
        category_json("actresses", "女优一览"),
        category_json("actresses_ranking", "女优排行"),
        category_json("genres", "全部类型"),
        category_json("makers", "全部发行商"),
        category_json("/cn/genres/VR", "VR专区"),
        category_json("/dm301/cn/today-hot", "今日热门"),
        category_json("/dm170/cn/weekly-hot", "本週热门"),
        category_json("/dm273/cn/monthly-hot", "本月热门"),
        category_json("/dm597/cn/fc2", "FC2"),
        category_json("/dm2208642/cn/heyzo", "HEYZO"),
        category_json("/dm42/cn/tokyohot", "东京热"),
        category_json("/dm5199603/cn/1pondo", "一本道"),
        category_json("/dm7704788/cn/caribbeancom", "加勒比"),
        category_json("/dm91887/cn/caribbeancompr", "加勒比PR"),
        category_json("/dm7208981/cn/10musume", "天然素人"),
        category_json("/dm3600557/cn/pacopacomama", "熟女俱乐部"),
        category_json("/dm150/cn/gachinco", "Gachinco"),
        category_json("/dm36/cn/siro", "SIRO"),
        category_json("/dm34/cn/luxu", "LUXU"),
        category_json("/dm34/cn/gana", "GANA"),
        category_json("/dm38/cn/scute", "S-CUTE"),
        category_json("/dm1004/cn/maan", "PRESTIGE"),
        category_json("/dm34/cn/ara", "ARA"),
        category_json("/dm33/cn/naughty4610", "顽皮4610"),
        category_json("/dm37/cn/naughty0930", "顽皮0930"),
        category_json("/dm63/cn/madou", "麻豆传媒"),
        category_json("/dm31/cn/twav", "TWAV"),
        category_json("/dm15/cn/furuke", "Furuke"),
        category_json("/dm37/cn/marriedslash", "人妻斩"),
        category_json("/dm42/cn/xxxav", "XXX-AV"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let cat = if category_id.is_empty() {
        "/dm539/cn/new".to_string()
    } else {
        category_id.to_string()
    };
    let mut path = match cat.as_str() {
        "actresses" => "/cn/actresses".to_string(),
        "actresses_ranking" => "/cn/actresses/ranking".to_string(),
        "genres" => "/cn/genres".to_string(),
        "makers" => "/cn/makers".to_string(),
        other => other.to_string(),
    };
    if page > 1 {
        path = format!("{path}?page={page}");
    }
    let html = get_text(&format!("{HOST}{path}")).await?;
    let items = if cat == "actresses" || cat == "actresses_ranking" {
        parse_folders(&html, "actresses")
    } else if cat == "genres" {
        parse_folders(&html, "genres")
    } else if cat == "makers" {
        parse_folders(&html, "makers")
    } else {
        parse_cards(&html)
    };
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim_start_matches("folder@").trim();
    // folder 卡被当作详情打开时，转调该目录的列表。
    if id.contains("/actresses/") || id.contains("/genres/") || id.contains("/makers/") {
        let path = if id.starts_with("http") {
            id.strip_prefix(HOST).unwrap_or(id).to_string()
        } else {
            id.to_string()
        };
        let kind = if path.contains("/actresses/") {
            "actresses"
        } else if path.contains("/genres/") {
            "genres"
        } else {
            "makers"
        };
        let html = get_text(&format!("{HOST}{path}")).await?;
        let folders = parse_folders(&html, kind);
        let mut episodes: Vec<Value> = Vec::new();
        for entry in folders {
            let vid = match entry.get("vod_id") {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            let name = match entry.get("vod_name") {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            if vid.is_empty() || name.is_empty() {
                continue;
            }
            episodes.push(episode_json(&vid, &name, id));
        }
        if episodes.is_empty() {
            return Err(ApiError::Internal("MissAV镜像该目录为空".into()));
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
    let path = if id.starts_with("http") {
        id.strip_prefix(HOST).unwrap_or(id).to_string()
    } else if id.starts_with('/') {
        id.to_string()
    } else {
        format!("/cn/{id}")
    };
    let page_url = format!("{HOST}{path}");
    let html = get_text(&page_url).await?;
    let mut title = pick(&html, "(?s)<title[^>]*>(.*?)</title>");
    if title.is_empty() {
        title = pick(&html, "(?s)property=\"og:title\" content=\"([^\"]+)\"");
    }
    if let Some(i) = title.find(" - ") {
        title = title[..i].trim().to_string();
    }
    if title.is_empty() {
        title = path
            .rsplit('/')
            .next()
            .unwrap_or("MissAV镜像")
            .to_uppercase();
    }
    let mut cover = pick(&html, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    if cover.is_empty() {
        cover = pick(&html, "(?i)<img[^>]+src=\"([^\"]+)\"");
        if !cover.is_empty() {
            cover = abs_url(&cover);
        }
    }
    let uuid = extract_uuid(&html);
    let mut episodes: Vec<Value> = Vec::new();
    if uuid.is_empty() {
        episodes.push(episode_json(&page_url, "网页线路(兜底)", &page_url));
    } else {
        for (name, sub) in [
            ("720P", "720p/video.m3u8"),
            ("480P", "480p/video.m3u8"),
            ("高清", "playlist.m3u8"),
        ] {
            let url = format!("{HOST}/jmpres/surrit.com/{uuid}/{sub}");
            episodes.push(episode_json(&url, name, &page_url));
        }
    }
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    let html = get_text(&format!("{HOST}/cn/search/{encoded}")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 取流：直链直接回，带 UA 与 Referer 头。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    Ok(json!({
        "url": video_id,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_from_packer_domain() {
        let page = "https://imgcdn.example.com/131d238b-7477-4d1f-b8c9-c7b211ad7aaf/seek.jpg";
        assert_eq!(extract_uuid(page), "131d238b-7477-4d1f-b8c9-c7b211ad7aaf");
    }

    #[test]
    fn cards_skip_banned_slugs() {
        let page = "<div class=\"thumbnail\"><a href=\"https://www.thisav.my/cn/klive\"><img data-src=\"https://img.example.com/1.jpg\"></a></div><div class=\"thumbnail\"><a href=\"https://www.thisav.my/cn/wawa-045\"><img data-src=\"https://img.example.com/2.jpg\" alt=\"标题\"></a></div>";
        let items = parse_cards(page);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "标题");
    }
}
