//! JavHer：`https://javher.com/`。
//!
//! 来源 jar 类 `ZakaJavherAmns`。列表页按
//! `<div class="col-4 col-md-3 col-lg-2">` 切块（每页实测 24 条），
//! 封面走 DMM 图床 `pics.dmm.co.jp/digital/video/<cid>/<cid>ps.jpg`；
//! 详情走站内 API `GET /api/video/<slug>`（头含固定
//! `Authorization: HAHA_ADAM_HAVE_TO_RESORT_TO_THIS#@!@#`）；分集
//! 为官方预览（DMM trailer m3u8）与原页面两路。
//!
//! 取流实情（据实写，不冒充）：jar 的分集最终都回到官方预览，站内
//! 没有蜘蛛可取的全长直链；全长正片在 watch 页里只以 avgle 嵌页
//! 形式存在（`avgleSource.embedded_url`），本机出口实测 avgle
//! 嵌页 000、视频页连接失败、静态预览 mp4 连接失败，均不通；
//! DMM 预览 m3u8 本机取回 403（换 DMM Referer 仍 403，疑似地区
//! 限制）。故首选 `trailerG`（media.javtrailers.com，同款官方预览，
//! 本机实测 master 200、4 档、最高档 12 分片 97.5 秒、首分片 200 +
//! TS 魔数 0x47），DMM 预览留作第二路，全长一项须手机侧复验。
//! 女优分类 17 条为正式分类（作品卡片形式）。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BASE: &str = "https://javher.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const API_AUTH: &str = "HAHA_ADAM_HAVE_TO_RESORT_TO_THIS#@!@#";

const CATEGORIES: &[(&str, &str)] = &[
    ("n|", "🔥最新上架"),
    ("u|", "🔥即将发售"),
    ("c|hi-def", "高清"),
    ("c|4k", "4K"),
    ("c|exclusive-distribution", "独家配信"),
    ("c|featured-actress", "单体作品"),
    ("c|amateur", "素人"),
    ("c|big-tits-lover", "巨乳"),
    ("c|big-asses", "美臀"),
    ("c|beautiful-legs", "美腿"),
    ("c|lesbian", "女同"),
    ("c|bdsm", "BDSM"),
    ("c|creampie", "中出"),
    ("c|blowjob", "口交"),
    ("c|facial", "颜射"),
    ("c|threesome-foursome", "3P/4P"),
    ("c|squirting", "潮吹"),
    ("c|cosplay", "角色扮演"),
    ("c|massage", "按摩"),
    ("c|pov", "POV"),
    ("c|school-uniform", "制服"),
    ("c|sailor-uniform", "水手服"),
    ("c|kimono", "和服"),
    ("c|lingerie", "内衣"),
    ("c|pantyhose", "丝袜"),
    ("c|miniskirt", "迷你裙"),
    ("c|swimsuits", "泳装"),
    ("c|maid", "女仆"),
    ("c|nurse", "护士"),
    ("c|office-lady", "OL"),
    ("c|female-teacher", "女教师"),
    ("c|housewife", "主妇"),
    ("c|mature-woman", "熟女"),
    ("c|cheating-wife", "出轨妻"),
    ("c|married-woman", "人妻"),
    ("c|idol-celebrity", "偶像艺人"),
    ("a|saika-kawakita", "🔥河北彩花"),
    ("a|seto-kanna", "🔥瀬戸環奈"),
    ("a|ichika-matsumoto", "🔥松本いちか"),
    ("a|yui-hatano", "🔥波多野結衣"),
    ("a|kibou-miu", "🔥希望みう"),
    ("a|hanamori-kaho", "🔥花守夏歩"),
    ("a|umpai", "🔥うんぱい"),
    ("a|amamiya-hanan", "🔥天宮花南"),
    ("a|miu-arioka", "🔥有岡みう"),
    ("a|waka-misono", "🔥美園和花"),
    ("a|akari-niimura", "🔥新村あかり"),
    ("a|luna-tsukino", "🔥月乃ルナ"),
    ("a|riho-shishido", "🔥宍戸里帆"),
    ("a|arisu-nanase", "🔥七瀬アリス"),
    ("a|aika-yamagishi", "🔥山岸逢花"),
    ("a|yumi-kazama", "🔥風間ゆみ"),
    ("a|hana-haruna", "🔥春菜はな"),
];

/// 分类 id 拼列表页地址（jar `catUrl` 原样）。
fn cat_url(tid: &str, page: i64) -> String {
    if tid == "n|" {
        return format!("{BASE}/videos?page={page}");
    }
    if tid == "u|" {
        return format!("{BASE}/videos/upcoming?page={page}");
    }
    if let Some(slug) = tid.strip_prefix("c|") {
        return format!("{BASE}/categories/{slug}?page={page}");
    }
    if let Some(slug) = tid.strip_prefix("a|") {
        return format!("{BASE}/casts/{slug}?page={page}");
    }
    format!("{BASE}/videos?page={page}")
}

/// 去 HTML 标签与空白。
fn strip_tags(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let out = tag_re.replace_all(s, " ");
    let out = out
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ");
    ws_re.replace_all(out.trim(), " ").to_string()
}

/// `cidOf`：`/video/watch-<cid>-<数字>` 取 cid，否则取 watch- 后子串。
fn cid_of(link: &str) -> String {
    let re = Regex::new(r"/video/watch-([a-z0-9_]+)-\d+").unwrap();
    if let Some(c) = re.captures(link) {
        return c[1].to_string();
    }
    if let Some(pos) = link.find("watch-") {
        let rest = &link[pos + 6..];
        return rest.split(['/', '?', '#']).next().unwrap_or("").to_string();
    }
    String::new()
}

/// `listPic`：DMM 图床小图。
fn list_pic(cid: &str) -> String {
    if cid.is_empty() {
        return String::new();
    }
    format!("https://pics.dmm.co.jp/digital/video/{cid}/{cid}ps.jpg")
}

async fn fetch_html(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JavHer 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 列表解析（jar `parseList`）：卡片块取链接/标题/时长备注/封面。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let block_re = Regex::new(r#"<div class="col-4 col-md-3 col-lg-2">"#).unwrap();
    let parts: Vec<&str> = block_re.split(html).collect();
    let link_re = Regex::new(r#"href="(/video/watch-[^"]+)""#).unwrap();
    let title_re = Regex::new(r#"(?s)<p class="card-text title mb-0"[^>]*>(.*?)</p>"#).unwrap();
    let title_attr_re = Regex::new(r#"title="([^"]{2,300})""#).unwrap();
    let dur_re =
        Regex::new(r#"(?s)<span class="badge duration-badge[^"]*"[^>]*>(.*?)</span>"#).unwrap();
    let small_re =
        Regex::new(r#"(?s)<small class="card-text title text-muted"[^>]*>(.*?)</small>"#).unwrap();
    for block in parts.iter().skip(1) {
        let block = if block.len() > 3000 {
            &block[..3000]
        } else {
            block
        };
        let Some(lc) = link_re.captures(block) else {
            continue;
        };
        let link = format!("{BASE}{}", &lc[1]);
        let cid = cid_of(&link);
        let mut title = title_re
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
        if title.is_empty() {
            title = title_attr_re
                .captures(block)
                .map(|c| strip_tags(&c[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            title = cid.clone();
        }
        if title.is_empty() {
            continue;
        }
        let dur = dur_re
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
        let small = small_re
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
        let mut remark = String::new();
        if !dur.is_empty() {
            remark.push_str(&dur);
        }
        if !small.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&small);
        }
        items.push(item_json(&link, &title, &list_pic(&cid), &remark));
    }
    items
}

/// 详情 slug：取 id 最后一段。
fn slug_of(id: &str) -> String {
    let trimmed = id.trim_end_matches('/');
    trimmed
        .rsplit('/')
        .next()
        .unwrap_or("")
        .split(['?', '#'])
        .next()
        .unwrap_or("")
        .to_string()
}

/// `apiVideo`：GET /api/video/<slug>，返回 video 对象。
async fn api_video(slug: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/api/video/{slug}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("Authorization", API_AUTH)
        .header("Referer", format!("{BASE}/video/{slug}"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JavHer 详情 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    match get(&body, "video") {
        Some(v) if v.is_object() => Ok(v.clone()),
        _ => Err(ApiError::Internal("JavHer 详情无 video 字段".into())),
    }
}

/// 详情解析：标题 `{dvdId} {title}`，简介多行，封面为 image 原址。
fn parse_detail(video: &Value, slug: &str) -> Value {
    let dvd_id = text_of(video, &["dvdId"]);
    let title_raw = text_of(video, &["title"]);
    let title = if dvd_id.is_empty() {
        title_raw.clone()
    } else if title_raw.is_empty() {
        dvd_id.clone()
    } else {
        format!("{dvd_id} {title_raw}")
    };
    let cover = text_of(video, &["image"]);
    let cover = if cover.is_empty() {
        list_pic(&text_of(video, &["contentId"]))
    } else {
        cover
    };
    let release = text_of(video, &["releaseDate"]);
    let release = release.chars().take(10).collect::<String>();
    let studio = get(video, "studio")
        .map(|s| text_of(s, &["name"]))
        .unwrap_or_default();
    let duration = int_of(video, &["duration"]);
    let jp_title = text_of(video, &["jpTitle"]);
    let zh_title = text_of(video, &["zhTitle"]);
    let mut casts: Vec<String> = Vec::new();
    if let Some(rows) = get(video, "casts").and_then(arr_of) {
        for c in rows {
            let name = text_of(c, &["jpName", "name"]);
            if !name.is_empty() && !casts.contains(&name) {
                casts.push(name);
            }
        }
    }
    let mut cats: Vec<String> = Vec::new();
    if let Some(rows) = get(video, "categories").and_then(arr_of) {
        for c in rows {
            let name = text_of(c, &["zhName", "name"]);
            if !name.is_empty() && !cats.contains(&name) {
                cats.push(name);
            }
        }
    }
    let mut synopsis = String::new();
    if !release.is_empty() {
        synopsis.push_str(&format!("發售：{release}\n"));
    }
    if !studio.is_empty() {
        synopsis.push_str(&format!("片商：{studio}\n"));
    }
    if duration > 0 {
        synopsis.push_str(&format!("時長：{duration} 分\n"));
    }
    if !jp_title.is_empty() {
        synopsis.push_str(&format!("日文標題：{jp_title}\n"));
    }
    if !zh_title.is_empty() {
        synopsis.push_str(&format!("中文標題：{zh_title}\n"));
    }
    if !casts.is_empty() {
        synopsis.push_str(&format!("女優：{}\n", casts.join(" / ")));
    }
    if !cats.is_empty() {
        synopsis.push_str(&format!("分類：{}\n", cats.join(" / ")));
    }
    let page = format!("{BASE}/video/{slug}");
    synopsis.push_str(&format!("來源：{page}"));
    let trailer = text_of(video, &["trailer"]);
    let trailer_g = text_of(video, &["trailerG"]);
    let mut episodes = Vec::new();
    if !trailer_g.is_empty() {
        episodes.push(episode_json(&format!("o|{trailer_g}"), "官方预览G", &page));
    }
    if !trailer.is_empty() {
        episodes.push(episode_json(&format!("o|{trailer}"), "官方预览", &page));
    }
    episodes.push(episode_json(&format!("p|{page}"), "原頁面", &page));
    json!({
        "id": page,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim_end().to_string(),
        "extra": {},
        "episodes": episodes,
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATEGORIES
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = fetch_html(&cat_url(category_id, page)).await?;
    let items = parse_list(&html);
    let has_more = items.len() >= 24;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let slug = slug_of(id);
    if slug.is_empty() {
        return Err(ApiError::Internal("JavHer 详情缺少编号".into()));
    }
    let video = api_video(&slug).await?;
    Ok(parse_detail(&video, &slug))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{BASE}/search/{}?page=1",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch_html(&url).await?;
    let items = parse_list(&html);
    Ok(json!({"items": items}))
}

/// 取流：官方预览为 DMM m3u8 直链；原頁面重取详情回官方预览；
/// javher.com 地址重取详情；4 位短 id 拼 video 地址再取详情。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let media_re = Regex::new(r#"https?://[^"'<>\s]+\.(m3u8|mp4)(\?|$)"#).unwrap();
    if let Some(rest) = video_id.strip_prefix("o|") {
        return Ok(json!({"url": rest.trim()}));
    }
    if let Some(rest) = video_id.strip_prefix("p|") {
        let detail_value = detail(rest.trim()).await?;
        return play_from_detail(&detail_value);
    }
    if media_re.is_match(video_id) {
        return Ok(json!({"url": video_id}));
    }
    if video_id.contains("javher.com") {
        let detail_value = detail(video_id).await?;
        return play_from_detail(&detail_value);
    }
    if video_id.len() == 4 {
        let url = format!("{BASE}/video/{video_id}");
        let detail_value = detail(&url).await?;
        return play_from_detail(&detail_value);
    }
    Err(ApiError::Internal("JavHer 该集没有播放地址".into()))
}

/// 从详情分集里取第一条官方预览地址。
fn play_from_detail(detail_value: &Value) -> ApiResult<Value> {
    if let Some(eps) = get(detail_value, "episodes").and_then(arr_of) {
        for ep in eps {
            let vid = text_of(ep, &["video_id"]);
            if let Some(rest) = vid.strip_prefix("o|") {
                return Ok(json!({"url": rest.trim()}));
            }
            if vid.starts_with("http") {
                return Ok(json!({"url": vid}));
            }
        }
    }
    Err(ApiError::Internal("JavHer 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cat_url_forms() {
        assert_eq!(cat_url("n|", 1), "https://javher.com/videos?page=1");
        assert_eq!(
            cat_url("u|", 2),
            "https://javher.com/videos/upcoming?page=2"
        );
        assert_eq!(
            cat_url("c|hi-def", 1),
            "https://javher.com/categories/hi-def?page=1"
        );
        assert_eq!(
            cat_url("a|yui-hatano", 1),
            "https://javher.com/casts/yui-hatano?page=1"
        );
    }

    #[test]
    fn cid_of_watch_links() {
        assert_eq!(cid_of("/video/watch-bada00015-1623427200000"), "bada00015");
        assert_eq!(cid_of("/video/watch-abc_def"), "abc_def");
    }

    #[test]
    fn parse_list_card() {
        let html = r#"<div class="col-4 col-md-3 col-lg-2"><a href="/video/watch-bada00015-1623427200000"><p class="card-text title mb-0">BADA-015 测试标题</p><span class="badge duration-badge">2:12:00</span></a></div>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "BADA-015 测试标题");
        assert_eq!(
            items[0]["cover"],
            "https://pics.dmm.co.jp/digital/video/bada00015/bada00015ps.jpg"
        );
        assert_eq!(items[0]["remark"], "2:12:00");
    }

    #[test]
    fn parse_detail_fields() {
        let video = json!({
            "dvdId": "BADA-015",
            "title": "Masochist Married Woman",
            "contentId": "bada00015",
            "image": "https://pics.dmm.co.jp/digital/video/bada00015/bada00015pl.jpg",
            "trailer": "https://cc3001.dmm.co.jp/hlsvideo/freepv/b/bad/bada015/playlist.m3u8",
            "trailerG": "https://media.javtrailers.com/hlsvideo/freepv/b/bad/bada00015/playlist.m3u8",
            "releaseDate": "2021-06-11T16:00:00.000Z",
            "duration": 132,
            "jpTitle": "マゾ人妻",
            "zhTitle": "马佐已婚妇女",
            "studio": {"name": "Baltan"},
            "casts": [{"jpName": "加藤あやの"}],
            "categories": [{"zhName": "人妻"}, {"zhName": "高清"}],
        });
        let detail_value = parse_detail(&video, "watch-bada00015-1623427200000");
        assert_eq!(detail_value["title"], "BADA-015 Masochist Married Woman");
        assert!(detail_value["synopsis"]
            .as_str()
            .unwrap()
            .contains("時長：132 分"));
        let eps = detail_value["episodes"].as_array().unwrap();
        assert_eq!(eps.len(), 3);
        assert!(eps[0]["video_id"]
            .as_str()
            .unwrap()
            .starts_with("o|https://media.javtrailers.com/"));
        assert!(eps[1]["video_id"]
            .as_str()
            .unwrap()
            .starts_with("o|https://cc3001.dmm.co.jp/"));
    }
}
