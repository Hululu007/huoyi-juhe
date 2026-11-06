//! J-AV：`https://j-av.com`。
//!
//! jar 内 ZakaJavAmns 的移植。博客式列表：分类在 `/{cat}/` 子目录，
//! 每页 5 条 `<!-- BLOG ENTRY BEGIN -->`，翻页是游标式（“下一頁”
//! 链接 `index.php?m=..&y=..&d=..&entry=..`，逐页跟链）。
//! 详情：`/{cat}/index.php?entry={entry}`；取流三级：详情页 iframe
//! `../player/{name}?id={vid}` → 站根播放器页 → 内嵌 mmsi02.com
//! 页 → 解包 Dean Edwards 打包 JS（radix 62）取 `"hlsN"` 键。
//! 搜索无服务端接口：jar 原文是 4 分类 × 前 4 页扫标题子串匹配，
//! 最多 20 条，核心照此实现。
//! 注意：解出的流（premilkyway/hls2、tradeexecution/hls3）本机出口
//! 四种头组合均回 403（CDN 拒），首分片验不了，取流须手机侧复验；
//! 列表/翻页/详情/搜索本机已验通。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://j-av.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 分类（jar 的 CATS 原文）。
const CATS: &[(&str, &str)] = &[
    ("uncensored", "日本無碼"),
    ("amateur", "自拍影片"),
    ("video", "中文有碼"),
    ("reducing-mosaic", "無碼破解"),
];

/// jar 的 base：分类基址 `HOST/{cat}/`。
fn base(cat: &str) -> String {
    if cat.is_empty() {
        format!("{HOST}/")
    } else {
        format!("{HOST}/{cat}/")
    }
}

fn cat_name(cat: &str) -> &'static str {
    CATS.iter()
        .find(|(k, _)| *k == cat)
        .map(|(_, n)| *n)
        .unwrap_or("J-AV")
}

/// 带头取页（jar 的 page 同款头）。
async fn fetch_text(url: &str) -> ApiResult<String> {
    fetch_with(
        url,
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    )
    .await
}

async fn fetch_with(url: &str, accept: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", accept)
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("J-AV 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("J-AV 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!("J-AV 请求失败：HTTP {status}")));
    }
    Ok(text)
}

fn unesc(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// jar 的 clean：去标签、去 \u{a0}、去首尾空白。
fn clean(s: &str) -> String {
    let tag = Regex::new(r"<[^>]+>").unwrap();
    tag.replace_all(s, "")
        .replace('\u{a0}', " ")
        .trim()
        .to_string()
}

/// jar 的 dec：URL 解码（image 参数）。
fn dec(s: &str) -> String {
    percent_encoding::percent_decode_str(s)
        .decode_utf8_lossy()
        .to_string()
}

/// 相对地址补成绝对地址。
fn abs_url(u: &str, referer_base: &str) -> String {
    let u = unesc(u.trim());
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u;
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https:{rest}");
    }
    if let Some(rest) = u.strip_prefix("../") {
        return format!("{HOST}/{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{referer_base}{u}")
}

/// 博客列表解析：按 `<!-- BLOG ENTRY BEGIN -->` 分块；标题取
///.blog_subject（空则取 <b>），封面取 iframe 的 image 参数，
/// 备注取分类名（jar 原文）。
fn parse_list(html: &str, cat: &str, limit: usize) -> Vec<Value> {
    let entry_re = Regex::new(r"<!--\s*BLOG ENTRY BEGIN\s*-->").unwrap();
    let id_re = Regex::new(r"index\.php\?entry=(entry[0-9a-zA-Z\-]+)").unwrap();
    let subj_re = Regex::new(r#"class="blog_subject"[^>]*>(.*?)</div>"#).unwrap();
    let b_re = Regex::new(r"<b>(.*?)</b>").unwrap();
    let if_re = Regex::new(
        r#"<iframe[^>]+src="\.\./player/([^"?]+)\?id=([0-9A-Za-z]+)(?:&(?:amp;)?image=([^"&]*))?"#,
    )
    .unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let parts: Vec<&str> = entry_re.split(html).collect();
    for part in parts.iter().skip(1) {
        let Some(id_cap) = id_re.captures(part) else {
            continue;
        };
        let entry = id_cap.get(1).unwrap().as_str();
        if !seen.insert(entry.to_string()) {
            continue;
        }
        let title = subj_re
            .captures(part)
            .map(|c| clean(c.get(1).unwrap().as_str()))
            .filter(|t| !t.is_empty())
            .or_else(|| {
                b_re.captures(part)
                    .map(|c| clean(c.get(1).unwrap().as_str()))
                    .filter(|t| !t.is_empty())
            })
            .unwrap_or_else(|| "J-AV 影片".to_string());
        let pic = if_re
            .captures(part)
            .and_then(|c| c.get(3))
            .map(|m| dec(m.as_str()))
            .unwrap_or_default();
        out.push(item_json(
            &format!("{cat}|{entry}"),
            &title,
            &pic,
            cat_name(cat),
        ));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// “下一頁”链接（相对地址），没有则回空。
fn next_link(html: &str) -> String {
    let re = Regex::new(r#"<a href="(index\.php\?[^"]+)"[^>]*>\s*下一頁\s*</a>"#).unwrap();
    re.captures(html)
        .map(|c| unesc(c.get(1).unwrap().as_str()))
        .unwrap_or_default()
}

/// 编号页链里的最大页码（没有则回 1）。
fn max_page_num(html: &str) -> i64 {
    let re = Regex::new(r#"<a href="(index\.php\?[^"]+)"[^>]*>\s*(\d{1,4})\s*</a>"#).unwrap();
    re.captures_iter(html)
        .filter_map(|c| c.get(2).unwrap().as_str().parse::<i64>().ok())
        .max()
        .unwrap_or(1)
}

/// 跟游标链取到第 N 页（jar 的 pageUrl/mergePager 同款）。
async fn page_html(cat: &str, page: i64) -> ApiResult<(String, i64)> {
    let mut url = base(cat);
    let mut html = fetch_text(&url).await?;
    let mut total = max_page_num(&html);
    let mut cur = 1;
    while cur < page {
        let next = next_link(&html);
        if next.is_empty() {
            break;
        }
        url = format!("{}{}", base(cat), next);
        html = fetch_text(&url).await?;
        total = total.max(max_page_num(&html));
        cur += 1;
    }
    Ok((html, total))
}

/// 读一个引号包裹的 JS 字符串字面量，返回（原样内文，不含外层
/// 引号，下一位置）；串内反斜杠转义不提前终结字符串。
fn read_quoted(chars: &[char], mut i: usize) -> Option<(String, usize)> {
    while i < chars.len() && chars[i].is_whitespace() {
        i += 1;
    }
    if i >= chars.len() || (chars[i] != '\'' && chars[i] != '"') {
        return None;
    }
    let q = chars[i];
    i += 1;
    let mut out = String::new();
    while i < chars.len() {
        let c = chars[i];
        if c == '\\' && i + 1 < chars.len() {
            out.push('\\');
            out.push(chars[i + 1]);
            i += 2;
        } else if c == q {
            return Some((out, i + 1));
        } else {
            out.push(c);
            i += 1;
        }
    }
    None
}

/// 读一个十进制整数，返回（值，下一位置）。
fn read_number(chars: &[char], mut i: usize) -> Option<(usize, usize)> {
    while i < chars.len() && chars[i].is_whitespace() {
        i += 1;
    }
    let start = i;
    while i < chars.len() && chars[i].is_ascii_digit() {
        i += 1;
    }
    if i == start {
        return None;
    }
    chars[start..i]
        .iter()
        .collect::<String>()
        .parse()
        .ok()
        .map(|n| (n, i))
}

/// 跳过空白后要求当前字符是 want，返回其后位置。
fn expect_char(chars: &[char], mut i: usize, want: char) -> Option<usize> {
    while i < chars.len() && chars[i].is_whitespace() {
        i += 1;
    }
    if i < chars.len() && chars[i] == want {
        Some(i + 1)
    } else {
        None
    }
}

/// Dean Edwards 打包 JS 解包（jar 的 unpack 同款，radix 62）。
/// Rust 的 regex 不支持反向引用，原先 `\1`/`\5` 的写法编译就
/// 报错；改为手工解析 eval(...) 的四个实参（打包串、进制、个数、
/// 字典串），字典串后的 .split('|') 不用消费。
fn unpack(html: &str) -> String {
    let head = "eval(function(p,a,c,k,e,d){";
    let Some(h) = html.find(head) else {
        return String::new();
    };
    let Some(close) = html[h..].find("}(") else {
        return String::new();
    };
    let args: Vec<char> = html[h + close + 2..].chars().collect();
    let Some((packed, i)) = read_quoted(&args, 0) else {
        return String::new();
    };
    let Some(i) = expect_char(&args, i, ',') else {
        return String::new();
    };
    let Some((radix, i)) = read_number(&args, i) else {
        return String::new();
    };
    let Some(i) = expect_char(&args, i, ',') else {
        return String::new();
    };
    let Some((count, i)) = read_number(&args, i) else {
        return String::new();
    };
    let Some(i) = expect_char(&args, i, ',') else {
        return String::new();
    };
    let Some((dict_raw, _)) = read_quoted(&args, i) else {
        return String::new();
    };
    let radix = radix as u32;
    if radix < 2 {
        return String::new();
    }
    let words: Vec<&str> = dict_raw.split('|').collect();
    let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let to_radix = |mut n: usize| -> String {
        if n == 0 {
            return "0".to_string();
        }
        let mut out = String::new();
        while n > 0 {
            out.insert(0, alphabet[n % radix as usize] as char);
            n /= radix as usize;
        }
        out
    };
    let mut dict = std::collections::HashMap::new();
    for i in 0..count {
        let key = to_radix(i);
        let val = words.get(i).copied().unwrap_or("");
        dict.insert(key, val.to_string());
    }
    let word_re = Regex::new(r"[A-Za-z0-9_]+").unwrap();
    let unpacked = word_re.replace_all(&packed, |c: &regex::Captures| {
        dict.get(c.get(0).unwrap().as_str())
            .cloned()
            .unwrap_or_else(|| c.get(0).unwrap().as_str().to_string())
    });
    unpacked.replace("\\'", "'").replace("\\\"", "\"")
}

/// jar 的 pickStream：取解包文本里的 `"hlsN":"http..."` 键（长 ≥12）。
fn pick_streams(unpacked: &str) -> Vec<String> {
    let re = Regex::new(r#""(hls\d?)"\s*:\s*"(http[^"]+)""#).unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for cap in re.captures_iter(unpacked) {
        let url = unesc(cap.get(2).unwrap().as_str());
        if url.len() < 12 {
            continue;
        }
        if seen.insert(url.clone()) {
            out.push(url);
        }
    }
    // 仍空则扫全页 m3u8/mp4（jar 的 pickStream 回退）。
    if out.is_empty() {
        let re2 = Regex::new(r#"(https?://[^"']+\.(?:m3u8|mp4)[^"']*)"#).unwrap();
        for cap in re2.captures_iter(unpacked) {
            let url = unesc(cap.get(1).unwrap().as_str());
            if seen.insert(url.clone()) {
                out.push(url);
            }
        }
    }
    out
}

/// jar 的 resolve：详情页 iframe → 站根播放器页 → 内嵌页 → 解包取流。
async fn resolve(detail_html: &str, detail_url: &str) -> ApiResult<Vec<String>> {
    let if_re = Regex::new(
        r#"<iframe[^>]+src="\.\./player/([^"?]+)\?id=([0-9A-Za-z]+)(?:&(?:amp;)?image=([^"&]*))?"#,
    )
    .unwrap();
    let Some(cap) = if_re.captures(detail_html) else {
        return Ok(Vec::new());
    };
    let name = cap.get(1).unwrap().as_str();
    let vid = cap.get(2).unwrap().as_str();
    let player_url = format!("{HOST}/player/{name}?id={vid}&play=1");
    let player_html = fetch_with(&player_url, "text/html,application/xhtml+xml,*/*;q=0.8").await?;
    let inner_re = Regex::new(r#"<iframe[^>]+src="(https?://[^"]+)""#).unwrap();
    let Some(inner) = inner_re.captures(&player_html) else {
        return Ok(Vec::new());
    };
    let inner_url = inner.get(1).unwrap().as_str();
    let inner_html = fetch_with(inner_url, "text/html,application/xhtml+xml,*/*;q=0.8").await?;
    let unpacked = unpack(&inner_html);
    if unpacked.len() < 12 {
        // jar 的 third：解包太短时再取一次（盾/直连兜底已在 fetch 里）。
        return Ok(pick_streams(&inner_html));
    }
    let _ = detail_url;
    Ok(pick_streams(&unpacked))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let list: Vec<Value> = CATS
        .iter()
        .map(|(id, name)| category_json(id, name))
        .collect();
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let cat = if CATS.iter().any(|(k, _)| *k == category_id) {
        category_id
    } else {
        "uncensored"
    };
    let (html, total) = page_html(cat, page).await?;
    let items = parse_list(&html, cat, 5);
    let has_more = !next_link(&html).is_empty();
    Ok(json!({
    "page": page,
    "pagecount": total.max(1),
    "limit": 5,
    "total": total,
    "has_more": has_more,
    "list": items,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    let (cat, entry) = match video_id.split_once('|') {
        Some((c, e)) => (c, e),
        None => ("uncensored", video_id),
    };
    let url = format!("{}index.php?entry={entry}", base(cat));
    let html = fetch_text(&url).await?;
    let title_re = Regex::new(r"<title>(.*?)</title>").unwrap();
    let suffix_re = Regex::new(r"\s*[-|]\s*J-AV.*$").unwrap();
    let title = title_re
        .captures(&html)
        .map(|c| clean(suffix_re.replace(c.get(1).unwrap().as_str(), "").as_ref()))
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "J-AV 影片".to_string());
    let og_re = Regex::new(r#"og:image"[^>]*content="([^"]+)""#).unwrap();
    let og_re2 = Regex::new(r#"content="([^"]+)"[^>]*og:image"#).unwrap();
    let if_re = Regex::new(
        r#"<iframe[^>]+src="\.\./player/([^"?]+)\?id=([0-9A-Za-z]+)(?:&(?:amp;)?image=([^"&]*))?"#,
    )
    .unwrap();
    let cover = og_re
        .captures(&html)
        .or_else(|| og_re2.captures(&html))
        .map(|c| abs_url(c.get(1).unwrap().as_str(), &base(cat)))
        .filter(|c| !c.is_empty())
        .or_else(|| {
            if_re
                .captures(&html)
                .and_then(|c| c.get(3))
                .map(|m| dec(m.as_str()))
        })
        .unwrap_or_default();
    let date_re = Regex::new(r#"class="blog_date">\s*([0-9\-]{4,12})"#).unwrap();
    let date = date_re
        .captures(&html)
        .map(|c| c.get(1).unwrap().as_str().to_string())
        .unwrap_or_default();
    let mut synopsis = format!("{}\n", cat_name(cat));
    if !date.is_empty() {
        synopsis.push_str(&format!("日期：{date}\n"));
    }
    synopsis.push_str("來源：J-AV（j-av.com）\n");
    let streams = resolve(&html, &url).await.unwrap_or_default();
    let mut episodes = Vec::new();
    for (i, stream) in streams.iter().enumerate() {
        episodes.push(episode_json(
            &format!("m|{stream}"),
            &format!("線{}", i + 1),
            &url,
        ));
    }
    if let Some(cap) = if_re.captures(&html) {
        let name = cap.get(1).unwrap().as_str();
        let vid = cap.get(2).unwrap().as_str();
        let player_url = format!("{HOST}/player/{name}?id={vid}&play=1");
        episodes.push(episode_json(&player_url, "播放器頁", &url));
    }
    episodes.push(episode_json(&url, "原頁面", &url));
    Ok(json!({
    "id": video_id,
    "title": title,
    "cover": cover,
    "synopsis": synopsis.trim(),
    "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    // jar 原文：无服务端搜索，4 分类 × 前 4 页扫标题子串，最多 20 条。
    let needle = query.trim().to_lowercase();
    let mut out: Vec<Value> = Vec::new();
    'outer: for (cat, _) in CATS {
        for page in 1..=4 {
            let (html, _) = match page_html(cat, page).await {
                Ok(v) => v,
                Err(_) => break,
            };
            for item in parse_list(&html, cat, 5) {
                let name = item["vod_name"].as_str().unwrap_or("").to_lowercase();
                if name.contains(&needle) {
                    out.push(item);
                    if out.len() >= 20 {
                        break 'outer;
                    }
                }
            }
            if next_link(&html).is_empty() {
                break;
            }
        }
    }
    Ok(json!({"items": out}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(stream) = video_id.strip_prefix("m|") {
        if stream.starts_with("http") {
            return Ok(json!({"url": stream}));
        }
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    if video_id.contains('|') {
        let d = detail(video_id).await?;
        if let Some(eps) = d.get("episodes").and_then(|e| e.as_array()) {
            for ep in eps {
                let id = ep["video_id"].as_str().unwrap_or("");
                if let Some(stream) = id.strip_prefix("m|") {
                    return Ok(json!({"url": stream}));
                }
            }
        }
        return Err(ApiError::Internal("J-AV 该视频没有播放地址".into()));
    }
    Err(ApiError::Internal("J-AV 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_builds_category_url() {
        assert_eq!(base("uncensored"), "https://j-av.com/uncensored/");
        assert_eq!(base(""), "https://j-av.com/");
    }

    #[test]
    fn unpack_restores_hls_keys() {
        // radix 62：'a' 是 10，'b' 是 11；字典 [url, key]。
        let packed = r#"eval(function(p,a,c,k,e,d){}('0 1',62,2,'https://x/hls2/master.m3u8|hls2'.split('|')))"#;
        let out = unpack(packed);
        assert!(out.contains("https://x/hls2/master.m3u8"));
    }

    #[test]
    fn parse_list_reads_blog_entries() {
        let html = r#"<!-- BLOG ENTRY BEGIN --><a href="index.php?entry=entry261105-070356"></a><div class="blog_subject">影片标题</div><iframe src="../player/twvid/sw.php?id=abc123&image=https://img/x.jpg"></iframe><div class="blog_date">2026-11-5</div><!-- BLOG ENTRY BEGIN -->"#;
        let items = parse_list(html, "uncensored", 5);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "uncensored|entry261105-070356");
        assert_eq!(items[0]["title"], "影片标题");
        assert_eq!(items[0]["cover"], "https://img/x.jpg");
    }
}
