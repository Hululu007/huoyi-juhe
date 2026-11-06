//! AVCNN：Next.js 站（avcnn.com），列表走 __next_f flight 数据，
//! 详情与取流走 /zh-CN/api/v1/article(-video) 接口。
//!
//! 分类与站导航 1:1（21 项，含女优分类 actors）；女优详情按作品卡片
//! 展示。取流失败时的跨站 chain（7mm/JavGuru/123av/Av6k）因核心里
//! 无这些站，无法复现，取不到时如实报错。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const BASE: &str = "https://avcnn.com";
const LANG: &str = "/zh-CN";
const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 静态分类：type_id -> 名，与站导航一致。
const CATS: &[(&str, &str)] = &[
    ("home", "最新上架"),
    ("actors", "女优"),
    ("t:mosaic", "有码"),
    ("t:uncensored", "无码"),
    (
        "p:/category/longfilm/european-and-american-uncensored",
        "欧美",
    ),
    ("p:/category/longfilm/hairless", "无毛"),
    ("p:/category/longfilm/featured-exclusive", "精选独家"),
    ("p:/category/longfilm/creampie-facial", "中出颜射"),
    ("p:/category/longfilm/masturbation-8", "自慰"),
    ("p:/category/longfilm/amateur-selfie", "素人自拍"),
    ("p:/category/longfilm/mature-woman-wife", "熟女人妻"),
    ("p:/category/longfilm/incest-3", "乱伦"),
    ("p:/category/longfilm/big-breasts-6", "巨乳美乳"),
    ("p:/category/longfilm/uniform", "制服"),
    ("p:/category/longfilm/female-6", "女性向"),
    ("p:/category/longfilm/small-breasts-4", "贫乳"),
    ("p:/category/longfilm/lesbian-8", "女同性恋"),
    ("p:/longfilm-rank", "长片排行"),
    ("p:/shortfilm-homepage", "短视频"),
    ("p:/shortfilm-rank", "短片排行"),
    ("s:FC2", "FC2"),
];

fn headers() -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", UA.to_string()),
        (
            "Accept",
            "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8".to_string(),
        ),
        ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
        ("Referer", format!("{BASE}/zh-CN")),
    ]
}

async fn get_text(url: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("AVCNN 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn get_json(url: &str) -> ApiResult<Value> {
    let text = get_text(url).await?;
    let body: Value = serde_json::from_str(&text)?;
    Ok(body)
}

fn abs_url(path: &str) -> String {
    if path.starts_with("http") {
        path.to_string()
    } else if path.starts_with('/') {
        format!("{BASE}{path}")
    } else {
        format!("{BASE}/{path}")
    }
}

/// 取出所有 self.__next_f.push([1,"..."]) 片段并反转义后拼接。
fn flight_text(html: &str) -> String {
    let mut out = String::new();
    let marker = "self.__next_f.push([1,\"";
    let mut rest = html;
    while let Some(pos) = rest.find(marker) {
        let start = pos + marker.len();
        let bytes = rest.as_bytes();
        let mut i = start;
        let mut end = None;
        while i < bytes.len() {
            match bytes[i] {
                b'\\' => i += 2,
                b'"' => {
                    end = Some(i);
                    break;
                }
                _ => i += 1,
            }
        }
        let Some(e) = end else { break };
        let raw = &rest[start..e];
        if let Ok(Value::String(s)) = serde_json::from_str::<Value>(&format!("\"{raw}\"")) {
            out.push_str(&s);
        }
        rest = &rest[e..];
    }
    out
}

/// 在 JSON 文本片段里取 "key":"..."（处理转义）。
fn field_str(chunk: &str, key: &str) -> String {
    let marker = format!("\"{key}\":\"");
    let Some(pos) = chunk.find(&marker) else {
        return String::new();
    };
    let start = pos + marker.len();
    let bytes = chunk.as_bytes();
    let mut i = start;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b'"' => {
                let raw = &chunk[start..i];
                if let Ok(Value::String(s)) = serde_json::from_str::<Value>(&format!("\"{raw}\"")) {
                    return s;
                }
                return raw.to_string();
            }
            _ => i += 1,
        }
    }
    String::new()
}

fn field_num(chunk: &str, key: &str) -> i64 {
    let marker = format!("\"{key}\":");
    let Some(pos) = chunk.find(&marker) else {
        return 0;
    };
    let rest = &chunk[pos + marker.len()..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit() && c != '-')
        .unwrap_or(rest.len());
    rest[..end].parse::<i64>().unwrap_or(0)
}

fn field_bool(chunk: &str, key: &str) -> bool {
    let marker = format!("\"{key}\":");
    chunk[chunk
        .find(&marker)
        .map(|p| p + marker.len())
        .unwrap_or(chunk.len())..]
        .starts_with("true")
}

/// flight 文本按 "uuid":" 切块解析影片；isActor 块按女优解析。
/// 封面在 flight 里是对象 {"url": "..."}，需取其 url 字段；
/// 非影片块（分类/标签）无 videoLength/videoCover/isFree，直接跳过。
fn parse_flight(text: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for chunk in text.split("\"uuid\":\"").skip(1) {
        let uuid_end = chunk.find('"').unwrap_or(chunk.len());
        let uuid = &chunk[..uuid_end];
        if uuid.len() < 5 || uuid.contains(' ') {
            continue;
        }
        if chunk.contains("\"isActor\":true") {
            let name = field_str(chunk, "name");
            if name.is_empty() {
                continue;
            }
            let cover = cover_url(chunk);
            let cup = field_str(chunk, "cup");
            let count = field_num(chunk, "count");
            let desc = field_str(chunk, "description");
            let mut remark = String::new();
            if !cup.is_empty() {
                remark.push_str(&cup);
            }
            if count > 0 {
                if !remark.is_empty() {
                    remark.push_str(" · ");
                }
                remark.push_str(&format!("{count} 部"));
            }
            if !desc.is_empty() {
                if !remark.is_empty() {
                    remark.push_str(" · ");
                }
                remark.push_str(&desc);
            }
            items.push(item_json(
                &format!("a:{uuid}"),
                &name,
                &abs_url(&cover),
                &remark,
            ));
            continue;
        }
        if !chunk.contains("\"videoLength\"")
            && !chunk.contains("\"isFree\"")
            && !chunk.contains("\"videoCover\"")
        {
            continue;
        }
        let title = field_str(chunk, "title");
        if title.is_empty() {
            continue;
        }
        let cover = cover_url(chunk);
        let code = field_str(chunk, "code");
        let code = if code.is_empty() {
            field_str(chunk, "slug")
        } else {
            code
        };
        let minutes = field_num(chunk, "videoLength") / 60;
        let date = field_str(chunk, "createdDate");
        let date = date.get(..10).unwrap_or(&date).to_string();
        let free = field_bool(chunk, "isFree");
        let mut remark = String::new();
        if !code.is_empty() {
            remark.push_str(&code);
        }
        if free {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str("免费");
        }
        if minutes > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("{minutes} 分钟"));
        }
        if !date.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&date);
        }
        items.push(item_json(uuid, &title, &abs_url(&cover), &remark));
    }
    items
}

/// 取封面 url：先 "videoCover":{"url": ...}，再 "cover":{"url": ...}，
/// 再退化为字符串字段。
fn cover_url(chunk: &str) -> String {
    for key in ["videoCover", "cover"] {
        let marker = format!("\"{key}\":{{\"url\":\"");
        if let Some(p) = chunk.find(&marker) {
            let s = p + marker.len();
            if let Some(e) = chunk[s..].find('"') {
                return chunk[s..s + e].to_string();
            }
        }
        let s = field_str(chunk, key);
        if !s.is_empty() {
            return s;
        }
    }
    String::new()
}

fn page_url(category_id: &str, page: i64) -> String {
    let page = page.to_string();
    if let Some(tag) = category_id.strip_prefix("t:") {
        return with_query(
            &format!("{BASE}/zh-CN/category/longfilm"),
            &[("tagUuid", tag), ("page", &page)],
        );
    }
    if let Some(path) = category_id.strip_prefix("p:") {
        let base = format!("{BASE}/zh-CN{path}");
        return if base.contains('?') {
            format!("{base}&page={page}")
        } else {
            format!("{base}?page={page}")
        };
    }
    if let Some(kw) = category_id.strip_prefix("s:") {
        return with_query(
            &format!("{BASE}/zh-CN/search"),
            &[("k", kw), ("page", &page)],
        );
    }
    if let Some(tag) = category_id.strip_prefix("a:") {
        return format!("{BASE}/zh-CN/tag/{tag}?page={page}");
    }
    match category_id {
        "actors" => format!("{BASE}/zh-CN/longfilm-actors-index?page={page}"),
        _ => format!("{BASE}/zh-CN?page={page}"),
    }
}

async fn parse_page(url: &str) -> ApiResult<Vec<Value>> {
    let html = get_text(url).await?;
    Ok(parse_flight(&flight_text(&html)))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = page_url(category_id, page);
    let items = parse_page(&url).await?;
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if let Some(tag) = series_id.strip_prefix("a:") {
        let url = format!("{BASE}/zh-CN/tag/{tag}?page=1");
        let items = parse_page(&url).await?;
        let name = items
            .first()
            .and_then(|i| i.get("title"))
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        let episodes: Vec<Value> = items
            .iter()
            .map(|i| {
                let id = text_of(i, &["id"]);
                let title = text_of(i, &["title"]);
                let remark = text_of(i, &["remark"]);
                let label = if remark.is_empty() {
                    title.clone()
                } else {
                    format!("{title}（{remark}）")
                };
                episode_json(&format!("{label}${id}"), &label, series_id)
            })
            .collect();
        let cover = items
            .first()
            .map(|i| text_of(i, &["cover"]))
            .unwrap_or_default();
        return Ok(json!({
            "id": series_id,
            "title": if name.is_empty() { "女优".to_string() } else { name },
            "cover": cover,
            "synopsis": "",
            "extra": {},
            "episodes": episodes,
        }));
    }
    let url = format!("{BASE}/zh-CN/api/v1/article/{series_id}");
    let body = get_json(&url).await?;
    let data = get(&body, "data").unwrap_or(&body);
    let title = text_of(data, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("AVCNN 未返回影片资料".into()));
    }
    let cover = match get(data, "videoCover").or_else(|| get(data, "cover")) {
        Some(v) if v.is_object() => text_of(v, &["url"]),
        Some(v) => super::str_of(v),
        None => String::new(),
    };
    let code = text_of(data, &["code", "uuid"]);
    let minutes = int_of(data, &["videoLength"]) / 60;
    let date = text_of(data, &["createdDate"]);
    let date = date.get(..10).unwrap_or(&date).to_string();
    let excerpt = text_of(data, &["excerpt", "description"]);
    let mut actors = Vec::new();
    if let Some(list) = get(data, "actors").and_then(arr_of) {
        for a in list {
            let n = text_of(a, &["name"]);
            if !n.is_empty() {
                actors.push(n);
            }
        }
    }
    let mut tags = Vec::new();
    if let Some(list) = get(data, "tags").and_then(arr_of) {
        for t in list {
            if text_of(t, &["isActor"]) == "true" {
                continue;
            }
            let n = text_of(t, &["name"]);
            if !n.is_empty() {
                tags.push(n);
            }
        }
    }
    let mut remark = String::new();
    if !code.is_empty() {
        remark.push_str(&code);
    }
    if minutes > 0 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str(&format!("{minutes} 分钟"));
    }
    if !date.is_empty() {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str(&date);
    }
    let mut extra = serde_json::Map::new();
    if !actors.is_empty() {
        extra.insert("actor".to_string(), json!(actors.join(" / ")));
    }
    if !tags.is_empty() {
        extra.insert("tag".to_string(), json!(tags.join(" / ")));
    }
    if !remark.is_empty() {
        extra.insert("remark".to_string(), json!(remark));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": abs_url(&cover),
        "synopsis": excerpt,
        "extra": extra,
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    let url = format!("{BASE}/zh-CN/api/v1/article-video/{video_id}");
    let body = get_json(&url).await?;
    let data = get(&body, "data").unwrap_or(&body);
    let play_url = text_of(data, &["url"]);
    if !play_url.is_empty() {
        return Ok(json!({
            "url": abs_url(&play_url),
            "header": {
                "User-Agent": UA,
                "Referer": format!("{BASE}/zh-CN/api/v1/article/{video_id}"),
            },
        }));
    }
    let preview = text_of(data, &["previewUrl"]);
    if !preview.is_empty() {
        return Err(ApiError::Internal(
            "AVCNN 该片仅提供试看（需会员），无完整播放地址".into(),
        ));
    }
    Err(ApiError::Internal(
        "AVCNN 未取到播放地址（跨站 chain 在核心里无对应站，无法复现）".into(),
    ))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/zh-CN/search"),
        &[("k", query), ("page", "1")],
    );
    let mut items = parse_page(&url).await?;
    if items.is_empty() {
        let url2 = format!("{url}&isLongfilm=-1&page=1");
        items = parse_page(&url2).await?;
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flight_unescapes_and_parses() {
        let html = r#"self.__next_f.push([1,"{\"uuid\":\"abc123\",\"title\":\"T1\",\"videoCover\":\"/c.jpg\",\"videoLength\":600,\"isFree\":true}"])"#;
        let text = flight_text(html);
        assert!(text.contains("\"uuid\":\"abc123\""));
        let items = parse_flight(&text);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "T1");
        assert_eq!(items[0]["remark"], "免费 · 10 分钟");
    }

    #[test]
    fn page_url_rules() {
        assert!(page_url("t:mosaic", 2).contains("tagUuid=mosaic"));
        assert!(page_url("p:/shortfilm-rank", 2).contains("page=2"));
        assert!(page_url("s:FC2", 1).contains("k=FC2"));
        assert!(page_url("actors", 1).contains("longfilm-actors-index"));
    }
}
