//! SWAG资源合集下载-R站：核心里的影视区站点。
//!
//! 站点结构（实测于 2026-11-05，均为 http 直连可达）：
//! - 首页 `/?a=11&t=sys` 有 热门/最新/推荐 三个视频 tab（各 12 条），
//!   分类页 `/category` 是主播索引（60 位主播，每位一位分类）；
//! - 主播页 `/category/{id}?page={N}` 每页 24 条，laypage 分页
//!   `var page_total`；详情页 `/category/{cat}/{vid}`；
//! - 搜索 GET `/search?content={词}`；
//! - 免费能播的只有详情页 `<video>` 里的 10 秒预告片
//!   `trailer.ripic.xyz/{hash}/trailer.mp4?preset=clear-10s`；
//! - 全片无在线播放器：在线播放按钮指向 `/user/vip`，JS 明写
//!   “在线播放功能仅对永久会员开放”；下载链接走
//!   `POST /ajax/get_down_url`，匿名调用回
//!   `{"code":500,"msg":"请登录后再操作！"}`，须登录后才给，
//!   故本模块只出预告片，VIP 墙如实报，不写任何绕 VIP 的路子。
//! - 导航里的 福利姬/录播区/其他精品 指向站外 jijiji.xyz，
//!   本机出口与浏览器线均够不着，本站也无直播流，故不含直播。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "http://zi.ri511.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 首页三个视频 tab（静态 id，顺序与站内 tab-hd 一致）。
const TABS: &[(&str, &str)] = &[("hot", "热门"), ("latest", "最新"), ("rec", "推荐")];

/// 分类页取不到时的主播回退：首页露出的 18 位主播（id 与站内一致）。
const FALLBACK_STREAMERS: &[(&str, &str)] = &[
    ("135", "琳琳"),
    ("123", "小媛"),
    ("32", "愛子"),
    ("167", "吴夢夢"),
    ("194", "princessdolly"),
    ("107", "灣灣"),
    ("52", "chinh"),
    ("161", "Mio"),
    ("169", "沐沐"),
    ("85", "菲菲"),
    ("46", "candybaby"),
    ("89", "funnyg"),
    ("3", "貝拉"),
    ("241", "aprillady"),
    ("149", "芊芊"),
    ("132", "黎兒"),
    ("239", "娃娃"),
    ("160", "minicat"),
];

/// 带重试的 GET：站间歇性超时，最多试 3 次，每次间隔 1 秒。
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
        .header("Referer", BASE)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("SWAG合集请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.trim().is_empty() {
        return Err(ApiError::Internal("SWAG合集返回空响应".into()));
    }
    Ok(text)
}

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

/// 标题：img alt 形如 `{主播}-swag-{标题}`，去前缀；无前缀时原样用。
fn title_from_alt(alt: &str) -> String {
    let t = unescape(alt.trim());
    if let Some(pos) = t.find("-swag-") {
        let rest = &t[pos + 6..];
        if !rest.trim().is_empty() {
            return rest.trim().to_string();
        }
    }
    t
}

/// 卡片解析：`<a href="/category/{cat}/{vid}">` + img alt（标题）
/// + data-src（封面）+ 播放量/时长（fa-unlock / fa-clock-o 后）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(
        r#"(?s)<a href="/category/(\d+)/(\d+)">.*?<img[^>]*alt="([^"]*)"[^>]*data-src="([^"]+)""#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let views_re = Regex::new(r#"fa-unlock"></i>\s*([^<\s]+)"#).ok();
    let dur_re = Regex::new(r#"fa-clock-o"></i>\s*([^<\s]+)"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let cat = cap[1].to_string();
        let vid = cap[2].to_string();
        let key = format!("{cat}/{vid}");
        if !seen.insert(key.clone()) {
            continue;
        }
        let title = title_from_alt(&cap[3]);
        if title.is_empty() {
            continue;
        }
        let cover = fix_url(&cap[4]);
        let tail = &html[cap.get(0).unwrap().end()..];
        let tail = &tail[..tail.len().min(800)];
        let remark = match &dur_re {
            Some(re) => re
                .captures(tail)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let _ = views_re.as_ref();
        items.push(item_json(&key, &title, &cover, &remark));
    }
    items
}

/// 首页 tab-bd：`<dl class="tab-bd">` 下的 <dd> 按顺序是 热门/最新/推荐/板块。
fn tab_sections(html: &str) -> Vec<String> {
    let dl_re = match Regex::new(r#"(?s)<dl class="tab-bd">(.*?)</dl>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let Some(dl) = dl_re.captures(html).map(|m| m[1].to_string()) else {
        return Vec::new();
    };
    let dd_re = match Regex::new(r"(?s)<dd[^>]*>(.*?)</dd>") {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    dd_re.captures_iter(&dl).map(|m| m[1].to_string()).collect()
}

/// 主播解析：分类页 `<a href="/category/{id}">{名字}</a>`，按站内顺序、id 去重。
fn parse_streamers(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"<a href="/category/(\d+)">([^<]{1,30})</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut list = Vec::new();
    for cap in re.captures_iter(html) {
        let id = cap[1].to_string();
        let name = unescape(cap[2].trim());
        if name.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        list.push(category_json(&format!("s{id}"), &name));
    }
    list
}

fn fallback_categories() -> Value {
    let mut list: Vec<Value> = TABS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    for (id, name) in FALLBACK_STREAMERS {
        list.push(category_json(&format!("s{id}"), name));
    }
    json!({"categories": list})
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = TABS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    match get_text(&format!("{BASE}/category")).await {
        Ok(html) => {
            let streamers = parse_streamers(&html);
            if streamers.is_empty() {
                return Ok(fallback_categories());
            }
            list.extend(streamers);
            Ok(json!({"categories": list}))
        }
        Err(_) => Ok(fallback_categories()),
    }
}

fn tab_index(category_id: &str) -> Option<usize> {
    TABS.iter().position(|(id, _)| *id == category_id)
}

/// 分页总数：主播页 laypage `var page_total =N;`。
fn page_total(html: &str) -> Option<i64> {
    let re = Regex::new(r"page_total\s*=\s*(\d+)").ok()?;
    re.captures(html).and_then(|m| m[1].parse::<i64>().ok())
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if let Some(idx) = tab_index(category_id) {
        let html = get_text(&format!("{BASE}/?a=11&t=sys")).await?;
        let sections = tab_sections(&html);
        let items = sections
            .get(idx)
            .map(|s| parse_cards(s))
            .unwrap_or_default();
        return Ok(json!({"items": items, "has_more": false}));
    }
    let Some(sid) = category_id.strip_prefix('s') else {
        return Err(ApiError::BadRequest(format!(
            "SWAG合集未知分类 {category_id}"
        )));
    };
    let url = if page <= 1 {
        format!("{BASE}/category/{sid}")
    } else {
        format!("{BASE}/category/{sid}?page={page}")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html) {
        page < total
    } else {
        items.len() >= 24
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 预告片：详情页 `<video ... src="...trailer.mp4...">`。
fn parse_trailer(html: &str) -> String {
    let re = match Regex::new(r#"(?s)<video[^>]*src="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|m| unescape(&m[1]))
        .unwrap_or_default()
}

/// 详情字段：标题 `<div class="online-title">`，封面 video poster，
/// 播放量 `[\d.]+[wk]`，时长 `N分N秒`，简介取详情区 <p> 纯文本，
/// 主播 `<h3 class="f-18">名字 / slug</h3>`。
fn parse_detail_fields(html: &str) -> (String, String, String, String, String, String) {
    let title_re = Regex::new(r#"(?s)<div class="online-title">\s*(.*?)\s*</div>"#).ok();
    let title = match &title_re {
        Some(re) => re
            .captures(html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let poster_re = Regex::new(r#"(?s)<video[^>]*poster="([^"]+)""#).ok();
    let cover = match &poster_re {
        Some(re) => re
            .captures(html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let views_re = Regex::new(r"(\d[\d.]*[wk])").ok();
    let views = match &views_re {
        Some(re) => re
            .captures(html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let dur_re = Regex::new(r"(\d+分\d+秒)").ok();
    let duration = match &dur_re {
        Some(re) => re
            .captures(html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    let p_re = Regex::new(r"(?s)<p[^>]*>([^<]{6,200})</p>").ok();
    let mut synopsis = String::new();
    if let Some(re) = &p_re {
        let mut parts: Vec<String> = Vec::new();
        for cap in re.captures_iter(html) {
            let t = unescape(cap[1].trim());
            if t.contains("下载")
                || t.contains("会员")
                || t.contains("VIP")
                || t.contains("百度")
                || t.contains("解压")
                || t.contains("提取")
                || t.contains("存储")
            {
                continue;
            }
            if !parts.contains(&t) {
                parts.push(t);
            }
            if parts.len() >= 5 {
                break;
            }
        }
        synopsis = parts.join(" ");
    }
    let actor_re = Regex::new(r#"<h3 class="f-18">([^<]+?)\s*/"#).ok();
    let actor = match &actor_re {
        Some(re) => re
            .captures(html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    (title, cover, views, duration, synopsis, actor)
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/category/{series_id}");
    let html = get_text(&url).await?;
    let trailer = parse_trailer(&html);
    let (title, cover, views, duration, synopsis, actor) = parse_detail_fields(&html);
    if title.is_empty() || trailer.is_empty() {
        return Err(ApiError::Internal("SWAG合集未返回预告片地址".into()));
    }
    let remark = if views.is_empty() {
        duration.clone()
    } else if duration.is_empty() {
        views.clone()
    } else {
        format!("{views} {duration}")
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"remark": remark, "actor": actor},
        "episodes": [episode_json(&trailer, "预告片", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("SWAG合集该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("content", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD_HTML: &str = r#"<li class="col-25 col-m-12 mb15"><div class="img-item mb5"><a href="/category/135/953"><span class="img-box" data-ratio="16:9"><img class="lazyload" alt="linlinbebe-swag-swag最淫亂女大生國王遊戲10p全輯" data-src="https://webp.ripic.xyz/5da85a2c0a8ba5be25dbb161.512x512.jpg?preset=clear"/></span><h3 class="f-12 txt-ov"><span class="mr10"><i class="fa fa-unlock"></i> 4.1w</span><span class="mr10"><i class="fa fa-clock-o"></i> 00:40:01</span></h3></a><a class="img-ico" href="/category/135">琳琳</a></div><p class="f-14 txt-ov ta-c">swag最淫亂女大生國王遊戲10p全輯</p></li><li class="col-25 col-m-12 mb15"><div class="img-item mb5"><a href="/category/135/953"><span class="img-box"><img class="lazyload" alt="重复卡片" data-src="https://webp.ripic.xyz/x.jpg"/></span></a></div></li>"#;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("/blog/19tv/img/logo.png"),
            "http://zi.ri511.xyz/blog/19tv/img/logo.png"
        );
        assert_eq!(
            fix_url(
                "https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s"
            ),
            "https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn title_from_alt_strips_prefix() {
        assert_eq!(
            title_from_alt("linlinbebe-swag-swag最淫亂女大生國王遊戲10p全輯"),
            "swag最淫亂女大生國王遊戲10p全輯"
        );
        assert_eq!(title_from_alt("plain title"), "plain title");
    }

    #[test]
    fn parse_cards_real_markup() {
        let items = parse_cards(CARD_HTML);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "135/953");
        assert_eq!(items[0]["title"], "swag最淫亂女大生國王遊戲10p全輯");
        assert_eq!(
            items[0]["cover"],
            "https://webp.ripic.xyz/5da85a2c0a8ba5be25dbb161.512x512.jpg?preset=clear"
        );
        assert_eq!(items[0]["remark"], "00:40:01");
    }

    #[test]
    fn parse_streamers_dedup() {
        let html = r#"<a href="/category/135">琳琳</a><a href="/category/123">小媛</a><a href="/category/135">琳琳</a><a href="/category/32">愛子</a>"#;
        let list = parse_streamers(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "s135");
        assert_eq!(list[2]["name"], "愛子");
    }

    #[test]
    fn fallback_has_tabs_and_streamers() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 3 + FALLBACK_STREAMERS.len());
        assert_eq!(list[0]["id"], "hot");
        assert_eq!(list[2]["name"], "推荐");
        assert_eq!(list[3]["id"], "s135");
    }

    #[test]
    fn tab_sections_split_in_order() {
        let html = r#"<dl class="tab-bd"><dd><ul><li><a href="/category/135/953"><img alt="linlinbebe-swag-片名A" data-src="https://webp.ripic.xyz/a.jpg"/></a></li></ul></dd><dd><ul><li><a href="/category/455/4580"><img alt="x-swag-片名B" data-src="https://webp.ripic.xyz/b.jpg"/></a></li></ul></dd><dd><ul><li><a href="/category/55/296"><img alt="y-swag-片名C" data-src="https://webp.ripic.xyz/c.jpg"/></a></li></ul></dd><dd></dd></dl>"#;
        let sections = tab_sections(html);
        assert_eq!(sections.len(), 4);
        assert!(sections[0].contains("/category/135/953"));
        assert!(sections[1].contains("/category/455/4580"));
        assert!(sections[2].contains("/category/55/296"));
        assert_eq!(parse_cards(&sections[1]).len(), 1);
        assert_eq!(parse_cards(&sections[1])[0]["title"], "片名B");
    }

    #[test]
    fn parse_trailer_real_markup() {
        let html = r#"<video id="video" loop muted playsinline poster="https://webp.ripic.xyz/5da85a2c0a8ba5be25dbb161.512x512.jpg?preset=clear" src="https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s"></video>"#;
        assert_eq!(
            parse_trailer(html),
            "https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s"
        );
        assert_eq!(parse_trailer("<div>no video</div>"), "");
    }

    #[test]
    fn page_total_reads_laypage_var() {
        let html = "var page=1; var page_total =3; if(Number(page_total)>1){";
        assert_eq!(page_total(html), Some(3));
        assert_eq!(page_total("<div>no pager</div>"), None);
    }

    #[test]
    fn detail_fields_real_markup() {
        let html = r#"<div class="online-title">swag最淫亂女大生國王遊戲10p全輯</div><span>4.1w</span><span>40分1秒</span><video poster="https://webp.ripic.xyz/5da85a2c0a8ba5be25dbb161.512x512.jpg?preset=clear" src="https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s"></video><h3 class="f-18">琳琳 / linlinbebe</h3><p>長片內容誠意獻上40分鐘</p><p>最多鹹濕的逞罰遊戲讓你一次滿足</p>"#;
        let (title, cover, views, duration, synopsis, actor) = parse_detail_fields(html);
        assert_eq!(title, "swag最淫亂女大生國王遊戲10p全輯");
        assert_eq!(
            cover,
            "https://webp.ripic.xyz/5da85a2c0a8ba5be25dbb161.512x512.jpg?preset=clear"
        );
        assert_eq!(views, "4.1w");
        assert_eq!(duration, "40分1秒");
        assert!(synopsis.contains("長片內容誠意獻上40分鐘"));
        assert_eq!(actor, "琳琳");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check(
            "https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s",
        )
        .unwrap();
        assert_eq!(
            ok["url"],
            "https://trailer.ripic.xyz/5da85a2c0a8ba5be25dbb161/trailer.mp4?preset=clear-10s"
        );
        assert!(play_check("135/953").is_err());
    }
}
