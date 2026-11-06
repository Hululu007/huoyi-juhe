//! 奶很大（naihenda）：MacCMS 站，实测于 2026-11-05。
//!
//! 入口 `https://yyngh.naihenditop.buzz/neinei/` 是跳转页，按日期拼
//! 子域名：前缀 55/66/77 三选一 + 日期码 + `.naihendacina.buzz/ddd/`。
//! 日期码算法（跳转页 JS 原样）：本地时间减 5 小时（用户在东八区，
//! 即 UTC+3 的日期），月取 getMonth()（0 起，11 月 = 10），月日每位
//! 数字映成表 `["0e","r1","2o","d3","4a","x5","6c","d7x","8g","b9"]`
//! 的对应项，两位数拼两项、一位数取一项；2026-11-05 得 `r10ex5`，
//! 实测通 `https://77r10ex5.naihendacina.buzz/ddd/`。
//! 分类与站导航 1:1（首页只链 3 个 vodtype 分类）：网曝门事件（25）、
//! 步兵无码（28）、起点传媒（134）；另有 19 个关键词组链向
//! `/vodsearch/<词>-------------.html`（属搜索入口，不作分类）。
//! 注意：播放页曾见 `/vodtype/10/`（无名空分类），不在导航里，不列入。
//! 目录 `/vodtype/<id>/`（p1）、`/vodtype/<id>-<n>/`（p>1，每页 20 条，
//! p1/p2 无重叠）；卡片 `/voddetail/<id>/` + 封面 img + 标题 `<p>`。
//! 详情 `/voddetail/<id>/`（h1 标题 + meta description；封面取首个
//! 带 data-src 的图）；取流在 `/vodplay/<id>-1-1/` 的 `player_data`
//! JSON 的 `url` 字段（m3u8，主清单 200、1000kb 变体清单 200、
//! METHOD=NONE、总长 603.6 秒、首分片 200）；
//! 搜索 `GET /vodsearch/<词>-------------.html`（“巨乳”实测 20 条）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

static HOST: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// 日期码数字映射表（跳转页 JS 原样，7 对应三字符 "d7x"）。
const DATE_TOKENS: &[&str] = &["0e", "r1", "2o", "d3", "4a", "x5", "6c", "d7x", "8g", "b9"];

/// 分类静态表：id → 站导航名，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("25", "网曝门事件"),
    ("28", "步兵无码"),
    ("134", "起点传媒"),
];

fn cat_name(id: &str) -> Option<&'static str> {
    CATS.iter().find(|(i, _)| *i == id).map(|(_, n)| *n)
}

/// 天数转年月日（Howard Hinnant 算法，无外部依赖）。
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 单个数转日期码段：两位数拼两项，一位数取一项。
fn date_part(n: u32) -> String {
    if n >= 10 {
        format!(
            "{}{}",
            DATE_TOKENS[(n / 10 % 10) as usize],
            DATE_TOKENS[(n % 10) as usize]
        )
    } else {
        DATE_TOKENS[n as usize].to_string()
    }
}

/// 跳转页 JS 的日期码：本地时间减 5 小时（UTC+3 的日期），月 0 起。
fn date_code() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
        + 3 * 3600;
    let (_, m, d) = civil_from_days(secs.div_euclid(86_400));
    date_code_for(m, d)
}

fn date_code_for(month0: u32, day: u32) -> String {
    format!("{}{}", date_part(month0), date_part(day))
}

/// 当日 3 个候选基址（前缀 55/66/77 各一）。
fn host_candidates() -> Vec<String> {
    let code = date_code();
    ["55", "66", "77"]
        .iter()
        .map(|p| format!("https://{p}{code}.naihendacina.buzz"))
        .collect()
}

async fn resolve_base() -> String {
    if let Ok(guard) = HOST.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return cached.clone();
            }
        }
    }
    for base in host_candidates() {
        let url = format!("{base}/ddd/");
        let ok = match client() {
            Ok(c) => c
                .get(&url)
                .header("User-Agent", UA)
                .send()
                .await
                .map(|r| r.status().as_u16() == 200)
                .unwrap_or(false),
            Err(_) => false,
        };
        if ok {
            if let Ok(mut guard) = HOST.lock() {
                *guard = Some((base.clone(), Instant::now() + Duration::from_secs(3600)));
            }
            return base;
        }
    }
    host_candidates().into_iter().next().unwrap_or_default()
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
        return Err(ApiError::Internal(format!("奶很大请求 HTTP {status}")));
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

/// 分类解析：首页 `/vodtype/<N>.html` 链接的 id，按静态表取站导航名。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/vodtype/(\d+)\.html""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        if let Some(name) = cat_name(&id) {
            categories.push(category_json(&id, name));
        }
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
    match get_text(&format!("{base}/ddd/")).await {
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

/// 卡片解析：`<a href="/voddetail/<id>/" class="group-item">` +
/// img src（封面）+ `<p>` 标题。目录页与搜索页同款。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/voddetail/(\d+)/"[^>]*class="group-item[^"]*"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<p>(.*?)</p>"#,
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
        format!("{base}/vodtype/{category_id}/")
    } else {
        format!("{base}/vodtype/{category_id}-{page}/")
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

/// 详情封面：首个带 data-src 的图（本片海报）；站标与横幅图无此属性。
fn parse_detail_cover(html: &str) -> String {
    let re = match Regex::new(r#"<img[^>]*data-src="(https?://[^"]+)""#) {
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

/// 取流：播放页 `player_data` JSON 的 url 字段（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_data=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|cap| unescape(&cap[1]))
        .unwrap_or_default()
}

/// 播放页标题兜底：去掉“-在线观看播放-…”后缀。
fn parse_play_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<title>(.*?)</title>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let raw = re
        .captures(html)
        .map(|cap| unescape(cap[1].trim()))
        .unwrap_or_default();
    raw.split("-在线观看播放")
        .next()
        .unwrap_or("")
        .trim()
        .to_string()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.trim();
    let base = resolve_base().await;
    let html = get_text(&format!("{base}/voddetail/{vid}/")).await?;
    let cover = parse_detail_cover(&html);
    let synopsis = parse_synopsis(&html);
    let play_html = get_text(&format!("{base}/vodplay/{vid}-1-1/")).await?;
    let m3u8 = parse_player_url(&play_html);
    let mut title = parse_h1(&html);
    if title.is_empty() {
        title = parse_play_title(&play_html);
    }
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("奶很大未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("奶很大该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
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
    fn date_code_for_known_date() {
        // 2026-11-05：月 10（0 起）→ "r1"+"0e"；日 5 → "x5"。
        assert_eq!(date_code_for(10, 5), "r10ex5");
        // 1 月 9 日：月 0 → "0e"；日 9 → "b9"。
        assert_eq!(date_code_for(0, 9), "0eb9");
        // 7 月 15 日：月 6 → "6c"；日 15 → "r1"+"x5"。
        assert_eq!(date_code_for(6, 15), "6cr1x5");
        // 含 7 的位：日 7 → "d7x"。
        assert_eq!(date_code_for(10, 7), "r10ed7x");
    }

    #[test]
    fn civil_from_days_known() {
        // 2026-11-05 自 epoch 起 20762 天（date -u -d 校验）。
        assert_eq!(civil_from_days(20762), (2026, 11, 5));
    }

    #[test]
    fn parse_categories_homepage_links() {
        let html = r#"<a href="/vodtype/25.html">更多相关视频</a><a href="/vodtype/28.html">更多相关视频</a><a href="/vodtype/134.html">更多相关视频</a><a href="/vodtype/10.html">更多相关视频</a>"#;
        let list = parse_categories(html);
        // 10 号无名空分类不在静态表里，不列入。
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "25");
        assert_eq!(list[0]["name"], "网曝门事件");
        assert_eq!(list[2]["id"], "134");
        assert_eq!(list[2]["name"], "起点传媒");
    }

    #[test]
    fn fallback_has_3_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 3);
        assert_eq!(list[1]["name"], "步兵无码");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/voddetail/837014/" target="_blank" class="group-item" style="width:100%" > <img src="https://thjpg10.top/upload/vod/20241107-1/0e978e4f7018b7f76fde88acafd02e1c.jpg" data-src="https://thjpg10.top/upload/vod/20241107-1/0e978e4f7018b7f76fde88acafd02e1c.jpg" alt="" > <span class="layui-badge score layui-bg-blue">❤️ 2026-07-23</span> <p>网曝门事件杭州某大学外语学生分手后性爱私拍被渣男友惨遭曝光视频</p> </a><a href="/voddetail/837014/" target="_blank" class="group-item"><img src="https://x.y/2.jpg"><p>重复卡片</p></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "837014");
        assert_eq!(
            items[0]["title"],
            "网曝门事件杭州某大学外语学生分手后性爱私拍被渣男友惨遭曝光视频"
        );
        assert_eq!(
            items[0]["cover"],
            "https://thjpg10.top/upload/vod/20241107-1/0e978e4f7018b7f76fde88acafd02e1c.jpg"
        );
    }

    #[test]
    fn catalog_url_forms() {
        assert_eq!(
            catalog_url("https://77r10ex5.naihendacina.buzz", "25", 1),
            "https://77r10ex5.naihendacina.buzz/vodtype/25/"
        );
        assert_eq!(
            catalog_url("https://77r10ex5.naihendacina.buzz", "25", 2),
            "https://77r10ex5.naihendacina.buzz/vodtype/25-2/"
        );
    }

    #[test]
    fn parse_detail_cover_prefers_data_src() {
        let html = r#"<img src="/upload/site/20241206-1/370daeca6f252f298985da2674e52f9c.png" ><img src="https://ki.dadi260522.top/20260522/0DoHuSD5/1.jpg" data-src="https://ki.dadi260522.top/20260522/0DoHuSD5/1.jpg" alt="" ><img style="width: 100%" src="/upload/vod/20250602-1/4e9235ec37eb4c61c179e223869d0098.gif">"#;
        assert_eq!(
            parse_detail_cover(html),
            "https://ki.dadi260522.top/20260522/0DoHuSD5/1.jpg"
        );
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/815622-1-1\/","link_next":"","link_pre":"","url":"https:\/\/2605.dadi2026.com\/20260522\/0DoHuSD5\/index.m3u8","url_next":"","from":"ckplayer","server":"no","note":""}"#;
        assert_eq!(
            parse_player_url(html),
            "https://2605.dadi2026.com/20260522/0DoHuSD5/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_play_title_strips_suffix() {
        let html = r#"<title>巨乳金多贤饥渴难耐 大奶被内射爆浆-在线观看播放-奶很大-色情国产视频-免费线上看</title>"#;
        assert_eq!(parse_play_title(html), "巨乳金多贤饥渴难耐 大奶被内射爆浆");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://2605.dadi2026.com/20260522/0DoHuSD5/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://2605.dadi2026.com/20260522/0DoHuSD5/index.m3u8"
        );
        assert!(play_check("815622").is_err());
    }
}
