//! 妇愁者联盟：核心里的影视区站点。
//!
//! MacCMS 站（站根 /index.php/vod/，无 /a/ 前缀）。详情页
//! /index.php/vod/detail/id/<n>.html 只是 JS 跳转壳（location.replace
//! 到播放页），故 detail() 直接取播放页；播放页用 player_data
//!（无 player_aaaa 时亦可）给 m3u8（主清单 200、METHOD=NONE、
//! 首分片 200，无需特殊头，分片为.jpg 后缀的 ts 流）；卡片
//! dx-card 直接链播放页；搜索 /index.php/vod/search.html?wd=。
//! 分类与站导航 1:1（63 项）：4 个父组（热播片库、精品资源、
//! 特色仓库、网曝黑料）+ 59 个子分类，每页约 21-22 条。
//! 注意：本站响应常被出口截断（48KB/56KB 处断开），get_text
//! 重试 3 次，播放页取到 64KB 以上才含 player_data。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, with_query};

const BASE: &str = "https://kkb1.sixnicefczlm.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("1", "热播片库"),
    ("6", "禁忌母子"),
    ("7", "兄弟姐妹"),
    ("8", "爱上嫂子"),
    ("9", "狂操小姨"),
    ("10", "换夫换妻"),
    ("11", "淫荡儿媳"),
    ("12", "爷爷奶奶"),
    ("20", "乱伦精选"),
    ("2", "精品资源"),
    ("13", "JK少女"),
    ("14", "黑丝白丝"),
    ("15", "女仆"),
    ("16", "cosplay"),
    ("21", "OL制服"),
    ("22", "旗袍"),
    ("23", "空姐制服"),
    ("24", "护士医生"),
    ("3", "特色仓库"),
    ("25", "学生少女"),
    ("26", "技师风采"),
    ("27", "熟女少妇"),
    ("28", "国产热播"),
    ("29", "反差母狗"),
    ("30", "美脚丝足"),
    ("31", "情侣自拍"),
    ("32", "私房俱乐部"),
    ("4", "网曝黑料"),
    ("33", "偷情约炮"),
    ("34", "真实偷拍"),
    ("35", "高潮喷水"),
    ("36", "强奸迷奸"),
    ("37", "户外露出"),
    ("38", "SM调教"),
    ("39", "情趣内衣"),
    ("40", "精选探花"),
    ("41", "国产剧情"),
    ("42", "网曝门事件"),
    ("43", "校园猛料"),
    ("44", "网红流出"),
    ("45", "明星黑料"),
    ("46", "裸贷肉偿"),
    ("47", "婚闹恶俗"),
    ("48", "抓奸名场面"),
    ("49", "男同女同"),
    ("50", "国产传媒"),
    ("51", "人兽性交"),
    ("52", "SM性虐"),
    ("53", "人妖伪娘"),
    ("54", "孕妇内射"),
    ("55", "吃屎喝尿"),
    ("56", "扩阴拳交"),
    ("57", "阳具巨物"),
    ("58", "动漫"),
    ("59", "必射精选"),
    ("60", "日本中文"),
    ("61", "无码流出"),
    ("62", "网红主播"),
    ("63", "主播网黄"),
    ("64", "国产AV"),
    ("65", "车震直播"),
    ("66", "自慰诱惑"),
    ("67", "欧美重口"),
];

/// 带重试的 GET：本站响应常被截断，最多试 3 次。
async fn get_text(path: &str) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(&url).await {
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
        return Err(ApiError::Internal(format!("妇愁者联盟请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 地址归一：站内相对路径补基址，协议相对补 https。
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
        .replace("&#x67E5;&#x770B;&#x66F4;&#x591A;", "")
}

/// 卡片解析：`dx-card` + play id + title 属性（标题）+ img src（封面）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="dx-card" href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*title="([^"]*)".*?<img src="([^"]+)""#,
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

/// 分类解析：首页标签面板里的 type 锚点（按站内顺序、id 去重），
/// “查看更多”锚点（实体编码文本）跳过。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"<a href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty()
            || name.contains("查看")
            || name.contains("67E5")
            || !seen.insert(id.clone())
        {
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
    match get_text("/").await {
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
    let path = if page <= 1 {
        format!("/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&path).await?;
    let items = parse_cards(&html);
    // 站内分页器在页尾，常随截断丢失；按页容量估算：满 20 条即有下一页。
    let has_more = items.len() >= 20;
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放地址：播放页 player_data（或 player_aaaa）JSON 的 url 字段
///（m3u8，\/ 转义还原）。
fn parse_player_url(html: &str) -> String {
    for var in ["player_data", "player_aaaa"] {
        let pattern = format!(r#"(?s){var}=.*?"url":"([^"]+)""#);
        if let Ok(re) = Regex::new(&pattern) {
            if let Some(cap) = re.captures(html) {
                let url = unescape(&cap[1]);
                if !url.is_empty() {
                    return url;
                }
            }
        }
    }
    String::new()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    // 详情页只是 JS 跳转壳，直接取播放页拿标题与分集。
    let play_path = format!("/index.php/vod/play/id/{id}/sid/1/nid/1.html");
    let html = get_text(&play_path).await?;
    let title_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = title.strip_suffix(" - 妇愁者联盟") {
        title = stripped.to_string();
    }
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let ep_re = Regex::new(&format!(
        r#"/index\.php/vod/play/id/{}/sid/1/nid/(\d+)\.html"#,
        regex::escape(id)
    ))
    .ok();
    let mut episodes = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Some(re) = &ep_re {
        for cap in re.captures_iter(&html) {
            let nid = cap[1].to_string();
            if !seen.insert(nid.clone()) {
                continue;
            }
            let href = format!("/index.php/vod/play/id/{id}/sid/1/nid/{nid}.html");
            episodes.push(episode_json(
                &fix_url(&href),
                &format!("第{nid}集"),
                series_id,
            ));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&fix_url(&play_path), "第1集", series_id));
    }
    if title.is_empty() {
        return Err(ApiError::Internal("妇愁者联盟未返回标题".into()));
    }
    Ok(json!({
    "id": series_id,
    "title": title,
    // 播放页无本片海报，封面留空（列表页封面正常）。
    "cover": "",
    "synopsis": synopsis,
    "extra": {},
    "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        fix_url(video_id)
    };
    if !url.contains("/vod/play/") {
        if url.starts_with("http") && url.ends_with(".m3u8") {
            return Ok(json!({"url": url}));
        }
        return Err(ApiError::Internal("妇愁者联盟该集没有播放地址".into()));
    }
    let path = match url.find("/index.php") {
        Some(pos) => url[pos..].to_string(),
        None => url.clone(),
    };
    let html = get_text(&path).await?;
    let m3u8 = parse_player_url(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("妇愁者联盟未返回可播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/index.php/vod/search.html"),
        &[("wd", query)],
    );
    let path = url.strip_prefix(BASE).unwrap_or(&url).to_string();
    let html = get_text(&path).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/index.php/vod/play/id/29951/sid/1/nid/1.html"),
            "https://kkb1.sixnicefczlm.cc/index.php/vod/play/id/29951/sid/1/nid/1.html"
        );
        assert_eq!(
            fix_url("https://thm3u8.co/20261103/98c729c5a806b186/index.m3u8"),
            "https://thm3u8.co/20261103/98c729c5a806b186/index.m3u8"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a class="dx-card" href="/index.php/vod/play/id/29951/sid/1/nid/1.html" name="rdmonclick" target="_blank" title="全网最真实，历经三个月，终于操到了自己亲妈…"><span class="dx-card__pic"><img src="https://ckbhjpg2.top/upload/vod/20261103-1/af7c508c99f268122146cf434f48e961.png" alt="全网最真实" loading="lazy"></span><strong>全网最真实</strong></a><a class="dx-card" href="/index.php/vod/play/id/29951/sid/1/nid/1.html" title="全网最真实"><img src="https://ckbhjpg2.top/upload/vod/20261103-1/af7c508c99f268122146cf434f48e961.png"></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "29951");
        assert_eq!(
            items[0]["title"],
            "全网最真实，历经三个月，终于操到了自己亲妈…"
        );
        assert_eq!(
            items[0]["cover"],
            "https://ckbhjpg2.top/upload/vod/20261103-1/af7c508c99f268122146cf434f48e961.png"
        );
    }

    #[test]
    fn parse_categories_skips_more_link() {
        let html = r#"<a href="/index.php/vod/type/id/1.html">热播片库</a><a href="/index.php/vod/type/id/6.html">禁忌母子</a><a href="/index.php/vod/type/id/6.html">&#x67E5;&#x770B;&#x66F4;&#x591A;</a><a href="/index.php/vod/type/id/2.html">精品资源</a><a href="/index.php/vod/type/id/1.html">热播片库</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[1]["name"], "禁忌母子");
        assert_eq!(list[2]["name"], "精品资源");
    }

    #[test]
    fn fallback_has_63_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 63);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[1]["name"], "禁忌母子");
        assert_eq!(list[62]["name"], "欧美重口");
    }

    #[test]
    fn parse_player_url_prefers_player_data() {
        let html = r#"<script>var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/index.php\/vod\/play\/id\/29951\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","url":"https:\/\/thm3u8.co\/20261103\/98c729c5a806b186\/index.m3u8","url_next":"","from":"ckm3u8","server":"","note":""}</script>"#;
        assert_eq!(
            parse_player_url(html),
            "https://thm3u8.co/20261103/98c729c5a806b186/index.m3u8"
        );
        let html2 = r#"var player_aaaa={"url":"https:\/\/x.y\/a.m3u8"}"#;
        assert_eq!(parse_player_url(html2), "https://x.y/a.m3u8");
        assert_eq!(parse_player_url("<div>no player</div>"), "");
    }

    #[test]
    fn search_url_builds_query() {
        let url = with_query(
            &format!("{BASE}/index.php/vod/search.html"),
            &[("wd", "人妻")],
        );
        assert_eq!(
            url,
            "https://kkb1.sixnicefczlm.cc/index.php/vod/search.html?wd=%E4%BA%BA%E5%A6%BB"
        );
    }
}
