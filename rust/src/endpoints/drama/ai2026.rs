//! 2026短剧AI：核心里的影视区站点。
//!
//! MacCMS 站，入口 https://2026.2026aidjtz.top/?yng 为跳转页，
//! 固定跳往 https://11051735.2026aidj18.lol/?yng（站名 2026AI短剧）。
//! 与站导航 1:1（115 项，见 CATS；首页各分区另有 5 个“更多>>”
//! 链接指向 id 184-188 的聚合页，不是分类，已排除）。
//! 列表 `/index.php/vod/type/id/<n>/`，翻页
//! `/index.php/vod/type/id/<n>/page/<p>.html`，每页 12 条；
//! 详情 `/index.php/vod/detail/id/<id>.html`（标题取 <title>，
//! 首张 data-original 图为封面）；取流在播放页
//! `/index.php/vod/play/id/<id>/sid/1/nid/1.html` 的 player_aaaa
//! JSON 的 url 字段（m3u8，媒体清单直出 200、AES-128 密钥 206
//! 取回 16 字节、首分片字节可达，实测于 2026-11-05）；
//! 搜索 `/index.php/vod/search.html?wd=`。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://11051735.2026aidj18.lol";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("20", "AI短剧"),
    ("21", "视频1区"),
    ("22", "视频2区"),
    ("23", "国产精品"),
    ("24", "华语AV"),
    ("25", "黑料吃瓜"),
    ("26", "欧美"),
    ("27", "禁漫"),
    ("28", "学生"),
    ("29", "乱伦"),
    ("30", "探花"),
    ("31", "日本无码"),
    ("32", "日本有码"),
    ("33", "主播网红"),
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
    ("64", "网红主播"),
    ("65", "国产传媒"),
    ("67", "人妻熟女"),
    ("68", "美乳巨乳"),
    ("69", "强制侵犯"),
    ("70", "制服诱惑"),
    ("73", "家庭乱伦"),
    ("76", "少女萝莉"),
    ("77", "SM调教"),
    ("78", "绝顶潮吹"),
    ("83", "电车痴汉"),
    ("84", "淫欲痴女"),
    ("88", "女同性恋"),
    ("90", "欧美精品"),
    ("91", "国产自拍"),
    ("92", "日本动漫"),
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
        return Err(ApiError::Internal(format!("2026短剧AI请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 地址归一：协议相对补 https，站内相对路径补基址。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("\\/", "/")
}

/// 卡片解析：list-link 锚点的 title（标题）+ img data-original（封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a[^>]+href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*title="([^"]+)"[^>]*>.*?<img[^>]+data-original="([^"]+)""#,
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
        let title = unescape(cap[2].trim());
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[3]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页导航锚点文本，按站内顺序、id 去重；“更多>>”不是分类，跳过。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)<"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || name == "更多>>" || !seen.insert(id.clone()) {
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
    match get_text(BASE).await {
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

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page <= 1 {
        format!("{BASE}/index.php/vod/type/id/{category_id}/")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty()
        && html.contains(&format!(
            "/index.php/vod/type/id/{category_id}/page/{}.html",
            page + 1
        ));
    Ok(json!({"items": items, "has_more": has_more}))
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

/// 详情页标题：<title> 去“视频详情,2026AI短剧”后缀。
fn parse_title(html: &str) -> String {
    let re = match Regex::new(r"(?s)<title>(.*?)</title>") {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    let raw = match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => return String::new(),
    };
    let raw = raw.strip_suffix(",2026AI短剧").unwrap_or(&raw).to_string();
    let raw = raw.strip_suffix("视频详情").unwrap_or(&raw).to_string();
    raw.trim().to_string()
}

/// 详情页封面：首张 data-original 图。
fn parse_cover(html: &str) -> String {
    let re = match Regex::new(r#"<img[^>]+data-original="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => fix_url(&cap[1]),
        None => String::new(),
    }
}

fn parse_synopsis(html: &str) -> String {
    let re = match Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => String::new(),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let id = id.strip_prefix("index.php/vod/detail/id/").unwrap_or(id);
    let id = id.trim_end_matches(".html");
    let html = get_text(&format!("{BASE}/index.php/vod/detail/id/{id}.html")).await?;
    let title = parse_title(&html);
    let cover = parse_cover(&html);
    let synopsis = parse_synopsis(&html);
    let play_re = Regex::new(r#"href="(/index\.php/vod/play/id/\d+/sid/1/nid/1\.html)""#).ok();
    let play_path = match &play_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() || play_path.is_empty() {
        return Err(ApiError::Internal(
            "2026短剧AI详情页缺少标题或播放入口".into(),
        ));
    }
    let play_html = get_text(&format!("{BASE}{play_path}")).await?;
    let m3u8 = parse_player_url(&play_html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("2026短剧AI未返回可播放地址".into()));
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
        Err(ApiError::Internal("2026短剧AI该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
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
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/upload/vod/20261102-1/00402efdd03ed9b4068ce80f00cbe7f7.jpg"),
            "https://11051735.2026aidj18.lol/upload/vod/20261102-1/00402efdd03ed9b4068ce80f00cbe7f7.jpg"
        );
        assert_eq!(fix_url("//98jpg1.vip/x.jpg"), "https://98jpg1.vip/x.jpg");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="list-link" href="/index.php/vod/detail/id/107.html" title="《老农调教精致母狗》" target="_blank"> <div class="img"> <img class="lazy" data-original="https://98jpg1.vip/upload/vod/20260922-1/51d237c0c6340e9ed6f87cf06e11e62f.jpg" src="/template/demo021/images/lazyload.gif" alt="《老农调教精致母狗》"> <span class="video-bg"></span> <p class="list-name">《老农调教精致母狗》</p> <p class="list-content">简介：林氏集团千金林晗为了推进公司的开发工作，亲自来到城中村与村民沟通，却不料被村长的父亲盯上，这名村中老农誓要将大城市精致白领调教成全村共用的母狗……</p> </div> </a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "107");
        assert_eq!(items[0]["title"], "《老农调教精致母狗》");
        assert_eq!(
            items[0]["cover"],
            "https://98jpg1.vip/upload/vod/20260922-1/51d237c0c6340e9ed6f87cf06e11e62f.jpg"
        );
    }

    #[test]
    fn parse_categories_skips_more_links() {
        let html = r#"<a href="/index.php/vod/type/id/20.html">AI短剧</a><a href="/index.php/vod/type/id/21.html">视频1区</a><a href="/index.php/vod/type/id/184.html" target="_self">更多>></a><a href="/index.php/vod/type/id/20.html">AI短剧</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "20");
        assert_eq!(list[1]["name"], "视频1区");
    }

    #[test]
    fn fallback_has_115_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 115);
        assert_eq!(list[0]["name"], "AI短剧");
        assert_eq!(list[114]["name"], "私房俱乐部");
    }

    #[test]
    fn parse_player_url_real_markup() {
        let html = r#"<script type="text/javascript">var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/98582\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"《父女同乐》","vod_actor":"","vod_director":"","vod_class":"乱伦"},"url":"https:\/\/c10.hs100.top\/20261102\/e78603419dcda8ca\/index.m3u8","url_next":"","from":"hs100","server":"","note":"","id":"98582","sid":1,"nid":1}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://c10.hs100.top/20261102/e78603419dcda8ca/index.m3u8"
        );
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn parse_title_strips_suffix() {
        let html = r#"<title>《《父女同乐》》视频详情,2026AI短剧</title>"#;
        assert_eq!(parse_title(html), "《《父女同乐》》");
        assert_eq!(parse_title("<div>no title</div>"), "");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://c10.hs100.top/20261102/e78603419dcda8ca/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://c10.hs100.top/20261102/e78603419dcda8ca/index.m3u8"
        );
        assert!(play_check("98582").is_err());
    }
}
