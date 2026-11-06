//! A色TV（asextv.xyz）：Next.js 站，3 个资源库（大奶子/极品/红楼）。
//! 列表与详情走 HTML 解析；m3u8 地址直接写在详情页里。
//! 实测 4518029：m3u8 200、328 分片、660.27 秒；无加密；
//! 分片为相对路径（相对 m3u8 host 解析）；首分片 200 + 0x47。
//! 注意：站内不显示时长，无法做时长对表；m3u8 host 带 52866
//! 端口，只认 https，http 会断连；首次拉取曾遇 IncompleteRead，
//! 失败时重试一次。
//! 分类与站导航 1:1，共 116 个（`/category/<库>/<id>`，库 1 大奶子、
//! 2 极品、3 红楼；分类名在三库间有重复，id 用完整路径，不冲突）；
//! 分类列表 `?page=N`；搜索 `/search?q=...`。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://asextv.xyz";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：首页导航 116 个，id 为 `<库>/<id>` 完整路径，
/// 显示名加库名前缀区分三库同名分类。
const CATS: &[(&str, &str)] = &[
    ("1/20", "大奶子·精品推荐"),
    ("1/21", "大奶子·国产主播"),
    ("1/22", "大奶子·国产乱伦"),
    ("1/23", "大奶子·自拍偷拍"),
    ("1/24", "大奶子·制服丝袜"),
    ("1/25", "大奶子·网曝事件"),
    ("1/26", "大奶子·传媒探花"),
    ("1/27", "大奶子·清纯学生"),
    ("1/28", "大奶子·A V 解说"),
    ("1/29", "大奶子·淫妻作乐"),
    ("1/30", "大奶子·港台辣妹"),
    ("1/31", "大奶子·足浴撩妹"),
    ("1/32", "大奶子·反差母狗"),
    ("1/33", "大奶子·A I 换脸"),
    ("1/34", "大奶子·V R 视角"),
    ("1/35", "大奶子·重口性癖"),
    ("1/36", "大奶子·制服诱惑"),
    ("1/37", "大奶子·丝袜美腿"),
    ("1/38", "大奶子·中文字幕"),
    ("1/39", "大奶子·无码流出"),
    ("1/40", "大奶子·多人群交"),
    ("1/41", "大奶子·凌辱快感"),
    ("1/42", "大奶子·角色剧情"),
    ("1/43", "大奶子·强奸乱伦"),
    ("1/44", "大奶子·韩国三级"),
    ("1/45", "大奶子·欧美激情"),
    ("1/46", "大奶子·人妻熟女"),
    ("1/47", "大奶子·主奴调教"),
    ("1/48", "大奶子·动漫卡通"),
    ("1/49", "大奶子·变性伪娘"),
    ("1/50", "大奶子·女同性恋"),
    ("1/51", "大奶子·野外露出"),
    ("2/54", "极品·日韩无码"),
    ("2/55", "极品·国产精品"),
    ("2/57", "极品·日韩精品"),
    ("2/58", "极品·欧美精品"),
    ("2/59", "极品·动漫精品"),
    ("2/60", "极品·自拍偷拍"),
    ("2/61", "极品·伦理影片"),
    ("2/62", "极品·中文字幕"),
    ("2/63", "极品·人妻系列"),
    ("2/64", "极品·制服诱惑"),
    ("2/65", "极品·强奸乱伦"),
    ("2/66", "极品·AV明星"),
    ("2/68", "极品·SM重味"),
    ("2/70", "极品·巨乳系列"),
    ("2/71", "极品·颜射系列"),
    ("2/72", "极品·口交视频"),
    ("2/73", "极品·自慰系列"),
    ("2/74", "极品·教师学生"),
    ("2/75", "极品·大秀视频"),
    ("2/76", "极品·明星换脸"),
    ("2/78", "极品·AV解说"),
    ("2/80", "极品·黑料网曝"),
    ("2/81", "极品·精品探花"),
    ("2/82", "极品·精品网红"),
    ("2/83", "极品·反差母狗"),
    ("2/84", "极品·颜值正义"),
    ("2/85", "极品·熟女少妇"),
    ("2/86", "极品·人兽乱交"),
    ("2/89", "极品·国产传媒"),
    ("2/90", "极品·野战车震"),
    ("2/91", "极品·SM调教"),
    ("2/92", "极品·家庭乱伦"),
    ("2/93", "极品·百合女同"),
    ("2/94", "极品·学生空姐"),
    ("2/95", "极品·撸管必看"),
    ("2/97", "极品·偷情少妇"),
    ("3/21", "红楼·原创乱伦"),
    ("3/22", "红楼·鬼父操女"),
    ("3/23", "红楼·中文字幕"),
    ("3/24", "红楼·制服诱惑"),
    ("3/25", "红楼·嫂子诱惑"),
    ("3/26", "红楼·姐夫小姨子"),
    ("3/27", "红楼·兄弟姐妹"),
    ("3/28", "红楼·风韵岳母"),
    ("3/32", "红楼·吃瓜黑料"),
    ("3/33", "红楼·酒店探花"),
    ("3/34", "红楼·儿媳献穴"),
    ("3/35", "红楼·SM调教"),
    ("3/36", "红楼·师生迷情"),
    ("3/37", "红楼·AI换脸"),
    ("3/38", "红楼·国产主播"),
    ("3/39", "红楼·AV解说"),
    ("3/40", "红楼·家族淫趴"),
    ("3/41", "红楼·淫母兽儿"),
    ("3/42", "红楼·近亲相奸"),
    ("3/59", "红楼·欧美劲爆"),
    ("3/60", "红楼·SM重味"),
    ("3/61", "红楼·伦理影片"),
    ("3/64", "红楼·日韩无码"),
    ("3/65", "红楼·强奸乱伦"),
    ("3/66", "红楼·强奸迷奸"),
    ("3/67", "红楼·野战车震"),
    ("3/68", "红楼·熟女少妇"),
    ("3/69", "红楼·反差母狗"),
    ("3/70", "红楼·巨乳尤物"),
    ("3/71", "红楼·人妻巨乳"),
    ("3/72", "红楼·站长推荐"),
    ("3/73", "红楼·自拍偷拍"),
    ("3/74", "红楼·教师学生"),
    ("3/75", "红楼·3D动漫"),
    ("3/76", "红楼·人妻系列"),
    ("3/77", "红楼·日韩精品"),
    ("3/78", "红楼·撸管必看"),
    ("3/79", "红楼·短视频"),
    ("3/80", "红楼·兄妹姐弟"),
    ("3/81", "红楼·叔嫂乱伦"),
    ("3/82", "红楼·姐夫小姨"),
    ("3/83", "红楼·家庭乱伦"),
    ("3/84", "红楼·母子乱伦"),
    ("3/87", "红楼·母子乱伦"),
    ("3/88", "红楼·母子乱伦"),
    ("3/89", "红楼·母子乱伦"),
    ("3/90", "红楼·国产传媒"),
    ("3/91", "红楼·直播裸聊"),
];

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https://[^\s"\\]+\.m3u8"#).unwrap())
}

async fn fetch(url: &str, referer: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", referer);
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("A色TV 请求 HTTP {status}")));
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

/// `<a class="movie-card" href="/video/<id>">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a class=\"movie-card\"").skip(1) {
        let end = block.find("<a class=\"movie-card\"").unwrap_or(block.len());
        let block = &block[..end];
        let Some(hp) = block.find("href=\"/video/") else {
            continue;
        };
        let s = hp + 13;
        let Some(e) = block[s..].find('"') else {
            continue;
        };
        let vid = &block[s..s + e];
        if vid.is_empty() || !vid.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let id = format!("{HOST}/video/{vid}");
        if seen.contains(&id) {
            continue;
        }
        // 标题：h3，兜底 img alt。
        let mut title = String::new();
        if let Some(p) = block.find("<h3") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</h3>") {
                    title = decode_entities(after[s..s + e].trim());
                }
            }
        }
        // 封面：/covers/...jpg（相对路径）。
        let mut cover = String::new();
        if let Some(p) = block.find("<img ") {
            let img = &block[p..];
            if let Some(s) = img.find("src=\"") {
                let s = s + 5;
                if let Some(e) = img[s..].find('"') {
                    let src = &img[s..s + e];
                    cover = if src.starts_with("http") {
                        src.to_string()
                    } else {
                        format!("{HOST}{src}")
                    };
                }
            }
            if title.is_empty() {
                if let Some(s) = img.find("alt=\"") {
                    let s = s + 5;
                    if let Some(e) = img[s..].find('"') {
                        title = decode_entities(&img[s..s + e]);
                    }
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        // 备注：caption（分类+库名），如“精品推荐 · 大奶子资源”。
        let mut remark = String::new();
        if let Some(p) = block.find("movie-caption") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</") {
                    remark = decode_entities(after[s..s + e].trim());
                }
            }
        }
        seen.push(id.clone());
        items.push(item_json(&id, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let base = format!("{HOST}/category/{category_id}");
    if page <= 1 {
        base
    } else {
        format!("{base}?page={page}")
    }
}

fn tag_title(html: &str) -> String {
    let Some(p) = html.find("<title>") else {
        return String::new();
    };
    let s = p + 7;
    let e = html[s..]
        .find("</title>")
        .map(|i| s + i)
        .unwrap_or(html.len());
    let t = decode_entities(&html[s..e]);
    for sep in [" - A-SEX-TV", " - A色TV"] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

/// 详情页第一个封面图（/covers/...）。
fn detail_cover(html: &str) -> String {
    let Some(p) = html.find("/covers/") else {
        return String::new();
    };
    let start = html[..p].rfind('"').map(|i| i + 1).unwrap_or(p);
    let rest = &html[start..];
    let end = rest
        .find(|c: char| c == '"' || c == '\'' || c == ' ')
        .unwrap_or(rest.len());
    let src = &rest[..end];
    if src.starts_with("http") {
        src.to_string()
    } else if src.starts_with("/covers/") {
        format!("{HOST}{src}")
    } else {
        String::new()
    }
}

/// 详情页里的 m3u8 直链。
fn extract_m3u8(html: &str) -> Option<String> {
    m3u8_re().find(html).map(|m| m.as_str().to_string())
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
    let html = fetch(series_id, &format!("{HOST}/")).await?;
    let title = tag_title(&html);
    if title.is_empty() {
        return Err(ApiError::Internal("A色TV 未返回影片资料".into()));
    }
    let cover = detail_cover(&html);
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": {},
        "episodes": [episode_json(&format!("{play_title}${series_id}"), "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url, &format!("{HOST}/")).await?;
    let url =
        extract_m3u8(&html).ok_or_else(|| ApiError::Internal("A色TV 详情页未找到 m3u8".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_movie_card() {
        let html = r#"<a class="movie-card" href="/video/4518029"><div class="movie-poster"><img src="/covers/87/72/8772f9ee437fbfe8733b6e3dc3cf15ca9046a02c6d9a9941c006bb35c3e2d232.jpg" alt="白.虎女大学生这么大屌....B都塞满了....白浆射这么多....必看" loading="lazy" referrerPolicy="no-referrer"/><span class="movie-lines">1<!-- --> 条线路</span></div><h3>白.虎女大学生这么大屌....B都塞满了....白浆射这么多....必看</h3><p class="movie-caption">精品推荐 · 大奶子资源</p></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://asextv.xyz/video/4518029");
        assert_eq!(
            items[0]["title"],
            "白.虎女大学生这么大屌....B都塞满了....白浆射这么多....必看"
        );
        assert_eq!(
            items[0]["cover"],
            "https://asextv.xyz/covers/87/72/8772f9ee437fbfe8733b6e3dc3cf15ca9046a02c6d9a9941c006bb35c3e2d232.jpg"
        );
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("1/20", 1), "https://asextv.xyz/category/1/20");
        assert_eq!(
            catalog_url("1/20", 2),
            "https://asextv.xyz/category/1/20?page=2"
        );
        assert_eq!(catalog_url("3/79", 1), "https://asextv.xyz/category/3/79");
    }

    #[test]
    fn extract_m3u8_real() {
        let html = r#"{"url":"https://voddadaizi5.com:52866/videos/202611/04/6aeb0aafe5c043d50491e89d/cg3bc0/index.m3u8"}"#;
        assert_eq!(
            extract_m3u8(html).unwrap(),
            "https://voddadaizi5.com:52866/videos/202611/04/6aeb0aafe5c043d50491e89d/cg3bc0/index.m3u8"
        );
        assert!(extract_m3u8("no stream here").is_none());
    }

    #[test]
    fn tag_title_strips_suffix() {
        let html =
            "<title>白.虎女大学生这么大屌....B都塞满了....白浆射这么多....必看 - A-SEX-TV</title>";
        assert_eq!(
            tag_title(html),
            "白.虎女大学生这么大屌....B都塞满了....白浆射这么多....必看"
        );
    }

    #[test]
    fn categories_count_matches_nav() {
        assert_eq!(CATS.len(), 116);
    }
}
