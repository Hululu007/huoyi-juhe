//! 🔞短剧one：duanju.one，AI 短剧资源站（Laravel + Vite，永久主站
//! duanju.one），独立站，不与黄果系 / 黄豆系 / 野果任一站合并。
//!
//! 去重实测（2026-11-06）：
//! - 本站自有后端与自有存储：列表 /drama/<slug>、详情同路径、
//!   播放 /player/drama/<slug>/ep/<n>（JSON），流为 cdn.duanju.one
//!   的 mp4 直链（Backblaze B2 桶）；黄果TV 走 media.huangguotv.com
//!   的 HLS（/video/<id>）、hgtv.im 是 theme4 模板站（/drama/<id>.html、
//!   /watch/<id>_<ep>.html、封面 img.mfantasy.net / img.689.mx）、
//!   野果是 PWA AES 接口（analyze.buxefaex.cc），三者后端、域名、
//!   存储、URL 形态全不同，不存在换域名关系。
//! - 同名只是撞题：《有五个姐姐的我》野果也有，但野果走 PWA 接口，
//!   本站走自有 B2；《琼明神女录》本站内豆版与黄果版是两个独立条目，
//!   实测第 1 集不是同一条流：豆版 QiongMingShenNvLu-Dou/ep-001.mp4
//!   130782636 字节、时长 388.567 秒，黄果版 QiongMingShenNvLu-fix/
//!   ep-001.mp4 413151994 字节、时长 1646.124 秒，是两份不同编码，
//!   两条目都保留、不合并、不去重。
//! - 部数：全部 197 部（9 页，24×8+5）、免费 184 部（8 页，
//!   24×7+16）、VIP / 积分 13 部（1 页）、已完结 38 部（2 页，
//!   24+14），免费 + VIP = 197 自洽。
//!
//! 取流（VIP 墙实测，未找到匿名绕道）：
//! - 免费集：分集页 / 播放 JSON 均直接给 src，
//!   https://cdn.duanju.one/<年>/<月>/<目录>/ep-NNN.mp4?v=<B2 文件 id>；
//!   裸路径（去掉 ?v=）同样 200：少妇白洁高画质版 ep-002（Range 206，
//!   ftyp isom/mp41、moov 在前，时长 177.3 秒，全长非预告）、
//!   有五个姐姐的我 ep-005、琼明神女录豆版 / 黄果版 ep-001 均验过。
//!   play() 回裸路径，不怕签名过期。
//! - 付费集：分集页不渲染 <video>，只留“第 N 集需要观看权益”锁屏；
//!   /player JSON 回 canWatch:false、src:null；裸路径猜测
//!   ep-011.mp4 回 B2 404（与不存在的 ep-999.mp4 同款报文），借别集
//!   的 v 参数也 404；/player/.../ep/11/next 404；贴板无流链接；
//!   注册只留邮箱、无邀请码，但 VIP / 积分购买须登录后付费，
//!   未测登录后路径。play() 对付费集如实报错，不编地址。
//! - 请求不要带饼干：本站回 one-session + XSRF-TOKEN 会话饼干后，
//!   同一会话的后续请求会在服务端挂起直至超时（本机实测：带饼干
//!   的第 3 个请求起连续读超时，不带饼干则连续 6 个请求各 3~4 秒
//!   全通）；本站匿名取数完全不需要饼干，py 与 Rust 一律不用
//!   CookieJar、不发 Cookie 头。
//! - 选集行同时标免费 / 付费（episode-free / episode-paid），
//!   付费集在播放列表标题里标“·VIP”，点之前就能看见。

use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, str_of, text_of};

const HOST: &str = "https://duanju.one";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 24;

/// 4 个一级分类：站内筛选 1:1（全部 / 免费 / VIP / 积分 / 已完结）。
const CATS: &[(&str, &str)] = &[
    ("all", "全部"),
    ("free", "免费"),
    ("vip", "VIP / 积分"),
    ("completed", "已完结"),
];

fn card_href_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"href="https?://duanju\.one/drama/([^"]+)""#).unwrap())
}

fn img_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<img[^>]*src="([^"]+)""#).unwrap())
}

fn ep_anchor_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<a class="([^"]*)" href="[^"]*/ep/(\d+)"[^>]*aria-label="([^"]*)""#).unwrap()
    })
}

async fn fetch_html(url: &str) -> ApiResult<String> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("短剧one请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

async fn fetch_json(url: &str) -> ApiResult<Value> {
    let req = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "application/json")
        .header("Referer", format!("{HOST}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("短剧one播放请求 HTTP {status}")));
    }
    resp.json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
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
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn attr(block: &str, name: &str) -> String {
    let marker = format!("{name}=\"");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    block[s..]
        .find('"')
        .map(|e| block[s..s + e].to_string())
        .unwrap_or_default()
}

fn tag_text(block: &str, tag: &str) -> String {
    let open = format!("<{tag}");
    let Some(p) = block.find(&open) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let close = format!("</{tag}>");
    let e = after[s..].find(&close).unwrap_or(after.len() - s);
    strip_tags(&after[s..s + e])
}

fn span_text(block: &str, class: &str) -> String {
    // class 后可跟修饰词（如 class="badge partial"），按前缀匹配。
    let marker = format!("class=\"{class}");
    let Some(p) = block.find(&marker) else {
        return String::new();
    };
    let after = &block[p..];
    let s = after.find('>').map(|i| i + 1).unwrap_or(0);
    let e = after[s..].find('<').map(|i| s + i).unwrap_or(after.len());
    strip_tags(&after[s..e])
}

/// `<a class="drama-card">` 卡片解析：标题取 h2，封面取 img src，
/// 备注取徽标 + 集数 + 更新时间 + 标签。首页含精选区重复卡片，
/// 按 slug 去重，保留第一次出现。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a class=\"drama-card\"").skip(1) {
        let end = block.find("</a>").unwrap_or(block.len());
        let block = &block[..end];
        let Some(cap) = card_href_re().captures(block) else {
            continue;
        };
        let id = cap[1].to_string();
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let title = tag_text(block, "h2");
        if title.is_empty() {
            continue;
        }
        let cover = img_re()
            .captures(block)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let mut bits: Vec<String> = Vec::new();
        let badge = span_text(block, "badge");
        if !badge.is_empty() {
            bits.push(badge);
        }
        let count = span_text(block, "episode-count");
        if !count.is_empty() {
            bits.push(count);
        }
        let updated = tag_text(block, "p");
        if !updated.is_empty() {
            bits.push(updated);
        }
        if let Some(p) = block.find("class=\"card-tags\"") {
            let after = &block[p..];
            let mut tags: Vec<String> = Vec::new();
            for seg in after.split("<span>").skip(1) {
                if let Some(e) = seg.find("</span>") {
                    let t = strip_tags(&seg[..e]);
                    if !t.is_empty() {
                        tags.push(t);
                    }
                }
            }
            if !tags.is_empty() {
                bits.push(tags.join(" / "));
            }
        }
        items.push(item_json(&id, &title, &cover, &bits.join(" · ")));
    }
    items
}

fn poster_of(html: &str) -> String {
    if let Some(p) = html.find("<video") {
        let after = &html[p..];
        let v = attr(after, "poster");
        if !v.is_empty() {
            return v;
        }
    }
    let marker = "property=\"og:image\"";
    if let Some(p) = html.find(marker) {
        let after = &html[p..];
        if let Some(c) = after.find("content=\"") {
            let s = c + 9;
            if let Some(e) = after[s..].find('"') {
                return after[s..s + e].to_string();
            }
        }
    }
    String::new()
}

fn desc_of(html: &str) -> String {
    let Some(p) = html.find("class=\"drama-description-content\"") else {
        return String::new();
    };
    let after = &html[p..];
    let end = after.find("</div>").unwrap_or(after.len());
    let seg = &after[..end];
    let mut paras: Vec<String> = Vec::new();
    for chunk in seg.split("<p>").skip(1) {
        if let Some(e) = chunk.find("</p>") {
            let t = strip_tags(&chunk[..e]);
            if !t.is_empty() {
                paras.push(t);
            }
        }
    }
    paras.join("\n")
}

fn tags_of(html: &str) -> Vec<String> {
    let Some(p) = html.find("class=\"series-tags\"") else {
        return Vec::new();
    };
    let after = &html[p..];
    let end = after.find("</div>").unwrap_or(after.len());
    let seg = &after[..end];
    let mut tags: Vec<String> = Vec::new();
    for chunk in seg.split("<a ").skip(1) {
        if let Some(s) = chunk.find('>') {
            if let Some(e) = chunk[s + 1..].find('<') {
                let t = strip_tags(&chunk[s + 1..s + 1 + e]);
                if !t.is_empty() {
                    tags.push(t);
                }
            }
        }
    }
    tags
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let base = match category_id {
        "free" => format!("{HOST}/?filter=free"),
        "vip" => format!("{HOST}/?filter=vip"),
        "completed" => format!("{HOST}/?filter=completed"),
        _ => format!("{HOST}/"),
    };
    if page <= 1 {
        return base;
    }
    if base.contains('?') {
        format!("{base}&page={page}")
    } else {
        format!("{base}?page={page}")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    for (id, name) in CATS {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let url = catalog_url(category_id, page);
    let html = fetch_html(&url).await?;
    let items = parse_cards(&html);
    let has_more = items.len() >= PAGE_SIZE as usize;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = format!("{HOST}/drama/{series_id}");
    let html = fetch_html(&url).await?;
    let mut title = tag_text(&html, "h1");
    if title.is_empty() {
        if let Some(p) = html.find("<title>") {
            let after = &html[p + 7..];
            if let Some(e) = after.find("</title>") {
                title = strip_tags(&after[..e]);
                if let Some(q) = title.find("在线观看") {
                    title = title[..q].trim().to_string();
                }
            }
        }
    }
    if title.is_empty() {
        return Err(ApiError::Internal("短剧one未返回影片资料".into()));
    }
    let cover = poster_of(&html);
    let desc = desc_of(&html);
    let tags = tags_of(&html);
    let mut views = String::new();
    if let Some(p) = html.find("class=\"series-views\"") {
        let after = &html[p..];
        if let Some(s) = after.find('>') {
            if let Some(e) = after[s + 1..].find('<') {
                views = strip_tags(&after[s + 1..s + 1 + e]);
            }
        }
    }
    let mut episodes: Vec<Value> = Vec::new();
    let mut paid: Vec<i64> = Vec::new();
    let mut seen: Vec<i64> = Vec::new();
    for cap in ep_anchor_re().captures_iter(&html) {
        let cls = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let n: i64 = match cap[2].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        if seen.contains(&n) {
            continue;
        }
        seen.push(n);
        let is_paid = cls.contains("episode-paid");
        if is_paid {
            paid.push(n);
        }
        let label = if is_paid {
            format!("第{n}集·VIP")
        } else {
            format!("第{n}集")
        };
        episodes.push(episode_json(&format!("{series_id}:{n}"), &label, series_id));
    }
    episodes.sort_by_key(|e| {
        str_of(&e["video_id"])
            .rsplit(':')
            .next()
            .unwrap_or("0")
            .parse::<i64>()
            .unwrap_or(0)
    });
    if episodes.is_empty() {
        episodes.push(episode_json(&format!("{series_id}:1"), "第1集", series_id));
    }
    let mut remark_bits: Vec<String> = Vec::new();
    if !tags.is_empty() {
        remark_bits.push(tags.join(" / "));
    }
    remark_bits.push(format!("共 {} 集", episodes.len()));
    if !paid.is_empty() {
        remark_bits.push(format!("{} 集付费", paid.len()));
    }
    if !views.is_empty() {
        remark_bits.push(views);
    }
    let mut extra = serde_json::Map::new();
    extra.insert("remark".to_string(), json!(remark_bits.join(" · ")));
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/?q={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch_html(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items}))
}

/// 站内签发地址去掉 ?v= 签名后即为裸路径直链（免费集已验 4 个文件），
/// 不怕签名过期；付费集 /player 回 canWatch:false、src:null。
fn bare_url(src: &str) -> String {
    match src.find('?') {
        Some(i) => src[..i].to_string(),
        None => src.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.contains(".m3u8") || video_id.contains(".mp4") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let (series_id, ep) = match video_id.split_once(':') {
        Some((s, e)) => (s.to_string(), e.parse::<i64>().unwrap_or(1)),
        None => (video_id.to_string(), 1),
    };
    let url = format!("{HOST}/player/drama/{series_id}/ep/{ep}");
    let data = fetch_json(&url).await?;
    let can_watch = get(&data, "canWatch")
        .map(|v| v.as_bool().unwrap_or(false))
        .unwrap_or(false);
    let src = text_of(&data, &["src"]);
    if !can_watch || src.is_empty() {
        return Err(ApiError::Internal(format!(
            "短剧one第{ep}集需VIP或积分购买后观看"
        )));
    }
    Ok(json!({
        "url": bare_url(&src),
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/drama/{series_id}/ep/{ep}")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD_HTML: &str = r#"<a class="drama-card" href="https://duanju.one/drama/shaofubaijie-HighQuality-GH7RS1JH">
    <div class="cover">
                    <img src="https://duanju.one/storage/covers/01M5GEBHN3Y13JY839TBJRA441.webp" alt="少妇白洁 (高画质版)封面" loading="lazy">
                        <span class="badge partial">部分付费</span>
        <span class="episode-count">35 集</span>
    </div>
    <h2>少妇白洁 (高画质版)</h2>
            <div class="card-tags"><span>凌辱</span><span>剧情</span></div>
        <p>更新于 1天前</p>
</a>
                    <a class="drama-card" href="https://duanju.one/drama/5sisters-with-me-QR3POPJM">
    <div class="cover">
                    <img src="https://duanju.one/storage/covers/01M4F66APPTKP29B6X66X11PK9.webp" alt="有五个姐姐的我封面" loading="lazy">
                        <span class="badge free">免费</span>
        <span class="episode-count">10 集</span>
    </div>
    <h2>有五个姐姐的我</h2>
            <div class="card-tags"><span>小编推荐</span><span>幻想</span></div>
        <p>更新于 2天前</p>
</a>"#;

    const DETAIL_HTML: &str = r#"<title>少妇白洁 (高画质版)在线观看 - 短剧one</title><div class="player-wrap series-player"><video data-series-player controls src="https://cdn.duanju.one/2026/10/shaofubaijie-HQ/ep-001.mp4?v=4_z2d0345a033a8c8359dfa081e_f117d7602a59ae75b_d20261009_m015831_c004_v0402027_t0019_u01791511111901" poster="https://duanju.one/storage/covers/01M5GEBHN3Y13JY839TBJRA441.webp"></video></div><header class="series-watch-heading"><div><h1>少妇白洁 (高画质版)</h1><p class="current-episode">第 1 集</p></div></header><span class="series-views">13,408 次点击</span><details class="series-description" id="series-description" open><summary><span>剧情简介</span></summary><div class="drama-description-content"><p><strong>高画质意味着您需要更高的网络连接速率。</strong></p><p>《少妇白洁》是一个带有强烈现实主义气质的故事原型，围绕人物关系、选择与命运变化展开。</p></div><div class="series-tags"><a href="https://duanju.one/tag/Humiliation">凌辱</a><a href="https://duanju.one/tag/story">剧情</a></div><small>内容更新：2026-11-05</small></details><div class="episode-grid"><a class="episode-free" href="https://duanju.one/drama/shaofubaijie-HighQuality-GH7RS1JH/ep/1" aria-label="第 1 集，免费"><b>1</b><small>免费</small></a><a class="episode-paid" href="https://duanju.one/drama/shaofubaijie-HighQuality-GH7RS1JH/ep/11" aria-label="第 11 集，付费"><b>11</b><small>付费</small></a><a class="episode-paid" href="https://duanju.one/drama/shaofubaijie-HighQuality-GH7RS1JH/ep/35" aria-label="第 35 集，付费"><b>35</b><small>付费</small></a></div>"#;

    #[test]
    fn parse_cards_real_snippet() {
        let items = parse_cards(CARD_HTML);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "shaofubaijie-HighQuality-GH7RS1JH");
        assert_eq!(items[0]["title"], "少妇白洁 (高画质版)");
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://duanju.one/storage/covers/"));
        assert_eq!(
            items[0]["remark"],
            "部分付费 · 35 集 · 更新于 1天前 · 凌辱 / 剧情"
        );
        assert_eq!(items[1]["id"], "5sisters-with-me-QR3POPJM");
        assert_eq!(
            items[1]["remark"],
            "免费 · 10 集 · 更新于 2天前 · 小编推荐 / 幻想"
        );
    }

    #[test]
    fn parse_cards_dedupes_featured() {
        let html = format!("{CARD_HTML}{CARD_HTML}");
        let items = parse_cards(&html);
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn catalog_url_shapes() {
        assert_eq!(catalog_url("all", 1), "https://duanju.one/");
        assert_eq!(catalog_url("all", 2), "https://duanju.one/?page=2");
        assert_eq!(catalog_url("free", 1), "https://duanju.one/?filter=free");
        assert_eq!(
            catalog_url("free", 8),
            "https://duanju.one/?filter=free&page=8"
        );
        assert_eq!(catalog_url("vip", 1), "https://duanju.one/?filter=vip");
        assert_eq!(
            catalog_url("completed", 2),
            "https://duanju.one/?filter=completed&page=2"
        );
    }

    #[test]
    fn detail_fields_from_fixture() {
        assert_eq!(tag_text(DETAIL_HTML, "h1"), "少妇白洁 (高画质版)");
        assert_eq!(
            poster_of(DETAIL_HTML),
            "https://duanju.one/storage/covers/01M5GEBHN3Y13JY839TBJRA441.webp"
        );
        let desc = desc_of(DETAIL_HTML);
        assert!(desc.contains("高画质意味着您需要更高的网络连接速率。"));
        assert!(desc.contains("强烈现实主义气质"));
        assert_eq!(tags_of(DETAIL_HTML), vec!["凌辱", "剧情"]);
        let eps: Vec<(i64, bool)> = ep_anchor_re()
            .captures_iter(DETAIL_HTML)
            .map(|c| (c[2].parse::<i64>().unwrap(), c[1].contains("episode-paid")))
            .collect();
        assert_eq!(eps, vec![(1, false), (11, true), (35, true)]);
    }

    #[test]
    fn bare_url_strips_signature() {
        assert_eq!(
            bare_url("https://cdn.duanju.one/2026/10/shaofubaijie-HQ/ep-002.mp4?v=4_z2d0345a033a8c8359dfa081e_f1147b1120b6d6c20_d20261021_m235027_c004_v0402010_t0003_u01792626627374"),
            "https://cdn.duanju.one/2026/10/shaofubaijie-HQ/ep-002.mp4"
        );
        assert_eq!(
            bare_url("https://cdn.duanju.one/2026/10/x/ep-001.mp4"),
            "https://cdn.duanju.one/2026/10/x/ep-001.mp4"
        );
    }

    #[test]
    fn categories_count() {
        assert_eq!(CATS.len(), 4);
        assert_eq!(CATS[0], ("all", "全部"));
        assert_eq!(CATS[1], ("free", "免费"));
        assert_eq!(CATS[2], ("vip", "VIP / 积分"));
        assert_eq!(CATS[3], ("completed", "已完结"));
    }

    #[test]
    fn play_json_shapes() {
        let free: Value =
            serde_json::from_str(r#"{"canWatch":true,"src":"https://cdn.duanju.one/2026/10/5sisterwithme/ep-005.mp4?v=4_z2d0345a033a8c8359dfa081e_f11721107fb7c60c6_d20261009_m015922_c004_v0402033_t0014_u01791511162963"}"#)
                .unwrap();
        assert!(get(&free, "canWatch").unwrap().as_bool().unwrap());
        assert_eq!(
            bare_url(&text_of(&free, &["src"])),
            "https://cdn.duanju.one/2026/10/5sisterwithme/ep-005.mp4"
        );
        let locked: Value = serde_json::from_str(r#"{"canWatch":false,"src":null}"#).unwrap();
        assert!(!get(&locked, "canWatch").unwrap().as_bool().unwrap());
        assert!(text_of(&locked, &["src"]).is_empty());
        let _ = arr_of(&free);
    }
}
