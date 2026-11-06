//! PacHub：核心里的影视区站点。
//!
//! 与 py 版 pachub.py 同一套分类、同一条已验播放链：分类与站 /av 过
//! 滤条 1:1（全部国产 + 21 个厂牌来源，萝莉社已删；AI 区只有
//! AI成人短剧一个分类，写真/Cosplay/韩漫是图片与漫画、不进视频
//! 区）；目录走站内 /api/videos 与 /api/ai 列表接口（24 条一页，
//! AV 按厂牌、AI 按集）；详情分两种：AV 单片（/av/<id>）、AI
//! 短剧（/ai/<系列>，各集为 /ai/<系列>-ep-<n>）；取流为详情页
//! StreamPlayer 的 /api/<av|ai>/<id>/stream，须 POST 且带
//! Origin + Referer（否则 403），回 m3u8Url；AV 直接给直链，AI
//! 给站内 /proxy/m3u8?u=<base64>，解开即直链（AES-128 清单，首
//! 分片已验 200）。标题不删（用户 22:39 铁律：标题是站长为推流故意写
//! 的假的，用户已亲自验过站内内容）。

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const BASE: &str = "https://pachub.net";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类表：实测于 2026-11-05。id、显示名、目录接口用的分类名
/// （空即全部）。萝莉社（668 部）已按规则删除。
const CATS: &[(&str, &str, &str)] = &[
    ("av-all", "全部国产", ""),
    ("av-kxgc", "开心鬼传媒", "开心鬼传媒"),
    ("av-mdsp", "麻豆视频", "麻豆视频"),
    ("av-crtt", "成人头条", "成人头条"),
    ("av-mini", "mini传媒", "mini传媒"),
    ("av-lbsc", "乐播传媒", "乐播传媒"),
    ("av-wjcm", "乌鸦传媒", "乌鸦传媒"),
    ("av-txvlog", "糖心Vlog", "糖心vlog"),
    ("av-91sp", "91视频", "91视频"),
    ("av-dxcm", "大象传媒", "大象传媒"),
    ("av-xkcm", "星空传媒", "星空传媒"),
    ("av-mtcm", "蜜桃传媒", "蜜桃传媒"),
    ("av-jdyy", "精东影业", "精东影业"),
    ("av-tmcm", "天美传媒", "天美传媒"),
    ("av-91zpc", "91制片厂", "91制片厂"),
    ("av-xbzc", "杏吧原创", "杏吧原创"),
    ("av-xsj", "性视界", "性视界"),
    ("av-hjhr", "皇家华人", "皇家华人"),
    ("av-tzxs", "兔子先生", "兔子先生"),
    ("av-psycho", "PsychoPorn", "psychoporn"),
    ("av-hjsw", "海角社区", "海角社区"),
    ("av-wjjj", "玩偶姐姐", "玩偶姐姐"),
    ("ai-dj", "AI成人短剧", "AI成人短剧"),
];

fn fmt_duration(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", BASE)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("PacHub 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 站内代理地址解开：/proxy/m3u8?u=<base64> 解出直链；本身已是
/// 直链或解不开时原样返回。
fn direct_url(raw: &str) -> String {
    let u = raw.trim();
    if let Some(rest) = u.strip_prefix("/proxy/m3u8?u=") {
        let b64 = rest.split('&').next().unwrap_or("");
        let mut padded = b64.to_string();
        while padded.len() % 4 != 0 {
            padded.push('=');
        }
        if let Ok(bytes) = B64.decode(padded.as_bytes()) {
            if let Ok(decoded) = String::from_utf8(bytes) {
                let d = decoded.trim().to_string();
                if d.starts_with("http") {
                    return d;
                }
            }
        }
        return format!("{BASE}{u}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

/// /api/videos 与 /api/ai 的 items 解析：AV 用数字 id，AI 用
/// sourceId（系列或系列-ep-n）。
fn parse_api_items(body: &Value, ai: bool) -> Vec<Value> {
    let mut items = Vec::new();
    let list = match get(body, "items").and_then(arr_of) {
        Some(v) => v,
        None => return items,
    };
    for entry in list {
        let title = text_of(entry, &["title"]);
        if title.is_empty() {
            continue;
        }
        let cover = text_of(entry, &["coverUrl"]);
        let remark = fmt_duration(int_of(entry, &["duration"]));
        let id = if ai {
            let sid = text_of(entry, &["sourceId"]);
            if sid.is_empty() {
                continue;
            }
            format!("ai/{sid}")
        } else {
            let num = int_of(entry, &["id"]);
            if num == 0 {
                continue;
            }
            format!("av/{num}")
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn page_total(body: &Value) -> Option<i64> {
    let pages = int_of(body, &["pages"]);
    if pages > 0 {
        Some(pages)
    } else {
        None
    }
}

/// 搜索页 HTML 卡片解析：/av/<id> 与 /ai/<系列> 两种锚点。
fn parse_html_cards(html: &str) -> Vec<Value> {
    let anchor_re = match Regex::new(r#"<a[^>]*href="/(av|ai)/([^"]+)"[^>]*aria-label="([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let img_re = Regex::new(r#"<img[^>]*src="(https://cdn\.pachub\.net/[^"]+)""#).ok();
    let dur_re = Regex::new(r#">(\d+:\d+(?::\d+)?)<"#).ok();
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for cap in anchor_re.captures_iter(html) {
        let kind = &cap[1];
        let path = &cap[2];
        let id = format!("{kind}/{path}");
        if !seen.insert(id.clone()) {
            continue;
        }
        let title = unescape(cap[3].trim());
        if title.is_empty() {
            continue;
        }
        let tail = &html[cap.get(0).unwrap().end()..];
        let tail = &tail[..tail.len().min(4000)];
        let cover = match &img_re {
            Some(re) => re
                .captures(tail)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let remark = match &dur_re {
            Some(re) => re
                .captures(tail)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATS
            .iter()
            .map(|(id, name, _)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let cat = CATS.iter().find(|(id, _, _)| *id == category_id);
    let Some((_, _, name)) = cat else {
        return Err(ApiError::BadRequest(format!(
            "PacHub 未知分类 {category_id}"
        )));
    };
    let ai = category_id == "ai-dj";
    let page_s = page.to_string();
    let params: Vec<(&str, &str)> = vec![("page", &page_s), ("page_size", "24")];
    let url = if ai {
        let mut p = params.clone();
        p.push(("category", name));
        with_query(&format!("{BASE}/api/ai"), &p)
    } else if name.is_empty() {
        with_query(&format!("{BASE}/api/videos"), &params)
    } else {
        let mut p = params.clone();
        p.push(("category", name));
        with_query(&format!("{BASE}/api/videos"), &p)
    };
    let text = get_text(&url).await?;
    let body: Value = serde_json::from_str(&text)?;
    let items = parse_api_items(&body, ai);
    let has_more = match page_total(&body) {
        Some(total) => page < total,
        None => items.len() >= 24,
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

fn meta_content(html: &str, prop: &str) -> String {
    let re = match Regex::new(&format!(
        r#"<meta[^>]*content="([^"]+)"[^>]*{prop}|<meta[^>]*{prop}[^>]*content="([^"]+)""#,
        prop = regex::escape(prop)
    )) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    match re.captures(html) {
        Some(cap) => unescape(
            cap.get(1)
                .or_else(|| cap.get(2))
                .map(|m| m.as_str())
                .unwrap_or(""),
        ),
        None => String::new(),
    }
}

fn detail_url(series_id: &str) -> String {
    if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{series_id}")
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = detail_url(series_id);
    let html = get_text(&url).await?;
    let ai = series_id.contains("/ai/") || url.contains("/ai/");
    let raw_title = meta_content(&html, "og:title");
    let suffix = if ai {
        " · AI | PacHub"
    } else {
        " · 国产 | PacHub"
    };
    let title = raw_title
        .strip_suffix(suffix)
        .unwrap_or(&raw_title)
        .trim()
        .to_string();
    let cover = meta_content(&html, "og:image");
    let desc = meta_content(&html, "description");
    let synopsis = desc.split(" — ").next().unwrap_or("").trim().to_string();
    if title.is_empty() {
        return Err(ApiError::Internal("PacHub 详情无标题".into()));
    }
    let mut episodes = Vec::new();
    if ai {
        let path = url.trim_start_matches(BASE).trim_start_matches('/');
        let series = path
            .strip_prefix("ai/")
            .unwrap_or(path)
            .split('-')
            .next()
            .unwrap_or("")
            .to_string();
        let ep_re = Regex::new(&format!(
            r#"href="/ai/{}(-ep-(\d+))?""#,
            regex::escape(&series)
        ));
        if let Ok(re) = ep_re {
            let mut nums: Vec<i64> = Vec::new();
            for cap in re.captures_iter(&html) {
                let n: i64 = cap
                    .get(2)
                    .and_then(|m| m.as_str().parse().ok())
                    .unwrap_or(1);
                if !nums.contains(&n) {
                    nums.push(n);
                }
            }
            nums.sort_unstable();
            for n in nums {
                let ep_id = if n == 1 {
                    format!("ai/{series}")
                } else {
                    format!("ai/{series}-ep-{n}")
                };
                episodes.push(episode_json(&ep_id, &format!("第{n}集"), series_id));
            }
        }
    }
    if episodes.is_empty() {
        episodes.push(episode_json(series_id, "播放", series_id));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

fn stream_endpoint(html: &str) -> Option<String> {
    let re = Regex::new(r#"apiEndpoint(?:&quot;|"):\[0,(?:&quot;|")(/api/[^&"]+/stream)"#).ok()?;
    re.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = detail_url(video_id);
    let html = get_text(&url).await?;
    let endpoint = stream_endpoint(&html)
        .ok_or_else(|| ApiError::Internal("PacHub 详情页无播放接口".into()))?;
    let resp = client()?
        .post(format!("{BASE}{endpoint}"))
        .header("User-Agent", UA)
        .header("Content-Type", "application/json")
        .header("Origin", BASE)
        .header("Referer", url.clone())
        .body("")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if status != 200 {
        return Err(ApiError::Internal(format!(
            "PacHub 取流 HTTP {status}: {}",
            &text[..text.len().min(120)]
        )));
    }
    let body: Value = serde_json::from_str(&text)?;
    let raw = text_of(&body, &["m3u8Url"]);
    if raw.is_empty() {
        return Err(ApiError::Internal("PacHub 取流无 m3u8 地址".into()));
    }
    Ok(json!({"url": direct_url(&raw)}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("q", query)]);
    let html = get_text(&url).await?;
    let items = parse_html_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_has_23_without_loli() {
        assert_eq!(CATS.len(), 23);
        assert_eq!(CATS[0], ("av-all", "全部国产", ""));
        assert_eq!(CATS[CATS.len() - 1], ("ai-dj", "AI成人短剧", "AI成人短剧"));
        assert!(!CATS.iter().any(|(_, name, _)| name.contains("萝莉")));
        assert!(!CATS.iter().any(|(_, name, _)| name.contains("萝莉社")));
    }

    #[test]
    fn fmt_duration_cases() {
        assert_eq!(fmt_duration(2163), "36:03");
        assert_eq!(fmt_duration(65), "1:05");
        assert_eq!(fmt_duration(3723), "1:02:03");
        assert_eq!(fmt_duration(0), "");
    }

    #[test]
    fn direct_url_decodes_proxy() {
        let proxied = "/proxy/m3u8?u=aHR0cHM6Ly95ZC1scGh1LWhscy5oemp2bG8uY24vdmlkZW9zNS80Njg4MmRmN2QxZTUyMDE3M2I1NTI4NWJmOWYwNTQwZC80Njg4MmRmN2QxZTUyMDE3M2I1NTI4NWJmOWYwNTQwZC5tM3U4P2F1dGhfa2V5PTE3OTM4ODA1ODctMC0wLTE3ZmJjMTA0OTFlOTgzMmU4NWE5NTU4ODg4M2YxNzJjJnY9MyZ0aW1lPTAmdmlhPWhnZGomdmlhX2JtPWR4&direct=1";
        let out = direct_url(proxied);
        assert!(out.starts_with(
            "https://yd-lphu-hls.hzjvlo.cn/videos5/46882df7d1e520173b55285bf9f0540d/"
        ));
        assert!(out.contains(".m3u8?auth_key="));
        assert_eq!(
            direct_url("https://t0.97img.com/a1002679/a.m3u8"),
            "https://t0.97img.com/a1002679/a.m3u8"
        );
    }

    #[test]
    fn parse_api_video_items_keep_all_titles() {
        let body = json!({"items": [
            {"id": 707883, "title": "粉红小萝莉-胖爷", "coverUrl": "https://cdn.pachub.net/av/cover/707883.webp", "duration": 1425},
            {"id": 708622, "title": "今天约个小嫩妹", "coverUrl": "https://cdn.pachub.net/av/cover/708622.webp", "duration": 0},
        ], "total": 2, "pages": 1});
        let items = parse_api_items(&body, false);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "av/707883");
        assert_eq!(items[0]["remark"], "23:45");
        assert_eq!(items[1]["id"], "av/708622");
        assert_eq!(
            items[1]["cover"],
            "https://cdn.pachub.net/av/cover/708622.webp"
        );
    }

    #[test]
    fn parse_api_ai_items_use_source_id() {
        let body = json!({"items": [
            {"id": 151552, "sourceId": "11413-ep-7", "title": "今夜情燃 第7集", "coverUrl": "https://cdn.pachub.net/ai/cover/151552.webp", "duration": 178},
            {"id": 151546, "sourceId": "11413", "title": "今夜情燃", "coverUrl": "https://cdn.pachub.net/ai/cover/151546.webp", "duration": 183},
        ], "total": 2, "pages": 1});
        let items = parse_api_items(&body, true);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "ai/11413-ep-7");
        assert_eq!(items[0]["remark"], "2:58");
        assert_eq!(items[1]["id"], "ai/11413");
        assert_eq!(items[1]["remark"], "3:03");
    }

    #[test]
    fn parse_html_cards_keep_all_titles_and_reads_duration() {
        let html = r#"<a href="/av/707883" aria-label="粉红小萝莉-胖爷"><img src="https://cdn.pachub.net/av/cover/707883.webp" alt="x"><span>23:45</span></a><a href="/av/708622" aria-label="今天约个小嫩妹"><img src="https://cdn.pachub.net/av/cover/708622.webp" alt="x"><span>16:20</span></a>"#;
        let items = parse_html_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "av/707883");
        assert_eq!(items[0]["remark"], "23:45");
        assert_eq!(items[1]["id"], "av/708622");
        assert_eq!(items[1]["remark"], "16:20");
    }

    #[test]
    fn stream_endpoint_parses_escaped_prop() {
        let html = r#"props="{&quot;apiEndpoint&quot;:[0,&quot;/api/av/708622/stream&quot;],&quot;poster&quot;:[0,&quot;x&quot;]}""#;
        assert_eq!(
            stream_endpoint(html).as_deref(),
            Some("/api/av/708622/stream")
        );
        let html2 = r#"props="{"apiEndpoint":[0,"/api/ai/151552/stream"]}"#;
        assert_eq!(
            stream_endpoint(html2).as_deref(),
            Some("/api/ai/151552/stream")
        );
    }
}
