//! kuaikan：快看漫画（www.kuaikanmanhua.com）。
//!
//! Nuxt SSR 站：列表 / 详情数据藏在 `__NUXT__=(function(a,b,...){...})(v1,v2,...)`
//! 内嵌调用里，参数名按位置映射到值（个别 Array(n) / void 0 占位跳过）。
//! 详情章节在函数体 `comics:[...]` 里、排行在 `topics:[...]` 里、
//! 分类在 `dataList:[...]` 里：键是裸键、值是参数名或字面量，经映射还原。
//! 章节图片走 /webs/comic-next/{id} 的 comic_images 数组；图片头
//! Referer: https://www.kuaikanmanhua.com + 桌面 UA。搜索封面取
//! __NUXT__ 数据里 topics.hit 数组，按 id 映射 cover_image_url，
//! 取不到留空（不用按值顺序硬对位置，会错位）。
//! 付费章节只标不绕：locked 的章节标题后加“（付费）”，不尝试解密或绕过。
//! 分集模型没有 status 位，标记只能落在标题上。
//! 分类照站原样写（2026-11-05 用户铁律）：13 个排行 + 6 个题材标签
//! 一个不少，不按站名/分类名/标题删；付费标记是付费边界，不是标签。

use std::collections::HashMap;

use flate2::read::GzDecoder;
use regex::Regex;
use serde_json::{json, Value};
use std::io::Read as _;

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://www.kuaikanmanhua.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Safari/537.36";

const CATEGORIES: [(&str, &str); 19] = [
    ("rank:9", "人气"),
    ("rank:2", "新作"),
    ("rank:7", "飙升"),
    ("rank:4", "畅销"),
    ("rank:11", "韩漫"),
    ("rank:10", "日漫"),
    ("rank:6", "恋爱"),
    ("rank:25", "剧情"),
    ("rank:13", "投稿"),
    ("rank:12", "完结"),
    ("rank:28", "免费"),
    ("rank:29", "等免"),
    ("rank:27", "月票"),
    ("tag:20", "恋爱"),
    ("tag:46", "古风"),
    ("tag:80", "穿越"),
    ("tag:63", "玄幻"),
    ("tag:65", "悬疑"),
    ("tag:67", "热血"),
];

fn must_re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|_| Regex::new("$^").unwrap())
}

fn decode_entities(s: &str) -> String {
    let dec = must_re(r"&#(\d+);");
    let mut out = dec
        .replace_all(s, |caps: &regex::Captures| {
            caps[1]
                .parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    let hex = must_re(r"&#x([0-9a-fA-F]+);");
    out = hex
        .replace_all(&out, |caps: &regex::Captures| {
            u32::from_str_radix(&caps[1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    for (from, to) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&amp;", "&"),
    ] {
        out = out.replace(from, to);
    }
    out
}

fn strip_tags(raw: &str) -> String {
    must_re(r"<[^>]+>").replace_all(raw, "").to_string()
}

fn clean_collapse(raw: &str) -> String {
    let decoded = decode_entities(&strip_tags(raw));
    let collapsed = must_re(r"\s+").replace_all(&decoded, " ");
    collapsed.replace('\u{a0}', " ").trim().to_string()
}

fn pct_encode_segment(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~'
            | b'/' => out.push(*b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 与 aabook 的 _fetch 同款：单次请求，失败空串；gzip 魔数开头即解压。
async fn fetch(path: &str) -> String {
    let Ok(c) = client() else {
        return String::new();
    };
    let url = format!("{BASE_URL}{path}");
    let resp = c
        .get(&url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .header("Referer", format!("{BASE_URL}/"))
        .send()
        .await;
    let Ok(resp) = resp else {
        return String::new();
    };
    let Ok(bytes) = resp.bytes().await else {
        return String::new();
    };
    if bytes.len() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b {
        let mut decoder = GzDecoder::new(&bytes[..]);
        let mut out = Vec::new();
        if decoder.read_to_end(&mut out).is_ok() {
            return String::from_utf8_lossy(&out).into_owned();
        }
        return String::new();
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

/// 从 start（开括号之后一位）向后扫，遇开括号 depth+1、闭括号 depth-1，
/// depth 回 0 的位置即配对闭括号；字符串内的括号不算（只认双引号串）。
fn scan_close(text: &str, start: usize, open: u8, close: u8) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut depth = 1i32;
    let mut in_str = false;
    let mut esc = false;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else if b == b'"' {
            in_str = true;
        } else if b == open {
            depth += 1;
        } else if b == close {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// 按顶层分隔符切分：字符串内的分隔符与嵌套括号内的分隔符都不切。
fn split_top_level(text: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    let mut cur = String::new();
    for c in text.chars() {
        if in_str {
            cur.push(c);
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            }
            continue;
        }
        match c {
            '"' => {
                in_str = true;
                cur.push(c);
            }
            '(' | '[' | '{' => {
                depth += 1;
                cur.push(c);
            }
            ')' | ']' | '}' => {
                depth -= 1;
                cur.push(c);
            }
            _ if c == sep && depth == 0 => {
                out.push(std::mem::take(&mut cur));
            }
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out
}

/// JS 双引号串解码：\\、\"、\/、\n、\t 与 \uXXXX（站方用 \u002F 藏 /）。
fn decode_js_string(s: &str) -> String {
    let mut out = String::new();
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
            Some('u') => {
                let hex: String = chars.by_ref().take(4).collect();
                if let Ok(n) = u32::from_str_radix(&hex, 16) {
                    if let Some(ch) = char::from_u32(n) {
                        out.push(ch);
                    }
                }
            }
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn is_ident(t: &str) -> bool {
    let mut chars = t.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' || c == '$' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
}

/// 宽松值还原：参数名查映射表（占位跳过后查不到即空），其余按 JSON 解析。
fn resolve_token(tok: &str, map: &HashMap<String, Value>) -> Value {
    let t = tok.trim();
    if t.is_empty() {
        return Value::Null;
    }
    if t.starts_with('"') {
        if let Ok(v) = serde_json::from_str::<Value>(t) {
            return v;
        }
        return Value::String(decode_js_string(t.trim_matches('"')));
    }
    if t.starts_with('{') || t.starts_with('[') {
        return serde_json::from_str::<Value>(t).unwrap_or(Value::Null);
    }
    if is_ident(t) {
        return map.get(t).cloned().unwrap_or(Value::Null);
    }
    serde_json::from_str::<Value>(t).unwrap_or(Value::Null)
}

fn value_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => {
            if *b {
                "true".to_string()
            } else {
                "false".to_string()
            }
        }
        _ => String::new(),
    }
}

fn get_s(obj: &HashMap<String, Value>, key: &str) -> String {
    obj.get(key).map(value_str).unwrap_or_default()
}

/// __NUXT__ 内嵌调用的解析结果：映射表 + 函数体文本。
struct Nuxt {
    map: HashMap<String, Value>,
    body: String,
}

fn parse_nuxt(html: &str) -> Option<Nuxt> {
    let marker = "__NUXT__=(function(";
    let mstart = html.find(marker)?;
    let params_start = mstart + marker.len();
    let params_end = html[params_start..].find(')')? + params_start;
    let params: Vec<&str> = html[params_start..params_end].split(',').collect();
    let body_rel = html[params_end..].find('{')?;
    let body_start = params_end + body_rel;
    let body_end = scan_close(html, body_start + 1, b'{', b'}')?;
    let body = html[body_start..=body_end].to_string();
    let vals_rel = html[body_end + 1..].find('(')?;
    let vals_start = body_end + 1 + vals_rel;
    let vals_end = scan_close(html, vals_start + 1, b'(', b')')?;
    let inner = &html[vals_start + 1..vals_end];
    let tokens = split_top_level(inner, ',');
    let mut map: HashMap<String, Value> = HashMap::new();
    for (name, tok) in params.iter().zip(tokens.iter()) {
        let t = tok.trim();
        if t.starts_with("Array(") || t == "void 0" || t == "undefined" {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(t) {
            map.insert(name.to_string(), v);
        }
    }
    Some(Nuxt { map, body })
}

/// 取函数体内 `key:[...]` 数组的内部文本（不含外层方括号）。
fn extract_array(body: &str, key: &str) -> Option<String> {
    let pat = format!("{key}[");
    let at = body.find(&pat)?;
    let start = at + pat.len();
    let end = scan_close(body, start, b'[', b']')?;
    Some(body[start..end].to_string())
}

/// 取函数体内 `key:{...}` 对象的完整文本（含外层花括号）。
fn extract_object(body: &str, key: &str) -> Option<String> {
    let pat = format!("{key}{{");
    let at = body.find(&pat)?;
    let start = at + key.len();
    let end = scan_close(body, start + 1, b'{', b'}')?;
    Some(body[start..=end].to_string())
}

/// 宽松对象按顶层逗号切 `键:值` 对，返回（键，原始值文本）。
fn loose_pairs(text: &str) -> Vec<(String, String)> {
    let trimmed = text.trim();
    let inner = trimmed.strip_prefix('{').unwrap_or(trimmed);
    let inner = inner.strip_suffix('}').unwrap_or(inner);
    let mut out = Vec::new();
    for pair in split_top_level(inner, ',') {
        if let Some((k, v)) = pair.split_once(':') {
            let key = k.trim().to_string();
            if !key.is_empty() {
                out.push((key, v.trim().to_string()));
            }
        }
    }
    out
}

/// 宽松对象数组：每项按裸键解析、值经映射表还原。
fn parse_loose_objects(inner: &str, map: &HashMap<String, Value>) -> Vec<HashMap<String, Value>> {
    let mut out = Vec::new();
    for tok in split_top_level(inner, ',') {
        let t = tok.trim();
        if !t.starts_with('{') {
            continue;
        }
        let resolved: HashMap<String, Value> = loose_pairs(t)
            .iter()
            .map(|(k, v)| (k.clone(), resolve_token(v, map)))
            .collect();
        out.push(resolved);
    }
    out
}

/// 付费判定：locked / is_pay_comic 为真，或字符串不是 "false" / "0" / 空。
fn is_locked(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::String(s) => !(s.is_empty() || s == "false" || s == "0"),
        Value::Number(n) => n.as_i64().map(|i| i != 0).unwrap_or(false),
        _ => false,
    }
}

fn topic_id_of(series_id: &str) -> String {
    let s = series_id.trim().trim_matches('/');
    let last = s.rsplit('/').next().unwrap_or("");
    let last = last.split(['?', '#']).next().unwrap_or("");
    last.chars().filter(|c| c.is_ascii_digit()).collect()
}

fn find_nickname(body: &str, param: &str) -> String {
    let pat = format!(
        r#"{}\.nickname="((?:[^"\\]|\\.)*)""#,
        regex::escape(param)
    );
    match must_re(&pat).captures(body) {
        Some(caps) => decode_js_string(&caps[1]),
        None => String::new(),
    }
}

fn parse_rank_items(html: &str) -> Vec<Value> {
    let Some(nuxt) = parse_nuxt(html) else {
        return Vec::new();
    };
    let Some(arr) = extract_array(&nuxt.body, "topics:") else {
        return Vec::new();
    };
    parse_loose_objects(&arr, &nuxt.map)
        .iter()
        .filter_map(|o| {
            let id = get_s(o, "id");
            if id.is_empty() {
                return None;
            }
            let title = get_s(o, "title");
            if title.is_empty() {
                return None;
            }
            let mut cover = get_s(o, "cover_image_url");
            if cover.is_empty() {
                cover = get_s(o, "vertical_image_url");
            }
            let remark = get_s(o, "update_remind");
            Some(item_json(&id, &title, &cover, &remark))
        })
        .collect()
}

fn parse_tag_items(html: &str) -> Vec<Value> {
    let Some(nuxt) = parse_nuxt(html) else {
        return Vec::new();
    };
    let Some(arr) = extract_array(&nuxt.body, "dataList:") else {
        return Vec::new();
    };
    parse_loose_objects(&arr, &nuxt.map)
        .iter()
        .filter_map(|o| {
            let id = get_s(o, "id");
            if id.is_empty() {
                return None;
            }
            let title = get_s(o, "title");
            if title.is_empty() {
                return None;
            }
            let mut cover = get_s(o, "cover_image_url");
            if cover.is_empty() {
                cover = get_s(o, "vertical_image_url");
            }
            let mut remark = get_s(o, "author_name");
            if remark.is_empty() {
                remark = get_s(o, "latest_comic_title");
            }
            Some(item_json(&id, &title, &cover, &remark))
        })
        .collect()
}

/// 取从 marker 处 `<div ...>` 开始、到其配对 `</div>` 为止的区段 [start, end)。
/// 搜索结果只取 div.resultList 内的条目，排除页内其它同类卡片区。
fn div_section_range(html: &str, marker: &str) -> Option<(usize, usize)> {
    let start = html.find(marker)?;
    let bytes = html.as_bytes();
    let mut depth = 0i32;
    let mut i = start;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            if html[i..].starts_with("</div>") {
                depth -= 1;
                if depth == 0 {
                    return Some((start, i + "</div>".len()));
                }
                i += "</div>".len();
                continue;
            }
            if html[i..].starts_with("<div")
                && (i + 4 >= bytes.len() || bytes[i + 4] == b' ' || bytes[i + 4] == b'>')
            {
                depth += 1;
                i += 4;
                continue;
            }
        }
        i += 1;
    }
    None
}

fn parse_search_items(html: &str) -> Vec<Value> {
    // 封面按 id 取：__NUXT__ 数据里 topics.hit 数组有每条结果的
    // cover_image_url / vertical_image_url；取不到留空。
    let mut covers: HashMap<String, String> = HashMap::new();
    if let Some(nuxt) = parse_nuxt(html) {
        if let Some(arr) = extract_array(&nuxt.body, "hit:") {
            for o in parse_loose_objects(&arr, &nuxt.map) {
                let id = get_s(&o, "id");
                if id.is_empty() || covers.contains_key(&id) {
                    continue;
                }
                let mut cover = get_s(&o, "cover_image_url");
                if cover.is_empty() {
                    cover = get_s(&o, "vertical_image_url");
                }
                if !cover.is_empty() {
                    covers.insert(id, cover);
                }
            }
        }
    }
    let section = match div_section_range(html, "<div class=\"resultList") {
        Some((s, e)) => &html[s..e],
        None => html,
    };
    let mut items = Vec::new();
    for block in section.split("<div class=\"TabW184").skip(1) {
        let Some(caps) =
            must_re(r#"href="/web/topic/(\d+)"[^>]*title="([^"]*)""#).captures(block)
        else {
            continue;
        };
        let id = caps[1].to_string();
        let title = decode_entities(&caps[2]).trim().to_string();
        if title.is_empty() {
            continue;
        }
        let author = match must_re(r#"(?s)class="author[^"]*"[^>]*>(.*?)</div>"#).captures(block)
        {
            Some(a) => clean_collapse(&a[1]),
            None => String::new(),
        };
        let first_tab = match must_re(r#"(?s)<span class="tab[^"]*">(.*?)</span>"#).captures(block)
        {
            Some(t) => clean_collapse(&t[1]),
            None => String::new(),
        };
        let remark = if author.is_empty() { first_tab } else { author };
        let cover = covers.get(&id).cloned().unwrap_or_default();
        items.push(item_json(&id, &title, &cover, &remark));
    }
    items
}

fn parse_chapter_images(html: &str) -> Vec<String> {
    let Some(arr) = extract_array(html, "comic_images:") else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::new();
    for tok in split_top_level(&arr, ',') {
        let t = tok.trim();
        if !t.starts_with('{') {
            continue;
        }
        if let Some(caps) = must_re(r#"url:"((?:[^"\\]|\\.)*)""#).captures(t) {
            let url = decode_js_string(&caps[1]);
            if url.starts_with("http") && !out.contains(&url) {
                out.push(url);
            }
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let Some((kind, num)) = category_id.split_once(':') else {
        return Ok(json!({"items": [], "has_more": false}));
    };
    if num.is_empty() || !num.bytes().all(|b| b.is_ascii_digit()) {
        return Ok(json!({"items": [], "has_more": false}));
    }
    match kind {
        "rank" => {
            if page > 1 {
                return Ok(json!({"items": [], "has_more": false}));
            }
            let items = parse_rank_items(&fetch(&format!("/ranking/{num}")).await);
            Ok(json!({"items": items, "has_more": false}))
        }
        "tag" => {
            let items =
                parse_tag_items(&fetch(&format!("/tag/{num}?region=&pays=&state=&sort=&page={page}")).await);
            let has_more = !items.is_empty();
            Ok(json!({"items": items, "has_more": has_more}))
        }
        _ => Ok(json!({"items": [], "has_more": false})),
    }
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = topic_id_of(series_id);
    if id.is_empty() {
        return Err(ApiError::Internal("快看漫画详情 id 为空".into()));
    }
    let html = fetch(&format!("/web/topic/{}", pct_encode_segment(&id))).await;
    if html.is_empty() {
        return Err(ApiError::Internal("快看漫画详情请求失败".into()));
    }
    let Some(nuxt) = parse_nuxt(&html) else {
        return Err(ApiError::Internal("快看漫画详情解析失败".into()));
    };
    let Some(info_text) = extract_object(&nuxt.body, "topic_info:") else {
        return Err(ApiError::Internal("快看漫画详情解析失败".into()));
    };
    let pairs = loose_pairs(&info_text);
    let info: HashMap<String, Value> = pairs
        .iter()
        .map(|(k, v)| (k.clone(), resolve_token(v, &nuxt.map)))
        .collect();
    let title = get_s(&info, "title");
    let title = if title.is_empty() { id.clone() } else { title };
    let cover = get_s(&info, "cover_image_url");
    let synopsis = get_s(&info, "description");
    let author = match pairs.iter().find(|(k, _)| k == "user") {
        Some((_, param)) => find_nickname(&nuxt.body, param),
        None => String::new(),
    };
    let mut episodes = Vec::new();
    if let Some(arr) = extract_array(&nuxt.body, "comics:") {
        for ch in parse_loose_objects(&arr, &nuxt.map) {
            let cid = get_s(&ch, "id");
            if cid.is_empty() {
                continue;
            }
            let mut ctitle = get_s(&ch, "title");
            if ctitle.is_empty() {
                ctitle = cid.clone();
            }
            let locked = is_locked(ch.get("locked").unwrap_or(&Value::Null))
                || is_locked(ch.get("is_pay_comic").unwrap_or(&Value::Null));
            if locked {
                ctitle = format!("{ctitle}（付费）");
            }
            episodes.push(episode_json(&cid, &ctitle, &id));
        }
    }
    let extra = if author.is_empty() {
        json!({})
    } else {
        json!({"author": author})
    };
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let q = query.trim();
    if q.is_empty() {
        return Ok(json!({"items": []}));
    }
    let items = parse_search_items(&fetch(&format!("/sou/{}", pct_encode_query(q))).await);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let id = strip_label(video_id);
    if id.starts_with("pics://") {
        return Ok(json!({"url": id}));
    }
    let chap = id.split('#').last().unwrap_or("").trim();
    let chap: String = chap.chars().filter(|c| c.is_ascii_digit()).collect();
    if chap.is_empty() {
        return Err(ApiError::Internal("快看漫画章节 id 为空".into()));
    }
    let html = fetch(&format!("/webs/comic-next/{chap}")).await;
    let imgs = parse_chapter_images(&html);
    if imgs.is_empty() {
        return Err(ApiError::Internal("快看漫画未返回图片".into()));
    }
    Ok(json!({
        "url": format!("pics://{}", imgs.join("&&")),
        "header": {"User-Agent": UA, "Referer": format!("{BASE_URL}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe_path(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mycomic_re")
            .join("probe")
            .join(name)
    }

    fn read_probe(name: &str) -> String {
        let bytes = std::fs::read(probe_path(name)).unwrap_or_else(|e| {
            panic!("读 probe 样本 {name} 失败: {e}");
        });
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[test]
    fn split_top_level_skips_strings_and_nesting() {
        let parts = split_top_level(r#"0,"a,b","x\"y",[1,2],{"k":3},Array(8)"#, ',');
        assert_eq!(parts.len(), 6);
        assert_eq!(parts[1], "\"a,b\"");
        assert_eq!(parts[3], "[1,2]");
        assert_eq!(parts[5], "Array(8)");
    }

    #[test]
    fn nuxt_value_unescapes_unicode_slash() {
        let html = r#"x __NUXT__=(function(a,b){a[0]="t";})("https:\u002F\u002Ff2.kkmh.com\u002Fimg.webp",1)); y"#;
        let nuxt = parse_nuxt(html).expect("应解析出 nuxt");
        assert_eq!(
            nuxt.map.get("a").map(value_str).unwrap_or_default(),
            "https://f2.kkmh.com/img.webp"
        );
        assert_eq!(nuxt.map.get("b").map(value_str).unwrap_or_default(), "1");
    }

    #[test]
    fn array_placeholder_and_void_are_skipped() {
        let html = r#"__NUXT__=(function(a,b,c){})("v",Array(8),void 0));"#;
        let nuxt = parse_nuxt(html).expect("应解析出 nuxt");
        assert_eq!(nuxt.map.len(), 1);
        assert_eq!(nuxt.map.get("a").map(value_str).unwrap_or_default(), "v");
        assert!(nuxt.map.get("b").is_none());
        assert!(nuxt.map.get("c").is_none());
    }

    #[test]
    fn locked_detection() {
        assert!(is_locked(&json!(true)));
        assert!(!is_locked(&json!(false)));
        assert!(is_locked(&json!("true")));
        assert!(!is_locked(&json!("false")));
        assert!(!is_locked(&json!("")));
        assert!(is_locked(&json!(1)));
        assert!(!is_locked(&json!(0)));
        assert!(!is_locked(&Value::Null));
    }

    #[test]
    fn detail_sample_parses() {
        let html = read_probe("kk_detail_full.bin");
        let nuxt = parse_nuxt(&html).expect("详情样本应解析出 nuxt");
        // 790 个参数，ae 是 Array(8) 占位被跳过，余 789 项。
        assert_eq!(nuxt.map.len(), 789);
        assert_eq!(nuxt.map.get("Y").map(value_str).unwrap_or_default(), "3095");
        assert_eq!(
            nuxt.map.get("T").map(value_str).unwrap_or_default(),
            "斗罗大陆外传唐门英雄传"
        );
        let info_text = extract_object(&nuxt.body, "topic_info:").expect("应有 topic_info");
        let pairs = loose_pairs(&info_text);
        let info: HashMap<String, Value> = pairs
            .iter()
            .map(|(k, v)| (k.clone(), resolve_token(v, &nuxt.map)))
            .collect();
        assert_eq!(get_s(&info, "title"), "斗罗大陆外传唐门英雄传");
        assert_eq!(
            get_s(&info, "cover_image_url"),
            "https://tn1-f2.kkmh.com/image/190115/GI7xWDYSt.webp-w750.jpg"
        );
        assert!(get_s(&info, "description").starts_with("被封印的神界"));
        let user_param = pairs
            .iter()
            .find(|(k, _)| k == "user")
            .map(|(_, v)| v.clone())
            .unwrap_or_default();
        assert_eq!(user_param, "iY");
        assert_eq!(
            find_nickname(&nuxt.body, &user_param),
            "唐家三少（原著）+Asoul+RIGON"
        );
        let arr = extract_array(&nuxt.body, "comics:").expect("应有 comics");
        let chapters = parse_loose_objects(&arr, &nuxt.map);
        assert_eq!(chapters.len(), 100);
        assert_eq!(get_s(&chapters[0], "id"), "147096");
        assert_eq!(get_s(&chapters[0], "title"), "第1话 心悸的小舞");
        assert!(!is_locked(chapters[0].get("locked").unwrap_or(&Value::Null)));
        assert!(is_locked(chapters[99].get("locked").unwrap_or(&Value::Null)));
        assert_eq!(get_s(&chapters[99], "id"), "368991");
    }

    #[test]
    fn chapter_sample_has_85_images() {
        let html = read_probe("kk_chapter.bin");
        let imgs = parse_chapter_images(&html);
        assert_eq!(imgs.len(), 85);
        let expected: Vec<String> =
            serde_json::from_str(&read_probe("kk_images.json")).expect("kk_images.json 应为数组");
        assert_eq!(imgs, expected);
        assert!(imgs[0].starts_with("https://tn1.kkmh.com/image/c147096/190202/"));
        assert!(imgs[0].contains("sign=") && imgs[0].contains("&t="));
    }

    #[test]
    fn rank_sample_parses() {
        let html = read_probe("kk_rank.bin");
        let items = parse_rank_items(&html);
        assert_eq!(items.len(), 20);
        assert_eq!(items[0]["id"], "17212");
        assert_eq!(items[0]["title"], "告白");
        assert_eq!(
            items[0]["cover"],
            "https://tn1-f2.kkmh.com/image/230108/lvZbRqysV.webp-w750.jpg"
        );
        assert_eq!(items[1]["id"], "12602");
        assert_eq!(items[1]["title"], "我！天命大反派");
    }

    #[test]
    fn tag_fixture_parses() {
        let html = r#"__NUXT__=(function(a,b,c,d,e,f,g){})("x",13455,"难哄","https:\u002F\u002Ftn1-f2.kkmh.com\u002Fimage\u002F1.webp-w750.jpg","竹已（原著）+四零工作室","枕边相伴",1));"#;
        let body = "dataList:[{category:a,comics_count:g,cover_image_url:d,id:b,title:c,author_name:e,latest_comic_title:f}]";
        let nuxt = parse_nuxt(html).expect("fixture 应解析出 nuxt");
        let arr = extract_array(body, "dataList:").expect("应有 dataList");
        let objs = parse_loose_objects(&arr, &nuxt.map);
        assert_eq!(objs.len(), 1);
        assert_eq!(get_s(&objs[0], "id"), "13455");
        assert_eq!(get_s(&objs[0], "title"), "难哄");
        assert_eq!(
            get_s(&objs[0], "cover_image_url"),
            "https://tn1-f2.kkmh.com/image/1.webp-w750.jpg"
        );
        assert_eq!(get_s(&objs[0], "author_name"), "竹已（原著）+四零工作室");
    }

    #[test]
    fn tag_sample_parses() {
        let path = std::path::Path::new("/tmp/kk_tag20.html");
        if !path.exists() {
            eprintln!("跳过 tag 样本单测：/tmp/kk_tag20.html 不存在（临时样本已清）");
            return;
        }
        let html = String::from_utf8_lossy(&std::fs::read(path).expect("读 tag 样本失败"))
            .into_owned();
        let items = parse_tag_items(&html);
        assert_eq!(items.len(), 47);
        assert_eq!(items[0]["id"], "13455");
        assert_eq!(items[0]["title"], "难哄");
        assert_eq!(items[0]["remark"], "竹已（原著）+四零工作室");
        assert_eq!(items[1]["id"], "5918");
        assert_eq!(items[1]["title"], "笙笙予你");
    }

    #[test]
    fn search_cover_comes_from_hit_by_id() {
        let html = concat!(
            "<div class=\"resultList cls\">",
            "<div class=\"TabW184 fl padding16\">",
            "<a href=\"/web/topic/3095\" target=\"_blank\" title=\"斗罗大陆外传唐门英雄传\" class=\"link\">",
            "<div class=\"imgBox\"></div><div class=\"itemTitle\"></div></a>",
            "<div class=\"itemFooter cls\"><div title=\"唐家三少\" class=\"author fl\">唐家三少</div></div>",
            "</div></div>",
            "__NUXT__=(function(a,b,c,d){return {layout:\"default\",data:[{code:200,originData:{topics:{hit:[{id:a,title:b,cover_image_url:c,vertical_image_url:d}]}}}]}})(3095,\"斗罗大陆外传唐门英雄传\",\"https:\\u002F\\u002Ftn1-f2.kkmh.com\\u002Fimage\\u002F190115\\u002FGI7xWDYSt.webp-w750.jpg\",\"https:\\u002F\\u002Ftn1-f2.kkmh.com\\u002Fimage\\u002F190115\\u002F6uDRSET7T.webp-w320.w.jpg\"));",
        );
        let items = parse_search_items(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "3095");
        assert_eq!(items[0]["title"], "斗罗大陆外传唐门英雄传");
        assert_eq!(items[0]["remark"], "唐家三少");
        assert_eq!(
            items[0]["cover"],
            "https://tn1-f2.kkmh.com/image/190115/GI7xWDYSt.webp-w750.jpg"
        );
    }

    #[test]
    fn search_sample_parses() {
        let html = read_probe("kuaikan_search.bin");
        // 该样本的 __NUXT__ 在文件尾被截断，解析应优雅失败、封面留空。
        assert!(parse_nuxt(&html).is_none());
        let items = parse_search_items(&html);
        // resultList 内共 12 条：10 条展示 + 2 条在“展开”之后。
        assert_eq!(items.len(), 12);
        assert_eq!(items[0]["id"], "3095");
        assert_eq!(items[0]["title"], "斗罗大陆外传唐门英雄传");
        assert_eq!(items[0]["remark"], "唐家三少（原著）+Asoul+RIGON");
        assert_eq!(items[0]["cover"], "");
        assert_eq!(items[1]["id"], "5901");
        assert_eq!(items[1]["title"], "斗魂大陆");
        assert_eq!(items[10]["id"], "7060");
        assert_eq!(items[10]["title"], "硬核一中");
        assert_eq!(items[11]["id"], "19109");
    }
}
