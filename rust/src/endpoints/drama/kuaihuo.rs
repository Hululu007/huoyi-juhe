//! 快活影院：静态站直取 + ES 搜索。
//!
//! 来源 jar 类 `ZakaKuaihuoAmns`。基址 2026-11-05 实测已由
//! `https://tbryy.opsizte.com` 换成 `https://tbryy.ksdlcme.cn`
//!（旧域目录仍通、详情 301 到新域首页）。目录页走
//! `/{slug}/list_{N}.html`；搜索走 ES 接口
//! `https://ser.m3u8111222333.com/.netlify/functions/search`；
//! 详情页取 `var playUrl="..."`，其中的 `+@xxx@+` 占位换成
//! `stream1.kkodjj.com` 才是真实流地址（站内 replace.js 的现
//! 值；jar 里的 pkckgcg.com 已过期，2026-11-05 实测 404）。
//! 搜索封面 `/pic/...` 拼 `https://res1.kkodjj.com`。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://tbryy.ksdlcme.cn";
const SEARCH_API: &str = "https://ser.m3u8111222333.com/.netlify/functions/search";
const SEARCH_ORIGIN: &str = "https://ser.m3u8111222333.com";
const PIC_BASE: &str = "https://res1.kkodjj.com";
const MEDIA_HOST: &str = "stream1.kkodjj.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("shipin", "视频·最新"),
    ("dianying", "电影·最新"),
    ("yazhouav", "亚洲AV"),
    ("zipaitoupai", "自拍偷拍"),
    ("oumeiav", "欧美AV"),
    ("3ddonghua", "3D动画"),
    ("shunvrenqi", "熟女人妻"),
    ("siwazhifu", "丝袜制服"),
    ("zhubozhibo", "主播直播"),
    ("smlinglei", "SM另类"),
    ("yazhouxingai", "亚洲性爱"),
    ("toupaizipai", "偷拍自拍"),
    ("chengrenkatong", "成人卡通"),
    ("oumeixingai", "欧美性爱"),
    ("zhifusiwa", "制服丝袜"),
    ("sanjijingdian", "经典三级"),
    ("luanlunshunv", "乱伦熟女"),
    ("lingleibiantai", "另类变态"),
];

static P_CARD: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<li>\s*<a\s+href="(/htm/[^"]+)"\s+title="([^"]*)""#).unwrap());
static P_H3: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<h3[^>]*>(.*?)</h3>").unwrap());
static P_IMG: Lazy<Regex> = Lazy::new(|| Regex::new(r#"(?:data-original|src)="([^"]+)""#).unwrap());
static P_REMARK: Lazy<Regex> = Lazy::new(|| Regex::new(r"<i>([^<]+)</i>").unwrap());
static P_PAGES: Lazy<Regex> = Lazy::new(|| Regex::new(r"href='[^']*?/list_(\d+)\.html'").unwrap());

fn unescape(s: &str) -> String {
    let mut out = s
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ");
    let re = Regex::new(r"&#(x?)([0-9a-fA-F]+);").unwrap();
    while let Some(cap) = re.captures(&out.clone()) {
        let full = cap.get(0).unwrap().as_str().to_string();
        let num = cap.get(2).unwrap().as_str();
        let parsed = if cap.get(1).unwrap().as_str() == "x" {
            i64::from_str_radix(num, 16).ok()
        } else {
            num.parse::<i64>().ok()
        };
        let replacement = parsed
            .and_then(|n| char::from_u32(n as u32))
            .map(|c| c.to_string())
            .unwrap_or_default();
        out = out.replacen(&full, &replacement, 1);
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

fn abs_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with('/') {
        format!("{BASE}{u}")
    } else {
        u.to_string()
    }
}

async fn html(path: &str, needle: &str) -> ApiResult<String> {
    let url = format!("{BASE}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("快活影院请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 2000 || (!needle.is_empty() && !text.contains(needle)) {
        return Err(ApiError::Internal("快活影院页面内容不符合预期".into()));
    }
    Ok(text)
}

fn cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in P_CARD.captures_iter(page) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let mut title = unescape(cap.get(2).map(|m| m.as_str()).unwrap_or(""));
        if !seen.insert(href.to_string()) {
            continue;
        }
        let start = cap.get(0).unwrap().start();
        let window = &page[start..page.len().min(start + 1600)];
        if title.is_empty() {
            title = P_H3
                .captures(window)
                .and_then(|c| c.get(1))
                .map(|m| unescape(m.as_str()))
                .unwrap_or_default();
        }
        let cover = P_IMG
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| abs_url(m.as_str()))
            .unwrap_or_default();
        let remark = P_REMARK
            .captures(window)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        items.push(item_json(href, &title, &cover, &remark));
    }
    items
}

fn cap1(re: &Regex, text: &str) -> String {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default()
}

/// `+@xxx@+` 占位换成真实媒体 host。
fn real_url(raw: &str) -> String {
    static RE_PLACE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\+@[a-zA-Z0-9_.\-]+@\+").unwrap());
    let mut url = RE_PLACE.replace_all(raw, MEDIA_HOST).to_string();
    if url.starts_with("//") {
        url = format!("https:{url}");
    } else if url.starts_with("http://") {
        url = url.replacen("http://", "https://", 1);
    }
    url
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = Vec::new();
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let slug = if category_id.is_empty() {
        "shipin"
    } else {
        category_id
    };
    let path = if page > 1 {
        format!("/{slug}/list_{page}.html")
    } else {
        format!("/{slug}/index.html")
    };
    let page_html = html(&path, "/htm/").await?;
    let items = cards(&page_html);
    let max_page = P_PAGES
        .captures_iter(&page_html)
        .filter_map(|c| c.get(1)?.as_str().parse::<i64>().ok())
        .max()
        .unwrap_or(0);
    let has_more = if max_page > 0 {
        page < max_page
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let path = if series_id.starts_with('/') {
        series_id.to_string()
    } else {
        format!("/{series_id}")
    };
    let page_html = html(&path, "playUrl").await?;
    let re_h1 = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
    let re_title = Regex::new(r"<title>([^<]+)</title>").unwrap();
    let re_poster = Regex::new(r#"var posterImg="([^"]+)""#).unwrap();
    let re_play = Regex::new(r#"var playUrl="([^"]+)""#).unwrap();
    let re_date = Regex::new(r"/htm/(\d{4})/(\d{2})/(\d{2})/").unwrap();
    let re_cat = Regex::new(r"/htm/\d{4}/\d{2}/\d{2}/([^/]+)/").unwrap();
    let mut title = re_h1
        .captures(&page_html)
        .and_then(|c| c.get(1))
        .map(|m| strip_tags(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        title = cap1(&re_title, &page_html)
            .replace("快活影院", "")
            .trim_matches(|c| c == '-' || c == ' ')
            .to_string();
    }
    let cover = abs_url(&cap1(&re_poster, &page_html));
    let play_url = real_url(&cap1(&re_play, &page_html));
    let date = re_date
        .captures(&path)
        .map(|c| {
            format!(
                "{}-{}-{}",
                c.get(1).unwrap().as_str(),
                c.get(2).unwrap().as_str(),
                c.get(3).unwrap().as_str()
            )
        })
        .unwrap_or_default();
    let cat = cap1(&re_cat, &path);
    let cat_name = CATS
        .iter()
        .find(|(slug, _)| *slug == cat)
        .map(|(_, name)| *name)
        .unwrap_or("");
    let synopsis = format!(
        "{}{}{}来源：快活影院",
        if cat_name.is_empty() {
            String::new()
        } else {
            format!("分类：{cat_name}\n")
        },
        if date.is_empty() {
            String::new()
        } else {
            format!("日期：{date}\n")
        },
        ""
    );
    if play_url.len() <= 20 {
        return Err(ApiError::Internal("快活影院详情未取到播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"category": cat_name, "date": date},
        "episodes": [episode_json(&play_url, "正片", series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let body = json!({
        "query": {"bool": {"must": [{"multi_match": {"query": query, "fields": ["data_name", "data_intro", "data_actor"]}}]}},
        "highlight": {"fragment_size": 200, "number_of_fragments": 1, "fields": {"data_name": {}, "data_intro": {}}},
        "_source": ["id", "data_name", "data_intro", "data_actor", "class_dir", "data_picbig", "year", "month", "day"],
        "aggs": {"class_name": {"terms": {"field": "class_name", "size": 30}}},
        "size": 40,
        "from": 0
    });
    let resp = client()?
        .post(SEARCH_API)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Origin", SEARCH_ORIGIN)
        .header("Referer", format!("{SEARCH_ORIGIN}/"))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("快活影院搜索 HTTP {status}")));
    }
    let result: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let mut items = Vec::new();
    if let Some(hits) = get(&result, "hits")
        .and_then(|h| get(h, "hits"))
        .and_then(|v| v.as_array())
    {
        for hit in hits {
            let src = get(hit, "_source").cloned().unwrap_or(Value::Null);
            let id = text_of(&src, &["id"]);
            let name = text_of(&src, &["data_name"]);
            let class_dir = text_of(&src, &["class_dir"]);
            let year = text_of(&src, &["year"]);
            let month = text_of(&src, &["month"]);
            let day = text_of(&src, &["day"]);
            let actor = text_of(&src, &["data_actor"]);
            if id.is_empty() || name.is_empty() {
                continue;
            }
            let href = format!("/htm/{year}/{month}/{day}/{class_dir}/{id}.html");
            let mut cover = text_of(&src, &["data_picbig"]);
            if cover.starts_with('/') {
                cover = format!("{PIC_BASE}{cover}");
            }
            items.push(item_json(&href, &name, &cover, &actor));
        }
    }
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.is_empty() {
        return Err(ApiError::Internal("快活影院没有播放地址".into()));
    }
    Ok(json!({"url": video_id}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_url_replaces_placeholder() {
        // 模块头已记：stream1.kkodjj.com 才是真实流地址，jar 里
        // 的 pkckgcg.com 已过期（2026-11-05 实测 404）。
        assert_eq!(
            real_url("https://+@movivecom@+/v/1.m3u8"),
            "https://stream1.kkodjj.com/v/1.m3u8"
        );
        assert_eq!(
            real_url("//+@abc@+/x.mp4"),
            "https://stream1.kkodjj.com/x.mp4"
        );
        assert_eq!(
            real_url("http://stream1.pkckgcg.com/x.mp4"),
            "https://stream1.pkckgcg.com/x.mp4"
        );
    }

    #[test]
    fn unescape_numeric_entities() {
        // &#12298; 就是 U+300A 《，不是 U+3008 〈。
        assert_eq!(unescape("&#12298;&#32473;&#39640;&#19977;"), "《给高三");
    }

    #[test]
    fn cards_parse_sample() {
        let html = r#"<li><a href="/htm/2026/01/01/shipin/123.html" title="Sample"><img data-original="//img.example.com/1.jpg"><i>12:34</i></a></li>"#;
        let items = cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/htm/2026/01/01/shipin/123.html");
        assert_eq!(items[0]["title"], "Sample");
        assert_eq!(items[0]["cover"], "https://img.example.com/1.jpg");
        assert_eq!(items[0]["remark"], "12:34");
    }
}
