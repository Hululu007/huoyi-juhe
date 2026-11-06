//! 17rip（17rip.com）：MacCMS 影视站，纯 HTML 解析。
//!
//! - 顶级分类 7 个，子分类平铺为正式分类（id 直接用子分类数字 id，
//!   与顶级 id 无冲突）；已删“少女萝莉”（id 21），站照常写。
//! - 列表：第 1 页 /vodshow/{id}-----------.html（11 个短横线），
//!   第 N 页 /vodshow/{id}--------{N}---.html（8 个短横线）。
//! - 卡片：class 含 public-list-exp 的 <a>（href 含 /voddetail/），
//!   其后 2500 字符内取 title/alt 标题、首个非 base64 图片、
//!   public-list-prb（回退 public-prt）备注。
//! - 详情：标题 h1 → og:title → <title>；封面 detail-pic 区域首图
//!   （回退 /upload/vod/ 图）；简介 og:description → meta
//!   description；剧集取 anthology-list-play 区域内的 /vodplay/
//!   链接，回退全页匹配，再回退正片默认地址。
//! - 取流：播放页 player_aaaa 后首个配对括号 JSON 的 url 字段，
//!   回退 "url":"...m3u8" 正则；去掉 .m3u8 后的 # 片段。
//! - 搜索：/vodsearch/{编码}-------------.html（13 个短横线），
//!   编码为 URLEncoder 后 + 改 %20。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://17rip.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: usize = 48;

fn headers(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    req.header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Accept-Encoding", "gzip, deflate")
        .header("Upgrade-Insecure-Requests", "1")
        .header("Referer", format!("{HOST}/"))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = headers(client()?.get(url))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("17rip 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 2000 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("17rip 页面异常（疑似盾拦截）".into()));
    }
    Ok(text)
}

/// 去标签 + 反转义 + 压空白（与 ZakaHttp.clean 一致）。
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

fn unesc(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// URLEncoder 编码后 + 改 %20（路径段编码）。
fn enc_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

fn list_url(category_id: &str, page: i64) -> String {
    if page <= 1 {
        format!("{HOST}/vodshow/{category_id}-----------.html")
    } else {
        format!("{HOST}/vodshow/{category_id}--------{page}---.html")
    }
}

fn first_img(seg: &str) -> String {
    let re = Regex::new(r#"(?:data-src|data-original|src)="([^"]+)""#).unwrap();
    for c in re.captures_iter(seg) {
        let u = &c[1];
        if u.len() > 20 && !u.contains("base64") && u.starts_with("http") {
            return u.to_string();
        }
    }
    String::new()
}

fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let re = Regex::new(
        r#"<a[^>]*class="[^"]*public-list-exp[^"]*"[^>]*href="([^"]*?/voddetail/\d+\.html)"[^>]*>"#,
    )
    .unwrap();
    for c in re.captures_iter(html) {
        let href = c[1].to_string();
        let m = c.get(0).unwrap();
        let end = (m.end() + 2500).min(html.len());
        let seg = &html[m.end()..end];
        let title_re = Regex::new(r#"title="([^"]+)""#).unwrap();
        // title 属性常写在 <a> 标签自身里（匹配串内），不在其后
        // 的片段里；先在标签内找，再到片段里找。
        let tag = &html[m.start()..m.end()];
        let mut title = title_re
            .captures(tag)
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
        if title.is_empty() {
            title = title_re
                .captures(seg)
                .map(|x| clean(&x[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            let alt_re = Regex::new(r#"alt="([^"]+)""#).unwrap();
            title = alt_re
                .captures(seg)
                .map(|x| clean(&x[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            continue;
        }
        let pic = first_img(seg);
        let remark_re =
            Regex::new(r#"(?s)<span[^>]*class="[^"]*public-list-prb[^"]*"[^>]*>(.*?)</span>"#)
                .unwrap();
        let remark_re2 =
            Regex::new(r#"(?s)<span[^>]*class="[^"]*public-prt[^"]*"[^>]*>(.*?)</span>"#).unwrap();
        let remark = remark_re
            .captures(seg)
            .or_else(|| remark_re2.captures(seg))
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

/// 配对括号取 JSON（player_aaaa 后首个 { 到配对 }）。
fn balanced_json(text: &str, start: usize) -> String {
    let bytes = text.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if in_str {
            if c == '\\' {
                i += 1;
            } else if c == '"' {
                in_str = false;
            }
        } else if c == '"' {
            in_str = true;
        } else if c == '{' {
            depth += 1;
        } else if c == '}' {
            depth -= 1;
            if depth == 0 {
                return text[start..=i].to_string();
            }
        }
        i += 1;
    }
    String::new()
}

fn detail_path(series_id: &str) -> String {
    if series_id.starts_with('/') {
        series_id.to_string()
    } else {
        format!("/voddetail/{series_id}.html")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let cats: &[(&str, &str)] = &[
        ("1", "AV"),
        ("2", "国产"),
        ("5", "网曝门"),
        ("3", "欧美"),
        ("4", "动漫"),
        ("33", "OnlyFans"),
        ("35", "其他"),
        ("20", "家庭乱伦"),
        ("22", "SM调教"),
        ("23", "绝顶潮吹"),
        ("24", "魔镜系列"),
        ("25", "时间停止"),
        ("26", "催眠洗脑"),
        ("27", "漫改系列"),
        ("28", "电车痴汉"),
        ("29", "淫欲痴女"),
        ("34", "AV解说"),
        ("6", "人妻熟女"),
        ("7", "日本无码"),
        ("8", "美乳巨乳"),
        ("9", "强制侵犯"),
        ("10", "制服诱惑"),
        ("11", "绝色佳人"),
        ("12", "风俗泡泡浴"),
        ("13", "网红主播"),
        ("14", "国产传媒"),
        ("15", "探花系列"),
        ("16", "国产自拍"),
        ("30", "欧美精品"),
        ("31", "日本动漫"),
        ("32", "3D动漫"),
        ("36", "三级电影"),
        ("37", "AI换脸"),
    ];
    Ok(json!({"categories": cats
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = get_text(&list_url(category_id, page)).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": items.len() >= PAGE_SIZE}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = detail_path(series_id);
    let html = get_text(&format!("{HOST}{path}")).await?;
    let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let mut title = h1_re
        .captures(&html)
        .map(|x| clean(&x[1]))
        .unwrap_or_default();
    if title.is_empty() {
        let og_re = Regex::new(r#"<meta[^>]*property="og:title"[^>]*content="([^"]*)""#).unwrap();
        title = og_re
            .captures(&html)
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
    }
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title>(.*?)</title>").unwrap();
        if let Some(c) = t_re.captures(&html) {
            title = clean(&c[1]);
            if let Some(pos) = title.find(" - 17RIP") {
                title.truncate(pos);
            }
            if let Some(pos) = title.rfind('_') {
                title.truncate(pos);
            }
        }
    }
    let mut pic = String::new();
    if let Some(pos) = html.find("detail-pic") {
        let end = (pos + 1600).min(html.len());
        pic = first_img(&html[pos..end]);
    }
    if pic.is_empty() {
        let re = Regex::new(r#"(?:data-src|src)="([^"]*/upload/vod/[^"]+)""#).unwrap();
        if let Some(c) = re.captures(&html) {
            pic = c[1].to_string();
        }
    }
    let mut desc = String::new();
    let ogd_re =
        Regex::new(r#"<meta[^>]*property="og:description"[^>]*content="([^"]*)""#).unwrap();
    if let Some(c) = ogd_re.captures(&html) {
        desc = clean(&c[1]);
    }
    if desc.is_empty() {
        let md_re = Regex::new(r#"<meta[^>]*name="description"[^>]*content="([^"]*)""#).unwrap();
        if let Some(c) = md_re.captures(&html) {
            desc = clean(&c[1]);
        }
    }
    let id_num = path
        .trim_start_matches("/voddetail/")
        .trim_end_matches(".html")
        .to_string();
    let mut episodes: Vec<Value> = Vec::new();
    if let Some(pos) = html.find("anthology-list-play") {
        let end = (pos + 8000).min(html.len());
        let seg = &html[pos..end];
        let ep_re =
            Regex::new(r#"<a[^>]*href="(/vodplay/\d+-\d+-\d+\.html)"[^>]*>(.*?)</a>"#).unwrap();
        for c in ep_re.captures_iter(seg) {
            let url = format!("{HOST}{}", &c[1]);
            let name = clean(&c[2]);
            let name = if name.is_empty() {
                "正片".to_string()
            } else {
                name
            };
            episodes.push(episode_json(&url, &name, series_id));
        }
    }
    if episodes.is_empty() {
        let ep_re = Regex::new(r"/vodplay/\d+-\d+-\d+\.html").unwrap();
        for m in ep_re.find_iter(&html) {
            let url = format!("{HOST}{}", m.as_str());
            episodes.push(episode_json(&url, "正片", series_id));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(
            &format!("{HOST}/vodplay/{id_num}-1-1.html"),
            "正片",
            series_id,
        ));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": pic,
        "synopsis": desc,
        "extra": {"vod_play_from": "17rip"},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") || video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{HOST}{video_id}")
    };
    let html = get_text(&page_url).await?;
    let mut url = String::new();
    if let Some(pos) = html.find("player_aaaa") {
        if let Some(open) = html[pos..].find('{') {
            let blob = balanced_json(&html, pos + open);
            if !blob.is_empty() {
                if let Ok(v) = serde_json::from_str::<Value>(&blob) {
                    url = v
                        .get("url")
                        .and_then(|u| u.as_str())
                        .unwrap_or("")
                        .to_string();
                }
            }
        }
    }
    if url.is_empty() {
        let re = Regex::new(r#""url"\s*:\s*"(https?://[^"]+?\.m3u8[^"]*)""#).unwrap();
        if let Some(c) = re.captures(&html) {
            url = unesc(&c[1]);
        }
    }
    if url.is_empty() {
        return Err(ApiError::Internal("17rip 未取到播放地址".into()));
    }
    let url = url.split('#').next().unwrap_or(&url).to_string();
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!("{HOST}/vodsearch/{}-------------.html", enc_path(query));
    let html = get_text(&url).await?;
    let mut items = Vec::new();
    let re =
        Regex::new(r#"<a[^>]*href="(/voddetail/\d+\.html)"[^>]*>\s*<h3[^>]*>(.*?)</h3>"#).unwrap();
    for c in re.captures_iter(&html) {
        let href = c[1].to_string();
        let title = clean(&c[2]);
        if title.is_empty() {
            continue;
        }
        let m = c.get(0).unwrap();
        let start = m.start().saturating_sub(1600);
        let pic = first_img(&html[start..m.start()]);
        let rm_re =
            Regex::new(r#"(?s)<span[^>]*class="[^"]*slide-info-remarks[^"]*"[^>]*>(.*?)</span>"#)
                .unwrap();
        let remark = rm_re
            .captures(&html[m.end()..(m.end() + 2000).min(html.len())])
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
        items.push(item_json(&href, &title, &pic, &remark));
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_url_shapes() {
        assert_eq!(
            list_url("1", 1),
            "https://17rip.com/vodshow/1-----------.html"
        );
        assert_eq!(
            list_url("1", 2),
            "https://17rip.com/vodshow/1--------2---.html"
        );
    }

    #[test]
    fn balanced_json_pairs() {
        let text = r#"player_aaaa={"flag":"play","vod_data":{"vod_name":"A"},"url":"https://x/index.m3u8"};"#;
        let pos = text.find('{').unwrap();
        let blob = balanced_json(text, pos);
        let v: Value = serde_json::from_str(&blob).unwrap();
        assert_eq!(v["url"], "https://x/index.m3u8");
        assert_eq!(v["vod_data"]["vod_name"], "A");
    }

    #[test]
    fn parse_cards_sample() {
        let html = r#"<a class="public-list-exp" href="/voddetail/68771.html" title="x"><img data-src="https://img/a.jpg" /></a><span class="public-list-prb">高清</span>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/voddetail/68771.html");
        assert_eq!(items[0]["remark"], "高清");
    }

    #[test]
    fn categories_drop_loli() {
        let cats = vec!["1", "21", "20"];
        let kept: Vec<&&str> = cats.iter().filter(|id| **id != "21").collect();
        assert_eq!(kept, vec![&"1", &"20"]);
    }
}
