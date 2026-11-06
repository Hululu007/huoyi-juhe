//! 🔞JJavFun（javfun.me，实际落点 en.javfun.me）：JAV tube 站。
//!
//! 列表（/movies/{slug} 卡片：data-original 取封面、
//! mli-quality 取清晰度）、详情（og 标题封面、各 Server 的
//! loadEpisode(server, episodeId) 取分集）、搜索
//! /search/{keyword}。取流（站方 fix-backup.js 混淆代码已解：
//! GET {HOST}/ajax/get_sources/{episodeId}/{md5}?count=1
//! &mobile=false，md5 = md5(episodeId + b + SALT)，b 为 6 位
//! 随机串，同时以 Cookie 送出，Cookie 名 =
//! TOKEN_STR[13:37] + episodeId + TOKEN_STR[40:64]；
//! 返回 playlist[0].sources[0].file 即 m3u8）。
//! 验门（2026-11-06 本机出口实测）：详情
//! asiansexdiary-kay-part-2，分集 JS3JLZ6SK53E9BNU；
//! get_sources 返回 cdnasa1.cdnamz.me m3u8，219 分片、
//! 2624.5 秒（43.7 分钟）；首分片跟跳转后 200，TS 流前
//! 贴 111 字节 PNG 头（剥掉后 ffprobe 认出 mpegts、
//! 12.056 秒，与 EXTINF 12.012 对上；站方 hls.js 播得
//! 通，手机端 ExoPlayer 须复验）；列表 p1/p2 各 28 条
//! 0 重合；搜索 asiansexdiary 40 条。
//! 注意：分片是 PNG 头 + TS 的拼接体，播放器须能跳过
//! 段首垃圾字节；工作室分类的 /page-{N} 翻页未在本机
//! 验过（只验过 MOVIE 列表的翻页）。

use md5::{Digest, Md5};
use rand::Rng;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://en.javfun.me";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// fix-backup.js 里的 thfq6jcc6pj85tez（KqSa.P0(60) 解出），
/// Cookie 名与 md5 盐都从它派生。
const TOKEN_STR: &str = "n1sqcua67bcq9826avrbi6m49vd7shxkn985mhodk06twz87wwxtp3dqiicks2dfyud213k6ygiomq01s94e4tr9v0k887bkyud213k6ygiomq01s94e4tr9v0k887bkqocxzw39esdyfhvtkpzq9n4e7at4kc6k8sxom08bl4dukp16h09oplu7zov4m5f8";
const MD5_SALT: &str = "9826avrbi6m49vd7shxkn9815";

/// 静态分类：MOVIE 全部 + 8 个工作室 + 未分级。
const CATS: &[(&str, &str)] = &[
    ("movie", "全部"),
    ("studio:1pondo", "1PONDO"),
    ("studio:caribbeancom", "CARIBBEANCOM"),
    ("studio:10musume", "10MUSUME"),
    ("studio:pacopacomama", "PACOPACOMAMA"),
    ("studio:heyzo", "HEYZO"),
    ("studio:tokyo-hot", "Tokyo Hot"),
    ("studio:japanhdv", "JapanHDV"),
    ("studio:asiansexdiary", "AsianSexDiary"),
    ("category:uncensored", "Jav Uncensored"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JJavFun 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
        .trim()
        .to_string()
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// 列表卡片：<a href="/movies/{slug}" class="ml-mask jt"
/// title="..."> + <img data-original='...'> + 画质徽标。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let re = Regex::new(
        r#"(?s)<a href="/movies/([A-Za-z0-9._-]+)"[^>]*class="ml-mask jt"[^>]*title="([^"]+)"[^>]*>.*?<img data-original='([^']+)'"#,
    )
    .unwrap();
    let qual_re = Regex::new(r#"<span class="mli-quality">([^<]+)</span>"#).unwrap();
    for cap in re.captures_iter(html) {
        let slug = cap[1].to_string();
        let id = format!("{HOST}/movies/{slug}");
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let title = decode_entities(&cap[2]);
        if title.is_empty() {
            continue;
        }
        let cover = cap[3].to_string();
        let start = cap.get(0).unwrap().start();
        let tail = &html[start..(start + 3000).min(html.len())];
        let remark = qual_re
            .captures(tail)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

/// 详情页各 Server 的 loadEpisode(server, "episodeId")，
/// 去重后按出现顺序返回分集 id。
fn extract_episode_ids(html: &str) -> Vec<String> {
    let re = Regex::new(r#"loadEpisode\(\d+,"([A-Za-z0-9]+)"\)"#).unwrap();
    let mut out: Vec<String> = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        if !out.contains(&id) {
            out.push(id);
        }
    }
    out
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let page_part = if page <= 1 {
        String::new()
    } else {
        format!("/page-{page}")
    };
    if category_id == "movie" {
        return format!("{HOST}/japanese-porn-videos{page_part}");
    }
    if let Some(slug) = category_id.strip_prefix("studio:") {
        return format!("{HOST}/studio/{slug}{page_part}");
    }
    if let Some(slug) = category_id.strip_prefix("category:") {
        return format!("{HOST}/category/{slug}{page_part}");
    }
    format!("{HOST}/japanese-porn-videos{page_part}")
}

fn meta_content(html: &str, attr: &str, key: &str) -> String {
    let marker = format!("{attr}=\"{key}\"");
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
        .map(|e| decode_entities(&after[s..s + e]))
        .unwrap_or_default()
}

fn tag_title(html: &str) -> String {
    let Some(p) = html.find("<title>") else {
        return String::new();
    };
    let s = p + 7;
    let e = html[s..]
        .find("</title>")
        .map(|i| s + i)
        .unwrap_or(html.len());
    decode_entities(&html[s..e])
}

fn md5_hex(data: &str) -> String {
    let mut h = Md5::new();
    h.update(data.as_bytes());
    format!("{:x}", h.finalize())
}

/// 站方 JS 的随机串：Math.random().toString(36).substring(2,8)，
/// 即 6 位 [0-9a-z]。
fn random_b() -> String {
    const CHARS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut rng = rand::thread_rng();
    (0..6)
        .map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char)
        .collect()
}

/// Cookie 名 = TOKEN_STR[13:37] + episodeId + TOKEN_STR[40:64]。
fn cookie_name(episode_id: &str) -> String {
    let chars: Vec<char> = TOKEN_STR.chars().collect();
    let head: String = chars[13..37].iter().collect();
    let tail: String = chars[40..64].iter().collect();
    format!("{head}{episode_id}{tail}")
}

fn sources_url(episode_id: &str, b: &str) -> String {
    let md5 = md5_hex(&format!("{episode_id}{b}{MD5_SALT}"));
    format!("{HOST}/ajax/get_sources/{episode_id}/{md5}?count=1&mobile=false")
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("JJavFun 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let desc = meta_content(&html, "name", "description");
    let ids = extract_episode_ids(&html);
    if ids.is_empty() {
        return Err(ApiError::Internal("JJavFun 详情页未找到分集".into()));
    }
    let mut episodes: Vec<Value> = Vec::new();
    for (i, ep) in ids.iter().enumerate() {
        let name = if ids.len() == 1 {
            "正片".to_string()
        } else {
            format!("线路{}", i + 1)
        };
        // video_id 里用 $ 拼详情页地址，供 play() 作 Referer。
        episodes.push(episode_json(&format!("{ep}${series_id}"), &name, series_id));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": truncate(&desc, 400),
        "extra": {},
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
    let mut parts = video_id.split('$');
    let episode_id = parts.next().unwrap_or(video_id);
    let referer = parts.next().unwrap_or(HOST).to_string();
    let b = random_b();
    let url = sources_url(episode_id, &b);
    let cookie = format!("{}={}", cookie_name(episode_id), b);
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, */*")
        .header("Referer", &referer)
        .header("Cookie", cookie)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "JJavFun 取流接口 HTTP {status}"
        )));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let v: Value = serde_json::from_str(&text).map_err(|e| ApiError::Internal(e.to_string()))?;
    let file = v
        .get("playlist")
        .and_then(|p| p.as_array())
        .and_then(|a| a.first())
        .and_then(|pl| pl.get("sources"))
        .and_then(|s| s.as_array())
        .and_then(|a| a.first())
        .and_then(|s| s.get("file"))
        .and_then(|f| f.as_str())
        .unwrap_or("")
        .to_string();
    if file.is_empty() {
        return Err(ApiError::Internal("JJavFun 取流接口未返回播放地址".into()));
    }
    Ok(json!({
        "url": file,
        "header": {"User-Agent": UA, "Referer": referer},
    }))
}

/// 站方 searchMovie()：去尖括号与 `~!@#$%^&*()_|=?;:'",.<>{}[]\/`
/// 等特殊字符后跳 /search/{keyword}。
fn search_url(query: &str) -> String {
    let specials = "`~!@#$%^&*()_|=?;:'\",.<>{}[]\\/";
    let cleaned: String = query
        .chars()
        .filter(|c| !specials.contains(*c) && *c != '<' && *c != '>')
        .collect();
    let cleaned = cleaned.trim();
    let enc: String = url::form_urlencoded::byte_serialize(cleaned.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    format!("{HOST}/search/{enc}")
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = search_url(query);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_name_and_md5_fixed_b() {
        // b 固定为 vfs0k9 时（2026-11-06 实测跑通的那次），
        // Cookie 名与 md5 须与 curl 实测一致。
        assert_eq!(
            cookie_name("JS3JLZ6SK53E9BNU"),
            "826avrbi6m49vd7shxkn985mJS3JLZ6SK53E9BNUk06twz87wwxtp3dqiicks2df"
        );
        assert_eq!(
            md5_hex("JS3JLZ6SK53E9BNUvfs0k99826avrbi6m49vd7shxkn9815"),
            "223a1a3e6fffed04fc873337d5e2b590"
        );
    }

    #[test]
    fn sources_url_shape() {
        let url = sources_url("JS3JLZ6SK53E9BNU", "vfs0k9");
        assert_eq!(
            url,
            "https://en.javfun.me/ajax/get_sources/JS3JLZ6SK53E9BNU/223a1a3e6fffed04fc873337d5e2b590?count=1&mobile=false"
        );
    }

    #[test]
    fn random_b_shape() {
        let b = random_b();
        assert_eq!(b.len(), 6);
        assert!(b
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
    }

    #[test]
    fn cards_parse_movie_link() {
        let html = r#"<div class="col-md-2">
        <a href="/movies/pacopacomama-051525-100-amoral-wife-who-wants-to-be-trained-by-a-group" data-url="" class="ml-mask jt" title="Pacopacomama 051525_100 Amoral wife who wants to be trained by a group">
            <span class="mli-quality">HD</span>
            <img data-original='/Cms_Data/Contents/admin/Media/images/pacopacomama---051525-100-amoral-wife-who-wants-to-be-trained-by-a-group.jpg' alt="Pacopacomama 051525_100 Amoral wife who wants to be trained by a group">
        </a></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://en.javfun.me/movies/pacopacomama-051525-100-amoral-wife-who-wants-to-be-trained-by-a-group"
        );
        assert_eq!(
            items[0]["title"],
            "Pacopacomama 051525_100 Amoral wife who wants to be trained by a group"
        );
        assert_eq!(items[0]["remark"], "HD");
    }

    #[test]
    fn episode_ids_dedup() {
        let html = r#"onclick='loadEpisode(8,"JS3JLZ6SK53E9BNU")' onclick='loadEpisode(7,"JS3JLZ6SK53E9BNU")' onclick='loadEpisode(10,"JS3JLZ6SK53E9BNU")'"#;
        assert_eq!(extract_episode_ids(html), vec!["JS3JLZ6SK53E9BNU"]);
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("movie", 1),
            "https://en.javfun.me/japanese-porn-videos"
        );
        assert_eq!(
            catalog_url("movie", 2),
            "https://en.javfun.me/japanese-porn-videos/page-2"
        );
        assert_eq!(
            catalog_url("studio:1pondo", 1),
            "https://en.javfun.me/studio/1pondo"
        );
    }

    #[test]
    fn search_url_sanitizes() {
        assert_eq!(
            search_url("asiansexdiary"),
            "https://en.javfun.me/search/asiansexdiary"
        );
        assert_eq!(search_url("a<b>c!d"), "https://en.javfun.me/search/abcd");
    }
}
