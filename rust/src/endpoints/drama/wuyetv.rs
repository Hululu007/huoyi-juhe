//! 午夜TV：wuye.tv API + MD5 签名。
//!
//! 来源 jar 类 `ZakaWuyetvAmns`。API 走 `api8.{root}/api|v3` 与
//! `rankv21.{root}/v3`（root 为 wuye.tv / wyav.tv，探活
//! `GET /v3/list/MainMenuV3?cinema=2` 含 `"ret":200` 且含
//! `channelList`）；每次请求在查询串后追加
//! `&vv={md5(毫秒 + "&" + 小写查询串 + "&" + PRIV[毫秒%8])}
//! &pub={毫秒}`，非 ASCII 字符按 UTF-8 字节转大写 `%XX`。
//! 注意：备用标签串里的“萝莉,少女”已按用户口径删除。

use md5::{Digest, Md5};
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const MAIN: &str = "https://www.wuye.tv";
const STATIC: &str = "https://static.wuye.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const ROOTS: &[&str] = &["wuye.tv", "wyav.tv"];

const PRIV: &[&str] = &[
    "version001",
    "vers1on001",
    "vers1on00i",
    "bersion001",
    "vcrsion001",
    "versi0n001",
    "versio_001",
    "version0o1",
];

const MAIN_CATS: &[(&str, &str)] = &[
    ("0,2,10,85", "日本"),
    ("0,2,10,86", "欧美"),
    ("0,2,10,88", "卡通"),
    ("0,2,10,87", "国产"),
];

/// 备用标签串（“萝莉,少女”已删）。
const FALLBACK_TAGS: &str = "美女,软妹,御姐,甜美,清纯,熟女,素人,学生,人妻,空姐,家教,教师,护士,女仆,模特,白领,巨乳,贫乳,美腿,黑丝,制服,痴女,群交,中出,颜射,口交,自慰,潮吹,调教,强奸,迷奸,痴汉,偷拍,野外,3P,多P,蕾丝,双性,无码,有码,中文字幕,无码流出,VR,4K,剧情,颜射,制服诱惑";

static ROOT_CACHE: Lazy<Mutex<Option<(String, std::time::Instant)>>> =
    Lazy::new(|| Mutex::new(None));
static TAG_CACHE: Lazy<Mutex<Option<(Vec<String>, std::time::Instant)>>> =
    Lazy::new(|| Mutex::new(None));

fn md5_hex(data: &[u8]) -> String {
    let mut h = Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 非 ASCII 字符按 UTF-8 字节转大写 `%XX`。
fn ascii(url: &str) -> String {
    let mut out = String::new();
    for ch in url.chars() {
        if (ch as u32) < 128 {
            out.push(ch);
        } else {
            let mut buf = [0u8; 4];
            for b in ch.encode_utf8(&mut buf).as_bytes() {
                out.push_str(&format!("%{b:02X}"));
            }
        }
    }
    out
}

fn sign(url: &str) -> String {
    let Some(qpos) = url.find('?') else {
        return url.to_string();
    };
    let query = &url[qpos + 1..];
    if query.contains("pub=") || query.contains("vv=") {
        return url.to_string();
    }
    let millis = now_millis();
    let input = format!(
        "{millis}&{}&{}",
        query.to_lowercase(),
        PRIV[(millis % 8) as usize]
    );
    let vv = md5_hex(input.as_bytes());
    format!("{url}&vv={vv}&pub={millis}")
}

async fn probe_root(root: &str) -> bool {
    let url = format!("https://api8.{root}/v3/list/MainMenuV3?cinema=2");
    let Some(c) = client().ok() else {
        return false;
    };
    let Ok(resp) = c
        .get(&ascii(&sign(&url)))
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{MAIN}/"))
        .header("Origin", MAIN)
        .send()
        .await
    else {
        return false;
    };
    if resp.status().as_u16() != 200 {
        return false;
    }
    let Ok(text) = resp.text().await else {
        return false;
    };
    text.contains("\"ret\":200") && text.contains("channelList")
}

async fn root() -> ApiResult<String> {
    {
        let guard = ROOT_CACHE.lock().unwrap();
        if let Some((r, t)) = guard.as_ref() {
            if t.elapsed().as_secs() < 1800 {
                return Ok(r.clone());
            }
        }
    }
    for r in ROOTS {
        if probe_root(r).await {
            let mut guard = ROOT_CACHE.lock().unwrap();
            *guard = Some((r.to_string(), std::time::Instant::now()));
            return Ok(r.to_string());
        }
    }
    Err(ApiError::Internal("午夜TV 全部域名不通".into()))
}

fn api_base(root: &str) -> String {
    format!("https://api8.{root}/api")
}

fn v3_base(root: &str) -> String {
    format!("https://api8.{root}/v3")
}

fn rank_base(root: &str) -> String {
    format!("https://rankv21.{root}/v3")
}

/// 带签名 GET；响应含 `data` 对象则返回它（`data.code==1` 时
/// 返回空），否则返回整个对象。
async fn api(base: &str, path: &str, query: &str) -> ApiResult<Value> {
    let url = if query.is_empty() {
        format!("{base}{path}")
    } else {
        format!("{base}{path}?{query}")
    };
    let resp = client()?
        .get(&ascii(&sign(&url)))
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{MAIN}/"))
        .header("Origin", MAIN)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("午夜TV 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if let Some(data) = get(&body, "data") {
        if data.is_object() {
            if get(data, "code").and_then(|v| v.as_i64()) == Some(1) {
                return Ok(Value::Null);
            }
            return Ok(data.clone());
        }
    }
    Ok(body)
}

fn abs_pic(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{STATIC}{u}")
    } else {
        u.to_string()
    }
}

fn strip_tags(s: &str) -> String {
    let tag = Regex::new(r"<[^>]*>").unwrap();
    let collapsed = Regex::new(r"\s+").unwrap();
    collapsed
        .replace_all(tag.replace_all(s, " ").as_ref(), " ")
        .trim()
        .to_string()
}

fn fmt_count(n: i64) -> String {
    if n >= 10000 {
        format!("{:.1}万", n as f64 / 10000.0)
    } else {
        n.to_string()
    }
}

fn card(row: &Value) -> Value {
    let id = text_of(row, &["key"]);
    let id = if id.is_empty() {
        text_of(row, &["contxt"])
    } else {
        id
    };
    let id = if id.is_empty() {
        text_of(row, &["link"])
    } else {
        id
    };
    let id = if id.is_empty() {
        text_of(row, &["videoKey"])
    } else {
        id
    };
    let title = strip_tags(&text_of(row, &["title"]));
    let mut cover = text_of(row, &["image"]);
    if cover.is_empty() {
        cover = text_of(row, &["imgPath"]);
    }
    let cover = abs_pic(&cover);
    let mut remark = text_of(row, &["starring"]);
    if remark.is_empty() {
        if let Some(stars) = get(row, "stars").and_then(arr_of) {
            let names: Vec<String> = stars
                .iter()
                .map(|s| text_of(s, &["name"]))
                .filter(|n| !n.is_empty())
                .collect();
            remark = names.join(" / ");
        }
    }
    let sno = text_of(row, &["sNo"]);
    if !sno.is_empty() && !sno.contains('*') {
        if !remark.is_empty() {
            remark.push(' ');
        }
        remark.push_str(&sno);
    }
    let mut type_name = text_of(row, &["videoType"]);
    if type_name.is_empty() {
        type_name = text_of(row, &["atypeName"]);
    }
    if type_name.is_empty() {
        if let Some(tags) = get(row, "tags").and_then(arr_of) {
            if let Some(first) = tags.first() {
                type_name = text_of(first, &["label"]);
            }
        }
    }
    let mut item = item_json(&id, &title, &cover, &remark);
    item["type_name"] = json!(type_name);
    item
}

fn cards_from_info(body: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    if let Some(info) = get(body, "info").and_then(arr_of) {
        for row in info {
            let item = card(row);
            if !item["id"].as_str().unwrap_or("").is_empty() {
                items.push(item);
            }
        }
    }
    items
}

async fn list_page(cid: &str, tag: Option<&str>, page: i64) -> ApiResult<Vec<Value>> {
    let root = root().await?;
    let base = api_base(&root);
    let mut query = format!("cinema=2&page={page}&cid={cid}&size=30&isn=0&isfree=-1");
    if let Some(t) = tag {
        let enc = url::form_urlencoded::byte_serialize(t.as_bytes()).collect::<String>();
        query.push_str(&format!("&tags={enc}"));
    }
    let body = api(&base, "/list/index", &query).await?;
    Ok(cards_from_info(&body))
}

async fn tag_names() -> Vec<String> {
    {
        let guard = TAG_CACHE.lock().unwrap();
        if let Some((tags, t)) = guard.as_ref() {
            if t.elapsed().as_secs() < 1800 {
                return tags.clone();
            }
        }
    }
    let mut tags: Vec<String> = FALLBACK_TAGS.split(',').map(|s| s.to_string()).collect();
    if let Ok(root) = root().await {
        let base = api_base(&root);
        if let Ok(body) = api(&base, "/list/allinonetype", "cinema=2").await {
            if let Some(info) = get(&body, "info").and_then(arr_of) {
                if let Some(first) = info.first() {
                    if let Some(fav) = get(first, "fav").and_then(arr_of) {
                        let mut fetched = Vec::new();
                        for f in fav {
                            let name = text_of(f, &["className"]);
                            if !name.is_empty() && name.chars().count() <= 12 {
                                fetched.push(name);
                            }
                        }
                        if !fetched.is_empty() {
                            tags = fetched;
                        }
                    }
                }
            }
        }
    }
    let mut guard = TAG_CACHE.lock().unwrap();
    *guard = Some((tags.clone(), std::time::Instant::now()));
    tags
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("0,2", "🆕 最新上架"),
        category_json("__rank", "🔥 人气排行"),
    ];
    for (cid, name) in MAIN_CATS {
        list.push(category_json(cid, name));
    }
    list.push(category_json("__stars", "⭐ 女优大全"));
    for tag in tag_names().await {
        list.push(category_json(&format!("tag:{tag}"), &tag));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let root = root().await?;
    let base = api_base(&root);
    if category_id == "__rank" {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let body = api(&base, "/home/GetPlayRank", "").await?;
        let items = cards_from_info(&body);
        return Ok(json!({"items": items, "has_more": false}));
    }
    if category_id == "__stars" {
        let body = api(
            &base,
            "/list/starlist",
            &format!("cinema=2&page={page}&size=42&orderBy=0&desc=1"),
        )
        .await?;
        let mut items = Vec::new();
        if let Some(info) = get(&body, "info").and_then(arr_of) {
            if let Some(first) = info.first() {
                if let Some(list) = get(first, "list").and_then(arr_of) {
                    for star in list {
                        let name = text_of(star, &["name"]);
                        if name.is_empty() {
                            continue;
                        }
                        let count = get(star, "count").and_then(|v| v.as_i64()).unwrap_or(0);
                        let cover = abs_pic(&text_of(star, &["imgPath"]));
                        let mut item = item_json(
                            &format!("star:{name}"),
                            &name,
                            &cover,
                            &format!("{count} 部作品"),
                        );
                        item["is_folder"] = json!(true);
                        items.push(item);
                    }
                }
            }
        }
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    if let Some(name) = category_id.strip_prefix("star:") {
        return search_by_star(name, page).await;
    }
    if let Some(tag) = category_id.strip_prefix("tag:") {
        let items = list_page("0,2", Some(tag), page).await?;
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    let cid = if category_id.is_empty() {
        "0,2"
    } else {
        category_id
    };
    let items = list_page(cid, None, page).await?;
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

async fn search_page(
    keyword: Option<&str>,
    star: Option<&str>,
    page: i64,
) -> ApiResult<(Vec<Value>, i64)> {
    let root = root().await?;
    let base = rank_base(&root);
    let mut query = format!("cinema=2&page={page}&size=30&orderby=0&desc=1");
    if let Some(kw) = keyword {
        let enc = url::form_urlencoded::byte_serialize(kw.as_bytes()).collect::<String>();
        query.push_str(&format!("&tags={enc}"));
    }
    if let Some(s) = star {
        let enc = url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>();
        query.push_str(&format!("&star={enc}"));
    }
    let body = api(&base, "/list/briefsearch", &query).await?;
    let mut items = Vec::new();
    let mut max_page = 0i64;
    if let Some(info) = get(&body, "info").and_then(arr_of) {
        if let Some(first) = info.first() {
            if let Some(result) = get(first, "result").and_then(arr_of) {
                for row in result {
                    let item = card(row);
                    if !item["id"].as_str().unwrap_or("").is_empty() {
                        items.push(item);
                    }
                }
            }
            max_page = get(first, "maxpage").and_then(|v| v.as_i64()).unwrap_or(0);
        }
    }
    Ok((items, max_page))
}

async fn search_by_star(name: &str, page: i64) -> ApiResult<Value> {
    let (items, max_page) = search_page(None, Some(name), page).await?;
    let has_more = if max_page > 0 {
        page < max_page
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if series_id.starts_with("star_") {
        return Ok(json!({
            "id": series_id,
            "title": "",
            "cover": "",
            "synopsis": "",
            "extra": {},
            "episodes": [],
        }));
    }
    let root = root().await?;
    let base = v3_base(&root);
    let enc = url::form_urlencoded::byte_serialize(series_id.as_bytes()).collect::<String>();
    let body = api(
        &base,
        "/video/detail",
        &format!("id={enc}&ispath=false&cinema=2&device=desktop&player=CkPlayer&tech=HLS&v=1"),
    )
    .await?;
    let info = get(&body, "info")
        .and_then(arr_of)
        .and_then(|a| a.first().cloned());
    let Some(info) = info else {
        return Err(ApiError::Internal("午夜TV 详情为空".into()));
    };
    let title = strip_tags(&text_of(&info, &["title"]));
    let cover = abs_pic(&text_of(&info, &["imgPath"]));
    let channel = text_of(&info, &["channel"]);
    let video_type = text_of(&info, &["videoType"]);
    let cid = text_of(&info, &["cid"]);
    let cat_name = MAIN_CATS
        .iter()
        .find(|(c, _)| cid.starts_with(c))
        .map(|(_, n)| n.to_string())
        .unwrap_or_else(|| {
            if cid.starts_with("0,2,10") || cid.starts_with("0,2") {
                "午夜精选".to_string()
            } else {
                String::new()
            }
        });
    let mut stars = Vec::new();
    if let Some(arr) = get(&info, "stars").and_then(arr_of) {
        for s in arr {
            let name = text_of(s, &["name"]);
            if !name.is_empty() {
                stars.push(name);
            }
        }
    }
    let mut labels = Vec::new();
    if let Some(arr) = get(&info, "tags").and_then(arr_of) {
        for t in arr {
            let label = text_of(t, &["label"]);
            if !label.is_empty() {
                labels.push(label);
            }
        }
    }
    let sno = text_of(&info, &["sNo"]);
    let add_date = text_of(&info, &["add_date"]);
    let view = get(&info, "view").and_then(|v| v.as_i64()).unwrap_or(0);
    let good = get(&info, "good").and_then(|v| v.as_i64()).unwrap_or(0);
    let fav_count = get(&info, "favoriteCount")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let publisher = text_of(&info, &["publisher", "title"]);
    let keyword = text_of(&info, &["keyWord"]);
    let mut synopsis = String::new();
    if !cat_name.is_empty() {
        synopsis.push_str(&format!("分类：{cat_name}\n"));
    }
    if !channel.is_empty() {
        synopsis.push_str(&format!("频道：{channel}\n"));
    }
    if !video_type.is_empty() {
        synopsis.push_str(&format!("类型：{video_type}\n"));
    }
    if !stars.is_empty() {
        synopsis.push_str(&format!("女优：{}\n", stars.join("、")));
    }
    if !labels.is_empty() {
        synopsis.push_str(&format!("标签：{}\n", labels.join("、")));
    }
    if !sno.is_empty() {
        synopsis.push_str(&format!("番号：{sno}\n"));
    }
    if !add_date.is_empty() {
        synopsis.push_str(&format!("日期：{add_date}\n"));
    }
    if view > 0 {
        synopsis.push_str(&format!("播放：{}\n", fmt_count(view)));
    }
    if good > 0 {
        synopsis.push_str(&format!("点赞：{}\n", fmt_count(good)));
    }
    if fav_count > 0 {
        synopsis.push_str(&format!("收藏：{}\n", fmt_count(fav_count)));
    }
    if !publisher.is_empty() {
        synopsis.push_str(&format!("发布：{publisher}\n"));
    }
    if !keyword.is_empty() {
        synopsis.push_str(&format!("关键词：{keyword}\n"));
    }
    synopsis.push_str("来源：午夜TV");
    let episodes = lines(series_id).await?;
    if episodes.is_empty() {
        return Err(ApiError::Internal("午夜TV 详情未取到播放线路".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { format!("午夜TV {series_id}") } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"actor": stars.join("、"), "category": cat_name},
        "episodes": episodes,
    }))
}

async fn play_info(video_id: &str) -> ApiResult<Value> {
    let root = root().await?;
    let base = v3_base(&root);
    let enc = url::form_urlencoded::byte_serialize(video_id.as_bytes()).collect::<String>();
    api(
        &base,
        "/video/play",
        &format!("id={enc}&cinema=2&a=1&lang=cns&device=1&region=GL.&usersign=1"),
    )
    .await
}

async fn lines(video_id: &str) -> ApiResult<Vec<Value>> {
    let body = play_info(video_id).await?;
    let info = get(&body, "info")
        .and_then(arr_of)
        .and_then(|a| a.first().cloned());
    let Some(info) = info else {
        return Ok(Vec::new());
    };
    let mut episodes = Vec::new();
    if let Some(clarity) = get(&info, "clarity").and_then(arr_of) {
        for c in clarity {
            let key = text_of(c, &["key"]);
            let title = text_of(c, &["title"]);
            let desc = text_of(c, &["description"]);
            let name = if !title.is_empty() {
                title
            } else if !desc.is_empty() {
                desc
            } else {
                format!("线路{key}")
            };
            episodes.push(episode_json(
                &format!("m|{video_id}|{key}"),
                &name,
                video_id,
            ));
        }
    }
    if let Some(flv) = get(&info, "flvPathList").and_then(arr_of) {
        for f in flv {
            let is_hls = get(f, "isHls").and_then(|v| v.as_bool()).unwrap_or(false);
            if is_hls {
                episodes.push(episode_json(
                    &format!("m|{video_id}|"),
                    "HLS 直连",
                    video_id,
                ));
                break;
            }
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("m|{video_id}|"), "正片", video_id));
    }
    Ok(episodes)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let (items, _max) = search_page(Some(query), None, 1).await?;
    if !items.is_empty() {
        return Ok(json!({"items": items}));
    }
    let (items2, _) = search_page(None, Some(query), 1).await?;
    Ok(json!({"items": items2}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let parts: Vec<&str> = video_id.split('|').collect();
    if parts.len() < 2 || parts[0] != "m" {
        return Ok(json!({"url": video_id}));
    }
    let vid = parts[1];
    let key = if parts.len() > 2 { parts[2] } else { "" };
    let body = play_info(vid).await?;
    let info = get(&body, "info")
        .and_then(arr_of)
        .and_then(|a| a.first().cloned());
    let Some(info) = info else {
        return Err(ApiError::Internal("午夜TV 未取到播放信息".into()));
    };
    let mut url = String::new();
    if let Some(clarity) = get(&info, "clarity").and_then(arr_of) {
        let mut chosen: Option<&Value> = None;
        if !key.is_empty() {
            chosen = clarity.iter().find(|c| text_of(c, &["key"]) == key);
        }
        if chosen.is_none() {
            chosen = clarity.iter().rev().find(|c| {
                let path = get(c, "path").cloned().unwrap_or(Value::Null);
                !text_of(&path, &["result"]).is_empty()
                    || !text_of(&path, &["dashResult"]).is_empty()
            });
        }
        if let Some(c) = chosen {
            let path = get(c, "path").cloned().unwrap_or(Value::Null);
            url = text_of(&path, &["result"]);
            if url.is_empty() {
                url = text_of(&path, &["dashResult"]);
            }
        }
    }
    if url.is_empty() {
        if let Some(flv) = get(&info, "flvPathList").and_then(arr_of) {
            for f in flv {
                let is_hls = get(f, "isHls").and_then(|v| v.as_bool()).unwrap_or(false);
                if !is_hls {
                    url = text_of(f, &["result"]);
                    if !url.is_empty() {
                        break;
                    }
                }
            }
            if url.is_empty() {
                for f in flv {
                    url = text_of(f, &["result"]);
                    if !url.is_empty() {
                        break;
                    }
                }
            }
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("午夜TV 未取到播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_percent_encodes_non_ascii() {
        assert_eq!(ascii("abc"), "abc");
        assert_eq!(ascii("中文"), "%E4%B8%AD%E6%96%87");
        assert_eq!(ascii("a/b?x=中"), "a/b?x=%E4%B8%AD");
    }

    #[test]
    fn sign_appends_vv_and_pub() {
        let url = "https://api8.wuye.tv/v3/list/MainMenuV3?cinema=2";
        let signed = sign(url);
        assert!(signed.contains("&vv="));
        assert!(signed.contains("&pub="));
        assert!(signed.starts_with(url));
        // 已带 pub/vv 的不重复追加。
        assert_eq!(sign(&signed), signed);
    }

    #[test]
    fn fallback_tags_have_no_lolita() {
        assert!(!FALLBACK_TAGS.contains("萝莉"));
        assert!(!FALLBACK_TAGS.contains("少女"));
    }

    #[test]
    fn card_parses_info_row() {
        let row = json!({
            "key": "abc123",
            "title": "Test <em>Title</em>",
            "image": "//static.wuye.tv/1.jpg",
            "starring": "Actor A",
            "sNo": "ABC-001",
            "videoType": "日本"
        });
        let item = card(&row);
        assert_eq!(item["id"], "abc123");
        assert_eq!(item["title"], "Test Title");
        assert_eq!(item["cover"], "https://static.wuye.tv/1.jpg");
        assert_eq!(item["remark"], "Actor A ABC-001");
        assert_eq!(item["type_name"], "日本");
    }
}
