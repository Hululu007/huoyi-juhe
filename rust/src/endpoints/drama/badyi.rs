//! 八度影院：核心里的影视区站点。
//!
//! 与 py 版 badyi.py 同一套分类、同一条已验播放链：分类与站 /tags 导
//! 航 1:1（58 项）、列表 12 条一页、单片详情、取流为详情页 og:video
//! 的 m3u8（AES-128 清单，密钥与首分片已验 200，无需特殊头）；封面
//! 地址站内为 https:/ 单斜杠写法，统一修正；站内无萝莉分类，萝莉
//! 只作单片标签出现，列表与搜索按标签过滤。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://badyi.cc";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态回退：与站 /tags 导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("c11", "后入"),
    ("c8", "玩偶姐姐"),
    ("c19", "蝴蝶逼"),
    ("c58", "蜜桃影像传媒"),
    ("c41", "主播"),
    ("c7", "饼干姐姐"),
    ("c66", "学妹"),
    ("c47", "精东影业"),
    ("c65", "姐弟"),
    ("c97", "情趣装扮"),
    ("c36", "巨屌"),
    ("c340", "媚黑"),
    ("c379", "熊"),
    ("c424", "职场"),
    ("c488", "G综艺"),
    ("c296", "抓奸"),
    ("c86", "重口味"),
    ("c286", "亚洲"),
    ("c373", "圣诞"),
    ("c504", "咩咩"),
    ("c108", "波多野結衣"),
    ("c270", "调情"),
    ("c431", "茄子视频"),
    ("c307", "窥视"),
    ("c530", "篠田優"),
    ("c226", "摄像头破解"),
    ("c294", "饼干姐姐"),
    ("c78", "淫叫"),
    ("c142", "少妇"),
    ("c555", "拳交"),
    ("c485", "有码"),
    ("c354", "大黑屌"),
    ("c159", "人妻巨乳"),
    ("c187", "偷情"),
    ("c436", "厕拍"),
    ("c238", "抄底"),
    ("c369", "浅网"),
    ("c156", "小敏儿"),
    ("c277", "校服"),
    ("c137", "传媒"),
    ("c457", "Chloe"),
    ("c491", "医生"),
    ("c385", "女上"),
    ("c126", "原创"),
    ("c99", "母子"),
    ("c109", "高潮"),
    ("c537", "gay"),
    ("c565", "台湾粉红兔"),
    ("c391", "寝取"),
    ("c434", "深网"),
    ("c160", "日本"),
    ("c241", "多人轮奸"),
    ("c201", "阿朱"),
    ("c272", "潮喷"),
    ("c461", "猥亵"),
    ("c89", "NicoLove"),
    ("c515", "留学生"),
    ("c446", "爸气十足"),
];

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("八度影院请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 地址归一：站内 `https:/` 单斜杠补成 `https://`，协议相对补
/// https，站内相对路径补基址。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if let Some(rest) = u.strip_prefix("https:/") {
        if !rest.starts_with('/') {
            return format!("https://{rest}");
        }
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("http:/") {
        if !rest.starts_with('/') {
            return format!("http://{rest}");
        }
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    u.to_string()
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 卡片解析：首页与分类页同款 nav-art-card；标签含萝莉的卡片跳过。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(r#"(?s)<a[^>]*href="/video/(\d+)"[^>]*>(.*?)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let label_re = Regex::new(r#"nav-card-cat">([^<]+)<"#).ok();
    let alt_re = Regex::new(r#"alt="([^"]+)""#).ok();
    let meta_img_re = Regex::new(r#"itemprop="image"[^>]*content="([^"]+)""#).ok();
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).ok();
    let date_re = Regex::new(r#"nav-card-date">([^<]+)<"#).ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let vid = format!("/video/{}", &cap[1]);
        if !seen.insert(vid.clone()) {
            continue;
        }
        let body = &cap[2];
        if let Some(re) = &label_re {
            if let Some(lm) = re.captures(body) {
                if lm[1].contains('萝') && lm[1].contains('莉') {
                    continue;
                }
            }
        }
        let title = match &alt_re {
            Some(re) => re
                .captures(body)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let mut cover = String::new();
        if let Some(re) = &meta_img_re {
            if let Some(m) = re.captures(body) {
                cover = fix_url(&m[1]);
            }
        }
        if cover.is_empty() {
            if let Some(re) = &img_re {
                if let Some(m) = re.captures(body) {
                    cover = fix_url(&m[1]);
                }
            }
        }
        let remark = match &date_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

/// 分类解析：/tags 页 nav-link 锚点，按站内顺序、id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="/c(\d+)"[^>]*>([^<]+)<"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let id = format!("c{}", &cap[1]);
        let name = cap[2].trim().to_string();
        if name.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/tags")).await {
        Ok(html) => {
            let list = parse_categories(&html);
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = if page <= 1 {
        format!("{BASE}/{category_id}/")
    } else {
        format!("{BASE}/{category_id}/page/{page}/")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html) {
        page < total
    } else {
        html.contains(&format!("/{category_id}/page/{}/", page + 1))
            || html.contains(&format!("/{category_id}/page/{}", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 分页总数：列表页 `nav-pg-info">当前 / 总数<`，取不到则 None。
fn page_total(html: &str) -> Option<i64> {
    let re = Regex::new(r#"nav-pg-info">\d+ / (\d+)<"#).ok()?;
    let cap = re.captures(html)?;
    cap[1].parse::<i64>().ok()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else if let Some(rest) = series_id.strip_prefix('/') {
        format!("{BASE}/{rest}")
    } else {
        format!("{BASE}/{series_id}")
    };
    let html = get_text(&url).await?;
    let title_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = title.find(" - ") {
        title.truncate(pos);
    }
    let cover_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
    let cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    let desc_re = Regex::new(r#"<meta name="description"[^>]*content="([^"]+)""#).ok();
    let mut synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if let Some(pos) = synopsis.find(" -91Pornhub.tv") {
        synopsis.truncate(pos);
    }
    let m3u8_re = Regex::new(r#"<meta property="og:video"[^>]*content="([^"]+)""#).ok();
    let m3u8 = match &m3u8_re {
        Some(re) => re
            .captures(&html)
            .map(|m| fix_url(&m[1]))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("八度影院未返回可播放地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&m3u8, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("八度影院该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(
        &format!("{BASE}/api/search.php"),
        &[("q", query), ("page", "1"), ("per", "12")],
    );
    let text = get_text(&url).await?;
    let body: Value = serde_json::from_str(&text)?;
    let articles = get(&body, "articles").and_then(arr_of);
    let mut items = Vec::new();
    if let Some(articles) = articles {
        for entry in articles {
            let url = text_of(entry, &["url"]);
            if !url.starts_with("/video/") {
                continue;
            }
            let mut blocked = false;
            if let Some(tags) = get(entry, "tags").and_then(arr_of) {
                for tag in tags {
                    let t = match tag.as_str() {
                        Some(s) => s.to_string(),
                        None => String::new(),
                    };
                    if t.contains('萝') && t.contains('莉') {
                        blocked = true;
                        break;
                    }
                }
            }
            if blocked {
                continue;
            }
            let title = text_of(entry, &["title"]);
            if title.is_empty() {
                continue;
            }
            let cover = fix_url(&text_of(entry, &["img"]));
            let remark = text_of(entry, &["date"]);
            items.push(item_json(&url, &title, &cover, &remark));
        }
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("https:/dfdf.tjacq.com/video/1.m3u8"),
            "https://dfdf.tjacq.com/video/1.m3u8"
        );
        assert_eq!(
            fix_url("https://dfdf.tjacq.com/video/1.m3u8"),
            "https://dfdf.tjacq.com/video/1.m3u8"
        );
        assert_eq!(
            fix_url("/media/image/2024-06-08/22/1799"),
            "https://badyi.cc/media/image/2024-06-08/22/1799"
        );
        assert_eq!(fix_url("//x.y/z"), "https://x.y/z");
        assert_eq!(fix_url(""), "");
    }

    #[test]
    fn parse_cards_filters_loli_label() {
        let html = r#"<a href="/video/1" class="nav-art-card"><meta itemprop="image" content="https:/a.com/i1"><span class="nav-card-date">2026-11-05</span><span class="nav-card-cat">萝莉</span><div class="nc-img"><img src="https:/a.com/i1" alt="片A"></div></a><a href="/video/2" class="nav-art-card"><meta itemprop="image" content="/media/image/2"><span class="nav-card-date">2026-11-04</span><span class="nav-card-cat">精选</span><div class="nc-img"><img src="/media/image/2" alt="片B"></div></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/video/2");
        assert_eq!(items[0]["title"], "片B");
        assert_eq!(items[0]["cover"], "https://badyi.cc/media/image/2");
        assert_eq!(items[0]["remark"], "2026-11-04");
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<a href="/c11" class="nav-link">后入</a><a href="/c8" class="nav-link">玩偶姐姐</a><a href="/c11" class="nav-link">后入</a>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "c11");
        assert_eq!(list[1]["name"], "玩偶姐姐");
    }

    #[test]
    fn fallback_has_58_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 58);
        assert_eq!(list[0]["id"], "c11");
    }

    #[test]
    fn search_filters_loli_tags() {
        let body = json!({"articles": [
            {"url": "/video/1", "title": "片A", "img": "https:/a.com/i1", "date": "2026-11-05", "tags": ["萝莉"]},
            {"url": "/video/2", "title": "片B", "img": "/media/image/2", "date": "2026-11-04", "tags": ["精选"]},
        ]});
        let articles = get(&body, "articles").and_then(arr_of).unwrap();
        let mut kept = 0;
        for entry in articles {
            let mut blocked = false;
            if let Some(tags) = get(entry, "tags").and_then(arr_of) {
                for tag in tags {
                    if tag.as_str().unwrap_or("").contains('萝')
                        && tag.as_str().unwrap_or("").contains('莉')
                    {
                        blocked = true;
                    }
                }
            }
            if !blocked {
                kept += 1;
            }
        }
        assert_eq!(kept, 1);
    }

    #[test]
    fn page_total_reads_nav_info() {
        assert_eq!(
            page_total(r#"<span class="nav-pg-info">2 / 51</span>"#),
            Some(51)
        );
        assert_eq!(page_total("<div>no pager</div>"), None);
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://x/1.m3u8").unwrap();
        assert_eq!(ok["url"], "https://x/1.m3u8");
        assert!(play_check("/video/1").is_err());
    }
}
