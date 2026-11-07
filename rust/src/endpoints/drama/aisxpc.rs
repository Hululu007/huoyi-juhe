//! Ai小视频：核心里的影视区站点。
//!
//! 与 ssisJAV 同批验过，MacCMS 站。入口 Aisxpc.cc 本身只是跳转页
//! （根为 FFMpeg WebUI，/ai 经 JS 跳到每日轮换的 *.aicjjc.cc），
//! 但裸域 https://aicjjc.cc 的 /home/ 及全部路径均可直连，故模块
//! 以裸域为基址，不做轮换域名计算。分类 4 项与站导航 1:1；列表
//! 每页 20 条、分页 /aidj/<slug>/page/N/；详情页给海报、简介与
//! “更新至N集”，选集在 /play/<id>-1-1/ 页取；取流链为播放页
//! player_data（url “11602|1”、from huangguo）→
//! /huangguo.php?ac=play&id=&ep= 现取 JSON（code 1 时 url 为
//! /hgmedia.php?e=… 代理地址）→ 代理回 m3u8（AES-128 清单，
//! 密钥与首分片已验 200）。签名带时效，播放须现取现用。取流同时回
//! 一个 User-Agent 头：地址是无后缀的 HLS 代理地址，Dart 侧凭
//! “有头即走本地代理”把它经 /r/ 转接、探到 HLS 后补 .m3u8 后缀，
//! 否则播放器会把它当 Progressive 流、拿 MP4 解析器读 #EXTM3U
//! 而报“视频解析失败”。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://aicjjc.cc";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态回退：与站导航一致，实测于 2026-11-05。
/// id 为 c1-c4，slug 为站内 /aidj/ 路径段。
const CATS: &[(&str, &str, &str)] = &[
    ("c1", "AI成人短剧", "AIchengrenduanju"),
    ("c2", "AI成人漫剧", "AIchengrenmanju"),
    ("c3", "AI换脸", "AIhuanlian"),
    ("c4", "AI魔改", "AImogai"),
];

fn slug_of(category_id: &str) -> Option<&'static str> {
    let t = category_id.trim();
    for (id, _name, slug) in CATS {
        if t == *id || t == *slug {
            return Some(slug);
        }
    }
    None
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("Ai小视频请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn blocked(text: &str) -> bool {
    text.contains("萝莉") || text.contains("幼女") || text.contains("未成年")
}

/// 卡片解析：首页、分类页与搜索页同款 video-card；标题或标签
/// 含禁词的单片跳过（实测 AI魔改页有一条“狗头萝莉”标题，按
/// 规则过滤该片，不动分类）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(r#"(?s)<a[^>]*href="/detail/(\d+)/"[^>]*>(.*?)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let h3_re = Regex::new(r#"<h3[^>]*>([^<]+)</h3>"#).ok();
    let alt_re = Regex::new(r#"alt="([^"]+)""#).ok();
    let title_attr_re = Regex::new(r#"title="([^"]+)""#).ok();
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).ok();
    let badge_re = Regex::new(r#"video-badge">([^<]+)<"#).ok();
    let date_re = Regex::new(r#"(\d{4}-\d{2}-\d{2})"#).ok();
    let mut seen = std::collections::HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let vid = format!("/detail/{}/", &cap[1]);
        if !seen.insert(vid.clone()) {
            continue;
        }
        let body = &cap[2];
        let mut title = String::new();
        if let Some(re) = &h3_re {
            if let Some(m) = re.captures(body) {
                title = m[1].trim().to_string();
            }
        }
        if title.is_empty() {
            if let Some(re) = &alt_re {
                if let Some(m) = re.captures(body) {
                    title = m[1].trim().to_string();
                }
            }
        }
        if title.is_empty() {
            if let Some(re) = &title_attr_re {
                if let Some(m) = re.captures(&cap[0]) {
                    title = m[1].trim().to_string();
                }
            }
        }
        if title.is_empty() || blocked(&title) {
            continue;
        }
        let cover = match &img_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let badge = match &badge_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let date = match &date_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let remark = match (date.is_empty(), badge.is_empty()) {
            (false, false) => format!("{date} · {badge}"),
            (false, true) => date,
            (true, false) => badge,
            (true, true) => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

/// 分类解析：首页 /home/ 的导航栏 /aidj/<slug>/ 链接，按站内
/// 顺序、slug 去重；id 取 c1-c4。
fn parse_categories(html: &str) -> Vec<Value> {
    let re = match Regex::new(r#"<a[^>]*href="/aidj/([^/]+)/"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen = std::collections::HashSet::new();
    let mut categories = Vec::new();
    for cap in re.captures_iter(html) {
        let slug = cap[1].trim().to_string();
        let name = cap[2].trim().to_string();
        if name.is_empty() || !seen.insert(slug.clone()) || blocked(&name) {
            continue;
        }
        let id = CATS
            .iter()
            .find(|(_, _, s)| *s == slug)
            .map(|(id, _, _)| *id)
            .unwrap_or("c1");
        categories.push(category_json(id, &name));
    }
    categories
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name, _)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

/// 分页总数：列表页 /aidj/<slug>/page/N/ 链接的最大 N。
fn page_total(html: &str, slug: &str) -> Option<i64> {
    let pat = format!(r"/aidj/{}/page/(\d+)/", regex::escape(slug));
    let re = Regex::new(&pat).ok()?;
    re.captures_iter(html)
        .filter_map(|cap| cap[1].parse::<i64>().ok())
        .max()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/home/")).await {
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
    let slug = slug_of(category_id).unwrap_or("AIchengrenduanju");
    let page = if page < 1 { 1 } else { page };
    let url = if page <= 1 {
        format!("{BASE}/aidj/{slug}/")
    } else {
        format!("{BASE}/aidj/{slug}/page/{page}/")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    let has_more = if items.is_empty() {
        false
    } else if let Some(total) = page_total(&html, slug) {
        page < total
    } else {
        html.contains(&format!("/aidj/{slug}/page/{}/", page + 1))
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

fn detail_num(series_id: &str) -> String {
    let re = Regex::new(r"(\d+)").unwrap();
    re.captures(series_id)
        .map(|cap| cap[1].to_string())
        .unwrap_or_default()
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 选集解析：播放页 .episode-list 的 /play/<id>-1-<n>/ 链接。
fn parse_episodes(html: &str, series_id: &str) -> Vec<Value> {
    let re = match Regex::new(r#"href="(/play/\d+-1-(\d+)/)"[^>]*>\s*第(\d+)集"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen = std::collections::HashSet::new();
    let mut episodes = Vec::new();
    for cap in re.captures_iter(html) {
        let path = cap[1].to_string();
        if !seen.insert(path.clone()) {
            continue;
        }
        let ep_no = &cap[2];
        episodes.push(episode_json(&path, &format!("第{ep_no}集"), series_id));
    }
    episodes.sort_by_key(|e| {
        text_of(e, &["title"])
            .trim_start_matches('第')
            .trim_end_matches('集')
            .parse::<i64>()
            .unwrap_or(0)
    });
    episodes
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let num = detail_num(series_id);
    if num.is_empty() {
        return Err(ApiError::Internal("Ai小视频详情 id 为空".into()));
    }
    let vid = format!("/detail/{num}/");
    let html = get_text(&format!("{BASE}{vid}")).await?;
    let title_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").ok();
    let mut title = match &title_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        if let Some(re) = &t_re {
            if let Some(m) = re.captures(&html) {
                title = unescape(m[1].trim());
                for suffix in ["在线观看", "剧情介绍"] {
                    if let Some(pos) = title.find(suffix) {
                        title.truncate(pos);
                        break;
                    }
                }
                title = title.trim().to_string();
            }
        }
    }
    let cover_re = Regex::new(r#"<img class="detail-poster"[^>]*src="([^"]+)""#).ok();
    let mut cover = match &cover_re {
        Some(re) => re
            .captures(&html)
            .map(|m| m[1].to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    if cover.is_empty() {
        let og_re = Regex::new(r#"<meta property="og:image"[^>]*content="([^"]+)""#).ok();
        if let Some(re) = &og_re {
            cover = re
                .captures(&html)
                .map(|m| m[1].to_string())
                .unwrap_or_default();
        }
    }
    let desc_re = Regex::new(r#"(?s)<div class="detail-desc">(.*?)</div>"#).ok();
    let synopsis = match &desc_re {
        Some(re) => re
            .captures(&html)
            .map(|m| unescape(m[1].trim()))
            .unwrap_or_default(),
        None => String::new(),
    };
    let meta_re = Regex::new(r#"(?s)<div class="detail-meta">(.*?)</div>"#).ok();
    let remark = match &meta_re {
        Some(re) => re
            .captures(&html)
            .map(|m| {
                let raw = unescape(m[1].trim());
                let text = Regex::new(r"<[^>]+>")
                    .map(|r| r.replace_all(&raw, " "))
                    .unwrap_or_default();
                text.split_whitespace().collect::<Vec<_>>().join(" ")
            })
            .unwrap_or_default(),
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("Ai小视频详情未返回标题".into()));
    }
    let mut episodes = Vec::new();
    if let Ok(play_html) = get_text(&format!("{BASE}/play/{num}-1-1/")).await {
        episodes = parse_episodes(&play_html, &vid);
    }
    if episodes.is_empty() {
        let btn_re = Regex::new(r#"href="(/play/\d+-1-\d+/)"[^>]*>立即播放"#).ok();
        if let Some(re) = &btn_re {
            if let Some(m) = re.captures(&html) {
                episodes.push(episode_json(&m[1], "第1集", &vid));
            }
        }
    }
    if episodes.is_empty() {
        return Err(ApiError::Internal("Ai小视频详情未返回选集".into()));
    }
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"remark": remark},
        "episodes": episodes,
    }))
}

/// 播放页 player_data 的 url 字段（形如 “11602|1”）拆成 id/ep。
fn split_play_url(raw: &str) -> Option<(String, String)> {
    let mut parts = raw.split('|');
    let id = parts.next()?.trim().to_string();
    let ep = parts.next()?.trim().to_string();
    if id.is_empty() || ep.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some((id, ep))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    // 取流回的播放地址是无后缀的 HLS 代理地址（/hgmedia.php?e=…）：
    // 播放器只凭地址后缀认流类型，直链原样给过去会被当成 Progressive
    // 流、拿 MP4 解析器读 #EXTM3U 文本而报“视频解析失败”。随地址回
    // 一个 UA 头，Dart 侧按“有头即走本地代理”把它经 /r/ 转接，代理
    // 层探到 HLS 后给地址补 .m3u8 后缀，播放器才走 HLS。
    let headers = json!({"User-Agent": UA});
    let vid = video_id.trim();
    if vid.starts_with("http") && vid.contains("hgmedia.php") {
        return Ok(json!({"url": vid, "headers": headers}));
    }
    if let Some(rest) = vid.strip_prefix(BASE) {
        if rest.starts_with("/hgmedia.php") {
            return Ok(json!({"url": vid, "headers": headers}));
        }
    }
    if vid.starts_with("/hgmedia.php") {
        return Ok(json!({"url": format!("{BASE}{vid}"), "headers": headers}));
    }
    let play_path = if vid.starts_with("/play/") {
        vid.to_string()
    } else if vid.starts_with("http") {
        match vid.find("/play/") {
            Some(pos) => vid[pos..].to_string(),
            None => {
                return Err(ApiError::Internal("Ai小视频该集没有播放地址".into()));
            }
        }
    } else {
        return Err(ApiError::Internal("Ai小视频该集没有播放地址".into()));
    };
    let html = get_text(&format!("{BASE}{play_path}")).await?;
    let data_re = Regex::new(r"var player_data=(\{.*?\})</script>")
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let data_cap = data_re
        .captures(&html)
        .ok_or_else(|| ApiError::Internal("Ai小视频播放页未返回 player_data".into()))?;
    let data: Value = serde_json::from_str(&data_cap[1])
        .map_err(|e| ApiError::Internal(format!("Ai小视频 player_data 解析失败：{e}")))?;
    let raw = text_of(&data, &["url"]);
    let (id, ep) = split_play_url(&raw)
        .ok_or_else(|| ApiError::Internal("Ai小视频播放参数格式错误".into()))?;
    let api_url = with_query(
        &format!("{BASE}/huangguo.php"),
        &[("ac", "play"), ("id", &id), ("ep", &ep)],
    );
    let api_text = get_text(&api_url).await?;
    let api: Value = serde_json::from_str(&api_text)
        .map_err(|e| ApiError::Internal(format!("Ai小视频取流接口解析失败：{e}")))?;
    let code = get(&api, "code").and_then(|v| v.as_i64()).unwrap_or(0);
    if code != 1 {
        return Err(ApiError::Internal("Ai小视频取流接口未返回播放地址".into()));
    }
    let proxy = text_of(&api, &["url"]);
    if proxy.is_empty() || !proxy.starts_with("/hgmedia.php?e=") {
        return Err(ApiError::Internal("Ai小视频代理播放地址格式错误".into()));
    }
    Ok(json!({"url": format!("{BASE}{proxy}"), "headers": headers}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search/-------------/"), &[("wd", query)]);
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_play_url_cases() {
        assert_eq!(
            split_play_url("11602|1"),
            Some(("11602".to_string(), "1".to_string()))
        );
        assert_eq!(split_play_url("11602"), None);
        assert_eq!(split_play_url("abc|1"), None);
        assert_eq!(split_play_url(""), None);
    }

    #[test]
    fn parse_cards_filters_loli_title() {
        let html = r#"<a href="/detail/3396/" title="AI魔改 狗头萝莉 骚浪网红"><div class="video-thumbnail"><img class="video-img" src="https://media.hgpicimg.cc//upload/huangguo/1.jpg" alt="AI魔改 狗头萝莉 骚浪网红"><span class="video-badge">更新至2集</span></div><div class="video-info"><h3 class="video-title">AI魔改 狗头萝莉 骚浪网红</h3><div class="video-meta"><span>2026-11-05</span><span>播放 100</span></div></div></a><a href="/detail/3352/" title="驯养篮球犬"><div class="video-thumbnail"><img class="video-img" src="https://media.hgpicimg.cc//upload/huangguo/11602.jpg" alt="驯养篮球犬"><span class="video-badge">更新至2集</span></div><div class="video-info"><h3 class="video-title">驯养篮球犬</h3><div class="video-meta"><span>2026-11-05</span><span>播放 39221</span></div></div></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/detail/3352/");
        assert_eq!(items[0]["title"], "驯养篮球犬");
        assert_eq!(items[0]["remark"], "2026-11-05 · 更新至2集");
    }

    #[test]
    fn parse_categories_dedup() {
        let html = r#"<nav class="main-nav"><a href="/aidj/AIchengrenduanju/">AI成人短剧</a><a href="/aidj/AIhuanlian/">AI换脸</a></nav><div class="hg-menu-panel"><a href="/aidj/AIchengrenduanju/">AI成人短剧</a><a href="/aidj/AImogai/">AI魔改</a></div>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "c1");
        assert_eq!(list[1]["name"], "AI换脸");
        assert_eq!(list[2]["id"], "c4");
    }

    #[test]
    fn fallback_has_4_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 4);
        assert_eq!(list[0]["id"], "c1");
        assert_eq!(list[3]["name"], "AI魔改");
    }

    #[test]
    fn page_total_reads_last_page() {
        let html = r#"<div class="paging"><a href="/aidj/AIchengrenduanju/page/2/">2</a><a href="/aidj/AIchengrenduanju/page/77/">77</a></div>"#;
        assert_eq!(page_total(html, "AIchengrenduanju"), Some(77));
        assert_eq!(page_total("<div>no pager</div>", "AIchengrenduanju"), None);
    }

    #[test]
    fn parse_episodes_sorted() {
        let html = r#"<div class="episode-list"><a class="episode" href="/play/3352-1-2/">第2集</a><a class="episode active" href="/play/3352-1-1/">第1集</a></div>"#;
        let eps = parse_episodes(html, "/detail/3352/");
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0]["video_id"], "/play/3352-1-1/");
        assert_eq!(eps[1]["title"], "第2集");
    }

    #[test]
    fn detail_num_forms() {
        assert_eq!(detail_num("/detail/3352/"), "3352");
        assert_eq!(detail_num("3352"), "3352");
    }
}
