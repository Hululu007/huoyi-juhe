//! whos.tv（以图搜片）：`https://whos.tv`，图片 CDN `https://f.hersav.me`。
//!
//! 来源 jar 类 `ZakaWhosAmns`（火蚁TV 注册名 ZakaWhos，显示名
//! 🔍whos识图┃原生）。分类：影片库 / 演员 / 排行榜 / 帧图 + 前 12
//! 服装标签 chip（首页“帧分类探索”第一组顺序）。列表、详情、搜索、
//! 取流均按 jar 配方，实测对照修正三处：
//! 1. 帧筛选不用 jar 的查询串 `/frames?type_id=&label_id=`（服务端
//!    忽略，返回未筛选），改用站内路径式 `/frames/type-{slug}/label-{id}`
//!    （实测返回已筛选帧图）；翻页 `/page-{n}`。
//! 2. 列表解析跳过翻页链接（`/videos/page-N`、`/actresses/page-N`
//!    会被 jar 的切分正则误认成卡片，实测每页多出 6 张假卡）。
//! 3. 女优 slug 只取名字段（jar 取到 `{名}/frames`）；详情取
//!    `/actresses/{名}`（实测 12 部作品）。
//! 取流：详情页 m3u8（`data-preview-source` 优先，
//! `v.hersav.me/{hash}/{hash}.m3u8` 兜底）；分片是 TS 数据、仅扩展
//! 名是 `.jpeg`（首分片验过 0x47 同步字节、Range 206）。
//! 以图搜片（上传图片识片）jar 未实现，核心也不做。

use base64::Engine as _;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://whos.tv";
const IMG_CDN: &str = "https://f.hersav.me";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const PER_PAGE_VIDEOS: usize = 12;
const PER_PAGE_ACTRESS: usize = 18;
const PER_PAGE_FRAMES: usize = 20;

/// 分类：影片库 / 演员 / 排行榜 / 帧图 + 前 12 服装标签 chip。
/// 标签 id 形如 `c{type_id}_{label_id}`，type 1 为服装（clothes）。
const CATEGORIES: &[(&str, &str)] = &[
    ("vid", "影片库"),
    ("act", "演员"),
    ("ranking", "排行榜"),
    ("frames", "帧图"),
    ("c1_49", "全裸"),
    ("c1_255", "裸体"),
    ("c1_168", "白色衬衫"),
    ("c1_248", "白色上衣"),
    ("c1_116", "白衬衫"),
    ("c1_476", "内衣"),
    ("c1_98", "黑色丝袜"),
    ("c1_308", "衬衫"),
    ("c1_152", "黑色短裙"),
    ("c1_568", "半裸"),
    ("c1_125", "短裙"),
    ("c1_1110", "白色内裤"),
];

/// 标签组 type_id 到路径 slug（与 jar 的 ZakaWhosCats 一致）。
fn type_slug(type_id: i64) -> &'static str {
    match type_id {
        1 => "clothes",
        2 => "location",
        3 => "closeup",
        4 => "pose",
        5 => "action",
        6 => "expression",
        7 => "prop",
        _ => "other",
    }
}

/// 去 HTML 标签与空白（与 520av 的 strip_tags 一致）。
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

/// HTML 实体反转义（标题与女优名用）。
fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// 路径段百分号编码（女优名含中日文；空格编成 %20 而非 +）。
fn path_encode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

async fn fetch(path: &str) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("whos 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// jar 的 xorUrl：末两位十六进制为密钥，其余每两字节异或还原。
fn xor_url(hex: &str) -> String {
    if hex.len() < 6 {
        return String::new();
    }
    let key = match u8::from_str_radix(&hex[hex.len() - 2..], 16) {
        Ok(k) => k,
        Err(_) => return String::new(),
    };
    let body = &hex[..hex.len() - 2];
    let bytes = body.as_bytes();
    let mut out: Vec<u8> = Vec::new();
    let mut i = 0;
    while i + 1 < body.len() {
        let pair = match std::str::from_utf8(&bytes[i..i + 2]) {
            Ok(s) => s,
            Err(_) => return String::new(),
        };
        match u8::from_str_radix(pair, 16) {
            Ok(v) => out.push(v ^ key),
            Err(_) => return String::new(),
        }
        i += 2;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// jar 的 slugOf：首个 3~41 位字母数字串，小写。
fn slug_of(s: &str) -> String {
    let re = Regex::new(r"([A-Za-z0-9][A-Za-z0-9\-_]{2,40})").unwrap();
    re.captures(s)
        .map(|c| c[1].to_lowercase())
        .unwrap_or_default()
}

/// jar 的 timeOf：首个 `h:mm:ss`。
fn time_of(s: &str) -> String {
    let re = Regex::new(r"(\d{1,2}:\d{2}:\d{2})").unwrap();
    re.captures(s)
        .map(|c| c[1].to_string())
        .unwrap_or_default()
}

/// jar 的 secOf：`h:mm:ss` 转秒数。
fn sec_of(s: &str) -> String {
    let t = time_of(s);
    if t.is_empty() {
        return String::new();
    }
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() != 3 {
        return String::new();
    }
    match (
        parts[0].parse::<i64>(),
        parts[1].parse::<i64>(),
        parts[2].parse::<i64>(),
    ) {
        (Ok(h), Ok(m), Ok(sec)) => (h * 3600 + m * 60 + sec).to_string(),
        _ => String::new(),
    }
}

/// jar 的 enc：字段用 \x1f 连接、去分隔符后 base64url（无填充）。
fn enc(parts: &[&str]) -> String {
    let clean: Vec<String> = parts
        .iter()
        .map(|p| p.replace('|', " ").replace('\x1f', " "))
        .collect();
    let joined = clean.join("\x1f");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(joined.as_bytes())
}

/// jar 的 dec：base64url（无填充）解开后按 \x1f 切分。
fn dec(id: &str) -> Vec<String> {
    let decoded = match base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(id.as_bytes())
    {
        Ok(b) => b,
        Err(_) => {
            return Vec::new();
        }
    };
    let text = String::from_utf8_lossy(&decoded).to_string();
    if text.is_empty() {
        return Vec::new();
    }
    text.split('\x1f').map(|s| s.to_string()).collect()
}

/// 按字符边界截断（直接按字节切会把多字节中文字符切断而 panic）。
fn truncate(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// 按锚点切卡片：regex 不支持 look-around，改用 find_iter 取每张卡片
/// 的起始位置、切到下一张卡片开头（jar 的 split 写法同效）。
fn card_chunks<'a>(html: &'a str, anchor: &Regex) -> Vec<&'a str> {
    let starts: Vec<usize> = anchor.find_iter(html).map(|m| m.start()).collect();
    let mut chunks = Vec::new();
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(html.len());
        chunks.push(&html[start..end]);
    }
    chunks
}

/// 视频卡片解析（jar `videos`）：slug、XOR 封面、h3/alt/p 标题。
/// 翻页链接（page-N）跳过（jar 会误认成卡片）。
fn parse_videos(html: &str) -> Vec<Value> {
    let anchor = Regex::new(r#"<a[^>]+href="/videos/([a-zA-Z0-9\-_]+)""#).unwrap();
    let cover_re = Regex::new(r#"data-cover-src="([0-9a-fA-F]{20,})""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+src="(https?://[^"]+)""#).unwrap();
    let h3_re = Regex::new(r"(?s)<h3[^>]*>(.{0,300}?)</h3>").unwrap();
    let alt_re = Regex::new(r#"alt="([^"]{2,200})""#).unwrap();
    let p_re = Regex::new(r"(?s)<p[^>]*>(.{0,200}?)</p>").unwrap();
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for chunk in card_chunks(html, &anchor) {
        let chunk = truncate(chunk, 6000);
        let Some(cap) = anchor.captures(chunk) else {
            continue;
        };
        let slug = cap[1].to_string();
        if slug.starts_with("page-") || seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        let mut cover = cover_re
            .captures(chunk)
            .map(|c| xor_url(&c[1]))
            .unwrap_or_default();
        if cover.is_empty() || !cover.starts_with("http") {
            cover = img_re
                .captures(chunk)
                .map(|c| c[1].to_string())
                .unwrap_or_default();
        }
        let mut title = h3_re
            .captures(chunk)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
        if title.is_empty() {
            title = alt_re
                .captures(chunk)
                .map(|c| strip_tags(&c[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            title = p_re
                .captures(chunk)
                .map(|c| strip_tags(&c[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            title = slug.to_uppercase();
        }
        if title.chars().count() > 120 {
            title = title.chars().take(120).collect();
        }
        items.push(item_json(
            &enc(&["v", &slug, &title, &cover, ""]),
            &title,
            &cover,
            &slug.to_uppercase(),
        ));
    }
    items
}

/// 女优卡片解析（jar `actresses`）：名字段做 slug（去掉末尾 /frames），
/// 翻页链接跳过；封面取 img src，名字取 img alt 或 slug。
fn parse_actresses(html: &str) -> Vec<Value> {
    let anchor = Regex::new(r#"<a[^>]+href="/actresses/([^"?#]{1,90})""#).unwrap();
    let alt_re = Regex::new(r#"<img[^>]+alt="([^"]{1,90})""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]+src="(https?://[^"]+)""#).unwrap();
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for chunk in card_chunks(html, &anchor) {
        let chunk = truncate(chunk, 3000);
        let Some(cap) = anchor.captures(chunk) else {
            continue;
        };
        let raw = cap[1].to_string();
        if raw.starts_with("page-") {
            continue;
        }
        let slug = raw.strip_suffix("/frames").unwrap_or(&raw).to_string();
        if slug.is_empty() || seen.contains(&slug) {
            continue;
        }
        seen.push(slug.clone());
        let mut name = unescape(&slug);
        if let Some(alt) = alt_re.captures(chunk) {
            let alt_name = unescape(&alt[1]).trim().to_string();
            if !alt_name.is_empty() {
                name = alt_name;
            }
        }
        let pic = img_re
            .captures(chunk)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        items.push(item_json(
            &enc(&["a", &slug, &name, &pic]),
            &name,
            &pic,
            "演员",
        ));
    }
    items
}

/// 帧图卡片解析（jar `frames`）：帧 id、封面、标题、演员、时间。
/// 无有效视频 slug 的帧跳过（详情要落到视频上）。
fn parse_frames(html: &str) -> Vec<Value> {
    let anchor = Regex::new(r#"<a href="/frames/(\d+)""#).unwrap();
    let img_re = Regex::new(r#"<img\s+src="([^"]+)""#).unwrap();
    let title_re = Regex::new(r#"data-frame-title="([^"]*)""#).unwrap();
    let actor_re = Regex::new(r#"<span class="font-medium">([^<]*)</span>"#).unwrap();
    let time_re = Regex::new(r"\d{1,2}:\d{2}:\d{2}").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let lead_re = Regex::new(r"^[\u{00b7}\-|,\u{ff0c}\s]+").unwrap();
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for chunk in card_chunks(html, &anchor) {
        let chunk = truncate(chunk, 6000);
        let Some(cap) = anchor.captures(chunk) else {
            continue;
        };
        let frame_id = cap[1].to_string();
        if seen.contains(&frame_id) {
            continue;
        }
        seen.push(frame_id.clone());
        let mut img = img_re
            .captures(chunk)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        if !img.starts_with("http") && !img.is_empty() {
            img = format!("{IMG_CDN}{img}");
        }
        let raw_title = title_re
            .captures(chunk)
            .map(|c| unescape(&c[1]))
            .unwrap_or_default();
        let actor = actor_re
            .captures(chunk)
            .map(|c| unescape(&c[1]))
            .unwrap_or_default();
        let mut slug = slug_of(&raw_title);
        if slug.is_empty() {
            slug = actor.to_lowercase();
        }
        if slug.is_empty() {
            continue;
        }
        let time = if !time_of(&raw_title).is_empty() {
            time_of(&raw_title)
        } else {
            time_of(&actor)
        };
        let sec = if !sec_of(&raw_title).is_empty() {
            sec_of(&raw_title)
        } else {
            sec_of(&actor)
        };
        let mut clean = time_re.replace_all(&raw_title, " ").to_string();
        clean = ws_re.replace_all(clean.trim(), " ").to_string();
        if !slug.is_empty() && clean.to_lowercase().starts_with(&slug) {
            clean = clean[slug.len()..].trim().to_string();
        }
        clean = lead_re.replace_all(&clean, "").trim().to_string();
        let mut name = if actor.is_empty() {
            slug.to_uppercase()
        } else {
            actor.to_uppercase()
        };
        if !time.is_empty() {
            name = format!("{name} · {time}");
        }
        if !clean.is_empty() {
            let short: String = clean.chars().take(60).collect();
            name = format!("{name} {short}");
        }
        let remark = if time.is_empty() {
            "帧".to_string()
        } else {
            time
        };
        items.push(item_json(
            &enc(&["f", &frame_id, &slug, &sec, &raw_title, &img]),
            name.trim(),
            &img,
            &remark,
        ));
    }
    items
}

/// 详情页解析（jar `videoInfo`）：标题、简介、封面、m3u8、时长、日期、演员。
struct VideoInfo {
    title: String,
    content: String,
    cover: String,
    m3u8: String,
    minutes: String,
    date: String,
    actors: String,
}

fn parse_video_info(html: &str) -> VideoInfo {
    let mut info = VideoInfo {
        title: String::new(),
        content: String::new(),
        cover: String::new(),
        m3u8: String::new(),
        minutes: String::new(),
        date: String::new(),
        actors: String::new(),
    };
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.{0,300}?)</h1>").unwrap();
    if let Some(c) = h1_re.captures(html) {
        info.title = strip_tags(&c[1]);
    }
    let desc_re =
        Regex::new(r#"<meta name="description" content="([^"]{0,400})""#).unwrap();
    if let Some(c) = desc_re.captures(html) {
        info.content = c[1].trim().to_string();
    }
    let cover_re =
        Regex::new(r"(https://v\.hersav\.me/images/av/[a-f0-9]+\.jpg)").unwrap();
    if let Some(c) = cover_re.captures(html) {
        info.cover = c[1].to_string();
    }
    let preview_re =
        Regex::new(r#"data-preview-source="(https?://[^"]+\.m3u8[^"]*)""#).unwrap();
    if let Some(c) = preview_re.captures(html) {
        info.m3u8 = c[1].to_string();
    } else {
        let fallback_re =
            Regex::new(r"(https://v\.hersav\.me/[a-f0-9]+/[a-f0-9]+\.m3u8)").unwrap();
        if let Some(c) = fallback_re.captures(html) {
            info.m3u8 = c[1].to_string();
        }
    }
    let min_re =
        Regex::new(r"时长[：:]?</span>\s*<span[^>]*>([^<]{1,24})</span>").unwrap();
    if let Some(c) = min_re.captures(html) {
        info.minutes = c[1].trim().to_string();
    }
    let date_re =
        Regex::new(r"发行日期</span>\s*<span[^>]*>([^<]{4,24})</span>").unwrap();
    if let Some(c) = date_re.captures(html) {
        info.date = c[1].trim().to_string();
    } else {
        let any_date_re = Regex::new(r"(\d{4}-\d{2}-\d{2})").unwrap();
        if let Some(c) = any_date_re.captures(html) {
            info.date = c[1].to_string();
        }
    }
    let actor_re = Regex::new(r#"href="/actresses/([^"]{1,60})""#).unwrap();
    let mut actors: Vec<String> = Vec::new();
    for c in actor_re.captures_iter(html) {
        let name = unescape(&c[1]).trim().to_string();
        let name = name.strip_suffix("/frames").unwrap_or(&name).to_string();
        if !name.is_empty() && !name.starts_with("page-") && !actors.contains(&name) {
            actors.push(name);
        }
    }
    info.actors = actors.into_iter().take(6).collect::<Vec<_>>().join("/");
    info
}

/// 视频详情 JSON（演员详情的单集也复用：分集 video_id 为 `p:{slug}`）。
fn video_detail_json(html: &str, slug: &str, id: &str) -> Value {
    let info = parse_video_info(html);
    let title = if info.title.is_empty() {
        slug.to_uppercase()
    } else {
        info.title
    };
    let synopsis = if info.content.is_empty() {
        title.clone()
    } else {
        info.content
    };
    let mut remarks: Vec<String> = Vec::new();
    if !info.date.is_empty() {
        remarks.push(info.date.clone());
    }
    if !info.minutes.is_empty() {
        remarks.push(info.minutes.clone());
    }
    let mut extra = serde_json::Map::new();
    if !info.date.is_empty() {
        extra.insert("date".to_string(), json!(info.date));
    }
    if !info.minutes.is_empty() {
        extra.insert("duration".to_string(), json!(info.minutes));
    }
    if !info.actors.is_empty() {
        extra.insert("actors".to_string(), json!(info.actors));
    }
    if !remarks.is_empty() {
        extra.insert("remarks".to_string(), json!(remarks.join(" · ")));
    }
    let episodes = vec![episode_json(&format!("p:{slug}"), "正片", id)];
    json!({
        "id": id,
        "title": title,
        "cover": info.cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATEGORIES
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let page_suffix = if page > 1 {
        format!("/page-{page}")
    } else {
        String::new()
    };
    let (items, has_more) = match category_id {
        "vid" | "videos" => {
            let html = fetch(&format!("/videos{page_suffix}")).await?;
            let items = parse_videos(&html);
            let has_more = items.len() >= PER_PAGE_VIDEOS;
            (items, has_more)
        }
        "act" | "actresses" => {
            let html = fetch(&format!("/actresses{page_suffix}")).await?;
            let items = parse_actresses(&html);
            let has_more = items.len() >= PER_PAGE_ACTRESS;
            (items, has_more)
        }
        "ranking" => {
            let html = fetch("/ranking/video").await?;
            let items = parse_videos(&html);
            (items, false)
        }
        "frames" => {
            let html = fetch(&format!("/frames{page_suffix}")).await?;
            let items = parse_frames(&html);
            let has_more = items.len() >= PER_PAGE_FRAMES;
            (items, has_more)
        }
        other => {
            let Some(rest) = other.strip_prefix('c') else {
                return Ok(json!({"items": [], "has_more": false}));
            };
            let mut parts = rest.splitn(2, '_');
            let type_id: i64 = parts.next().unwrap_or("").parse().unwrap_or(1);
            let label_id = parts.next().unwrap_or("");
            if label_id.is_empty() || !label_id.chars().all(|c| c.is_ascii_digit()) {
                return Ok(json!({"items": [], "has_more": false}));
            }
            let slug = type_slug(type_id);
            let path = format!("/frames/type-{slug}/label-{label_id}{page_suffix}");
            let html = fetch(&path).await?;
            let items = parse_frames(&html);
            let has_more = items.len() >= PER_PAGE_FRAMES;
            (items, has_more)
        }
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let parts = dec(id);
    if parts.len() < 2 {
        return Err(ApiError::Internal("whos 详情缺少编号".into()));
    }
    match parts[0].as_str() {
        "a" => {
            let slug = parts[1].clone();
            if slug.is_empty() {
                return Err(ApiError::Internal("whos 女优缺少名字".into()));
            }
            let html = fetch(&format!("/actresses/{}", path_encode(&slug))).await?;
            let videos = parse_videos(&html);
            let name = if parts.len() > 2 && !parts[2].is_empty() {
                parts[2].clone()
            } else {
                slug.clone()
            };
            let cover = videos.first().and_then(|v| v.get("cover")).and_then(|c| c.as_str()).unwrap_or("").to_string();
            let mut episodes = Vec::new();
            for (i, v) in videos.iter().enumerate() {
                let vid = v.get("id").and_then(|x| x.as_str()).unwrap_or("");
                let vparts = dec(vid);
                let vslug = vparts.get(1).cloned().unwrap_or_default();
                if vslug.is_empty() {
                    continue;
                }
                let title = v
                    .get("title")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let title = if title.is_empty() {
                    format!("作品{}", i + 1)
                } else if title.chars().count() > 60 {
                    title.chars().take(60).collect()
                } else {
                    title
                };
                episodes.push(episode_json(&format!("p:{vslug}"), &title, id));
            }
            Ok(json!({
                "id": id,
                "title": name,
                "cover": cover,
                "synopsis": format!("whos.tv 演员：{name}\n本页作品 {} 部，点选集直接播。", videos.len()),
                "extra": {"remarks": format!("{} 部作品", videos.len())},
                "episodes": episodes,
            }))
        }
        "f" => {
            let slug = parts.get(2).cloned().unwrap_or_default();
            if slug.is_empty() {
                return Err(ApiError::Internal("whos 帧图缺少视频编号".into()));
            }
            let html = fetch(&format!("/videos/{}", path_encode(&slug))).await?;
            Ok(video_detail_json(&html, &slug, id))
        }
        _ => {
            let slug = parts[1].clone();
            if slug.is_empty() {
                return Err(ApiError::Internal("whos 详情缺少编号".into()));
            }
            let html = fetch(&format!("/videos/{}", path_encode(&slug))).await?;
            Ok(video_detail_json(&html, &slug, id))
        }
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let slug = video_id.strip_prefix("p:").unwrap_or(video_id);
    if slug.is_empty() {
        return Err(ApiError::Internal("whos 播放缺少编号".into()));
    }
    if slug.starts_with("http") {
        return Ok(json!({
            "url": slug,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/"), "Origin": BASE, "Accept": "*/*"},
        }));
    }
    let html = fetch(&format!("/videos/{}", path_encode(slug))).await?;
    let info = parse_video_info(&html);
    if info.m3u8.is_empty() {
        return Err(ApiError::Internal("whos 详情页未找到播放地址".into()));
    }
    Ok(json!({
        "url": info.m3u8,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/"), "Origin": BASE, "Accept": "*/*"},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let page = "1";
    let url = with_query(
        &format!("{BASE}/result"),
        &[("search", query), ("page", page)],
    );
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("whos 搜索 HTTP {status}")));
    }
    let html = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let items = parse_videos(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xor_url_roundtrip() {
        // jar 的 xorUrl：末两位为密钥；"https://x" 用密钥 0x2a 编码后应还原。
        let plain = "https://v.hersav.me/images/av/abc.jpg";
        let key: u8 = 0x2a;
        let mut hex = String::new();
        for b in plain.as_bytes() {
            hex.push_str(&format!("{:02x}", b ^ key));
        }
        hex.push_str("2a");
        assert_eq!(xor_url(&hex), plain);
        assert_eq!(xor_url(""), "");
        assert_eq!(xor_url("abcd"), "");
    }

    #[test]
    fn enc_dec_roundtrip() {
        let id = enc(&["v", "sdde-537", "标题", "https://x/c.jpg", ""]);
        let parts = dec(&id);
        assert_eq!(parts.len(), 5);
        assert_eq!(parts[0], "v");
        assert_eq!(parts[1], "sdde-537");
        assert_eq!(parts[2], "标题");
        assert_eq!(dec("!!!not-base64!!!").len(), 0);
    }

    #[test]
    fn time_and_sec() {
        assert_eq!(time_of("在 0:56:40 微笑"), "0:56:40");
        assert_eq!(time_of("无时间"), "");
        assert_eq!(sec_of("在 0:56:40 微笑"), "3400");
        assert_eq!(sec_of("1:02:03"), "3723");
        assert_eq!(slug_of("nps-079 在 0:56:40"), "nps-079");
    }

    #[test]
    fn parse_videos_skips_pagination() {
        let html = r#"<a href="/videos/sdde-537"><img src="https://x/c.jpg"><h3>片名一</h3></a><a href="/videos/page-2">2</a><a href="/videos/cjvr-067"><img src="https://x/d.jpg"><h3>片名二</h3></a>"#;
        let items = parse_videos(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["title"], "片名一");
        assert_eq!(items[0]["remark"], "SDDE-537");
        assert_eq!(items[1]["remark"], "CJVR-067");
        assert!(items[0]["cover"].as_str().unwrap().contains("x/c.jpg"));
    }

    #[test]
    fn parse_actresses_strips_frames_suffix() {
        let html = r#"<a href="/actresses/波多野結衣/frames"><img alt="波多野結衣" src="https://x/a.jpg"></a><a href="/actresses/page-2">2</a>"#;
        let items = parse_actresses(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "波多野結衣");
        assert_eq!(items[0]["remark"], "演员");
        let id = items[0]["id"].as_str().unwrap().to_string();
        assert_eq!(dec(&id)[1], "波多野結衣");
    }

    #[test]
    fn parse_frames_builds_name() {
        let html = r#"<a href="/frames/129737072"><img src="https://f.hersav.me/video_frames/abc"><div data-frame-title="nps-079 在 0:56:40 微笑面部特写"></div><span class="font-medium">NPS-079</span></a>"#;
        let items = parse_frames(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["remark"], "0:56:40");
        assert!(items[0]["title"].as_str().unwrap().contains("0:56:40"));
        let id = items[0]["id"].as_str().unwrap().to_string();
        let parts = dec(&id);
        assert_eq!(parts[0], "f");
        assert_eq!(parts[2], "nps-079");
    }

    #[test]
    fn parse_video_info_fields() {
        let html = r#"<h1>片名</h1><meta name="description" content="简介文字"><img src="https://v.hersav.me/images/av/76c534a897dc603d6cdf8ef9c4d746a6.jpg"><video data-preview-source="https://v.hersav.me/abc/abc.m3u8"></video><span>时长：</span><span>146 分钟</span><span>发行日期</span><span>2018-04-26</span>"#;
        let info = parse_video_info(html);
        assert_eq!(info.title, "片名");
        assert_eq!(info.content, "简介文字");
        assert!(info.cover.ends_with(".jpg"));
        assert!(info.m3u8.ends_with(".m3u8"));
        assert_eq!(info.minutes, "146 分钟");
        assert_eq!(info.date, "2018-04-26");
    }

    #[test]
    fn parse_video_info_fallback_m3u8() {
        let html = "xxx https://v.hersav.me/76c534a897dc603d6cdf8ef9c4d746a6/76c534a897dc603d6cdf8ef9c4d746a6.m3u8 yyy";
        let info = parse_video_info(html);
        assert!(info.m3u8.contains("v.hersav.me"));
    }

    #[test]
    fn categories_are_sixteen() {
        assert_eq!(CATEGORIES.len(), 16);
        assert_eq!(CATEGORIES[0], ("vid", "影片库"));
        assert_eq!(CATEGORIES[3], ("frames", "帧图"));
        assert_eq!(CATEGORIES[15], ("c1_1110", "白色内裤"));
        assert_eq!(type_slug(1), "clothes");
        assert_eq!(type_slug(8), "other");
    }

    // 以下为联网实测（默认忽略，手动 `cargo test --lib wohs -- --ignored` 跑）：
    // 2026-11-06 实测全过，见模块头注释；留着供以后复验。
    #[tokio::test]
    #[ignore]
    async fn live_categories() {
        let cats = categories().await.unwrap();
        let list = cats["categories"].as_array().unwrap();
        assert_eq!(list.len(), 16);
        assert_eq!(list[0]["id"], "vid");
    }

    #[tokio::test]
    #[ignore]
    async fn live_catalog_vid_and_page2() {
        let r = catalog("vid", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        assert_eq!(items.len(), 12);
        assert!(!items[0]["cover"].as_str().unwrap_or("").is_empty());
        assert_eq!(r["has_more"], true);
        let r2 = catalog("vid", 2).await.unwrap();
        let items2 = r2["items"].as_array().unwrap();
        assert_eq!(items2.len(), 12);
        assert_ne!(items[0]["id"], items2[0]["id"]);
    }

    #[tokio::test]
    #[ignore]
    async fn live_catalog_act_ranking_frames_tag() {
        let act = catalog("act", 1).await.unwrap();
        assert_eq!(act["items"].as_array().unwrap().len(), 18);
        let rank = catalog("ranking", 1).await.unwrap();
        assert!(!rank["items"].as_array().unwrap().is_empty());
        assert_eq!(rank["has_more"], false);
        let frames = catalog("frames", 1).await.unwrap();
        assert_eq!(frames["items"].as_array().unwrap().len(), 20);
        let tag = catalog("c1_49", 1).await.unwrap();
        assert_eq!(tag["items"].as_array().unwrap().len(), 20);
    }

    #[tokio::test]
    #[ignore]
    async fn live_detail_and_play() {
        let r = catalog("vid", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        let id = items[0]["id"].as_str().unwrap().to_string();
        let d = detail(&id).await.unwrap();
        assert!(!d["title"].as_str().unwrap_or("").is_empty());
        assert!(!d["cover"].as_str().unwrap_or("").is_empty());
        let eps = d["episodes"].as_array().unwrap();
        assert!(!eps.is_empty());
        let vid = eps[0]["video_id"].as_str().unwrap().to_string();
        let p = play(&vid).await.unwrap();
        let url = p["url"].as_str().unwrap().to_string();
        assert!(url.ends_with(".m3u8"), "{url}");
        assert!(p.get("header").is_some());
    }

    #[tokio::test]
    #[ignore]
    async fn live_actress_detail() {
        let r = catalog("act", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        let id = items[0]["id"].as_str().unwrap().to_string();
        let d = detail(&id).await.unwrap();
        assert!(!d["title"].as_str().unwrap_or("").is_empty());
        let eps = d["episodes"].as_array().unwrap();
        assert!(!eps.is_empty());
        // 女优详情的分集就是她的作品，取流走同一条 play 路。
        let vid = eps[0]["video_id"].as_str().unwrap().to_string();
        assert!(vid.starts_with("p:"));
    }

    #[tokio::test]
    #[ignore]
    async fn live_search() {
        let r = search("波多野").await.unwrap();
        let items = r["items"].as_array().unwrap();
        assert!(!items.is_empty());
    }
}
