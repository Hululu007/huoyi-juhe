//! 推特涩涩：pektino.com JSON API + fxtwitter 补标题。
//!
//! 来源 jar 类 `ZakaPektinoAmns`（`https://pektino.com`）。
//! 列表走 `/api/media?range=&page=&per_page=50&category=&ids=
//! &isFilteredOnly=0&sort=`；详情走 `/api/media/{url_cd}`，
//! 推文正文走 `https://api.fxtwitter.com/{user}/status/{sid}`。
//! 注意：分类里的 `lolita`（别名“萝莉|lolita|ロリ”）已按
//! 用户口径删除，标签映射里 tag_id 16（ロリ系）同样跳过；
//! 列表标题用 `anime_title` 或 `@账号 · MM-DD · 时长`，
//! 推文标题只在详情里补。

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const HOST: &str = "https://pektino.com";
const API_MEDIA: &str = "/api/media";
const API_TAGS: &str = "/api/tags";
const TWEET_API: &str = "https://api.fxtwitter.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const UA_WIN: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PER_PAGE: i64 = 50;

/// (code, 显示名, 别名串)。`lolita` 已删。
const TAGS: &[(&str, &str, &str)] = &[
    ("shirouto", "素人", "业余|amateur|素人"),
    ("kyonyu", "巨乳", "丰胸|large bust|巨乳"),
    ("masturbation", "オナニー", "自慰|masturbation|オナニー"),
    ("jk", "女子高生", "女高中生|jk|女子高生"),
    ("anime", "アニメ・二次元", "动漫|二次元|anime|アニメ"),
    ("female-teacher", "女教師", "女教师|teacher|女教師"),
    ("nurse", "看護婦・ナース", "护士|nurse|ナース"),
    ("female-pervert", "痴女", "痴女|slut|female pervert"),
    ("married-woman", "人妻", "已婚|人妻|married"),
    ("beautiful-girl", "美少女", "美少女|beautiful girl"),
    ("big-sister", "お姉さん", "姐姐|お姉さん|sister"),
    ("gal", "ギャル", "时尚女孩|gal|ギャル"),
    ("shaved", "パイパン", "白虎|无毛|shaved|パイパン"),
    (
        "small-breasts",
        "貧乳・微乳",
        "贫乳|小胸|small breasts|貧乳",
    ),
    ("swimsuit", "水着", "泳装|swimsuit|水着"),
    ("sm", "SM", "sm|调教"),
    ("special-feature", "企画", "企划|feature|企画"),
    ("incest", "近親相姦", "近亲|incest|近親"),
    ("rape", "レイプ", "强暴|rape|レイプ"),
    ("molestation", "痴漢", "骚扰|痴汉|molestation|痴漢"),
    ("voyeur", "盗撮・のぞき", "偷拍|voyeur|盗撮"),
    ("pickup", "ナンパ", "搭讪|pickup|ナンパ"),
    ("massage", "マッサージ", "按摩|massage|マッサージ"),
    ("outdoor", "野外・露出", "野外|露出|outdoor|野外"),
    ("orgy", "乱交", "群交|orgy|乱交"),
    ("anal", "アナル", "肛|anal|アナル"),
    ("deep-throat", "イラマチオ", "深喉|throat|イラマチオ"),
    ("facial", "顔射", "颜射|facial|顔射"),
    ("cum-swallowing", "ごっくん", "吞精|swallow|ごっくん"),
    ("handjob", "手コキ", "手活|handjob|手コキ"),
    ("creampie", "中出し", "中出|内射|creampie|中出し"),
    ("titjob", "パイズリ", "乳交|titjob|パイズリ"),
    ("fellatio", "フェラ", "口交|fellatio|フェラ"),
    ("bukkake", "ぶっかけ", "颜射|bukkake|ぶっかけ"),
    ("hamedori", "ハメ撮り", "自拍|hamedori|ハメ撮り"),
    (
        "personal-filming",
        "個人撮影",
        "个人拍摄|自摄|personal|個人撮影",
    ),
    ("uncensored", "無修正", "无码|无修|uncensored|無修正"),
    ("gay", "ゲイ・男の娘", "男同|伪娘|gay|ゲイ"),
    ("cosplay", "コスプレ", "角色扮演|cosplay|コスプレ"),
];

const LANGS: &[(&str, &str, &str)] = &[
    ("ja", "日本", "日本|日语|ja|japanese"),
    ("zh-CN", "简体中文", "中国|简体|中文|zh-cn|chinese"),
    ("zh-TW", "繁體中文", "台湾|繁体|zh-tw"),
    ("en", "English", "英语|英文|en|english"),
    ("ko", "한국어", "韩国|韩语|ko|korean"),
    ("th", "ไทย", "泰国|泰语|th|thai"),
    ("id", "Indonesia", "印尼|id|indonesia"),
    ("pt", "Português", "葡萄牙|葡语|pt"),
    ("fr", "Français", "法国|法语|fr|french"),
    ("de", "Deutsch", "德国|德语|de|german"),
];

/// (tag_id, 名)。tag_id 16（ロリ系）已删，不列入。
const TAG_NAMES: &[(i64, &str)] = &[
    (2, "素人"),
    (3, "巨乳"),
    (4, "オナニー"),
    (6, "女子高生"),
    (7, "アニメ・二次元"),
    (8, "女教師"),
    (9, "看護婦・ナース"),
    (10, "痴女"),
    (11, "人妻"),
    (12, "美少女"),
    (13, "お姉さん"),
    (14, "ギャル"),
    (15, "パイパン"),
    (17, "水着"),
    (18, "SM"),
    (19, "企画"),
    (20, "近親相姦"),
    (21, "レイプ"),
    (22, "痴漢"),
    (23, "盗撮・のぞき"),
    (24, "ナンパ"),
    (25, "マッサージ"),
    (26, "野外・露出"),
    (27, "乱交"),
    (28, "アナル"),
    (29, "イラマチオ"),
    (30, "顔射"),
    (31, "ごっくん"),
    (32, "手コキ"),
    (33, "中出し"),
    (34, "パイズリ"),
    (35, "フェラ"),
    (36, "ぶっかけ"),
    (37, "ハメ撮り"),
    (38, "個人撮影"),
    (39, "無修正"),
    (40, "ゲイ・男の娘"),
    (41, "コスプレ"),
];

fn norm_url(u: &str) -> String {
    if u.starts_with("//") {
        format!("https:{u}")
    } else if u.starts_with("http://") {
        format!("https://{}", &u[7..])
    } else {
        u.to_string()
    }
}

fn strip_tags(s: &str) -> String {
    let tag = Regex::new(r"<[^>]*>").unwrap();
    let collapsed = Regex::new(r"\s+").unwrap();
    collapsed
        .replace_all(tag.replace_all(s, " ").as_ref(), " ")
        .trim()
        .to_string()
}

fn dur(secs: i64) -> String {
    if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, (secs % 3600) / 60, secs % 60)
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
    }
}

fn is_real(s: &str) -> bool {
    let t = s.trim();
    if t.is_empty() {
        return false;
    }
    !matches!(
        t.to_lowercase().as_str(),
        "null" | "undefined" | "none" | "nan"
    )
}

fn day_of(item: &Value) -> String {
    let posted = text_of(item, &["posted_at"]);
    if posted.len() < 10 {
        return String::new();
    }
    let b = posted.as_bytes();
    if b[4] != b'-' || b[7] != b'-' {
        return String::new();
    }
    format!("{}-{}", &posted[5..7], &posted[8..10])
}

fn real_title(item: &Value) -> String {
    let anime = strip_tags(&text_of(item, &["anime_title"]));
    if is_real(&anime) {
        return anime;
    }
    let mut sb = String::new();
    let account = strip_tags(&text_of(item, &["tweet_account"]))
        .trim()
        .to_string();
    sb.push_str(if account.is_empty() {
        "推特视频"
    } else {
        &format!("@{account}")
    });
    let day = day_of(item);
    if !day.is_empty() {
        sb.push_str(&format!(" · {day}"));
    }
    let time = get(item, "time").and_then(|v| v.as_i64()).unwrap_or(0);
    if time > 0 {
        sb.push_str(&format!(" · {}", dur(time)));
    }
    if sb.is_empty() {
        let cd = text_of(item, &["url_cd"]);
        if !cd.is_empty() {
            return cd;
        }
        return "PeKtino".to_string();
    }
    sb
}

fn remark_of(item: &Value) -> String {
    let mut parts = Vec::new();
    let time = get(item, "time").and_then(|v| v.as_i64()).unwrap_or(0);
    if time > 0 {
        parts.push(format!("⏱{}", dur(time)));
    }
    let pv = text_of(item, &["pv"]);
    if !pv.is_empty() {
        parts.push(format!("👁{pv}"));
    }
    let fav = text_of(item, &["favorite"]);
    if !fav.is_empty() && fav != "0" {
        parts.push(format!("❤{fav}"));
    }
    parts.join(" | ")
}

async fn api_get(path: &str) -> ApiResult<String> {
    let url = format!("{HOST}{path}");
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,ja;q=0.9,en;q=0.8")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("推特涩涩请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 40 {
        return Err(ApiError::Internal("推特涩涩返回过短".into()));
    }
    Ok(text)
}

fn list_query(range: &str, page: i64, category: &str, sort: &str) -> String {
    let range = if range.is_empty() { "all" } else { range };
    let sort = if sort.is_empty() { "favorite" } else { sort };
    let enc = url::form_urlencoded::byte_serialize(category.as_bytes()).collect::<String>();
    format!("range={range}&page={}&per_page={PER_PAGE}&category={enc}&ids=&isFilteredOnly=0&sort={sort}", page.max(1))
}

fn parse_list(text: &str) -> (Vec<Value>, i64, i64) {
    let Ok(body) = serde_json::from_str::<Value>(text) else {
        return (Vec::new(), 0, 0);
    };
    let mut items = Vec::new();
    if let Some(rows) = get(&body, "items").and_then(arr_of) {
        for row in rows {
            let id = text_of(row, &["url_cd"]).trim().to_string();
            if id.is_empty() {
                continue;
            }
            let title = real_title(row);
            let cover = norm_url(&text_of(row, &["thumbnail"]));
            items.push(item_json(&id, &title, &cover, &remark_of(row)));
        }
    }
    let total = get(&body, "total").and_then(|v| v.as_i64()).unwrap_or(0);
    let last_page = get(&body, "lastPage").and_then(|v| v.as_i64()).unwrap_or(0);
    (items, total, last_page)
}

async fn list(
    range: &str,
    page: i64,
    category: &str,
    sort: &str,
) -> ApiResult<(Vec<Value>, i64, i64)> {
    let text = api_get(&format!(
        "{API_MEDIA}?{}",
        list_query(range, page, category, sort)
    ))
    .await?;
    Ok(parse_list(&text))
}

fn tag_line(item: &Value) -> String {
    let mut out = Vec::new();
    if let Some(tags) = get(item, "tags").and_then(arr_of) {
        for t in tags {
            let id = get(t, "tag_id").and_then(|v| v.as_i64()).unwrap_or(-1);
            if let Some((_, name)) = TAG_NAMES.iter().find(|(tid, _)| *tid == id) {
                let name = name.to_string();
                if !out.contains(&name) {
                    out.push(name);
                }
            }
        }
    }
    out.join("、")
}

/// 推文链接取 (账号, 状态 id)。
fn tweet_key(url: &str) -> Option<(String, String)> {
    let url = url.trim();
    let pos = url.find("/status/")?;
    let sid_part = &url[pos + 8..];
    let mut len = 0;
    for c in sid_part.chars() {
        if c.is_ascii_digit() {
            len += 1;
        } else {
            break;
        }
    }
    if len == 0 {
        return None;
    }
    let sid = sid_part[..len].to_string();
    let before = &url[..pos];
    let slash = before.rfind('/')?;
    let account = before[slash + 1..].trim().to_string();
    if account.is_empty() {
        return None;
    }
    Some((account, sid))
}

async fn tweet_text(url: &str) -> String {
    let Some((account, sid)) = tweet_key(url) else {
        return String::new();
    };
    let api_url = format!("{TWEET_API}/{account}/status/{sid}");
    for attempt in 0..2 {
        if attempt == 1 {
            tokio::time::sleep(std::time::Duration::from_millis(280)).await;
        }
        let resp = match client() {
            Ok(c) => {
                c.get(&api_url)
                    .header("User-Agent", UA_WIN)
                    .header("Accept", "application/json,text/plain,*/*")
                    .header("Referer", format!("{TWEET_API}/"))
                    .send()
                    .await
            }
            Err(_) => return String::new(),
        };
        let Ok(resp) = resp else {
            continue;
        };
        let status = resp.status().as_u16();
        if status == 404 {
            return String::new();
        }
        if status != 200 {
            continue;
        }
        let Ok(text) = resp.text().await else {
            continue;
        };
        if let Ok(body) = serde_json::from_str::<Value>(&text) {
            if let Some(t) = get(&body, "tweet")
                .and_then(|t| get(t, "text"))
                .and_then(|v| v.as_str())
            {
                return t.to_string();
            }
            if let Some(t) = get(&body, "text").and_then(|v| v.as_str()) {
                return t.to_string();
            }
        }
        return String::new();
    }
    String::new()
}

fn drop_url_words(line: &str) -> String {
    line.split(' ')
        .filter(|w| {
            let l = w.to_lowercase();
            !l.starts_with("http://")
                && !l.starts_with("https://")
                && !l.starts_with("t.co/")
                && !l.starts_with("www.")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// 推文首个 ≥24 字符的词串，超 60 字符截断加 `…`。
fn title_of_tweet(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let plain = strip_tags(text);
    if plain.is_empty() {
        return String::new();
    }
    let mut sb = String::new();
    for line in plain.split('\n') {
        let line = drop_url_words(line).trim().to_string();
        if line.is_empty() {
            continue;
        }
        if !sb.is_empty() {
            sb.push(' ');
        }
        sb.push_str(&line);
        if sb.chars().count() >= 24 {
            break;
        }
    }
    let collapsed = Regex::new(r"\s+")
        .unwrap()
        .replace_all(&sb, " ")
        .trim()
        .to_string();
    if collapsed.is_empty() {
        return String::new();
    }
    if collapsed.chars().count() > 60 {
        let cut: String = collapsed.chars().take(60).collect();
        format!("{}…", cut.trim())
    } else {
        collapsed
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![category_json("hot", "🔥 全站排行")];
    for (code, name, _) in TAGS {
        list.push(category_json(code, name));
    }
    for (code, name, _) in LANGS {
        list.push(category_json(code, &format!("🌏 {name}")));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let category = if category_id.is_empty() || category_id == "hot" {
        ""
    } else {
        category_id
    };
    let (items, _total, last_page) = list("all", page, category, "favorite").await?;
    let has_more = if last_page > 0 {
        page < last_page
    } else {
        items.len() as i64 >= PER_PAGE
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(series_id.as_bytes()).collect::<String>();
    let text = api_get(&format!("{API_MEDIA}/{enc}")).await?;
    let body: Value = serde_json::from_str(&text)?;
    let mut id = text_of(&body, &["url_cd"]);
    if id.is_empty() {
        id = series_id.to_string();
    }
    // 推文链接：条目自带，无则按 ids 查一次。
    let mut tweet_url = text_of(&body, &["tweet_url"]);
    if tweet_url.is_empty() {
        let enc_id = url::form_urlencoded::byte_serialize(id.as_bytes()).collect::<String>();
        if let Ok(t) = api_get(&format!("{API_MEDIA}?ids={enc_id}&per_page=1")).await {
            if let Ok(v) = serde_json::from_str::<Value>(&t) {
                if let Some(rows) = get(&v, "items").and_then(arr_of) {
                    if let Some(first) = rows.first() {
                        tweet_url = text_of(first, &["tweet_url"]);
                    }
                }
            }
        }
    }
    let tweet = tweet_text(&tweet_url).await;
    let mut title = real_title(&body);
    let tweet_title = title_of_tweet(&tweet);
    if !tweet_title.is_empty() {
        title = tweet_title;
    }
    let cover = norm_url(&text_of(&body, &["thumbnail"]));
    let account = text_of(&body, &["tweet_account"]).trim().to_string();
    let posted = text_of(&body, &["posted_at"]);
    let posted = if posted.len() >= 10 {
        posted[..10].to_string()
    } else {
        posted
    };
    let pv = text_of(&body, &["pv"]);
    let fav = text_of(&body, &["favorite"]);
    let time = get(&body, "time").and_then(|v| v.as_i64()).unwrap_or(0);
    let tags = tag_line(&body);
    let mut synopsis = String::new();
    if !tweet.is_empty() {
        synopsis.push_str(&format!("推文：{}\n", tweet.replace('\n', " ").trim()));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("標籤：{tags}\n"));
    }
    if !account.is_empty() {
        synopsis.push_str(&format!("來源：@{account}\n"));
    }
    if time > 0 {
        synopsis.push_str(&format!("片長：{}\n", dur(time)));
    }
    if !posted.is_empty() {
        synopsis.push_str(&format!("發布：{posted}\n"));
    }
    if !pv.is_empty() {
        synopsis.push_str(&format!("播放：{pv}\n"));
    }
    if !fav.is_empty() {
        synopsis.push_str(&format!("收藏：{fav}\n"));
    }
    synopsis.push_str(&format!("\n{id}"));
    let url = norm_url(&text_of(&body, &["url"]));
    if url.is_empty() {
        return Err(ApiError::Internal("推特涩涩详情未取到视频地址".into()));
    }
    let ep_name = title.replace('$', " ").replace('#', " ");
    Ok(json!({
        "id": series_id,
        "title": if title.is_empty() { format!("PeKtino {id}") } else { title },
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"actor": if account.is_empty() { String::new() } else { format!("@{account}") }, "tags": tags},
        "episodes": [episode_json(&url, &ep_name, series_id)],
    }))
}

fn match_tag(query: &str) -> String {
    let needle = query.to_lowercase().trim().to_string();
    if needle.is_empty() {
        return String::new();
    }
    let all: Vec<(&str, &str, &str)> = TAGS
        .iter()
        .chain(LANGS.iter())
        .map(|(a, b, c)| (*a, *b, *c))
        .collect();
    for pass in 0..2 {
        for (code, name, aliases) in &all {
            if pass == 0 {
                if needle == code.to_lowercase() || needle == name.to_lowercase() {
                    return code.to_string();
                }
                for alias in aliases.split('|') {
                    if !alias.is_empty() && needle == alias.to_lowercase() {
                        return code.to_string();
                    }
                }
            } else {
                if name.len() > 1 && name.to_lowercase().contains(&needle) {
                    return code.to_string();
                }
                if code.len() > 2 && code.to_lowercase().contains(&needle) {
                    return code.to_string();
                }
                for alias in aliases.split('|') {
                    if alias.len() > 1 && alias.to_lowercase().contains(&needle) {
                        return code.to_string();
                    }
                }
            }
        }
    }
    String::new()
}

async fn resolve_code_from_site(query: &str) -> String {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let url = format!("{HOST}/search?tag={enc}");
    let resp = match client() {
        Ok(c) => {
            c.get(&url)
                .header("User-Agent", UA)
                .header("Accept", "text/html,*/*")
                .header("Accept-Language", "zh-CN,ja;q=0.9,en;q=0.8")
                .header("Referer", format!("{HOST}/"))
                .header("RSC", "1")
                .send()
                .await
        }
        Err(_) => return String::new(),
    };
    let Ok(resp) = resp else {
        return String::new();
    };
    let Ok(text) = resp.text().await else {
        return String::new();
    };
    if text.len() < 100 {
        return String::new();
    }
    let marker = "\"tag\":\"";
    let Some(pos) = text.find(marker) else {
        return String::new();
    };
    let rest = &text[pos + marker.len()..];
    let Some(end) = rest.find('"') else {
        return String::new();
    };
    let code = &rest[..end];
    if code.is_empty() || code.len() > 64 || code.contains('/') || code.contains('\\') {
        return String::new();
    }
    code.to_string()
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let mut code = match_tag(query);
    if code.is_empty() {
        code = resolve_code_from_site(query).await;
    }
    if code.is_empty() {
        return Ok(json!({"items": []}));
    }
    let (items, _, _) = list("all", 1, &code, "favorite").await?;
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = norm_url(video_id);
    if url.is_empty() {
        return Err(ApiError::Internal("推特涩涩没有播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn match_tag_exact_and_substring() {
        assert_eq!(match_tag("jk"), "jk");
        assert_eq!(match_tag("素人"), "shirouto");
        assert_eq!(match_tag("巨乳"), "kyonyu");
        // lolita 已删：精确与子串都不应命中。
        assert_eq!(match_tag("lolita"), "");
        assert_eq!(match_tag("萝莉"), "");
        assert_eq!(match_tag("ロリ"), "");
    }

    #[test]
    fn real_title_prefers_anime_title() {
        let item = json!({"anime_title": "Real Title", "tweet_account": "abc", "posted_at": "2026-01-02T00:00:00Z", "time": 65, "url_cd": "x1"});
        assert_eq!(real_title(&item), "Real Title");
        let item2 = json!({"anime_title": "", "tweet_account": "abc", "posted_at": "2026-01-02T00:00:00Z", "time": 65, "url_cd": "x1"});
        assert_eq!(real_title(&item2), "@abc · 01-02 · 1:05");
    }

    #[test]
    fn title_of_tweet_truncates() {
        let text = "这是一个很长的推文标题内容超过六十个字符需要被截断并加上省略号结尾的部分内容继续写下去直到足够长为止";
        let t = title_of_tweet(text);
        assert!(t.ends_with('…'));
        assert_eq!(t.chars().count(), 61);
    }

    #[test]
    fn tag_line_skips_lolita() {
        let item = json!({"tags": [{"tag_id": 2}, {"tag_id": 16}, {"tag_id": 3}]});
        assert_eq!(tag_line(&item), "素人、巨乳");
    }
}
