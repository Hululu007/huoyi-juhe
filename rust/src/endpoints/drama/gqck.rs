//! 高清仓库：MacCMS 免登直取（与 PUA独家爆料同构）。
//!
//! 来源 jar 类 `ZakaGqckAmns`。ENTRY 4 个域名 + POOL 9 个子域名
//! 依次探活：先探 POOL（`GET {host}/vodtype/8/` 200 且 ≥2000
//! 字节且含 `stui-vodlist` 或 `/vodplay/` 才算活），再探 ENTRY
//!（跟随 302 到随机子域名后同样探活），30 分钟缓存；目录走
//! `/vodtype/{id}/`；详情取 `player_aaaa` 后的 JSON 块里的
//! `url` 字段做取流。
//! 注意：Java 经本地代理改写 m3u8（相对分片/密钥地址转绝对并带
//! Referer 取回），Rust 核心 `play()` 只回原始 m3u8 直链，
//! 分片/密钥是否需带 Referer 待手机侧实测。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::Mutex;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const ENTRY: &[&str] = &[
    "https://gqck.cc",
    "https://gqck.net",
    "https://gqck.tv",
    "https://www.gqck.net",
];
const POOL: &[&str] = &[
    "https://o4hwka.gqck.net",
    "https://vxlzd6.gqck.net",
    "https://h2z0r3.gqck.net",
    "https://k118fw.gqck.net",
    "https://xdd3f2.gqck.net",
    "https://l3myuj.gqck.net",
    "https://u9syd6.gqck.net",
    "https://6ger9s.gqck.net",
    "https://on7jwi.gqck.net",
];
const PAGE_SIZE: i64 = 40;

const CATS: &[(&str, i64)] = &[
    ("日韩AV", 1),
    ("国产系列", 2),
    ("欧美", 3),
    ("动漫", 4),
    ("无码中文字幕", 8),
    ("有码中文字幕", 9),
    ("日本无码", 10),
    ("日本有码", 7),
    ("国产视频", 15),
    ("吃瓜爆料", 25),
    ("欧美高清", 21),
    ("动漫剧情", 22),
];

static BASE_CACHE: Lazy<Mutex<Option<(String, std::time::Instant)>>> =
    Lazy::new(|| Mutex::new(None));

fn unescape(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ");
    loop {
        let Some(start) = out.find("&#") else { break };
        let Some(end) = out[start..].find(';') else {
            break;
        };
        let body = &out[start + 2..start + end];
        let num = if let Some(hex) = body.strip_prefix(['x', 'X']) {
            u32::from_str_radix(hex, 16).ok()
        } else {
            body.parse::<u32>().ok()
        };
        let Some(n) = num.and_then(char::from_u32) else {
            break;
        };
        out.replace_range(start..start + end + 1, &n.to_string());
    }
    out
}

fn strip_tags(s: &str) -> String {
    let tag = Regex::new(r"<[^>]*>").unwrap();
    let collapsed = Regex::new(r"\s+").unwrap();
    collapsed
        .replace_all(tag.replace_all(s, " ").as_ref(), " ")
        .trim()
        .to_string()
}

fn abs_url(base: &str, u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{base}{u}")
    } else {
        u.to_string()
    }
}

async fn probe(host: &str) -> bool {
    let url = format!("{host}/vodtype/8/");
    let Ok(c) = client() else {
        return false;
    };
    let Ok(resp) = c
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,*/*")
        .header("Referer", format!("{host}/"))
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
    text.len() >= 2000 && (text.contains("stui-vodlist") || text.contains("/vodplay/"))
}

/// ENTRY 域名跟随跳转（302 到随机子域名）再探活。
async fn follow_entry(entry: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .get(format!("{entry}/"))
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .send()
        .await
        .ok()?;
    let final_url = resp.url().clone();
    let host = final_url.host_str()?;
    let host = format!("{}://{host}", final_url.scheme());
    if host.len() > 8 {
        Some(host)
    } else {
        None
    }
}

async fn base() -> ApiResult<String> {
    {
        let guard = BASE_CACHE.lock().unwrap();
        if let Some((b, t)) = guard.as_ref() {
            if t.elapsed().as_secs() < 1800 {
                return Ok(b.clone());
            }
        }
    }
    for host in POOL {
        if probe(host).await {
            let mut guard = BASE_CACHE.lock().unwrap();
            *guard = Some((host.to_string(), std::time::Instant::now()));
            return Ok(host.to_string());
        }
    }
    for entry in ENTRY {
        if let Some(host) = follow_entry(entry).await {
            if probe(&host).await {
                let mut guard = BASE_CACHE.lock().unwrap();
                *guard = Some((host.clone(), std::time::Instant::now()));
                return Ok(host);
            }
        }
    }
    Err(ApiError::Internal("高清仓库全部域名不通".into()))
}

async fn fetch(path: &str) -> ApiResult<(String, String)> {
    let host = base().await?;
    let url = format!("{host}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{host}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("高清仓库请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok((host, text))
}

fn cards(base: &str, page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    static RE_A: Lazy<Regex> = Lazy::new(|| {
        Regex::new(
            r#"(?s)<a[^>]*class="[^"]*stui-vodlist__thumb[^"]*"[^>]*href="([^"]*?/vodplay/[^"]*)""#,
        )
        .unwrap()
    });
    static RE_TITLE_ATTR: Lazy<Regex> = Lazy::new(|| Regex::new(r#"title="([^"]+)""#).unwrap());
    static RE_IMG: Lazy<Regex> = Lazy::new(|| Regex::new(r#"data-original="([^"]+)""#).unwrap());
    static RE_REMARK: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"(?s)<span class="[^"]*pic-text[^"]*"[^>]*>([^<]*)</span>"#).unwrap()
    });
    for cap in RE_A.captures_iter(page) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        if href.is_empty() || !seen.insert(href.to_string()) {
            continue;
        }
        let start = cap.get(0).unwrap().start();
        let window = &page[start..page.len().min(start + 400)];
        let title = RE_TITLE_ATTR
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| unescape(m.as_str()))
            .unwrap_or_default();
        let cover = RE_IMG
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(base, m.as_str()))
            .unwrap_or_default();
        let mut remark = RE_REMARK
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        if remark.is_empty() {
            remark = "高清".to_string();
        }
        let full = if href.starts_with("http") {
            href.to_string()
        } else {
            format!("{base}{href}")
        };
        items.push(item_json(&full, &title, &cover, &remark));
    }
    items
}

/// 找 marker 之后最近的 `{...}` 括号匹配块并解析为 JSON。
fn blob(page: &str, marker: &str) -> Option<Value> {
    let pos = page.find(marker)?;
    let rest = &page[pos + marker.len()..];
    let start = rest.find('{')?;
    let bytes = rest[start..].as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    for (i, &b) in bytes.iter().enumerate() {
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else {
            match b {
                b'"' => in_str = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        let s = std::str::from_utf8(&bytes[..=i]).ok()?;
                        return serde_json::from_str::<Value>(s).ok();
                    }
                }
                _ => {}
            }
        }
    }
    None
}

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (name, id) in CATS {
        list.push(category_json(&id.to_string(), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let id = if category_id.is_empty() {
        "1"
    } else {
        category_id
    };
    let path = if page > 1 {
        format!("/vodtype/{id}-{page}/")
    } else {
        format!("/vodtype/{id}/")
    };
    let (host, page_html) = fetch(&path).await?;
    let items = cards(&host, &page_html);
    let has_more = items.len() as i64 >= PAGE_SIZE;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = if series_id.starts_with("http") {
        let re = Regex::new(r"^https?://[^/]+(/.*)$").unwrap();
        re.captures(series_id)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_else(|| series_id.to_string())
    } else if series_id.starts_with('/') {
        series_id.to_string()
    } else {
        format!("/{series_id}")
    };
    let (host, page_html) = fetch(&path).await?;
    let b = blob(&page_html, "player_aaaa");
    let re_h1 = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let re_og_title = Regex::new(r#"og:title"\s+content="([^"]+)""#).unwrap();
    let re_og_img = Regex::new(r#"og:image"\s+content="([^"]+)""#).unwrap();
    let re_desc =
        Regex::new(r#"(?:name="description"|og:description)"\s+content="([^"]*)""#).unwrap();
    let re_play = Regex::new(r"/vodplay/(\d+)-(\d+)-(\d+)/").unwrap();
    let re_info = Regex::new(r"(类型|地区|年份|更新)：([^<\n]{1,80})").unwrap();
    let re_actor = Regex::new(r#"<a[^>]*href="[^"]*?/vodsearch/[^"]*"[^>]*>([^<]+)</a>"#).unwrap();
    let mut title = re_h1
        .captures(&page_html)
        .and_then(|c| c.get(1))
        .map(|m| strip_tags(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        title = unescape(&cap1(&re_og_title, &page_html));
    }
    if title.is_empty() {
        if let Some(bb) = &b {
            title = bb
                .get("vod_data")
                .and_then(|v| v.get("vod_name"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
        }
    }
    if title.is_empty() {
        static RE_TITLE: Lazy<Regex> =
            Lazy::new(|| Regex::new(r"(?s)<title>(.*?)</title>").unwrap());
        title = unescape(&strip_tags(&cap1(&RE_TITLE, &page_html)));
    }
    let mut cover = cap1(&re_og_img, &page_html);
    if cover.is_empty() {
        static RE_IMG: Lazy<Regex> = Lazy::new(|| {
            Regex::new(r#"data-original="(https?://[^"]+?\.(?:jpg|jpeg|png|webp))""#).unwrap()
        });
        cover = cap1(&RE_IMG, &page_html);
    }
    let cover = abs_url(&host, &cover);
    let desc = unescape(&cap1(&re_desc, &page_html));
    let mut info_lines = Vec::new();
    for cap in re_info.captures_iter(&page_html) {
        info_lines.push(format!(
            "{}：{}",
            cap.get(1).unwrap().as_str(),
            cap.get(2).unwrap().as_str().trim()
        ));
    }
    let mut actors = Vec::new();
    for cap in re_actor.captures_iter(&page_html) {
        let name = cap.get(1).unwrap().as_str().trim().to_string();
        if !name.is_empty() && actors.len() < 8 && !actors.contains(&name) {
            actors.push(name);
        }
    }
    let mut seen = std::collections::HashSet::new();
    let mut episodes = Vec::new();
    for cap in re_play.captures_iter(&page_html) {
        let (line, ep) = (cap.get(2).unwrap().as_str(), cap.get(3).unwrap().as_str());
        let key = (line.to_string(), ep.to_string());
        if !seen.insert(key) {
            continue;
        }
        let name = if line == "1" {
            format!("第 {ep} 集")
        } else {
            format!("线路 {line} · 第 {ep} 集")
        };
        let url = format!(
            "{host}/vodplay/{}/{}/{}/",
            cap.get(1).unwrap().as_str(),
            line,
            ep
        );
        episodes.push(episode_json(&url, &name, series_id));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("{host}{path}"), "播放", series_id));
    }
    let mut synopsis = String::new();
    if !info_lines.is_empty() {
        synopsis.push_str(&info_lines.join("\n"));
        synopsis.push('\n');
    }
    if !actors.is_empty() {
        synopsis.push_str(&format!("主演：{}\n", actors.join("、")));
    }
    synopsis.push_str(&desc);
    synopsis.push_str("\n来源：高清仓库");
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { "高清仓库".to_string() } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"actor": actors.join("、")},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let path = format!("/vodsearch/{enc}----------1---.html");
    let (host, page_html) = fetch(&path).await?;
    let items = cards(&host, &page_html);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({"url": video_id}));
    }
    let host = base().await?;
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{host}{video_id}")
    };
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,*/*")
        .header("Referer", format!("{host}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let mut stream = String::new();
    if let Some(b) = blob(&text, "player_aaaa") {
        if let Some(u) = b.get("url").and_then(|v| v.as_str()) {
            stream = u.replace("\\/", "/");
        }
    }
    if stream.is_empty() {
        static RE_URL: Lazy<Regex> =
            Lazy::new(|| Regex::new(r#""url"\s*:\s*"(https?:[^"]+\.m3u8[^"]*)""#).unwrap());
        stream = cap1(&RE_URL, &text).replace("\\/", "/");
    }
    if stream.is_empty() {
        return Ok(json!({"url": url}));
    }
    Ok(json!({"url": stream}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_extracts_json_after_marker() {
        let page = "xxx player_aaaa = {\"url\":\"https://a/b.m3u8\",\"vod_name\":\"T\"}; yyy";
        let b = blob(page, "player_aaaa").expect("blob");
        assert_eq!(b["url"], "https://a/b.m3u8");
        assert_eq!(b["vod_name"], "T");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r##"<a class="stui-vodlist__thumb lazyload" href="/vodplay/123-1-1/" title="Sample"><img data-original="//img.example.com/1.jpg"><span class="pic-text text-right">HD</span></a>"##;
        let items = cards("https://gqck.cc", html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://gqck.cc/vodplay/123-1-1/");
        assert_eq!(items[0]["title"], "Sample");
        assert_eq!(items[0]["cover"], "https://img.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "HD");
    }
}
