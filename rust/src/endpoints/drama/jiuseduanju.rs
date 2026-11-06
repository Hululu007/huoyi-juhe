//! 九色短剧：核心里的影视区站点。
//!
//! 入口是阅女阁给的 IDN 快速加载页（标题“为了提升连线品质”，
//! 500ms 后 JS 跳到 https://www.jiuseai.top/aa/，
//! possibleValues 只有 www.jiuseai 一个值，落点固定）；
//! 实站为 MacCMS（/aa 前缀），与已注册的九色（jiuse，
//! jiusequ.cyou 的 /list/? 模板、日文番号标题）不是同站：
//! 域名、模板、视频 id 段、标题库均不同，本轮实测标题零重叠。
//! - 分类 72 项（站内顺序：顶栏 2-17、分区 62-77、44-59、
//!   19-42；id 1/18/43/61 只在“更多”链接里出现，无名，
//!   解析时跳过“更多”，不进分类表）。
//! - 目录：/aa/index.php/vod/type/id/<id>.html，翻页
//!   /page/<n>.html，每页 40 条；卡片直链播放页
//!   /aa/index.php/vod/play/id/<id>/sid/1/nid/1.html，
//!   封面 img.lazy 的 data-original、标题 h3.video-title 的
//!   <text>。
//! - 详情路由 /aa/index.php/vod/detail/id/<id>.html 回 500，
//!   故详情走播放页（与狠狠撸同款做法）：player_aaaa 的
//!   vod_name/vod_class 作标题/分类，封面取播放页首个
//!   data-original（相关推荐首图，站内无单片封面字段）。
//! - 取流：播放页 player_aaaa 的 url 即 m3u8（from slm3u8，
//!   实测 108656：2605.senlin2026.com 主清单 200、变体清单
//!   2000kb 200（408 分片、1219.8 秒）、首分片 3/3 回 200、
//!   1175752 字节、TS 魔数 47；trysee=0、points=0，全免费）。
//! - 搜索：GET /aa/index.php/vod/search.html?wd=，实测“国产”
//!   20 条。写源照站原样写，不按站名/分类名/标题删任何内容
//!   （用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://www.jiuseai.top/aa";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：首页顶栏 + 各分区，站内顺序，实测于 2026-11-06。
const CATS: &[(&str, &str)] = &[
    ("2", "精品推荐"),
    ("3", "国产精品"),
    ("4", "主播秀色"),
    ("5", "日本无码"),
    ("6", "欧美情色"),
    ("7", "自拍偷拍"),
    ("8", "日本片商"),
    ("9", "剧情介绍"),
    ("10", "网曝系列"),
    ("11", "同性恋"),
    ("12", "探花嫖娼"),
    ("13", "国产人妻"),
    ("14", "国产SM"),
    ("15", "国产丝袜"),
    ("16", "麻豆传媒"),
    ("17", "国产乱伦"),
    ("62", "国产主播"),
    ("63", "欧美劲爆"),
    ("64", "自拍偷拍"),
    ("65", "群P换妻"),
    ("66", "吃瓜黑料"),
    ("67", "酒店探花"),
    ("68", "直播裸聊"),
    ("69", "反差母狗"),
    ("70", "国产传媒"),
    ("71", "野战车震"),
    ("72", "SM调教"),
    ("73", "家庭乱伦"),
    ("74", "百合女同"),
    ("75", "学生空姐"),
    ("76", "撸管必看"),
    ("77", "偷情少妇"),
    ("44", "偷拍自拍"),
    ("45", "国产大制作"),
    ("46", "乱伦毁三观"),
    ("47", "主播女网红"),
    ("48", "黑料网曝"),
    ("49", "淫乱学生妹"),
    ("50", "FC2"),
    ("51", "会所技师"),
    ("52", "国产推荐"),
    ("53", "探花约炮"),
    ("54", "韩国直播"),
    ("55", "国产直播"),
    ("56", "淫妻绿帽"),
    ("57", "重口猎奇"),
    ("58", "东京热"),
    ("59", "一本道"),
    ("19", "精品推荐"),
    ("20", "国产色情"),
    ("21", "主播直播"),
    ("22", "自拍偷拍"),
    ("23", "Cosplay"),
    ("24", "素人自拍"),
    ("25", "台湾辣妹"),
    ("26", "韩国御姐"),
    ("27", "唯美港姐"),
    ("28", "剧情介绍"),
    ("29", "多人多P"),
    ("30", "91探花"),
    ("31", "网红流出"),
    ("32", "野外露出"),
    ("33", "古装扮演"),
    ("34", "女优系列"),
    ("35", "可爱学生"),
    ("36", "风情旗袍"),
    ("37", "兽耳系列"),
    ("38", "瑜伽裤"),
    ("39", "闷骚护士"),
    ("40", "网曝门"),
    ("41", "传媒出品"),
    ("42", "女同性恋"),
];

/// 带重试的 GET：站间歇回空响应，最多试 3 次，每次间隔 1 秒。
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
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("九色短剧请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("九色短剧返回空响应".into()));
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

/// 分类解析：顶栏与各分区的 type 锚点 + <text> 名；跳过“更多”。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(
        r#"href="/aa/index\.php/vod/type/id/(\d+)\.html"[^>]*>\s*<text>([^<]+)</text>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = unescape(cap[2].trim());
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

/// 卡片解析：播放页锚点 + img.lazy 的 data-original 封面 +
/// 随后 h3.video-title 内 <text> 标题。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/aa/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>\s*<img[^>]*data-original="([^"]+)""#,
    ) {
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

/// 播放页 player_aaaa JSON：大括号配对扫描，内含嵌套
/// vod_data 对象，普通 [^}]* 正则切不到 url 字段。
fn parse_player_aaaa(html: &str) -> Option<Value> {
    let start = html.find("player_aaaa=")?;
    let rest = &html[start + "player_aaaa=".len()..];
    let brace = rest.find('{')?;
    let bytes = rest.as_bytes();
    let mut depth = 0i32;
    let mut end = None;
    for (i, &b) in bytes.iter().enumerate().skip(brace) {
        if b == b'{' {
            depth += 1;
        } else if b == b'}' {
            depth -= 1;
            if depth == 0 {
                end = Some(i + 1);
                break;
            }
        }
    }
    let json_str = rest.get(brace..end?)?;
    serde_json::from_str(json_str).ok()
}

fn play_page_url(video_id: &str) -> String {
    let s = video_id.trim();
    let id = match s.find("/vod/play/id/") {
        Some(pos) => {
            let rest = &s[pos + "/vod/play/id/".len()..];
            rest.split(|c: char| !c.is_ascii_digit())
                .next()
                .unwrap_or("")
                .to_string()
        }
        None => s
            .trim_start_matches("/aa/index.php/vod/play/id/")
            .trim_start_matches("/vod/play/id/")
            .trim_end_matches(".html")
            .trim_end_matches('/')
            .split("/sid/")
            .next()
            .unwrap_or(s)
            .to_string(),
    };
    format!("{BASE}/index.php/vod/play/id/{id}/sid/1/nid/1.html")
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/index.php/index/index.html")).await {
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
        format!("{BASE}/index.php/vod/type/id/{category_id}.html")
    } else {
        format!("{BASE}/index.php/vod/type/id/{category_id}/page/{page}.html")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!(
            "/aa/index.php/vod/type/id/{category_id}/page/{}.html",
            page + 1
        ))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = play_page_url(series_id);
    let html = get_text(&url).await?;
    let player = parse_player_aaaa(&html)
        .ok_or_else(|| ApiError::Internal("九色短剧详情未取到播放器数据".into()))?;
    let vod = player.get("vod_data").cloned().unwrap_or(json!({}));
    let title = vod
        .get("vod_name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if title.is_empty() {
        return Err(ApiError::Internal("九色短剧详情未返回标题".into()));
    }
    let genre = vod
        .get("vod_class")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let cover_re = Regex::new(r#"data-original="([^"]*?/upload/vod/[^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {"genre": genre},
        "episodes": [episode_json(&url, "立即播放", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.ends_with(".m3u8") {
        return Ok(json!({"url": video_id}));
    }
    let url = play_page_url(video_id);
    let html = get_text(&url).await?;
    let player = parse_player_aaaa(&html)
        .ok_or_else(|| ApiError::Internal("九色短剧未取到播放器数据".into()))?;
    let stream = player
        .get("url")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if stream.is_empty() {
        return Err(ApiError::Internal("九色短剧未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{BASE}/index.php/vod/search.html?wd={enc}");
    let html = get_text(&url).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<a href="/aa/index.php/vod/play/id/276132/sid/1/nid/1.html" name="rdmonclick" target="_blank" rel="nofollow">
	<img class="lazy" data-original="https://yt.malatang10.xyz/mlt/upload/vod/20261025-1/ec3943e0f646ae0db36b01f3a27b2a97.jpg" src="/aa/template/abc/static/loading.svg">
	</a>
	<div class="video-detail"><a href="/aa/index.php/vod/play/id/276132/sid/1/nid/1.html" name="rdmonclick" target="_blank" rel="nofollow"></a>
	<h3 class="video-title"><a href="/aa/index.php/vod/play/id/276132/sid/1/nid/1.html" name="rdmonclick" target="_blank" rel="nofollow"></a><a><text>酒店绿叶房偷情东北小哥操完逼用被子给女友擦精液故.意把精液往她脸上抹</text></a> </h3> </div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "276132");
        assert_eq!(
            items[0]["cover"],
            "https://yt.malatang10.xyz/mlt/upload/vod/20261025-1/ec3943e0f646ae0db36b01f3a27b2a97.jpg"
        );
        assert!(items[0]["title"]
            .as_str()
            .unwrap()
            .starts_with("酒店绿叶房"));
    }

    #[test]
    fn parse_categories_skip_more() {
        let html = r#"<a href="/aa/index.php/vod/type/id/2.html" name="rdmonclick" target="_blank" rel="nofollow">
				<text>精品推荐</text>
			</a><a href="/aa/index.php/vod/type/id/3.html" name="rdmonclick" target="_blank" rel="nofollow">
				<text>国产精品</text>
			</a><a href="/aa/index.php/vod/type/id/1.html">更多</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "2");
        assert_eq!(list[1]["name"], "国产精品");
    }

    #[test]
    fn fallback_has_72_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 72);
        assert_eq!(list[0]["id"], "2");
        assert_eq!(list[71]["id"], "42");
        assert_eq!(list[71]["name"], "女同性恋");
    }

    #[test]
    fn parse_player_aaaa_real_markup() {
        let html = r#"var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/aa\/index.php\/vod\/play\/id\/108656\/sid\/1\/nid\/1.html","link_next":"","link_pre":"","vod_data":{"vod_name":"模特自拍泄密土豪重金约啪","vod_actor":"","vod_director":"","vod_class":"Cosplay"},"url":"https://2605.senlin2026.com/20260524/tcGih4LP/index.m3u8","url_next":"","from":"slm3u8","server":"no","note":"","id":108656,"sid":1,"nid":1};"#;
        let player = parse_player_aaaa(html).expect("player_aaaa");
        assert_eq!(
            player["url"],
            "https://2605.senlin2026.com/20260524/tcGih4LP/index.m3u8"
        );
        assert_eq!(player["vod_data"]["vod_name"], "模特自拍泄密土豪重金约啪");
        assert_eq!(player["vod_data"]["vod_class"], "Cosplay");
        assert_eq!(player["trysee"], 0);
        assert!(parse_player_aaaa("<div>no player</div>").is_none());
    }

    #[test]
    fn play_page_url_forms() {
        assert_eq!(
            play_page_url("108656"),
            "https://www.jiuseai.top/aa/index.php/vod/play/id/108656/sid/1/nid/1.html"
        );
        assert_eq!(
            play_page_url("/aa/index.php/vod/play/id/108656/sid/1/nid/1.html"),
            "https://www.jiuseai.top/aa/index.php/vod/play/id/108656/sid/1/nid/1.html"
        );
        assert_eq!(
            play_page_url(
                "https://www.jiuseai.top/aa/index.php/vod/play/id/108656/sid/1/nid/1.html"
            ),
            "https://www.jiuseai.top/aa/index.php/vod/play/id/108656/sid/1/nid/1.html"
        );
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(
            format!("{BASE}/index.php/vod/type/id/{}.html", "2"),
            "https://www.jiuseai.top/aa/index.php/vod/type/id/2.html"
        );
        assert_eq!(
            format!("{BASE}/index.php/vod/type/id/{}/page/{}.html", "2", 2),
            "https://www.jiuseai.top/aa/index.php/vod/type/id/2/page/2.html"
        );
    }
}
