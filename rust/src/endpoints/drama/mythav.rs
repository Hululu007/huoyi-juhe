//! 🔞MythAV：mythav.com 的镜像站（sdyoof.asia，/zh/ 中文站）。
//!
//! 站点整页为十六进制混淆包着的真 HTML：
//! `document.write(FN(unescape(GN("HEX","%"))))`，函数名每次变，
//! 但 HEX 本身就是整页 HTML 的十六进制；模块提最长 hex 串解码。
//! 详情页 `window.videoConfig.url` / JSON-LD `contentUrl` 给
//! m3cdn.playergo.top 的 master m3u8（带 verify 签名，现取现用）。
//! 注意：取清单必须带 `Origin: https://sdyoof.asia` 头，否则 CDN
//! 只回 8 秒占位清单（1 分片 video20000.jpeg，且分片 404）。
//! 验门（2026-11-06 本机出口实测）：首页 12 条/页；最新 p1/p2
//!（`?p=N`）各 12 条不重合；无码分类 p1/p2 各 12 条不重合；
//! 搜索 `?text=AKDL-373` 首条即本片；详情 AKDL-373（id 19232602，
//! 02:04:57）与 MUSUME-110426_01（id 19232630，00:37:54）两片；
//! 19232630 的 720p 清单 569 分片/2274.2 秒，与卡片 37:54 精确
//! 对上，首分片 200 + 207552B + TS 魔数 0x47；国产区
//! [无码] 骚妻全程露脸深喉爆操（19146633，01:33:10）的变体清单
//! 1870 分片/5608.4 秒，首分片 200 + 1175752B + TS 魔数 0x47。
//! mythav.com 本身 301 到 mythav.org，mythav.org/zh/ 404，
//! 故 HOST 用实测可用的镜像 sdyoof.asia；标签页 48 项。
//! 分类与站导航 1:1（最新上传 + 12 主题 + 国产传媒 + 标签）；
//! AI 短剧/漫剧/视频为多集剧集，走另一套播放页，本模块不含。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://sdyoof.asia";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 站内 12 主题（/zh/categories 页实测，含站内影片数）。
const CATS: &[(&str, &str)] = &[
    ("chinese-subtitle", "中文字幕"),
    ("bdsm", "主奴调教"),
    ("sex-only", "直接开啪"),
    ("insult", "凌辱快感"),
    ("uniform", "制服诱惑"),
    ("roleplay", "角色剧情"),
    ("private-cam", "盗摄偷拍"),
    ("uncensored", "无码解放"),
    ("pov", "男友视角"),
    ("groupsex", "多P群交"),
    ("pantyhose", "丝袜美腿"),
    ("lesbian", "女同性恋"),
];

/// 取页：失败时如实报错；返回解码后的 HTML。
async fn fetch(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", format!("{HOST}/zh/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("MythAV 请求 HTTP {status}")));
    }
    let body = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    Ok(decode_page(&body))
}

/// 整页十六进制混淆解码：找最长的十六进制串（>=1000 字符），
/// 按字节拼回 UTF-8；找不到时原样返回（站改版成明文时兜底）。
fn decode_page(body: &str) -> String {
    let bytes = body.as_bytes();
    let mut best_start = 0usize;
    let mut best_len = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i];
        let is_hex = c.is_ascii_digit() || (b'a'..=b'f').contains(&c) || (b'A'..=b'F').contains(&c);
        if is_hex {
            let start = i;
            while i < bytes.len() {
                let c = bytes[i];
                if c.is_ascii_digit() || (b'a'..=b'f').contains(&c) || (b'A'..=b'F').contains(&c) {
                    i += 1;
                } else {
                    break;
                }
            }
            if i - start > best_len {
                best_len = i - start;
                best_start = start;
            }
        } else {
            i += 1;
        }
    }
    if best_len >= 1000 && best_len % 2 == 0 {
        let hex = &body[best_start..best_start + best_len];
        let mut out = Vec::with_capacity(best_len / 2);
        let hb = hex.as_bytes();
        let mut ok = true;
        let mut j = 0usize;
        while j + 1 < hb.len() {
            let hi = hex_val(hb[j]);
            let lo = hex_val(hb[j + 1]);
            match (hi, lo) {
                (Some(h), Some(l)) => out.push((h << 4) | l),
                _ => {
                    ok = false;
                    break;
                }
            }
            j += 2;
        }
        if ok {
            if let Ok(s) = String::from_utf8(out) {
                return s;
            }
        }
    }
    body.to_string()
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn decode_entities(s: &str) -> String {
    let mut out = s
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "–")
        .replace("&mdash;", "—");
    // 数字实体 &#22269; 形：逐个转成字符。
    loop {
        let Some(p) = out.find("&#") else {
            break;
        };
        let rest = &out[p + 2..];
        let Some(end) = rest.find(';') else {
            break;
        };
        let num = &rest[..end];
        if num.len() > 7 || !num.bytes().all(|b| b.is_ascii_digit()) {
            break;
        }
        let Ok(n) = num.parse::<u32>() else {
            break;
        };
        let Some(ch) = char::from_u32(n) else {
            break;
        };
        out.replace_range(p..p + 2 + end + 1, &ch.to_string());
    }
    out.trim().to_string()
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

/// `<article class="video-card">` 卡片解析：JAV 详情
/// `/zh/video?id=NNN` 与国产 `/zh/guochan/play/NNN` 两种链接。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<article class=\"video-card\">").skip(1) {
        let end = block.find("</article>").unwrap_or(block.len());
        let block = &block[..end];
        let path = if let Some(p) = block.find("href=\"/zh/video?id=") {
            let s = p + 6;
            match block[s..].find('"') {
                Some(e) => block[s..s + e].to_string(),
                None => continue,
            }
        } else if let Some(p) = block.find("href=\"/zh/guochan/play/") {
            let s = p + 6;
            match block[s..].find('"') {
                Some(e) => block[s..s + e].to_string(),
                None => continue,
            }
        } else {
            continue;
        };
        let id = format!("{HOST}{path}");
        if seen.contains(&id) {
            continue;
        }
        let cover = match block.find("<img src=\"") {
            Some(p) => {
                let s = p + 10;
                block[s..]
                    .find('"')
                    .map(|e| block[s..s + e].to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let remark = match block.find("<span class=\"duration\">") {
            Some(p) => {
                let s = p + 23;
                block[s..]
                    .find("</span>")
                    .map(|e| block[s..s + e].trim().to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        let title = match block.find("<h3>") {
            Some(p) => {
                let after = &block[p..];
                match after.find("</h3>") {
                    Some(e) => strip_tags(&after[..e]),
                    None => String::new(),
                }
            }
            None => String::new(),
        };
        let title = truncate(&title, 90);
        if title.is_empty() {
            continue;
        }
        seen.push(id.clone());
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

/// 标签索引页解析：`<b># 名称</b><small>数量</small>`，出 folder 卡。
fn parse_tags(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<a href=\"/zh/tags/").skip(1) {
        let Some(e) = block.find('"') else {
            continue;
        };
        let slug = &block[..e];
        if slug.is_empty() || seen.contains(&slug.to_string()) {
            continue;
        }
        let name = match block.find("<b># ") {
            Some(p) => {
                let s = p + 5;
                block[s..]
                    .find("</b>")
                    .map(|e| decode_entities(block[s..s + e].trim()))
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        if name.is_empty() {
            continue;
        }
        let count = match block.find("<small>") {
            Some(p) => {
                let s = p + 7;
                block[s..]
                    .find("</small>")
                    .map(|e| block[s..s + e].trim().to_string())
                    .unwrap_or_default()
            }
            None => String::new(),
        };
        seen.push(slug.to_string());
        let mut item = item_json(
            &format!("folder@/zh/tags/{slug}"),
            &name,
            "",
            &format!("{count} 部影片"),
        );
        if let Some(obj) = item.as_object_mut() {
            obj.insert("vod_tag".to_string(), Value::String("folder".to_string()));
        }
        items.push(item);
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let with_page = |base: String| -> String {
        if page <= 1 {
            base
        } else if base.contains('?') {
            format!("{base}&p={page}")
        } else {
            format!("{base}?p={page}")
        }
    };
    match category_id {
        "latest" => with_page(format!("{HOST}/zh/latest-updates")),
        "guochan" => with_page(format!(
            "{HOST}/zh/guochan/category/43996?name=%E5%9B%BD%E4%BA%A7%E4%BC%A0%E5%AA%92"
        )),
        "tags" => format!("{HOST}/zh/tags"),
        _ => {
            if let Some(v) = category_id.strip_prefix("cat:") {
                with_page(format!("{HOST}/zh/categories/{v}"))
            } else if let Some(v) = category_id.strip_prefix("tag:") {
                with_page(format!("{HOST}/zh/tags/{v}"))
            } else {
                with_page(format!("{HOST}/zh/latest-updates"))
            }
        }
    }
}

/// JSON-LD `duration":"PT02H04M57S"` 转秒数。
fn parse_iso_duration(html: &str) -> Option<u64> {
    let p = html.find("\"duration\":\"PT")?;
    let rest = &html[p + 14..];
    let end = rest.find('"')?;
    let body = &rest[..end];
    let mut secs: u64 = 0;
    let mut num = String::new();
    for c in body.chars() {
        if c.is_ascii_digit() {
            num.push(c);
        } else {
            let v: u64 = num.parse().ok()?;
            match c {
                'H' => secs += v * 3600,
                'M' => secs += v * 60,
                'S' => secs += v,
                _ => return None,
            }
            num.clear();
        }
    }
    Some(secs)
}

fn fmt_duration(secs: u64) -> String {
    format!(
        "{:02}:{:02}:{:02}",
        secs / 3600,
        (secs / 60) % 60,
        secs % 60
    )
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

/// 详情页取流地址：videoConfig.url 优先，contentUrl 兜底。
fn extract_stream_url(html: &str) -> String {
    if let Some(p) = html.find("\"url\":\"https://") {
        let s = p + 7;
        if let Some(e) = html[s..].find('"') {
            let url = &html[s..s + e];
            if url.contains(".m3u8") {
                return url.to_string();
            }
        }
    }
    if let Some(p) = html.find("\"contentUrl\":\"") {
        let s = p + 14;
        if let Some(e) = html[s..].find('"') {
            let url = &html[s..s + e];
            if url.contains(".m3u8") {
                return url.to_string();
            }
        }
    }
    String::new()
}

fn json_ld_genres(html: &str) -> Vec<String> {
    let Some(p) = html.find("\"genre\":[") else {
        return Vec::new();
    };
    let rest = &html[p + 9..];
    let Some(end) = rest.find(']') else {
        return Vec::new();
    };
    rest[..end]
        .split(',')
        .filter_map(|t| {
            let t = t.trim().trim_matches('"');
            if t.is_empty() {
                None
            } else {
                Some(decode_entities(t))
            }
        })
        .collect()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = vec![category_json("latest", "最新上传")];
    for (slug, name) in CATS {
        list.push(category_json(&format!("cat:{slug}"), name));
    }
    list.push(category_json("guochan", "国产传媒"));
    list.push(category_json("tags", "标签"));
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    // folder 卡：标签页作列表。
    if let Some(folder_path) = category_id.strip_prefix("folder@") {
        let url = if page > 1 {
            format!("{HOST}{folder_path}?p={page}")
        } else {
            format!("{HOST}{folder_path}")
        };
        let html = fetch(&url).await?;
        let items = parse_cards(&html);
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    if category_id == "tags" {
        let html = fetch(&format!("{HOST}/zh/tags")).await?;
        let items = parse_tags(&html);
        return Ok(json!({"items": items, "has_more": !items.is_empty()}));
    }
    let url = catalog_url(category_id, page);
    let html = fetch(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page_url = series_id.split('$').last().unwrap_or(series_id).to_string();
    let html = fetch(&page_url).await?;
    let title = match html.find("<h1>") {
        Some(p) => {
            let after = &html[p + 4..];
            after
                .find("</h1>")
                .map(|e| strip_tags(&after[..e]))
                .unwrap_or_default()
        }
        None => String::new(),
    };
    if title.is_empty() {
        return Err(ApiError::Internal("MythAV 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let mut synopsis = String::new();
    if let Some(secs) = parse_iso_duration(&html) {
        synopsis.push_str(&format!("时长：{}", fmt_duration(secs)));
    }
    let genres = json_ld_genres(&html);
    if !genres.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push('\n');
        }
        synopsis.push_str(&format!("标签：{}", genres.join("、")));
    }
    Ok(json!({
        "id": page_url,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&page_url, "正片", &page_url)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    // 详情页 URL 直接进；已是 m3u8 地址时原样回（带 Origin 头）。
    if video_id.starts_with("http") && video_id.contains(".m3u8") {
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/zh/"), "Origin": HOST, "Accept": "*/*"},
        }));
    }
    let page_url = video_id.split('$').last().unwrap_or(video_id).to_string();
    let html = fetch(&page_url).await?;
    let url = extract_stream_url(&html);
    if url.is_empty() {
        return Err(ApiError::Internal("MythAV 详情页未找到播放地址".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": page_url, "Origin": HOST, "Accept": "*/*"},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/zh/search?text={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_page_hex_payload() {
        // 真实结构的小样本：hex 编码一段 >=1000 字符的十六进制串
        //（真实页的 hex 串以万计，1000 为解码阈值）。
        let raw = format!(
            "<title>X</title><article class=\"video-card\">{}</article>",
            "x".repeat(600)
        );
        let hex: String = raw.bytes().map(|b| format!("{b:02x}")).collect();
        assert!(hex.len() >= 1000);
        let body = format!("<script>document.write(FN(unescape(GN(\"{hex}\",\"%\"))));</script>");
        assert_eq!(decode_page(&body), raw);
    }

    #[test]
    fn decode_page_plain_passthrough() {
        let body = "<html><body>plain</body></html>";
        assert_eq!(decode_page(body), body);
    }

    #[test]
    fn decode_entities_numeric() {
        assert_eq!(decode_entities("&#22269;&#20135;情色"), "国产情色");
        assert_eq!(decode_entities("A &amp; B"), "A & B");
    }

    #[test]
    fn parse_video_cards() {
        let html = r#"<article class="video-card">
  <a class="poster" href="/zh/video?id=19232602"><img src="https://cache.example.com/cover.cache" alt="AKDL-373 由香" loading="lazy">
<b class="source-badge">JAV</b><span class="view-count">● 0</span><span class="duration">02:04:57</span></a>
  <h3><a href="/zh/video?id=19232602"><b>akdl-373</b> AKDL-373 由香</a></h3>
</article>
<article class="video-card">
  <a class="poster" href="/zh/guochan/play/19146633"><img src="https://cache.example.com/gc.cache" alt="x" loading="lazy">
<b class="source-badge">国产</b><span class="duration">01:33:10</span></a>
  <h3><a href="/zh/guochan/play/19146633"><b>19146633</b> [无码] 骚妻全程露脸深喉爆操</a></h3>
</article>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "https://sdyoof.asia/zh/video?id=19232602");
        assert_eq!(items[0]["title"], "akdl-373 AKDL-373 由香");
        assert_eq!(items[0]["remark"], "02:04:57");
        assert_eq!(
            items[1]["id"],
            "https://sdyoof.asia/zh/guochan/play/19146633"
        );
        assert_eq!(items[1]["remark"], "01:33:10");
    }

    #[test]
    fn parse_tag_index() {
        let html = r#"<a href="/zh/tags/%E7%BB%BC%E8%89%BA" style="">
        <i></i><b># 综艺</b><small>106</small>
      </a>"#;
        let items = parse_tags(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "folder@/zh/tags/%E7%BB%BC%E8%89%BA");
        assert_eq!(items[0]["title"], "综艺");
        assert_eq!(items[0]["remark"], "106 部影片");
        assert_eq!(items[0]["vod_tag"], "folder");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("latest", 1),
            "https://sdyoof.asia/zh/latest-updates"
        );
        assert_eq!(
            catalog_url("latest", 2),
            "https://sdyoof.asia/zh/latest-updates?p=2"
        );
        assert_eq!(
            catalog_url("cat:uncensored", 2),
            "https://sdyoof.asia/zh/categories/uncensored?p=2"
        );
        assert_eq!(
            catalog_url("guochan", 2),
            "https://sdyoof.asia/zh/guochan/category/43996?name=%E5%9B%BD%E4%BA%A7%E4%BC%A0%E5%AA%92&p=2"
        );
        assert_eq!(
            catalog_url("tag:%E7%BB%BC%E8%89%BA", 1),
            "https://sdyoof.asia/zh/tags/%E7%BB%BC%E8%89%BA"
        );
    }

    #[test]
    fn iso_duration_parses() {
        assert_eq!(
            parse_iso_duration(r#""duration":"PT02H04M57S""#),
            Some(2 * 3600 + 4 * 60 + 57)
        );
        assert_eq!(
            parse_iso_duration(r#""duration":"PT37M54S""#),
            Some(37 * 60 + 54)
        );
        assert_eq!(fmt_duration(7497), "02:04:57");
    }

    #[test]
    fn stream_url_from_video_config() {
        let html = r#"window.videoConfig={"fanhao":"akdl-373","url":"https://m3cdn.playergo.top/abc/playlist.m3u8?verify=1","img":"x"};"#;
        assert_eq!(
            extract_stream_url(html),
            "https://m3cdn.playergo.top/abc/playlist.m3u8?verify=1"
        );
        let html2 = r#""contentUrl":"https://m3cdn.playergo.top/def/playlist.m3u8?verify=2""#;
        assert_eq!(
            extract_stream_url(html2),
            "https://m3cdn.playergo.top/def/playlist.m3u8?verify=2"
        );
    }
}
