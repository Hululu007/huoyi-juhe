//! 🔞JAVMIT：javmit.com 的 WordPress 站（rawx 主题），免费 HD 流。
//!
//! 列表（article.v-card 卡片解析：帖子链接取 id、img 取封面、
//! alt 取标题、vc-dur 取时长；分类页 12 条/页，翻页 `/page/N/`；
//! 搜索 `/?s=词`）、详情（og 标题、meta 简介、封面图、
//! JSON-LD / video:duration 取时长）、取流（详情页 og:video 即
//! s2.javmit.com 的 master.m3u8，1080p/480p 变体同目录，须现取现用）。
//! 验门（2026-11-06 本机出口实测）：/categories/ 页 100 分类（模块
//! 取其中 95 个有效分类，3 个畸形 slug 与 debuts/insct 两个 0 条
//! 空分类未入）；creampie 分类 p1 12 条、p2 12 条不重合；搜索 GANA
//! 12 条；详情 GANA-3482 的 og:video 清单 master 200、1080p 变体
//! 1079 分片/4315.11 秒，与 JSON-LD 时长 PT1H11M55S 及
//! video:duration 4315 精确对上（全长非预告）；首分片 Range 206 +
//! TS 魔数 0x47。
//! 分类与站 /categories/ 页 1:1；翻页 `/category/{slug}/page/{N}/`。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javmit.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：/categories/ 页验过的 95 个有效分类（站名原样大写）。
const CATS: &[(&str, &str)] = &[
    ("creampie", "CREAMPIE"),
    ("solowork", "SOLOWORK"),
    ("big-tits", "BIG TITS"),
    ("married", "MARRIED"),
    ("amateur", "AMATEUR"),
    ("blowjob", "BLOWJOB"),
    ("slut", "SLUT"),
    ("ol", "OL"),
    ("beautiful-girl", "BEAUTIFUL GIRL"),
    ("slender", "SLENDER"),
    ("pov", "POV"),
    ("boobs-fetish", "BOOBS FETISH"),
    ("3p", "3P"),
    ("mature", "MATURE"),
    ("squirting", "SQUIRTING"),
    ("orgasm", "ORGASM"),
    ("big-breasts", "BIG BREASTS"),
    ("individual", "INDIVIDUAL"),
    ("cuckold", "CUCKOLD"),
    ("mature-woman", "MATURE WOMAN"),
    ("back", "BACK"),
    ("drama", "DRAMA"),
    ("schoolgirls", "SCHOOLGIRLS"),
    ("cunnilingus", "CUNNILINGUS"),
    ("facials", "FACIALS"),
    ("big-butt", "BIG BUTT"),
    ("uniform", "UNIFORM"),
    ("kissing", "KISSING"),
    ("cowgirl", "COWGIRL"),
    ("titty-fuck", "TITTY FUCK"),
    ("orgy", "ORGY"),
    ("toy", "TOY"),
    ("documentary", "DOCUMENTARY"),
    ("nasty", "NASTY"),
    ("deep-throat", "DEEP THROAT"),
    ("mother", "MOTHER"),
    ("uncategorized", "UNCATEGORIZED"),
    ("cosplay", "COSPLAY"),
    ("affair", "AFFAIR"),
    ("shaved", "SHAVED"),
    ("humiliation", "HUMILIATION"),
    ("bukkake", "BUKKAKE"),
    ("subtitles", "字幕付き"),
    ("debut-production", "DEBUT PRODUCTION"),
    ("handjob", "HANDJOB"),
    ("anal", "ANAL"),
    ("original", "ORIGINAL"),
    ("planning", "PLANNING"),
    ("pantyhose", "PANTYHOSE"),
    ("voyeur", "VOYEUR"),
    ("incest", "INCEST"),
    ("dirty-talk", "DIRTY TALK"),
    ("other-fetish", "OTHER FETISH"),
    ("lotion", "LOTION"),
    ("lesbian", "LESBIAN"),
    ("gal", "GAL"),
    ("cum", "CUM"),
    ("nampa", "NAMPA"),
    ("transsexual", "TRANSSEXUAL"),
    ("urination", "URINATION"),
    ("sweat", "SWEAT"),
    ("mini", "MINI"),
    ("close-up", "CLOSE UP"),
    ("cross-dressing", "CROSS DRESSING"),
    ("big-breast-fetish", "BIG BREAST FETISH"),
    ("beauty-shop", "BEAUTY SHOP"),
    ("outdoors", "OUTDOORS"),
    ("leg-fetish", "LEG FETISH"),
    ("action", "ACTION"),
    ("bbw", "BBW"),
    ("special-effects", "SPECIAL EFFECTS"),
    ("school-uniform", "SCHOOL UNIFORM"),
    ("busty-fetish", "BUSTY FETISH"),
    ("vibe", "VIBE"),
    ("lesbian-kiss", "LESBIAN KISS"),
    ("huge-butt", "HUGE BUTT"),
    ("4hr", "4HR"),
    ("prank", "PRANK"),
    ("petite", "PETITE"),
    ("drug", "DRUG"),
    ("foot-fetish", "FOOT FETISH"),
    ("panty-flash", "PANTY FLASH"),
    ("butt-fetish", "BUTT FETISH"),
    ("bunny-girl", "BUNNY GIRL"),
    ("old-friend", "OLD FRIEND"),
    ("loli", "LOLI"),
    ("hardcore", "HARDCORE"),
    ("69", "69"),
    ("hd", "HD"),
    ("dance", "DANCE"),
    ("rape", "RAPE"),
    ("black-actor", "BLACK ACTOR"),
    ("digital-mosaic", "DIGITAL MOSAIC"),
    ("hentai-collab", "HENTAI COLLAB"),
    ("4k", "4K"),
];

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAVMIT 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—")
        .trim()
        .to_string()
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// 卡片 alt 形如 `JUR-918 (...) [Download and Stream]`，
/// 去掉末尾的下载后缀。
fn clean_card_title(raw: &str) -> String {
    let mut s = decode_entities(raw);
    if let Some(i) = s.find("[Download and Stream]") {
        s = s[..i].trim().to_string();
    }
    truncate(&s, 90)
}

/// `<article class="v-card">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article class=\"v-card\"").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a href=\"https://javmit.com/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        if href.ends_with("/feed/") || href.contains("/category/") || href.contains("/tag/") {
            continue;
        }
        let id = href.to_string();
        if seen.contains(&id) {
            continue;
        }
        let title = match block.find("alt=\"") {
            Some(p) => {
                let s = p + 5;
                block[s..]
                    .find('"')
                    .map(|e| clean_card_title(&block[s..s + e]))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let cover = match block.find("src=\"https://javmit.com/wp-content/uploads/") {
            Some(p) => {
                let s = p + 5;
                block[s..]
                    .find('"')
                    .map(|e| block[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match block.find("<div class=\"vc-dur\">") {
            Some(p) => {
                let s = p + 20;
                block[s..]
                    .find("</div>")
                    .map(|e| block[s..s + e].trim().to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        seen.push(id.clone());
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let slug = if category_id.is_empty() {
        "creampie"
    } else {
        category_id
    };
    if page <= 1 {
        format!("{HOST}/category/{slug}/")
    } else {
        format!("{HOST}/category/{slug}/page/{page}/")
    }
}

fn meta_content(html: &str, attr: &str, key: &str) -> String {
    let marker = format!("{attr}=\"{key}\"");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let after = &html[p..];
    let Some(c) = after.find("content=\"") else {
        return String::new();
    };
    let s = c + 9;
    after[s..]
        .find('"')
        .map(|e| decode_entities(&after[s..s + e]))
        .unwrap_or_default()
}

fn og_video_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"property="og:video" content="([^"]+\.m3u8[^"]*)""#).unwrap())
}

/// 详情页 og:video 即 master.m3u8。
fn extract_m3u8(html: &str) -> String {
    match og_video_re().captures(html) {
        Some(cap) => cap[1].to_string(),
        None => String::new(),
    }
}

/// 详情页封面：第一张 `-cover` 上传图（og:image 是 rank-math 的
/// 播放叠加图，不是封面）。
fn detail_cover(html: &str) -> String {
    let marker = "src=\"https://javmit.com/wp-content/uploads/";
    let mut rest = html;
    while let Some(p) = rest.find(marker) {
        let s = p + 5;
        if let Some(e) = rest[s..].find('"') {
            let url = &rest[s..s + e];
            if url.contains("-cover") {
                return url.to_string();
            }
        }
        rest = &rest[p + 1..];
    }
    String::new()
}

fn format_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return String::new();
    }
    let h = seconds / 3600;
    let m = (seconds % 3600) / 60;
    let s = seconds % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn video_duration(html: &str) -> String {
    let marker = "video:duration\" content=\"";
    if let Some(p) = html.find(marker) {
        let s = p + marker.len();
        if let Some(e) = html[s..].find('"') {
            if let Ok(sec) = html[s..s + e].trim().parse::<i64>() {
                return format_duration(sec);
            }
        }
    }
    String::new()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more":!items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page_url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{HOST}/{}/", series_id.trim_matches('/'))
    };
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let mut title = meta_content(&html, "property", "og:title");
    if let Some(i) = title.find(" - JAVMIT") {
        title = title[..i].trim().to_string();
    }
    if title.is_empty() {
        return Err(ApiError::Internal("JAVMIT 未返回影片资料".into()));
    }
    let cover = detail_cover(&html);
    let desc = meta_content(&html, "name", "description");
    let duration = video_duration(&html);
    let mut extra = serde_json::Map::new();
    if !duration.is_empty() {
        extra.insert("duration".to_string(), Value::String(duration.clone()));
    }
    let play_title = truncate(&title, 60);
    Ok(json!({
    "id": page_url,
    "title": title,
    "cover": cover,
    "synopsis": truncate(&desc, 400),
    "extra": extra,
    "episodes": [episode_json(&format!("{play_title}${page_url}"), "正片", &page_url)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") {
        return Ok(json!({
        "url": video_id,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let url = extract_m3u8(&html);
    if url.is_empty() {
        return Err(ApiError::Internal("JAVMIT 详情页未找到播放地址".into()));
    }
    Ok(json!({
    "url": url,
    "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?s={}",
        url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_v_card() {
        let html = r#"<article class="v-card" data-post-id="111146">
<a href="https://javmit.com/jur-918/" class="vc-thumb-wrap" data-rawx-preview-url="https://s2.javmit.com/JUR-918/preview.mp4">
<img width="640" height="360" src="https://javmit.com/wp-content/uploads/2026/11/JUR-918-cover-640x360.jpg" class="vc-thumb-img" alt="JUR-918 (「アンタの奥さん、最高だったよ」3ヶ月で辞めた新入社員の退職届に書かれた想定外のNTR話 生写真とパンティセット)[Download and Stream]" decoding="async" loading="lazy" />
<div class="vc-dur">2h 22m 18s</div>
</a>
</article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://javmit.com/jur-918/");
        assert!(items[0]["title"].as_str().unwrap().starts_with("JUR-918 ("));
        assert!(!items[0]["title"]
            .as_str()
            .unwrap()
            .contains("Download and Stream"));
        assert_eq!(
            items[0]["cover"],
            "https://javmit.com/wp-content/uploads/2026/11/JUR-918-cover-640x360.jpg"
        );
        assert_eq!(items[0]["remark"], "2h 22m 18s");
    }

    #[test]
    fn og_video_and_duration() {
        let html = r#"<meta property="og:video" content="https://s2.javmit.com/GANA-3482-U/master.m3u8" /> <meta property="video:duration" content="4315" />"#;
        assert_eq!(
            extract_m3u8(html),
            "https://s2.javmit.com/GANA-3482-U/master.m3u8"
        );
        assert_eq!(video_duration(html), "1:11:55");
        assert_eq!(format_duration(4315), "1:11:55");
        assert_eq!(format_duration(306), "5:06");
        assert_eq!(format_duration(0), "");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("creampie", 1),
            "https://javmit.com/category/creampie/"
        );
        assert_eq!(
            catalog_url("creampie", 2),
            "https://javmit.com/category/creampie/page/2/"
        );
        assert_eq!(
            catalog_url("subtitles", 3),
            "https://javmit.com/category/subtitles/page/3/"
        );
    }

    #[test]
    fn detail_cover_picks_cover_image() {
        let html = r#"<img src="https://javmit.com/wp-content/uploads/2026/11/GANA-3482-UNCENSORED-cover-javmit.jpg"><img src="https://javmit.com/wp-content/uploads/2026/09/FSBK-026-UNCENSORED-cover-320x180.jpg">"#;
        assert_eq!(
            detail_cover(html),
            "https://javmit.com/wp-content/uploads/2026/11/GANA-3482-UNCENSORED-cover-javmit.jpg"
        );
    }
}
