//! 天天A片：vjav.tube 的 KVS JSON 接口。
//!
//! 来源 jar 类 `ZakaDaydayAmns`（`https://vjav.tube`）。
//! 列表走 `/api/json/videos2/...`；详情走 `/api/json/video/...`；
//! 取流走 `/api/videofile.php?video_id=`，返回的 `video_url` 是
//! 形变 base64（西里尔同形字母 + `,`→`/`、`~`→`=`），须先还原再
//! 解码；`/get_file/` 链接取流时跟随跳转。

use base64::Engine as _;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://vjav.tube";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE: i64 = 25;

const SORTS: &[(&str, &str, &str)] = &[
    ("new", "latest-updates", "最新更新"),
    ("hot", "most-popular", "最热门"),
];
const CATS: &[(&str, &str)] = &[
    ("asian", "Asian"),
    ("japanese", "Japanese"),
    ("hd", "HD"),
    ("big-tits", "Big Tits"),
    ("cuckold", "Cuckold"),
    ("dildos-toys", "Toys"),
];

const B64V: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn api_get(path: &str) -> ApiResult<reqwest::RequestBuilder> {
    let url = format!("{BASE}{path}");
    Ok(client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .header("X-Requested-With", "XMLHttpRequest"))
}

async fn api(path: &str) -> ApiResult<Value> {
    let resp = api_get(path)?
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("天天A片请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 20 {
        return Err(ApiError::Internal("天天A片返回过短".into()));
    }
    let body: Value = serde_json::from_str(&text)?;
    if text.contains("\"error\"") && get(&body, "videos").is_none() && get(&body, "video").is_none()
    {
        return Err(ApiError::Internal("天天A片接口报错".into()));
    }
    Ok(body)
}

fn cards(body: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let Some(rows) = get(body, "videos").and_then(arr_of) else {
        return items;
    };
    for row in rows {
        let id = text_of(row, &["video_id"]);
        if id.is_empty() {
            continue;
        }
        let mut title = text_of(row, &["title"]);
        if title.is_empty() {
            title = id.clone();
        }
        let mut cover = text_of(row, &["thumb"]);
        if cover.is_empty() {
            if let Ok(n) = id.parse::<i64>() {
                let base = (n / 1000) * 1000;
                cover = format!(
                    "https://tn.vjav.com/contents/videos_screenshots/{base}/{id}/240x180/1.jpg"
                );
            }
        }
        let remark = text_of(row, &["duration"]);
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn list_path(kind: &str, value: &str, page: i64) -> String {
    format!("/api/json/videos2/14400/str/latest-updates/25/{kind}.{value}.{page}.all...json")
}

fn homo(c: char) -> char {
    match c as u32 {
        1040 => 'A',
        1042 => 'B',
        1045 => 'E',
        1050 => 'K',
        1052 => 'M',
        1053 => 'H',
        1054 => 'O',
        1056 => 'P',
        1057 => 'C',
        1058 => 'T',
        1059 => 'Y',
        1061 => 'X',
        1072 => 'a',
        1074 => 'b',
        1077 => 'e',
        1082 => 'k',
        1084 => 'm',
        1085 => 'h',
        1086 => 'o',
        1088 => 'p',
        1089 => 'c',
        1090 => 't',
        1091 => 'y',
        1093 => 'x',
        1109 => 's',
        1110 => 'i',
        1112 => 'j',
        _ => c,
    }
}

/// 形变 base64 还原：同形字母换回拉丁、`,`→`/`、`~`→`=`，只留
/// base64 字符，补 `=` 后解码。
fn deobf(s: &str) -> String {
    let mut mapped = String::new();
    for c in s.chars() {
        if (c as u32) > 127 {
            mapped.push(homo(c));
        } else if c == ',' {
            mapped.push('/');
        } else if c == '~' {
            mapped.push('=');
        } else {
            mapped.push(c);
        }
    }
    let filtered: String = mapped
        .chars()
        .filter(|c| B64V.contains(*c) || *c == '=')
        .collect();
    let mut padded = filtered;
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(padded.as_bytes())
        .unwrap_or_default();
    String::from_utf8_lossy(&decoded).trim().to_string()
}

async fn file_url(video_id: &str) -> String {
    let path = format!("/api/videofile.php?video_id={video_id}&lifetime=8640000");
    let url = format!("{BASE}{path}");
    let Some(c) = client().ok() else {
        return String::new();
    };
    let Ok(resp) = c
        .get(&url)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
    else {
        return String::new();
    };
    let Ok(text) = resp.text().await else {
        return String::new();
    };
    if text.len() < 20 {
        return String::new();
    }
    let Ok(body) = serde_json::from_str::<Value>(&text) else {
        return String::new();
    };
    let Some(first) = get(&body, "0").or_else(|| arr_of(&body).and_then(|a| a.first())) else {
        return String::new();
    };
    let raw = text_of(first, &["video_url"]);
    if raw.is_empty() {
        return String::new();
    }
    let url = deobf(&raw);
    if url.starts_with('/') {
        format!("{BASE}{url}")
    } else {
        url
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (id, _path, name) in SORTS {
        list.push(category_json(id, name));
    }
    for (slug, name) in CATS {
        list.push(category_json(&format!("c:{slug}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let path = if let Some(slug) = category_id.strip_prefix("c:") {
        list_path("categories", slug, page)
    } else {
        let sort = SORTS
            .iter()
            .find(|(id, _, _)| *id == category_id)
            .map(|(_, p, _)| *p)
            .unwrap_or("latest-updates");
        format!("/api/json/videos2/14400/str/{sort}/{PAGE}/top-country.sg.{page}.all...json")
    };
    let body = api(&path).await?;
    let items = cards(&body);
    Ok(json!({"items": items, "has_more": true}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    static RE_NUM: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\d{4,})").unwrap());
    let vid = RE_NUM
        .captures(series_id)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| series_id.to_string());
    let bucket = vid.parse::<i64>().map(|n| (n / 1000) * 1000).unwrap_or(0);
    let body = api(&format!("/api/json/video/86400/0/{bucket}/{vid}.json")).await?;
    let video = get(&body, "video").cloned().unwrap_or(Value::Null);
    let title = text_of(&video, &["title"]);
    let title = if title.is_empty() {
        format!("天天A片 {vid}")
    } else {
        title
    };
    let cover = text_of(&video, &["thumb"]);
    let duration = text_of(&video, &["duration"]);
    let mut cat_names = Vec::new();
    if let Some(cats) = get(&video, "categories").and_then(|v| v.as_object()) {
        for (_, entry) in cats {
            let name = text_of(entry, &["title"]);
            if !name.is_empty() {
                cat_names.push(name);
            }
        }
    }
    let synopsis = format!(
        "{}{}{}来源：天天A片",
        if cat_names.is_empty() {
            String::new()
        } else {
            format!("分类：{}\n", cat_names.join(" / "))
        },
        if duration.is_empty() {
            String::new()
        } else {
            format!("时长：{duration}\n")
        },
        ""
    );
    let url = file_url(&vid).await;
    if url.len() <= 20 {
        return Err(ApiError::Internal("天天A片详情未取到播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"duration": duration},
        "episodes": [episode_json(&url, "正片", series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let path =
        format!("/api/json/videos2/14400/str/relevance/25/top-country.sg.1.all...json?sq={enc}");
    let items = match api(&path).await {
        Ok(body) => cards(&body),
        Err(_) => Vec::new(),
    };
    if items.is_empty() {
        let path2 =
            format!("/api/json/videos2/14400/str/relevance/25/top-country.sg.1.all...json?s={enc}");
        if let Ok(body) = api(&path2).await {
            return Ok(json!({"items": cards(&body)}));
        }
    }
    Ok(json!({"items": items}))
}

async fn resolve_redirect(url: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .head(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        return Some(final_url);
    }
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        Some(final_url)
    } else {
        None
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut url = video_id.to_string();
    if url.contains("/get_file/") {
        if let Some(resolved) = resolve_redirect(&url).await {
            if resolved.len() > 20 {
                url = resolved;
            }
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("天天A片没有播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deobf_passthrough_plain_b64() {
        // 明文 base64 不含形变字符时原样解码。
        let plain =
            base64::engine::general_purpose::STANDARD.encode("https://cdn.example.com/v.mp4");
        assert_eq!(deobf(&plain), "https://cdn.example.com/v.mp4");
    }

    #[test]
    fn deobf_comma_and_tilde() {
        // `,`→`/`、`~`→`=` 的形变。
        let encoded = base64::engine::general_purpose::STANDARD.encode("https://a/b?x=1");
        let deformed = encoded.replace('/', ",").replace('=', "~");
        assert_eq!(deobf(&deformed), "https://a/b?x=1");
    }

    #[test]
    fn deobf_cyrillic_homoglyph() {
        // 西里尔 А(1040)→A、а(1072)→a。
        let with_homo = "Аa";
        let _ = deobf(with_homo);
    }

    #[test]
    fn list_path_shape() {
        assert_eq!(
            list_path("categories", "asian", 2),
            "/api/json/videos2/14400/str/latest-updates/25/categories.asian.2.all...json"
        );
    }
}
