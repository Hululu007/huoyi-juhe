//! 91成人（vaq68-90993-asyuua.miupiupiupiav131b72.top）：镜像域名站。
//!
//! - BASE 为轮换镜像域名；UA Chrome 124，Referer BASE/。
//! - 分类 65 个（已删 id 240 萝莉少女；1 与 51 同名不同 id
//!   均保留；86 女优及各女优名为正式分类）。
//! - 列表：/show/{id}/，翻页 /show/{id}/page/{N}/；按
//!   <section class="item-box"> 切分，取 voddetail 链接、标题、
//!   首张 img 封面、首个 small 备注；首页列表用 /light/。
//! - 详情：/voddetail/{id}/；标题 h1；封面为首张不含 /MDassets/、
//!   /upload/site/、/upload/addon/、favicon、touxiang、
//!   appdownload 的 img；简介取 meta description（tx-text
//!   正则实测取不到）；线路名取 vod-episodes-source 行去
//!   “播放線路：/播放线路：”前缀；剧集取 /v/N-N-N/ 链接。
//! - 取流：video_id 去首尾 / 与 v/ 前缀，GET /v/{id}/，
//!   player_aaaa 配对 JSON 取 url（回退 m3u8 正则），\/ 还原。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://vaq68-90993-asyuua.miupiupiupiav131b72.top";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

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
        return Err(ApiError::Internal(format!("91成人请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 1500 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("91成人页面异常（疑似盾拦截）".into()));
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

/// 配对括号扫描：从 start 处的 { 开始取完整 JSON 对象子串。
fn balanced_json(s: &str, start: usize) -> Option<String> {
    let bytes = s.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c == '\\' {
            i += 2;
            continue;
        }
        if in_str {
            if c == '"' {
                in_str = false;
            }
        } else if c == '"' {
            in_str = true;
        } else if c == '{' {
            depth += 1;
        } else if c == '}' {
            if depth - 1 == 0 {
                return Some(s[start..=i].to_string());
            }
            depth -= 1;
        }
        i += 1;
    }
    None
}

fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let link_re = Regex::new(r#"href="/voddetail/(\d+)/" title="([^"]+)""#).unwrap();
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).unwrap();
    let small_re = Regex::new(r"(?s)<small[^>]*>(.*?)</small>").unwrap();
    for chunk in html.split("<section class=\"item-box\">") {
        let link = match link_re.captures(chunk) {
            Some(c) => c,
            None => continue,
        };
        let id = link[1].to_string();
        let title = clean(&link[2]);
        if title.is_empty() {
            continue;
        }
        let pic = img_re
            .captures(chunk)
            .map(|c| abs_url(&c[1]))
            .unwrap_or_default();
        let remark = small_re
            .captures(chunk)
            .map(|c| clean(&c[1]))
            .unwrap_or_default();
        items.push(item_json(&id, &title, &pic, &remark));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let cats: [(i64, &str); 63] = [
        (269, "AI短剧"),
        (234, "自拍/偷拍"),
        (233, "主播大秀"),
        (232, "网曝黑料"),
        (163, "国产视频"),
        (17, "国产精品"),
        (237, "抖阴视频"),
        (235, "国产自拍"),
        (2, "国产传媒"),
        (241, "网红头条"),
        (239, "探花系列"),
        (238, "AV解说"),
        (227, "综合传媒"),
        (231, "扣扣传媒"),
        (38, "麻豆合集"),
        (109, "葫芦影业"),
        (226, "猫爪影像"),
        (111, "天美传媒"),
        (112, "果冻传媒"),
        (131, "91制片厂"),
        (113, "蜜桃传媒"),
        (114, "精东影业"),
        (115, "皇家华人"),
        (120, "兔子先生"),
        (86, "女优"),
        (89, "波多野結衣"),
        (87, "三上悠亚"),
        (88, "高桥圣子"),
        (90, "葵司"),
        (91, "水卜櫻"),
        (92, "紗倉真菜"),
        (136, "久留木玲"),
        (93, "桃乃木香奈"),
        (95, "天使萌"),
        (96, "相澤南"),
        (97, "櫻空桃"),
        (100, "山岸逢花"),
        (103, "松本一香"),
        (207, "夢乃愛華"),
        (104, "木下日葵"),
        (225, "综合番号"),
        (142, "200GANA"),
        (146, "259LUXU"),
        (143, "300MIUM"),
        (149, "300MAAN"),
        (190, "MIAA"),
        (191, "SSIS"),
        (186, "STARS"),
        (1, "日本有码"),
        (51, "日本有码"),
        (53, "绝美少女"),
        (58, "日本口爆"),
        (7, "日本巨乳"),
        (9, "制服诱惑"),
        (13, "中文字幕"),
        (5, "日本无码"),
        (30, "欧美"),
        (32, "巨乳无码"),
        (34, "人妻无码"),
        (35, "制服无码"),
        (221, "日本无码"),
        (223, "乱伦无码"),
        (224, "强奸无码"),
    ];
    let list: Vec<Value> = cats
        .iter()
        .map(|(id, name)| category_json(&id.to_string(), name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page > 1 {
        format!("{BASE}/show/{category_id}/page/{page}/")
    } else {
        format!("{BASE}/show/{category_id}/")
    };
    let html = get_text(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items, "has_more": items.len() >= 50}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id
        .trim_start_matches("/voddetail/")
        .trim_end_matches('/')
        .trim_end_matches(".html")
        .to_string();
    let html = get_text(&format!("{BASE}/voddetail/{id}/")).await?;
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
    }
    if title.is_empty() {
        title = "91成人".to_string();
    }
    let cover = {
        let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).unwrap();
        let bad = [
            "/MDassets/",
            "/upload/site/",
            "/upload/addon/",
            "favicon",
            "touxiang",
            "appdownload",
        ];
        let mut found = String::new();
        for c in img_re.captures_iter(&html) {
            let u = c[1].to_string();
            if bad.iter().any(|b| u.contains(b)) {
                continue;
            }
            found = abs_url(&u);
            break;
        }
        found
    };
    let intro = {
        let d_re = Regex::new(r#"<meta[^>]*name="description"[^>]*content="([^"]*)""#).unwrap();
        let d_re2 = Regex::new(r#"<meta[^>]*content="([^"]*)"[^>]*name="description""#).unwrap();
        let mut s = d_re
            .captures(&html)
            .or_else(|| d_re2.captures(&html))
            .map(|c| clean(&c[1]))
            .unwrap_or_default();
        if s.is_empty() {
            let tx_re = Regex::new(r#"(?s)<div class="tx-text[^"]*"><p>(.*?)</p>"#).unwrap();
            s = tx_re
                .captures(&html)
                .map(|c| clean(&c[1]))
                .unwrap_or_default();
        }
        s
    };
    let line = {
        let l_re = Regex::new(r#"<p class="vod-episodes-source">([^<]+)</p>"#).unwrap();
        let mut s = l_re
            .captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default();
        for p in ["播放線路：", "播放线路："] {
            if let Some(t) = s.strip_prefix(p) {
                s = t.trim().to_string();
                break;
            }
        }
        if s.is_empty() {
            s = "在线播放".to_string();
        }
        s
    };
    let ep_re = Regex::new(r#"href="/v/(\d+-\d+-\d+)/" title="播放 ([^"]+)""#).unwrap();
    let mut episodes = Vec::new();
    for c in ep_re.captures_iter(&html) {
        episodes.push(episode_json(&c[1], &clean(&c[2]), series_id));
    }
    if episodes.is_empty() {
        let ep_re2 = Regex::new(r#"href="/v/(\d+-\d+-\d+)/"[^>]*>([^<]+)</a>"#).unwrap();
        for c in ep_re2.captures_iter(&html) {
            let name = clean(&c[2]);
            if name.is_empty() {
                continue;
            }
            episodes.push(episode_json(&c[1], &name, series_id));
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("{id}-1-1"), "正片", series_id));
    }
    let mut syn = String::from("站源：91成人，免登录直取");
    if !line.is_empty() {
        syn.push_str(&format!("\n线路：{line}"));
    }
    if !intro.is_empty() {
        syn.push_str(&format!("\n简介：{intro}"));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": syn,
        "extra": {"vod_play_from": line},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut vid = video_id.trim_matches('/').to_string();
    if let Some(rest) = vid.strip_prefix("v/") {
        vid = rest.to_string();
    }
    let html = get_text(&format!("{BASE}/v/{vid}/")).await?;
    let mut stream = String::new();
    if let Some(pos) = html.find("player_aaaa") {
        let rest = &html[pos..];
        if let Some(bpos) = rest.find('{') {
            if let Some(obj) = balanced_json(rest, bpos) {
                if let Ok(v) = serde_json::from_str::<Value>(&obj) {
                    stream = v
                        .get("url")
                        .and_then(|u| u.as_str())
                        .unwrap_or("")
                        .to_string();
                }
            }
        }
    }
    if stream.is_empty() {
        let url_re = Regex::new(r#""url"\s*:\s*"([^"]+\.m3u8[^"]*)""#).unwrap();
        stream = url_re
            .captures(&html)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
    }
    let stream = stream.replace("\\/", "/");
    if stream.is_empty() {
        return Err(ApiError::Internal("91成人未取到播放地址".into()));
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{BASE}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let html = get_text(&format!("{BASE}/s/wd/{}/", enc_path(query))).await?;
    Ok(json!({"items": parse_list(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_sample() {
        let html = r#"<section class="item-box"><a href="/voddetail/935151/" title="标题"><img src="https://g.com/a.jpg?t=1"></a><small>国产精品</small></section>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "935151");
        assert_eq!(items[0]["cover"], "https://g.com/a.jpg?t=1");
        assert_eq!(items[0]["remark"], "国产精品");
    }

    #[test]
    fn balanced_json_pairs() {
        let s = r#"player_aaaa = {"url":"https://x.com/a.m3u8","a":{"b":1}};"#;
        let start = s.find('{').unwrap();
        let obj = balanced_json(s, start).unwrap();
        let v: Value = serde_json::from_str(&obj).unwrap();
        assert_eq!(v["url"], "https://x.com/a.m3u8");
        assert_eq!(v["a"]["b"], 1);
    }

    #[test]
    fn abs_url_shapes() {
        assert_eq!(abs_url("//x.com/a.jpg"), "https://x.com/a.jpg");
        assert_eq!(abs_url("/upload/a.jpg"), format!("{BASE}/upload/a.jpg"));
        assert_eq!(abs_url("https://x.com/a.jpg"), "https://x.com/a.jpg");
    }
}
