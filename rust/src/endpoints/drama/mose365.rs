//! 魔色365：核心里的影视区站点。
//!
//! 入口域名 exwxfmd4.work（站内自称魔色365.CC，正域名 madou365.cc，
//! 同一后端）；站是 JS 单页应用，但公开 JSON 接口可直接调，无登录、
//! 无付费墙（抽查视频 is_vip 为 0，首页/分类/搜索三处 JSON 里根本
//! 没有 is_vip 字段）。
//! - 分类 4 个，与首页接口 sections 1:1：MissAV、XVideos、XNXX、
//!   Eporner；每页 24 条，MissAV 总量 2661。
//! - 目录：GET /api/public/category/<slug>?page=<n>&pageSize=24，
//!   封面为站内 /uploads/covers/... 相对路径。
//! - 详情：GET /api/public/video/<id>，取流字段 source_url 是
//!   <scheme>://<source_id> 形式（如 missav-stream://hawa-389），
//!   对应取流端点 /api/public/<scheme>/<source_id>，实测回 200、
//!   Content-Type 为 application/vnd.apple.mpegurl 的主清单
//!   （360p/480p 变体走 /api/public/missav-proxy?url=<base64>）。
//! - 搜索：GET /api/public/search?q=<词>&page=1，实测“美女”共 99 条。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const BASE: &str = "https://exwxfmd4.work";
const API: &str = "https://exwxfmd4.work/api/public";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 分类静态回退：与首页接口 sections 一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("missav", "MissAV"),
    ("xvideos", "XVideos"),
    ("xnxx", "XNXX"),
    ("eporner", "Eporner"),
];

async fn get_json(url: &str) -> ApiResult<Value> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("魔色365请求 HTTP {status}")));
    }
    resp.json::<Value>()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 封面归一：站内相对路径补基址。
fn fix_cover(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    format!("{BASE}/{u}")
}

/// 取流地址归一：直链原样回；<scheme>://<id> 拼成站内取流端点。
fn resolve_stream(source_url: &str) -> String {
    let u = source_url.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u.to_string();
    }
    if let Some((scheme, rest)) = u.split_once("://") {
        if !scheme.is_empty() && !rest.is_empty() {
            return format!("{API}/{scheme}/{rest}");
        }
    }
    String::new()
}

fn parse_videos(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let Some(list) = get(data, "videos").and_then(arr_of) else {
        return items;
    };
    for v in list {
        let id = text_of(v, &["id"]);
        let title = text_of(v, &["title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = fix_cover(&text_of(v, &["cover"]));
        let remark = text_of(v, &["source_name"]);
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
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
    match get_json(&format!("{API}/home")).await {
        Ok(root) => {
            let mut list = Vec::new();
            if let Some(data) = get(&root, "data") {
                if let Some(sections) = get(data, "sections").and_then(arr_of) {
                    for s in sections {
                        let slug = text_of(s, &["slug"]);
                        let name = text_of(s, &["name"]);
                        if slug.is_empty() || name.is_empty() {
                            continue;
                        }
                        list.push(category_json(&slug, &name));
                    }
                }
            }
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
    let url = with_query(
        &format!("{API}/category/{category_id}"),
        &[("page", &page.to_string()), ("pageSize", "24")],
    );
    let root = get_json(&url).await?;
    let Some(data) = get(&root, "data") else {
        return Err(ApiError::Internal("魔色365分类接口未返回数据".into()));
    };
    let items = parse_videos(data);
    let total = int_of(data, &["total"]);
    let has_more = total > 0 && page * 24 < total;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim()
        .trim_start_matches("/video/")
        .trim_end_matches('/');
    let root = get_json(&format!("{API}/video/{id}")).await?;
    let Some(video) = get(&root, "data").and_then(|d| get(d, "video")) else {
        return Err(ApiError::Internal("魔色365详情接口未返回视频".into()));
    };
    let title = text_of(video, &["title"]);
    let cover = fix_cover(&text_of(video, &["cover"]));
    let source_url = text_of(video, &["source_url"]);
    let stream = resolve_stream(&source_url);
    if title.is_empty() || stream.is_empty() {
        return Err(ApiError::Internal("魔色365未返回可播放地址".into()));
    }
    let mut synopsis = text_of(video, &["description"]);
    if synopsis.is_empty() {
        synopsis = title.clone();
    }
    let duration = int_of(video, &["duration"]);
    let views = int_of(video, &["view_count"]);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {
            "duration": duration,
            "views": views,
            "source_name": text_of(video, &["source_name"]),
            "category_name": text_of(video, &["category_name"]),
            "tags": text_of(video, &["tags"]),
            "published_at": text_of(video, &["published_at"]),
        },
        "episodes": [episode_json(&stream, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("魔色365该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{API}/search"), &[("q", query), ("page", "1")]);
    let root = get_json(&url).await?;
    let Some(data) = get(&root, "data") else {
        return Ok(json!({"items": []}));
    };
    Ok(json!({"items": parse_videos(data)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_cover_cases() {
        assert_eq!(
            fix_cover("/uploads/covers/missav/hawa-389.jpg"),
            "https://exwxfmd4.work/uploads/covers/missav/hawa-389.jpg"
        );
        assert_eq!(
            fix_cover("https://madou365.cc/uploads/covers/missav/hawa-389.jpg"),
            "https://madou365.cc/uploads/covers/missav/hawa-389.jpg"
        );
        assert_eq!(fix_cover(""), "");
    }

    #[test]
    fn resolve_stream_cases() {
        assert_eq!(
            resolve_stream("missav-stream://hawa-389"),
            "https://exwxfmd4.work/api/public/missav-stream/hawa-389"
        );
        assert_eq!(
            resolve_stream("ph-stream://abc123"),
            "https://exwxfmd4.work/api/public/ph-stream/abc123"
        );
        assert_eq!(
            resolve_stream("https://x.y/z/index.m3u8"),
            "https://x.y/z/index.m3u8"
        );
        assert_eq!(resolve_stream(""), "");
        assert_eq!(resolve_stream("://x"), "");
    }

    #[test]
    fn parse_home_sections_real_sample() {
        let root: Value = serde_json::from_str(
            r#"{"code":200,"data":{"sections":[
                {"name":"MissAV","slug":"missav","videos":[]},
                {"name":"XVideos","slug":"xvideos","videos":[]},
                {"name":"XNXX","slug":"xnxx","videos":[]},
                {"name":"Eporner","slug":"eporner","videos":[]}
            ]}}"#,
        )
        .unwrap();
        let data = get(&root, "data").unwrap();
        let sections = get(data, "sections").and_then(arr_of).unwrap();
        assert_eq!(sections.len(), 4);
        assert_eq!(text_of(&sections[0], &["slug"]), "missav");
        assert_eq!(text_of(&sections[3], &["name"]), "Eporner");
        assert_eq!(
            fallback_categories()["categories"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
    }

    #[test]
    fn parse_videos_real_sample() {
        let data: Value = serde_json::from_str(
            r#"{"category":{"id":2,"name":"MissAV","slug":"missav"},"videos":[
                {"id":7542,"title":"DLDSS-572 从早上9点先生上班后到下午6点，我都在忙著和公公进行无保护性行为，希望抱孙子。 ——美咲香奈","cover":"/uploads/covers/missav/dldss-572.jpg","source_name":"MissAV","view_count":326111},
                {"id":7538,"title":"HNHU-225 一位身材娇小、胸围仅48厘米、拥有G罩杯的肉食性女性","cover":"/uploads/covers/missav/hnhu-225.jpg","source_name":"MissAV","view_count":287946}
            ],"total":2661,"page":1,"pageSize":24}"#,
        )
        .unwrap();
        let items = parse_videos(&data);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "7542");
        assert_eq!(
            items[0]["cover"],
            "https://exwxfmd4.work/uploads/covers/missav/dldss-572.jpg"
        );
        assert_eq!(items[0]["remark"], "MissAV");
        assert_eq!(int_of(&data, &["total"]), 2661);
        assert!(1 * 24 < 2661);
    }

    #[test]
    fn parse_video_detail_real_sample() {
        let video: Value = serde_json::from_str(
            r#"{"id":7520,"category_id":2,"title":"HAWA-389 “皮恩妻子”的人体马桶训练：由乃（24岁）","cover":"/uploads/covers/missav/hawa-389.jpg","description":"","source_url":"missav-stream://hawa-389","source_name":"MissAV","duration":9971,"tags":"HAWA,389","view_count":384944,"is_vip":0,"category_name":"MissAV"}"#,
        )
        .unwrap();
        assert_eq!(
            text_of(&video, &["title"])
                .chars()
                .take(8)
                .collect::<String>(),
            "HAWA-389"
        );
        assert_eq!(int_of(&video, &["duration"]), 9971);
        assert_eq!(
            resolve_stream(&text_of(&video, &["source_url"])),
            "https://exwxfmd4.work/api/public/missav-stream/hawa-389"
        );
        assert_eq!(int_of(&video, &["is_vip"]), 0);
    }

    #[test]
    fn parse_search_real_sample() {
        let data: Value = serde_json::from_str(
            r#"{"videos":[
                {"id":5576,"title":"游戏日期 和 一个惊人的 美丽 美女 亲吻 公共场合","cover":"/uploads/covers/xnxx/1i8i5dd8.jpg","source_name":"XNXX"},
                {"id":4821,"title":"微缩 日本 美女被浇油了","cover":"/uploads/covers/xvideos/opfoevuf235.jpg","source_name":"XVideos"}
            ],"total":99}"#,
        )
        .unwrap();
        let items = parse_videos(&data);
        assert_eq!(items.len(), 2);
        assert_eq!(items[1]["id"], "4821");
        assert_eq!(int_of(&data, &["total"]), 99);
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://exwxfmd4.work/api/public/missav-stream/hawa-389").unwrap();
        assert_eq!(
            ok["url"],
            "https://exwxfmd4.work/api/public/missav-stream/hawa-389"
        );
        assert!(play_check("hawa-389").is_err());
    }
}
