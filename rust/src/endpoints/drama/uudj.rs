//! UU短剧（uudj）：MacCMS 站，实测于 2026-11-05。
//!
//! 入口 `https://e3-pvx-t0.uudjmusic.vip/uudj/` 是随机跳转页链：
//! 入口页（MAIN_DOMAIN `uudj01.top`）→ 随机 7 位子域名
//! `.uudj01.top`（PRIMARY_DOMAIN `uudj02.vip`）→ 随机 6 位子域名
//! `.uudj02.vip` 即本站（标题“UU短剧 - 免费在线影视”）。子域名每次
//! 随机生成（DNS 泛解析），模块按链实时跟跳；域名本身可能轮换，
//! 每跳的下一域名都从当页 JS 里现取，不写死。
//! 与核心已有站 `uu.rs`（未注册的 API 型站，加密信封 + 指纹登录，
//! 宿主 aad.ubh19fa.com 等）不是同站：本站是 MacCMS 网页站，基址、
//! 分类体系、内容链路全都不同，只是同名“UU短剧”。
//! 分类与站导航 1:1（24 项）：AI短剧/职场权色/都市爱情/家庭伦理/
//! 武侠江湖/古装奇谈/异能超能/系统逆袭/精品国产/探花约炮/传媒剧情/
//! 国产自拍/主播诱惑/抖阴短片/明星换脸/偷拍偷窥/中文字幕/AV解说/
//! 强奸乱伦/日本无码/重口激情/欧美情色/SM调教/女同性恋。
//! 目录 `/index.php/vod/type/id/<id>.html`（p1）、
//! `/index.php/vod/type/id/<id>/page/<n>.html`（p>1，每页 24 条，
//! 6 号分类实测 12 页）；卡片 `/index.php/vod/detail/id/<N>.html` +
//! 封面 img + 标题 alt；详情同页（h1 标题 + meta description +
//! `detail-cover` 海报 + 第1..N集播放链接）；取流为播放页
//! `/index.php/vod/play/id/<N>/sid/1/nid/<k>.html` 的 `player_aaaa`
//! JSON 的 `url` 字段（m3u8，`vod.djqiepian.app`，主清单 200、
//! 60 分片、AES-128、首分片 200）；
//! 搜索 `GET /index.php/vod/search.html?wd=<词>`（“国产”实测 24 条）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const ENTRY: &str = "https://e3-pvx-t0.uudjmusic.vip/uudj/";
const FALLBACK_BASE: &str = "https://m4n8p1.uudj02.vip";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const SUB_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";

static HOST: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("6", "AI短剧"),
    ("7", "职场权色"),
    ("8", "都市爱情"),
    ("9", "家庭伦理"),
    ("10", "武侠江湖"),
    ("11", "古装奇谈"),
    ("12", "异能超能"),
    ("20", "系统逆袭"),
    ("13", "精品国产"),
    ("14", "探花约炮"),
    ("15", "传媒剧情"),
    ("16", "国产自拍"),
    ("21", "主播诱惑"),
    ("22", "抖阴短片"),
    ("23", "明星换脸"),
    ("24", "偷拍偷窥"),
    ("25", "中文字幕"),
    ("26", "AV解说"),
    ("27", "强奸乱伦"),
    ("28", "日本无码"),
    ("29", "重口激情"),
    ("30", "欧美情色"),
    ("31", "SM调教"),
    ("32", "女同性恋"),
];

/// 轻量伪随机：纳秒时间种子 + xorshift64，够生成随机子域名。
fn rand_sub(len: usize) -> String {
    let mut x = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15);
    if x == 0 {
        x = 0x9e3779b97f4a7c15;
    }
    let mut out = String::new();
    for _ in 0..len {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push(SUB_CHARS[(x % 36) as usize] as char);
    }
    out
}

/// 跳转页里下一跳的一级域名（MAIN_DOMAIN 或 PRIMARY_DOMAIN）。
fn next_domain(html: &str) -> Option<String> {
    for pat in [
        r#"MAIN_DOMAIN\s*=\s*['"]([^'"]+)['"]"#,
        r#"PRIMARY_DOMAIN\s*=\s*['"]([^'"]+)['"]"#,
    ] {
        if let Ok(re) = Regex::new(pat) {
            if let Some(cap) = re.captures(html) {
                let d = cap[1].trim().to_string();
                if !d.is_empty() {
                    return Some(d);
                }
            }
        }
    }
    None
}

/// 跟跳链拿基址：入口页 → 随机 7 位子域 → 随机 6 位子域即本站。
async fn resolve_base() -> String {
    if let Ok(guard) = HOST.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return cached.clone();
            }
        }
    }
    let base = follow_chain()
        .await
        .unwrap_or_else(|| FALLBACK_BASE.to_string());
    if let Ok(mut guard) = HOST.lock() {
        *guard = Some((base.clone(), Instant::now() + Duration::from_secs(3600)));
    }
    base
}

async fn follow_chain() -> Option<String> {
    let entry = get_text(ENTRY).await.ok()?;
    let d1 = next_domain(&entry)?;
    let hop1 = format!("https://{}.{d1}/", rand_sub(7));
    let hop1_html = get_text(&hop1).await.ok()?;
    let d2 = next_domain(&hop1_html)?;
    let base = format!("https://{}.{d2}", rand_sub(6));
    let home = get_text(&format!("{base}/")).await.ok()?;
    if home.contains("UU短剧") {
        Some(base)
    } else {
        None
    }
}

async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("UU短剧请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 分类解析：首页导航栏 `<a href="/index.php/vod/type/id/<N>.html">`
/// 内 `<text>名</text>`，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"(?s)<a[^>]*href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>\s*<text>([^<]+)</text>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let base = resolve_base().await;
    match get_text(&format!("{base}/")).await {
        Ok(html) => {
            let list = parse_categories(&html);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

/// 卡片解析：`<a href="/index.php/vod/detail/id/<N>.html"><img
/// src="<封面>" alt="<标题>"`。目录页与搜索页同款。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/index\.php/vod/detail/id/(\d+)\.html"><img src="([^"]+)" alt="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].trim().to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = unescape(cap[2].trim());
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

fn catalog_url(base: &str, category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{base}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{base}/index.php/vod/type/id/{category_id}/page/{page}.html")
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let base = resolve_base().await;
    let html = get_text(&catalog_url(&base, category_id, page)).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!(
            "/index.php/vod/type/id/{}/page/{}.html",
            category_id,
            page + 1
        ))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

fn parse_h1(html: &str) -> String {
    let re = match Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| {
            let t = Regex::new(r"<[^>]+>")
                .ok()
                .map(|x| x.replace_all(&cap[1], "").trim().to_string())
                .unwrap_or_default();
            unescape(&t)
        })
        .unwrap_or_default()
}

/// 详情封面：`detail-cover` 海报图。
fn parse_detail_cover(html: &str) -> String {
    let re = match Regex::new(r#"<img class="detail-cover"[^>]*src="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(cap[1].trim()))
        .unwrap_or_default()
}

fn parse_synopsis(html: &str) -> String {
    let re = match Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(cap[1].trim()))
        .unwrap_or_default()
}

/// 详情页选集：`/index.php/vod/play/id/<N>/sid/1/nid/<k>.html`（第k集）。
fn parse_episodes(html: &str, base: &str, series_id: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"<a[^>]*href="(/index\.php/vod/play/id/\d+/sid/1/nid/(\d+)\.html)"[^>]*>([^<]*)</a>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut episodes = Vec::new();
    for cap in re.captures_iter(html) {
        let nid = cap[2].to_string();
        if !seen.insert(nid.clone()) {
            continue;
        }
        let name = cap[3].trim();
        let title = if name.is_empty() {
            format!("第{nid}集")
        } else {
            name.to_string()
        };
        episodes.push(episode_json(
            &format!("{base}{}", &cap[1]),
            &title,
            series_id,
        ));
    }
    episodes
}

/// 取流：播放页 `player_aaaa` JSON 的 url 字段（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(&cap[1]))
        .unwrap_or_default()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.trim();
    let base = resolve_base().await;
    let html = get_text(&format!("{base}/index.php/vod/detail/id/{vid}.html")).await?;
    let title = parse_h1(&html);
    let cover = parse_detail_cover(&html);
    let synopsis = parse_synopsis(&html);
    let mut episodes = parse_episodes(&html, &base, series_id);
    if episodes.is_empty() {
        // 无选集链接时兜底第 1 集（播放页直取）。
        episodes.push(episode_json(
            &format!("{base}/index.php/vod/play/id/{vid}/sid/1/nid/1.html"),
            "第1集",
            series_id,
        ));
    }
    if title.is_empty() {
        return Err(ApiError::Internal("UU短剧未返回标题".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id.trim();
    if !url.starts_with("http") {
        return Err(ApiError::Internal("UU短剧该集没有播放地址".into()));
    }
    let html = get_text(url).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("UU短剧未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = resolve_base().await;
    let url = with_query(
        &format!("{base}/index.php/vod/search.html"),
        &[("wd", query.trim())],
    );
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_domain_both_names() {
        assert_eq!(
            next_domain(r#"const MAIN_DOMAIN = "uudj01.top";"#),
            Some("uudj01.top".to_string())
        );
        assert_eq!(
            next_domain(r#"const PRIMARY_DOMAIN = "uudj02.vip";"#),
            Some("uudj02.vip".to_string())
        );
        assert_eq!(next_domain("<html>no jump</html>"), None);
    }

    #[test]
    fn rand_sub_shape() {
        let s = rand_sub(7);
        assert_eq!(s.len(), 7);
        assert!(s
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
        assert_eq!(rand_sub(6).len(), 6);
    }

    #[test]
    fn parse_categories_real_nav() {
        let html = r#"<a href="/index.php/vod/type/id/6.html" target="_self" rel="nofollow"> <text>AI短剧 </text> </a><a href="/index.php/vod/type/id/7.html" target="_self" rel="nofollow"> <text>职场权色 </text> </a><a href="/index.php/vod/type/id/6.html">更多 &#8250; &nbsp;</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "6");
        assert_eq!(list[0]["name"], "AI短剧");
        assert_eq!(list[1]["name"], "职场权色");
    }

    #[test]
    fn fallback_has_24_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 24);
        assert_eq!(list[0]["id"], "6");
        assert_eq!(list[0]["name"], "AI短剧");
        assert_eq!(list[8]["id"], "13");
        assert_eq!(list[8]["name"], "精品国产");
        assert_eq!(list[23]["id"], "32");
        assert_eq!(list[23]["name"], "女同性恋");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/index.php/vod/detail/id/42577.html"><img src="https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/cover-w600-v1-ccd3ab138a00.jpg" alt="带着AI老婆穿越2018" loading="lazy"><span><text>带着AI老婆穿越2018</text></span></a></li> <li><a href="/index.php/vod/detail/id/42577.html"><img src="https://x.y/2.jpg" alt="重复卡片"></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "42577");
        assert_eq!(items[0]["title"], "带着AI老婆穿越2018");
        assert_eq!(
            items[0]["cover"],
            "https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/cover-w600-v1-ccd3ab138a00.jpg"
        );
    }

    #[test]
    fn catalog_url_forms() {
        assert_eq!(
            catalog_url("https://m4n8p1.uudj02.vip", "7", 1),
            "https://m4n8p1.uudj02.vip/index.php/vod/type/id/7.html"
        );
        assert_eq!(
            catalog_url("https://m4n8p1.uudj02.vip", "7", 2),
            "https://m4n8p1.uudj02.vip/index.php/vod/type/id/7/page/2.html"
        );
    }

    #[test]
    fn parse_detail_cover_and_episodes() {
        let html = r#"<img class="detail-cover" src="https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/cover-w600-v1-ccd3ab138a00.jpg" alt="带着AI老婆穿越2018"><a class="episode-link is-current" href="/index.php/vod/play/id/42577/sid/1/nid/1.html">第1集</a><a class="episode-link" href="/index.php/vod/play/id/42577/sid/1/nid/2.html">第2集</a><a class="episode-link" href="/index.php/vod/play/id/42577/sid/1/nid/1.html">第1集</a>"#;
        assert_eq!(
            parse_detail_cover(html),
            "https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/cover-w600-v1-ccd3ab138a00.jpg"
        );
        let eps = parse_episodes(html, "https://m4n8p1.uudj02.vip", "42577");
        assert_eq!(eps.len(), 2);
        assert_eq!(
            eps[0]["video_id"],
            "https://m4n8p1.uudj02.vip/index.php/vod/play/id/42577/sid/1/nid/1.html"
        );
        assert_eq!(eps[1]["title"], "第2集");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/42577\/sid\/1\/nid\/1.html","vod_data":{"vod_name":"带着AI老婆穿越2018"},"url":"https:\/\/vod.djqiepian.app\/vod\/t-b90f551641c745fbf546905d\/ep-000001-ef21d1ef00a9\/index.m3u8","url_next":"https:\/\/vod.djqiepian.app\/vod\/t-b90f551641c745fbf546905d\/ep-000002-ded037f2c947\/index.m3u8","from":"zym3u8"}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/ep-000001-ef21d1ef00a9/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }
}
