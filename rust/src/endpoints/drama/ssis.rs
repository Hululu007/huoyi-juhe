//! ssisJAV：核心里的影视区站点。
//!
//! 与 py 版 ssis.py 同一套分类、同一条已验播放链：站为 XOR 加密
//! 单页壳（外层 HTML 只有 CRYPT_KEY 与 base64 载荷，解密后才是真
//! 页），分类取 /genres 导航（36 项，含导航 8 项与网格 28 项；
//! 页上“共 42 个分类”含 6 个未列入导航的隐藏 topic，其中 id=39
//! 萝莉少女按规则不注册，其余 5 个亦不在导航内故不进）；列表每页
//! 24 条、分页 /topic?id=N&page=P；详情页 window.__INITIAL_DATA__
//! 的 video 对象给出 videoUrl（myavimg.top 的 m3u8，明文清单，
//! 首分片已验 200，无需特殊头）；搜索走 /search?q=&page=。

use base64::Engine as _;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of, with_query};

const BASE: &str = "https://ssis1.cc";
const UA: &str = "Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const PAGE_SIZE: i64 = 24;

/// 分类静态回退：与站 /genres 导航一致，实测于 2026-11-05。
const CATS: &[(&str, &str)] = &[
    ("t14", "中文字幕"),
    ("t11", "亚洲有码"),
    ("t40", "制服丝袜"),
    ("t18", "亚洲无码"),
    ("t6", "日本精品"),
    ("t5", "女优系列"),
    ("t7", "巨乳美乳"),
    ("t15", "欧美精品"),
    ("t47", "过膝袜"),
    ("t17", "男同性恋"),
    ("t19", "传媒出品"),
    ("t33", "兽耳系列"),
    ("t27", "古装扮演"),
    ("t32", "瑜伽裤"),
    ("t28", "野外露出"),
    ("t34", "女同性恋"),
    ("t13", "韩国御姐"),
    ("t31", "可爱学生"),
    ("t21", "台湾辣妹"),
    ("t26", "唯美港姐"),
    ("t41", "闷骚护士"),
    ("t29", "多人多P"),
    ("t20", "伦理三级"),
    ("t3", "东南亚AV"),
    ("t25", "剧情介绍"),
    ("t12", "风情旗袍"),
    ("t10", "欺辱凌辱"),
    ("t8", "恋腿狂魔"),
    ("t36", "素人自拍"),
    ("t37", "网红流出"),
    ("t38", "自拍偷拍"),
    ("t30", "Cosplay"),
    ("t9", "口交颜射"),
    ("t24", "主播直播"),
    ("t43", "精品推荐"),
    ("t22", "网曝门"),
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
        return Err(ApiError::Internal(format!("ssisJAV 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 解密外层壳：取 CRYPT_KEY 与 h=decrypt('...') 载荷，base64 解码
/// 后按 key 循环异或，得到内层真页。
fn decrypt_page(html: &str) -> ApiResult<String> {
    let key_re =
        Regex::new(r#"CRYPT_KEY="([^"]+)""#).map_err(|e| ApiError::Internal(e.to_string()))?;
    let key = match key_re.captures(html) {
        Some(cap) => cap[1].to_string(),
        None => return Ok(html.to_string()),
    };
    let pay_re =
        Regex::new(r"h=decrypt\('([^']+)'\)").map_err(|e| ApiError::Internal(e.to_string()))?;
    let payload = match pay_re.captures(html) {
        Some(cap) => cap[1].to_string(),
        None => return Ok(html.to_string()),
    };
    let raw = base64::engine::general_purpose::STANDARD
        .decode(payload.as_bytes())
        .map_err(|e| ApiError::Internal(format!("ssisJAV 载荷解码失败：{e}")))?;
    let kb = key.as_bytes();
    if kb.is_empty() {
        return Err(ApiError::Internal("ssisJAV 解密密钥为空".into()));
    }
    let plain: Vec<u8> = raw
        .iter()
        .enumerate()
        .map(|(i, &b)| b ^ kb[i % kb.len()])
        .collect();
    Ok(String::from_utf8_lossy(&plain).into_owned())
}

/// 取 window.__INITIAL_DATA__ 的 JSON 对象（花括号配对扫描）。
fn initial_data(html: &str) -> Option<Value> {
    let marker = "window.__INITIAL_DATA__ = ";
    let start = html.find(marker)? + marker.len();
    let bytes = html.as_bytes();
    let mut depth: i32 = 0;
    let mut in_str = false;
    let mut esc = false;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else if b == b'"' {
            in_str = true;
        } else if b == b'{' {
            depth += 1;
        } else if b == b'}' {
            depth -= 1;
            if depth == 0 {
                let slice = &html[start..=i];
                return serde_json::from_str(slice).ok();
            }
        }
        i += 1;
    }
    None
}

fn blocked(text: &str) -> bool {
    text.contains("萝莉") || text.contains("幼女") || text.contains("未成年")
}

/// 列表 JSON 的 videos 数组转卡片；标题或标签含禁词的单片跳过。
fn videos_to_items(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    if let Some(videos) = get(data, "videos").and_then(arr_of) {
        for v in videos {
            let title = text_of(v, &["title"]);
            let tag = text_of(v, &["tag", "code", "category"]);
            if title.is_empty() || blocked(&title) || blocked(&tag) {
                continue;
            }
            let id = text_of(v, &["id"]);
            if id.is_empty() {
                continue;
            }
            let vid = format!("/watch?id={id}");
            let cover = text_of(v, &["thumb"]);
            let date = text_of(v, &["date"]);
            let remark = if date.is_empty() {
                tag
            } else if tag.is_empty() {
                date
            } else {
                format!("{date} · {tag}")
            };
            items.push(item_json(&vid, &title, &cover, &remark));
        }
    }
    items
}

/// 卡片 HTML 回退解析（内层页无 videos JSON 时用）。
fn parse_cards(html: &str) -> Vec<Value> {
    let card_re = match Regex::new(r#"(?s)<a[^>]*href="/watch\?id=(\d+)"[^>]*>(.*?)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let alt_re = Regex::new(r#"alt="([^"]+)""#).ok();
    let img_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).ok();
    let date_re = Regex::new(r#"(\d{4}-\d{2}-\d{2})"#).ok();
    let mut seen = std::collections::HashSet::new();
    let mut items = Vec::new();
    for cap in card_re.captures_iter(html) {
        let vid = format!("/watch?id={}", &cap[1]);
        if !seen.insert(vid.clone()) {
            continue;
        }
        let body = &cap[2];
        let title = match &alt_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].trim().to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
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
        let remark = match &date_re {
            Some(re) => re
                .captures(body)
                .map(|m| m[1].to_string())
                .unwrap_or_default(),
            None => String::new(),
        };
        items.push(item_json(&vid, &title, &cover, &remark));
    }
    items
}

fn total_of(data: &Value) -> i64 {
    let total = get(data, "total").and_then(|v| v.as_i64()).unwrap_or(0);
    if total > 0 {
        return total;
    }
    0
}

/// 分类解析：导航栏 topic 链接在前，网格卡片在后，按 id 去重。
fn parse_categories(html: &str) -> Vec<Value> {
    let nav_re = match Regex::new(r#"<a href="/topic\?id=(\d+)"[^>]*>([^<]+)</a>"#) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let grid_re = match Regex::new(
        r#"(?s)<a class="iw-cat-card" href="/topic\?id=(\d+)".*?<span class="iw-cat-name">([^<]+)</span>"#,
    ) {
        Ok(re) => re,
        Err(_) => return Vec::new(),
    };
    let mut seen = std::collections::HashSet::new();
    let mut categories = Vec::new();
    for cap in nav_re.captures_iter(html) {
        let name = cap[2].trim().to_string();
        if name.is_empty() || name == "首页" || name == "分类" || name == "公告" || name == "搜索"
        {
            continue;
        }
        let id = format!("t{}", &cap[1]);
        if !seen.insert(id.clone()) || blocked(&name) {
            continue;
        }
        categories.push(category_json(&id, &name));
    }
    for cap in grid_re.captures_iter(html) {
        let name = cap[2].trim().to_string();
        if name.is_empty() {
            continue;
        }
        let id = format!("t{}", &cap[1]);
        if !seen.insert(id.clone()) || blocked(&name) {
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

fn topic_num(category_id: &str) -> String {
    let t = category_id.trim();
    let t = t.strip_prefix('t').unwrap_or(t);
    t.to_string()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match get_text(&format!("{BASE}/genres")).await {
        Ok(html) => match decrypt_page(&html) {
            Ok(inner) => {
                let list = parse_categories(&inner);
                if list.is_empty() {
                    Ok(fallback_categories())
                } else {
                    Ok(json!({"categories": list}))
                }
            }
            Err(_) => Ok(fallback_categories()),
        },
        Err(_) => Ok(fallback_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let num = topic_num(category_id);
    let page = if page < 1 { 1 } else { page };
    let page_s = page.to_string();
    let url = with_query(
        &format!("{BASE}/topic"),
        &[("id", num.as_str()), ("page", page_s.as_str())],
    );
    let html = get_text(&url).await?;
    let inner = decrypt_page(&html)?;
    let (items, has_more) = match initial_data(&inner) {
        Some(data) => {
            let items = videos_to_items(&data);
            let total = total_of(&data);
            let more = if total > 0 {
                page * PAGE_SIZE < total
            } else {
                !items.is_empty() && inner.contains(&format!("page={}", page + 1))
            };
            (items, more)
        }
        None => {
            let items = parse_cards(&inner);
            let more = !items.is_empty() && inner.contains(&format!("page={}", page + 1));
            (items, more)
        }
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

fn watch_id(series_id: &str) -> String {
    let s = series_id.trim();
    if let Some(cap) = Regex::new(r"id=(\d+)").ok().and_then(|re| re.captures(s)) {
        return cap[1].to_string();
    }
    s.trim_start_matches('/')
        .trim_start_matches("watch")
        .trim_start_matches('?')
        .to_string()
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = watch_id(series_id);
    let url = with_query(&format!("{BASE}/watch"), &[("id", id.as_str())]);
    let html = get_text(&url).await?;
    let inner = decrypt_page(&html)?;
    let data =
        initial_data(&inner).ok_or_else(|| ApiError::Internal("ssisJAV 详情未返回数据".into()))?;
    let video =
        get(&data, "video").ok_or_else(|| ApiError::Internal("ssisJAV 详情未返回视频".into()))?;
    let title = text_of(video, &["title"]);
    let mut m3u8 = text_of(video, &["videoUrl"]);
    if m3u8.is_empty() {
        m3u8 = text_of(video, &["magnet"]);
    }
    if m3u8.is_empty() {
        let re = Regex::new(r#"data-video-url="([^"]+\.m3u8[^"]*)""#)
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        if let Some(cap) = re.captures(&inner) {
            m3u8 = cap[1].to_string();
        }
    }
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("ssisJAV 详情未返回可播放地址".into()));
    }
    let cover = text_of(video, &["thumb"]);
    let synopsis = text_of(video, &["desc"]);
    let vid = format!("/watch?id={id}");
    Ok(json!({
        "id": vid,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&m3u8, "播放", &vid)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("ssisJAV 该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = with_query(&format!("{BASE}/search"), &[("q", query), ("page", "1")]);
    let html = get_text(&url).await?;
    let inner = decrypt_page(&html)?;
    let items = match initial_data(&inner) {
        Some(data) => videos_to_items(&data),
        None => parse_cards(&inner),
    };
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn xor_encrypt(plain: &str, key: &str) -> String {
        let kb = key.as_bytes();
        let enc: Vec<u8> = plain
            .as_bytes()
            .iter()
            .enumerate()
            .map(|(i, &b)| b ^ kb[i % kb.len()])
            .collect();
        base64::engine::general_purpose::STANDARD.encode(enc)
    }

    #[test]
    fn decrypt_page_roundtrip() {
        let key = "InkWave@2026#!";
        let inner = "<html><body>hello ssis</body></html>";
        let payload = xor_encrypt(inner, key);
        let outer = format!(
            "<script>const CRYPT_KEY=\"{key}\";</script><script>h=decrypt('{payload}');</script>"
        );
        assert_eq!(decrypt_page(&outer).unwrap(), inner);
    }

    #[test]
    fn decrypt_page_passthrough_without_shell() {
        let plain = "<html>no shell</html>";
        assert_eq!(decrypt_page(plain).unwrap(), plain);
    }

    #[test]
    fn initial_data_brace_match() {
        let html = r#"window.__INITIAL_DATA__ = {"page":1,"total":7084,"videos":[{"id":"204017","title":"片A"}]};</script>"#;
        let data = initial_data(html).unwrap();
        assert_eq!(data["total"], 7084);
        assert_eq!(data["videos"][0]["title"], "片A");
    }

    #[test]
    fn videos_to_items_filters_blocked() {
        let data = json!({"videos": [
            {"id": "1", "title": "萝莉少女片", "thumb": "https://x/1.jpg", "date": "2026-11-05", "tag": "中文字幕"},
            {"id": "2", "title": "正常片", "thumb": "https://x/2.jpg", "date": "2026-11-05", "tag": "中文字幕"},
            {"id": "3", "title": "幼女片", "thumb": "https://x/3.jpg", "date": "2026-11-05", "tag": "中文字幕"},
        ]});
        let items = videos_to_items(&data);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/watch?id=2");
        assert_eq!(items[0]["remark"], "2026-11-05 · 中文字幕");
    }

    #[test]
    fn parse_categories_nav_then_grid_dedup() {
        let html = r#"<ul class="iw-nav"><li><a href="/topic?id=14">中文字幕</a></li><li><a href="/topic?id=5">女优系列</a></li></ul><div class="iw-cat-grid"><a class="iw-cat-card" href="/topic?id=47"><span class="iw-cat-name">过膝袜</span><span class="iw-cat-count">共 1 个视频</span></a><a class="iw-cat-card" href="/topic?id=5"><span class="iw-cat-name">女优系列</span><span class="iw-cat-count">共 5313 个视频</span></a></div>"#;
        let list = parse_categories(html);
        assert_eq!(list.len(), 3);
        assert_eq!(list[0]["id"], "t14");
        assert_eq!(list[1]["name"], "女优系列");
        assert_eq!(list[2]["id"], "t47");
    }

    #[test]
    fn fallback_has_36_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 36);
        assert_eq!(list[0]["id"], "t14");
        assert_eq!(list[35]["id"], "t22");
    }

    #[test]
    fn watch_id_forms() {
        assert_eq!(watch_id("/watch?id=204017"), "204017");
        assert_eq!(watch_id("204017"), "204017");
        assert_eq!(watch_id("https://ssis1.cc/watch?id=204017"), "204017");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://myavimg.top/VodPlay/videoUrl/play_x.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://myavimg.top/VodPlay/videoUrl/play_x.m3u8"
        );
        assert!(play_check("/watch?id=204017").is_err());
    }
}
