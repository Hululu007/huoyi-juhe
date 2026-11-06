//! 悟空传媒（3ng23h0f.niumochishi06.sbs）：门禁 cookie 站。
//!
//! - 门禁：首页取 var token='...' 存为静态 gateToken，其余请求
//!   一律带 Cookie xk_gate=<token>。
//! - 分类 39 个（已删 id 3 萝莉）；列表 /vod/{id}.html，翻页
//!   /vod/{id}-{N}.html；卡片取 div.card 块内 pic 锚点（标题、
//!   背景图封面、sub-hits 备注），空结果回退全页 title 锚点。
//! - 详情：/play/{id}.html；标题 h1（回退 title 在 _ 前截断），
//!   类型取 meta 行，简介取 article-content；剧集取 line-play
//!   链接，无则单集“在线播放$/v-p/{id}-1-1.html”；详情无封面
//!   字段（Java 原样，vod_pic 为空）。
//! - 取流：video_id 含 $ 取 $ 后部分；已是 http 的 m3u8 直出；
//!   否则 GET /v-p/... 页取 "url" 字段（\/ 还原）；变体清单
//!   的根相对路径按 origin 拼（验证时简单拼目录曾 404）。
//! - 搜索：/sou/{编码}-.html，编码为 URLEncoder 后 + 改 %20。

use std::sync::Mutex;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://3ng23h0f.niumochishi06.sbs";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

static GATE_TOKEN: Mutex<Option<String>> = Mutex::new(None);

fn headers(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    req.header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = headers(client()?.get(url))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("悟空请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 1500 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("悟空页面异常（疑似盾拦截）".into()));
    }
    Ok(text)
}

/// 首页取门禁 token（不带 cookie），缓存为静态值。
async fn gate_token() -> ApiResult<String> {
    if let Ok(guard) = GATE_TOKEN.lock() {
        if let Some(t) = guard.as_ref() {
            if !t.is_empty() {
                return Ok(t.clone());
            }
        }
    }
    let html = get_text(&format!("{BASE}/")).await?;
    let re = Regex::new(r"var token='([^']+)'").unwrap();
    let token = re
        .captures(&html)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    if token.is_empty() {
        return Err(ApiError::Internal("悟空首页未找到门禁 token".into()));
    }
    if let Ok(mut guard) = GATE_TOKEN.lock() {
        *guard = Some(token.clone());
    }
    Ok(token)
}

/// 带门禁 cookie 的页面请求。
async fn get_gated(url: &str) -> ApiResult<String> {
    let token = gate_token().await?;
    let resp = headers(client()?.get(url))
        .header("Cookie", format!("xk_gate={token}"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("悟空请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 1500 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("悟空页面异常（疑似盾拦截）".into()));
    }
    Ok(text)
}

fn clean(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let t = tag_re.replace_all(s, " ");
    let t = t
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace('\u{a0}', " ");
    ws_re.replace_all(&t, " ").trim().to_string()
}

fn enc_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

/// 相对地址补绝对：// 补 https:，/ 补 BASE，其余补 BASE/。
fn abs_url(u: &str) -> String {
    let t = u.trim();
    if t.starts_with("http") {
        t.to_string()
    } else if let Some(rest) = t.strip_prefix("//") {
        format!("https://{rest}")
    } else if t.starts_with('/') {
        format!("{BASE}{t}")
    } else {
        format!("{BASE}/{t}")
    }
}

fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let block_re = Regex::new(r#"(?s)<div class="card">(.*?)</div>\s*</div>"#).unwrap();
    let anchor_re =
        Regex::new(r#"<a class="pic" href="/play/(\d+)\.html" title="([^"]*)""#).unwrap();
    let bg_re = Regex::new(r"background-image:url\(([^)]+)\)").unwrap();
    let hits_re = Regex::new(r#"<span class="sub-hits">([^<]*)</span>"#).unwrap();
    for b in block_re.captures_iter(html) {
        let seg = &b[1];
        let a = match anchor_re.captures(seg) {
            Some(x) => x,
            None => continue,
        };
        let id = a[1].to_string();
        let title = clean(&a[2]);
        if title.is_empty() {
            continue;
        }
        let pic = bg_re
            .captures(seg)
            .map(|x| abs_url(&x[1]))
            .unwrap_or_default();
        let remark = hits_re
            .captures(seg)
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
        items.push(item_json(&id, &title, &pic, &remark));
    }
    if items.is_empty() {
        let title_re =
            Regex::new(r#"<a class="title" href="/play/(\d+)\.html" title="([^"]*)""#).unwrap();
        for c in title_re.captures_iter(html) {
            let title = clean(&c[2]);
            if title.is_empty() {
                continue;
            }
            items.push(item_json(&c[1], &title, "", ""));
        }
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let cats: [(i64, &str); 39] = [
        (1, "国产"),
        (6, "自拍"),
        (8, "强奸"),
        (9, "传媒"),
        (12, "偷拍"),
        (2, "网红"),
        (14, "吃瓜"),
        (16, "人兽"),
        (5, "探花"),
        (4, "大秀"),
        (17, "人妖"),
        (20, "喷水"),
        (22, "性虐"),
        (24, "无码"),
        (26, "欧美"),
        (27, "动漫"),
        (41, "Cosplay"),
        (18, "OnlyFans"),
        (10, "反差婊"),
        (15, "大学生"),
        (11, "网爆门"),
        (13, "福利姬"),
        (38, "瑜伽裤"),
        (40, "多人群P"),
        (23, "AI换脸"),
        (28, "三级片"),
        (29, "AV解说"),
        (25, "中文字幕"),
        (39, "兽耳系列"),
        (37, "学生下海"),
        (36, "淫荡儿媳"),
        (35, "夫妻交换"),
        (34, "野外车震"),
        (33, "猛干嫂子"),
        (32, "狂操小姨"),
        (31, "禁忌母子"),
        (30, "兄弟姐妹"),
        (7, "家族乱伦"),
        (50, "魔改AI短剧"),
    ];
    let list: Vec<Value> = cats
        .iter()
        .map(|(id, name)| category_json(&id.to_string(), name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page > 1 {
        format!("{BASE}/vod/{category_id}-{page}.html")
    } else {
        format!("{BASE}/vod/{category_id}.html")
    };
    let html = get_gated(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": items.len() >= 16}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/play/")
        .trim_end_matches(".html")
        .trim_end_matches('/')
        .to_string();
    let html = get_gated(&format!("{BASE}/play/{id}.html")).await?;
    let mut title = {
        let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
        h1_re
            .captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default()
    };
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").unwrap();
        title = t_re
            .captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default();
        if let Some(pos) = title.find('_') {
            title.truncate(pos);
            title = title.trim().to_string();
        }
    }
    if title.is_empty() {
        title = "悟空传媒".to_string();
    }
    let kind = {
        let k_re = Regex::new(r#"<p class="meta">类型：([^<]+)</p>"#).unwrap();
        k_re.captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default()
    };
    let intro = {
        let i_re = Regex::new(r#"(?s)<div class="article-content">(.*?)</div>"#).unwrap();
        i_re.captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default()
    };
    let line_re =
        Regex::new(r#"<a class="line-play" href="(/v-p/\d+-\d+-\d+\.html)">([^<]+)</a>"#).unwrap();
    let mut episodes = Vec::new();
    for c in line_re.captures_iter(&html) {
        episodes.push(episode_json(&c[1], &clean(&c[2]), series_id));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(
            &format!("/v-p/{id}-1-1.html"),
            "在线播放",
            series_id,
        ));
    }
    let mut syn = String::from("站源：悟空传媒，门禁 cookie 取流");
    if !kind.is_empty() {
        syn.push_str(&format!("\n类型：{kind}"));
    }
    if !intro.is_empty() {
        syn.push_str(&format!("\n简介：{intro}"));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": "",
        "synopsis": syn,
        "extra": {"vod_play_from": "悟空传媒"},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut vid = video_id.to_string();
    if let Some(pos) = vid.find('$') {
        vid = vid[pos + 1..].to_string();
    }
    if vid.starts_with("http") && vid.contains(".m3u8") {
        return Ok(json!({
            "url": vid,
            "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
        }));
    }
    let url = if let Some(rest) = vid.strip_prefix("/v-p/") {
        format!("{BASE}/v-p/{rest}")
    } else if vid.starts_with("http") {
        vid.clone()
    } else {
        format!("{BASE}/v-p/{vid}-1-1.html")
    };
    let html = get_gated(&url).await?;
    let url_re = Regex::new(r#""url"\s*:\s*"([^"]+)""#).unwrap();
    let stream = url_re
        .captures(&html)
        .map(|c| c[1].replace("\\/", "/"))
        .unwrap_or_default();
    if stream.is_empty() {
        return Err(ApiError::Internal("悟空未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let html = get_gated(&format!("{BASE}/sou/{}-.html", enc_path(query))).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abs_url_shapes() {
        assert_eq!(abs_url("//x.com/a.jpg"), "https://x.com/a.jpg");
        assert_eq!(abs_url("/upload/a.webp"), format!("{BASE}/upload/a.webp"));
        assert_eq!(abs_url("upload/a.webp"), format!("{BASE}/upload/a.webp"));
        assert_eq!(abs_url("https://x.com/a.jpg"), "https://x.com/a.jpg");
    }

    #[test]
    fn parse_cards_sample() {
        let html = r#"<div class="card"><a class="pic" href="/play/314061.html" title="标题" style="background-image:url(/upload/vod/a.webp)"></a><span class="sub-hits">850观看</span></div></div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "314061");
        assert_eq!(items[0]["cover"], format!("{BASE}/upload/vod/a.webp"));
        assert_eq!(items[0]["remark"], "850观看");
    }

    #[test]
    fn parse_cards_fallback() {
        let html = r#"<a class="title" href="/play/123.html" title="无图标题">x</a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["cover"], "");
    }
}
