//! 海角社区高清4K：MacCMS 站，实测于 2026-11-05。
//!
//! 入口跳转页 `https://ddddd.energize.click/kkkk/`（JS 倒计时）
//! 按日期拼子域名跳往 `https://<3字母+3数字>.10mf4k03.buzz/box/`，
//! 子域名算法与跳转页 JS 一致：种子为当日年月日 `YYYYMMDD`，
//! 线性同余 `seed = (seed * 9301 + 49297) % 233280`，依次取
//! 3 个字母（`seed / 233280 * 26`）+ 3 个数字（`seed / 233280 * 10`），
//! 当日两个候选（种子与种子 + 1，如 2026-11-05 → `lqs005`/`mlm206`），
//! 模块按同一算法算出当日候选依次试，首个 200 的即为当日基址
//! （缓存 1 小时）。
//!
//! 注意：与核心已有站 🔞海角社区（haijiao.rs）不是同站——已有站
//! 走 API 后端 `https://api1.ogokfmrx.com`（PWA 应用，20 个固定
//! 分类 `video:/post:/comm:/short`）；本站是 MacCMS 网页站，
//! 首页导航 72 个 `/vodtype/<id>/` 分类、卡片 `/voddetail/<id>/`、
//! 取流 `/vodplay/<id>-1-1/`，基址、分类体系、内容链路全都不同，
//! 只是共用“海角社区”品牌名。
//!
//! 分类与站导航 1:1（72 项，见首页菜单与栏目“更多”）：极品资源/
//! 杏吧原创/女同性恋/可爱学生/国产传媒/颜值正义/欧美精品/日本素人/
//! AI换脸/中文字幕/百合女同/无码专区/日本无码/VR视角/亚洲情色…
//! 目录 `/vodtype/<id>/`（p1），翻页 `/vodtype/<id>-<n>/`
//! （每页 20 条，435 号分类实测 32 页；600 号“极品资源”站内
//! 为空，返回空列表）；卡片 `/voddetail/<id>/`，封面
//! `img data-original`，标题在 `<h3>` 内。
//! 详情 `/voddetail/<id>/`（简介取 meta description），取流在
//! `/vodplay/<id>-1-1/` 的 `player_data` JSON 的 `url` 字段
//! （m3u8，如 `https://t27.cdn2020.com/video/m3u8/2026/11/03/1c5ce67b/index.m3u8`，
//! 271 分片、2629 秒）；搜索 `GET /vodsearch/<词>-------------.html`
//! （“国产”实测 20 条）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("600", "极品资源"),
    ("435", "杏吧原创"),
    ("102", "女同性恋"),
    ("93", "可爱学生"),
    ("633", "国产传媒"),
    ("630", "颜值正义"),
    ("444", "欧美精品"),
    ("60", "日本素人"),
    ("174", "AI换脸"),
    ("140", "中文字幕"),
    ("637", "百合女同"),
    ("351", "无码专区"),
    ("156", "日本无码"),
    ("320", "VR视角"),
    ("348", "亚洲情色"),
    ("91", "古装扮演"),
    ("603", "国产精品"),
    ("288", "欧美激情"),
    ("66", "中文字幕"),
    ("305", "国产主播"),
    ("427", "蜜桃传媒"),
    ("138", "自拍偷拍"),
    ("608", "自拍偷拍"),
    ("631", "熟女少妇"),
    ("141", "人妻系列"),
    ("377", "伦理三级"),
    ("146", "巨乳系列"),
    ("376", "国产盗摄"),
    ("626", "黑料网曝"),
    ("375", "国产自拍"),
    ("289", "重口激情"),
    ("169", "SM调教"),
    ("78", "日本精品"),
    ("61", "森林资源"),
    ("397", "家庭乱伦"),
    ("29", "3P合辑"),
    ("135", "日韩精品"),
    ("423", "精选视频"),
    ("18", "大地资源"),
    ("48", "桃花资源"),
    ("132", "杏吧资源"),
    ("347", "乐播资源"),
    ("434", "兔子先生"),
    ("400", "少女萝莉"),
    ("374", "国产裸聊"),
    ("179", "貧乳小奶"),
    ("370", "卡通动漫"),
    ("363", "人兽性交"),
    ("85", "欺辱凌辱"),
    ("315", "极品媚黑"),
    ("292", "SM调教"),
    ("161", "日本素人"),
    ("172", "制服诱惑"),
    ("615", "SM重味"),
    ("149", "自慰系列"),
    ("69", "欧美精品"),
    ("94", "风情旗袍"),
    ("383", "国产区"),
    ("408", "淫欲痴女"),
    ("426", "天美传媒"),
    ("175", "多人群交"),
    ("86", "剧情介绍"),
    ("64", "主播直播"),
    ("177", "丝袜美腿"),
    ("150", "教师学生"),
    ("379", "少女萝莉"),
    ("638", "学生空姐"),
    ("50", "华语AV"),
    ("33", "口交视频"),
    ("415", "男同性恋"),
    ("614", "AV明星"),
    ("356", "中文字幕"),
];

/// 2026-11-05 实测可用的基址（当日候选之一），解析失败时兜底。
const FALLBACK_BASE: &str = "https://lqs005.10mf4k03.buzz";

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

/// 跳转页 JS 的取词算法：种子经线性同余迭代，取 3 字母 + 3 数字。
fn generate_word(mut seed: i64) -> String {
    const LETTERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz";
    let mut word = String::new();
    for _ in 0..3 {
        seed = (seed * 9301 + 49297) % 233280;
        word.push(LETTERS[(seed * 26 / 233280) as usize] as char);
    }
    for _ in 0..3 {
        seed = (seed * 9301 + 49297) % 233280;
        word.push_str(&(seed * 10 / 233280).to_string());
    }
    word
}

/// 当日两个候选基址（种子为东八区当日年月日，及种子 + 1）。
fn host_candidates() -> Vec<String> {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
        + 8 * 3600;
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let seed = y * 10_000 + m as i64 * 100 + d as i64;
    [seed, seed + 1]
        .iter()
        .map(|s| format!("https://{}.10mf4k03.buzz", generate_word(*s)))
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
        let url = format!("{base}/box/");
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
        return Err(ApiError::Internal(format!(
            "海角社区高清4K请求 HTTP {status}"
        )));
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

/// 分类解析：首页 `/vodtype/<id>/` 锚点（跳过“更多”）+ 栏目
/// 标题（`<div class="title"><h3>名</h3>…/vodtype/<id>/`）补齐。
fn parse_categories(html: &str) -> Vec<Value> {
    let mut names: Vec<(String, String)> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let re = match Regex::new(r#"href="/vodtype/(\d+)/"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || name == "更多" || !seen.insert(id.clone()) {
            continue;
        }
        names.push((id, name));
    }
    let sec_re = match Regex::new(
        r#"(?s)<div class="title">\s*<h3>([^<]+)</h3>.*?<a[^>]*href="/vodtype/(\d+)/""#,
    ) {
        Ok(re) => re,
        Err(_) => {
            return names
                .iter()
                .map(|(id, name)| category_json(id, name))
                .collect();
        }
    };
    for cap in sec_re.captures_iter(html) {
        let name = cap[1].trim().to_string();
        let id = cap[2].to_string();
        if name.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        names.push((id, name));
    }
    names
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect()
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
    match get_text(&format!("{base}/box/")).await {
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

/// 卡片解析：`<a href="/voddetail/<id>/">` 内 img data-original
/// （封面）+ 随后 `<h3>` 标题（限在同一卡片内）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/voddetail/(\d+)/"[^>]*><img[^>]*data-original="([^"]+)"[^>]*>.*?</a>.*?<h3>([^<]+)</h3>"#,
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

/// 播放页标题：`<b>在线播放 <标题></b>`。
fn parse_play_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<b>在线播放\s*([^<]+)</b>").ok() {
        Some(re) => re,
        None => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => String::new(),
    }
}

/// 详情页标题兜底：meta description 为 `<标题>剧情:-海角社区高清4K-`。
fn parse_desc_title(html: &str) -> String {
    let re = match Regex::new(r#"<meta name="description"[^>]*content="([^"]*)""#).ok() {
        Some(re) => re,
        None => return String::new(),
    };
    let Some(cap) = re.captures(html) else {
        return String::new();
    };
    let desc = unescape(cap[1].trim());
    match desc.split_once("剧情:") {
        Some((title, _)) => title.trim().to_string(),
        None => desc,
    }
}

fn parse_synopsis(html: &str) -> String {
    let re = match Regex::new(r#"<meta name="description"[^>]*content="([^"]*)""#).ok() {
        Some(re) => re,
        None => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => String::new(),
    }
}

/// 详情页封面：og:image（排除 favicon），否则首个含 upload/vod 的绝对图。
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
    let cover = parse_cover(&html);
    let synopsis = parse_synopsis(&html);
    let desc_title = parse_desc_title(&html);
    let play_html = get_text(&format!("{base}/vodplay/{vid}-1-1/")).await?;
    let m3u8 = parse_player_url(&play_html);
    let mut title = parse_play_title(&play_html);
    if title.is_empty() {
        title = desc_title;
    }
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("海角社区高清4K未返回可播放地址".into()));
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
        Err(ApiError::Internal("海角社区高清4K该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return play_check(vid);
    }
    if vid.is_empty() || !vid.chars().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::Internal("海角社区高清4K该集没有播放地址".into()));
    }
    let base = resolve_base().await;
    let html = get_text(&format!("{base}/vodplay/{vid}-1-1/")).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("海角社区高清4K未返回可播放地址".into()));
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
    fn generate_word_matches_jump_page() {
        assert_eq!(generate_word(20261105), "lqs005");
        assert_eq!(generate_word(20261106), "mlm206");
    }

    #[test]
    fn civil_from_days_known() {
        assert_eq!(civil_from_days(20762), (2026, 11, 5));
        assert_eq!(civil_from_days(0), (1970, 1, 1));
    }

    #[test]
    fn parse_categories_skips_more_and_fills_sections() {
        let html = r#"<div class="menu clearfix"><dl><dt><a>国产视频</a></dt><dd><a target="_blank" href="/vodtype/600/">极品资源</a></dd><dd><a target="_blank" href="/vodtype/435/">杏吧原创</a></dd><dd><a target="_blank" href="/vodtype/600/">极品资源</a></dd></dl></div><div class="wrap"><div class="mod index-list"><div class="title"><h3>精选视频</h3><span class="total"><a target="_blank" href="/vodtype/423/">更多</a></span></div></div></div>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "600");
        assert_eq!(list[1]["id"], "435");
        assert_eq!(list[2]["id"], "423");
        assert_eq!(list[2]["name"], "精选视频");
    }

    #[test]
    fn fallback_has_72_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 72);
        assert_eq!(list[0]["id"], "600");
        assert_eq!(list[0]["name"], "极品资源");
        assert_eq!(list[71]["id"], "356");
        assert_eq!(list[71]["name"], "中文字幕");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="row col5 clearfix" id="block-post"> <dl> <dt class="preview-item"><a href="/voddetail/1874954/" target="_blank"><img class="nature lazy" data-original="https://thjpg16.vip/upload/vod/20261105-1/69135a819b295d18a086e48bef808b65.png" src="/template/vod/loading.png"><i></i> <div class="preview-div"></div> </a></dt> <dd><a href="/voddetail/1874954/" target="_blank"> <h3>国产自拍 猛操套子脱落，无套内射妹子惊呼</h3> </a></dd> </dl> <dl> <dt class="preview-item"><a href="/voddetail/1874062/" target="_blank"><img class="nature lazy" data-original="https://picmeta2026.xyz/upload/vod/20261104-1/122104a9e471ac9f25459db029a8bddc.jpg" src="/template/vod/loading.png"><i></i> <div class="preview-div"></div> </a></dt> <dd><a href="/voddetail/1874062/" target="_blank"> <h3>东京女子图鉴 纱也佳 24岁 INS博主</h3> </a></dd> </dl> </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "1874954");
        assert_eq!(items[0]["title"], "国产自拍 猛操套子脱落，无套内射妹子惊呼");
        assert_eq!(
            items[0]["cover"],
            "https://thjpg16.vip/upload/vod/20261105-1/69135a819b295d18a086e48bef808b65.png"
        );
        assert_eq!(items[1]["id"], "1874062");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/vodplay\/1874808-1-1\/","link_next":"","link_pre":"","url":"https:\/\/t27.cdn2020.com\/video\/m3u8\/2026\/11\/03\/1c5ce67b\/index.m3u8","url_next":"","from":"dplayer","server":"no","note":""}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://t27.cdn2020.com/video/m3u8/2026/11/03/1c5ce67b/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_play_title_and_desc_title() {
        let play = "<div><b>在线播放 东京女子图鉴 纱也佳 24岁 INS博主</b></div>";
        assert_eq!(parse_play_title(play), "东京女子图鉴 纱也佳 24岁 INS博主");
        let detail = r#"<meta name="description" content="东京女子图鉴 纱也佳 24岁 INS博主剧情:-海角社区高清4K-">"#;
        assert_eq!(parse_desc_title(detail), "东京女子图鉴 纱也佳 24岁 INS博主");
        assert_eq!(
            parse_synopsis(detail),
            "东京女子图鉴 纱也佳 24岁 INS博主剧情:-海角社区高清4K-"
        );
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            catalog_url("https://lqs005.10mf4k03.buzz", "435", 1),
            "https://lqs005.10mf4k03.buzz/vodtype/435/"
        );
        assert_eq!(
            catalog_url("https://lqs005.10mf4k03.buzz", "435", 2),
            "https://lqs005.10mf4k03.buzz/vodtype/435-2/"
        );
    }

    #[test]
    fn parse_cover_real_detail_page() {
        // 真实详情页 /voddetail/1874808/ 片段：og:image 是 favicon、
        // 首图是站内横幅 gif（相对路径）、第二张即 detail_left 本片海报。
        let html = r#"<meta property="og:image" content="/favicon.ico"><img style="height:80px; width: 100%;" src="/upload/vod/20260906-1/b60616550e22cd6448852d867d1dd748.gif" alt="" /><div class="detail_left"> <img src="https://picmeta2026.xyz/upload/vod/20261104-1/122104a9e471ac9f25459db029a8bddc.jpg" alt="Happy 10 Million Views to us WetPinayers! Shower Scene Bloopers"> </div>"#;
        assert_eq!(
            parse_cover(html),
            "https://picmeta2026.xyz/upload/vod/20261104-1/122104a9e471ac9f25459db029a8bddc.jpg"
        );
        assert_eq!(parse_cover("<div>no images</div>"), "");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://t27.cdn2020.com/video/m3u8/2026/11/03/1c5ce67b/index.m3u8")
            .unwrap();
        assert_eq!(
            ok["url"],
            "https://t27.cdn2020.com/video/m3u8/2026/11/03/1c5ce67b/index.m3u8"
        );
        assert!(play_check("1874808").is_err());
    }
}
