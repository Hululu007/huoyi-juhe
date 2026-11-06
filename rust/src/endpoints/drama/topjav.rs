//! TopJAV（topjav.tv）：JAV 视频站，列表与详情走 HTML 解析。
//! 取流：详情页 jwplayer 的 `file: f("...")` 是混淆串，解码为
//! `https://topjav.tv/m3u8/{id}.m3u8?time=...&sig=...&sig2=...`，
//! 现取现解（sig 含时间戳，有效期短）。解码算法（Node 实跑两页确认）：
//! payload 去头 16 字符、去尾 16 字符、字符反转、标准 base64 解码。
//! 实测 SNOS-334（id 110330）：m3u8 200、2394 分片、9575.6 秒，
//! 与卡片时长 02:39:36 精确对上；首分片 200 + TS 魔数 0x47。
//! 注意：分片 CDN（stream-*-cdn.b-cdn.net）有 Bunny Shield，
//! plain curl 取分片回 403，Chrome 模拟可取；Rust reqwest 的
//! TLS 指纹能否通过未验证，手机端 ExoPlayer 须复验。
//! 分类与站导航 1:1（人気/修正/無修正/モザイク破壊 + 热门ジャンル）；
//! 索引路由 /genre/{slug}、/pornstar/{slug}、/makers/{slug}，
//! 翻页 `?page=N`；搜索 `/search?s=...`。

use base64::Engine;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://topjav.tv";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：首页 4 分区 + /genres 页验过的热门ジャンル。
const CATS: &[(&str, &str)] = &[
    ("popular", "人気"),
    ("censored", "修正"),
    ("uncensored", "無修正"),
    ("reducing_mosaic", "モザイク破壊"),
    ("genre:solowork", "単体作品"),
    ("genre:busty", "巨乳"),
    ("genre:creampie", "中出し"),
    ("genre:cosplay", "コスプレ"),
    ("genre:teen", "ティーン"),
    ("genre:debut", "デビュー"),
    ("genre:massage", "マッサージ"),
    ("genre:blowjob", "フェラ"),
    ("genre:anal", "アナル"),
    ("genre:lesbian", "レズビアン"),
    ("genre:maid", "メイド"),
    ("genre:virgin", "処女"),
];

fn payload_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"file: f\("([^"]+)"\)"#).unwrap())
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
        return Err(ApiError::Internal(format!("TopJAV 请求 HTTP {status}")));
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

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ => {
                if !in_tag {
                    out.push(c);
                }
            }
        }
    }
    decode_entities(&out)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}

/// 混淆串解码：去头 16 字符、去尾 16 字符、字符反转、标准 base64。
/// 结果须是本站 m3u8 地址才算解出，否则返回 None（站改算法时
/// 报错而不是返回错地址）。
fn decode_stream_url(payload: &str) -> Option<String> {
    let chars: Vec<char> = payload.chars().collect();
    if chars.len() <= 32 {
        return None;
    }
    let inner: String = chars[16..chars.len() - 16].iter().collect();
    let reversed: String = inner.chars().rev().collect();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(reversed.as_bytes())
        .ok()?;
    let url = String::from_utf8(bytes).ok()?;
    if url.starts_with("https://topjav.tv/m3u8/") {
        Some(url)
    } else {
        None
    }
}

fn extract_payload(html: &str) -> Option<String> {
    let cap = payload_re().captures(html)?;
    Some(cap[1].to_string())
}

/// `<article class="movie-item">` 卡片解析。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article class=\"movie-item\">").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let href = match block.find("<a href=\"https://topjav.tv/video/") {
            Some(p) => {
                let s = p + 9;
                match block[s..].find('"') {
                    Some(e) => &block[s..s + e],
                    None => continue,
                }
            }
            None => continue,
        };
        let id = href.to_string();
        if seen.contains(&id) {
            continue;
        }
        let title = if let Some(p) = block.find("<h3") {
            let after = &block[p..];
            match after.find('>') {
                Some(gt) => {
                    let s = gt + 1;
                    after[s..]
                        .find("</h3>")
                        .map(|e| decode_entities(after[s..s + e].trim()))
                        .unwrap_or_default()
                }
                None => String::new(),
            }
        } else {
            String::new()
        };
        let title = if title.is_empty() {
            // main-image 的 alt 兜底（background-sample-image 的 alt 是 background，要跳过）。
            match block.find("class=\"main-image\"") {
                Some(p) => {
                    let after = &block[p..];
                    match after.find("alt=\"") {
                        Some(a) => {
                            let s = a + 5;
                            after[s..]
                                .find('"')
                                .map(|e| decode_entities(&after[s..s + e]))
                                .unwrap_or_default()
                        }
                        None => String::new(),
                    }
                }
                None => String::new(),
            }
        } else {
            title
        };
        if title.is_empty() {
            continue;
        }
        let cover = match block.find("class=\"main-image\"") {
            Some(p) => {
                let after = &block[p..];
                match after.find("src=\"") {
                    Some(a) => {
                        let s = a + 5;
                        after[s..]
                            .find('"')
                            .map(|e| after[s..s + e].to_string())
                            .unwrap_or_default()
                    }
                    None => String::new(),
                }
            }
            None => String::new(),
        };
        let remark = match block.find("<div class=\"duration\">") {
            Some(p) => {
                let s = p + 22;
                block[s..]
                    .find("</div>")
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
    let with_page = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}?page={page}")
        }
    };
    match category_id {
        "popular" => with_page(format!("{HOST}/popular")),
        "censored" | "uncensored" | "reducing_mosaic" => {
            with_page(format!("{HOST}/categories/{category_id}"))
        }
        _ => {
            if let Some(v) = category_id.strip_prefix("genre:") {
                with_page(format!("{HOST}/genre/{v}"))
            } else if let Some(v) = category_id.strip_prefix("pornstar:") {
                with_page(format!("{HOST}/pornstar/{v}"))
            } else if let Some(v) = category_id.strip_prefix("makers:") {
                with_page(format!("{HOST}/makers/{v}"))
            } else {
                with_page(format!("{HOST}/popular"))
            }
        }
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
    for sep in ["　ー　", " — ", " | ", " - "] {
        if let Some((head, _)) = t.rsplit_once(sep) {
            return head.trim().to_string();
        }
    }
    t
}

/// 详情信息区链接文本：`<a href="https://topjav.tv/{kind}/...">NAME</a>`，
/// NAME 里常带换行与空格，先去标签再 trim。站内导航用复数路径
///（/genres、/pornstars、/makers），不会误命中。
fn info_links(html: &str, kind: &str) -> Vec<String> {
    let marker = format!("href=\"{HOST}/{kind}/");
    let mut out: Vec<String> = Vec::new();
    let mut rest = html;
    while let Some(p) = rest.find(&marker) {
        let after = &rest[p..];
        if let Some(gt) = after.find('>') {
            let s = gt + 1;
            if let Some(e) = after[s..].find("</a>") {
                let name = strip_tags(&after[s..s + e]);
                if !name.is_empty() && !out.contains(&name) {
                    out.push(name);
                }
            }
        }
        rest = &rest[p + 1..];
        if out.len() >= 8 {
            break;
        }
    }
    out
}

fn json_ld_field(html: &str, key: &str) -> String {
    let marker = format!("\"{key}\":");
    let Some(p) = html.find(&marker) else {
        return String::new();
    };
    let mut rest = html[p + marker.len()..].trim_start();
    if !rest.starts_with('"') {
        return String::new();
    }
    rest = &rest[1..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('u') => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Ok(n) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(n) {
                            out.push(ch);
                        }
                    }
                }
                Some(e) => out.push(e),
                None => break,
            },
            '"' => break,
            _ => out.push(c),
        }
    }
    out
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
        return Err(ApiError::Internal("TopJAV 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let mut desc = json_ld_field(&html, "description");
    let actresses = info_links(&html, "pornstar");
    let makers = info_links(&html, "makers");
    let genres = info_links(&html, "genre");
    let published = json_ld_field(&html, "datePublished");
    let mut lines: Vec<String> = Vec::new();
    if !actresses.is_empty() {
        lines.push(format!("女優：{}", actresses.join("、")));
    }
    if !makers.is_empty() {
        lines.push(format!("メーカー：{}", makers.join("、")));
    }
    if !genres.is_empty() {
        lines.push(format!("ジャンル：{}", genres.join("、")));
    }
    if !published.is_empty() {
        lines.push(format!("发布：{}", &published[..published.len().min(10)]));
    }
    if !lines.is_empty() {
        if !desc.is_empty() {
            desc.push('\n');
        }
        desc.push_str(&lines.join("\n"));
    }
    let desc = truncate(&desc, 400);
    let play_title = truncate(&title, 60);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
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
    let payload = extract_payload(&html)
        .ok_or_else(|| ApiError::Internal("TopJAV 详情页未找到混淆播放串".into()))?;
    let url = decode_stream_url(&payload)
        .ok_or_else(|| ApiError::Internal("TopJAV 播放串解码失败（站可能改了算法）".into()))?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/search?s={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 两条真实 payload（同一视频 110330，不同时间取的），Node 实跑解出。
    const PAYLOAD_A: &str = "iFR4xfvyrJ4751C02p2a0hVW2w2bVNHMCV2TX1jMnl2cmUWNkV2Y1YzYhVGM5UDOlNGNiNGN5MjM3IWOjZ2N4EGZwQDOkNjZlVzNzcTMiR2M5MGMhZjYzUGNmJWZ1QGMwQTPnl2cmQDNxcjM5MTO3ETPl1Wa09DO1NTbuAzMzATMx8CO1NTbvYHduYXYqB3b09yL6MHc0RHaZXDdukCUdDIywtHl";
    const PAYLOAD_B: &str = "l7LiGzOKn3KUU2SmS1UWwc1cNpGevBDR0I2cv1jMnl2cmE2N5M2MiZWMjFGOjVGZyMDNyImNkNzM4gjZhVmZiZmMmZTM0IDZiBjYjhTZyQjZzYmM1IjZ2cTO2UmMyITMiZWPnl2cmcDN5YjM5MTO3ETPl1Wa09DO1NTbuAzMzATMx8CO1NTbvYHduYXYqB3b09yL6MHc0RHajirn9enWqUCkDNUS";

    #[test]
    fn decode_payload_known_pair_a() {
        assert_eq!(
            decode_stream_url(PAYLOAD_A).unwrap(),
            "https://topjav.tv/m3u8/110330.m3u8?time=1793927144&sig=400d5ebf4e3b6a0c93db17375ef3d840da87fc9b72394cb4ce8590eac65ced5e&sig2=WOeB0sUol6YXtkjv"
        );
    }

    #[test]
    fn decode_payload_known_pair_b() {
        assert_eq!(
            decode_stream_url(PAYLOAD_B).unwrap(),
            "https://topjav.tv/m3u8/110330.m3u8?time=1793926947&sig=fb1222e6976f252f3f42e8cb0bd2416f2fbfeaf8833d6b2432dec8ac1fb3c97a&sig2=osb4D0oxjMsW0YMR"
        );
    }

    #[test]
    fn decode_payload_garbage() {
        assert!(decode_stream_url("short").is_none());
        assert!(decode_stream_url("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").is_none());
    }

    #[test]
    fn extract_payload_from_detail() {
        let html = r#"jwplayer("media-player"); playerInstance.setup({ file: f("iFR4xfvyrJ4751C02p2a0hVW2w2bVNHMCV2TX1jMnl2cmUWNkV2Y1YzYhVGM5UDOlNGNiNGN5MjM3IWOjZ2N4EGZwQDOkNjZlVzNzcTMiR2M5MGMhZjYzUGNmJWZ1QGMwQTPnl2cmQDNxcjM5MTO3ETPl1Wa09DO1NTbuAzMzATMx8CO1NTbvYHduYXYqB3b09yL6MHc0RHaZXDdukCUdDIywtHl"), width: '100%' });"#;
        assert_eq!(extract_payload(html).unwrap(), PAYLOAD_A);
    }

    #[test]
    fn parse_movie_card() {
        let html = r#"<article class="movie-item">
        <a href="https://topjav.tv/video/113411">
            <div class="thumbnail-container">
                <div class="movie-image thumb">
                    <div class="movie-link">
                        <img class="background-sample-image" src="data:image/png;base64,xxx" alt="background">
                        <img class="main-image" src="https://topjav.tv/storage/images/113411/thumbnail.jpg" alt="IDPC-001-REDUCING-MOSAIC 大原伶菜">
                    </div>
                    <div class="duration">02:33:49</div>
                </div>
            </div>
            <div class="movie-name">
                <h3 class="movie-link">IDPC-001-REDUCING-MOSAIC 大原伶菜</h3>
            </div>
            <div class="movie-meta">
                <span class="date">5日前</span>
            </div>
        </a>
    </article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "https://topjav.tv/video/113411");
        assert_eq!(items[0]["title"], "IDPC-001-REDUCING-MOSAIC 大原伶菜");
        assert_eq!(
            items[0]["cover"],
            "https://topjav.tv/storage/images/113411/thumbnail.jpg"
        );
        assert_eq!(items[0]["remark"], "02:33:49");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(catalog_url("popular", 1), "https://topjav.tv/popular");
        assert_eq!(
            catalog_url("popular", 2),
            "https://topjav.tv/popular?page=2"
        );
        assert_eq!(
            catalog_url("censored", 1),
            "https://topjav.tv/categories/censored"
        );
        assert_eq!(
            catalog_url("genre:solowork", 3),
            "https://topjav.tv/genre/solowork?page=3"
        );
        assert_eq!(
            catalog_url("pornstar:seto-kanna", 1),
            "https://topjav.tv/pornstar/seto-kanna"
        );
        assert_eq!(
            catalog_url("makers:sod-create", 2),
            "https://topjav.tv/makers/sod-create?page=2"
        );
    }

    #[test]
    fn tag_title_strips_site_name() {
        let html = "<title>SNOS-334-REDUCING-MOSAIC 瀬戸環奈　ー　TopJAV</title>";
        assert_eq!(tag_title(html), "SNOS-334-REDUCING-MOSAIC 瀬戸環奈");
    }

    #[test]
    fn info_links_actress() {
        let html = r#"<span class="info-data">女優:</span> <a href="https://topjav.tv/pornstar/seto-kanna" class="btn btn-outline-secondary btn-sm mb-1"> 瀬戸環奈 </a>"#;
        assert_eq!(info_links(html, "pornstar"), vec!["瀬戸環奈"]);
        assert!(info_links(html, "makers").is_empty());
    }
}
