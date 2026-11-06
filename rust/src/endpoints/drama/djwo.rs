//! 短剧窝：核心里的影视区站点。
//!
//! 入口 langwosp.xyz/ravo/kelmi.html 是跳转页，实站落在
//! langwonqyl.forum（与中文短剧网同模板、不同库：分类 id
//! 段 223-294、详情走 /info/id/、搜索走 /lookup/，视频
//! id 段也不同，不是同站）。站首页提示“部分视频首次点击
//! 可能会跳转至合作站点，再次点击即可正常观影”，属站内
//! 导流提示，不影响直取。
//! - 分类 68 个，与首页分类行 /type/id/ 链接 1:1。
//! - 目录：/type/id/<id>.html，翻页 /type/id/<id>/<n>.html，
//!   每页 20 条；卡片标题在 h3.video-title 的 <text> 里、
//!   封面在 img.lazy 的 src。
//! - 详情：/info/id/<id>.html，标题 h1.title 的 <text>、
//!   封面为首张 /upload/vod/ 图、简介取 meta description；
//!   播放入口 /play/id/<id>.html，单集。
//! - 取流：播放页 Aliplayer 的 playUrl 即 m3u8（实测
//!   2740134：v.heicdn.com 主清单 200、变体清单 200、
//!   首分片带 Referer（播放清单地址本身）实测时通时不通
//!   （一次回 200、472KB，另一次回 403，须手机端复验）；
//!   注意 Referer 用播放页地址时分片回 403（nginx 防盗链），
//!   故 play() 返回的 header 里 Referer 直接用清单地址本身）。
//! - 搜索：/lookup/<词>.html，实测“美女”20 条。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://langwonqyl.forum";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页分类行，站内顺序，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("223", "国产视频"),
    ("224", "精品推荐"),
    ("225", "国产色情"),
    ("226", "中文字幕"),
    ("227", "主播直播"),
    ("228", "国产传媒"),
    ("229", "亚洲无码"),
    ("230", "日本有码"),
    ("231", "亚洲有码"),
    ("232", "日本无码"),
    ("233", "中文有码"),
    ("234", "欧美无码"),
    ("235", "巨乳美乳"),
    ("236", "强奸乱伦"),
    ("237", "人妻系列"),
    ("238", "制服诱惑"),
    ("239", "强奸精品"),
    ("240", "直播主播"),
    ("241", "欧美精品"),
    ("242", "激情动漫"),
    ("243", "萝莉少女"),
    ("244", "明星换脸"),
    ("245", "伦理三级"),
    ("246", "抖阴视频"),
    ("248", "女优明星"),
    ("249", "自拍偷拍"),
    ("250", "视频一区"),
    ("251", "制服丝袜"),
    ("252", "视频二区"),
    ("253", "口交颜射"),
    ("254", "网-曝-门"),
    ("255", "日本精品"),
    ("256", "视频三区"),
    ("257", "Cosplay"),
    ("258", "伦理三级"),
    ("259", "素人自拍"),
    ("260", "AV解说"),
    ("261", "台湾辣妹"),
    ("262", "SM调教"),
    ("263", "韩国御姐"),
    ("264", "萝莉少女"),
    ("265", "唯美港姐"),
    ("267", "东南亚AV"),
    ("268", "女同性恋"),
    ("269", "欺辱凌辱"),
    ("270", "玩偶姐姐"),
    ("271", "剧情介绍"),
    ("272", "视频四区"),
    ("273", "多人多P"),
    ("274", "人妖系列"),
    ("275", "91探花"),
    ("276", "网红流出"),
    ("277", "野外露出"),
    ("278", "古装扮演"),
    ("279", "女优系列"),
    ("280", "可爱学生"),
    ("281", "风情旗袍"),
    ("282", "兽耳系列"),
    ("283", "瑜伽裤"),
    ("284", "闷骚护士"),
    ("285", "过膝袜"),
    ("286", "网曝门"),
    ("287", "传媒出品"),
    ("288", "女同性恋"),
    ("289", "男同性恋"),
    ("290", "恋腿狂魔"),
    ("293", "韩国主播"),
    ("294", "VR视角"),
];

/// 带重试的 GET：站间歇回空响应，最多试 3 次，每次间隔 2 秒。
async fn get_text(url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_once(url).await {
            Ok(text) => return Ok(text),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("短剧窝请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("短剧窝返回空响应".into()));
    }
    Ok(text)
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// 卡片解析：/info/id/<id>.html 锚点 + img.lazy 封面 + 随后
/// h3.video-title 内 <text> 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re =
        match Regex::new(r#"(?s)<a href="/info/id/(\d+)\.html"[^>]*>\s*<img[^>]*src="([^"]+)""#) {
            Ok(re) => re,
            Err(_) => return Vec::new(),
        };
    let title_re = Regex::new(r#"(?s)<h3 class="video-title">.*?<text>([^<]+)</text>"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let id = cap[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = cap[2].trim().to_string();
        let tail = &html[cap.get(0).map(|m| m.end()).unwrap_or(0)..];
        let window = tail.get(..3000).unwrap_or(tail);
        let title = match &title_re {
            Some(re) => re
                .captures(window)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页 /type/id/<id>.html + title 属性的锚点。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/type/id/(\d+)\.html"[^>]*title="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = unescape(cap[2].trim());
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

/// 播放地址：播放页 Aliplayer 的 playUrl（m3u8）。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"var playUrl\s*=\s*'([^']+\.m3u8[^']*)'"#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => cap[1].trim().to_string(),
        None => String::new(),
    }
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
    let page = if page < 1 { 1 } else { page };
    let url = if page <= 1 {
        format!("{BASE}/type/id/{category_id}.html")
    } else {
        format!("{BASE}/type/id/{category_id}/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/type/id/{category_id}/{}.html", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/info/id/")
        .trim_end_matches(".html")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{BASE}/info/id/{id}.html")).await?;
    let h1_re = Regex::new(r#"(?s)<h1 class="title">.*?<text>([^<]+)</text>"#).ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(stripped) = title.strip_suffix("详情页") {
        title = stripped.trim().to_string();
    }
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        if let Some(re) = t_re {
            title = re
                .captures(&html)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default();
            if let Some(stripped) = title.strip_suffix("-短剧窝详情页面") {
                title = stripped.trim().to_string();
            }
        }
    }
    let cover_re = Regex::new(r#"<img[^>]*src="([^"]*?/upload/vod/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description" content="([^"]*)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("短剧窝详情未返回标题".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&id, "立即播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let vid = video_id.trim();
    if vid.starts_with("http") {
        return Ok(json!({"url": vid}));
    }
    let id = vid
        .trim_start_matches("/play/id/")
        .trim_end_matches(".html");
    let html = get_text(&format!("{BASE}/play/id/{id}.html")).await?;
    let stream = parse_play_url(&html);
    if stream.is_empty() {
        return Err(ApiError::Internal("短剧窝未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream.clone(),
        "header": {"User-Agent": UA, "Referer": stream},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{BASE}/lookup/{enc}.html");
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<li> <a href="/info/id/2840894.html" name="rdmonclick" target="_blank" class="enable-random-friend-link" rel="nofollow"> <img class="lazy" src="https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg"> </a> <div class="video-detail"><a href="/info/id/2840894.html" name="rdmonclick" target="_blank" rel="nofollow"></a> <h3 class="video-title"><a href="/info/id/2840894.html" name="rdmonclick" target="_blank" rel="nofollow"></a><a><text>[フェアリーダスト] くりいむレモン PART 30 亜麻木硅ベストヒット チェリーなゆううつ</text></a> </h3> </div> </li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "2840894");
        assert_eq!(
            items[0]["cover"],
            "https://pic.heiimg.com/upload/vod/20261104-1/587de26d40c19e8b4f150f3182b5c15b.jpg"
        );
        assert!(items[0]["title"]
            .as_str()
            .unwrap()
            .starts_with("[フェアリーダスト]"));
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/type/id/224.html" title="精品推荐" target="_blank"><text>精品推荐</text></a><a href="/type/id/225.html" title="国产色情" target="_blank"><text>国产色情</text></a><a href="/type/id/224.html" title="精品推荐" target="_blank"><text>精品推荐</text></a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "224");
        assert_eq!(list[1]["name"], "国产色情");
    }

    #[test]
    fn fallback_has_68_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 68);
        assert_eq!(list[0]["id"], "223");
        assert_eq!(list[67]["id"], "294");
        assert_eq!(list[67]["name"], "VR视角");
    }

    #[test]
    fn parse_play_url_real_markup() {
        let html = r#" <script> var playUrl = 'https://v.heicdn.com/20220803/Vm53SKHX/index.m3u8'; var player = new Aliplayer({ "id": "video", "source": playUrl, "#;
        assert_eq!(
            parse_play_url(html),
            "https://v.heicdn.com/20220803/Vm53SKHX/index.m3u8"
        );
        assert_eq!(parse_play_url("<div>no player</div>"), "");
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            format!("{BASE}/type/id/{}.html", "224"),
            "https://langwonqyl.forum/type/id/224.html"
        );
        assert_eq!(
            format!("{BASE}/type/id/{}/{}.html", "224", 2),
            "https://langwonqyl.forum/type/id/224/2.html"
        );
    }
}
