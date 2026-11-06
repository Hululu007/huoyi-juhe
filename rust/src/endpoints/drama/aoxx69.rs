//! AOXX69：HTML 站（列表/详情正则解析，取流走站内 vs.m3u8）。
//!
//! 与 jar 的 ZakaAoxx69Amns 一一对应：分类（静态 h/j/p/cl/an＋36
//! 个分类——已按口径删“貧乳蘿莉”，剩 35 个＋24 个女优＋163 个
//! 标签）、目录（jav/clips/anime/popular/tag/av-stars-view）、
//! 详情（取 iframe 的 video-play 参数拼分集）、搜索（三路单卡＋
//! 标签搜索补齐）、取流（先拼 vs.m3u8 直探，含 #EXTM3U 即回，
//! 否则抓 video-play 页的 var source 再探；m3u8 本身为标准
//! AES-128 加密分片，播放器原生处理）。
//! 2026-11-05 本机已验：/hk/jav?page=1 200；详情 GENT-143 取到
//! iframe 参数（publish_time/video_lock/poster）；vs.m3u8 直
//! 接 200 且为真实 HLS 清单。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const BASE_URL: &str = "https://www.aoxx69.app";
const IMG_BASE_URL: &str = "https://img.aoxx69.app";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类表（clinit 原文，36 条；“貧乳蘿莉”已按口径删除，剩 35 条）。
const CATS: &[&str] = &[
    "泰國字幕", "近親相姦", "日本無碼", "學生妹", "歐美無碼", "翹臀美尻", "群P亂舞", "巨乳咪咪", "素人系列",
    "熟女人妻", "絲襪長腿", "清純可愛", "獨家推薦", "女性專區", "女歡女愛", "狂野奔放", "重鹹口味", "男同性戀",
    "野外露出", "角色扮演", "無套內射", "第一視角", "虛擬實境", "女老師", "辦公女郎", "自拍偷拍", "口交",
    "按摩", "手淫自慰", "顏射", "大號美女", "職業", "時間停止", "女同性戀", "多片合輯",
];

/// 女优表（clinit 原文，24 条）。
const STARS: &[&str] = &[
    "素人", "無碼素人", "三上悠亜", "安齋らら", "有栖花あか", "安位カヲル", "夢乃あいか", "新名あみん",
    "架乃ゆら", "奥田咲", "星宮一花", "乙白さやか", "潮美舞", "高橋しょう子", "水卜さくら", "七沢みあ",
    "小野六花", "藍芽みずき", "日下部加奈", "深田えいみ", "桜空もも", "桃乃木かな", "相沢みなみ", "西宮ゆめ",
];

/// 标签表（clinit 原文，163 条；其中的“貧乳・微乳”是标签，按口径保留）。
const TAGS: &[&str] = &[
    "泰國字幕", "母親", "熟女", "素人", "単体作品", "人妻・主婦", "美少女", "痴女", "女子校生", "お姉さん",
    "人妻", "コスプレ", "キャバ嬢・風俗嬢", "お母さん", "姉・妹", "アイドル・芸能人", "職業色々", "已婚婦女",
    "看護婦・ナース", "女子大生", "メイド", "業餘", "高中女生", "AV女優", "女教師", "痴漢", "蕩婦",
    "エステ", "花嫁・若妻", "花癡", "義母", "首次亮相", "M男", "姐姐", "競泳・スクール水着", "OL",
    "中出し", "フェラ", "乱交", "尻フェチ", "潮吹き", "パイズリ", "クンニ", "近親相姦", "ナンパ",
    "その他フェチ", "イラマチオ", "羞恥", "キス・接吻", "中出", "寝取り・寝取られ", "顔射", "盗撮・のぞき",
    "フェラチオ", "自慰", "輪姦", "潮吹", "ごっくん", "口交", "口内発射", "放尿", "偷窥", "乳交",
    "強姦", "性奴", "出軌", "生ハメ", "手コキ", "オナニー", "騎乗位", "拘束", "辱め", "淫語",
    "アナル", "デカチン・巨根", "アナルセックス", "バック", "汗だく", "足コキ", "バイブ", "69",
    "生ハメ・生姦", "多P", "顏射", "電マ", "指マン", "縛り・緊縛", "凌辱", "巨乳フェチ", "ドラッグ",
    "レズキス", "女上位", "脚フェチ", "ぶっかけ", "おもちゃ", "SM", "巨乳", "スレンダー", "美乳",
    "パイパン", "貧乳・微乳", "長身", "童貞", "美尻", "美脚", "巨尻", "色白", "ギャル", "乳房",
    "苗條", "小柄", "女優ベスト・総集編", "ぽっちゃり", "ハイビジョン", "簡體中文", "高畫質", "無碼",
    "サンプル動画", "ハメ撮り", "歐美", "ギリモザ", "數位馬賽克", "オリジナル動画", "成人動畫", "成人卡通",
    "H動畫", "中文字幕", "主観", "寝取り・寝取られ・NTR", "淫乱・ハード系", "独占配信", "ドラマ", "不倫",
    "マッサージ", "單體作品", "DMM獨家", "ミニ系", "4時間以上作品", "3P・4P", "企画", "温泉",
    "ドキュメンタリー", "野外・露出", "調教・奴隷", "ベスト・総集編", "レズ", "イタズラ", "企畫",
    "デビュー作品", "单体作品", "4小時以上作品", "纪录片", "めがね", "戲劇", "ハーレム", "制服",
    "学生服", "水着", "パンチラ", "和服・浴衣", "ランジェリー", "セーラー服", "校服",
];

fn headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
        ),
        (
            "Accept-Language".to_string(),
            "zh-CN,zh;q=0.9,en;q=0.8".to_string(),
        ),
        ("Referer".to_string(), format!("{BASE_URL}/hk/")),
    ]
}

/// 与 Java 的 ZakaHttp.enc 一致：标准 URL 编码。
fn enc(raw: &str) -> String {
    url::form_urlencoded::byte_serialize(raw.as_bytes()).collect()
}

/// 百分号解码（avkey 用；解不出时回原文）。
fn dec(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && bytes[i + 1].is_ascii_hexdigit()
            && bytes[i + 2].is_ascii_hexdigit()
        {
            let h = (bytes[i + 1] as char).to_digit(16).unwrap_or(0);
            let l = (bytes[i + 2] as char).to_digit(16).unwrap_or(0);
            out.push((h * 16 + l) as u8);
            i += 3;
        } else if bytes[i] == b'+' {
            out.push(b' ');
            i += 1;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 去标签、解实体、去空白（与 jar 的 strip/clean 一致）。
fn plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(ch);
                }
            }
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

async fn page(url: &str) -> ApiResult<String> {
    let mut req = client()?.get(url);
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("AOXX69 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(text)
}

async fn page_status(url: &str) -> i64 {
    let mut req = match client() {
        Ok(c) => c.get(url),
        Err(_) => return 0,
    };
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    match req.send().await {
        Ok(resp) => resp.status().as_u16() as i64,
        Err(_) => 0,
    }
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("aoxx69 regex")
}

fn cap<'a>(re: &Regex, text: &'a str, group: usize) -> String {
    match re.captures(text) {
        Some(c) => c
            .get(group)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default(),
        None => String::new(),
    }
}

fn type_of(path: &str) -> i64 {
    if path.contains("/jav/") {
        1
    } else if path.contains("/clips/") {
        2
    } else if path.contains("/anime/") {
        3
    } else {
        1
    }
}

fn type_name(t: i64) -> &'static str {
    match t {
        2 => "短片",
        3 => "動畫",
        _ => "JAV",
    }
}

fn parse_list(html: &str) -> Vec<Value> {
    let list_re = re(r#"<a[^>]+href="(/hk/(?:jav|clips|anime)/([^"]+))"[^>]*>(.{0,1200}?)</a>"#);
    let img_re = re(r#"(?:data-src|data-original|src)="([^"]+)""#);
    let alt_re = re(r#"alt="([^"]*)""#);
    let gtm_re = re(r#"gtm-name="([^"]*)""#);
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    for c in list_re.captures_iter(html) {
        let path = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let seg = c.get(2).map(|m| m.as_str()).unwrap_or("");
        let inner = c.get(3).map(|m| m.as_str()).unwrap_or("");
        if path.is_empty() || seg.is_empty() {
            continue;
        }
        let t = type_of(path);
        let avkey = dec(seg);
        let id = format!("{t}|{avkey}");
        if !seen.insert(id.clone()) {
            continue;
        }
        let mut title = plain(&cap(&alt_re, inner, 1));
        if title.is_empty() {
            title = plain(&cap(&gtm_re, inner, 1));
        }
        if title.is_empty() {
            continue;
        }
        let mut cover = cap(&img_re, inner, 1);
        if cover.contains("banner")
            || cover.contains("/image/header")
            || cover.contains("/image/teach")
            || cover.contains("/image/game")
            || cover.contains("/image/activity")
        {
            cover = String::new();
        }
        let remark = match t {
            2 => "短片".to_string(),
            3 => "動畫".to_string(),
            _ => String::new(),
        };
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut cats = vec![
        category_json("h:home", "★最新"),
        category_json("j:new", "長片·最新"),
        category_json("p:hot", "🔥熱門"),
        category_json("cl:new", "短片·Short"),
        category_json("an:new", "動畫·Anime"),
    ];
    for cat in CATS {
        cats.push(category_json(&format!("c:{cat}"), cat));
    }
    for star in STARS {
        cats.push(category_json(&format!("st:{star}"), &format!("女優·{star}")));
    }
    for tag in TAGS {
        cats.push(category_json(&format!("t:{tag}"), &format!("標籤·{tag}")));
    }
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, pg: i64) -> ApiResult<Value> {
    let pg = if pg < 1 { 1 } else { pg };
    let url = if category_id == "h:home" || category_id == "j:new" {
        format!("{BASE_URL}/hk/jav?page={pg}")
    } else if category_id == "p:hot" {
        format!("{BASE_URL}/hk/popular")
    } else if category_id == "cl:new" {
        format!("{BASE_URL}/hk/clips?page={pg}")
    } else if category_id == "an:new" {
        format!("{BASE_URL}/hk/anime?page={pg}")
    } else if let Some(id) = category_id.strip_prefix("st:") {
        format!("{BASE_URL}/hk/av-stars-view?origin_id={}", enc(id))
    } else if let Some(tag) = category_id.strip_prefix("t:") {
        format!(
            "{BASE_URL}/hk/tag/jav?tag={}&origin_id={}&page={pg}",
            enc(tag),
            enc(tag)
        )
    } else if let Some(cat) = category_id.strip_prefix("c:") {
        format!(
            "{BASE_URL}/hk/jav?category={}&origin_id={}&page={pg}",
            enc(cat),
            enc(cat)
        )
    } else {
        format!("{BASE_URL}/hk/jav?page={pg}")
    };
    let html = page(&url).await?;
    let items = parse_list(&html);
    let has_more = items.len() >= 15;
    Ok(json!({"items": items, "has_more": has_more}))
}

fn detail_url(t: i64, path: &str) -> String {
    match t {
        2 => format!("{BASE_URL}/hk/clips/{}", enc(path)),
        3 => format!("{BASE_URL}/hk/anime/{}", enc(path)),
        _ => format!("{BASE_URL}/hk/jav/{}", enc(path)),
    }
}

fn cover_of(html: &str, avkey: &str) -> String {
    let cover_re = re(
        r#"(https://img\.aoxx69\.app/(?:data/adult-videos/[^/\"\s]+/cover/|imgs/cover/)[^\"\s]+)"#,
    );
    let found = cap(&cover_re, html, 1);
    if !found.is_empty() {
        return found;
    }
    format!("{IMG_BASE_URL}/data/adult-videos/{avkey}/cover/{avkey}.jpg")
}

/// 从 iframe 地址里取 query 参数（publish_time/video_lock/poster/id）。
fn qv(url: &str, key: &str) -> String {
    let needle = format!("{key}=");
    let Some(start) = url.find(&needle) else {
        return String::new();
    };
    let rest = &url[start + needle.len()..];
    let end = rest.find('&').unwrap_or(rest.len());
    dec(&rest[..end])
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let parts: Vec<&str> = series_id.split('|').collect();
    if parts.len() < 2 {
        return Err(ApiError::Internal("AOXX69 详情 id 格式错误".into()));
    }
    let t: i64 = parts[0].parse().unwrap_or(1);
    let path = parts[1];
    let url = detail_url(t, path);
    let html = page(&url).await?;
    let title_re = re(r"<title>(.*?)</title>");
    let mut title = plain(&cap(&title_re, &html, 1));
    if let Some(stripped) = title.strip_suffix("-AOXX69") {
        title = stripped.trim().to_string();
    }
    let cover = cover_of(&html, path);
    let desc_re = re(r#"<p class="moretext[^"]*"[^>]*>(.*?)</p>"#);
    let synopsis = plain(&cap(&desc_re, &html, 1));
    let date_re = re(r#"class="view_show_time[^"]*"[^>]*>([^<]+)<"#);
    let views_re = re(r#"class="viewers_count[^"]*"[^>]*>(.*?)</div>"#);
    let date = plain(&cap(&date_re, &html, 1));
    let views = plain(&cap(&views_re, &html, 1));
    let mut remark = String::new();
    if !date.is_empty() {
        remark.push_str(&date);
    }
    if !views.is_empty() {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str(&views);
    }
    let actor_re = re(r#"href="/hk/av-stars-view\?origin_id=([^"&]+)""#);
    let mut actors: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for c in actor_re.captures_iter(&html) {
        let a = dec(c.get(1).map(|m| m.as_str()).unwrap_or(""));
        if !a.is_empty() && seen.insert(a.clone()) {
            actors.push(a);
        }
    }
    let tag_re = re(r#"href="/hk/tag/jav\?tag=([^"&]+)""#);
    let mut tags: Vec<String> = Vec::new();
    let mut seen_tag = HashSet::new();
    for c in tag_re.captures_iter(&html) {
        let tag = dec(c.get(1).map(|m| m.as_str()).unwrap_or(""));
        if !tag.is_empty() && seen_tag.insert(tag.clone()) && tags.len() < 12 {
            tags.push(tag);
        }
    }
    let mut synopsis_full = synopsis;
    if !actors.is_empty() {
        if !synopsis_full.is_empty() {
            synopsis_full.push('\n');
        }
        synopsis_full.push_str(&format!("女優：{}", actors.join(", ")));
    }
    if !tags.is_empty() {
        if !synopsis_full.is_empty() {
            synopsis_full.push('\n');
        }
        synopsis_full.push_str(&format!("標籤：{}", tags.join(" ")));
    }
    let iframe1 = re(r#"<iframe[^>]*class="[^"]*video_player[^"]*"[^>]*src="([^"]+)""#);
    let iframe2 = re(r#"<iframe[^>]*src="(/video/video-play[^"]*)""#);
    let mut iframe = cap(&iframe1, &html, 1);
    if iframe.is_empty() {
        iframe = cap(&iframe2, &html, 1);
    }
    let mut episodes = Vec::new();
    if !iframe.is_empty() {
        let publish_time = qv(&iframe, "publish_time");
        let mut lock = qv(&iframe, "video_lock");
        if lock.is_empty() {
            lock = "N".to_string();
        }
        let poster = qv(&iframe, "poster");
        let video_id = format!("{t}|{path}|{publish_time}|{lock}|{poster}");
        episodes.push(episode_json(&video_id, &title, series_id));
    }
    let _ = remark;
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis_full,
        "extra": {"area": type_name(t)},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let mut items: Vec<Value> = Vec::new();
    let mut seen = HashSet::new();
    for (t, prefix) in [(1i64, "/jav/"), (2i64, "/clips/"), (3i64, "/anime/")] {
        if items.len() >= 20 {
            break;
        }
        let url = format!("{BASE_URL}/hk{prefix}{}", enc(query));
        if page_status(&url).await != 200 {
            continue;
        }
        let html = match page(&url).await {
            Ok(h) => h,
            Err(_) => continue,
        };
        let title_re = re(r"<title>(.*?)</title>");
        let mut title = plain(&cap(&title_re, &html, 1));
        if let Some(stripped) = title.strip_suffix("-AOXX69") {
            title = stripped.trim().to_string();
        }
        if title.is_empty() {
            continue;
        }
        let id = format!("{t}|{query}");
        if !seen.insert(id.clone()) {
            continue;
        }
        let cover = cover_of(&html, query);
        items.push(item_json(&id, &title, &cover, type_name(t)));
    }
    if items.len() < 20 {
        let url = format!(
            "{BASE_URL}/hk/tag/jav?tag={}&origin_id={}",
            enc(query),
            enc(query)
        );
        if let Ok(html) = page(&url).await {
            for item in parse_list(&html) {
                if items.len() >= 60 {
                    break;
                }
                let id = item
                    .get("id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if seen.insert(id) {
                    items.push(item);
                }
            }
        }
    }
    Ok(json!({"items": items}))
}

fn site_of(t: i64) -> &'static str {
    match t {
        2 => "short_video_url",
        3 => "animate_video_url",
        _ => "long_video_url",
    }
}

async fn probe_m3u8(url: &str, referer: &str) -> bool {
    let mut req = match client() {
        Ok(c) => c.get(url),
        Err(_) => return false,
    };
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    req = req.header("Referer", referer);
    match req.send().await {
        Ok(resp) => {
            if resp.status().as_u16() != 200 {
                return false;
            }
            match resp.text().await {
                Ok(text) => text.contains("#EXTM3U"),
                Err(_) => false,
            }
        }
        Err(_) => false,
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let parts: Vec<&str> = video_id.split('|').collect();
    if parts.len() < 2 {
        return Err(ApiError::Internal("AOXX69 分集 id 格式错误".into()));
    }
    let t: i64 = parts[0].parse().unwrap_or(1);
    let path = parts[1];
    let publish_time = parts.get(2).copied().unwrap_or("");
    let lock = parts.get(3).copied().unwrap_or("N");
    let poster = parts.get(4).copied().unwrap_or("");
    let referer = detail_url(t, path);
    let vs = format!(
        "{BASE_URL}/vs.m3u8?avkey={}&site={}&path={}",
        enc(path),
        site_of(t),
        enc(&format!("{path}/240/{path}.m3u8"))
    );
    if probe_m3u8(&vs, &referer).await {
        return Ok(json!({"url": vs}));
    }
    let play_page = format!(
        "{BASE_URL}/video/video-play?id={}&type={}&autoplay=0&publish_time={}&video_lock={}&poster={}",
        enc(path),
        t,
        enc(publish_time),
        enc(lock),
        enc(poster)
    );
    let html = page(&play_page).await?;
    let src_re = re(r"var\s+source\s*=\s*'([^']+)'");
    let source = cap(&src_re, &html, 1);
    if source.is_empty() {
        return Err(ApiError::Internal("AOXX69 未取到播放地址".into()));
    }
    let mut url = source;
    if url.starts_with("//") {
        url = format!("https:{url}");
    } else if url.starts_with('/') {
        url = format!("{BASE_URL}{url}");
    }
    if !url.contains("/vs.m3u8") {
        return Err(ApiError::Internal("AOXX69 未取到有效播放地址".into()));
    }
    if probe_m3u8(&url, &referer).await {
        return Ok(json!({"url": url}));
    }
    Err(ApiError::Internal("AOXX69 播放地址验证失败".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_loli_removed() {
        assert!(!CATS.contains(&"貧乳蘿莉"));
        assert_eq!(CATS.len(), 35);
        assert_eq!(STARS.len(), 24);
        assert_eq!(TAGS.len(), 163);
    }

    #[test]
    fn type_detection() {
        assert_eq!(type_of("/hk/jav/GENT-143"), 1);
        assert_eq!(type_of("/hk/clips/abc"), 2);
        assert_eq!(type_of("/hk/anime/xyz"), 3);
    }

    #[test]
    fn parse_list_sample() {
        let html = r##"<a href="/hk/jav/GENT-143" class="x"><img data-src="https://img.aoxx69.app/a.jpg" alt="GENT-143 标题"></a><a href="/hk/clips/C1" class="x"><img src="https://img.aoxx69.app/b.jpg" alt="短片标题"></a>"##;
        let items = parse_list(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "1|GENT-143");
        assert_eq!(items[0]["title"], "GENT-143 标题");
        assert_eq!(items[1]["id"], "2|C1");
        assert_eq!(items[1]["remark"], "短片");
    }

    #[test]
    fn qv_params() {
        let url = "/video/video-play?id=GENT-143&type=1&autoplay=0&publish_time=2019-11-11+16%3A34%3A00&video_lock=N&poster=https%3A%2F%2Fx.jpg";
        assert_eq!(qv(url, "publish_time"), "2019-11-11 16:34:00");
        assert_eq!(qv(url, "video_lock"), "N");
        assert_eq!(qv(url, "poster"), "https://x.jpg");
    }

    #[test]
    fn vs_url_shape() {
        let path = "GENT-143";
        let vs = format!(
            "{}/vs.m3u8?avkey={}&site={}&path={}",
            BASE_URL,
            enc(path),
            site_of(1),
            enc(&format!("{path}/240/{path}.m3u8"))
        );
        assert!(vs.contains("avkey=GENT-143"));
        assert!(vs.contains("site=long_video_url"));
        assert!(vs.contains("path=GENT-143%2F240%2FGENT-143.m3u8"));
    }
}
