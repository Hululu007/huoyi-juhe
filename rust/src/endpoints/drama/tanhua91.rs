//! 九色 91PORNY（tanhua91）：核心里的影视区站点。
//!
//! 与 py 版 tanhua91.py 同一套分类、同一条已验播放链。
//! 基址 www.91tanhua196.sbs（备用 301/326 同站镜像）；品牌九色视频 /
//! 91PORNY。不是 thdh（探花短视频 token 站）、不是 Tanhuavip12.xyz
//! （只有《木兰辞》）、不是 tanhuaav.com（/vodtype/ tube）、不是
//! jiusequ.cyou（MacCMS 站，dormant 的 jiuse.rs 未注册）；同名不同站。
//! 分类与站导航 1:1（41 项）：/video 14 个排序 tab、/videos 3 个排序 +
//! 18 个分类、/vod 4 个筛选、/swag 与 /madou 2 个关键词列表；/premium
//! 是 VIP 付费墙，只做免费部分。列表卡片四池同一结构（video-elem）。
//! 取流：详情页 <video data-src>，现取现播（token 分钟级过期）。
//! /video SD HLS 全长已验（152 分片 1258.47 秒 = 00:20:59，首分片
//! 206 + TS 魔数）；/vod HLS 全长已验（6 分片 49.33 秒 = 00:00:49）。
//! /videos 直链 mp4 的 token 每次现取（115370/120814 已验 206 +
//! ftyp 魔数；127616 的 mp4 404，属站内死链）。
//! 注意：2026-11-06 复验发现最近上传的 /video 视频 SD 流已死：详情
//! 页看着正常（JSON-LD 时长与卡片一致，无删除标记），但清单只剩
//! 1 分片 6.0 秒且带 __vnotice=1002 提示片（viewhd 前 6 部与
//! v-latest 前 4 部全中；老视频 1257271/1257310 仍是全长）。
//! 只有拉清单核对总时长才能发现，故 detail/player 侧验清单：
//! 提示片或总时长不足标称一半时换 embed 页（cdn3 同路流）重试，
//! 两路都死则回共享 12 秒预告 js10（用户 2026-11-06 令：死片也给
//! 12 秒预告；js10 还活着才回，死了才不给地址；取清单失败时不断言
//! 死，放行原地址）。
//! VIP（本站是用户自己的站，按实测写进两份）：匿名 viewhd 的 data-src
//! 是全站共享的 12 秒预告清单（两部不同视频同一条地址，已验 12 分片
//! 12.0 秒 + ENDLIST + 首分片 206），不是正片 HD；完整 HD 流匿名页
//! 里根本没有，只在 VIP 登录后由服务端发。2026-11-06 已试遍可推导
//! 的匿名 HD 路：/hlsd/ 与 /hd/（带签/不带签、jiuse2/jiuse3/cdn3、
//! 数字 id/hex id）三部视频共 26 次全是 404；SD 签名绑 host，换
//! host 回 403；页内 JS 只是 video.js 播放器包，无取流接口；
//! premium 页没漏 HD 域名；embed 页是同一条 SD 流（cdn3，死视频
//! 同样是 6 秒提示片）。无 VIP 测试号，匿名拿不到完整 HD，不编造。
//! 故 viewhd 详情出两个选集：高清预览（共享预告清单）+ 标清全片
//! （同视频 /video/view/<hex> 的 SD 流，活的才给，死的剔掉）。
//! 下载须登录，匿名页无下载直链。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOSTS: [&str; 3] = [
    "https://www.91tanhua196.sbs",
    "https://www.91tanhua301.sbs",
    "https://www.91tanhua326.sbs",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05～06。
const CATS: &[(&str, &str)] = &[
    ("v-latest", "最近更新"),
    ("v-hd", "高清视频"),
    ("v-recent-favorite", "最近加精"),
    ("v-hot-list", "当前最热"),
    ("v-recent-rating", "最近得分"),
    ("v-ori", "91原创"),
    ("v-long-list", "10分钟以上"),
    ("v-longer-list", "20分钟以上"),
    ("v-month-discuss", "本月讨论"),
    ("v-top-favorite", "本月收藏"),
    ("v-most-favorite", "收藏最多"),
    ("v-top-list", "本月最热"),
    ("v-top-last", "上月最热"),
    ("k-top-rated", "最高评分"),
    ("k-latest-updates", "最近更新"),
    ("k-most-popular", "最受欢迎"),
    ("k-europe-america", "欧美"),
    ("k-chinese", "国产"),
    ("k-fornication", "乱伦"),
    ("k-japan-korea", "日韩"),
    ("k-anime", "动漫"),
    ("k-homosexual", "同性"),
    ("k-hd", "高清AV"),
    ("k-sm", "SM专区"),
    ("k-jijin", "片商集锦"),
    ("k-guodong", "果冻传媒"),
    ("k-xingkong", "星空传媒"),
    ("k-madou", "麻豆传媒"),
    ("k-tianmei", "天美传媒"),
    ("k-jingdong", "精东影业"),
    ("k-swag", "台湾SWAG"),
    ("k-tuzi", "兔子先生"),
    ("k-mitao", "蜜桃传媒"),
    ("k-huangjia", "皇家华人"),
    ("d-all", "精品"),
    ("d-orig", "原创"),
    ("d-repost", "转发"),
    ("d-sponsor", "赞助"),
    ("s-swag", "SWAG"),
    ("s-madou", "麻豆"),
];

/// 蝌蚪 3 个排序 slug。
const K_SORTS: &[&str] = &["top-rated", "latest-updates", "most-popular"];

/// 带备用域 + 重试的取页：出口时通时断，每域最多试 2 次。
async fn get_path(path: &str) -> ApiResult<String> {
    let mut last_err = String::new();
    for host in HOSTS {
        for _ in 0..2 {
            match fetch_once(&format!("{host}{path}")).await {
                Ok(text) => return Ok(text),
                Err(e) => {
                    last_err = e.to_string();
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn fetch_once(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", HOSTS[0])
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("九色请求 HTTP {status}")));
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
        .replace("&nbsp;", " ")
}

fn strip_tags(s: &str) -> String {
    let re = Regex::new(r"<[^>]+>").unwrap();
    re.replace_all(s, "").trim().to_string()
}

/// 地址归一：协议相对补 https，站内相对路径补基址。
fn fix_url(raw: &str) -> String {
    let u = unescape(raw.trim());
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("https://") || u.starts_with("http://") {
        return u;
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{}{u}", HOSTS[0]);
    }
    u
}

fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 卡片解析：四池同一结构 video-elem（展示链接 + 背景封面 +
/// layer 时长 + title 标题 + 作者/日期/播放量）。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let href_re = Regex::new(r#"<a[^>]*class="display d-block"[^>]*href="([^"]+)""#).ok();
    let cover_re =
        Regex::new(r#"background-image:\s*url\(['"]?([^)'"]+)"#).ok();
    let dur_re = Regex::new(r#"<small class="layer">([^<]+)</small>"#).ok();
    let title_re = Regex::new(
        r#"(?s)<a[^>]*class="title[^"]*"[^>]*href="[^"]+">([^<]+)</a>"#,
    )
    .ok();
    for block in html.split("<div class=\"video-elem\">").skip(1) {
        let href = match &href_re {
            Some(re) => re
                .captures(block)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        if href.is_empty() || !seen.insert(href.clone()) {
            continue;
        }
        if !href.starts_with("/video/")
            && !href.starts_with("/videos/")
            && !href.starts_with("/vod/")
        {
            continue;
        }
        let title = match &title_re {
            Some(re) => re
                .captures(block)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let cover = match &cover_re {
            Some(re) => re
                .captures(block)
                .map(|m| fix_url(&m[1]))
                .unwrap_or_default(),
            None => String::new(),
        };
        let remark = match &dur_re {
            Some(re) => re
                .captures(block)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&href, &title, &cover, &remark));
    }
    items
}

/// 排序 tab 解析：div data-href + 文本（/video 与 /videos 共用）。
fn parse_tabs(html: &str, prefix: &str) -> Vec<(String, String)> {
    let re = match Regex::new(
        r#"data-href="([^"]+)"[^>]*>([^<]+)</div>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re.captures_iter(html) {
        let href = cap[1].trim().to_string();
        let name = cap[2].trim().to_string();
        if !href.starts_with(prefix) || name.is_empty() {
            continue;
        }
        if !seen.insert(href.clone()) {
            continue;
        }
        out.push((href, name));
    }
    out
}

/// 蝌蚪排序解析：<a href="/videos/<sort>/<页>">文本</a>。
fn parse_k_sorts(html: &str) -> Vec<(String, String)> {
    let re = match Regex::new(
        r#"<a[^>]*href="/videos/([a-z-]+)/\d+"[^>]*>([^<]+)</a>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for cap in re.captures_iter(html) {
        let slug = cap[1].trim().to_string();
        let name = cap[2].trim().to_string();
        if !K_SORTS.contains(&slug.as_str()) || name.is_empty() {
            continue;
        }
        if !seen.insert(slug.clone()) {
            continue;
        }
        out.push((slug, name));
    }
    out
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

/// 去掉 HTML 注释：站内有被注释掉的分类（有码/群交/无码），不 live。
fn strip_comments(html: &str) -> String {
    let re = Regex::new(r"(?s)<!--.*?-->").unwrap();
    re.replace_all(html, "").to_string()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Ok(html) = get_path("/video").await {
        for (href, name) in parse_tabs(&strip_comments(&html), "/video/category/") {
            if let Some(slug) = href.strip_prefix("/video/category/") {
                let slug = slug.trim_matches('/');
                if slug == "nonpaid" {
                    continue;
                }
                let id = format!("v-{slug}");
                if seen.insert(id.clone()) {
                    list.push(category_json(&id, &name));
                }
            }
        }
    }
    if let Ok(html) = get_path("/videos").await {
        let live = strip_comments(&html);
        for (slug, name) in parse_k_sorts(&live) {
            let id = format!("k-{slug}");
            if seen.insert(id.clone()) {
                list.push(category_json(&id, &name));
            }
        }
        for (href, name) in parse_tabs(&live, "/videos/categories/") {
            if let Some(slug) = href.strip_prefix("/videos/categories/") {
                let slug = slug.trim_matches('/');
                let id = format!("k-{slug}");
                if seen.insert(id.clone()) {
                    list.push(category_json(&id, &name));
                }
            }
        }
    }
    if list.len() < 10 {
        return Ok(fallback_categories());
    }
    for (id, name) in [
        ("d-all", "精品"),
        ("d-orig", "原创"),
        ("d-repost", "转发"),
        ("d-sponsor", "赞助"),
        ("s-swag", "SWAG"),
        ("s-madou", "麻豆"),
    ] {
        if seen.insert(id.to_string()) {
            list.push(category_json(id, name));
        }
    }
    Ok(json!({ "categories": list }))
}

/// 分类 → 列表路径与下一页标记；None 表示未知分类。
fn catalog_route(category_id: &str, page: i64) -> Option<(String, String)> {
    let pg = page.max(1);
    if let Some(slug) = category_id.strip_prefix("v-") {
        let base = format!("/video/category/{slug}");
        let path = if pg <= 1 {
            base.clone()
        } else {
            format!("{base}/{pg}")
        };
        return Some((path, format!("{base}/{}", pg + 1)));
    }
    if let Some(slug) = category_id.strip_prefix("k-") {
        if K_SORTS.contains(&slug) {
            let base = format!("/videos/{slug}");
            return Some((
                format!("{base}/{pg}"),
                format!("{base}/{}", pg + 1),
            ));
        }
        let base = format!("/videos/categories/{slug}");
        let path = if pg <= 1 {
            base.clone()
        } else {
            format!("{base}/{pg}")
        };
        return Some((path, format!("{base}/{}", pg + 1)));
    }
    if let Some(slug) = category_id.strip_prefix("d-") {
        let filter = match slug {
            "all" => String::new(),
            "orig" => "/%E5%8E%9F%E5%88%9B".to_string(),
            "repost" => "/%E8%BD%AC%E5%8F%91".to_string(),
            "sponsor" => "/%E8%B5%9E%E5%8A%A9".to_string(),
            _ => return None,
        };
        let path = if pg <= 1 {
            format!("/vod{filter}")
        } else {
            format!("/vod{filter}?page={pg}")
        };
        return Some((path, format!("/vod{filter}?page={}", pg + 1)));
    }
    if let Some(slug) = category_id.strip_prefix("s-") {
        if slug != "swag" && slug != "madou" {
            return None;
        }
        let path = format!("/{slug}?keywords={slug}&page={pg}");
        return Some((path, format!("/{slug}?keywords={slug}&page={}", pg + 1)));
    }
    None
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (path, next) = match catalog_route(category_id, page) {
        Some(v) => v,
        None => return Ok(json!({"items": [], "has_more": false})),
    };
    let html = get_path(&path).await?;
    let items = parse_cards(&html);
    let has_more = !items.is_empty() && html.contains(&next.replace("&", "&amp;"))
        || !items.is_empty() && html.contains(&next);
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 详情页 data-src（<video data-src="流地址">），// 开头补 https:。
fn parse_play_url(html: &str) -> String {
    let re = match Regex::new(r#"data-src="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => fix_url(&cap[1]),
        None => String::new(),
    }
}

fn meta_content(html: &str, attr: &str, value: &str) -> String {
    let pat = format!(r#"<meta[^>]*{attr}="{value}"[^>]*content="([^"]+)""#);
    let re = match Regex::new(&pat) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(cap[1].trim()),
        None => String::new(),
    }
}

/// 详情页 JSON-LD 的标称时长（PT1M53S / PT17S），秒；没有则 None。
fn iso_duration_secs(html: &str) -> Option<f64> {
    let re = Regex::new(r#""duration":\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?""#).ok()?;
    let cap = re.captures(html)?;
    let h: f64 = cap.get(1).and_then(|m| m.as_str().parse().ok()).unwrap_or(0.0);
    let m: f64 = cap.get(2).and_then(|m| m.as_str().parse().ok()).unwrap_or(0.0);
    let s: f64 = cap.get(3).and_then(|m| m.as_str().parse().ok()).unwrap_or(0.0);
    let total = h * 3600.0 + m * 60.0 + s;
    if total > 0.0 { Some(total) } else { None }
}

struct PlaylistInfo {
    total: Option<f64>,
    notice: bool,
}

/// 清单纯解析：分片时长求和 + __vnotice 标记；主清单（无分片但有
/// .m3u8 引用）时长记 None，不断言死。
fn parse_playlist(text: &str) -> Option<PlaylistInfo> {
    if !text.contains("#EXTM3U") {
        return None;
    }
    let notice = text.contains("__vnotice");
    let re = Regex::new(r"#EXTINF:([\d.]+)").ok()?;
    let mut total = 0.0;
    let mut n = 0;
    for cap in re.captures_iter(text) {
        if let Ok(v) = cap[1].parse::<f64>() {
            total += v;
            n += 1;
        }
    }
    if n == 0 {
        if text.contains(".m3u8") {
            return Some(PlaylistInfo { total: None, notice });
        }
        return Some(PlaylistInfo { total: Some(0.0), notice });
    }
    Some(PlaylistInfo { total: Some(total), notice })
}

async fn playlist_info(url: &str) -> Option<PlaylistInfo> {
    match fetch_once(url).await {
        Ok(text) => parse_playlist(&text),
        Err(_) => None,
    }
}

/// 提示片直接判死；总时长不足标称一半判死；无标称或主清单不断言死。
fn playlist_playable(info: &PlaylistInfo, claimed: Option<f64>) -> bool {
    if info.notice {
        return false;
    }
    match (info.total, claimed) {
        (Some(total), Some(want)) => total >= want * 0.5,
        _ => true,
    }
}

/// embed 页流地址（/video 与 /vod 两池）；取不到返回空串。
async fn embed_play_url(detail_path: &str) -> String {
    let hex = detail_path.trim_matches('/').rsplit('/').next().unwrap_or("");
    if hex.is_empty() {
        return String::new();
    }
    let embed = if detail_path.contains("/video/view") {
        format!("/video/embed/{hex}")
    } else if detail_path.contains("/vod/view/") {
        format!("/vod/embed/{hex}")
    } else {
        return String::new();
    };
    match get_path(&embed).await {
        Ok(html) => parse_play_url(&html),
        Err(_) => String::new(),
    }
}

/// HLS 流验真：共享 12 秒预告原样放行；主路清单死则换 embed 路重试；
/// 两路都死返回 None；清单取不到（出口抖动）时放行原地址，不断言死。
async fn resolve_hls(url: &str, detail_path: &str, claimed: Option<f64>) -> Option<String> {
    if url.contains("/hlsd/js10/") {
        return Some(url.to_string());
    }
    match playlist_info(url).await {
        Some(info) if playlist_playable(&info, claimed) => return Some(url.to_string()),
        Some(_) => {}
        None => return Some(url.to_string()),
    }
    let alt = embed_play_url(detail_path).await;
    if !alt.is_empty() && alt != url {
        match playlist_info(&alt).await {
            Some(info) if playlist_playable(&info, claimed) => return Some(alt),
            Some(_) => {}
            None => return Some(alt),
        }
    }
    None
}

const PREVIEW_URL: &str = "https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8";

/// 死片兜底：共享 12 秒预告还活着就回它，否则 None。
async fn preview_fallback() -> Option<String> {
    match playlist_info(PREVIEW_URL).await {
        Some(info) if playlist_playable(&info, None) => Some(PREVIEW_URL.to_string()),
        _ => None,
    }
}

/// mp4 直链验活：只有 404/410 判死，其余一律放行（出口抖动不断言死）。
async fn mp4_alive(url: &str) -> bool {
    let Ok(client) = client() else {
        return true;
    };
    match client
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", HOSTS[0])
        .header("Range", "bytes=0-0")
        .send()
        .await
    {
        Ok(resp) => {
            let st = resp.status().as_u16();
            st != 404 && st != 410
        }
        Err(_) => true,
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim().trim_start_matches('/');
    let html = get_path(&format!("/{id}")).await?;
    let claimed = iso_duration_secs(&html);
    let mut title = meta_content(&html, "property", "og:title");
    if title.is_empty() {
        let re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        title = match &re {
            Some(re) => re
                .captures(&html)
                .map(|m| unescape(&strip_tags(&m[1])))
                .unwrap_or_default(),
            None => String::new(),
        };
        if let Some(pos) = title.find(" - ") {
            title.truncate(pos);
        }
    }
    let mut cover = meta_content(&html, "property", "og:image:secure_url");
    if cover.is_empty() {
        cover = meta_content(&html, "property", "og:image");
    }
    let actor = meta_content(&html, "name", "twitter:creator");
    let keywords = meta_content(&html, "name", "keywords");
    let mut synopsis = meta_content(&html, "property", "og:description");
    if synopsis.is_empty() {
        synopsis = title.clone();
    }
    if !actor.is_empty() {
        synopsis = format!("{synopsis}\n作者：{actor}");
    }
    if !keywords.is_empty() {
        synopsis = format!("{synopsis}\n标签：{keywords}");
    }
    let play_url = parse_play_url(&html);
    if title.is_empty() || play_url.is_empty() {
        return Err(ApiError::Internal("九色未返回可播放地址".into()));
    }
    let mut episodes = Vec::new();
    if id.starts_with("video/viewhd/") {
        episodes.push(episode_json(&play_url, "高清预览", series_id));
        if let Some(hex) = id.rsplit('/').next() {
            if let Ok(sd_html) = get_path(&format!("/video/view/{hex}")).await {
                let sd_url = parse_play_url(&sd_html);
                if !sd_url.is_empty() {
                    let sd_claimed = iso_duration_secs(&sd_html).or(claimed);
                    if let Some(ok) = resolve_hls(&sd_url, &format!("/video/view/{hex}"), sd_claimed).await {
                        episodes.push(episode_json(&ok, "标清全片", series_id));
                    }
                }
            }
        }
    } else if play_url.contains(".m3u8") {
        match resolve_hls(&play_url, &id, claimed).await {
            Some(ok) => episodes.push(episode_json(&ok, "在线播放", series_id)),
            None => match preview_fallback().await {
                Some(pv) => episodes.push(episode_json(&pv, "在线播放", series_id)),
                None => return Err(ApiError::Internal("九色该视频暂无可播流".into())),
            },
        }
    } else if play_url.contains(".mp4") {
        if mp4_alive(&play_url).await {
            episodes.push(episode_json(&play_url, "在线播放", series_id));
        } else if let Some(pv) = preview_fallback().await {
            episodes.push(episode_json(&pv, "在线播放", series_id));
        } else {
            return Err(ApiError::Internal("九色该视频暂无可播流".into()));
        }
    } else {
        episodes.push(episode_json(&play_url, "在线播放", series_id));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": episodes,
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("九色该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let path = format!("/search?keywords={}&page=1", url_encode(query));
    let html = get_path(&path).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cards_real_video_elem() {
        let html = r#"<div class="colVideoList">
                    <div class="video-elem">
                        <a target="_self" class="display d-block" href="/video/viewhd/ef5152fe75b733995347">
                            <div class="scale"></div>
                                                        <div class="img" style="background-image: url('//bae9594a4d.ucloud165.xyz/thumb/1257601.jpg')"></div>
                                                        <small class="layer">00:01:53</small>
                            <small class="vip-layer">高清</small>                                                    </a>
                        <a target="_self" class="title text-sub-title mt-2 mb-1" href="/video/viewhd/ef5152fe75b733995347">[原创] 苏州人妻在自己家楼道被内射后夹着精液回家继续伺候老公</a>
                        <small class="d-inline-block text-truncate mt-1 mb-1" style="max-width: 100%;">
                            <div class="text-muted">作者: <a class="text-dark" href="/author/47-AK">47-AK</a>
                            </div>
                            <div class="text-muted">2026-11-05&nbsp;|&nbsp;3045次播放
                            </div>
                        </small>
                    </div>
         "#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/video/viewhd/ef5152fe75b733995347");
        assert_eq!(
            items[0]["title"],
            "[原创] 苏州人妻在自己家楼道被内射后夹着精液回家继续伺候老公"
        );
        assert_eq!(
            items[0]["cover"],
            "https://bae9594a4d.ucloud165.xyz/thumb/1257601.jpg"
        );
        assert_eq!(items[0]["remark"], "00:01:53");
    }

    #[test]
    fn commented_tabs_excluded() {
        let html = r#"<!-- <div class="item" data-href="/videos/categories/gangbang">群交</div> --><div class="item" data-href="/videos/categories/chinese">国产</div>"#;
        let live = strip_comments(html);
        let tabs = parse_tabs(&live, "/videos/categories/");
        assert_eq!(tabs.len(), 1);
        assert_eq!(tabs[0].0, "/videos/categories/chinese");
    }

    #[test]
    fn parse_tabs_real_markup() {
        let html = r#"<div class="item col-30 " click="redirect" data-href="/video/category/latest">最近更新</div>
            <div class="item col-30 active" click="redirect" data-href="/video/category/hd">高清视频</div>
            <div class="item col-30 " click="redirect" data-href="/video/category/hot-list">当前最热</div>"#;
        let tabs = parse_tabs(html, "/video/category/");
        assert_eq!(tabs.len(), 3);
        assert_eq!(tabs[1], ("/video/category/hd".to_string(), "高清视频".to_string()));
    }

    #[test]
    fn parse_k_sorts_real_markup() {
        let html = r#"<a class=" px-2" href="/videos/latest-updates/1">最近更新</a>
                    <a class="active px-2" href="/videos/top-rated/1">最高评分</a>
                    <a class=" px-2" href="/videos/most-popular/1">最受欢迎</a>"#;
        let sorts = parse_k_sorts(html);
        assert_eq!(sorts.len(), 3);
        assert_eq!(sorts[1].0, "top-rated");
    }

    #[test]
    fn parse_play_url_variants() {
        let sd = r#"<video id="video-play" data-src="https://cdn2.jiuse3.cloud/s/1793923200/6rWNx_6Y86_29dlI95W1rg/hls/1257310/index.m3u8">"#;
        assert_eq!(
            parse_play_url(sd),
            "https://cdn2.jiuse3.cloud/s/1793923200/6rWNx_6Y86_29dlI95W1rg/hls/1257310/index.m3u8"
        );
        let hd = r#"<video id="video-play" data-src="//cdn2.jiuse2.cloud/hlsd/js10/index.m3u8">"#;
        assert_eq!(
            parse_play_url(hd),
            "https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8"
        );
        let vod = r#"<video data-src="https://cdn22.jiuse3.cloud/2026/11/05/e7bc985da2f0a3d3a83bfc04396f0fc7/index.m3u8?t=1793894633&amp;m=cQd-lWZRaxynZ0XrDWz6cw">"#;
        assert_eq!(
            parse_play_url(vod),
            "https://cdn22.jiuse3.cloud/2026/11/05/e7bc985da2f0a3d3a83bfc04396f0fc7/index.m3u8?t=1793894633&m=cQd-lWZRaxynZ0XrDWz6cw"
        );
        let mp4 = r#"<video data-src="https://cdn.cdnkdjs.com/get_file/3/21795521367c790f7cf9c755219dda91/127000/127663/127663.mp4?t=1793894931&amp;m=yy8Aa7GC2Cb6OyutKooLBg">"#;
        assert!(parse_play_url(mp4).ends_with(".mp4?t=1793894931&m=yy8Aa7GC2Cb6OyutKooLBg"));
        assert_eq!(parse_play_url("<div>no video</div>"), "");
    }

    #[test]
    fn catalog_route_all_prefixes() {
        assert_eq!(
            catalog_route("v-hd", 1).unwrap(),
            ("/video/category/hd".to_string(), "/video/category/hd/2".to_string())
        );
        assert_eq!(
            catalog_route("v-hd", 3).unwrap(),
            ("/video/category/hd/3".to_string(), "/video/category/hd/4".to_string())
        );
        assert_eq!(
            catalog_route("k-top-rated", 2).unwrap(),
            ("/videos/top-rated/2".to_string(), "/videos/top-rated/3".to_string())
        );
        assert_eq!(
            catalog_route("k-chinese", 1).unwrap(),
            ("/videos/categories/chinese".to_string(), "/videos/categories/chinese/2".to_string())
        );
        assert_eq!(
            catalog_route("d-all", 2).unwrap(),
            ("/vod?page=2".to_string(), "/vod?page=3".to_string())
        );
        assert_eq!(
            catalog_route("d-orig", 1).unwrap().0,
            "/vod/%E5%8E%9F%E5%88%9B"
        );
        assert_eq!(
            catalog_route("s-swag", 2).unwrap(),
            ("/swag?keywords=swag&page=2".to_string(), "/swag?keywords=swag&page=3".to_string())
        );
        assert!(catalog_route("x-nope", 1).is_none());
    }

    #[test]
    fn fallback_has_40_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 40);
        assert_eq!(list[0]["id"], "v-latest");
        assert_eq!(list[12]["name"], "上月最热");
        assert_eq!(list[13]["id"], "k-top-rated");
        assert_eq!(list[34]["id"], "d-all");
        assert_eq!(list[39]["name"], "麻豆");
        assert!(!list.iter().any(|c| c["id"] == "v-nonpaid"));
    }

    #[test]
    fn iso_duration_secs_cases() {
        assert_eq!(
            iso_duration_secs(r#""duration": "PT1M53S""#),
            Some(113.0)
        );
        assert_eq!(
            iso_duration_secs(r#""duration": "PT17S""#),
            Some(17.0)
        );
        assert_eq!(
            iso_duration_secs(r#""duration": "PT20M59S""#),
            Some(1259.0)
        );
        assert_eq!(iso_duration_secs("no duration here"), None);
    }

    #[test]
    fn notice_clip_playlist_is_dead() {
        let notice = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:6.000000,\nindex0.ts?__vnotice=1002\n#EXT-X-ENDLIST\n";
        let info = parse_playlist(notice).unwrap();
        assert_eq!(info.total, Some(6.0));
        assert!(info.notice);
        assert!(!playlist_playable(&info, Some(113.0)));
        let full = "#EXTM3U\n#EXTINF:8.341667,\nindex0.ts\n#EXTINF:8.341667,\nindex1.ts\n#EXT-X-ENDLIST\n";
        let info = parse_playlist(full).unwrap();
        assert!(!info.notice);
        assert!(playlist_playable(&info, Some(17.0)));
        assert!(!playlist_playable(&info, Some(113.0)));
        assert!(parse_playlist("not a playlist").is_none());
    }

    #[test]
    fn viewhd_sd_path() {
        let id = "video/viewhd/ec38d7530bee96c9708c";
        assert!(id.starts_with("video/viewhd/"));
        let hex = id.rsplit('/').next().unwrap();
        assert_eq!(format!("/video/view/{hex}"), "/video/view/ec38d7530bee96c9708c");
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("//bae9594a4d.ucloud165.xyz/thumb/1257601.jpg"),
            "https://bae9594a4d.ucloud165.xyz/thumb/1257601.jpg"
        );
        assert_eq!(
            fix_url("/video/view/abc"),
            "https://www.91tanhua196.sbs/video/view/abc"
        );
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://cdn2.jiuse3.cloud/s/1/x/hls/1/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://cdn2.jiuse3.cloud/s/1/x/hls/1/index.m3u8"
        );
        assert!(play_check("/video/view/abc").is_err());
    }
}
