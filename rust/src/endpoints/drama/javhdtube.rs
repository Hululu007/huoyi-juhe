//! 🔞JAVHDTube：javhdtube.com 的 KVS 风格站（get_file 签名直链）。
//!
//! 与核心已有 javhd（javhd.today）是不同站，key 与域名都不重复。
//! 列表（div.item.th 卡片解析：th-image-link 取 id 与标题、
//! img data-original 取封面截图、th-duration 取时长；24 条/页，
//! 翻页 `路径{N}/`；搜索 `/search/{词}/`）、详情（og 标题封面、
//! JSON-LD 时长、video_url 取流）、取流（详情页 video_url 是带
//! v-acctoken 签名的 get_file 直链，跟随 302 到 privatehost CDN
//! 的 mp4，签名有时效，须现取现用；另有 720p 变体同页）。
//! 验门（2026-11-06 本机出口实测）：/categories/ 页 98 分类（站
//! 内 title 属性错位，显示名按 slug 转写）；big-breasts 分类 p1
//! 24 条、p2 24 条不重合；latest-updates p1/p2 各 24 条不重合；
//! 搜索 blowjob 25 条；详情 video 23226：video_url（480p 签名）
//! 跟随 302 到 nvms14-b.cdn.privatehost.com mp4，Range 206 +
//! ftypisom 魔数；时长 306 秒（PT0H5M06S）。无签名的 get_file
//! 直链回 403，必须用详情页现取的签名地址。
//! 分类与站 /categories/ 页 1:1；翻页 `路径{N}/`。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://javhdtube.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：最新更新 + /categories/ 页验过的 98 分类。
const CATS: &[(&str, &str)] = &[
    ("latest-updates", "最新更新"),
    ("4k", "4K"),
    ("asian", "Asian"),
    ("asian2", "Asian2"),
    ("ass", "Ass"),
    ("ass-licking", "Ass Licking"),
    ("ass-to-mouth", "Ass To Mouth"),
    ("bed-sex", "Bed Sex"),
    ("big-breasts", "Big Breasts"),
    ("big-cock", "Big Cock"),
    ("big-natural-tits", "Big Natural Tits"),
    ("big-tits", "Big Tits"),
    ("bikini", "Bikini"),
    ("blonde", "Blonde"),
    ("blowjob", "Blowjob"),
    ("boyfriend", "Boyfriend"),
    ("brunette", "Brunette"),
    ("brunette2", "Brunette2"),
    ("couple", "Couple"),
    ("cum-in-mouth", "Cum In Mouth"),
    ("cum-in-mouth2", "Cum In Mouth2"),
    ("cum-in-pussy", "Cum In Pussy"),
    ("cum-inside", "Cum Inside"),
    ("cumshot", "Cumshot"),
    ("cunnilingus", "Cunnilingus"),
    ("dirty-talk", "Dirty Talk"),
    ("doggystyle", "Doggystyle"),
    ("double-blowjob", "Double Blowjob"),
    ("exclusive", "Exclusive"),
    ("facial", "Facial"),
    ("facial-cumshot", "Facial Cumshot"),
    ("finger-fuck", "Finger Fuck"),
    ("girlfriend", "Girlfriend"),
    ("hairy", "Hairy"),
    ("hairy-pussy", "Hairy Pussy"),
    ("handjob", "Handjob"),
    ("hardcore", "Hardcore"),
    ("hardcore2", "Hardcore2"),
    ("hd", "HD"),
    ("hot-milf", "Hot Milf"),
    ("individual", "Individual"),
    ("insertions", "Insertions"),
    ("japanese", "Japanese"),
    ("japanese-close-up", "Japanese Close Up"),
    ("japanese2", "Japanese2"),
    ("kissing", "Kissing"),
    ("lesbian", "Lesbian"),
    ("lingerie", "Lingerie"),
    ("lingerie2", "Lingerie2"),
    ("maid", "Maid"),
    ("masturbating", "Masturbating"),
    ("masturbation", "Masturbation"),
    ("mature", "Mature"),
    ("mature-woman", "Mature Woman"),
    ("milf", "Milf"),
    ("mini-skirt", "Mini Skirt"),
    ("missionary", "Missionary"),
    ("mmf", "Mmf"),
    ("natural-boobs", "Natural Boobs"),
    ("natural-tits", "Natural Tits"),
    ("natural-tits2", "Natural Tits2"),
    ("nipple-play", "Nipple Play"),
    ("nurse", "Nurse"),
    ("office-lady", "Office Lady"),
    ("on-her-knees", "On Her Knees"),
    ("open-pussy", "Open Pussy"),
    ("outdoor", "Outdoor"),
    ("panties", "Panties"),
    ("perfect-ass", "Perfect Ass"),
    ("pink-pussy", "Pink Pussy"),
    ("pov", "Pov"),
    ("pussy-licking", "Pussy Licking"),
    ("pussy-to-mouth", "Pussy To Mouth"),
    ("reality", "Reality"),
    ("reverse-cowgirl", "Reverse Cowgirl"),
    ("riding", "Riding"),
    ("schoolgirl-18", "Schoolgirl 18+"),
    ("shaved", "Shaved"),
    ("shaved-pussy", "Shaved Pussy"),
    ("skinny", "Skinny"),
    ("small-cock", "Small Cock"),
    ("small-tits", "Small Tits"),
    ("squirting", "Squirting"),
    ("standing-sex", "Standing Sex"),
    ("stockings", "Stockings"),
    ("sucking", "Sucking"),
    ("talk", "Talk"),
    ("tattoo", "Tattoo"),
    ("teen-18", "Teen 18+"),
    ("thong", "Thong"),
    ("threesome", "Threesome"),
    ("tit-fuck", "Tit Fuck"),
    ("titjob", "Titjob"),
    ("toys", "Toys"),
    ("trimmed-pussy", "Trimmed Pussy"),
    ("undressing", "Undressing"),
    ("vibrator", "Vibrator"),
    ("vr", "VR"),
    ("wet-pussy", "Wet Pussy"),
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
        return Err(ApiError::Internal(format!("JAVHDTube 请求 HTTP {status}")));
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

/// `<div class="item th">` 视频卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"item th\">").skip(1) {
        let end = block.find("<div class=\"item th\">").unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a class=\"th-image-link\" href=\"") {
            Some(p) => {
                let s = p + 31;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        if !href.contains("/video/") {
            continue;
        }
        let id = href.to_string();
        if seen.contains(&id) {
            continue;
        }
        let title = match block.find("title=\"") {
            Some(p) => {
                let s = p + 7;
                block[s..]
                    .find('"')
                    .map(|e| decode_entities(&block[s..s + e]))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        if title.is_empty() {
            continue;
        }
        let cover = match block.find("data-original=\"") {
            Some(p) => {
                let s = p + 15;
                block[s..]
                    .find('"')
                    .map(|e| block[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match block.find("<span class=\"th-duration\">") {
            Some(p) => {
                let s = p + 26;
                block[s..]
                    .find("</span>")
                    .map(|e| block[s..s + e].trim().to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let slug = if category_id.is_empty() {
        "latest-updates"
    } else {
        category_id
    };
    let base = if slug == "latest-updates" {
        format!("{HOST}/latest-updates/")
    } else {
        format!("{HOST}/categories/{slug}/")
    };
    if page <= 1 {
        base
    } else {
        format!("{base}{page}/")
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

/// 详情页 `video_url: 'https://...mp4/?v-acctoken=...'`（480p），
/// 同页另有 `_720p.mp4` 变体。
fn extract_video_url(html: &str) -> String {
    let marker = "video_url: '";
    let Some(p) = html.find(marker) else {
        return String::new();
    };
    let s = p + marker.len();
    match html[s..].find('\'') {
        Some(e) => html[s..s + e].to_string(),
        None => String::new(),
    }
}

fn extract_video_url_720p(html: &str) -> String {
    let marker = "_720p.mp4/?v-acctoken=";
    let Some(p) = html.find(marker) else {
        return String::new();
    };
    let start = html[..p].rfind("https://").unwrap_or(0);
    let rest = &html[start..];
    match rest.find('"') {
        Some(e) => rest[..e].to_string(),
        None => rest.to_string(),
    }
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
    let marker = "duration\" content=\"";
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

/// 跟随跳转拿最终地址（签名直链 302 到 privatehost CDN；同 jable
/// 的 resolve_redirect 写法）。
async fn resolve_redirect(url: &str, referer: &str) -> Option<String> {
    let resp = client()
        .ok()?
        .head(url)
        .header("User-Agent", UA)
        .header("Referer", referer)
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        return Some(final_url);
    }
    let resp = client()
        .ok()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", referer)
        .send()
        .await
        .ok()?;
    let final_url = resp.url().to_string();
    if final_url != url {
        Some(final_url)
    } else {
        None
    }
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
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page_url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{HOST}{}", series_id.trim_start_matches('/'))
    };
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let title = meta_content(&html, "property", "og:title");
    if title.is_empty() {
        return Err(ApiError::Internal("JAVHDTube 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let desc = meta_content(&html, "name", "description");
    let duration = video_duration(&html);
    let mut extra = serde_json::Map::new();
    if !duration.is_empty() {
        extra.insert("duration".to_string(), Value::String(duration));
    }
    let mut episodes: Vec<Value> = Vec::new();
    let url_480p = extract_video_url(&html);
    let url_720p = extract_video_url_720p(&html);
    if !url_720p.is_empty() {
        episodes.push(episode_json(&url_720p, "720p", &page_url));
    }
    if !url_480p.is_empty() {
        episodes.push(episode_json(&url_480p, "正片", &page_url));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&page_url, "正片", &page_url));
    }
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": truncate(&desc, 400),
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let header = json!({"User-Agent": UA, "Referer": format!("{HOST}/")});
    if video_id.contains(".mp4") {
        let mut url = video_id.to_string();
        if let Some(resolved) = resolve_redirect(&url, &format!("{HOST}/")).await {
            if resolved.len() > 20 {
                url = resolved;
            }
        }
        return Ok(json!({"url": url, "header": header}));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let mut url = extract_video_url(&html);
    if url.is_empty() {
        url = extract_video_url_720p(&html);
    }
    if url.is_empty() {
        return Err(ApiError::Internal("JAVHDTube 详情页未找到播放地址".into()));
    }
    if let Some(resolved) = resolve_redirect(&url, &page_url).await {
        if resolved.len() > 20 {
            url = resolved;
        }
    }
    Ok(json!({"url": url, "header": header}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search/{}/",
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
    fn parse_item_card() {
        let html = r#"<div class="item th">
					<div class="th-image">
						<a class="th-image-link" href="https://javhdtube.com/video/151920/yuri-saegusa-celebrates-her-60th-with-a-creamy-surprise-inside4/" title="Yuri Saegusa celebrates her 60th with a creamy surprise inside">
							<img class="lazy-load" data-original="https://javhdtube.com/contents/videos_screenshots/151000/151920/528x396/4.jpg" alt="Yuri Saegusa celebrates her 60th with a creamy surprise inside" />
						</a>
						<span class="th-duration">
							11:54
						</span>
					</div>
					<a class="th-row-title" href="https://javhdtube.com/video/151920/yuri-saegusa-celebrates-her-60th-with-a-creamy-surprise-inside4/" title="Yuri Saegusa celebrates her 60th with a creamy surprise inside">
							Yuri Saegusa celebrates her 60th with a creamy surprise inside
						</a>
					</div>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://javhdtube.com/video/151920/yuri-saegusa-celebrates-her-60th-with-a-creamy-surprise-inside4/"
        );
        assert_eq!(
            items[0]["title"],
            "Yuri Saegusa celebrates her 60th with a creamy surprise inside"
        );
        assert_eq!(
            items[0]["cover"],
            "https://javhdtube.com/contents/videos_screenshots/151000/151920/528x396/4.jpg"
        );
        assert_eq!(items[0]["remark"], "11:54");
    }

    #[test]
    fn video_url_extraction() {
        let html = r#"video_url: 'https://javhdtube.com/get_file/3/e397075b684852d52c75bf8e154f9ae5/23000/23226/23226.mp4/?v-acctoken=MTA1MnwxfDB8NjdlODI3MWI1OTZmM2MzNjNkYmNjNGI1Y2ViNWNhMDYc6908855e63a6932', video_url_text: '480p'"#;
        let url = extract_video_url(html);
        assert!(url.starts_with("https://javhdtube.com/get_file/3/"));
        assert!(url.contains("v-acctoken="));
        assert!(extract_video_url("no player here").is_empty());
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest-updates", 1),
            "https://javhdtube.com/latest-updates/"
        );
        assert_eq!(
            catalog_url("latest-updates", 2),
            "https://javhdtube.com/latest-updates/2/"
        );
        assert_eq!(
            catalog_url("big-breasts", 1),
            "https://javhdtube.com/categories/big-breasts/"
        );
        assert_eq!(
            catalog_url("big-breasts", 2),
            "https://javhdtube.com/categories/big-breasts/2/"
        );
    }

    #[test]
    fn duration_formats() {
        assert_eq!(format_duration(306), "5:06");
        assert_eq!(format_duration(4315), "1:11:55");
    }
}
