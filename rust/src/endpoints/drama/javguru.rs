//! JavGuru（jav.guru）：列表页解析 + 网关解包取流。
//!
//! - 分类：latest 最新发布、cat 分类、tag 标签、maker 片商、
//!   actress 女优、rank 排行榜；子分类平铺为正式分类，id 用
//!   cat:<slug> / tag:<slug> / maker:<slug> / actress:<slug>。
//! - 列表：latest → /；rank → /most-watched-rank/；子分类 →
//!   /category|tag|maker|actress/{slug}/；翻页后缀 page/N/。
//! - 卡片：href="https://.../数字id/..." 锚点，其后 3000 字符内
//!   取 h2 标题、封面（cdn.javmiku.com 等图改写为站内路径）、
//!   番号、日期、标签。
//! - 详情：标题取 title（在 en dash 或 U+22A2 处截断），封面
//!   用 pickPoster（首张 /uploads/ 图，排除 logo 等），女优 /
//!   片商 / 标签取对应链接；剧集为 streamLines 每条线路一集。
//! - 取流：详情页找 data-localize 按钮 + var <id> 里的
//!   iframe_url（base64url 解码）得短链；resolveGateway：取
//!   window.cfg（base/rtype/cid/keys），按 keys 在 cid 元素上
//!   取属性拼串、反转，GET {base}?{rtype}r={反转串} 取 Location
//!   得网关页，Dean Edwards 解包取首个 m3u8；play 逐线路试到
//!   可播为止（优先上次成功的线路），分片在死域名上判死。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://jav.guru";
const GATE: &str = "https://javclan.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const DEAD_SEG_HOSTS: [&str; 6] = [
    "googleusercontent.com",
    "googleapis.com",
    "googlevideo.com",
    "turbosplayer.com",
    "turbo-splayer.com",
    "google.com",
];

static LAST_GOOD: Mutex<Option<String>> = Mutex::new(None);

fn headers(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    req.header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{HOST}/"))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = headers(client()?.get(url))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JavGuru 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 800 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("JavGuru 页面异常（疑似盾拦截）".into()));
    }
    Ok(text)
}

fn clean(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let t = tag_re.replace_all(s, " ");
    let t = t
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace('\u{a0}', " ");
    ws_re.replace_all(&t, " ").trim().to_string()
}

fn enc_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

/// cdn 图改写为站内路径。
fn fix_pic(u: &str) -> String {
    if !u.starts_with("http") {
        return u.to_string();
    }
    for cdn in ["cdn.javmiku.com", "cdn.javsts.com", "cdn.javnorth.com"] {
        if u.contains(cdn) {
            if let Some(pos) = u.find(cdn) {
                let rest = &u[pos + cdn.len()..];
                if rest.starts_with('/') {
                    return format!("{HOST}{rest}");
                }
            }
        }
    }
    u.to_string()
}

/// 配对括号扫描：从 start 处的 { 开始取完整 JSON 对象子串。
fn balanced_json(s: &str, start: usize) -> Option<String> {
    let bytes = s.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c == '\\' {
            i += 2;
            continue;
        }
        if in_str {
            if c == '"' {
                in_str = false;
            }
        } else if c == '"' {
            in_str = true;
        } else if c == '{' {
            depth += 1;
        } else if c == '}' {
            if depth - 1 == 0 {
                return Some(s[start..=i].to_string());
            }
            depth -= 1;
        }
        i += 1;
    }
    None
}

const B62: &[u8; 62] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn enc_b62(mut n: u64, base: u64) -> String {
    if n < base {
        return (B62[n as usize] as char).to_string();
    }
    let mut out = String::new();
    while n >= base {
        out.insert(0, B62[(n % base) as usize] as char);
        n /= base;
    }
    out.insert(0, B62[n as usize] as char);
    out
}

/// Dean Edwards packer 解包：P_PACK 正则取 p/a/c/k，base62 词表逆序替换。
fn dean_unpack(packed: &str) -> Option<String> {
    let re = Regex::new(r"(?s)\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)").unwrap();
    let c = re.captures(packed)?;
    let mut p = c[1].to_string();
    let a: u64 = c[2].parse().ok()?;
    let count: u64 = c[3].parse().ok()?;
    let k: Vec<&str> = c[4].split('|').collect();
    let mut i = count;
    while i > 0 {
        i -= 1;
        let word = enc_b62(i, a);
        let kw = k.get(i as usize).copied().unwrap_or("");
        if kw.is_empty() {
            continue;
        }
        let wre = Regex::new(&format!(r"\b{}\b", regex::escape(&word))).unwrap();
        p = wre.replace_all(&p, kw).to_string();
    }
    Some(p)
}

/// URL 相对拼绝对（根相对按 origin，相对按目录）。
fn join_url(base: &str, rel: &str) -> String {
    if rel.starts_with("http") {
        return rel.to_string();
    }
    if let Ok(b) = url::Url::parse(base) {
        if let Ok(j) = b.join(rel) {
            return j.to_string();
        }
    }
    rel.to_string()
}

/// cfg 内单引号字段：key: 'value'。
fn cfg_field(cfg: &str, key: &str) -> Option<String> {
    let re = Regex::new(&format!(r"{}\s*:\s*'([^']*)'", regex::escape(key))).unwrap();
    re.captures(cfg).map(|c| c[1].to_string())
}

/// 网关解包：短链 → window.cfg → 反转串 → Location → 网关页 → 解包取 m3u8。
async fn resolve_gateway(url: &str) -> Option<String> {
    let mut page = String::new();
    for _ in 0..2 {
        match get_text(url).await {
            Ok(t) if t.len() >= 500 => {
                page = t;
                break;
            }
            _ => continue,
        }
    }
    if page.len() < 500 {
        return None;
    }
    let cfg_pos = page.find("window.cfg")?;
    let brace = page[cfg_pos..].find('{')? + cfg_pos;
    let cfg = balanced_json(&page, brace)?;
    let base = cfg_field(&cfg, "base").unwrap_or_else(|| format!("{HOST}/searcho/"));
    let rtype = cfg_field(&cfg, "rtype").unwrap_or_else(|| "x".to_string());
    let cid = cfg_field(&cfg, "cid")?;
    let keys_re = Regex::new(r"keys\s*:\s*\[([^\]]*)\]").unwrap();
    let keys_raw = keys_re.captures(&cfg).map(|c| c[1].to_string())?;
    let key_re = Regex::new(r"'([^']+)'").unwrap();
    let keys: Vec<String> = key_re
        .captures_iter(&keys_raw)
        .map(|c| c[1].to_string())
        .collect();
    if keys.is_empty() {
        return None;
    }
    let id_pos = page.find(&format!("id=\"{cid}\""))?;
    let tag_start = page[..id_pos].rfind('<')?;
    let tag_end = page[id_pos..].find('>')? + id_pos;
    let tag = &page[tag_start..=tag_end];
    let mut concat = String::new();
    for k in &keys {
        let are = Regex::new(&format!(r#"{}\s*=\s*["']([^"']*)["']"#, regex::escape(k))).unwrap();
        if let Some(c) = are.captures(tag) {
            concat.push_str(&c[1]);
        }
    }
    if concat.is_empty() {
        return None;
    }
    let rev: String = concat.chars().rev().collect();
    let gw_url = format!("{base}?{rtype}r={rev}");
    let nofollow = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
        .ok()?;
    let resp = headers(nofollow.get(&gw_url)).send().await.ok()?;
    let loc = resp
        .headers()
        .get("location")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())?;
    let gw_page_url = if let Some(rest) = loc.strip_prefix("//") {
        format!("https:{rest}")
    } else if loc.starts_with('/') {
        format!("{GATE}{loc}")
    } else {
        loc
    };
    let mut gpage = String::new();
    for _ in 0..2 {
        match get_text(&gw_page_url).await {
            Ok(t) if t.len() >= 800 => {
                gpage = t;
                break;
            }
            _ => continue,
        }
    }
    if gpage.len() < 800 {
        return None;
    }
    let unpacked = dean_unpack(&gpage).unwrap_or_default();
    let m3u8_re = Regex::new(r#"https?://[^\s"'\\]+\.m3u8[^\s"'\\]*"#).unwrap();
    if let Some(m) = m3u8_re.find(&unpacked) {
        return Some(m.as_str().to_string());
    }
    let txt_re = Regex::new(r#"https?://[^\s"'\\]+master\.txt[^\s"'\\]*"#).unwrap();
    if let Some(m) = txt_re.find(&unpacked) {
        return Some(m.as_str().to_string());
    }
    m3u8_re.find(&gpage).map(|m| m.as_str().to_string())
}

/// 可播校验：清单含 EXT-X-STREAM-INF 时下钻变体清单，取首分片
/// Range 0-2047 得 200 字节以上，且分片 host 不在死域名表。
async fn playable(m3u8_url: &str) -> bool {
    let fetch = |u: String| async move {
        let resp = headers(client().ok()?.get(&u)).send().await.ok()?;
        if resp.status().as_u16() != 200 {
            return None;
        }
        resp.text().await.ok()
    };
    let text = match fetch(m3u8_url.to_string()).await {
        Some(t) => t,
        None => return false,
    };
    if !text.contains("#EXTM3U") {
        return false;
    }
    let mut list_url = m3u8_url.to_string();
    let mut list_text = text;
    if list_text.contains("#EXT-X-STREAM-INF") {
        let variant = list_text
            .lines()
            .map(|l| l.trim())
            .find(|l| !l.is_empty() && !l.starts_with('#'));
        let variant = match variant {
            Some(v) => v.to_string(),
            None => return false,
        };
        let vurl = join_url(&list_url, &variant);
        match fetch(vurl.clone()).await {
            Some(t) if t.contains("#EXTM3U") => {
                list_url = vurl;
                list_text = t;
            }
            _ => return false,
        }
    }
    let seg = list_text
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.is_empty() && !l.starts_with('#'));
    let seg = match seg {
        Some(s) => s.to_string(),
        None => return false,
    };
    let seg_url = join_url(&list_url, &seg);
    let host = url::Url::parse(&seg_url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_string()))
        .unwrap_or_default();
    if DEAD_SEG_HOSTS.iter().any(|d| host.ends_with(d)) {
        return false;
    }
    let cli = match client() {
        Ok(c) => c,
        Err(_) => return false,
    };
    let resp = match headers(cli.get(&seg_url))
        .header("Range", "bytes=0-2047")
        .send()
        .await
    {
        Ok(r) => r,
        Err(_) => return false,
    };
    let bytes = resp.bytes().await.unwrap_or_default();
    bytes.len() > 200
}

/// 详情页线路：data-localize 按钮 + var <id> 里的 iframe_url（base64url）。
fn stream_lines(html: &str) -> Vec<(String, String)> {
    let mut lines = Vec::new();
    let re =
        Regex::new(r#"data-localize="([a-z0-9]{6,24})"[^>]*>\s*(STREAM\s+[A-Z]{2})\s*<"#).unwrap();
    for c in re.captures_iter(html) {
        let id = c[1].to_string();
        let name = c[2].replace("STREAM", "").trim().to_string();
        if lines.len() >= 8 {
            break;
        }
        let var_pat = format!("var {id} = ");
        let vpos = match html.find(&var_pat) {
            Some(p) => p,
            None => continue,
        };
        let window = &html[vpos..(vpos + 3000).min(html.len())];
        let ire = Regex::new(r#""iframe_url"\s*:\s*"([^"]+)""#).unwrap();
        let b64 = match ire.captures(window) {
            Some(x) => x[1].to_string(),
            None => continue,
        };
        let std = b64.replace('-', "+").replace('_', "/");
        let padded = format!("{}{}", std, "=".repeat((4 - std.len() % 4) % 4));
        use base64::Engine;
        let decoded = match base64::engine::general_purpose::STANDARD.decode(&padded) {
            Ok(d) => d,
            Err(_) => continue,
        };
        let url = String::from_utf8_lossy(&decoded).trim().to_string();
        if url.starts_with("http") {
            lines.push((name, url));
        }
    }
    lines
}

fn list_url(category_id: &str, page: i64) -> String {
    let suffix = format!("page/{page}/");
    match category_id {
        "latest" => format!("{HOST}/{suffix}"),
        "rank" => format!("{HOST}/most-watched-rank/{suffix}"),
        _ => {
            if let Some(v) = category_id.strip_prefix("cat:") {
                format!("{HOST}/category/{v}/{suffix}")
            } else if let Some(v) = category_id.strip_prefix("tag:") {
                format!("{HOST}/tag/{v}/{suffix}")
            } else if let Some(v) = category_id.strip_prefix("maker:") {
                format!("{HOST}/maker/{v}/{suffix}")
            } else if let Some(v) = category_id.strip_prefix("actress:") {
                format!("{HOST}/actress/{v}/{suffix}")
            } else {
                format!("{HOST}/{suffix}")
            }
        }
    }
}

fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let re = Regex::new(r#"href="(https?://[^/"]+/\d{5,}/[^"]+/)"#).unwrap();
    for c in re.captures_iter(html) {
        let href = c[1].to_string();
        let m = c.get(0).unwrap();
        let end = (m.end() + 3000).min(html.len());
        let seg = &html[m.end()..end];
        let title_re = Regex::new(r#"<h2[^>]*>\s*<a[^>]*title="([^"]+)""#).unwrap();
        let mut title = title_re
            .captures(seg)
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
        if title.is_empty() {
            let alt_re = Regex::new(r#"alt="([^"]+)""#).unwrap();
            title = alt_re
                .captures(seg)
                .map(|x| clean(&x[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
            title = h1_re
                .captures(html)
                .map(|x| clean(&x[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            continue;
        }
        let img_re =
            Regex::new(r#"(?:data-src|src)="(https?://[^"]+?\.(?:jpg|jpeg|png|webp)[^"]*)""#)
                .unwrap();
        let mut pic = img_re
            .captures(seg)
            .map(|x| fix_pic(&x[1]))
            .unwrap_or_default();
        if pic.is_empty() {
            let any_re = Regex::new(r#"(?:data-src|src)="(https?://[^"]+)""#).unwrap();
            pic = any_re
                .captures(seg)
                .map(|x| fix_pic(&x[1]))
                .unwrap_or_default();
        }
        let code_re = Regex::new(r"\[([A-Z0-9]{2,12})\]").unwrap();
        let code = code_re
            .captures(&title)
            .map(|x| x[1].to_string())
            .unwrap_or_else(|| {
                // 站内标题常以裸番号开头（如 T38-075 Sample），无
                // 方括号时也取开头的番号，否则备注只能退回日期。
                let lead_re = Regex::new(r"^([A-Z]{1,5}[0-9]{2,4}-[0-9]{2,6})").unwrap();
                lead_re
                    .captures(&title)
                    .map(|x| x[1].to_string())
                    .unwrap_or_default()
            });
        let date_re = Regex::new(r#"class="date">([^<]{1,30})<"#).unwrap();
        let date = date_re
            .captures(seg)
            .map(|x| clean(&x[1]))
            .unwrap_or_default();
        let tag_re =
            Regex::new(r#"<span[^>]*class="[^"]*tag[^"]*"[^>]*>([^<]{1,14})</span>"#).unwrap();
        let tags: Vec<String> = tag_re
            .captures_iter(seg)
            .map(|x| clean(&x[1]))
            .filter(|t| !t.is_empty())
            .collect();
        let mut remark = if !code.is_empty() {
            code.clone()
        } else {
            date.clone()
        };
        if !tags.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&tags.join("·"));
        }
        if remark.chars().count() > 36 {
            remark = remark.chars().take(36).collect();
        }
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

/// 详情封面：首张 /uploads/ 图，排除 logo / favicon / sprite /
/// avatar / placeholder / banner / base64。
fn pick_poster(html: &str) -> String {
    let img_re = Regex::new(r#"(?:data-src|src)="(https?://[^"]+)""#).unwrap();
    let mut first = String::new();
    for c in img_re.captures_iter(html) {
        let u = fix_pic(&c[1]);
        if first.is_empty() {
            first = u.clone();
        }
        if !u.contains("/uploads/") {
            continue;
        }
        let low = u.to_lowercase();
        if low.contains("logo")
            || low.contains("favicon")
            || low.contains("sprite")
            || low.contains("avatar")
            || low.contains("placeholder")
            || low.contains("banner")
            || low.contains("base64")
        {
            continue;
        }
        return u;
    }
    first
}

/// 取 /actress/、/maker/、/tag/ 链接的 slug 转空格文案，上限 n 条。
fn collect_links(html: &str, prefix: &str, n: usize) -> Vec<String> {
    let re = Regex::new(&format!(
        r#"href="[^"]*{}/([^"/]+)/?""#,
        regex::escape(prefix)
    ))
    .unwrap();
    let mut out: Vec<String> = Vec::new();
    for c in re.captures_iter(html) {
        let slug = c[1].to_string();
        let text = slug.replace('-', " ");
        if !text.is_empty() && !out.contains(&text) {
            out.push(text);
        }
        if out.len() >= n {
            break;
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("latest", "最新发布"),
        category_json("cat", "分类"),
        category_json("tag", "标签"),
        category_json("maker", "片商"),
        category_json("actress", "女优"),
        category_json("rank", "排行榜"),
    ];
    let cats: [(&str, &str); 7] = [
        ("jav", "JAV 正片"),
        ("4k", "4K"),
        ("FC2", "FC2"),
        ("decensored", "无码流出"),
        ("amateur", "素人"),
        ("english-subbed", "英文字幕"),
        ("idol", "偶像"),
    ];
    for (slug, name) in cats {
        list.push(category_json(&format!("cat:{slug}"), name));
    }
    let tags: [(&str, &str); 63] = [
        ("3p", "3P"),
        ("amateur", "素人"),
        ("anal", "肛交"),
        ("back", "后背位"),
        ("beautiful-girl", "美女"),
        ("big-butt", "巨臀"),
        ("big-tits", "巨乳"),
        ("blowjob", "口交"),
        ("boobs", "胸器"),
        ("bukkake", "颜射"),
        ("busty-fetish", "爆乳癖"),
        ("cosplay", "角色扮演"),
        ("cowgirl", "女上位"),
        ("creampie", "中出"),
        ("cuckold", "绿帽"),
        ("date", "约会"),
        ("debut-production", "出道作"),
        ("deep-throat", "深喉"),
        ("dirty-talk", "淫语"),
        ("documentary", "纪录片"),
        ("drama", "剧情"),
        ("facials", "颜射集"),
        ("female-boss", "女上司"),
        ("female-investigator", "女搜查官"),
        ("gal", "辣妹"),
        ("girl", "少女"),
        ("glasses", "眼镜"),
        ("hot-spring", "温泉"),
        ("hotel", "酒店"),
        ("humiliation", "羞辱"),
        ("kimono", "和服"),
        ("kiss", "亲吻"),
        ("leg-fetish", "美腿癖"),
        ("lesbian", "女同"),
        ("lesbian-kiss", "女同接吻"),
        ("m-girl", "M女"),
        ("married", "人妻"),
        ("masturbation-support", "自慰支援"),
        ("mature", "熟女"),
        ("mature-woman", "成熟女性"),
        ("mini", "迷你"),
        ("mother", "母亲"),
        ("nasty", "淫荡"),
        ("nurse", "护士"),
        ("orgasm", "高潮"),
        ("orgy", "乱交"),
        ("original-collaboration", "原创合作"),
        ("otaku", "宅"),
        ("panty-flash", "走光"),
        ("pantyhose", "丝袜"),
        ("petite", "娇小"),
        ("pov", "主观视角"),
        ("prostitutes", "娼妇"),
        ("rape", "强制"),
        ("shaved", "剃毛"),
        ("slender", "纤细"),
        ("slut", "荡妇"),
        ("solowork", "单体作品"),
        ("squirting", "潮吹"),
        ("titty-fuck", "乳交"),
        ("toy", "玩具"),
        ("travel", "旅行"),
        ("uniform", "制服"),
    ];
    for (slug, name) in tags {
        list.push(category_json(&format!("tag:{slug}"), name));
    }
    let makers: [(&str, &str); 13] = [
        ("s1-no-1-style", "S1"),
        ("moodyz", "MOODYZ"),
        ("idea-pocket", "IDEA POCKET"),
        ("sod-create", "SOD Create"),
        ("attackers", "ATTACKERS"),
        ("madonna", "Madonna"),
        ("prestige", "PRESTIGE"),
        ("wanz-factory", "WANZ"),
        ("das", "ダスッ！"),
        ("glory-quest", "GLORY QUEST"),
        ("hunter", "Hunter"),
        ("caribbeancom", "加勒比"),
        ("k-m-produce", "KMP"),
    ];
    for (slug, name) in makers {
        list.push(category_json(&format!("maker:{slug}"), name));
    }
    let actresses: [(&str, &str); 14] = [
        ("hatano-yui", "波多野結衣"),
        ("hasumi-kurea", "蓮實克蕾雅"),
        ("kobayakawa-reiko", "小早川怜子"),
        ("ootsuki-hibiki", "大槻ひびき"),
        ("kitagawa-erika", "北川エリカ"),
        ("morisawa-kana", "森沢かな"),
        ("misono-waka", "美園和花"),
        ("hamasaki-mao", "濱崎真緒"),
        ("minazuki-hikaru", "水無月ヒカル"),
        ("rukawa-rina", "Rukawa Rina"),
        ("shinoda-yu", "Shinoda Yu"),
        ("tenma-yui", "Tenma Yui"),
        ("yayoi-mizuki", "Yayoi Mizuki"),
        ("otsu-arisu", "Otsu Arisu"),
    ];
    for (slug, name) in actresses {
        list.push(category_json(&format!("actress:{slug}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = get_text(&list_url(category_id, page)).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": items.len() >= 48}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{HOST}{series_id}")
    };
    let html = get_text(&url).await?;
    let mut title = {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").unwrap();
        t_re.captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default()
    };
    for sep in ['\u{2013}', '\u{22a2}'] {
        if let Some(pos) = title.find(sep) {
            title.truncate(pos);
            title = title.trim().to_string();
            break;
        }
    }
    if title.is_empty() {
        let h1_re = Regex::new(r"(?s)<h1[^>]*>(.*?)</h1>").unwrap();
        title = h1_re
            .captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default();
    }
    if title.is_empty() {
        title = "JavGuru".to_string();
    }
    let cover = pick_poster(&html);
    let code_re = Regex::new(r"\[([A-Z0-9]{2,12})\]").unwrap();
    let code = code_re
        .captures(&title)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let actresses = collect_links(&html, "/actress/", 6);
    let makers = collect_links(&html, "/maker/", 3);
    let tags = collect_links(&html, "/tag/", 10);
    let lines = stream_lines(&html);
    let mut episodes = Vec::new();
    for (name, link) in &lines {
        episodes.push(episode_json(link, name, series_id));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(&url, "正片", series_id));
    }
    let mut syn = String::from(
        "站源：JavGuru（jav.guru），免登录直取\n取流：网关解包，多线路逐条试播，首个可播线路为准",
    );
    if !code.is_empty() {
        syn.push_str(&format!("\n番号：{code}"));
    }
    if !actresses.is_empty() {
        syn.push_str(&format!("\n女优：{}", actresses.join("、")));
    }
    if !makers.is_empty() {
        syn.push_str(&format!("\n片商：{}", makers.join("、")));
    }
    if !tags.is_empty() {
        syn.push_str(&format!("\n标签：{}", tags.join("、")));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": syn,
        "extra": {"vod_play_from": "JavGuru"},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let header = json!({"User-Agent": UA, "Referer": format!("{HOST}/")});
    if video_id.contains(".m3u8") || video_id.contains(".mp4") {
        return Ok(json!({"url": video_id, "header": header}));
    }
    let started = Instant::now();
    let budget = Duration::from_secs(45);
    if video_id.contains("jav.guru/searcho") {
        if let Ok(Some(m3u8)) =
            tokio::time::timeout(Duration::from_millis(14000), resolve_gateway(video_id)).await
        {
            if tokio::time::timeout(Duration::from_secs(8), playable(&m3u8))
                .await
                .unwrap_or(false)
            {
                return Ok(json!({"url": m3u8, "header": header}));
            }
        }
        return Err(ApiError::Internal("JavGuru 网关线路未取到可播地址".into()));
    }
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{HOST}{video_id}")
    };
    let html = get_text(&url).await?;
    let mut lines = stream_lines(&html);
    if lines.is_empty() {
        return Err(ApiError::Internal("JavGuru 详情页未找到播放线路".into()));
    }
    if let Some(last) = LAST_GOOD.lock().unwrap().clone() {
        if let Some(pos) = lines.iter().position(|(_, l)| *l == last) {
            let item = lines.remove(pos);
            lines.insert(0, item);
        }
    }
    for (_, link) in &lines {
        if started.elapsed() > budget {
            break;
        }
        let m3u8 =
            match tokio::time::timeout(Duration::from_millis(11000), resolve_gateway(link)).await {
                Ok(Some(u)) => u,
                _ => continue,
            };
        if started.elapsed() > budget {
            break;
        }
        let ok = tokio::time::timeout(Duration::from_secs(8), playable(&m3u8))
            .await
            .unwrap_or(false);
        if ok {
            *LAST_GOOD.lock().unwrap() = Some(link.clone());
            return Ok(json!({"url": m3u8, "header": header}));
        }
    }
    Err(ApiError::Internal(
        "JavGuru 全部线路均未取到可播地址".into(),
    ))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let html = get_text(&format!("{HOST}/page/1/?s={}", enc_path(query))).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_url_shapes() {
        assert_eq!(list_url("latest", 1), "https://jav.guru/page/1/");
        assert_eq!(
            list_url("rank", 2),
            "https://jav.guru/most-watched-rank/page/2/"
        );
        assert_eq!(
            list_url("cat:jav", 1),
            "https://jav.guru/category/jav/page/1/"
        );
        assert_eq!(
            list_url("actress:hatano-yui", 3),
            "https://jav.guru/actress/hatano-yui/page/3/"
        );
    }

    #[test]
    fn dean_unpack_replaces() {
        let packed = "eval(function(p,a,c,k,e,d){}('0 1 2',10,3,'x|y|z'.split('|')))";
        let out = dean_unpack(packed).unwrap();
        assert_eq!(out, "x y z");
    }

    #[test]
    fn enc_b62_values() {
        assert_eq!(enc_b62(0, 62), "0");
        assert_eq!(enc_b62(61, 62), "Z");
        assert_eq!(enc_b62(62, 62), "10");
    }

    #[test]
    fn parse_cards_sample() {
        let html = r#"<a href="https://jav.guru/12345/title/"><h2><a title="T38-075 Sample">x</a></h2><img data-src="https://cdn.javmiku.com/uploads/a-550x374.jpg"><span class="date">12 Nov, 25</span></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["cover"], "https://jav.guru/uploads/a-550x374.jpg");
        assert_eq!(items[0]["remark"], "T38-075");
    }

    #[test]
    fn stream_lines_sample() {
        let b64 = "aHR0cHM6Ly9leGFtcGxlLmNvbS9pZnJhbWU=";
        let html = format!(
            "<a data-localize=\"abc123\" href=\"#\">STREAM SB</a><script>var abc123 = {{\"iframe_url\":\"{b64}\"}};</script>"
        );
        let lines = stream_lines(&html);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].0, "SB");
        assert_eq!(lines[0].1, "https://example.com/iframe");
    }
}
