//! 免费AI短剧：核心里的影视区站点。
//!
//! 本站是一条跳转链，不是固定域名：阅女阁给的是友链跳转页
//! go.html（from=yuenvge）→ 调 tiaoapi.php?action=batch（yl_from=yuenvge
//! 钉住星空中文影院，3 次实测站名稳定，域名只换随机子域标签）→
//! 随机子域落地页是 xk_gate 门（页内嵌有时效 token，点“点击立即进入”
//! 后以 Cookie xk_gate=<token> 再请求才放行）→ 真站星空中文影院。
//! 故模块每次调用都先跑这条链解析出当次可用域名与门票，不写死域名。
//!
//! 真站与导航 1:1（视频 50 项，data-flag="vod" 区块；另有小说/图片
//! 8 项 data-flag="art"，不是视频，不进本模块）：国产、自拍、AI短剧、
//! 三观尽毁、无码、有码、中字、欧美、动漫、三级片……每页 16 条；
//! 卡片 /s/<id>.html，封面为 background-image；详情页 /s/<id>.html，
//! 播放链 /s-p/<id>-1-1.html，取流为 player_data 的 m3u8（主清单 200、
//! 变体清单 1500kb 200、1049 分片、首分片 Range 206、METHOD=NONE、
//! 首字节 0x47）；trysee=0、points=0，全站免费无 VIP 墙；
//! 搜索 GET /sou/-.html?wd=。AI短剧分类（/t/60）实测有 16 条在架。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

/// 跳转接口：任意子域标签均可（通配解析），yl_from=yuenvge 钉住星空中文影院。
const API: &str = "https://abcdefgh.xingkongtuieee.cc/tiaoapi.php?action=batch&yl_from=yuenvge";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与真站视频导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("1", "国产"),
    ("6", "自拍"),
    ("60", "AI短剧"),
    ("7", "三观尽毁"),
    ("24", "无码"),
    ("50", "有码"),
    ("25", "中字"),
    ("26", "欧美"),
    ("27", "动漫"),
    ("28", "三级片"),
    ("10", "反差婊"),
    ("11", "网爆门"),
    ("29", "AV解说"),
    ("9", "传媒"),
    ("8", "迷奸强奸"),
    ("12", "偷拍"),
    ("30", "兄妹"),
    ("31", "母子"),
    ("32", "小姨"),
    ("33", "嫂子"),
    ("34", "野外"),
    ("35", "换妻"),
    ("36", "儿媳"),
    ("37", "下海"),
    ("2", "网红"),
    ("15", "学生妹"),
    ("3", "萝莉"),
    ("51", "黑料"),
    ("13", "福利姬"),
    ("14", "吃瓜"),
    ("16", "人兽"),
    ("5", "探花"),
    ("38", "瑜伽裤"),
    ("52", "技师"),
    ("53", "绿帽"),
    ("54", "丝足"),
    ("55", "偷情"),
    ("56", "校园"),
    ("57", "撸管"),
    ("4", "大秀"),
    ("58", "制服"),
    ("39", "兽耳系列"),
    ("20", "喷水"),
    ("40", "多人群P"),
    ("23", "AI换脸"),
    ("22", "性虐"),
    ("17", "人妖"),
    ("41", "Cosplay"),
    ("18", "OnlyFans"),
    ("59", "黑巨炮"),
];

/// 当次可用站：域名 + 门票 Cookie（形如 xk_gate=<token>），每次调用现解析。
struct Site {
    base: String,
    cookie: Option<String>,
}

async fn fetch(url: &str, cookie: Option<&str>) -> ApiResult<String> {
    let mut req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", url);
    if let Some(c) = cookie {
        req = req.header("Cookie", format!("xk_gate={c}"));
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("免费AI短剧请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("免费AI短剧返回空体".into()));
    }
    Ok(text)
}

/// 门票提取：落地页 `var token='...';`（时效 token，每次现取，不写死）。
fn parse_token(html: &str) -> Option<String> {
    let re = Regex::new(r"var token='([^']+)'").ok()?;
    re.captures(html).map(|m| m[1].to_string())
}

fn is_gate(html: &str) -> bool {
    html.contains("var token='") || html.contains("xk_gate")
}

/// 解析当次可用站：调 batch 接口取域名 → 取落地页 → 有门则取票。
async fn resolve_site() -> ApiResult<Site> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match resolve_once().await {
            Ok(site) => return Ok(site),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn resolve_once() -> ApiResult<Site> {
    let body = fetch(API, None).await?;
    let v: Value = serde_json::from_str(&body).map_err(|e| ApiError::Internal(e.to_string()))?;
    let base = v["domains"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|d| d.as_str())
        .unwrap_or_default()
        .trim_end_matches('/')
        .to_string();
    if base.is_empty() || !base.starts_with("http") {
        return Err(ApiError::Internal("免费AI短剧未解析到可用域名".into()));
    }
    let home_url = format!("{base}/?yl_from=yuenvge");
    let home = fetch(&home_url, None).await?;
    if is_gate(&home) {
        let token =
            parse_token(&home).ok_or_else(|| ApiError::Internal("免费AI短剧门票未取到".into()))?;
        Ok(Site {
            base,
            cookie: Some(token),
        })
    } else {
        Ok(Site { base, cookie: None })
    }
}

/// 带门票的 GET：先按解析到的站与票取一次；若回的是门页则重取票再试一次。
///
/// 2026-11-07：目录取数实测单次请求常在 20 秒超时附近抖动（随机子域
/// 首连慢），一次失败就判死站；与其他站的 get_text 同款，最多试 3 次。
async fn get_text(site: &Site, url: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch(url, site.cookie.as_deref()).await {
            Ok(text) => {
                if is_gate(&text) {
                    if let Some(token) = parse_token(&text) {
                        match fetch(url, Some(&token)).await {
                            Ok(text) => return Ok(text),
                            Err(e) => last_err = e.to_string(),
                        }
                    } else {
                        return Err(ApiError::Internal("免费AI短剧被拦在门外".into()));
                    }
                } else {
                    return Ok(text);
                }
            }
            Err(e) => last_err = e.to_string(),
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Err(ApiError::Internal(last_err))
}

/// 地址归一：协议相对补 https，站内相对路径补当次基址。
fn fix_url(base: &str, raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{base}{u}");
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

/// 卡片解析：首页 `<a class="pic" …>`、分类页 `<a class="vpic" …>`，
/// 均为 href="/s/<id>.html" + title + background-image 封面；按 id 去重。
fn parse_cards(base: &str, html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a class="(?:pic|vpic)" href="/s/(\d+)\.html" title="([^"]+)" style="background-image:url\(([^)]+)\)""#,
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
        let cover = fix_url(base, &cap[3]);
        items.push(item_json(&id, &title, &cover, ""));
    }
    items
}

/// 分类解析：首页 `<div class="nav nav-cats" data-flag="vod">` 区块内
/// 的 /t/<id>.html 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let block = match Regex::new(r#"(?s)<div class="nav nav-cats" data-flag="vod">(.*?)</div>"#) {
        Ok(re) => re
            .captures(html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        Err(_) => String::new(),
    };
    let scope: &str = if block.is_empty() { html } else { &block };
    let re = match Regex::new(r#"href="/t/(\d+)\.html"[^>]*>([^<]+)<"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(scope) {
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
    let site = resolve_site().await?;
    match get_text(&site, &format!("{}/", site.base)).await {
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

fn catalog_url(base: &str, category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{base}/t/{category_id}.html")
    } else {
        format!("{base}/t/{category_id}-{page}.html")
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let site = resolve_site().await?;
    let html = get_text(&site, &catalog_url(&site.base, category_id, page)).await?;
    let items = parse_cards(&site.base, &html);
    let has_more = if items.is_empty() {
        false
    } else {
        html.contains(&format!("/t/{category_id}-{}.html", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 播放器 JSON：播放页 `var player_data={...}</script>`。
fn parse_player(html: &str) -> Option<Value> {
    let re = Regex::new(r"(?s)var player_data=(\{.*?\})\s*</script>").ok()?;
    let cap = re.captures(html)?;
    serde_json::from_str(&cap[1]).ok()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let site = resolve_site().await?;
    let id = series_id.trim().trim_start_matches('/');
    let id = id.strip_prefix("s/").unwrap_or(id);
    let id = id.trim_end_matches(".html");
    let id = id.split('/').next().unwrap_or(id);
    let url = format!("{}/s/{id}.html", site.base);
    let html = get_text(&site, &url).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let mut title = match &h1_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        let t_re = Regex::new(r"<title>(.*?)</title>").ok();
        if let Some(re) = t_re {
            if let Some(cap) = re.captures(&html) {
                title = unescape(cap[1].trim());
                if let Some(stripped) = title.strip_suffix("_星空中文影院") {
                    title = stripped.to_string();
                }
            }
        }
    }
    let cover_re = Regex::new(r"background-image:url\(([^)]+)\)").ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&site.base, &m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let genre_re = Regex::new(r#"href="/t/(\d+)\.html">([^<]+)<"#).ok();
    let genre = match &genre_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[2].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let play_re = Regex::new(r#"href="(/s-p/\d+-1-1\.html)""#).ok();
    let play_path = match &play_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() || play_path.is_empty() {
        return Err(ApiError::Internal("免费AI短剧详情未返回播放链".into()));
    }
    let play_html = get_text(&site, &format!("{}{play_path}", site.base)).await?;
    let player = parse_player(&play_html)
        .ok_or_else(|| ApiError::Internal("免费AI短剧未返回播放器数据".into()))?;
    let m3u8 = text_of(&player, &["url"]);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("免费AI短剧未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"genre": genre},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("免费AI短剧该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let site = resolve_site().await?;
    let url = with_query(&format!("{}/sou/-.html", site.base), &[("wd", query)]);
    let html = get_text(&site, &url).await?;
    let items = parse_cards(&site.base, &html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        let base = "https://jy3d5ktz.tiannbingtjw1.sbs";
        assert_eq!(
            fix_url(base, "/upload/vod/20261104-1/d0bc7de4fe19a2e325fbea0798b1339b.webp"),
            "https://jy3d5ktz.tiannbingtjw1.sbs/upload/vod/20261104-1/d0bc7de4fe19a2e325fbea0798b1339b.webp"
        );
        assert_eq!(
            fix_url(base, "https://lsbbf11.com/20261102/MeF2wFlb/index.m3u8"),
            "https://lsbbf11.com/20261102/MeF2wFlb/index.m3u8"
        );
        assert_eq!(fix_url(base, "//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(base, ""), "");
    }

    #[test]
    fn parse_cards_real_markup() {
        let base = "https://jy3d5ktz.tiannbingtjw1.sbs";
        let html = r#"<div class="card"><a class="pic" href="/s/363910.html" title="秦总会所探花最近妹子质量稳步提高会所小杨幂高跟美.腿风情万种女神相伴呼声很高下次还操她" style="background-image:url(/upload/vod/20261104-1/d0bc7de4fe19a2e325fbea0798b1339b.webp)"><span class="badge-score">5.0</span><span class="badge">探花</span></a></div><div class="vcard"><a class="vpic" href="/s/363622.html" title="AI短剧.高三爱情故事-35-侦探篇1" style="background-image:url(/upload/vod/20261104-1/dac6e20a8c2ae29e7f18fb0988764a56.webp)"><span class="badge-score">3.0</span><span class="badge">高清</span></a></div>"#;
        let items = parse_cards(base, html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "363910");
        assert_eq!(
            items[0]["title"],
            "秦总会所探花最近妹子质量稳步提高会所小杨幂高跟美.腿风情万种女神相伴呼声很高下次还操她"
        );
        assert_eq!(
            items[0]["cover"],
            "https://jy3d5ktz.tiannbingtjw1.sbs/upload/vod/20261104-1/d0bc7de4fe19a2e325fbea0798b1339b.webp"
        );
        assert_eq!(items[1]["id"], "363622");
        assert_eq!(items[1]["title"], "AI短剧.高三爱情故事-35-侦探篇1");
    }

    #[test]
    fn parse_categories_vod_block() {
        let html = r#"<div class="nav nav-cats" data-flag="vod"><a href="/t/1.html" data-tid="1">国产</a><a href="/t/6.html" data-tid="6">自拍</a><a href="/t/60.html" data-tid="60">AI短剧</a><a href="/t/7.html" data-tid="7">三观尽毁</a></div><div class="nav nav-cats" data-flag="art"><a href="/a/42.html">都市小说</a></div>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "1");
        assert_eq!(list[2]["id"], "60");
        assert_eq!(list[2]["name"], "AI短剧");
        assert_eq!(list[3]["name"], "三观尽毁");
    }

    #[test]
    fn fallback_has_50_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 50);
        assert_eq!(list[0]["name"], "国产");
        assert_eq!(list[2]["id"], "60");
        assert_eq!(list[2]["name"], "AI短剧");
        assert_eq!(list[49]["name"], "黑巨炮");
    }

    #[test]
    fn parse_player_real_markup() {
        let html = r#"<div class="player"><script type="text/javascript">var player_data={"flag":"play","encrypt":0,"trysee":0,"points":0,"link":"\/s-p\/363910-1-1.html","link_next":"","link_pre":"","url":"https:\/\/lsbbf11.com\/20261102\/MeF2wFlb\/index.m3u8","url_next":"","from":"ytm3u8","server":"no","note":""}</script><script type="text/javascript" src="/static/js/playerconfig.js"></script></div>"#;
        let player = parse_player(html).expect("player json");
        assert_eq!(
            text_of(&player, &["url"]),
            "https://lsbbf11.com/20261102/MeF2wFlb/index.m3u8"
        );
        assert_eq!(player["trysee"].as_i64(), Some(0));
        assert_eq!(player["points"].as_i64(), Some(0));
        assert!(parse_player("<div>no player</div>").is_none());
    }

    #[test]
    fn parse_token_shape() {
        let html = "var token='1794498927.abcdef0123456789';";
        let token = parse_token(html).expect("token");
        assert!(token.starts_with("1794498927."));
        assert!(is_gate(html));
        assert!(!is_gate("<div>real site</div>"));
        assert!(parse_token("<div>no token</div>").is_none());
    }

    #[test]
    fn catalog_url_shapes() {
        let base = "https://jy3d5ktz.tiannbingtjw1.sbs";
        assert_eq!(
            catalog_url(base, "1", 1),
            "https://jy3d5ktz.tiannbingtjw1.sbs/t/1.html"
        );
        assert_eq!(
            catalog_url(base, "60", 2),
            "https://jy3d5ktz.tiannbingtjw1.sbs/t/60-2.html"
        );
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://lsbbf11.com/20261102/MeF2wFlb/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://lsbbf11.com/20261102/MeF2wFlb/index.m3u8"
        );
        assert!(play_check("363910").is_err());
    }
    #[tokio::test]
    #[ignore]
    async fn live_avjieshuo_catalog() {
        let start = std::time::Instant::now();
        let r = catalog("29", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        eprintln!(
            "LIVE mianfeiai av解说 cat=29 items={} elapsed={:?}",
            items.len(),
            start.elapsed()
        );
        assert!(!items.is_empty(), "mianfeiai AV解说 catalog empty");
    }
}
