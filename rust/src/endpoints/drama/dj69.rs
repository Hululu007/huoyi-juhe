//! 69短剧（dj69）：MacCMS 站，实测于 2026-11-05。
//!
//! 入口 `https://agx6p-z9.69djudaq.vip/69d/` 是随机跳转页链：
//! 入口页（MAIN_DOMAIN `69dj02.top`）→ 随机 7 位子域名
//! `.69dj02.top`（MAIN_DOMAIN `69dj05.vip`）→ 随机 6 位子域名
//! `.69dj05.vip` 即本站（标题“69短剧 - 免费AI短剧”）。子域名每次
//! 随机生成（DNS 泛解析），模块按链实时跟跳；域名本身可能轮换，
//! 每跳的下一域名都从当页 JS 里现取，不写死。
//! 与核心已有站 🔞AOXX69（`aoxx69.rs`，基址
//! `https://www.aoxx69.app`、路径 `/hk/jav` 等）不是同站：本站是
//! MacCMS 网页站，基址、分类体系、内容链路全都不同，只是同含“69”。
//! 另：本站与 UU短剧（`uudj.rs`）同模板、同内容池（同一视频的
//! 播放地址相同，如 144819 与 42577 同为
//! `vod.djqiepian.app/.../ep-000001-ef21d1ef00a9/index.m3u8`），
//! 但域名、品牌、分类体系各不相同，各立模块。
//! 分类与站导航 1:1（24 项）：AI短剧/家庭短剧/武侠短剧/宫廷短剧/
//! 都市短剧/仙侠短剧/异能短剧/校园短剧/国产黑料/传媒精选/抖阴视频/
//! 国产主播/网红头条/伦理三级/国产乱伦/明星换脸/中文字幕/日本无码/
//! 强奸乱伦/制服诱惑/萝莉少女/AV解说/欧美无码/人妖系列。
//! 目录 `/vodtype/<id>.html`（p1）、`/vodtype/<id>-<n>.html`（p>1，
//! 每页 24 条，p1/p2 无重叠）；卡片 `/voddetail/<id>.html` + 封面
//! img + 标题 alt；详情同页（h1 标题 + meta description +
//! `detail-cover` 海报 + 第1..N集播放链接）；取流为播放页
//! `/vodplay/<id>-1-<k>.html` 的 `player_aaaa` JSON 的 `url` 字段
//! （m3u8，`vod.djqiepian.app`，主清单 200、60 分片、AES-128、
//! 首分片 200，与 UU短剧同源同流）；
//! 搜索 `GET /vodsearch/<词>-------------.html`（“国产”实测 24 条）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const ENTRY: &str = "https://agx6p-z9.69djudaq.vip/69d/";
const FALLBACK_BASE: &str = "https://q7w2kx.69dj05.vip";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const SUB_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";

static HOST: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("6", "AI短剧"),
    ("7", "家庭短剧"),
    ("8", "武侠短剧"),
    ("9", "宫廷短剧"),
    ("10", "都市短剧"),
    ("11", "仙侠短剧"),
    ("12", "异能短剧"),
    ("20", "校园短剧"),
    ("13", "国产黑料"),
    ("14", "传媒精选"),
    ("15", "抖阴视频"),
    ("16", "国产主播"),
    ("21", "网红头条"),
    ("22", "伦理三级"),
    ("23", "国产乱伦"),
    ("24", "明星换脸"),
    ("25", "中文字幕"),
    ("26", "日本无码"),
    ("27", "强奸乱伦"),
    ("28", "制服诱惑"),
    ("29", "萝莉少女"),
    ("30", "AV解说"),
    ("31", "欧美无码"),
    ("32", "人妖系列"),
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
    if home.contains("69短剧") {
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
        return Err(ApiError::Internal(format!("69短剧请求 HTTP {status}")));
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

/// 路径段百分号编码（搜索词进 /vodsearch/<词>-------------.html）。
fn encode_path(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~') {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// 分类解析：首页导航 `/vodtype/<N>.html` 锚点文本，按站内顺序、
/// id 去重（跳过“更多”一类空名/非分类锚点）。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"(?s)<a[^>]*href="/vodtype/(\d+)\.html"[^>]*>(.*?)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let tag_re = Regex::new(r"<[^>]+>").ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = match &tag_re {
            Some(t) => t.replace_all(&cap[2], "").trim().to_string(),
            None => continue,
        };
        if name.is_empty() || name.contains("更多") || !seen.insert(id.clone()) {
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

/// 卡片解析：`<a href="/voddetail/<N>.html"><img src="<封面>">` +
/// `<span><text><标题></text></span>`（2026-11-07 站改版：img 去掉
/// 了 alt，标题改放在 span/text 里；旧版 alt 仍有 span/text，
/// 同一正则两版都认）。目录页与搜索页同款。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/voddetail/(\d+)\.html">.*?<img src="([^"]+)"[^>]*>.*?<span><text>([^<]+)</text></span>"#,
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
        format!("{base}/vodtype/{category_id}.html")
    } else {
        format!("{base}/vodtype/{category_id}-{page}.html")
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let base = resolve_base().await;
    let html = get_text(&catalog_url(&base, category_id, page)).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/vodtype/{category_id}-{}", page + 1))
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

/// 详情页选集：`/vodplay/<N>-1-<k>.html`（第k集）。
fn parse_episodes(html: &str, base: &str, series_id: &str) -> Vec<Value> {
    let re = match Regex::new(r#"<a[^>]*href="(/vodplay/\d+-1-(\d+)\.html)"[^>]*>([^<]*)</a>"#) {
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
    let html = get_text(&format!("{base}/voddetail/{vid}.html")).await?;
    let title = parse_h1(&html);
    let cover = parse_detail_cover(&html);
    let synopsis = parse_synopsis(&html);
    let mut episodes = parse_episodes(&html, &base, series_id);
    if episodes.is_empty() {
        episodes.push(episode_json(
            &format!("{base}/vodplay/{vid}-1-1.html"),
            "第1集",
            series_id,
        ));
    }
    if title.is_empty() {
        return Err(ApiError::Internal("69短剧未返回标题".into()));
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
        return Err(ApiError::Internal("69短剧该集没有播放地址".into()));
    }
    let html = get_text(url).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("69短剧未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = resolve_base().await;
    let url = format!(
        "{base}/vodsearch/{}-------------.html",
        encode_path(query.trim())
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
            next_domain(r#"const MAIN_DOMAIN = '69dj05.vip';"#),
            Some("69dj05.vip".to_string())
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
        let html = r#"<a href="/vodtype/6.html">AI短剧</a><a href="/vodtype/7.html">家庭短剧</a><a href="/vodtype/6.html">更多 &#8250; &nbsp;</a><a href="/vodtype/13.html">国产黑料</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "6");
        assert_eq!(list[0]["name"], "AI短剧");
        assert_eq!(list[2]["id"], "13");
        assert_eq!(list[2]["name"], "国产黑料");
    }

    #[test]
    fn fallback_has_24_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 24);
        assert_eq!(list[0]["id"], "6");
        assert_eq!(list[0]["name"], "AI短剧");
        assert_eq!(list[7]["id"], "20");
        assert_eq!(list[7]["name"], "校园短剧");
        assert_eq!(list[23]["id"], "32");
        assert_eq!(list[23]["name"], "人妖系列");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/voddetail/144882.html"><img src="https://98jpg1.vip/upload/vod/20261031-1/12d1994420326890ab0e1f8c825e00a4.jpg" alt="《原味拍卖》" loading="lazy"><span><text>《原味拍卖》</text></span></a></li> <li><a href="/voddetail/144882.html"><img src="https://x.y/2.jpg" alt="重复卡片"></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "144882");
        assert_eq!(items[0]["title"], "《原味拍卖》");
        assert_eq!(
            items[0]["cover"],
            "https://98jpg1.vip/upload/vod/20261031-1/12d1994420326890ab0e1f8c825e00a4.jpg"
        );
    }

    #[test]
    fn parse_cards_new_markup_no_alt() {
        // 2026-11-07 实测：img 去掉 alt，标题在 span/text 里。
        let html = r#"<li><a href="/voddetail/145008.html"><img src="https://aoksazysz.com/20261105/h7Zz2Sii/1.jpg"><span><text>大漠公主的成人礼成为女王要先被內射</text></span></a></li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "145008");
        assert_eq!(items[0]["title"], "大漠公主的成人礼成为女王要先被內射");
        assert_eq!(
            items[0]["cover"],
            "https://aoksazysz.com/20261105/h7Zz2Sii/1.jpg"
        );
    }

    #[test]
    fn catalog_url_forms() {
        assert_eq!(
            catalog_url("https://q7w2kx.69dj05.vip", "6", 1),
            "https://q7w2kx.69dj05.vip/vodtype/6.html"
        );
        assert_eq!(
            catalog_url("https://q7w2kx.69dj05.vip", "6", 2),
            "https://q7w2kx.69dj05.vip/vodtype/6-2.html"
        );
    }

    #[test]
    fn parse_detail_cover_and_episodes() {
        let html = r#"<img class="detail-cover" src="https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/cover-w600-v1-ccd3ab138a00.jpg" alt="带着AI老婆穿越2018"><a class="episode-link is-current" href="/vodplay/144819-1-1.html">第1集</a><a class="episode-link" href="/vodplay/144819-1-2.html">第2集</a><a class="episode-link" href="/vodplay/144819-1-3.html">第3集</a>"#;
        assert_eq!(
            parse_detail_cover(html),
            "https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/cover-w600-v1-ccd3ab138a00.jpg"
        );
        let eps = parse_episodes(html, "https://q7w2kx.69dj05.vip", "144819");
        assert_eq!(eps.len(), 3);
        assert_eq!(
            eps[0]["video_id"],
            "https://q7w2kx.69dj05.vip/vodplay/144819-1-1.html"
        );
        assert_eq!(eps[2]["title"], "第3集");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/144819-1-1.html","vod_data":{"vod_name":"带着AI老婆穿越2018"},"url":"https:\/\/vod.djqiepian.app\/vod\/t-b90f551641c745fbf546905d\/ep-000001-ef21d1ef00a9\/index.m3u8","url_next":"https:\/\/vod.djqiepian.app\/vod\/t-b90f551641c745fbf546905d\/ep-000002-ded037f2c947\/index.m3u8","from":"zym3u8"}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://vod.djqiepian.app/vod/t-b90f551641c745fbf546905d/ep-000001-ef21d1ef00a9/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }
    #[tokio::test]
    #[ignore]
    async fn live_avjieshuo_catalog() {
        let start = std::time::Instant::now();
        let r = catalog("30", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE dj69 av解说 cat=30 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "dj69 AV解说 catalog empty");
    }
}
