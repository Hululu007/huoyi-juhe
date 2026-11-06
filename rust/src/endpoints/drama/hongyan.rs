//! 红颜AI短剧：MacCMS 站，实测于 2026-11-05。
//!
//! 入口跳转页 `https://1103.hyaidjtz.top/?yuenvge`（JS 倒计时 1 秒）
//! 固定跳往 `https://1104.hyaidj221.lol/`，模块直连后者。
//! 分类与站导航 1:1（92 项，见 `/index.php/vod/type.html`）：
//! 视频1区/视频2区/精品推荐/主播秀色/中文字幕/童颜巨乳/性感人妻/
//! 强奸乱伦/丝袜OL/自拍偷拍/日本片商/网曝系列/麻豆传媒/国产乱伦…
//! 目录 `/index.php/vod/type/id/<id>.html`（p1），翻页
//! `/index.php/vod/type/id/<id>/page/<n>.html`（每页 20 条，
//! 视频1区实测 1204 页）；卡片直链播放页
//! `/index.php/vod/play/id/<vid>/sid/1/nid/1.html`（无独立详情页，
//! 详情即播放页）；取流为播放页 `player_aaaa` JSON 的 `url` 字段
//! （m3u8，如 `https://thm3u8.co/20261104/0be54146546cd5a2/index.m3u8`）；
//! 搜索 `GET /index.php/vod/search.html?wd=<词>`（“国产”实测 20 条）。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://1104.hyaidj221.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("21", "视频1区"),
    ("22", "视频2区"),
    ("35", "精品推荐"),
    ("36", "主播秀色"),
    ("37", "中文字幕"),
    ("38", "童颜巨乳"),
    ("39", "性感人妻"),
    ("40", "强奸乱伦"),
    ("44", "丝袜OL"),
    ("45", "自拍偷拍"),
    ("46", "日本片商"),
    ("48", "网曝系列"),
    ("49", "麻豆传媒"),
    ("51", "国产乱伦"),
    ("52", "国产丝袜"),
    ("53", "国产SM"),
    ("54", "国产人妻"),
    ("55", "探花嫖娼"),
    ("56", "同性恋"),
    ("57", "国产区"),
    ("58", "AV区"),
    ("59", "欧美区"),
    ("60", "动漫区"),
    ("61", "其他区"),
    ("62", "网曝门"),
    ("97", "学生少女"),
    ("98", "技师风采"),
    ("99", "熟女少妇"),
    ("100", "国产热播"),
    ("101", "反差母狗"),
    ("102", "美脚丝足"),
    ("103", "情侣自拍"),
    ("104", "偷情约炮"),
    ("105", "真实偷拍"),
    ("106", "高潮喷水"),
    ("108", "强奸迷奸"),
    ("109", "户外露出"),
    ("110", "情趣内衣"),
    ("111", "精选探花"),
    ("112", "黑料曝光"),
    ("113", "网曝门事件"),
    ("114", "校园猛料"),
    ("115", "网红流出"),
    ("116", "明星黑料"),
    ("119", "抓奸名场面"),
    ("120", "男同女同"),
    ("121", "JK少女"),
    ("122", "黑丝白丝"),
    ("123", "女仆"),
    ("124", "cosplay"),
    ("125", "OL制服"),
    ("127", "空姐制服"),
    ("128", "护士医生"),
    ("130", "禁忌母子"),
    ("131", "兄弟姐妹"),
    ("132", "爱上嫂子"),
    ("133", "狂操小姨"),
    ("134", "换夫换妻"),
    ("135", "淫荡儿媳"),
    ("136", "爷爷奶奶"),
    ("138", "啪啪直播"),
    ("139", "学生直播"),
    ("140", "自慰诱惑"),
    ("141", "乱伦直播"),
    ("142", "户外勾搭"),
    ("143", "车震直播"),
    ("144", "国产AV"),
    ("145", "欧美精选"),
    ("146", "户外搭讪"),
    ("147", "美女自慰"),
    ("148", "成人剧情"),
    ("149", "黑人大屌"),
    ("150", "群P大作战"),
    ("151", "欧美重口"),
    ("153", "人兽性交"),
    ("155", "人妖伪娘"),
    ("156", "孕妇内射"),
    ("158", "扩阴拳交"),
    ("159", "阳具巨物"),
    ("163", "日本中文"),
    ("164", "无码流出"),
    ("170", "伦理精选"),
    ("173", "主播网黄"),
    ("174", "色情综艺"),
    ("175", "情色AV"),
    ("176", "乱伦精选"),
    ("177", "私房俱乐部"),
    ("185", "国产自拍."),
    ("186", "主播."),
    ("187", "欧美."),
    ("188", "日本无码."),
    ("184", "AI短剧"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("红颜AI短剧请求 HTTP {status}")));
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

/// 分类解析：`/index.php/vod/type/id/<n>.html` 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/index.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>"#) {
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
    match get_text(&format!("{BASE}/index.php/vod/type.html")).await {
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

/// 卡片解析：播放页直链 + img src（封面）+ strong.title（标题）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)/index.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<strong class="title">([^<]+)</strong>"#,
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

fn has_more(html: &str, page: i64) -> bool {
    html.contains(&format!("/page/{}.html", page + 1))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page <= 1 {
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": has_more(&html, page)}))
}

/// 播放地址：播放页 player_aaaa JSON 的 url 字段（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    let re = match Regex::new(r#"(?s)player_aaaa=.*?"url":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(&cap[1]),
        None => String::new(),
    }
}

/// 标题：`<title>在线播放<标题> - 红颜AI短剧</title>` 去前后缀。
fn parse_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<title>(.*?)</title>").ok() {
        Some(re) => re,
        None => return String::new(),
    };
    let Some(cap) = re.captures(html) else {
        return String::new();
    };
    let mut title = unescape(cap[1].trim());
    if let Some(stripped) = title.strip_prefix("在线播放") {
        title = stripped.to_string();
    }
    if let Some(stripped) = title.strip_suffix(" - 红颜AI短剧") {
        title = stripped.to_string();
    }
    title.trim().to_string()
}

fn parse_cover(html: &str) -> String {
    let og_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
    if let Some(re) = og_re {
        if let Some(cap) = re.captures(html) {
            let cover = cap[1].trim().to_string();
            if !cover.is_empty() {
                return cover;
            }
        }
    }
    let poster_re = Regex::new(r#"poster="([^"]+)""#).ok();
    if let Some(re) = poster_re {
        if let Some(cap) = re.captures(html) {
            return cap[1].trim().to_string();
        }
    }
    String::new()
}

fn play_url(vid: &str) -> String {
    format!("{BASE}/index.php/vod/play/id/{vid}/sid/1/nid/1.html")
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vid = series_id.trim();
    let html = get_text(&play_url(vid)).await?;
    let title = parse_title(&html);
    let m3u8 = parse_player_url(&html);
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("红颜AI短剧未返回可播放地址".into()));
    }
    let cover = parse_cover(&html);
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
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
        Err(ApiError::Internal("红颜AI短剧该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return play_check(vid);
    }
    if vid.is_empty() || !vid.chars().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::Internal("红颜AI短剧该集没有播放地址".into()));
    }
    let html = get_text(&play_url(vid)).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("红颜AI短剧未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/index.php/vod/search.html"),
        &[("wd", query)],
    );
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/index.php/vod/type/id/21.html">视频1区</a><a href="/index.php/vod/type/id/22.html">视频2区</a><a href="/index.php/vod/type/id/21.html">视频1区</a><a href="/index.php/vod/type/id/35.html">精品推荐</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "21");
        assert_eq!(list[0]["name"], "视频1区");
        assert_eq!(list[2]["id"], "35");
    }

    #[test]
    fn fallback_has_92_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 92);
        assert_eq!(list[0]["id"], "21");
        assert_eq!(list[0]["name"], "视频1区");
        assert_eq!(list[91]["id"], "184");
        assert_eq!(list[91]["name"], "AI短剧");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<div class="item"> <a class="popup-video-link" href="/index.php/vod/play/id/35139/sid/1/nid/1.html" target="_blank"> <div class="mobile-preview"></div> <div class="img ithumb"> <img class="thumb lazy" src="https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png" data-src="https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png" width="293" height="165" /> </div><strong class="title">户外车震自拍最强美腿蜜臀尤物</strong> </a> </div> <div class="item"> <a class="popup-video-link" href="/index.php/vod/play/id/99573/sid/1/nid/1.html" target="_blank"> <div class="mobile-preview"></div> <div class="img ithumb"> <img class="thumb lazy" src="https://thjpg16.vip/upload/vod/20261105-1/ee03bdf9d649336e924b37aa302671e0.png" data-src="https://thjpg16.vip/upload/vod/20261105-1/ee03bdf9d649336e924b37aa302671e0.png" width="293" height="165" /> </div><strong class="title">欲求不满极品女神姬太爽了使劲打我鸡巴好胀好大口活真是一流口爆尤物</strong> </a> </div> <div class="item"> <a class="popup-video-link" href="/index.php/vod/play/id/35139/sid/1/nid/1.html" target="_blank"> <div class="mobile-preview"></div> <div class="img ithumb"> <img class="thumb lazy" src="https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png" width="293" height="165" /> </div><strong class="title">重复卡片</strong> </a> </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "35139");
        assert_eq!(items[0]["title"], "户外车震自拍最强美腿蜜臀尤物");
        assert_eq!(
            items[0]["cover"],
            "https://thjpg16.vip/upload/vod/20260221-1/57c431e9f2b1385e6dc59d72394faa3d.png"
        );
        assert_eq!(items[1]["id"], "99573");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/35139\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","url":"https:\/\/thm3u8.co\/20261104\/0be54146546cd5a2\/index.m3u8","url_next":"","from":"thm3u8","server":"","note":"","id":"35139","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://thm3u8.co/20261104/0be54146546cd5a2/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_title_strips_affixes() {
        let html = "<title>在线播放户外车震自拍最强美腿蜜臀尤物 - 红颜AI短剧</title>";
        assert_eq!(parse_title(html), "户外车震自拍最强美腿蜜臀尤物");
        assert_eq!(parse_title("<title>红颜AI短剧</title>"), "红颜AI短剧");
    }

    #[test]
    fn has_more_reads_next_page_link() {
        let html = r#"<a href="/index.php/vod/type/id/21/page/1.html">1</a><a href="/index.php/vod/type/id/21/page/2.html">2</a><a href="/index.php/vod/type/id/21/page/1204.html">1204</a>"#;
        assert!(has_more(html, 1));
        assert!(!has_more(html, 1204));
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://thm3u8.co/20261104/0be54146546cd5a2/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://thm3u8.co/20261104/0be54146546cd5a2/index.m3u8"
        );
        assert!(play_check("35139").is_err());
    }

    #[test]
    fn play_url_shape() {
        assert_eq!(
            play_url("35139"),
            "https://1104.hyaidj221.lol/index.php/vod/play/id/35139/sid/1/nid/1.html"
        );
    }
}
