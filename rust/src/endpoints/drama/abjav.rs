//! 🔞ABJAV：abjav.com，KVS 架构的 JAV tube（JSON API，不抓 HTML）。
//!
//! 首页是 JS 壳（app.js），内容走 API：
//! 列表 `/api/json/videos2/86400/str/{sort}/60/{section}.{object}.{page}.all...json`
//! （sort=latest-updates/most-popular/top-rated；分类 section=categories，
//! object=分类 dir）；搜索 `/api/videos2.php?params=86400/str/relevance/60/search..{page}.all...&s={词}`；
//! 分类表 `/api/json/categories/14400/str.toptn.en.json`（198 个）；
//! 详情 `/api/json/video/86400/{id/1e6*1e6}/{id/1e3*1e3}/{id}.json`；
//! 取流 `/api/videofile.php?video_id={id}&lifetime=8640000`，
//! video_url 是 base164 编码（65 字符表，含西里尔同形字母，
//! 末尾 `~` 为填充位），解出 `/get_file/5/{hash}/{id}.mp4/?d=&br=&ti=`，
//! 拼 `&f=video.m3u8` 得 HLS，再跟 301 到 ahcdn 最终清单。
//! 验门（2026-11-06 本机出口实测）：最新列表 60 条/页、4535 页；
//! asian 分类 p1/p2 各 60 条不重合（总量 249488）；搜索 JAV 60 条、
//! 总量 17347；详情 378393（She Holds Two Men…，07:52）；
//! HLS 清单 48 分片/472.0 秒，与卡片 07:52 精确对上；
//! mp4 直链 Range 206 + ftypisom。
//! 分类与站导航 1:1（最新/最受欢迎/评分最高 + 分类表全量；
//! 女优/频道/标签索引为独立体系，本模块不含）。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://abjav.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类表接口挂了时的静态兜底：按总量排前 15 的分类（dir 实测）。
const FALLBACK_CATS: &[(&str, &str)] = &[
    ("asian", "Asian"),
    ("japanese", "Japanese"),
    ("hd", "HD"),
    ("censored", "Censored"),
    ("uncensored", "Uncensored"),
    ("big-tits", "Big Tits"),
    ("amateur", "Amateur"),
    ("milf", "MILF"),
    ("pov", "POV"),
    ("creampie", "Creampie"),
    ("brunette", "Brunette"),
    ("hairy", "Hairy"),
    ("toys", "Toys"),
    ("deepthroat", "Deepthroat"),
    ("shaved", "Shaved"),
];

/// base164 字母表（与 app.js 的 base164_decode 一致）：
/// 前 26 个大写里 А/В/С/Е/М 为西里尔字母（U+0410/0412/0421/0415/041C），
/// 其余为拉丁字母；`~`（下标 64）为填充位。
const B164_ALPHABET: &str = "\u{410}\u{412}\u{421}D\u{415}FGHIJKL\u{41C}NOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,~";

async fn fetch_json(url: &str) -> ApiResult<Value> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, */*")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("ABJAV 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    serde_json::from_str(&text).map_err(|e| ApiError::Internal(e.to_string()))
}

/// base164 解码：4 字符一组出 3 字节，下标 64 的字符对应字节跳过；
/// 再做 %XX 还原（与 JS 的 unescape 一致）。
fn base164_decode(input: &str) -> Option<String> {
    let alpha: Vec<char> = B164_ALPHABET.chars().collect();
    let cleaned: Vec<char> = input.chars().filter(|c| alpha.contains(c)).collect();
    let mut bytes: Vec<u8> = Vec::with_capacity(cleaned.len() * 3 / 4);
    let mut n = 0usize;
    while n + 4 <= cleaned.len() {
        let idx = |c: char| alpha.iter().position(|&a| a == c).unwrap_or(64);
        let o = idx(cleaned[n]);
        let r = idx(cleaned[n + 1]);
        let a = idx(cleaned[n + 2]);
        let c = idx(cleaned[n + 3]);
        let b0 = ((o << 2) | (r >> 4)) as u8;
        let b1 = (((15 & r) << 4) | (a >> 2)) as u8;
        let b2 = (((3 & a) << 6) | c) as u8;
        bytes.push(b0);
        if a != 64 {
            bytes.push(b1);
        }
        if c != 64 {
            bytes.push(b2);
        }
        n += 4;
    }
    // %XX 还原。
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = hex_val(bytes[i + 1]);
            let lo = hex_val(bytes[i + 2]);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).ok()
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn list_url(section: &str, object_id: &str, sort: &str, page: i64) -> String {
    format!("{HOST}/api/json/videos2/86400/str/{sort}/60/{section}.{object_id}.{page}.all...json")
}

/// videos2 的 `videos[]` 数组转卡片。
fn parse_videos(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let Some(arr) = data.get("videos").and_then(|v| v.as_array()) else {
        return items;
    };
    let mut seen: Vec<String> = Vec::new();
    for v in arr {
        let video_id = text_of(v, &["video_id"]);
        let dir = text_of(v, &["dir"]);
        if video_id.is_empty() || dir.is_empty() {
            continue;
        }
        let id = format!("{HOST}/video/{video_id}/{dir}/");
        if seen.contains(&id) {
            continue;
        }
        let title = text_of(v, &["title"]);
        if title.is_empty() {
            continue;
        }
        let cover = text_of(v, &["scr"]);
        let remark = text_of(v, &["duration"]);
        seen.push(id.clone());
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 从详情页 URL 或裸 id 里抠数字 id。
fn numeric_id(input: &str) -> String {
    let trimmed = input.split('$').last().unwrap_or(input);
    // 形如 /video/378393/dir/：取 /video/ 后的数字段。
    if let Some(p) = trimmed.find("/video/") {
        let rest = &trimmed[p + 7..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if !digits.is_empty() {
            return digits;
        }
    }
    trimmed.chars().filter(|c| c.is_ascii_digit()).collect()
}

/// 跟随跳转拿最终地址：直接 GET 取最终 URL，不读 body；
/// 不用 HEAD——ahcdn 对 HEAD 的跳转与 GET 不一致（会落到 _TPL_.mp4）。
async fn resolve_redirect(url: &str, referer: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", referer)
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

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = vec![
        category_json("latest-updates", "最新"),
        category_json("most-popular", "最受欢迎"),
        category_json("top-rated", "评分最高"),
    ];
    // 分类表全量拉取；失败时用静态前 15 兜底。
    match fetch_json(&format!(
        "{HOST}/api/json/categories/14400/str.toptn.en.json"
    ))
    .await
    {
        Ok(data) => {
            if let Some(arr) = data.get("categories").and_then(|v| v.as_array()) {
                for c in arr {
                    let dir = text_of(c, &["dir"]);
                    let title = text_of(c, &["title"]);
                    if dir.is_empty() || title.is_empty() {
                        continue;
                    }
                    list.push(category_json(&format!("category:{dir}"), &title));
                }
            }
            if list.len() <= 3 {
                for (dir, title) in FALLBACK_CATS {
                    list.push(category_json(&format!("category:{dir}"), title));
                }
            }
        }
        Err(_) => {
            for (dir, title) in FALLBACK_CATS {
                list.push(category_json(&format!("category:{dir}"), title));
            }
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = match category_id {
        "latest-updates" | "most-popular" | "top-rated" => list_url("", "", category_id, page),
        _ => {
            if let Some(dir) = category_id.strip_prefix("category:") {
                list_url("categories", dir, "latest-updates", page)
            } else {
                list_url("", "", "latest-updates", page)
            }
        }
    };
    let data = fetch_json(&url).await?;
    let items = parse_videos(&data);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = numeric_id(series_id);
    if id.is_empty() {
        return Err(ApiError::Internal("ABJAV 详情缺少视频 id".into()));
    }
    let id_num: i64 = id.parse().unwrap_or(0);
    let million = (id_num / 1_000_000) * 1_000_000;
    let thousand = (id_num / 1_000) * 1_000;
    let url = format!("{HOST}/api/json/video/86400/{million}/{thousand}/{id}.json");
    let data = fetch_json(&url).await?;
    let video = data.get("video").cloned().unwrap_or(Value::Null);
    let title = text_of(&video, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("ABJAV 未返回影片资料".into()));
    }
    let cover = text_of(&video, &["thumb"]);
    let mut synopsis = String::new();
    let duration = text_of(&video, &["duration"]);
    if !duration.is_empty() {
        synopsis.push_str(&format!("时长：{duration}"));
    }
    if let Some(channel) = video.get("channel") {
        let name = text_of(channel, &["title"]);
        if !name.is_empty() {
            if !synopsis.is_empty() {
                synopsis.push('\n');
            }
            synopsis.push_str(&format!("频道：{name}"));
        }
    }
    if let Some(tags) = video.get("tags").and_then(|v| v.as_object()) {
        let mut names: Vec<String> = Vec::new();
        for (_, t) in tags {
            let name = text_of(t, &["title"]);
            if !name.is_empty() && !names.contains(&name) {
                names.push(name);
            }
        }
        if !names.is_empty() {
            if !synopsis.is_empty() {
                synopsis.push('\n');
            }
            synopsis.push_str(&format!("标签：{}", names.join("、")));
        }
    }
    let page_url = format!("{HOST}/video/{}/{}/", id, text_of(&video, &["dir"]));
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&page_url, "正片", &page_url)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let id = numeric_id(&page_url);
    if id.is_empty() {
        return Err(ApiError::Internal("ABJAV 播放缺少视频 id".into()));
    }
    let url = format!("{HOST}/api/videofile.php?video_id={id}&lifetime=8640000");
    let data = fetch_json(&url).await?;
    let arr = data.as_array().cloned().unwrap_or_default();
    // 优先默认 mp4（is_default=1），否则取第一条。
    let mut chosen: Option<&Value> = None;
    for item in &arr {
        if text_of(item, &["format"]) == ".mp4" {
            chosen = Some(item);
            break;
        }
    }
    if chosen.is_none() {
        chosen = arr.first();
    }
    let Some(item) = chosen else {
        return Err(ApiError::Internal("ABJAV 未取到播放文件".into()));
    };
    let encoded = text_of(item, &["video_url"]);
    let path = base164_decode(&encoded)
        .ok_or_else(|| ApiError::Internal("ABJAV 播放地址解码失败".into()))?;
    if !path.starts_with("/get_file/") {
        return Err(ApiError::Internal("ABJAV 播放地址解码失败".into()));
    }
    let hls_url = format!("{HOST}{path}&f=video.m3u8");
    // 跟 301 到 ahcdn 最终清单；跟不到时直接回站内地址。
    let url = resolve_redirect(&hls_url, &page_url)
        .await
        .unwrap_or(hls_url);
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/api/videos2.php?params=86400/str/relevance/60/search..1.all...&s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let data = fetch_json(&url).await?;
    let items = parse_videos(&data);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实取流响应里的 video_url（378393 的 .mp4 档），Node/Python 实跑解出。
    const VIDEO_URL_B164: &str = "L2dldF9maWxlLzUv\u{41c}TI5YTlm\u{41c}WFjNm\u{415}yYmFjODNiZmQ2YjcxYz\u{412}kY2Y4\u{41c}jNlNjU1\u{41c}WIxNDNiLz\u{41c}3OD\u{410}w\u{41c}\u{421}8zNzgzOT\u{41c}v\u{41c}zc4\u{41c}zkzLm1wN\u{421}8,ZD00NzImYnI9\u{41c}jc2JnRpPT\u{415}3OT\u{41c}5\u{41c}jgzNz\u{410}~";

    #[test]
    fn base164_decode_known_vector() {
        assert_eq!(
            base164_decode(VIDEO_URL_B164).unwrap(),
            "/get_file/5/129a9f1ac6a2bac83bfd6b71c0dcf823e6551b143b/378000/378393/378393.mp4/?d=472&br=276&ti=1793928370"
        );
    }

    #[test]
    fn base164_decode_garbage() {
        assert!(base164_decode("").is_none() || base164_decode("").unwrap().is_empty());
        assert!(base164_decode("####").is_none() || base164_decode("####").unwrap().is_empty());
    }

    #[test]
    fn list_url_rules() {
        assert_eq!(
            list_url("", "", "latest-updates", 1),
            "https://abjav.com/api/json/videos2/86400/str/latest-updates/60/..1.all...json"
        );
        assert_eq!(
            list_url("categories", "asian", "latest-updates", 2),
            "https://abjav.com/api/json/videos2/86400/str/latest-updates/60/categories.asian.2.all...json"
        );
        assert_eq!(
            list_url("", "", "most-popular", 1),
            "https://abjav.com/api/json/videos2/86400/str/most-popular/60/..1.all...json"
        );
    }

    #[test]
    fn parse_video_list() {
        let data = json!({"videos": [
            {"video_id": "378393", "dir": "she-holds-two-men-on-her-breasts-until-something-comes-out",
             "title": "She Holds Two Men On Her Breasts Until Something Comes Out",
             "duration": "07:52", "scr": "https://ii.abjav.com/contents/videos_screenshots/378000/378393/480x270/1.jpg"}
        ]});
        let items = parse_videos(&data);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://abjav.com/video/378393/she-holds-two-men-on-her-breasts-until-something-comes-out/"
        );
        assert_eq!(items[0]["remark"], "07:52");
    }

    #[test]
    fn numeric_id_from_page_url() {
        assert_eq!(
            numeric_id("https://abjav.com/video/378393/she-holds-two-men/"),
            "378393"
        );
        assert_eq!(numeric_id("378393"), "378393");
    }

    #[test]
    fn detail_url_segments() {
        let id_num: i64 = 378393;
        assert_eq!((id_num / 1_000_000) * 1_000_000, 0);
        assert_eq!((id_num / 1_000) * 1_000, 378000);
    }
}
