//! 91porna（91porna.com）：视频站，列表与详情走 HTML 解析。
//! 取流链路（已全程跑通）：详情页 → 内嵌页
//! `/comic/index/embed?id=<数字id>` → 页内打包脚本动态加载
//! `/index/embed_play.js?img=<urlencoded logo>&u=<hex>&h=&t=<floor(now/2100)>`
//! → 该 JS 是 Dean Edwards 打包脚本，解包后得到
//! `<video id="videoPlayer"><source src="https://yd-jhph-hls.hzjvlo.cn/videos5/<hash>/<hash>.m3u8?auth_key=...&v=3&time=0&via=91porna&via_bm=dx">`。
//! 两步都要解包：内嵌页的打包脚本解包后给出 `u`（每视频嵌在页里的
//! hex 串，须现取）与 img 参数；embed_play.js 解包后给出 m3u8。
//! CDN 头：详情页 `#cdn-config` 的 `x-cdn-auth` 与 `x-cdn-app`，
//! 从页里现解析，不写死。
//! 实测 video_key=446762：m3u8 200、254 分片、1268.4 秒，
//! 与卡片 1268 秒精确对上（全长）；AES-128（密钥
//! `https://tp4.drleao.cn/videos5/<hash>/crypt.key`，200/16B）；
//! 首分片 200，AES-128-CBC 解密后首字节 0x47。
//! 注意：列表页详情链接是 `/comic/index/detail?video_key=<数字>`，
//! 搜索页是 `/comic/index/avdetail?video_key=<字母串>`，数字 id
//! 须从详情页 `data-video="<数字>"` 或 embed 链接里现取。
//! 分类：视频区 3 项 + AV 主题（model 号）；列表 `?page=N`；
//! 搜索 `/comic/index/search?keyword=...`。

use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://91porna.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 静态分类：视频区 3 项 + AV 主题。
const CATS: &[(&str, &str)] = &[
    ("play", "正在播放"),
    ("now_month_hot", "热门排行榜"),
    ("original", "国产原创"),
    ("theme:1", "多P群交"),
    ("theme:12", "无码解放"),
    ("theme:5", "中文字幕"),
    ("theme:6", "制服诱惑"),
    ("theme:107", "黑人专区"),
    ("theme:7", "SM调教"),
];

fn word_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\w+").unwrap())
}

fn pack_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?s)\}\('(.*)',(\d+),(\d+),'(.*)'\.split\('\|'\)").unwrap())
}

fn m3u8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"https://[^\s"\\]+\.m3u8[^\s"\\]*"#).unwrap())
}

fn play_params_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"embed_play\.js\?img=([^"&]+)&u="\+encodeURIComponent\("([0-9a-f]+)"\)"#)
            .unwrap()
    })
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
        return Err(ApiError::Internal(format!("91porna 请求 HTTP {status}")));
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

/// Dean Edwards 打包器的基数字符：0-9a-z，36 以上用 chr(v+29)。
fn encode_base(mut n: u32, base: u32) -> String {
    fn digit(v: u32) -> char {
        if v <= 35 {
            char::from_digit(v, 36).unwrap_or('0')
        } else {
            char::from_u32(v + 29).unwrap_or('?')
        }
    }
    if n < base {
        return digit(n).to_string();
    }
    let mut out = String::new();
    while n >= base {
        out.insert(0, digit(n % base));
        n /= base;
    }
    out.insert(0, digit(n));
    out
}

/// JS 单引号字符串字面量转义还原。
fn js_unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('b') => out.push('\u{0008}'),
            Some('f') => out.push('\u{000C}'),
            Some('v') => out.push('\u{000B}'),
            Some('0') => out.push('\0'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

/// Dean Edwards 打包脚本解包：
/// `eval(function(p,a,c,k,e,d){...}('PAYLOAD',BASE,COUNT,'K0|K1|...'.split('|'),0,{}))`
/// 字典 d[e(i)] = k[i]（空则为 e(i) 本身），再把 payload 里每个
/// `\w+` 单词按字典替换。
fn dean_unpack(packed: &str) -> Option<String> {
    let cap = pack_re().captures(packed)?;
    let payload = js_unescape(&cap[1]);
    let base: u32 = cap[2].parse().ok()?;
    let count: u32 = cap[3].parse().ok()?;
    let keys: Vec<&str> = cap[4].split('|').collect();
    let mut dict: HashMap<String, String> = HashMap::new();
    for i in 0..count {
        let key = encode_base(i, base);
        let val = keys.get(i as usize).copied().unwrap_or("");
        if val.is_empty() {
            dict.insert(key.clone(), key);
        } else {
            dict.insert(key, val.to_string());
        }
    }
    let re = word_re();
    let out = re.replace_all(&payload, |c: &regex::Captures| {
        dict.get(&c[0]).cloned().unwrap_or_else(|| c[0].to_string())
    });
    Some(out.into_owned())
}

/// 从 HTML 里抠出 Dean Edwards 打包脚本（到下一个 `</script>` 为止）。
fn extract_packed(html: &str) -> Option<String> {
    let start = html.find("eval(function(p,a,c,k,e,d)")?;
    let after = &html[start..];
    let end = after.find("</script>").unwrap_or(after.len());
    Some(after[..end].to_string())
}

fn attr<'a>(tag: &'a str, name: &str) -> String {
    let marker = format!("{name}=\"");
    let Some(p) = tag.find(&marker) else {
        return String::new();
    };
    let s = p + marker.len();
    tag[s..]
        .find('"')
        .map(|e| decode_entities(&tag[s..s + e]))
        .unwrap_or_default()
}

/// `<div class="video-item">` 卡片解析（列表页与搜索页通用）。
fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for block in html.split("<div class=\"video-item\">").skip(1) {
        let end = block
            .find("<div class=\"video-item\">")
            .unwrap_or(block.len());
        let block = &block[..end];
        let Some(hp) = block.find("video_key=") else {
            continue;
        };
        let after_key = &block[hp + 10..];
        let key_end = after_key
            .find(|c: char| c == '"' || c == '\'' || c == '&' || c == ' ')
            .unwrap_or(after_key.len());
        let key = &after_key[..key_end];
        if key.is_empty() {
            continue;
        }
        // 详情链接两种格式：detail（数字）与 avdetail（字母串）。
        let href = if block[..hp].contains("avdetail") {
            format!("{HOST}/comic/index/avdetail?video_key={key}")
        } else {
            format!("{HOST}/comic/index/detail?video_key={key}")
        };
        if seen.contains(&href) {
            continue;
        }
        // 标题：img alt，兜底 h2。
        let mut title = String::new();
        if let Some(p) = block.find("<img ") {
            let img = &block[p..];
            title = attr(img, "alt");
        }
        if title.is_empty() {
            if let Some(p) = block.find("<h2") {
                let after = &block[p..];
                if let Some(gt) = after.find('>') {
                    let s = gt + 1;
                    if let Some(e) = after[s..].find("</h2>") {
                        title = strip_tags(&after[s..s + e]);
                    }
                }
            }
        }
        if title.is_empty() {
            continue;
        }
        // 封面：img data-src，跳过站内加载占位图。
        let mut cover = String::new();
        if let Some(p) = block.find("<img ") {
            let img = &block[p..];
            let ds = attr(img, "data-src");
            let src = attr(img, "src");
            if !ds.is_empty() && !ds.contains("poster_loading") {
                cover = ds;
            } else if !src.is_empty() && !src.contains("poster_loading") {
                cover = src;
            }
        }
        // 时长徽章。
        let mut remark = String::new();
        if let Some(p) = block.find("opacity-50") {
            let after = &block[p..];
            if let Some(gt) = after.find('>') {
                let s = gt + 1;
                if let Some(e) = after[s..].find("</div>") {
                    remark = after[s..s + e].trim().to_string();
                }
            }
        }
        seen.push(href.clone());
        items.push(item_json(&href, &truncate(&title, 90), &cover, &remark));
    }
    items
}

fn catalog_url(category_id: &str, page: i64) -> String {
    let with_page = |base: String| -> String {
        if page <= 1 {
            base
        } else {
            format!("{base}&page={page}")
        }
    };
    match category_id {
        "play" | "now_month_hot" | "original" => {
            with_page(format!("{HOST}/comic/index/video?category={category_id}"))
        }
        _ => {
            if let Some(v) = category_id.strip_prefix("theme:") {
                with_page(format!(
                    "{HOST}/comic/av/relvideo?model={v}&type=theme&order=week"
                ))
            } else {
                with_page(format!("{HOST}/comic/index/video?category=play"))
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
    let mut t = decode_entities(&html[s..e]);
    if let Some((head, _)) = t.rsplit_once(" - 91视频") {
        t = head.trim().to_string();
    }
    for suf in [" 日本AV", " A片"] {
        if let Some(head) = t.strip_suffix(suf) {
            t = head.trim().to_string();
        }
    }
    t
}

/// 详情页 JSON-LD `description` 字段。
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

/// 秒数格式化为 `21:08`。
fn fmt_duration(secs: &str) -> String {
    let total: i64 = secs.parse().unwrap_or(0);
    if total <= 0 {
        return String::new();
    }
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// 详情页数字 id：`data-video="<数字>"`，兜底 embed 链接。
fn numeric_id(html: &str) -> Option<String> {
    if let Some(p) = html.find("data-video=\"") {
        let s = p + 12;
        if let Some(e) = html[s..].find('"') {
            let v = &html[s..s + e];
            if !v.is_empty() && v.chars().all(|c| c.is_ascii_digit()) {
                return Some(v.to_string());
            }
        }
    }
    if let Some(p) = html.find("/comic/index/embed?id=") {
        let s = p + 22;
        let e = html[s..]
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(html[s..].len());
        let v = &html[s..s + e];
        if !v.is_empty() {
            return Some(v.to_string());
        }
    }
    None
}

/// `#cdn-config` 的鉴权头（从页里现解析）。
fn cdn_headers(html: &str) -> (String, String) {
    let mut auth_val = String::new();
    let mut app_val = String::new();
    if let Some(p) = html.find("id=\"cdn-config\"") {
        let tag = &html[p..];
        let end = tag.find('>').unwrap_or(tag.len());
        let tag = &tag[..end];
        auth_val = attr(tag, "data-video_cdn_auth_value");
        app_val = attr(tag, "data-cdn_app");
    }
    (auth_val, app_val)
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
        return Err(ApiError::Internal("91porna 未返回影片资料".into()));
    }
    let cover = meta_content(&html, "property", "og:image");
    let mut desc = json_ld_field(&html, "description");
    let dur = fmt_duration(&meta_content(&html, "property", "video:duration"));
    let mut tags: Vec<String> = Vec::new();
    let mut rest = html.as_str();
    while let Some(p) = rest.find("property=\"video:tag\"") {
        let after = &rest[p..];
        if let Some(c) = after.find("content=\"") {
            let s = c + 9;
            if let Some(e) = after[s..].find('"') {
                let t = decode_entities(&after[s..s + e]);
                if !t.is_empty() && !tags.contains(&t) {
                    tags.push(t);
                }
            }
        }
        rest = &rest[p + 1..];
        if tags.len() >= 10 {
            break;
        }
    }
    let mut lines: Vec<String> = Vec::new();
    if !dur.is_empty() {
        lines.push(format!("时长：{dur}"));
    }
    if !tags.is_empty() {
        lines.push(format!("标签：{}", tags.join("、")));
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
    let detail_html = fetch(&page_url, &format!("{HOST}/")).await?;
    let vid = numeric_id(&detail_html)
        .ok_or_else(|| ApiError::Internal("91porna 详情页未找到数字视频 id".into()))?;
    let (cdn_auth, cdn_app) = cdn_headers(&detail_html);
    // 第一步：内嵌页打包脚本解包，拿 img 与 u。
    let embed_url = format!("{HOST}/comic/index/embed?id={vid}");
    let embed_html = fetch(&embed_url, &page_url).await?;
    let packed = extract_packed(&embed_html)
        .ok_or_else(|| ApiError::Internal("91porna 内嵌页未找到打包脚本".into()))?;
    let unpacked = dean_unpack(&packed)
        .ok_or_else(|| ApiError::Internal("91porna 内嵌页打包脚本解包失败".into()))?;
    let cap = play_params_re()
        .captures(&unpacked)
        .ok_or_else(|| ApiError::Internal("91porna 未找到 embed_play 参数".into()))?;
    let img = cap[1].to_string();
    let u = cap[2].to_string();
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() / 2100)
        .unwrap_or(0);
    // 第二步：embed_play.js 解包，拿 m3u8。
    let play_js = format!("{HOST}/index/embed_play.js?img={img}&u={u}&h=&t={t}");
    let play_body = fetch(&play_js, &embed_url).await?;
    let play_unpacked = dean_unpack(&play_body)
        .ok_or_else(|| ApiError::Internal("91porna embed_play 解包失败".into()))?;
    let url = m3u8_re()
        .find(&play_unpacked)
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| ApiError::Internal("91porna 未解出 m3u8 地址".into()))?;
    let mut header = serde_json::Map::new();
    header.insert("User-Agent".to_string(), json!(UA));
    header.insert("Referer".to_string(), json!(embed_url));
    if !cdn_auth.is_empty() {
        header.insert("x-cdn-auth".to_string(), json!(cdn_auth));
    }
    if !cdn_app.is_empty() {
        header.insert("x-cdn-app".to_string(), json!(cdn_app));
    }
    Ok(json!({"url": url, "header": Value::Object(header)}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{HOST}/comic/index/search?keyword={}",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let html = fetch(&url, &format!("{HOST}/")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items.into_iter().take(60).collect::<Vec<_>>()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 embed_play.js（video_key=446762），Node 实跑解出 m3u8。
    const PACKED_PLAY: &str = r#"eval(function(p,a,c,k,e,d){e=function(c){return(c<a?'':e(parseInt(c/a)))+((c=c%a)>35?String.fromCharCode(c+29):c.toString(36))};if(!''.replace(/^/,String)){while(c--){d[e(c)]=k[c]||e(c)}k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}('(T(){S.R("<!-- 主播放器 -->\\n<1 Q=\"P\" G O N F=\"6://E.D.5/C/B/A/z.y?t=w?2=u-0-0-s\" M-L-K=\"\">\\n    <!-- 如果支持原生 H，将使用这个 7 -->\\n    <7 r=\"6://q-p-o.m.5/l/4/4.k?2=j-i-0-h&v=3&g=0&f=e&d=c\" b=\"a/x-9\"/>\\n    您的浏览器不支持 H 播放。\\n</1>\\n\\n<!-- J 给 I 抓取结构 -->\\n<8>\\n    <1 G F=\"6://E.D.5/C/B/A/z.y?t=w?2=u-0-0-s\">\\n        <7 r=\"6://q-p-o.m.5/l/4/4.k?2=j-i-0-h&v=3&g=0&f=e&d=c\" b=\"a/x-9\"/>\\n    </1>\\n</8>")})();',56,56,'|video|auth_key||ff7ad76ba5169c24d399af375cbd9e98|cn|https|source|noscript|mpegURL|application|type|dx|via_bm|91porna|via|time|cf36503fede0982bb44840de615c3121|6aed2ee11bbd1|1793928929|m3u8|videos5|hzjvlo||hls|jhph|yd|src|2a8b741da48cf33824afa0c9cf50eee6||1793939729||1748339311446762||png|logo|images|web|static|drleao|pic|poster|controls|HLS|Googlebot|fallback|hevc|url|data|playsinline|autoplay|videoPlayer|id|write|document|function'.split('|'),0,{}))"#;

    const EXPECTED_M3U8: &str = "https://yd-jhph-hls.hzjvlo.cn/videos5/ff7ad76ba5169c24d399af375cbd9e98/ff7ad76ba5169c24d399af375cbd9e98.m3u8?auth_key=1793928929-6aed2ee11bbd1-0-cf36503fede0982bb44840de615c3121&v=3&time=0&via=91porna&via_bm=dx";

    #[test]
    fn dean_unpack_real_play_js() {
        let out = dean_unpack(PACKED_PLAY).unwrap();
        let url = m3u8_re().find(&out).unwrap().as_str().to_string();
        assert_eq!(url, EXPECTED_M3U8);
    }

    #[test]
    fn dean_unpack_garbage() {
        assert!(dean_unpack("not a packer script").is_none());
        assert!(
            dean_unpack("eval(function(p,a,c,k,e,d){}('x',62,1,'a'.split('|'),0,{}))").is_some()
        );
    }

    #[test]
    fn encode_base_spot() {
        assert_eq!(encode_base(0, 56), "0");
        assert_eq!(encode_base(35, 56), "z");
        assert_eq!(encode_base(36, 56), "A");
        assert_eq!(encode_base(56, 56), "10");
        assert_eq!(encode_base(62, 62), "10");
    }

    #[test]
    fn parse_search_card() {
        let html = r#"<ul class="video-items"><li><div class="video-item"><a class="flex" href="/comic/index/avdetail?video_key=jNZgg2wXZ1"><div class="poster"><img class="w-full" src="/static/web/images/poster_loading.svg" data-src="https://pic.drleao.cn/md-204/dcc-file/0a/0afb63ea68de5f62f4bb852410aa0b44.jpg?auth_key=1793935697-0-0-3c62e71fd027144d65e9ad45ad609844" alt="被他人之物疯狂的令和淫乱妻 FC2PPV4800841"/><div class="text-sm opacity-50 py-0.5 px-1.5 bg-black">1:44:00</div></div></a><a href="/comic/index/avdetail?video_key=jNZgg2wXZ1"><h2 class="line-clamp-2">被他人之物疯狂的令和淫乱妻 FC2PPV4800841</h2></a></div></li></ul>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["id"],
            "https://91porna.com/comic/index/avdetail?video_key=jNZgg2wXZ1"
        );
        assert_eq!(
            items[0]["title"],
            "被他人之物疯狂的令和淫乱妻 FC2PPV4800841"
        );
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://pic.drleao.cn/"));
        assert_eq!(items[0]["remark"], "1:44:00");
    }

    #[test]
    fn catalog_url_rules() {
        assert_eq!(
            catalog_url("play", 1),
            "https://91porna.com/comic/index/video?category=play"
        );
        assert_eq!(
            catalog_url("play", 2),
            "https://91porna.com/comic/index/video?category=play&page=2"
        );
        assert_eq!(
            catalog_url("theme:12", 1),
            "https://91porna.com/comic/av/relvideo?model=12&type=theme&order=week"
        );
    }

    #[test]
    fn numeric_id_from_detail() {
        let html = r#"<div id="mse" data-video="445883" data-video_id="445883"></div><a href="/comic/index/embed?id=445883">play</a>"#;
        assert_eq!(numeric_id(html).unwrap(), "445883");
        assert!(numeric_id("no id here").is_none());
    }

    #[test]
    fn cdn_headers_parse() {
        let html = r#"<div id="cdn-config" data-video_m3u8_cdn_enabled="1" data-video_cdn_auth_key="x-cdn-auth" data-video_cdn_auth_value="4aae16c3b20ec822f87518504478bb35" data-cdn_app="065"></div>"#;
        let (auth, app) = cdn_headers(html);
        assert_eq!(auth, "4aae16c3b20ec822f87518504478bb35");
        assert_eq!(app, "065");
    }

    #[test]
    fn tag_title_strips_suffix() {
        let html = "<title>短发嫩妹逼里直接连着水库 A片 - 91视频|色情视频|成人视频|91porn</title>";
        assert_eq!(tag_title(html), "短发嫩妹逼里直接连着水库");
    }

    #[test]
    fn fmt_duration_spot() {
        assert_eq!(fmt_duration("1268"), "21:08");
        assert_eq!(fmt_duration("3661"), "1:01:01");
        assert_eq!(fmt_duration(""), "");
    }
}
