//! JAVSiri（javsiri.cc）：KVS（Kernel Video Sharing）模板站。
//! 取流：详情页 flashvars 的 `video_url` 是明文直链
//! `https://javsiri.cc/get_file/5/<hash>/18000/<id>/<id>.mp4/?v-acctoken=...`，
//! 现取现用（token 按次变化，旧页的 token 会 403，须重拉详情页）。
//! 实测 18141（FC2-PPV-1891670）：Range 请求 206 + ftyp 魔数，
//! 文件 419894299 字节；卡片时长 1-3 小时量级，属全长正片。
//! 注意：video_url 不是 base64（与 KissJAV 不同），直接用；
//! video_url_hd 同样只是标志位，不用它。
//! 分类与站导航 1:1（最新/最高评分/最多观看 + 4 个分类）；
//! 列表翻页 `/latest-updates/N/`、分类 `/categories/<slug>/N/`；
//! 搜索 `/search/?q=...`。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javsiri.cc";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：站导航 + /categories/ 页验过的 4 个分类。
const CATS: &[(&str, &str)] = &[
    ("latest", "最新"),
    ("top-rated", "最高评分"),
    ("popular", "最多观看"),
    ("cat:amateur", "Amateur"),
    ("cat:censored", "Censored"),
    ("cat:fc2ppv", "FC2PPV"),
    ("cat:jav-uncensored", "Uncensored"),
];

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
        return Err(ApiError::Internal(format!("JAVSiri 请求 HTTP {status}")));
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

/// KVS 卡片：`<a href="https://javsiri.cc/video/<id>/<slug>/">`，
/// 封面 `data-original`，时长 `<div class="time">`。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("href=\"https://javsiri.cc/video/").skip(1) {
        let end = block
            .find("href=\"https://javsiri.cc/video/")
            .unwrap_or(block.len());
        let block = &block[..end];
        let Some(q) = block.find('"') else {
            continue;
        };
        let path = &block[..q];
        let mut it = path.split('/');
        let Some(vid) = it.next() else {
            continue;
        };
        if vid.is_empty() || !vid.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let id = format!("{HOST}/video/{path}");
        if seen.contains(&id) {
            continue;
        }
        let mut title = String::new();
        if let Some(p) = block.find("title=\"") {
            let s = p + 7;
            if let Some(e) = block[s..].find('"') {
                title = decode_entities(&block[s..s + e]);
            }
        }
        let mut cover = String::new();
        if let Some(p) = block.find("data-original=\"") {
            let s = p + 15;
            if let Some(e) = block[s..].find('"') {
                let src = &block[s..s + e];
                cover = if src.starts_with("//") {
                    format!("https:{src}")
                } else if src.starts_with("http") {
                    src.to_string()
                } else {
                    format!("{HOST}{src}")
                };
            }
        }
        if title.is_empty() {
            if let Some(p) = block.find("alt=\"") {
                let s = p + 5;
                if let Some(e) = block[s..].find('"') {
                    title = decode_entities(&block[s..s + e]);
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        let mut remark = String::new();
        if let Some(p) = block.find("<div class=\"time\">") {
            let s = p + 18;
            if let Some(e) = block[s..].find("</div>") {
                remark = block[s..s + e].trim().to_string();
            }
        }
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let paged = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}{page}/")
        }
    };
    match category_id {
        "latest" => paged(format!("{HOST}/latest-updates/")),
        "top-rated" => paged(format!("{HOST}/top-rated/")),
        "popular" => paged(format!("{HOST}/most-popular/")),
        _ => {
            if let Some(v) = category_id.strip_prefix("cat:") {
                paged(format!("{HOST}/categories/{v}/"))
            } else {
                paged(format!("{HOST}/latest-updates/"))
            }
        }
    }
}

/// flashvars 单引号字段。
fn flashvar(html: &str, name: &str) -> String {
    let marker = format!("{name}: '");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    html[s..]
        .find('\'')
        .map(|e| html[s..s + e].to_string())
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
    for sep in [" - JAVSiri", " | JAVSiri"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
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
    let mut title = flashvar(&html, "video_title");
    if title.is_empty() {
        title = tag_title(&html);
    }
    if title.is_empty() {
        return Err(ApiError::Internal("JAVSiri 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let cats = flashvar(&html, "video_categories");
    let desc = if cats.is_empty() {
        String::new()
    } else {
        format!("分类：{cats}")
    };
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
    if video_id.starts_with("http") && video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let url = flashvar(&html, "video_url");
    if url.is_empty() || !url.starts_with("http") || !url.contains(".mp4") {
        return Err(ApiError::Internal("JAVSiri 详情页未找到 video_url".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_video_card() {
        let html = r#"<div class="thumbs"><div class="thumb item"><a href="https://javsiri.cc/video/18141/fc2-ppv-1891670/" title="FC2-PPV-1891670: Suspect K, Victim A, and Victim B."><div class="img-holder"><img class="lazy-load" data-original="//javsiri.cc/contents/videos_screenshots/18000/18141/320x180/1.jpg" alt="FC2-PPV-1891670: Suspect K, Victim A, and Victim B."/><div class="item-bottom"><div class="time">1:35:24</div></div></div></a></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://javsiri.cc/video/18141/fc2-ppv-1891670/"
        );
        assert_eq!(
            items[0]["title"],
            "FC2-PPV-1891670: Suspect K, Victim A, and Victim B."
        );
        assert_eq!(
            items[0]["cover"],
            "https://javsiri.cc/contents/videos_screenshots/18000/18141/320x180/1.jpg"
        );
        assert_eq!(items[0]["remark"], "1:35:24");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest", 1),
            "https://javsiri.cc/latest-updates/"
        );
        assert_eq!(
            catalog_url("latest", 2),
            "https://javsiri.cc/latest-updates/2/"
        );
        assert_eq!(
            catalog_url("cat:fc2ppv", 1),
            "https://javsiri.cc/categories/fc2ppv/"
        );
        assert_eq!(catalog_url("top-rated", 1), "https://javsiri.cc/top-rated/");
    }

    #[test]
    fn flashvar_extract() {
        let html = "flashvars = {\n video_id: '18141', video_title: 'FC2-PPV-1891670: Suspect K, Victim A, and Victim B.', video_url: 'https://javsiri.cc/get_file/5/8882fa397cc4863efe3f91ec4d5b396a/18000/18141/18141.mp4/?v-acctoken=NTczfDN8MHxiNTRiNDI4MjZjMzZkNDQ5MzFjNmNkNTI1NGUyNTc4MA9c6e6cf3345290e1',";
        let url = flashvar(html, "video_url");
        assert!(url.starts_with("https://javsiri.cc/get_file/5/"));
        assert!(url.contains(".mp4/?v-acctoken="));
        assert_eq!(
            flashvar(html, "video_title"),
            "FC2-PPV-1891670: Suspect K, Victim A, and Victim B."
        );
    }
}
