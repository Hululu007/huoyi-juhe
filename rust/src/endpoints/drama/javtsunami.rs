//! JAV Tsunami（javtsunami.com）：WordPress 站，列表与详情走 HTML 解析。
//! 取流：详情页 3 个 iframe（HG/DS/VD），`src="about:blank"`，
//! 真地址须拿 `data-server-token` 去解析口子换：
//! `POST https://javtsunami.com/wp-json/jw-dom-tabs/v1/resolve`
//! `{"token": "..."}` → `{"url": "https://<嵌片站>/e/<code>"}`。
//! VD 路（iosbgaigo.com，Vidara 播放器）已验通：
//! `POST https://iosbgaigo.com/api/stream`
//! `{"filecode": "<code>", "device": "web", "codecs": []}`
//! → `{"streaming_url": "<master.m3u8?token=...>"}`。
//! 实测 YUJ_075（VD 路）：变体清单 1798 分片、7192.45 秒，
//! 与卡片 1:59:53（7193 秒）精确对上（全长）；
//! 首分片 206 + 0x47（分片文件名为 .css 后缀，内容是 TS）。
//! 注意：变体清单用 plain 请求曾被远端断连，Chrome 模拟可取；
//! play() 只返回主清单（多清晰度，ExoPlayer 原生可播），
//! 不在模块内下钻变体；HG（hicherri.com）与 DS（vide0.net，
//! 嵌片页 403）两路未实现，模块优先用 VD，缺 VD 时报错。
//! 分类与站导航 1:1（18 个分类 + 4 个字幕标签）；
//! 分类列表 `/category/<slug>/page/N/`；搜索 `/?s=...`。

use base64::Engine;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javtsunami.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 18 个分类 + 4 个字幕标签。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新"),
    ("jav-censored", "JAV Censored"),
    ("jav-uncensored", "JAV Uncensored"),
    ("chinese", "Chinese AV"),
    ("new-release", "New Release"),
    ("trending", "Trending JAV"),
    ("featured", "Featured"),
    ("hot-jav", "Hot JAV"),
    ("upcoming", "Upcoming"),
    ("jav-sub", "JAV Sub"),
    ("fc2", "FC2 PPV"),
    ("amateur", "JAV Amateur"),
    ("av-debut", "AV Debut"),
    ("cosplay", "Cosplay"),
    ("family", "Family Porn"),
    ("premium", "Premium"),
    ("stepmom", "Japanese Stepmom"),
    ("game-show", "Japanese Game Show"),
    ("tag:jav-eng-sub", "Sub Eng"),
    ("tag:jav-sub-indo", "Sub Indo"),
    ("tag:av-ซับไทย", "AV ซับไทย"),
    ("tag:jav-english-subtitle", "JAV English Subtitle"),
];

fn token_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"data-server-token="([^"]+)" data-server-label="(\w+)""#).unwrap()
    })
}

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "JAV Tsunami 请求 HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn post_json(url: &str, referer: &str, body: &Value) -> ApiResult<String> {
    let resp = client()?
        .post(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("Referer", referer)
        .json(body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "JAV Tsunami POST 请求 HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .trim()
        .to_string()
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// `<article class="video-card ...">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article class=\"video-card").skip(1) {
        let end = block
            .find("<article class=\"video-card")
            .unwrap_or(block.len());
        let block = &block[..end];
        let Some(hp) = block.find("href=\"https://javtsunami.com/") else {
            continue;
        };
        let s = hp + 6;
        let Some(e) = block[s..].find('"') else {
            continue;
        };
        let href = &block[s..s + e];
        if !href.ends_with("v.html") {
            continue;
        }
        if seen.contains(&href.to_string()) {
            continue;
        }
        // 标题：img alt，兜底 card-title。
        let mut title = String::new();
        let mut cover = String::new();
        if let Some(p) = block.find("<img ") {
            let img = &block[p..];
            if let Some(a) = img.find("alt=\"") {
                let s = a + 5;
                if let Some(e) = img[s..].find('"') {
                    title = decode_entities(&img[s..s + e]);
                }
            }
            if let Some(a) = img.find("src=\"") {
                let s = a + 5;
                if let Some(e) = img[s..].find('"') {
                    cover = img[s..s + e].to_string();
                }
            }
        }
        if title.is_empty() {
            if let Some(p) = block.find("card-title") {
                let after = &block[p..];
                if let Some(gt) = after.find('>') {
                    let s = gt + 1;
                    if let Some(e) = after[s..].find("</") {
                        title = decode_entities(after[s..s + e].trim());
                    }
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        let mut remark = String::new();
        if let Some(p) = block.find("class=\"duration\"") {
            let after = &block[p..];
            // 时长在内层 <span> 里：<span class="duration">…<span>1:59:53</span></span>。
            let mut rest = after;
            while let Some(sp) = rest.find("<span>") {
                let s = sp + 6;
                if let Some(e) = rest[s..].find("</span>") {
                    let t = rest[s..s + e].trim();
                    if !t.is_empty()
                        && t.chars().all(|c| c.is_ascii_digit() || c == ':')
                        && t.contains(':')
                    {
                        remark = t.to_string();
                    }
                }
                rest = &rest[sp + 1..];
            }
        }
        seen.push(href.to_string());
        items.push(item_json(href, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let paged = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}page/{page}/")
        }
    };
    match category_id {
        "latest" => paged(format!("{HOST}/latest/")),
        _ => {
            if let Some(v) = category_id.strip_prefix("tag:") {
                paged(format!("{HOST}/tag/{v}/"))
            } else {
                paged(format!("{HOST}/category/{category_id}/"))
            }
        }
    }
}

fn meta_content(html: &str, attr: &str, key: &str) -> String {
    let marker = format!("{attr}=\"{key}\"");
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
        .map(|e| decode_entities(&after[s..s + e]))
        .unwrap_or_default()
}

fn tag_title(html: &str) -> String {
    let Some(p) = html.find("<title>") else {
        return String::new();
    };
    let s = p + 7;
    let e = html[s..]
        .find("</title>")
        .map(|i| s + i)
        .unwrap_or(html.len());
    let t = decode_entities(&html[s..e]);
    for sep in [" JAV Video", " - JAV Tsunami", " | JAV Tsunami"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

/// 女优链接 `/actor/<slug>` 的显示名。
fn actors(html: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = html;
    while let Some(p) = rest.find("href=\"https://javtsunami.com/actor/") {
        let after = &rest[p..];
        if let Some(gt) = after.find('>') {
            let s = gt + 1;
            if let Some(e) = after[s..].find("</a>") {
                let name = decode_entities(after[s..s + e].trim());
                if !name.is_empty() && !out.contains(&name) {
                    out.push(name);
                }
            }
        }
        rest = &rest[p + 1..];
        if out.len() >= 8 {
            break;
        }
    }
    out
}

/// server token 的 JWT 式载荷（base64url JSON）解出服务器序号 i。
fn token_server_index(token: &str) -> Option<i64> {
    let head = token.split('.').next()?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(head.as_bytes())
        .ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v.get("i").and_then(|x| x.as_i64())
}

/// 详情页全部服务器 token（label → token）。
fn server_tokens(html: &str) -> Vec<(String, String)> {
    token_re()
        .captures_iter(html)
        .map(|c| (c[2].to_string(), c[1].to_string()))
        .collect()
}

/// resolve 口子返回的嵌片地址。
fn resolve_url(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body).ok()?;
    v.get("url").and_then(|x| x.as_str()).map(|s| s.to_string())
}

/// Vidara /api/stream 返回的 streaming_url。
fn stream_url(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body).ok()?;
    v.get("streaming_url")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
}

/// 嵌片地址拆出 host 与 filecode（`https://<host>/e/<code>`）。
fn embed_parts(url: &str) -> Option<(String, String)> {
    let rest = url.strip_prefix("https://")?;
    let (host, path) = rest.split_once('/')?;
    let code = path.strip_prefix("e/")?;
    let code = code.split(['?', '#']).next()?;
    if code.is_empty() {
        return None;
    }
    Some((host.to_string(), code.to_string()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("JAV Tsunami 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let desc = meta_content(&html, "property", "og:description");
    let cast = actors(&html);
    let desc = if cast.is_empty() {
        desc
    } else if desc.is_empty() {
        format!("女優：{}", cast.join("、"))
    } else {
        format!("{desc}\n女優：{}", cast.join("、"))
    };
    let desc = truncate(&desc, 400);
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${series_id}"), "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let tokens = server_tokens(&html);
    if tokens.is_empty() {
        return Err(ApiError::Internal(
            "JAV Tsunami 详情页未找到服务器 token".into(),
        ));
    }
    // 优先 VD（iosbgaigo.com，Vidara 路已验通），其次 HG、DS。
    let mut ordered: Vec<(String, String)> = Vec::new();
    for want in ["VD", "HG", "DS"] {
        for (label, tok) in &tokens {
            if label == want {
                ordered.push((label.clone(), tok.clone()));
            }
        }
    }
    for (label, tok) in &tokens {
        if !ordered.iter().any(|(l, _)| l == label) {
            ordered.push((label.clone(), tok.clone()));
        }
    }
    let mut last_err = String::new();
    for (label, tok) in ordered {
        let body = post_json(
            &format!("{HOST}/wp-json/jw-dom-tabs/v1/resolve"),
            &page_url,
            &json!({"token": tok}),
        )
        .await;
        let body = match body {
            Ok(b) => b,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let Some(embed) = resolve_url(&body) else {
            last_err = format!("{label} resolve 未返回地址");
            continue;
        };
        let Some((host, code)) = embed_parts(&embed) else {
            last_err = format!("{label} 嵌片地址异常：{embed}");
            continue;
        };
        // 只实现 Vidara（iosbgaigo.com）一路。
        if host != "iosbgaigo.com" {
            last_err = format!("{label} 嵌片站 {host} 未实现取流");
            continue;
        }
        let api = format!("https://{host}/api/stream");
        let stream_body = post_json(
            &api,
            &embed,
            &json!({"filecode": code, "device": "web", "codecs": []}),
        )
        .await;
        let stream_body = match stream_body {
            Ok(b) => b,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if let Some(url) = stream_url(&stream_body) {
            return Ok(json!({
                "url": url,
                "header": {"User-Agent": UA, "Referer": embed},
            }));
        }
        last_err = format!("{label} api/stream 未返回流地址");
    }
    Err(ApiError::Internal(format!(
        "JAV Tsunami 取流失败：{last_err}"
    )))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 token：YUJ_075 的 VD 路（i=3）。
    const TOKEN_VD: &str = "eyJhIjoxLCJwIjoxOTA1MDIsImkiOjMsImUiOjE3OTM5NDk1NDksInYiOiI4ZGVlNGFhZDcxNDYwYzdkNzY5NjZjOGE0N2NkOTQxZjA2ZTJiMmE0NDc0NzA1N2IzMjM4ODRjNWUyODZhZmVlIn0.c5253465da79ff9d85dd8070178b066bc4a0d1d021871371f5731257a9f41833";

    #[test]
    fn token_server_index_known() {
        assert_eq!(token_server_index(TOKEN_VD).unwrap(), 3);
        assert!(token_server_index("garbage").is_none());
    }

    #[test]
    fn server_tokens_extract() {
        let html = r#"<iframe src="about:blank" data-server-token="eyJhIjoxLCJwIjoxOTA1MDIsImkiOjEsImUiOjE3OTM5NDk1NDksInYiOiI5OWE4ODY4ZDQ3NDE3NmM4YzBhNTJjMjczNzE5MjVlNGVlMDc5ZmQ4NmYxMmViMTM0NWM1MjE1MmIxMTIxNDA0In0.7405378e38f7733ed754739eeac002b6c4264affd4634ea8ff19add3c2f340b8" data-server-label="HG" title="Video player: YUJ_075"></iframe><iframe src="about:blank" data-server-token="TOKENVD" data-server-label="VD"></iframe>"#;
        let toks = server_tokens(html);
        assert_eq!(toks.len(), 2);
        assert_eq!(toks[0].0, "HG");
        assert_eq!(toks[1].0, "VD");
        assert_eq!(toks[1].1, "TOKENVD");
    }

    #[test]
    fn resolve_and_stream_parse() {
        assert_eq!(
            resolve_url(r#"{"url":"https:\/\/iosbgaigo.com\/e\/D7xeYbqb3QFC"}"#).unwrap(),
            "https://iosbgaigo.com/e/D7xeYbqb3QFC"
        );
        let body = r#"{"default_sub_lang":"English","filecode":"D7xeYbqb3QFC","streaming_url":"https://s12-s501740.s1q2105.com/hls/uSdxzAZoZ7k0JNMXiY6cDvccns9A5Fv2/master.m3u8?token=abc","subtitles":null}"#;
        assert_eq!(
            stream_url(body).unwrap(),
            "https://s12-s501740.s1q2105.com/hls/uSdxzAZoZ7k0JNMXiY6cDvccns9A5Fv2/master.m3u8?token=abc"
        );
        assert_eq!(
            embed_parts("https://iosbgaigo.com/e/D7xeYbqb3QFC").unwrap(),
            ("iosbgaigo.com".to_string(), "D7xeYbqb3QFC".to_string())
        );
    }

    #[test]
    fn parse_video_card() {
        let html = r#"<article class="video-card post-190502"><a class="thumb-link" href="https://javtsunami.com/yuj075v.html"><img src="https://imagerls.com/wp-content/uploads/2026/10/yuj075pl.jpg" alt="YUJ_075" decoding="async"><span class="card-media-meta"><span class="duration"><span>1:59:53</span></span></span></a><div class="card-body"><h2 class="card-title"><a href="https://javtsunami.com/yuj075v.html">YUJ_075</a></h2></div></article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://javtsunami.com/yuj075v.html");
        assert_eq!(items[0]["title"], "YUJ_075");
        assert_eq!(
            items[0]["cover"],
            "https://imagerls.com/wp-content/uploads/2026/10/yuj075pl.jpg"
        );
        assert_eq!(items[0]["remark"], "1:59:53");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("jav-censored", 1),
            "https://javtsunami.com/category/jav-censored/"
        );
        assert_eq!(
            catalog_url("jav-censored", 2),
            "https://javtsunami.com/category/jav-censored/page/2/"
        );
        assert_eq!(catalog_url("latest", 1), "https://javtsunami.com/latest/");
        assert_eq!(
            catalog_url("tag:jav-eng-sub", 1),
            "https://javtsunami.com/tag/jav-eng-sub/"
        );
    }

    #[test]
    fn tag_title_strips_suffix() {
        assert_eq!(tag_title("<title>YUJ_075 JAV Video</title>"), "YUJ_075");
    }
}
