//! 18开苞妹妹：MacCMS 站，实测于 2026-11-05。
//!
//! 入口跳转页 `https://yyhad.love18year.buzz/go/`（JS 倒计时）
//! 按日期拼子域名跳往 `https://<aa|bb|cc><日期码>.18ywmmresi.buzz/vod/`，
//! 日期码算法与跳转页 JS 一致：本地时间减 5 小时后取月日，
//! 每位数字映成 `0k..9k`（如 2026-11-05 → `1k1k0k5k`），前缀
//! `aa`/`bb`/`cc` 三选一；模块按同一算法算出当日 3 个候选域名
//! 依次试，首个 200 的即为当日基址（缓存 1 小时）。
//! 分类与站导航 1:1（4 项）：桃花资源/华语AV/欧美/糖心Vlog。
//! 目录 `/vodtype/<id>/`（p1），翻页 `/vodtype/<id>-<n>/`
//! （每页 20 条，48 号分类实测 5 页）；卡片 `/voddetail/<id>/`，
//! 封面 img src，标题在 `<p>` 内，日期徽标 `❤️ YYYY-MM-DD`。
//! 详情 `/voddetail/<id>/`（h1 标题 + 简介），取流在
//! `/vodplay/<id>-1-1/` 的 `player_data` JSON 的 `url` 字段
//! （m3u8，如 `https://2608.xbv2608.com/20261031/lwVYHmRY/index.m3u8`，
//! 主清单，变体 `/20261031/lwVYHmRY/hls/index.m3u8` 720x1280）；
//! 搜索 `GET /vodsearch/<词>-------------.html`（“开苞”实测 20 条）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("48", "桃花资源"),
    ("50", "华语AV"),
    ("52", "欧美"),
    ("441", "糖心Vlog"),
];

/// 2026-11-05 实测可用的基址（当日候选之一），解析失败时兜底。
const FALLBACK_BASE: &str = "https://cc1k1k0k5k.18ywmmresi.buzz";

static HOST: Mutex<Option<(String, Instant)>> = Mutex::new(None);

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

/// 跳转页 JS 的日期码：本地时间减 5 小时（用户在东八区，即 UTC+3 的
/// 日期）后，月日每位数字映成 `0k..9k`。
fn date_code() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
        + 3 * 3600;
    let (_, m, d) = civil_from_days(secs.div_euclid(86_400));
    date_code_for(m, d)
}

fn date_code_for(month: u32, day: u32) -> String {
    let two = |n: u32| -> String { format!("{}k{}k", n / 10, n % 10) };
    format!("{}{}", two(month), two(day))
}

/// 当日 3 个候选基址（前缀 aa/bb/cc 各一）。
fn host_candidates() -> Vec<String> {
    let code = date_code();
    ["aa", "bb", "cc"]
        .iter()
        .map(|p| format!("https://{p}{code}.18ywmmresi.buzz"))
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
        let url = format!("{base}/vod/");
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
    FALLBACK_BASE.to_string()
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("18开苞妹妹请求 HTTP {status}")));
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

/// 分类解析：首页导航 `/vodtype/<id>/` 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/vodtype/(\d+)/"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || name == "更多" || !seen.insert(id.clone()) {
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
    match get_text(&format!("{base}/vod/")).await {
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

/// 卡片解析：`<a href="/voddetail/<id>/">` + img src（封面）+ `<p>` 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)/voddetail/(\d+)/"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<p>([^<]+)</p>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let vid = cap[1].trim().to_string();
        if vid.is_empty() || !seen.insert(vid.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let cover = cap[2].trim().to_string();
        items.push(item_json(&vid, &title, &cover, ""));
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
    let has_more = html.contains(&format!("/vodtype/{category_id}-{}", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 取流地址：播放页 `player_data` JSON 的 `url` 字段（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_data=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    }
}

/// 详情页封面：og:image（排除 favicon），否则首个含 upload/vod 的图。
fn parse_cover(html: &str) -> String {
    let og_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
    if let Some(re) = og_re {
        if let Some(cap) = re.captures(html) {
            let cover = cap[1].trim().to_string();
            if !cover.is_empty() && !cover.ends_with("favicon.ico") {
                return cover;
            }
        }
    }
    let img_re =
        Regex::new(r#"(?s)<img[^>]*(?:data-original|src)="(https?://[^"]*upload/vod[^"]+)""#).ok();
    if let Some(re) = img_re {
        if let Some(cap) = re.captures(html) {
            return cap[1].trim().to_string();
        }
    }
    String::new()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.trim();
    let base = resolve_base().await;
    let html = get_text(&format!("{base}/voddetail/{vid}/")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let cover = parse_cover(&html);
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let play_html = get_text(&format!("{base}/vodplay/{vid}-1-1/")).await?;
    let m3u8 = parse_player_url(&play_html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("18开苞妹妹未返回可播放地址".into()));
    }
    Ok(json!({
    "id": series_id,
    "title": title,
    "cover": cover,
    "synopsis": synopsis,
    "extra": {},
    "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("18开苞妹妹该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return play_check(vid);
    }
    if vid.is_empty() || !vid.chars().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::Internal("18开苞妹妹该集没有播放地址".into()));
    }
    let base = resolve_base().await;
    let html = get_text(&format!("{base}/vodplay/{vid}-1-1/")).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("18开苞妹妹未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let base = resolve_base().await;
    let encoded = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{base}/vodsearch/{encoded}-------------.html");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_code_for_known_date() {
        assert_eq!(date_code_for(11, 5), "1k1k0k5k");
        assert_eq!(date_code_for(1, 9), "0k1k0k9k");
        assert_eq!(date_code_for(12, 25), "1k2k2k5k");
    }

    #[test]
    fn civil_from_days_known() {
        // 2026-11-05 UTC：自 epoch 起 20762 天。
        assert_eq!(civil_from_days(20762), (2026, 11, 5));
        assert_eq!(civil_from_days(0), (1970, 1, 1));
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/vodtype/48/">桃花资源</a><a href="/vodtype/50/">华语AV</a><a href="/vodtype/48/">桃花资源</a><a href="/vodtype/52/">欧美</a><a href="/vodtype/441/">糖心Vlog</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "48");
        assert_eq!(list[3]["name"], "糖心Vlog");
    }

    #[test]
    fn fallback_has_4_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 4);
        assert_eq!(list[1]["name"], "华语AV");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="layui-col-md3 m-md6" > <h4> <a href="/voddetail/1549465/" target="_blank" class="group-item" style="width:100%" > <img src="https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png" data-src="https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png" alt="" > <span class="layui-badge score layui-bg-blue">❤️ 2026-11-05</span> <p>户外车震自拍最强美腿蜜臀尤物</p> </a> </h4> </div> <div class="layui-col-md3 m-md6" > <h4> <a href="/voddetail/1992826/" target="_blank" class="group-item" style="width:100%" > <img src="https://pp2.xbp261028.top/upload/vod/20261102-1/5ef8380241a0e75fc5ae433711e73f0a.jpg" data-src="https://pp2.xbp261028.top/upload/vod/20261102-1/5ef8380241a0e75fc5ae433711e73f0a.jpg" alt="" > <span class="layui-badge score layui-bg-blue">❤️ 2026-11-02</span> <p>暴力开苞痛的哇哇直叫简直丧尽天良！奶声奶气</p> </a> </h4> </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "1549465");
        assert_eq!(items[0]["title"], "户外车震自拍最强美腿蜜臀尤物");
        assert_eq!(
            items[0]["cover"],
            "https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png"
        );
        assert_eq!(items[1]["id"], "1992826");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/1989455-1-1\/","link_next":"","link_pre":"","url":"https:\/\/2608.xbv2608.com\/20261031\/lwVYHmRY\/index.m3u8","url_next":"","from":"s8m3u8","server":"","note":""}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://2608.xbv2608.com/20261031/lwVYHmRY/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_cover_skips_logo_and_banners() {
        let html = r#"<img src="/upload/site/20250703-1/645303b1a4612c9b46360a67567f1f39.jpg" > <img style="width: 100%;max-width: 100%;height: 80px;"src="/upload/vod/20261028-1/383a2cff31c39034d609f95c97d19566.gif"> <img src="https://pp2.xbp261028.top/upload/vod/20261102-1/5ef8380241a0e75fc5ae433711e73f0a.jpg" data-src="https://pp2.xbp261028.top/upload/vod/20261102-1/5ef8380241a0e75fc5ae433711e73f0a.jpg" alt="" >"#;
        assert_eq!(
            parse_cover(html),
            "https://pp2.xbp261028.top/upload/vod/20261102-1/5ef8380241a0e75fc5ae433711e73f0a.jpg"
        );
        assert_eq!(parse_cover("<div>no img</div>"), "");
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            catalog_url("https://cc1k1k0k5k.18ywmmresi.buzz", "48", 1),
            "https://cc1k1k0k5k.18ywmmresi.buzz/vodtype/48/"
        );
        assert_eq!(
            catalog_url("https://cc1k1k0k5k.18ywmmresi.buzz", "48", 2),
            "https://cc1k1k0k5k.18ywmmresi.buzz/vodtype/48-2/"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://2608.xbv2608.com/20261031/lwVYHmRY/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://2608.xbv2608.com/20261031/lwVYHmRY/index.m3u8"
        );
        assert!(play_check("1989455").is_err());
    }
}
