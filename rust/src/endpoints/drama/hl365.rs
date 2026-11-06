//! 黑料不打烊：`https://hl365.com` 等 4 域名轮询。
//!
//! 来源 jar 类 `ZakaHl365Amns`。UA 为 Chrome 126 Android Pixel 7；
//! `BASES` 轮询试错（200 才算成功，失败记异常继续下一域名）。
//! 分类：`all` 首页 + 23 个 `cat:<code>`。列表：首页第 1 页 `/`、之后
//! `/page/<n>/`；分类第 1 页 `/category/<code>/`、之后
//! `/category/<code>/page/<n>/`；按 `<article…</article>` 切块，id 取
//! `content="…/archives/<id>.html"`，标题取
//! `post-card-bottom-text">…`（排除标题“广告”），封面取
//! `z-image-loader-url="…"`（含 `/hc237/` 的封面跳过该卡），备注取
//! `datePublished">…`（去尾部 `•`）；`has_more` 看页面是否含
//! `/page/<n+1>/`。详情 GET `/archives/<id>.html`，标题取 `<title>` 去
//! ` - ` 后缀；播放器取全部 `data-config='{…}'` JSON（括号匹配法抽取）
//! 中 `video.url` 含 `.m3u8` 或 `.mp4` 的项，`pic` 作封面；分集为单段
//! 时“正片”，多段时“第N段”，video_id 为 `post:<id>:<段下标>`。取流
//! 解析 `post:<id>:<idx>`，重新 GET 详情页，取 `players()[idx].url`，
//! parse 0 + UA + Referer `<base>/`；无视频时报错。搜索 GET
//! `/search/<编码词>/`，同 `cards` 解析。
//!
//! 注意：封面 URL 可能是 AES 加密图（Java proxy 层才解密），核心只返
//! 回 `z-image-loader-url` 原值。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";
const BASES: &[&str] = &[
    "https://absence.egiaajsd.cc",
    "https://hl365.com",
    "https://boat.rhemepsy.cc",
    "https://rhemepsy.cc",
];

const CATS: &[(&str, &str)] = &[
    ("all", "首页"),
    ("cat:24hcg", "今日看料"),
    ("cat:youxuan", "优选投放"),
    ("cat:mrds", "每日大赛"),
    ("cat:swdj", "AI短剧"),
    ("cat:mrrg", "每日热瓜"),
    ("cat:hlda", "黑料大事"),
    ("cat:rgtj", "热门吃瓜"),
    ("cat:fcns", "反差女神"),
    ("cat:xyrg", "学院热瓜"),
    ("cat:whhl", "网红吃瓜"),
    ("cat:lydt", "撸友看片"),
    ("cat:llsq", "海角乱伦"),
    ("cat:hlzt", "黑料杂谈"),
    ("cat:thdq", "探花大全"),
    ("cat:whzj", "网黄专辑"),
    ("cat:mxbg", "明星吃瓜"),
    ("cat:avjs", "av解说"),
    ("cat:qgzq", "原创投稿"),
    ("cat:wyxs", "性爱技巧"),
    ("cat:chjlb", "偷拍盗摄"),
    ("cat:gcmw", "官场秘闻"),
    ("cat:mrst", "禁播动漫"),
    ("cat:pmv", "PMV混剪"),
];

fn re_article() -> &'static Regex {
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<article.*?</article>").unwrap());
    &RE
}

fn first_group(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default()
}

async fn get_text(url: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.text().await.ok()
}

/// 轮询 BASES：第一个 200 的域名即锁定。
async fn probe_base() -> Option<String> {
    for base in BASES {
        if get_text(&format!("{base}/")).await.is_some() {
            return Some(base.to_string());
        }
    }
    None
}

fn cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let id_re = Regex::new(r#"content="[^"]*/archives/(\d+)\.html""#).unwrap();
    let title_re = Regex::new(r#"post-card-bottom-text">\s*([^<]+)"#).unwrap();
    let cover_re = Regex::new(r#"z-image-loader-url="([^"]+)""#).unwrap();
    let date_re = Regex::new(r#"datePublished"[^>]*>([^<]+)"#).unwrap();
    for cap in re_article().captures_iter(html) {
        let block = cap.get(0).unwrap().as_str();
        let Some(id) = id_re.captures(block).and_then(|c| c.get(1)).map(|m| m.as_str().to_string()) else {
            continue;
        };
        let title = first_group(&title_re, block);
        if title.trim().is_empty() || title.trim() == "广告" {
            continue;
        }
        let cover = first_group(&cover_re, block);
        if cover.contains("/hc237/") {
            continue;
        }
        let mut remark = first_group(&date_re, block);
        remark = remark.trim_end_matches('•').trim().to_string();
        items.push(item_json(&id, title.trim(), &cover, &remark));
    }
    items
}

/// 从 HTML 里抽全部 `data-config='{…}'`（括号匹配法），返回其中
/// `video.url` 含 `.m3u8` 或 `.mp4` 的 `(url, pic)` 列表。
fn players(html: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut rest = html;
    while let Some(pos) = rest.find("data-config='") {
        let start = pos + "data-config='".len();
        let bytes = rest.as_bytes();
        let mut depth = 0i32;
        let mut end: Option<usize> = None;
        let mut i = start;
        while i < bytes.len() {
            match bytes[i] {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        end = Some(i + 1);
                        break;
                    }
                }
                _ => {}
            }
            i += 1;
        }
        let Some(end) = end else {
            break;
        };
        let frag = &rest[start..end];
        if let Ok(v) = serde_json::from_str::<Value>(frag) {
            let url = v
                .get("video")
                .and_then(|x| x.get("url"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            if url.contains(".m3u8") || url.contains(".mp4") {
                let pic = v
                    .get("video")
                    .and_then(|x| x.get("pic"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                out.push((url, pic));
            }
        }
        rest = &rest[end..];
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let Some(base) = probe_base().await else {
        return Ok(json!({"items": [], "has_more": false}));
    };
    let url = if category_id == "all" {
        if page == 1 {
            format!("{base}/")
        } else {
            format!("{base}/page/{page}/")
        }
    } else if let Some(code) = category_id.strip_prefix("cat:") {
        if page == 1 {
            format!("{base}/category/{code}/")
        } else {
            format!("{base}/category/{code}/page/{page}/")
        }
    } else {
        return Ok(json!({"items": [], "has_more": false}));
    };
    let Some(html) = get_text(&url).await else {
        return Ok(json!({"items": [], "has_more": false}));
    };
    let items = cards(&html);
    let has_more = html.contains(&format!("/page/{}/", page + 1));
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let Some(base) = probe_base().await else {
        return Ok(json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}));
    };
    let Some(html) = get_text(&format!("{base}/archives/{id}.html")).await else {
        return Ok(json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}));
    };
    let title_re = Regex::new(r"<title>([^<]+)</title>").unwrap();
    let mut title = first_group(&title_re, &html);
    if let Some(pos) = title.rfind(" - ") {
        title = title[..pos].trim().to_string();
    }
    if title.is_empty() {
        title = format!("文章{id}");
    }
    let segs = players(&html);
    let cover = segs.first().map(|(_, p)| p.clone()).unwrap_or_default();
    let mut episodes: Vec<Value> = Vec::new();
    if segs.len() == 1 {
        episodes.push(episode_json(&format!("post:{id}:0"), "正片", id));
    } else {
        for (i, _) in segs.iter().enumerate() {
            episodes.push(episode_json(
                &format!("post:{id}:{i}"),
                &format!("第{}段", i + 1),
                id,
            ));
        }
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover, "synopsis": "",
        "extra": {}, "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let Some(base) = probe_base().await else {
        return Ok(json!({"items": []}));
    };
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let Some(html) = get_text(&format!("{base}/search/{enc}/")).await else {
        return Ok(json!({"items": []}));
    };
    Ok(json!({"items": cards(&html)}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let parts: Vec<&str> = video_id.split(':').collect();
    if parts.len() != 3 || parts[0] != "post" {
        return Err(ApiError::BadRequest("bad hl365 episode id".into()));
    }
    let (id, idx) = (parts[1], parts[2].parse::<usize>().unwrap_or(0));
    let Some(base) = probe_base().await else {
        return Err(ApiError::Internal("hl365 no base".into()));
    };
    let Some(html) = get_text(&format!("{base}/archives/{id}.html")).await else {
        return Err(ApiError::Internal("hl365 detail empty".into()));
    };
    let segs = players(&html);
    let Some((url, _)) = segs.get(idx) else {
        return Err(ApiError::Internal(format!("hl365 no video in post {id}")));
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{base}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_skip_ad_and_hc237() {
        let html = r#"<article><meta content="https://x/archives/1.html"><div class="post-card-bottom-text">广告</div><img z-image-loader-url="https://x/a.jpg"></article><article><meta content="https://x/archives/2.html"><div class="post-card-bottom-text">好瓜</div><img z-image-loader-url="https://x/hc237/b.jpg"></article><article><meta content="https://x/archives/3.html"><div class="post-card-bottom-text">真瓜</div><img z-image-loader-url="https://x/c.jpg"><span datePublished">2026-11-01•</span></article>"#;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "3");
        assert_eq!(items[0]["remark"], "2026-11-01");
    }

    #[test]
    fn players_pick_m3u8() {
        let html = r#"x data-config='{"video":{"url":"https://cdn/x.mp4","pic":"https://cdn/p.jpg"}}' y data-config='{"video":{"url":"https://cdn/a.m3u8","pic":""}}' z"#;
        let segs = players(html);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[1].0, "https://cdn/a.m3u8");
    }
}
