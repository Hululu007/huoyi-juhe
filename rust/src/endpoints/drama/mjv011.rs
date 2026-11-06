//! mjv011：`https://mjv011.com`。
//!
//! 来源 jar 类 `ZakaMjv011Amns`（对照 py `mjv011_______31_05m6.py`）。
//! 年龄门：先 GET 年龄页，Cookie `YES_Eighteen=IamOverEighteenYearsOld`；
//! 取页短于 3000 且含 `同意(enter)` / `IamOverEighteenYearsOld` 时重走
//! 年龄门再取。分类从年龄门页正则抓 `_random/all`（去 `(数字)` 后缀，
//! 去含 random/隨機/随机/近作的项），前置 `home` 与 `content_news/all`；
//! 抓不到时用写死的 15 类。列表先试 `video_9s` 块，回退通用 post 正则；
//! 小说类走无封面文本解析。详情视频须同时取到 `hadeedg252` /
//! `hcdeedg252` / AES key / AES iv / `mvarr['10_1']`，每集出 480P /
//! 720P / 1080P 三条；`decryptId` 为：按 `chr(base+97)` 切分，每段按
//! `base` 进制解析后异或 `hadeedg252`，拼成 Base64 再 AES/CBC/NoPadding
//! 解密（key/iv 各取前 16 字节）去 PKCS7。小说详情出 `novel://`，
//! 图片详情（18H/doujin/cg/cwp）出 `pics://`。取流走
//! `/js/player/play.php` 的 `videoSources` 按清晰度匹配，回退页内
//! 第一个 `.m3u8`。
//!
//! 注意：中文分类下的 filter 子项（如“蘿莉塔”）是筛选项不是顶级分类，
//! 核心 drama 模块无 filter 概念，不进核心。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://mjv011.com";
const AGE_URL: &str = "https://mjv011.com/zh/chinese_IamOverEighteenYearsOld/19/index.html";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const COOKIE: &str = "YES_Eighteen=IamOverEighteenYearsOld";

const FALLBACK_CLASSES: &[(&str, &str)] = &[
    ("chinese_random/all", "中文字幕"),
    ("censored_random/all", "有码"),
    ("uncensored_random/all", "无码"),
    ("amateurjav_random/all", "素人"),
    ("reducing-mosaic_random/all", "无码破解"),
    ("animation_random/all", "H动画"),
    ("CensoredAnimation_random/all", "H有码动画"),
    ("UncensoredAnimation_random/all", "H无码动画"),
    ("tdAnimation_random/all", "H_3D动画"),
    ("dt_random/all", "国产自拍"),
    ("18H_random/all", "18H漫画"),
    ("doujin_random/all", "18H短篇同人"),
    ("cg_random/all", "写真图集"),
    ("cwp_random/all", "国产写真"),
    ("novel_random/all", "小说"),
];

fn re_classes() -> &'static Regex {
    static RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"href=['"](https://mjv011\.com/zh/([^'"/_]+)_random/all/index\.html)['"][^>]*>([^<]+)</a>"#)
            .unwrap()
    });
    &RE
}

fn re_post1() -> &'static Regex {
    static RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"(?s)<div class='post'>\s*<a[^>]*href="([^"]+)"[^>]*><img[^>]*src='([^']+)'[^>]*>\s*</a>\s*<div class='con'>\s*<h3[^>]*><a[^>]*>([^<]+)</a></h3>(?:\s*<div class='meta'>([^<]*)</div>)?"#)
            .unwrap()
    });
    &RE
}

fn re_post2() -> &'static Regex {
    static RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"(?si)<a[^>]+href="([^"]*zh/[^"]*_content/[^"]*)"[^>]*>.*?<img[^>]+src="([^"]+)"[^>]*>.*?<(?:h3|h2|h4|div\s+class="title")[^>]*>(.*?)</"#)
            .unwrap()
    });
    &RE
}

fn re_text_post() -> &'static Regex {
    static RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"(?s)<div class='post'>\s*<div class='con'>\s*<h3[^>]*><a[^>]*href="([^"]+)"[^>]*>([^<]+)</a></h3>"#)
            .unwrap()
    });
    &RE
}

fn re_content_link() -> &'static Regex {
    static RE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"/([^/]+)_content/(\d+)/([^/]+)\.html").unwrap());
    &RE
}

fn first_group(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

fn strip_tags(s: &str) -> String {
    let re = Regex::new(r"<[^>]+>").unwrap();
    re.replace_all(s, "").trim().to_string()
}

fn is_novel(tid: &str) -> bool {
    tid.starts_with("novel")
}

fn is_image(tid: &str) -> bool {
    ["18H", "doujin", "cg", "cwp"]
        .iter()
        .any(|p| tid.starts_with(p))
}

async fn fetch(url: &str) -> String {
    let req = || {
        client().map(|c| {
            c.get(url)
                .header("User-Agent", UA)
                .header(
                    "Accept",
                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                )
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .header("Referer", format!("{HOST}/"))
                .header("Cookie", COOKIE)
        })
    };
    let Ok(reqb) = req() else {
        return String::new();
    };
    let Ok(resp) = reqb.send().await else {
        return String::new();
    };
    if !resp.status().is_success() {
        return String::new();
    }
    let Ok(text) = resp.text().await else {
        return String::new();
    };
    if text.len() < 3000
        && (text.contains("同意(enter)") || text.contains("IamOverEighteenYearsOld"))
    {
        // 重走年龄门再取一次。
        if let Ok(c) = client() {
            let _ = c
                .get(AGE_URL)
                .header("User-Agent", UA)
                .header("Referer", format!("{HOST}/"))
                .header("Cookie", COOKIE)
                .send()
                .await;
        }
        let Ok(req2) = req() else {
            return String::new();
        };
        let Ok(resp2) = req2.send().await else {
            return String::new();
        };
        if !resp2.status().is_success() {
            return String::new();
        }
        return resp2.text().await.unwrap_or_default();
    }
    text
}

/// 年龄门页的当天日期（UTC；Howard Hinnant 民用日期算法）。
fn today_ymd() -> (i64, u32, u32) {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn parse_posts(text: &str, tid: &str) -> Vec<Value> {
    if is_novel(tid) {
        let mut items = Vec::new();
        for cap in re_text_post().captures_iter(text) {
            let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            let title = cap.get(2).map(|m| m.as_str()).unwrap_or("");
            let Some(l) = re_content_link().captures(href) else {
                continue;
            };
            let vod_id = format!(
                "{}#{}#{}",
                l.get(1).unwrap().as_str(),
                l.get(2).unwrap().as_str(),
                l.get(3).unwrap().as_str()
            );
            items.push(item_json(&vod_id, title.trim(), "", ""));
        }
        return items;
    }
    let mut items = Vec::new();
    let mut found = false;
    for cap in re_post1().captures_iter(text) {
        found = true;
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let pic = cap.get(2).map(|m| m.as_str()).unwrap_or("");
        let title = cap.get(3).map(|m| m.as_str()).unwrap_or("");
        let date = cap.get(4).map(|m| m.as_str()).unwrap_or("");
        let Some(l) = re_content_link().captures(href) else {
            continue;
        };
        let vod_id = format!(
            "{}#{}#{}",
            l.get(1).unwrap().as_str(),
            l.get(2).unwrap().as_str(),
            l.get(3).unwrap().as_str()
        );
        items.push(item_json(&vod_id, title.trim(), pic, date.trim()));
    }
    if found {
        return items;
    }
    for cap in re_post2().captures_iter(text) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let pic = cap.get(2).map(|m| m.as_str()).unwrap_or("");
        let title = cap.get(3).map(|m| m.as_str()).unwrap_or("");
        let Some(l) = re_content_link().captures(href) else {
            continue;
        };
        let vod_id = format!(
            "{}#{}#{}",
            l.get(1).unwrap().as_str(),
            l.get(2).unwrap().as_str(),
            l.get(3).unwrap().as_str()
        );
        items.push(item_json(&vod_id, &strip_tags(title), pic, ""));
    }
    items
}

fn load_classes(text: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in re_classes().captures_iter(text) {
        let key = cap.get(2).map(|m| m.as_str()).unwrap_or("");
        let name = cap.get(3).map(|m| m.as_str()).unwrap_or("");
        let re_num = Regex::new(r"\s*\(\d+\)\s*$").unwrap();
        let name = re_num.replace(name.trim(), "").to_string();
        if ["random", "隨機", "随机", "近作"]
            .iter()
            .any(|x| name.contains(x))
        {
            continue;
        }
        let tid = format!("{key}_random/all");
        if !seen.insert(tid.clone()) {
            continue;
        }
        out.push(category_json(&tid, &name));
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let text = fetch(AGE_URL).await;
    let mut classes = load_classes(&text);
    if classes.is_empty() {
        classes = FALLBACK_CLASSES
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect();
    }
    let mut all = vec![
        category_json("home", "首页"),
        category_json("content_news/all", "每日更新"),
    ];
    all.extend(classes);
    Ok(json!({"categories": all}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if category_id == "home" {
        let text = fetch(AGE_URL).await;
        let items = parse_posts(&text, "chinese_random/all");
        let per_page = 20usize;
        let total = items.len();
        let start = ((page - 1) as usize * per_page).min(total);
        let end = (start + per_page).min(total);
        let page_items: Vec<Value> = items[start..end].to_vec();
        let has_more = end < total;
        return Ok(json!({"items": page_items, "has_more": has_more}));
    }
    if category_id == "content_news/all" {
        let (y, m, d) = today_ymd();
        let url = format!("{HOST}/zh/content_news/all/{y:04}-{m:02}-{d:02}.html");
        let text = fetch(&url).await;
        let items = parse_posts(&text, category_id);
        return Ok(json!({"items": items, "has_more": false}));
    }
    if let Some(kw) = category_id.strip_prefix("search_") {
        let enc = url::form_urlencoded::byte_serialize(kw.as_bytes())
            .collect::<String>()
            .replace('+', "%20");
        let url = format!("{HOST}/zh/chinese_search/all/{enc}/{page}.html");
        let text = fetch(&url).await;
        let items = parse_posts(&text, category_id);
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    let mut base_tid = category_id.to_string();
    for suffix in ["_random/all", "_random", "_list/all"] {
        if let Some(s) = base_tid.strip_suffix(suffix) {
            base_tid = s.to_string();
            break;
        }
    }
    let mut candidates: Vec<String> = Vec::new();
    if page == 1 {
        candidates.push(format!("{HOST}/zh/{base_tid}_list/all/index.html"));
        candidates.push(format!("{HOST}/zh/{base_tid}_random/all/index.html"));
    }
    candidates.push(format!("{HOST}/zh/{base_tid}_list/all/{page}.html"));
    candidates.push(format!("{HOST}/zh/{base_tid}_list/index_{page}.html"));
    candidates.push(format!("{HOST}/zh/{base_tid}/{page}.html"));
    candidates.push(format!("{HOST}/zh/{base_tid}/page/{page}.html"));
    candidates.push(format!("{HOST}/zh/{base_tid}_random/all/{page}.html"));
    if page > 1 {
        candidates.push(format!("{HOST}/zh/{base_tid}_list/index_{page}.html"));
    }
    let mut items: Vec<Value> = Vec::new();
    for url in candidates {
        let text = fetch(&url).await;
        if text.is_empty() {
            continue;
        }
        items = parse_posts(&text, category_id);
        if !items.is_empty() {
            break;
        }
    }
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

/// `decryptId`：按 `chr(base+97)` 切分，每段按 `base` 进制解析后异或
/// `xor_key`，拼成 Base64 再 AES/CBC/NoPadding 解密（key/iv 各取前 16
/// 字节），去 PKCS7 填充；异常返回空串。
fn decrypt_id(enc: &str, xor_key: i64, base: i64, aes_key: &str, aes_iv: &str) -> String {
    if !(2..=36).contains(&base) {
        return String::new();
    }
    let Some(sep) = char::from_u32((base + 97) as u32) else {
        return String::new();
    };
    let mut s1 = String::new();
    for part in enc.split(sep) {
        if part.is_empty() {
            continue;
        }
        let Ok(v) = i64::from_str_radix(part, base as u32) else {
            return String::new();
        };
        let x = v ^ xor_key;
        let Some(c) = char::from_u32(x as u32) else {
            return String::new();
        };
        if x < 0 || x > 0x10ffff {
            return String::new();
        }
        s1.push(c);
    }
    use base64::Engine as _;
    let mut padded = s1.clone();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let Ok(data) = base64::engine::general_purpose::STANDARD.decode(padded.as_bytes()) else {
        return String::new();
    };
    if data.is_empty() || data.len() % 16 != 0 {
        return String::new();
    }
    let key = &aes_key.as_bytes()[..aes_key.len().min(16)];
    let iv = &aes_iv.as_bytes()[..aes_iv.len().min(16)];
    if key.len() < 16 || iv.len() < 16 {
        return String::new();
    }
    let plain = crate::crypto::aes_cbc_decrypt(&data, key, iv);
    let unpadded = crate::crypto::pkcs7_unpad(&plain, 16);
    String::from_utf8(unpadded.to_vec()).unwrap_or_default()
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let parts: Vec<&str> = id.splitn(3, '#').collect();
    if parts.len() != 3 {
        return Err(ApiError::BadRequest("bad mjv011 id".into()));
    }
    let (ctype, num, slug) = (parts[0], parts[1], parts[2]);
    let url = format!("{HOST}/zh/{ctype}_content/{num}/{slug}.html");
    let text = fetch(&url).await;
    if text.is_empty() {
        return Ok(
            json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}),
        );
    }
    let title_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let mut title = title_re
        .captures(&text)
        .map(|c| strip_tags(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        let t_re = Regex::new(r"<title>([^<]+)</title>").unwrap();
        title = t_re
            .captures(&text)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
    }
    if is_novel(ctype) {
        let mut content = String::new();
        let c_re = Regex::new(r#"(?s)id=['"]novel_content_txtsize['"][^>]*>(.*?)</div>"#).unwrap();
        if let Some(c) = c_re.captures(&text).and_then(|c| c.get(1)) {
            content = strip_tags(c.as_str())
                .replace("&nbsp;", " ")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
        }
        if content.is_empty() {
            let c2_re = Regex::new(
                r"(?s)<span class='content_18h_wpcg'>([\s\S]*?)</span>\s*<div class='contents'",
            )
            .unwrap();
            if let Some(c) = c2_re.captures(&text).and_then(|c| c.get(1)) {
                content = strip_tags(c.as_str())
                    .replace("&nbsp;", " ")
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ");
            }
        }
        if content.chars().count() > 3000 {
            content = format!("{}...", content.chars().take(3000).collect::<String>());
        }
        let novel_json = json!({"title": title, "content": content}).to_string();
        let play_url = format!("阅读$novel://{novel_json}");
        return Ok(json!({
            "id": id, "title": title, "cover": "", "synopsis": "",
            "extra": {"vod_tag": "text", "vod_player": "书"},
            "episodes": [episode_json(&format!("novel://{novel_json}"), "阅读", id)],
            "vod_play_from": "小说",
            "vod_play_url": play_url,
        }));
    }
    if is_image(ctype) {
        let cover_re = Regex::new(r#""thumbnailUrl"\s*:\s*"([^"]+)""#).unwrap();
        let cover = first_group(&cover_re, &text);
        let img_re =
            Regex::new(r#"(?i)src=['"]([^'"]*eemmhh02\.com/[^'"]+\.(?:jpg|png|webp))['"]"#)
                .unwrap();
        let mut seen = std::collections::HashSet::new();
        let mut big: Vec<String> = Vec::new();
        for cap in img_re.captures_iter(&text) {
            let u = cap.get(1).unwrap().as_str().to_string();
            if seen.insert(u.clone()) {
                big.push(u);
            }
        }
        if big.is_empty() {
            return Ok(
                json!({"id": id, "title": title, "cover": cover, "synopsis": "", "extra": {}, "episodes": []}),
            );
        }
        let pics = big.join("&&");
        let play_url = format!("查看$pics://{pics}");
        return Ok(json!({
            "id": id, "title": title, "cover": cover,
            "synopsis": format!("共 {} 张图片", big.len()),
            "extra": {"vod_tag": "image", "vod_player": "画"},
            "episodes": [episode_json(&format!("pics://{pics}"), "查看", id)],
            "vod_play_from": "图片",
            "vod_play_url": play_url,
        }));
    }
    let cover_re = Regex::new(r#""thumbnailUrl"\s*:\s*"([^"]+)""#).unwrap();
    let mut cover = first_group(&cover_re, &text);
    if cover.is_empty() {
        let og_re = Regex::new(r#"<meta[^>]*property="og:image"[^>]*content="([^"]+)""#).unwrap();
        cover = first_group(&og_re, &text);
    }
    if cover.is_empty() {
        let p_re = Regex::new(r"(?s)<div class='post'>.*?<img[^>]*src='([^']+)'").unwrap();
        cover = first_group(&p_re, &text);
    }
    let xor_re = Regex::new(r"hadeedg252=(\d+)").unwrap();
    let base_re = Regex::new(r"hcdeedg252=(\d+)").unwrap();
    let key_re = Regex::new(r"var argdeqweqweqwe = '([^']+)'").unwrap();
    let iv_re = Regex::new(r"var hdddedg252 = '([^']+)'").unwrap();
    let mv_re = Regex::new(r"(?s)mvarr\['10_1'\]=(\[.*?\]);").unwrap();
    let xor_s = first_group(&xor_re, &text);
    let base_s = first_group(&base_re, &text);
    let aes_key = first_group(&key_re, &text);
    let aes_iv = first_group(&iv_re, &text);
    let mvarr = first_group(&mv_re, &text);
    let mut episodes: Vec<Value> = Vec::new();
    if !xor_s.is_empty()
        && !base_s.is_empty()
        && !aes_key.is_empty()
        && !aes_iv.is_empty()
        && !mvarr.is_empty()
    {
        if let (Ok(xor_key), Ok(base)) = (xor_s.parse::<i64>(), base_s.parse::<i64>()) {
            let item_re =
                Regex::new(r"\['([^']*)','([^']*)','([^']*)','([^']*)','([^']*)','([^']*)'\]")
                    .unwrap();
            for cap in item_re.captures_iter(&mvarr) {
                let enc = cap.get(2).map(|m| m.as_str()).unwrap_or("");
                let prefix = cap.get(4).map(|m| m.as_str()).unwrap_or("");
                if enc.is_empty() || prefix.is_empty() {
                    continue;
                }
                let pid = decrypt_id(enc, xor_key, base, &aes_key, &aes_iv);
                if pid.is_empty() {
                    continue;
                }
                for (res, label) in [("480", "480P"), ("720", "720P"), ("1080", "1080P")] {
                    episodes.push(episode_json(
                        &format!("{num}|{slug}|{pid}|{res}"),
                        label,
                        id,
                    ));
                }
            }
        }
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover, "synopsis": "",
        "extra": {}, "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let url = format!("{HOST}/zh/chinese_search/all/{enc}/1.html");
    let text = fetch(&url).await;
    let items = parse_posts(&text, "search");
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("novel://") || video_id.starts_with("pics://") {
        return Ok(json!({"url": video_id}));
    }
    let parts: Vec<&str> = video_id.splitn(4, '|').collect();
    if parts.len() != 4 {
        return Err(ApiError::BadRequest("bad mjv011 episode id".into()));
    }
    let (_num, _slug, pid, res) = (parts[0], parts[1], parts[2], parts[3]);
    let url = format!("{HOST}/js/player/play.php?numresolution={res}&lo=on&id={pid}");
    let text = fetch(&url).await;
    let mut m3u8 = String::new();
    if !text.is_empty() {
        let vs_re = Regex::new(r"(?s)videoSources\s*=\s*(\[.*?\]);").unwrap();
        if let Some(cap) = vs_re.captures(&text).and_then(|c| c.get(1)) {
            let arr = cap.as_str();
            let src_re = Regex::new(r"src:\s*'([^']+)'[^}]*?size:\s*(\d+)").unwrap();
            let mut first = String::new();
            let target: i64 = res.parse().unwrap_or(0);
            for s in src_re.captures_iter(arr) {
                let u = s.get(1).unwrap().as_str();
                if first.is_empty() {
                    first = u.to_string();
                }
                if let Ok(sz) = s.get(2).unwrap().as_str().parse::<i64>() {
                    if sz == target {
                        m3u8 = u.to_string();
                        break;
                    }
                }
            }
            if m3u8.is_empty() {
                m3u8 = first;
            }
        }
        if m3u8.is_empty() {
            let any_re = Regex::new(r#"https?://[^\s\"<>']+?\.m3u8"#).unwrap();
            m3u8 = first_group(&any_re, &text);
        }
    }
    if m3u8.is_empty() {
        return Err(ApiError::Internal("mjv011 no stream found".into()));
    }
    Ok(json!({"url": m3u8, "header": {"Referer": format!("{HOST}/")}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypt_id_bad_base_returns_empty() {
        assert_eq!(decrypt_id("abc", 1, 1, "k", "v"), "");
        assert_eq!(decrypt_id("abc", 1, 37, "k", "v"), "");
    }

    #[test]
    fn today_ymd_shape() {
        let (y, m, d) = today_ymd();
        assert!(y >= 2026 && m >= 1 && m <= 12 && d >= 1 && d <= 31);
    }

    #[test]
    fn parse_posts_video9s() {
        let html = r#"<div class='post'> <a href="/zh/chinese_content/123/abc.html"><img src='https://x/y.jpg'> </a> <div class='con'> <h3><a>标题</a></h3> <div class='meta'>2026-01-01</div>"#;
        let items = parse_posts(html, "chinese_random/all");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "chinese#123#abc");
    }
}
