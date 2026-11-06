//! AV18.Live（jav188.net / av18.live）：日本 AV 站，PHP 站。
//!
//! 与 18av.wiki 系（av18av.rs）是另一站，勿混淆。
//! 导航（首页实测 2026-11-06）：免費 `/?cat=free`；女優
//! `/actor_list.php`（共 45317 位，每页 42 位）；癖好/動作/身材/羞恥/
//! 強迫/身份 `/category.php?cate=1..6`；漫畫 `/comic_list.php`
//! （漫画，非视频，不做）；日本
//! `/search.php?order=latest&s_type=jp&s_tid=37`；無碼
//! `/search.php?order=latest&s_type=scate&s_tid=35`；歐美
//! `/search.php?order=latest&s_type=us&s_tid=33`；獨家
//! `/search.php?s_type=event&s_tid=17`；VR
//! `/search.php?s_type=tag&s_tid=488`；主題 `/special_topic.php`；
//! 國產 `/zone_index.php?zone=1`；卡通 `/zone_index.php?zone=2`；
//! 黑料 `/leaks_zone.php`。
//! 2026-11-06 修：`/?cat=free` 只剩 5 张精选，真正的免费列表在裸首页
//! `/`（79 张，不分页）；黑料 `/leaks_zone.php` 是 JS 壳，内容走
//! `ajax/site/get_tg_posts.php?format=json&page=N&limit=12&...&featured=1`
//! （须 `X-Requested-With: XMLHttpRequest` 头），帖子视频全部锁定，匿名
//! POST `ajax/site/get_tg_video.php` 回 `{"error":"need_login"}`，如实
//! 报须登录；翻页参数是 `num=`（站内分页链接即 `num=N`），`page=` 被
//! 服务端忽略；分区/主題单页不分页；`order=latest` 列表随新片到达滑动，
//! num=2 与 num=1 可能大面积重合，是站侧行为。
//! 搜索：GET `/search.php?cat=hd&kw_type=key&kw=<词>`（表单
//! `action="/search.php?cat=hd"`，隐藏 `kw_type=key`，框 `kw`）。
//! 列表卡片：`<a href="/player.php?uuid=<9–11 位>&cat=<N>">`，封面
//! `https://jav188.net/preview/50/s/<uuid>-800.jpg` 或
//! `https://jav188.net/preview/80/b/<uuid>-800.jpg`（首页轮播/网格用
//! data-src，分类/搜索页用 src），时长
//! `<span... video-time>03:20:40</span>`，标题含番号（如 MURIKURI-021），
//! 分类页标题在 img alt 里，另带 data-description 简介、data-time 秒数、
//! 预览 `https://msc1.vdosl.club/video_preview_2/<uuid>.mp4?v=<ts>` 直链；
//! 首页另有 `/subpage/getMvPreview.php?uuid=<uuid>&v=<ts>`（`v` 为 unix 秒）。
//! 女优卡片：单引号 `href='/search.php?s_type=actor&s_tid=<N>'`，图
//! `./resources/site_public/actor/<hex>.jpg`。
//! 详情/播放：`/player.php?uuid=<uuid>&cat=<N>`；播放器 jwplayer 7.11.3，
//! `<source>` 的 src 由 JS 填；分集
//! `<li class="vdplay01 part1" index=N ms_id=o9 start/end 每 600 秒一段
//! cat_id=15 token=<32 位 hex>>`（start 属性在页内重复写了两次，
//! 示例片 21 段，全片 12040 秒正好 21 段）；播放页嵌
//! `player_settings = playerJS_init({islogin:false, uuid, img_url_b,
//! urlencode, siteroot:"/", previewServer:"https://msc1.vdosl.club",
//! cat_id:"15", device_is:0, rtmp_open:true, all_vtt, is_free:false,...})`。
//! 取流：GET `subpage/getMv.php?num=<uuid>&ms_id=<ms_id>&file_prefix=`
//! `&start=<s>&end=<e>&cat_id=<cat_id>&quality=1&token=<token>&playall=0`
//! （playerJS.js 解码）；成功回 `{vurl, vurl_hls, request_uri, vr_type,
//! vr_angle, vr_host, vr_encrypt, other_alert}`，失败回 `{loginFail}`
//! 或 `{error, error_code: verify|permission_pay_no|permission_pay_exp|
//! need_use_point, PMVCases, point}`。第 1 段带 `is_free_preview="true"`，
//! 点播不走权限；其余段要权限。
//! 2026-11-06 17:46 无 cookie 调 getMv part1/part2 均回
//! `{"loginFail":"未登入"}`（200，34 字节）。本模块先抓播放页取会话
//! cookie（SITE_TOTAL_ID 等）再带 cookie 调 getMv；若仍 loginFail 则
//! 报须登录，不编造。2026-11-06 18:00 起 jav188.net 持续 000，cookie
//! 复验 20 次全 000，未能完成，须出口恢复后复验。

use std::sync::Mutex;

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://jav188.net";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PREVIEW_SERVER: &str = "https://msc1.vdosl.club";

static COOKIES: Lazy<Mutex<Vec<(String, String)>>> = Lazy::new(|| Mutex::new(Vec::new()));

fn cookie_header() -> String {
    COOKIES
        .lock()
        .unwrap()
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

fn store_cookies(resp: &reqwest::Response) {
    let mut jar = COOKIES.lock().unwrap();
    for value in resp.headers().get_all("set-cookie").iter() {
        if let Ok(s) = value.to_str() {
            if let Some(pair) = s.split(';').next() {
                if let Some((k, v)) = pair.split_once('=') {
                    let k = k.trim().to_string();
                    let v = v.trim().to_string();
                    if k.is_empty() {
                        continue;
                    }
                    if let Some(slot) = jar.iter_mut().find(|(ek, _)| *ek == k) {
                        slot.1 = v;
                    } else {
                        jar.push((k, v));
                    }
                }
            }
        }
    }
}

/// GET 文本页：带 UA/Referer/会话 cookie，存回 set-cookie，最多 3 次。
async fn get_page(path: &str) -> ApiResult<String> {
    let url = if path.starts_with("http") {
        path.to_string()
    } else {
        format!("{BASE}{path}")
    };
    let mut last_err = String::new();
    for _ in 0..3 {
        let mut req = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE}/"));
        let ck = cookie_header();
        if !ck.is_empty() {
            req = req.header("Cookie", ck);
        }
        match req.send().await {
            Ok(resp) => {
                store_cookies(&resp);
                let status = resp.status().as_u16();
                if status == 200 {
                    return resp
                        .text()
                        .await
                        .map_err(|e| ApiError::Internal(e.to_string()));
                }
                last_err = format!("jav188 请求 HTTP {status}");
            }
            Err(e) => last_err = e.to_string(),
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Err(ApiError::Internal(last_err))
}

const LEAKS_LIST: &str = "/ajax/site/get_tg_posts.php?format=json&page={page}&limit=12&sort=newest&featured=1&featured_pool=1&featured_default_sort=1";
const LEAKS_ONE: &str = "/ajax/site/get_tg_posts.php?format=json&page=1&limit=1&sort=newest&featured=1&featured_pool=1&uuid={uuid}";

/// 黑料帖子接口 GET：须 XHR 头，否则回 403 空体。最多 3 次。
async fn leaks_api(path: &str) -> ApiResult<Value> {
    let url = format!("{BASE}{path}");
    let mut last_err = String::new();
    for _ in 0..3 {
        let mut req = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE}/leaks_zone.php"))
            .header("X-Requested-With", "XMLHttpRequest");
        let ck = cookie_header();
        if !ck.is_empty() {
            req = req.header("Cookie", ck);
        }
        match req.send().await {
            Ok(resp) => {
                store_cookies(&resp);
                let status = resp.status().as_u16();
                if status == 200 {
                    let text = resp
                        .text()
                        .await
                        .map_err(|e| ApiError::Internal(e.to_string()))?;
                    return Ok(serde_json::from_str(&text).unwrap_or(Value::Null));
                }
                last_err = format!("jav188 黑料接口 HTTP {status}");
            }
            Err(e) => last_err = e.to_string(),
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Err(ApiError::Internal(last_err))
}

fn leaks_title(post: &Value) -> String {
    let msg = clean(&text_of(post, &["message_content"]))
        .replace(['\n', '\r'], " ");
    if !msg.trim().is_empty() {
        return msg.trim().to_string();
    }
    clean(&text_of(post, &["category_tag"]))
}

/// 帖子列表 → 卡片（id `leaks|<uuid>`）+ 是否还有下一页。
fn parse_leaks_posts(data: &Value) -> (Vec<Value>, bool) {
    let mut out: Vec<Value> = Vec::new();
    let Some(posts) = data.get("posts").and_then(|p| p.as_array()) else {
        return (out, false);
    };
    for post in posts {
        let uuid = text_of(post, &["uuid"]);
        let cover = text_of(post, &["cover_url"]);
        if uuid.is_empty() || cover.is_empty() {
            continue;
        }
        let tag = clean(&text_of(post, &["category_tag"]));
        let views = text_of(post, &["view_count"]);
        let remark = format!("{tag} {views}").trim().to_string();
        out.push(item_json(
            &format!("leaks|{uuid}"),
            &leaks_title(post),
            &cover,
            &remark,
        ));
    }
    let has_more = data
        .get("hasMore")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    (out, has_more)
}

async fn leaks_post(uuid: &str) -> ApiResult<Option<Value>> {
    let enc = url::form_urlencoded::byte_serialize(uuid.as_bytes()).collect::<String>();
    let data = leaks_api(&LEAKS_ONE.replace("{uuid}", &enc)).await?;
    let post = data
        .get("posts")
        .and_then(|p| p.as_array())
        .and_then(|a| a.first().cloned());
    Ok(post)
}

/// 黑料帖子详情：标题/分类/播放量、选集（锁定加“（需會員）”）、未锁定图片进剧照。
fn leaks_detail_parts(post: &Value, id: &str) -> (String, String, String, Vec<Value>, Vec<String>) {
    let title = leaks_title(post);
    let tag = clean(&text_of(post, &["category_tag"]));
    let views = text_of(post, &["view_count"]);
    let post_id = text_of(post, &["id"]);
    let mut episodes: Vec<Value> = Vec::new();
    let mut stills: Vec<String> = Vec::new();
    let mut vid_no = 0i64;
    if let Some(media) = post.get("media_list").and_then(|m| m.as_array()) {
        for (idx, m) in media.iter().enumerate() {
            let path = text_of(m, &["path"]);
            if path.is_empty() {
                continue;
            }
            let is_video = m.get("is_video").and_then(|v| v.as_bool()).unwrap_or(false);
            let is_locked = m.get("is_locked").and_then(|v| v.as_bool()).unwrap_or(false);
            if is_video {
                vid_no += 1;
                let mut name = format!("影片 {vid_no}");
                if is_locked {
                    name.push_str("（需會員）");
                }
                episodes.push(episode_json(
                    &format!("leaks|{post_id}|{idx}"),
                    &name,
                    id,
                ));
            } else if !is_locked {
                stills.push(path);
            }
        }
    }
    (title, tag, views, episodes, stills)
}

/// get_tg_video.php 响应取地址：成功回顶层 `url`，匿名回 `{"error":"need_login"}`。
fn tg_video_url(text: &str) -> Option<String> {
    let v: Value = serde_json::from_str(text).ok()?;
    let url = text_of(&v, &["url"]);
    if url.is_empty() {
        None
    } else {
        Some(url)
    }
}

/// 黑料取流 POST：匿名须登录时如实报错，不编造地址。
async fn get_tg_video(post_id: &str, index: i64) -> ApiResult<String> {
    let url = format!("{BASE}/ajax/site/get_tg_video.php");
    let body = json!({"post_id": post_id, "index": index}).to_string();
    let mut req = client()?
        .post(&url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/leaks_zone.php"))
        .header("Content-Type", "application/json")
        .header("X-Requested-With", "XMLHttpRequest")
        .body(body);
    let ck = cookie_header();
    if !ck.is_empty() {
        req = req.header("Cookie", ck);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    store_cookies(&resp);
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if let Some(u) = tg_video_url(&text) {
        return Ok(u);
    }
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    let err = text_of(&v, &["error"]);
    if err.is_empty() {
        return Err(ApiError::Internal(format!(
            "jav188 黑料取流未回地址：{}",
            text.chars().take(120).collect::<String>()
        )));
    }
    Err(ApiError::Internal(format!("jav188 黑料取流受限：{err}")))
}

fn clean(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ");
    loop {
        let t = out.replace(" ", " ");
        if t.len() == out.len() {
            break;
        }
        out = t;
    }
    out.trim().to_string()
}

fn re(pat: &str) -> Regex {
    Regex::new(pat).unwrap()
}

struct Card {
    id: String,
    title: String,
    cover: String,
    remark: String,
}

/// 列表卡片：逐块解析（两布局：首页轮播/网格用 data-src 封面 +
/// `<span class="title">` 标题；分类/搜索页用 src 封面 + img alt 标题，
/// 另带 data-description 简介、data-time 秒数、data-videourl 预览 mp4
/// 直链）；漫画卡（comic_player.php）无 player.php 链接，自动跳过。
fn parse_cards(html: &str) -> Vec<Card> {
    let block_re = re(r#"(?s)<div class="item [^"]*"[^>]*>(.*?)</div>\s*</div>"#);
    let uuid_re = re(r#"href="/player\.php\?uuid=([A-Za-z0-9_-]{9,12})&cat=(\d+)"#);
    let uuid2_re = re(r#"data-uuid="([A-Za-z0-9_-]{9,12})""#);
    let cover_re = re(
        r#"(?:data-src|src)="(https://jav188\.net/preview/\d+/[sb]/[A-Za-z0-9_-]+-800\.jpg[^"]*)""#,
    );
    let time_re = re(r#"video-time">([^<]+)<"#);
    let title_re = re(r#"(?s)<span class="title"[^>]*>\s*<a[^>]*>\s*([^<]+?)\s*</a>"#);
    let alt_re = re(r#"(?s)<img[^>]+alt='([^']+)'"#);
    let mut out: Vec<Card> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in block_re.captures_iter(html) {
        let b = &block[1];
        let (uuid, cat) = match uuid_re.captures(b) {
            Some(c) => (c[1].to_string(), c[2].to_string()),
            None => match uuid2_re.captures(b) {
                Some(c) => (c[1].to_string(), "19".to_string()),
                None => continue,
            },
        };
        let cover = match cover_re.captures(b) {
            Some(c) => c[1].to_string(),
            None => continue,
        };
        let time = match time_re.captures(b) {
            Some(c) => clean(&c[1]),
            None => continue,
        };
        let title = match title_re.captures(b) {
            Some(c) => clean(&c[1]),
            None => match alt_re.captures(b) {
                Some(c) => clean(&c[1]),
                None => continue,
            },
        };
        if title.is_empty() || seen.contains(&uuid) {
            continue;
        }
        seen.push(uuid.clone());
        out.push(Card {
            id: format!("{uuid}|{cat}"),
            title,
            cover,
            remark: time,
        });
    }
    out
}

struct Actress {
    tid: String,
    name: String,
    cover: String,
}

fn parse_actresses(html: &str) -> Vec<Actress> {
    let link_re = re(r#"href='/search\.php\?s_type=actor&s_tid=(\d+)' title="([^"]+)""#);
    let pic_re = re(r#"src="\./resources/site_public/actor/([0-9a-f]+\.jpg)""#);
    let links: Vec<(String, String)> = link_re
        .captures_iter(html)
        .map(|c| (c[1].to_string(), clean(&c[2])))
        .collect();
    let pics: Vec<String> = pic_re
        .captures_iter(html)
        .map(|c| c[1].to_string())
        .collect();
    let n = links.len().min(pics.len());
    let mut out = Vec::new();
    for i in 0..n {
        out.push(Actress {
            tid: links[i].0.clone(),
            name: links[i].1.clone(),
            cover: format!("{BASE}/resources/site_public/actor/{}", pics[i]),
        });
    }
    out
}

const CATS: &[(&str, &str, &str)] = &[
    ("free", "免費", "/?cat=free"),
    ("jp", "日本", "/search.php?order=latest&s_type=jp&s_tid=37"),
    (
        "scate",
        "無碼",
        "/search.php?order=latest&s_type=scate&s_tid=35",
    ),
    ("us", "歐美", "/search.php?order=latest&s_type=us&s_tid=33"),
    ("event", "獨家", "/search.php?s_type=event&s_tid=17"),
    ("vr", "VR", "/search.php?s_type=tag&s_tid=488"),
    ("zone1", "國產", "/zone_index.php?zone=1"),
    ("zone2", "卡通", "/zone_index.php?zone=2"),
    ("leaks", "黑料", "/leaks_zone.php"),
    ("topic", "主題", "/special_topic.php"),
    ("cate1", "癖好", "/category.php?cate=1"),
    ("cate2", "動作", "/category.php?cate=2"),
    ("cate3", "身材", "/category.php?cate=3"),
    ("cate4", "羞恥", "/category.php?cate=4"),
    ("cate5", "強迫", "/category.php?cate=5"),
    ("cate6", "身份", "/category.php?cate=6"),
    ("actor", "女優", "/actor_list.php"),
];

fn cat_path(tid: &str) -> Option<&'static str> {
    CATS.iter()
        .find(|(id, _, _)| *id == tid)
        .map(|(_, _, p)| *p)
}

fn page_url(path: &str, page: i64) -> String {
    let sep = if path.contains('?') { "&" } else { "?" };
    format!("{path}{sep}num={page}")
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let cats: Vec<Value> = CATS
        .iter()
        .map(|(id, name, _)| category_json(id, name))
        .collect();
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if category_id == "free" {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let html = get_page("/").await?;
        let items: Vec<Value> = parse_cards(&html)
            .into_iter()
            .map(|c| item_json(&c.id, &c.title, &c.cover, &c.remark))
            .collect();
        return Ok(json!({"items": items, "has_more": false}));
    }
    if category_id == "leaks" {
        let data = leaks_api(&LEAKS_LIST.replace("{page}", &page.to_string())).await?;
        let (items, has_more) = parse_leaks_posts(&data);
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    if matches!(category_id, "zone1" | "zone2" | "topic") && page > 1 {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let path = cat_path(category_id).unwrap_or("/?cat=free");
    let html = get_page(&page_url(path, page)).await?;
    if category_id == "actor" {
        let items: Vec<Value> = parse_actresses(&html)
            .into_iter()
            .map(|a| {
                item_json(
                    &format!("actor|{}|{}", a.tid, a.name),
                    &a.name,
                    &a.cover,
                    "",
                )
            })
            .collect();
        return Ok(json!({"items": items, "has_more": items.len() >= 42}));
    }
    let items: Vec<Value> = parse_cards(&html)
        .into_iter()
        .map(|c| item_json(&c.id, &c.title, &c.cover, &c.remark))
        .collect();
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

struct Segment {
    index: i64,
    ms_id: String,
    start: String,
    end: String,
    cat_id: String,
    token: String,
}

fn parse_segments(html: &str) -> Vec<Segment> {
    let seg_re = re(
        r#"(?s)<li class="vdplay01[^>]*?index="(?P<index>\d+)" ms_id="(?P<ms_id>[^"]*)" file_prefix="(?P<fp>[^"]*)" start="(?P<start>\d+)"(?: start="(?P<start2>\d+)")? end="(?P<end>\d+)" cat_id="(?P<cat_id>\d+)" token="(?P<token>[0-9a-f]{32})""#,
    );
    seg_re
        .captures_iter(html)
        .map(|c| Segment {
            index: c
                .name("index")
                .and_then(|m| m.as_str().parse().ok())
                .unwrap_or(0),
            ms_id: c
                .name("ms_id")
                .map(|m| m.as_str().to_string())
                .unwrap_or_default(),
            start: c
                .name("start")
                .map(|m| m.as_str().to_string())
                .unwrap_or_default(),
            end: c
                .name("end")
                .map(|m| m.as_str().to_string())
                .unwrap_or_default(),
            cat_id: c
                .name("cat_id")
                .map(|m| m.as_str().to_string())
                .unwrap_or_default(),
            token: c
                .name("token")
                .map(|m| m.as_str().to_string())
                .unwrap_or_default(),
        })
        .collect()
}

fn parse_player(html: &str, uuid: &str) -> (String, String, Vec<String>, Vec<Segment>) {
    let title = re(r#"<title>([^<|]+)"#)
        .captures(html)
        .map(|c| clean(&c[1]))
        .unwrap_or_default();
    let cover = re(r#"img_url_b\s*:\s*"([^"]+)""#)
        .captures(html)
        .map(|c| c[1].to_string())
        .unwrap_or_else(|| format!("{BASE}/preview/50/s/{uuid}-800.jpg"));
    let actor_re = re(r#"s_type=actor&s_tid=\d+[^>]*>([^<]+)<"#);
    let mut actors: Vec<String> = Vec::new();
    for c in actor_re.captures_iter(html) {
        let a = clean(&c[1]);
        if !a.is_empty() && !actors.contains(&a) {
            actors.push(a);
        }
    }
    (title, cover, actors, parse_segments(html))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(uuid) = id.strip_prefix("leaks|") {
        let post = leaks_post(uuid)
            .await?
            .ok_or_else(|| ApiError::Internal("jav188 黑料帖子不存在".into()))?;
        let cover = text_of(&post, &["cover_url"]);
        let (title, tag, views, episodes, stills) = leaks_detail_parts(&post, id);
        let mut synopsis = title.clone();
        if !tag.is_empty() {
            synopsis.push_str(&format!("\n分類：{tag}"));
        }
        if !views.is_empty() {
            synopsis.push_str(&format!("\n播放量：{views}"));
        }
        if !stills.is_empty() {
            synopsis.push_str(&format!("\n本片劇照：\n{}", stills.join("\n")));
        }
        return Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"category": tag, "tags": "", "remarks": "", "stills": stills},
        "episodes": episodes,
        }));
    }
    if let Some(rest) = id.strip_prefix("actor|") {
        let mut parts = rest.splitn(2, '|');
        let tid = parts.next().unwrap_or("");
        let name = parts.next().unwrap_or("").to_string();
        let name = if name.is_empty() {
            tid.to_string()
        } else {
            name
        };
        let html = get_page(&format!("/search.php?s_type=actor&s_tid={tid}")).await?;
        let cards = parse_cards(&html);
        let episodes: Vec<Value> = cards
            .into_iter()
            .map(|c| episode_json(&c.id, &c.title, id))
            .collect();
        return Ok(json!({
        "id": id,
        "title": name,
        "cover": "",
        "synopsis": name,
        "extra": {"category": "女優", "tags": "", "remarks": "", "stills": []},
        "episodes": episodes,
        }));
    }
    let mut parts = id.split('|');
    let uuid = parts.next().unwrap_or("");
    let page_cat = parts.next().unwrap_or("19");
    if uuid.is_empty() {
        return Err(ApiError::Internal("jav188 空 id".into()));
    }
    let html = get_page(&format!("/player.php?uuid={uuid}&cat={page_cat}")).await?;
    let (title, cover, actors, segments) = parse_player(&html, uuid);
    let mut episodes: Vec<Value> = Vec::new();
    episodes.push(episode_json(
        &format!("{uuid}|{page_cat}|preview"),
        "預告片",
        id,
    ));
    for seg in &segments {
        let name = if seg.index == 1 {
            format!("第{}段（免费预览）", seg.index)
        } else {
            format!("第{}段", seg.index)
        };
        let vid = format!(
            "{uuid}|{page_cat}|{}|{}|{}|{}|{}",
            seg.ms_id, seg.start, seg.end, seg.token, seg.cat_id
        );
        episodes.push(episode_json(&vid, &name, id));
    }
    if segments.is_empty() {
        episodes.push(episode_json(&format!("{uuid}|{page_cat}"), "正片", id));
    }
    let stills = if cover.is_empty() {
        Vec::new()
    } else {
        vec![cover.clone()]
    };
    Ok(json!({
    "id": id,
    "title": title,
    "cover": cover,
    "synopsis": title,
    "extra": {"category": "", "tags": "", "remarks": actors.join(" "), "stills": stills},
    "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let html = get_page(&format!("/search.php?cat=hd&kw_type=key&kw={enc}")).await?;
    let items: Vec<Value> = parse_cards(&html)
        .into_iter()
        .map(|c| item_json(&c.id, &c.title, &c.cover, &c.remark))
        .collect();
    Ok(json!({"items": items}))
}

/// getMv.php 调取：先抓播放页刷新会话 cookie 再带 cookie 调。
async fn get_mv(
    uuid: &str,
    page_cat: &str,
    ms_id: &str,
    start: &str,
    end: &str,
    token: &str,
    cat_id: &str,
) -> ApiResult<String> {
    let _ = get_page(&format!("/player.php?uuid={uuid}&cat={page_cat}")).await;
    let url = format!(
"{BASE}/subpage/getMv.php?num={uuid}&ms_id={ms_id}&file_prefix=&start={start}&end={end}&cat_id={cat_id}&quality=1&token={token}&playall=0"
);
    let mut req = client()?.get(&url).header("User-Agent", UA).header(
        "Referer",
        format!("{BASE}/player.php?uuid={uuid}&cat={page_cat}"),
    );
    let ck = cookie_header();
    if !ck.is_empty() {
        req = req.header("Cookie", ck);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    store_cookies(&resp);
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if get(&v, "loginFail").is_some() {
        return Err(ApiError::Internal("jav188 须登录后播放".into()));
    }
    if let Some(err) = get(&v, "error") {
        let code = text_of(&v, &["error_code"]);
        return Err(ApiError::Internal(format!(
            "jav188 播放受限：{}（{}）",
            err.as_str().unwrap_or(""),
            code
        )));
    }
    let url = text_of(&v, &["vurl_hls"]);
    let url = if url.is_empty() {
        text_of(&v, &["vurl"])
    } else {
        url
    };
    if url.is_empty() {
        return Err(ApiError::Internal(format!(
            "jav188 getMv 未回播放地址：{}",
            text.chars().take(120).collect::<String>()
        )));
    }
    Ok(url)
}

/// 预告片：/subpage/getMvPreview.php?uuid=<uuid>&v=<unix 秒>，可能 302 到 mp4。
async fn get_preview(uuid: &str, page_cat: &str) -> ApiResult<String> {
    let _ = get_page(&format!("/player.php?uuid={uuid}&cat={page_cat}")).await;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let url = format!("{BASE}/subpage/getMvPreview.php?uuid={uuid}&v={now}");
    let mut req = client()?.get(&url).header("User-Agent", UA).header(
        "Referer",
        format!("{BASE}/player.php?uuid={uuid}&cat={page_cat}"),
    );
    let ck = cookie_header();
    if !ck.is_empty() {
        req = req.header("Cookie", ck);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    store_cookies(&resp);
    let final_url = resp.url().to_string();
    let ctype = resp
        .headers()
        .get("content-type")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("")
        .to_string();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if final_url.ends_with(".mp4") || ctype.contains("video/") {
        return Ok(final_url);
    }
    if let Ok(v) = serde_json::from_str::<Value>(&text) {
        let u = text_of(&v, &["url", "vurl", "vurl_hls"]);
        if !u.is_empty() {
            return Ok(u);
        }
    }
    if text.trim_start().starts_with("http") {
        return Ok(text.trim().to_string());
    }
    Err(ApiError::Internal(format!(
        "jav188 预告接口未回地址（{}）",
        text.chars().take(120).collect::<String>()
    )))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(rest) = video_id.strip_prefix("leaks|") {
        let mut parts = rest.split('|');
        let post_id = parts.next().unwrap_or("");
        let index: i64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
        let url = get_tg_video(post_id, index).await?;
        return Ok(
            json!({"url": url, "header": {"User-Agent": UA, "Referer": format!("{BASE}/leaks_zone.php")}}),
        );
    }
    let parts: Vec<&str> = video_id.split('|').collect();
    let uuid = parts.first().copied().unwrap_or("");
    let page_cat = parts.get(1).copied().unwrap_or("19");
    if uuid.is_empty() {
        return Err(ApiError::Internal("jav188 空 video_id".into()));
    }
    let url = if parts.len() >= 3 && parts[2] == "preview" {
        get_preview(uuid, page_cat).await?
    } else if parts.len() >= 7 {
        get_mv(
            uuid, page_cat, parts[2], parts[3], parts[4], parts[5], parts[6],
        )
        .await?
    } else {
        let html = get_page(&format!("/player.php?uuid={uuid}&cat={page_cat}")).await?;
        let segs = parse_segments(&html);
        let seg = segs
            .first()
            .ok_or_else(|| ApiError::Internal("jav188 该片无分段".into()))?;
        get_mv(
            uuid,
            page_cat,
            &seg.ms_id,
            &seg.start,
            &seg.end,
            &seg.token,
            &seg.cat_id,
        )
        .await?
    };
    let _ = PREVIEW_SERVER;
    Ok(
        json!({"url": url, "header": {"User-Agent": UA, "Referer": format!("{BASE}/player.php?uuid={uuid}&cat={page_cat}")}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD_HTML: &str = r#"<div class="item pc-one-info-panel one ">
<a href="/player.php?uuid=zDhqy3J35ao&cat=19">
<div class="img-wrapper one_pic" data-videourl="/subpage/getMvPreview.php?uuid=zDhqy3J35ao&v=1793824659">
<img class="img-w cover lazyload" data-src="https://jav188.net/preview/50/s/zDhqy3J35ao-800.jpg?v=1793824659" alt='片名。'>
<span class="btn-sm border-rounded-sm small bg-trans-b text-w d-flex video-time">03:20:40</span>
</div>
</a>
<div class="content flex-columns small px-2">
<span class="title" >
<a class="ga_click" href="/player.php?uuid=zDhqy3J35ao&cat=19">
把在網遊認識的2名女●生培育完成成沉迷於黏稠濃密百合軟禁。 MURIKURI-021
</a>
</span>
<span class="name text-secondary">
<a href="/search.php?s_type=fac&s_tid=4024">無理くりえいてぃぶ</a>
</span>
</div>
</div>"#;

    #[test]
    fn parse_cards_real_snippet() {
        let cards = parse_cards(CARD_HTML);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].id, "zDhqy3J35ao|19");
        assert!(cards[0].title.contains("MURIKURI-021"));
        assert_eq!(
            cards[0].cover,
            "https://jav188.net/preview/50/s/zDhqy3J35ao-800.jpg?v=1793824659"
        );
        assert_eq!(cards[0].remark, "03:20:40");
    }

    #[test]
    fn parse_cards_layout_b_snippet() {
        let html = r#"<div class="item col-12 col-sm-6 col-md-3 pb-2 one list-preview-item one-info-panel col-md-3 "
                     data-description='简介文字。'
                     style="position:relative">
                    <a class="ga_click" href="/player.php?uuid=1RcZCnQjD6H&cat=19">
                        <div class="ga_id one_pic " data-time="9100" data-uuid="1RcZCnQjD6H"
                             data-videourl="https://msc1.vdosl.club/video_preview_2/1RcZCnQjD6H.mp4?v=1793824546">
                            <img alt='流浪的偷情黑色肉棒' class="img-h cover"
                                 src="https://jav188.net/preview/80/b/1RcZCnQjD6H-800.jpg?v=1793824546" style="width:100%">
                            <span class="btn-sm border-rounded-sm small bg-trans-b text-w d-flex video-time">02:31:40</span>
                            <p class="list-item-lt list-item-lt-uni"></p>
                        </div>
                    </a>
                    <div class="content flex-columns small px-2">
                        <span class="title"><a class="ga_click" href="/player.php?uuid=1RcZCnQjD6H&cat=19">流浪的偷情黑色肉棒 CB-126</a></span>
                    </div>
                </div>"#;
        let cards = parse_cards(html);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].id, "1RcZCnQjD6H|19");
        assert!(cards[0].title.contains("CB-126"));
        assert_eq!(
            cards[0].cover,
            "https://jav188.net/preview/80/b/1RcZCnQjD6H-800.jpg?v=1793824546"
        );
        assert_eq!(cards[0].remark, "02:31:40");
    }

    #[test]
    fn parse_actresses_real_snippet() {
        let html = r#"<a class="ga_click" href='/search.php?s_type=actor&s_tid=22000' title="山井鈴">
<div class="img-wrapper one_pic ">
<img class="img-w cover actor" src="./resources/site_public/actor/ffff223bf1cb20f9d770a924c3a900b1.jpg" alt="山井鈴" style="width:100%">
</div></a>"#;
        let a = parse_actresses(html);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].tid, "22000");
        assert_eq!(a[0].name, "山井鈴");
        assert_eq!(
            a[0].cover,
            "https://jav188.net/resources/site_public/actor/ffff223bf1cb20f9d770a924c3a900b1.jpg"
        );
    }

    #[test]
    fn parse_segments_real_snippet() {
        let html = r#"<li class="vdplay01 part1 item mb-0 col col-md-6 px-2" index="1" ms_id="o9" file_prefix="" start="0" start="0" end="600" cat_id="15" token="069fe0ed3f56b6b684e476c2936fa7e5" vtt="outTooltipImage-zDhqy3J35ao-8e50f3ef4518410a7a12b2b3600ee702-0-600.vtt">
<li class="vdplay01 part1 item mb-0 col col-md-6 px-2" index="2" ms_id="o9" file_prefix="" start="600" start="600" end="1200" cat_id="15" token="ac615f93b7d3491cd39c204793376177" vtt="outTooltipImage-zDhqy3J35ao-67f6721a648118b0c9a68eb405b1a20b-600-1200.vtt">"#;
        let segs = parse_segments(html);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0].index, 1);
        assert_eq!(segs[0].ms_id, "o9");
        assert_eq!(segs[0].start, "0");
        assert_eq!(segs[0].end, "600");
        assert_eq!(segs[0].cat_id, "15");
        assert_eq!(segs[0].token, "069fe0ed3f56b6b684e476c2936fa7e5");
        assert_eq!(segs[1].start, "600");
    }

    #[test]
    fn parse_player_title_cover_actors() {
        let html = r#"<title>把在網遊認識的2名女●生培育完成成沉迷於黏稠濃密百合軟禁。 MURIKURI-021|豪華館HD AV18 | 18AV 線上看 - AV18.Live 日本AV免費萬部影片</title>
player_settings = playerJS_init({islogin:false, uuid: "zDhqy3J35ao", img_url_b: "https://jav188.net/preview/b/zDhqy3J35ao.jpg",
<a href="/search.php?s_type=actor&s_tid=27054">宮西光</a><a href="/search.php?s_type=actor&s_tid=54824">今井なつめ</a>"#;
        let (title, cover, actors, segs) = parse_player(html, "zDhqy3J35ao");
        assert!(title.contains("MURIKURI-021"));
        assert!(!title.contains("豪華館"));
        assert_eq!(cover, "https://jav188.net/preview/b/zDhqy3J35ao.jpg");
        assert_eq!(actors, vec!["宮西光", "今井なつめ"]);
        assert!(segs.is_empty());
    }

    #[test]
    fn getmv_success_and_login_fail() {
        let ok: Value = serde_json::from_str(
r#"{"vurl":"https://msc1.vdosl.club/x.mp4","vurl_hls":"https://msc1.vdosl.club/x.m3u8","request_uri":"/a","vr_type":0}"#,
)
.unwrap();
        assert_eq!(
            text_of(&ok, &["vurl_hls"]),
            "https://msc1.vdosl.club/x.m3u8"
        );
        let fail: Value = serde_json::from_str(r#"{"loginFail":"未登入"}"#).unwrap();
        assert!(get(&fail, "loginFail").is_some());
        let err: Value =
            serde_json::from_str(r#"{"error":"需付費","error_code":"permission_pay_no"}"#).unwrap();
        assert_eq!(text_of(&err, &["error_code"]), "permission_pay_no");
    }

    #[test]
    fn categories_count_17() {
        assert_eq!(CATS.len(), 17);
        assert_eq!(CATS[0].1, "免費");
        assert_eq!(CATS[16].1, "女優");
        assert!(CATS.iter().any(|(id, _, _)| *id == "leaks"));
        assert!(CATS.iter().any(|(id, _, _)| *id == "topic"));
    }

    #[test]
    fn page_url_uses_num() {
        let u = page_url("/search.php?order=latest&s_type=jp&s_tid=37", 2);
        assert!(u.contains("num=2"), "{u}");
        assert!(!u.contains("page="), "{u}");
        let u2 = page_url("/category.php?cate=1", 3);
        assert_eq!(u2, "/category.php?cate=1&num=3");
    }

    const LEAKS_FIXTURE: &str = r##"{"ok":true,"hasMore":true,"posts":[
{"id":"29391","uuid":"fKvI4ucVR1ZkuY73bx","category_tag":"韓國主播","message_content":"#panda #ketyes98325 20260519","cover_url":"https://mstg2.vdosl.club/backend/fKvI4ucVR1ZkuY73bx/25690.jpg","view_count":"0","media_list":[]},
{"id":"29392","uuid":"aaaa","category_tag":"日本","message_content":"","cover_url":"","view_count":"5","media_list":[]},
{"id":"29393","uuid":"bbbb","category_tag":"韓國主播","message_content":"","cover_url":"https://mstg2.vdosl.club/backend/bbbb/1.jpg","view_count":"12","media_list":[]}
]}"##;

    #[test]
    fn leaks_posts_parse_fixture() {
        let data: Value = serde_json::from_str(LEAKS_FIXTURE).unwrap();
        let (items, has_more) = parse_leaks_posts(&data);
        assert!(has_more);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"].as_str().unwrap(), "leaks|fKvI4ucVR1ZkuY73bx");
        assert_eq!(
            items[0]["title"].as_str().unwrap(),
            "#panda #ketyes98325 20260519"
        );
        assert_eq!(
            items[0]["cover"].as_str().unwrap(),
            "https://mstg2.vdosl.club/backend/fKvI4ucVR1ZkuY73bx/25690.jpg"
        );
        assert_eq!(items[0]["remark"].as_str().unwrap(), "韓國主播 0");
        assert_eq!(items[1]["title"].as_str().unwrap(), "韓國主播");
        assert_eq!(items[1]["remark"].as_str().unwrap(), "韓國主播 12");
    }

    #[test]
    fn leaks_detail_parts_episodes() {
        let post: Value = json!({
            "id": "29391",
            "uuid": "fKvI4ucVR1ZkuY73bx",
            "category_tag": "韓國主播",
            "message_content": "#panda #ketyes98325 20260519",
            "cover_url": "https://mstg2.vdosl.club/backend/fKvI4ucVR1ZkuY73bx/25690.jpg",
            "view_count": "0",
            "media_list": [
                {"path": "https://mstg2.vdosl.club/backend/fKvI4ucVR1ZkuY73bx/25690.jpg", "is_video": false, "is_locked": false},
                {"path": "https://mstg2.vdosl.club/backend/fKvI4ucVR1ZkuY73bx/25691_cover.jpg", "is_video": true, "is_locked": true},
                {"path": "https://mstg2.vdosl.club/backend/fKvI4ucVR1ZkuY73bx/25692.mp4", "is_video": true, "is_locked": false}
            ]
        });
        let (title, tag, views, episodes, stills) =
            leaks_detail_parts(&post, "leaks|fKvI4ucVR1ZkuY73bx");
        assert_eq!(title, "#panda #ketyes98325 20260519");
        assert_eq!(tag, "韓國主播");
        assert_eq!(views, "0");
        assert_eq!(episodes.len(), 2);
        assert_eq!(episodes[0]["video_id"].as_str().unwrap(), "leaks|29391|1");
        assert_eq!(episodes[0]["title"].as_str().unwrap(), "影片 1（需會員）");
        assert_eq!(episodes[1]["video_id"].as_str().unwrap(), "leaks|29391|2");
        assert_eq!(episodes[1]["title"].as_str().unwrap(), "影片 2");
        assert_eq!(stills.len(), 1);
        assert!(stills[0].ends_with("25690.jpg"));
    }

    #[test]
    fn tg_video_url_shapes() {
        assert_eq!(
            tg_video_url(r#"{"url":"https://mstg2.vdosl.club/x.mp4"}"#).as_deref(),
            Some("https://mstg2.vdosl.club/x.mp4")
        );
        assert_eq!(tg_video_url(r#"{"error":"need_login"}"#), None);
        assert_eq!(tg_video_url(r#"{}"#), None);
        assert_eq!(tg_video_url("not json"), None);
    }
}
