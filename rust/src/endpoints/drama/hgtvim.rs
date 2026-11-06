//! 🔞黄果短剧HGTV：hgtv.im，独立站，不与黄果TV短剧 huangguotv、
//! 黄果短剧 hgdj、黄果短剧V hgdjv、新黄果短剧 aimove、黄果
//! huangguo 合并。
//!
//! 去重实测（2026-11-06）：本站为 theme4 模板站（卡片
//! `<article class="card">`，详情 /drama/<id>.html，观看页
//! /watch/<id>_<ep>.html，分类 /category/<n>.html，翻页
//! /category/<n>-p<p>.html，首页翻页 /page/<p>.html，搜索
//! /search/<词>.html）；huangguotv.com 是 SSR 站
//! （seo-fallback-card 卡片，详情 /video/<id>，封面与流走
//! media.huangguotv.com）；同部剧《重生之征服郭伯母》本站
//! /drama/32.html 全 21 集、封面 img.mfantasy.net，对方
//! /video/221611 仅 5 集、封面 media.huangguotv.com；部数
//! 1449 vs 1341 也不一致（两站目录不同）。封面分两处：
//! 首页/详情走 img.mfantasy.net，分类列表走 img.689.mx。
//! 注意 key 取 hgtvim 而不用 hgtv：'hgtv' 已被旧站 HGTV（红果
//! App 客户端，fqnovel/hongguoduanju.com，Dart 侧 HgtvContentClient）
//! 占用，复用会撞 id 且 Dart 路由会把它当成红果客户端。
//! 取流（VIP 墙绕行，机制已实测、流字节未通）：第 1 集免费，
//! 第 2 集起观看页不渲染 video、只留“第1集免费，整部
//! ¥19.90 / 购买会员可免费观看本站所有短剧资源”；60 秒
//! 试看上限只在站内 player.js 里做（data-trail="60"，到点
//! pause + 弹 trailLock），流地址本身是观看页 video 的
//! data-src（/play/<id>_<ep>.html，data-kind="hls"），
//! hls.js 直接以它为清单源。play() 先取观看页拿 Laravel
//! 会话饼干（duanju_session + XSRF-TOKEN，无饼干时 /play/
//! 直接 403），再带饼干 + Referer 取 /play/ 地址：
//! 302 则跟到最终 m3u8，200 且正文为 #EXTM3U 时回 /play/
//! 地址 + 饼干头由播放器直取。注意：本机出口对 /play/
//! 全程无响应（curl/requests/http2 均 60～180 秒 0 字节，
//! 出口代理还会掐断长连接），流清单与全长未在本机验通，
//! 须手机侧实测。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, str_of, text_of};

const HOST: &str = "https://hgtv.im";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 24;

/// 14 个一级分类：首页 + /categories.html 的 13 个分类，站导航 1:1。
const CATS: &[(&str, &str)] = &[
    ("home", "首页"),
    ("3", "经典魔改"),
    ("10", "家庭伦理"),
    ("2", "都市爱情"),
    ("17", "特殊趣味"),
    ("11", "校园记忆"),
    ("1", "古装玄幻"),
    ("6", "现代惊悚"),
    ("13", "域外传奇"),
    ("4", "经典动漫"),
    ("5", "AI演示"),
    ("12", "特殊口味"),
    ("9", "异能穿越"),
    ("68", "二次元区"),
];

fn card_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"href="/drama/(\d+)\.html""#).unwrap())
}

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https?://[^\s"'<>]+\.m3u8"#).unwrap())
}

fn watch_link_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"href="/watch/(\d+)_(\d+)\.html""#).unwrap())
}

fn ep_num_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#""episodeNumber":(\d+)"#).unwrap())
}

async fn fetch(url: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "黄果短剧HGTV请求 HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn attr(block: &str, name: &str) -> String {
    let marker = format!("{name}=\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    block[s..]
        .find('"')
        .map(|e| block[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(block: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = block.find(&open) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

fn span_text(block: &str, class: &str) -> String {
    let marker = format!("class=\"{class}\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
    strip_tags(&after[s..e])
}

/// 集数行：`<span class="count"><em>1天前</em> … <b>更新至10集</b></span>`，
/// 直接取 span 文本会被开头的 `<em>` 截断，改取里面的 `<b>`。
fn count_text(block: &str) -> String {
    let Some(p) = block.find("class=\"count\"") else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let rest = &after[s..];
    // 集数行里嵌着 <span class="split"></span>，按第一个 </span>
    // 截会丢掉后面的 <b>；按 poster 的 </div> 截才完整。
    let end = rest.find("</div>").unwrap_or(rest.len());
    let seg = &rest[..end];
    if let Some(b) = seg.find("<b>") {
        let s = b + 3;
        if let Some(e) = seg[s..].find("</b>") {
            return strip_tags(&seg[s..s + e]);
        }
    }
    strip_tags(seg)
}

fn abs_url(u: &str) -> String {
    let u = u.trim();
    if u.starts_with("https://") || u.starts_with("http://") {
        return u.to_string();
    }
    if u.starts_with("//") {
        return format!("https:{u}");
    }
    if u.starts_with('/') {
        return format!("{HOST}{u}");
    }
    format!("{HOST}/{u}")
}

/// `<article class="card">` 卡片解析：标题取 h3，封面取 img src，
/// 备注取评分 + 热度 + 集数（“9.0分 · 9501热度 · 更新至10集”）。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for block in html.split("<article class=\"card\"").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let Some(cap) = card_re().captures(block) else {
            continue;
        };
        let id = cap[1].to_string();
        let title = tag_text(block, "h3");
        if title.is_empty() {
            continue;
        }
        let cover = abs_url(&attr(block, "src"));
        let mut bits: Vec<String> = Vec::new();
        let score = span_text(block, "card-score");
        if !score.is_empty() {
            bits.push(score);
        }
        let heat = span_text(block, "heat");
        if !heat.is_empty() {
            bits.push(heat);
        }
        let count = count_text(block);
        if !count.is_empty() {
            bits.push(count);
        }
        items.push(item_json(&id, &title, &cover, &bits.join(" · ")));
    }
    items
}

/// 搜索页有两个 t4-list（匹配列表 + 猜你想看），只取第一个。
fn parse_search_cards(html: &str) -> Vec<Value> {
    let Some(p) = html.find("<div class=\"cards t4-list\">") else {
        return parse_cards(html);
    };
    let rest = &html[p..];
    let end = rest.find("<section").unwrap_or(rest.len());
    parse_cards(&rest[..end])
}

fn jld_str(html: &str, key: &str) -> String {
    let marker = format!("\"{key}\":\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    let mut out = String::new();
    let mut chars = html[s..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            }
            '"' => break,
            _ => out.push(c),
        }
    }
    out
}

fn og(html: &str, prop: &str) -> String {
    let marker = format!("property=\"{prop}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let Some(c) = after.find("content=\"") else {
        return String::new();
    };
    let s = c + 9;
    after[s..]
        .find('"')
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn meta_name(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let Some(c) = after.find("content=\"") else {
        return String::new();
    };
    let s = c + 9;
    after[s..]
        .find('"')
        .map(|e| after[s..s + e].to_string())
        .unwrap_or_default()
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let base = match category_id {
        "home" | "" => format!("{HOST}/index.html"),
        id => format!("{HOST}/category/{id}.html"),
    };
    if page <= 1 {
        return base;
    }
    match category_id {
        "home" | "" => format!("{HOST}/page/{page}.html"),
        id => format!("{HOST}/category/{id}-p{page}.html"),
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url).await?;
    let items = parse_cards(&html);
    let has_more = items.len() >= PAGE_SIZE as usize;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = format!("{HOST}/drama/{series_id}.html");
    let html = fetch(&url).await?;
    let mut title = jld_str(&html, "name");
    if title.is_empty() {
        title = og(&html, "og:title");
    }
    if let Some(p) = title.find(" - 黄果TV") {
        title = title[..p].to_string();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("黄果短剧HGTV未返回影片资料".into()));
    }
    let mut cover = jld_str(&html, "image");
    if cover.is_empty() {
        cover = og(&html, "og:image");
    }
    let mut desc = jld_str(&html, "description");
    if desc.is_empty() {
        desc = meta_name(&html, "description");
    }
    if desc.is_empty() {
        desc = og(&html, "og:description");
    }
    let genre = jld_str(&html, "genre");
    let mut eps: Vec<i64> = watch_link_re()
        .captures_iter(&html)
        .filter(|c| c.get(1).map(|m| m.as_str()) == Some(series_id))
        .filter_map(|c| c[2].parse::<i64>().ok())
        .collect();
    if eps.is_empty() {
        eps = ep_num_re()
            .captures_iter(&html)
            .filter_map(|c| c[1].parse::<i64>().ok())
            .collect();
    }
    eps.sort_unstable();
    eps.dedup();
    if eps.is_empty() {
        if let Some(p) = html.find("\"numberOfEpisodes\":") {
            let after = &html[p + 19..];
            let n: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(total) = n.parse::<i64>() {
                if total > 0 {
                    eps = (1..=total).collect();
                }
            }
        }
    }
    if eps.is_empty() {
        eps.push(1);
    }
    let mut episodes: Vec<Value> = Vec::new();
    for n in &eps {
        episodes.push(episode_json(
            &format!("{series_id}:{n}"),
            &format!("第{n}集"),
            series_id,
        ));
    }
    let remark = if genre.is_empty() {
        format!("共 {} 集", eps.len())
    } else {
        format!("{genre} · 共 {} 集", eps.len())
    };
    let mut extra = serde_json::Map::new();
    extra.insert("remark".to_string(), json!(remark));
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/{}.html",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url).await?;
    let items = parse_search_cards(&html);
    Ok(json!({"items": items}))
}

/// 观看页取会话饼干（duanju_session + XSRF-TOKEN）。
async fn watch_cookies(series_id: &str, ep: i64) -> ApiResult<(String, String)> {
    let watch_url = format!("{HOST}/watch/{series_id}_{ep}.html");
    let req = client()?
        .get(&watch_url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    let mut cookies: Vec<String> = Vec::new();
    for v in resp.headers().get_all("set-cookie").iter() {
        if let Ok(s) = v.to_str() {
            if let Some(pair) = s.split(';').next() {
                let pair = pair.trim();
                if !pair.is_empty() {
                    cookies.push(pair.to_string());
                }
            }
        }
    }
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "黄果短剧HGTV观看页 HTTP {status}"
        )));
    }
    let html = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let mut play_path = format!("/play/{series_id}_{ep}.html");
    if let Some(p) = html.find("data-src=\"") {
        let s = p + 10;
        if let Some(e) = html[s..].find('"') {
            let v = &html[s..s + e];
            if !v.is_empty() {
                play_path = v.to_string();
            }
        }
    }
    Ok((play_path, cookies.join("; ")))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") || video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let (series_id, ep) = match video_id.split_once(':') {
        Some((s, e)) => (s.to_string(), e.parse::<i64>().unwrap_or(1)),
        None => (video_id.to_string(), 1),
    };
    let (play_path, cookies) = watch_cookies(&series_id, ep).await?;
    let play_url = abs_url(&play_path);
    let watch_url = format!("{HOST}/watch/{series_id}_{ep}.html");
    let req = client()?
        .get(&play_url)
        .header("User-Agent", UA)
        .header("Accept", "application/vnd.apple.mpegurl, */*")
        .header("Referer", &watch_url)
        .header("Cookie", &cookies);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let final_url = resp.url().to_string();
    let status = resp.status().as_u16();
    if status == 403 || status == 401 {
        return Err(ApiError::Internal(
            "黄果短剧HGTV播放地址需登录或购买后观看".into(),
        ));
    }
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "黄果短剧HGTV播放请求 HTTP {status}"
        )));
    }
    // 302 跟到的最终地址是 m3u8 时直接回它；否则回 /play/ 地址 +
    // 会话饼干，由播放器直取（清单本身即全长，60 秒上限只在
    // 站内 JS 里做）。
    if final_url != play_url && (final_url.contains(".m3u8") || final_url.contains(".mp4")) {
        return Ok(json!({
            "url": final_url,
            "header": {"User-Agent": UA, "Referer": watch_url},
        }));
    }
    let body = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if body.trim_start().starts_with("#EXTM3U") {
        return Ok(json!({
            "url": play_url,
            "header": {"User-Agent": UA, "Referer": watch_url, "Cookie": cookies},
        }));
    }
    if let Some(cap) = m3u8_re().captures(&body) {
        let url = cap.get(0).map(|m| m.as_str()).unwrap_or("").to_string();
        if !url.is_empty() {
            return Ok(json!({
                "url": url,
                "header": {"User-Agent": UA, "Referer": watch_url},
            }));
        }
    }
    Ok(json!({
        "url": play_url,
        "header": {"User-Agent": UA, "Referer": watch_url, "Cookie": cookies},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD_HTML: &str = r#"<div class="cards t4-list"><article class="card"><a href="/drama/1484.html"><div class="poster"><img src="https://img.689.mx/i/2026/11/05/6aeb6d1cc0b15.jpg" alt="大吊姐驾到，统统闪开" loading="lazy" decoding="async"><div class="marks"><span class="shelf-new">新上架</span> <span class="heat">9501热度</span></div><span class="card-score">9.0分</span><span class="count"><em>1天前</em> <span class="split"></span> <b>更新至10集</b></span></div><h3>大吊姐驾到，统统闪开</h3><p class="intro">夏宁意外身体异变。</p></a></article><article class="card"><a href="/drama/45.html"><div class="poster"><img src="https://img.mfantasy.net/siteinfo/965f8c7a437c73aec6919c33a10c3191.webp" alt="少妇白洁" loading="lazy" decoding="async"><div class="marks"><span class="heat">2万热度</span></div><span class="card-score">10.0分</span><span class="count"><b>全30集</b></span></div><h3>少妇白洁</h3><p class="intro">关于欲望、人性、婚姻与背叛。</p></a></article></div>"#;

    const DETAIL_HTML: &str = r#"<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"TVSeries","name":"重生之征服郭伯母","description":"杨过重生归来，誓要改写命令，她浴火重生，他步步沦陷！","image":"https://img.mfantasy.net/siteinfo/1543a85c90ef2bacd963ba6fdb05c53d.webp","genre":"经典魔改","numberOfEpisodes":21,"url":"https://hgtv.im/drama/32.html","episode":[{"@type":"TVEpisode","episodeNumber":1,"name":"第1集","url":"https://hgtv.im/watch/32_1.html"},{"@type":"TVEpisode","episodeNumber":21,"name":"第21集","url":"https://hgtv.im/watch/32_21.html"}]}]}</script><a href="/watch/32_1.html">第1集</a><a href="/watch/32_2.html">第2集</a><a href="/watch/32_21.html">第21集</a>"#;

    #[test]
    fn parse_cards_real_snippet() {
        let items = parse_cards(CARD_HTML);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "1484");
        assert_eq!(items[0]["title"], "大吊姐驾到，统统闪开");
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://img.689.mx/"));
        assert_eq!(items[0]["remark"], "9.0分 · 9501热度 · 更新至10集");
        assert_eq!(items[1]["id"], "45");
        assert_eq!(items[1]["remark"], "10.0分 · 2万热度 · 全30集");
    }

    #[test]
    fn search_scopes_first_list_only() {
        let html = format!(
            "{CARD_HTML}<section class=\"seek-block\"><div class=\"cards t4-list\"><article class=\"card\"><a href=\"/drama/999.html\"><div class=\"poster\"><img src=\"https://img.mfantasy.net/x.jpg\" alt=\"猜你想看剧\"><span class=\"heat\">1热度</span></div><h3>猜你想看剧</h3></a></article></div></section>"
        );
        let items = parse_search_cards(&html);
        assert_eq!(items.len(), 2);
        assert!(!items.iter().any(|i| i["id"] == "999"));
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(catalog_url("home", 1), "https://hgtv.im/index.html");
        assert_eq!(catalog_url("home", 2), "https://hgtv.im/page/2.html");
        assert_eq!(catalog_url("home", 61), "https://hgtv.im/page/61.html");
        assert_eq!(catalog_url("2", 1), "https://hgtv.im/category/2.html");
        assert_eq!(catalog_url("2", 3), "https://hgtv.im/category/2-p3.html");
        assert_eq!(catalog_url("68", 1), "https://hgtv.im/category/68.html");
    }

    #[test]
    fn jld_fields_from_detail() {
        assert_eq!(jld_str(DETAIL_HTML, "name"), "重生之征服郭伯母");
        assert_eq!(jld_str(DETAIL_HTML, "genre"), "经典魔改");
        assert!(jld_str(DETAIL_HTML, "image").starts_with("https://img.mfantasy.net/"));
        let eps: Vec<i64> = watch_link_re()
            .captures_iter(DETAIL_HTML)
            .filter(|c| c.get(1).map(|m| m.as_str()) == Some("32"))
            .filter_map(|c| c[2].parse::<i64>().ok())
            .collect();
        assert_eq!(eps, vec![1, 2, 21]);
    }

    #[test]
    fn play_url_shape() {
        assert_eq!(abs_url("/play/32_1.html"), "https://hgtv.im/play/32_1.html");
        assert_eq!(
            abs_url("/play/32_21.html"),
            "https://hgtv.im/play/32_21.html"
        );
    }

    #[test]
    fn categories_count() {
        assert_eq!(CATS.len(), 14);
        assert_eq!(CATS[0], ("home", "首页"));
        assert!(CATS
            .iter()
            .any(|(id, name)| *id == "2" && *name == "都市爱情"));
        assert!(CATS
            .iter()
            .any(|(id, name)| *id == "68" && *name == "二次元区"));
    }
}
