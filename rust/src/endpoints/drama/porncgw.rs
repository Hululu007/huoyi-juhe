//! Porn吃瓜网：核心里的影视区站点。
//!
//! 与 py 版 porncgw.py 同一套分类、同一条已验播放链：分类与站首页
//! 导航 1:1（25 项，均为视频分区；吃瓜社区 /archives/* 是纯帖子，
//! 不进分类；标签页是指引页，不进分类）、列表每页 20 条、单视频
//! 与多集短剧两种详情、取流为详情页或单集页 JSON 数据里的 videoSrc
//! 直链 m3u8（AES-128 清单，密钥与首分片已验 200，无需特殊头）；
//! 标题不删（用户 22:39 铁律：标题是站长为推流故意写的，用户已亲自验
//! 过站内内容）。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE: &str = "https://porncgw.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 分类静态表：与站导航一致，实测于 2026-11-05；每项为
/// (分类 id，显示名，列表路径)。括号内为首页条数。
const CATS: &[(&str, &str, &str)] = &[
    ("recommend", "推荐吃瓜", "/recommend/"),
    ("today", "今日吃瓜", "/today/"),
    ("hot", "热门爆料", "/hot/"),
    ("hot-xsxy", "学生校园", "/hot/xsxy/"),
    ("hot-whhl", "网红黑料", "/hot/whhl/"),
    ("hot-snsf", "熟女少妇", "/hot/snsf/"),
    ("hot-cgbd", "吃瓜榜单", "/hot/cgbd/"),
    ("shrd", "社会热点", "/shrd/"),
    ("shrd-ylbg", "娱乐八卦", "/shrd/ylbg/"),
    ("shrd-wybl", "网友爆料", "/shrd/wybl/"),
    ("ent", "热门短片", "/entertainment/"),
    ("ent-cgtq", "出轨偷情", "/entertainment/cgtq/"),
    ("ent-zplc", "自拍流出", "/entertainment/zplc/"),
    ("door", "门事件", "/door/"),
    ("door-jiudian", "酒店", "/door/jiudian/"),
    ("door-chezhen", "车震", "/door/chezhen/"),
    ("ai", "AI成人", "/ai/"),
    ("ai-aidj", "AI短剧", "/ai/aidj/"),
    ("ai-AImj", "AI漫剧", "/ai/AImj/"),
    ("long-video", "长视频", "/long-video/"),
    ("ntxl", "女同系列", "/ntxl/"),
    ("omxl", "欧美系列", "/omxl/"),
    ("jqyy", "剧情演绎", "/jqyy/"),
    ("yzcm", "亚洲传媒", "/yzcm/"),
    ("list", "短视频", "/list"),
];

fn cat_path(category_id: &str) -> Option<&'static str> {
    CATS.iter()
        .find(|(id, _, _)| *id == category_id)
        .map(|(_, _, path)| *path)
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
        return Err(ApiError::Internal(format!("吃瓜网请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn unescape(s: &str) -> String {
    s.replace("\\u0026", "&")
        .replace("\\/", "/")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 卡片解析：article 卡片，标题取 data-title，封面取
/// video-thumb-img 的 data-src，时长取 data-time，短剧另取
/// “更新至 N 集”作备注。
fn parse_cards(html: &str) -> Vec<Value> {
    let article_re = match Regex::new(
        r#"(?s)<article[^>]*?data-title="([^"]*)"[^>]*?data-time="([^"]*)"[^>]*?>(.*?)</article>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let href_re = Regex::new(r#"href="/(video|drama)/(\d+)/""#).ok();
    let img_re = Regex::new(r#"data-src="(https://[^"]+)""#).ok();
    let upd_re = Regex::new(r"更新至(\d+)集").ok();
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for cap in article_re.captures_iter(html) {
        let title = unescape(cap[1].trim());
        if title.is_empty() {
            continue;
        }
        let body = &cap[3];
        let (kind, num) = match &href_re {
            Some(re) => match re.captures(body) {
                Some(m) => (m[1].to_string(), m[2].to_string()),
                None => continue,
            },
            None => continue,
        };
        let vid = format!("{kind}/{num}");
        if !seen.insert(vid.clone()) {
            continue;
        }
        let cover = match &img_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        let mut remark = cap[2].trim().to_string();
        if kind == "drama" {
            if let Some(re) = &upd_re {
                if let Some(m) = re.captures(body) {
                    remark = format!("更新至{}集", &m[1]);
                }
            }
        }
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

fn has_next(html: &str) -> bool {
    html.contains("aria-label=\"下一页\"")
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
    let path = match cat_path(category_id) {
        Some(p) => p,
        None => return Err(ApiError::Internal("吃瓜网未知分类".into())),
    };
    let page = page.max(1);
    let url = if page <= 1 {
        format!("{BASE}{path}")
    } else if path.ends_with('/') {
        format!("{BASE}{path}{page}/")
    } else {
        format!("{BASE}{path}/{page}/")
    };
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": has_next(&html)}))
}

fn strip_site_suffix(title: &str) -> String {
    match title.strip_suffix(" - porn吃瓜网") {
        Some(t) => t.trim().to_string(),
        None => title.trim().to_string(),
    }
}

fn meta_content(html: &str, prop: &str) -> String {
    let pat = format!(r#"<meta property="{prop}"[^>]*content="([^"]+)""#);
    let re = match Regex::new(&pat) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|m| unescape(m[1].trim()))
        .unwrap_or_default()
}

fn meta_name(html: &str, name: &str) -> String {
    let pat = format!(r#"<meta name="{name}"[^>]*content="([^"]+)""#);
    let re = match Regex::new(&pat) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|m| unescape(m[1].trim()))
        .unwrap_or_default()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{BASE}/{series_id}")
    };
    let html = get_text(&url).await?;
    let mut title = meta_content(&html, "og:title");
    if title.is_empty() {
        let title_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").ok();
        title = match &title_re {
            Some(re) => re
                .captures(&html)
                .map(|m| unescape(m[1].trim()))
                .unwrap_or_default(),
            None => String::new(),
        };
    }
    let title = strip_site_suffix(&title);
    let cover = meta_content(&html, "og:image");
    let synopsis = meta_name(&html, "description");
    if title.is_empty() {
        return Err(ApiError::Internal("吃瓜网详情无标题".into()));
    }
    let episodes = if series_id.starts_with("drama/") {
        let id_part = series_id.trim_start_matches("drama/").trim_end_matches('/');
        let ep_re = match Regex::new(&format!(
            r#"href="/drama/{}/(\d+)/""#,
            regex::escape(id_part)
        )) {
            Ok(re) => re,
            Err(_) => return Err(ApiError::Internal("吃瓜网选集解析失败".into())),
        };
        let mut nums: Vec<i64> = Vec::new();
        for cap in ep_re.captures_iter(&html) {
            if let Ok(n) = cap[1].parse::<i64>() {
                if !nums.contains(&n) {
                    nums.push(n);
                }
            }
        }
        nums.sort_unstable();
        if nums.is_empty() {
            return Err(ApiError::Internal("吃瓜网短剧无选集".into()));
        }
        nums.iter()
            .map(|n| {
                let vid = format!("drama/{id_part}/{n}");
                episode_json(&vid, &format!("第{n}集"), &vid)
            })
            .collect::<Vec<Value>>()
    } else {
        vec![episode_json(series_id, "播放", series_id)]
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": episodes,
    }))
}

/// 详情页或单集页 JSON 数据里的 videoSrc 直链 m3u8。
fn extract_video_src(html: &str) -> String {
    let re = match Regex::new(r#""videoSrc":"([^"]+)""#) {
        Ok(re) => re,
        Err(_) => return String::new(),
    };
    re.captures(html)
        .map(|m| unescape(&m[1]))
        .unwrap_or_default()
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    let url = format!("{BASE}/{video_id}");
    let html = get_text(&url).await?;
    let m3u8 = extract_video_src(&html);
    if m3u8.is_empty() {
        return Err(ApiError::Internal("吃瓜网该集没有播放地址".into()));
    }
    Ok(json!({"url": m3u8}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded =
        percent_encoding::utf8_percent_encode(query.trim(), percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let url = format!("{BASE}/search/{encoded}/");
    let html = get_text(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_has_25_no_archives() {
        assert_eq!(CATS.len(), 25);
        for (id, _, path) in CATS {
            assert!(!path.starts_with("/archives/"), "{id} 不应是帖子分区");
            assert!(!path.contains("/tags/"), "{id} 不应是标签页");
        }
        assert_eq!(CATS[0].0, "recommend");
        assert_eq!(CATS[24].0, "list");
    }

    #[test]
    fn parse_cards_real_markup() {
        let html = r#"<article class="card video-card" data-id="58062" data-title="末世男女比例失衡" data-author="茎侯佳阴" data-preview-src="https://x/1.m3u8" data-likes="2.4w" data-views="2万" data-time=""><a class="card-link" href="/drama/58062/" aria-label="末世男女比例失衡，2.4w播放"><div class="video-thumb card-cover"><img class="video-thumb-img" src="/static/web/images/cover-placeholder-logo.png" data-src="https://pic.drleao.cn/a.jpeg?auth_key=1" alt="末世男女比例失衡视频封面"></div><span>更新至10集</span></a></article><article class="card video-card" data-id="58032" data-title="粉红小萝莉" data-views="1万" data-time="0:52"><a class="card-link" href="/video/58032/" aria-label="粉红小萝莉，1万播放"><img class="video-thumb-img" data-src="https://pic.drleao.cn/b.jpeg"></a></article><article class="card video-card" data-id="58033" data-title="少妇系列" data-views="3万" data-time="7:43"><a class="card-link" href="/video/58033/" aria-label="少妇系列，3万播放"><img class="video-thumb-img" data-src="https://pic.drleao.cn/c.jpeg"></a></article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0]["id"], "drama/58062");
        assert_eq!(items[0]["title"], "末世男女比例失衡");
        assert_eq!(items[0]["cover"], "https://pic.drleao.cn/a.jpeg?auth_key=1");
        assert_eq!(items[0]["remark"], "更新至10集");
        assert_eq!(items[1]["id"], "video/58032");
        assert_eq!(items[1]["title"], "粉红小萝莉");
        assert_eq!(items[1]["remark"], "0:52");
        assert_eq!(items[2]["id"], "video/58033");
        assert_eq!(items[2]["remark"], "7:43");
    }

    #[test]
    fn extract_video_src_unescapes() {
        let html = r#"{"videoSrc":"https://yd-pwem-hls.hzjvlo.cn/videos5/aa/bb.m3u8?auth_key=1\u0026v=3\u0026time=0\u0026via=91porn","videoSrcHevc":""}"#;
        assert_eq!(
            extract_video_src(html),
            "https://yd-pwem-hls.hzjvlo.cn/videos5/aa/bb.m3u8?auth_key=1&v=3&time=0&via=91porn"
        );
        assert_eq!(extract_video_src("<html>no src</html>"), "");
    }

    #[test]
    fn strip_site_suffix_cases() {
        assert_eq!(
            strip_site_suffix("末世男女比例失衡 - porn吃瓜网"),
            "末世男女比例失衡"
        );
        assert_eq!(strip_site_suffix("无后缀标题"), "无后缀标题");
    }

    #[test]
    fn has_next_cases() {
        assert!(has_next(r#"<a href="/today/2/" aria-label="下一页">"#));
        assert!(!has_next("<div>末页</div>"));
    }

    #[test]
    fn cat_path_lookup() {
        assert_eq!(cat_path("ai-AImj"), Some("/ai/AImj/"));
        assert_eq!(cat_path("list"), Some("/list"));
        assert_eq!(cat_path("archives"), None);
    }
}
