//! 🎬懂色帝：dsd.com.se 的 MacCMS 站 + AAEncode 混淆取流。
//!
//! 与 jar 的 ZakaDsdAmns 一一对应：分类（首页 /vod/type/id/
//! 链接，少于 2 个回退 1 独家精选/2 中文字幕/4 无码破解）、
//! 目录（CARD 正则取卡片，/page/<N>/ 翻页）、详情（player 页
//! 的 player_aaaa 对象取标题封面，单集“正片”）、搜索（先
//! ajax/suggest 接口，无结果回退搜索页）、取流（player_aaaa.url
//! 为相对路径时走 /addons/vplayer/ 再经 ZakaAA.decode 取
//! vPath 签名 m3u8）。
//! ZakaAA.decode 已完整移植（AAEncode 解码器：vars 取 base、
//! inner 大括号配对、toExpr 替换、tokenize 分词、递归下降求值、
//! unescapeJs 解转义；Python 移植已验证通过：_ 与 o 保持原始
//! base，只有 ﾟｰﾟ 取 base+theta；inner 须用加减计数，jadx
//! 反编译丢了 ) 时的减 1，dexdump 字节码证实）。
//! 差异：jar 原文返回经 DSD.hls 本地代理改写的 m3u8，核心里
//! 没有本地代理，这里直接返回签名 m3u8 直链 + 头。
//! 验门（2026-11-05 请求复现）：分类页 24 卡、翻页 24 卡、
//! 详情、搜索 suggest（EBWH 86 条）、取流签名 m3u8 首分片
//! 200（146KB）全过。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json, text_of};

const HOST: &str = "https://www.dsd.com.se";
const MIRRORS: &[&str] = &["https://www.dsd900.com", "https://www.dsd900.lol"];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn bases() -> Vec<&'static str> {
    let mut out = vec![HOST];
    out.extend(MIRRORS.iter().copied());
    out
}

/// 与 Java 的 page() 一致：按 host→mirrors 逐个试，正文
/// >500 字算成功；全败则报错（jar 的 ZakaShield 兜底在核心
/// 里无法实现）。
async fn fetch_page(path: &str) -> ApiResult<(String, String)> {
    for base in bases() {
        let url = format!("{base}{path}");
        if let Ok(resp) = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "text/html,application/xhtml+xml,*/*")
            .header("Referer", format!("{base}/"))
            .send()
            .await
        {
            if resp.status().as_u16() == 200 {
                if let Ok(text) = resp.text().await {
                    if text.len() > 500 {
                        return Ok((base.to_string(), text));
                    }
                }
            }
        }
    }
    Err(ApiError::Internal("懂色帝没有取到页面".into()))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("懂色帝请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&no_tag, " ").trim().to_string()
}

fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 与 Java 的 ZakaDrama.matchEnd 一致：从 { 起括号配对。
fn match_end(page: &str, start: usize) -> Option<usize> {
    let bytes = page.as_bytes();
    let mut depth: i64 = 0;
    let mut in_str = false;
    let mut escaped = false;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if in_str {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_str = false;
            }
        } else if c == '"' {
            in_str = true;
        } else if c == '{' {
            depth += 1;
        } else if c == '}' {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// 与 Java 的 ZakaDrama.blob 一致：找含 key 的 JSON 对象。
fn blob(page: &str, key: &str) -> String {
    let mut offset = 0usize;
    for _ in 0..8 {
        let Some(rel) = page[offset..].find(key) else {
            return String::new();
        };
        let idx = offset + rel;
        let mut pos = idx;
        for _ in 0..300 {
            let Some(open) = page[..pos].rfind('{') else {
                break;
            };
            pos = open;
            if let Some(end) = match_end(page, open) {
                if end > idx {
                    let cand = &page[open..=end];
                    if cand.len() <= 3 * 1024 * 1024 && serde_json::from_str::<Value>(cand).is_ok()
                    {
                        return cand.to_string();
                    }
                }
            }
            if pos == 0 {
                break;
            }
            let Some(prev) = page[..pos.saturating_sub(1)].rfind('{') else {
                break;
            };
            pos = prev + 1;
        }
        offset = idx + key.len();
    }
    String::new()
}

/// 与 Java 的 ZakaDrama.svRaw 一致：正则取 "key":"..."。
fn sv_raw(s: &str, key: &str) -> String {
    let pattern = format!("\"{}\"\\s*:\\s*\"([^\"]*)\"", regex::escape(key));
    let Ok(re) = Regex::new(&pattern) else {
        return String::new();
    };
    match re.captures(s) {
        Some(cap) => cap[1].replace("\\/", "/"),
        None => String::new(),
    }
}

/// 与 Java 的 ZakaDrama.sv 一致：先按 JSON 取，取不到走正则。
fn sv(blob_json: &str, key: &str) -> String {
    if let Ok(body) = serde_json::from_str::<Value>(blob_json) {
        let v = text_of(&body, &[key]);
        if !v.is_empty() {
            return v;
        }
    }
    sv_raw(blob_json, key)
}

/// 与 Java 的 parseCards 一致：CARD 正则取播放链接与卡片体，
/// 再取图、标题、备注（时长或播放量）。
fn parse_cards(page: &str, base: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let Ok(re) = Regex::new(
        "(?s)<a href=\"(/index\\.php/vod/play/id/(\\d+)/sid/(\\d+)/nid/(\\d+)\\.html)\"[^>]*class=\"[^\"]*(?:video-surface|video-item)[^\"]*\"[^>]*>(.*?)</a>",
    ) else {
        return items;
    };
    let mut seen: Vec<String> = Vec::new();
    for cap in re.captures_iter(page) {
        let play_path = cap[1].to_string();
        if seen.contains(&play_path) {
            continue;
        }
        seen.push(play_path.clone());
        let body = &cap[5];
        let mut pic = pick(body, "(?i)data-src=\"([^\"]+)\"");
        if pic.is_empty() {
            pic = pick(body, "(?i)<img[^>]+src=\"([^\"]+)\"");
        }
        let pic = if pic.starts_with("http") {
            pic
        } else if pic.starts_with("//") {
            format!("https:{pic}")
        } else if pic.starts_with('/') {
            format!("{base}{pic}")
        } else {
            String::new()
        };
        let mut title = pick(body, "(?s)<div class=\"video-desc\"[^>]*>(.*?)</div>");
        if title.is_empty() {
            title = pick(body, "(?s)<h2[^>]*>(.*?)</h2>");
        }
        if title.is_empty() {
            title = format!("影片 {}", &cap[2]);
        }
        let mut remark = pick(
            body,
            "(?s)class=\"[^\"]*video-item-tag-duration[^\"]*\"[^>]*>(.*?)<",
        );
        if remark.is_empty() {
            remark = pick(
                body,
                "(?s)class=\"[^\"]*video-item-tag-hits[^\"]*\"[^>]*>(.*?)<",
            );
        }
        let href = format!("{base}{play_path}");
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

fn page_count(page: &str) -> i64 {
    let Ok(re) = Regex::new("/page/(\\d+)\\.html") else {
        return 0;
    };
    let mut max: i64 = 0;
    for cap in re.captures_iter(page) {
        let n: i64 = cap[1].parse().unwrap_or(0);
        if n > max {
            max = n;
        }
    }
    max
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    if let Ok((_base, html)) = fetch_page("/").await {
        let re = Regex::new(
            "(?s)<a[^>]*href=\"(?:/index\\.php)?/vod/type/id/(\\d+)\\.html\"[^>]*>([^<]+)</a>",
        )
        .unwrap();
        let exclude = [
            "首页",
            "开通VIP",
            "VIP",
            "爱看",
            "专题",
            "会员",
            "登录",
            "注册",
        ];
        let mut seen: Vec<String> = Vec::new();
        for cap in re.captures_iter(&html) {
            let id = cap[1].to_string();
            let name = strip_tags(&cap[2]);
            if name.is_empty() || exclude.contains(&name.as_str()) || seen.contains(&id) {
                continue;
            }
            seen.push(id.clone());
            list.push(category_json(&id, &name));
        }
    }
    if list.len() < 2 {
        list = vec![
            category_json("1", "独家精选"),
            category_json("2", "中文字幕"),
            category_json("4", "无码破解"),
        ];
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let id = if category_id.is_empty() {
        "1".to_string()
    } else {
        category_id.to_string()
    };
    let path = if page > 1 {
        format!("/index.php/vod/type/id/{id}/page/{page}.html")
    } else {
        format!("/index.php/vod/type/id/{id}.html")
    };
    let (base, html) = fetch_page(&path).await?;
    let items = parse_cards(&html, &base);
    let total = page_count(&html);
    let has_more = if total > 0 {
        page < total
    } else {
        !items.is_empty()
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let play_re = Regex::new("/vod/play/id/(\\d+)/sid/(\\d+)/nid/(\\d+)\\.html").unwrap();
    let (id, sid, nid) = match play_re.captures(series_id) {
        Some(cap) => (cap[1].to_string(), cap[2].to_string(), cap[3].to_string()),
        None => {
            let digits: String = series_id.chars().filter(|c| c.is_ascii_digit()).collect();
            (digits, "1".to_string(), "1".to_string())
        }
    };
    let (base, page) =
        fetch_page(&format!("/index.php/vod/player/id/{id}/sid/1/nid/1.html")).await?;
    // 页内另有 maccms={...}，blob 键须用 vod_data 才能取到
    // player_aaaa 对象。
    let mut b = blob(&page, "vod_data");
    if b.is_empty() {
        b = blob(&page, "player_aaaa");
    }
    let vod_data = if let Ok(body) = serde_json::from_str::<Value>(&b) {
        match body.get("vod_data") {
            Some(v) => v.clone(),
            None => body,
        }
    } else {
        Value::Null
    };
    let mut title = text_of(&vod_data, &["vod_name"]);
    if title.is_empty() {
        title = pick(
            &page,
            "(?s)<div class=\"basic-top\"[^>]*>\\s*<h2[^>]*>(.*?)</h2>",
        );
    }
    if title.is_empty() {
        title = format!("影片 {id}");
    }
    let mut cover = text_of(&vod_data, &["vod_pic"]);
    if cover.is_empty() {
        cover = pick(&page, "(?s)property=\"og:image\" content=\"([^\"]+)\"");
    }
    let cover = if cover.starts_with("http") {
        cover
    } else if cover.starts_with("//") {
        format!("https:{cover}")
    } else if cover.starts_with('/') {
        format!("{base}{cover}")
    } else {
        String::new()
    };
    let mut extra = serde_json::Map::new();
    let actor = text_of(&vod_data, &["vod_actor"]);
    if !actor.is_empty() {
        extra.insert("actors".to_string(), Value::String(actor));
    }
    let director = text_of(&vod_data, &["vod_director"]);
    if !director.is_empty() {
        extra.insert("director".to_string(), Value::String(director));
    }
    let class = text_of(&vod_data, &["vod_class"]);
    if !class.is_empty() {
        extra.insert("class".to_string(), Value::String(class));
    }
    let play_url = format!("{base}/index.php/vod/play/id/{id}/sid/{sid}/nid/{nid}.html");
    Ok(json!({
        "id": play_url,
        "title": title,
        "cover": cover,
        "synopsis": "",
        "extra": extra,
        "episodes": [episode_json(&play_url, "正片", &play_url)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    // 先走 suggest 接口。
    for base in bases() {
        let url = format!("{base}/index.php/ajax/suggest?mid=1&wd={encoded}&page=1");
        if let Ok(text) = get_text(&url).await {
            if let Ok(body) = serde_json::from_str::<Value>(&text) {
                if let Some(list) = body.get("list").and_then(|v| v.as_array()) {
                    let mut items = Vec::new();
                    for entry in list {
                        let id = text_of(entry, &["id"]);
                        let name = text_of(entry, &["name"]);
                        if id.is_empty() || name.is_empty() {
                            continue;
                        }
                        let mut pic = text_of(entry, &["pic"]);
                        if pic.starts_with('/') {
                            pic = format!("{base}{pic}");
                        }
                        let href = format!("{base}/index.php/vod/play/id/{id}/sid/1/nid/1.html");
                        items.push(item_json(&href, &name, &pic, ""));
                    }
                    if !items.is_empty() {
                        return Ok(json!({"items": items}));
                    }
                }
            }
        }
    }
    // 无结果回退搜索页。
    let (base, html) = fetch_page(&format!("/index.php/vod/search.html?wd={encoded}")).await?;
    let items = parse_cards(&html, &base);
    Ok(json!({"items": items}))
}

/// 取流：解析播放地址中的 id/sid/nid，抓 player 页取
/// player_aaaa.url；http 直传，否则走 /addons/vplayer/ 再经
/// AA 解码取 vPath 签名 m3u8（直接回直链，不走本地代理）。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let play_re = Regex::new("/vod/play/id/(\\d+)/sid/(\\d+)/nid/(\\d+)").unwrap();
    let (vid, sid, nid) = match play_re.captures(video_id) {
        Some(cap) => (cap[1].to_string(), cap[2].to_string(), cap[3].to_string()),
        None => {
            let digits: String = video_id.chars().filter(|c| c.is_ascii_digit()).collect();
            (digits, "1".to_string(), "1".to_string())
        }
    };
    let (base, page) = fetch_page(&format!(
        "/index.php/vod/player/id/{vid}/sid/{sid}/nid/{nid}.html"
    ))
    .await?;
    let mut b = blob(&page, "vod_data");
    if b.is_empty() {
        b = blob(&page, "player_aaaa");
    }
    let mut url = sv(&b, "url");
    if url.is_empty() {
        return Err(ApiError::Internal("懂色帝未取到播放地址".into()));
    }
    if url.starts_with("http") {
        return Ok(json!({
            "url": url,
            "header": {"User-Agent": UA, "Referer": format!("{base}/"), "Origin": base},
        }));
    }
    // 相对路径：走 vplayer 再 AA 解码。
    let encoded: String = url::form_urlencoded::byte_serialize(url.as_bytes()).collect();
    let vplayer_url = format!("{base}/addons/vplayer/?url={encoded}&jump=");
    let vpage = get_text(&vplayer_url).await?;
    let decoded = aa::decode(&vpage).unwrap_or_default();
    let mut stream = String::new();
    if let Ok(re) = Regex::new("vPath\\s*=\\s*\"([^\"]+)\"") {
        if let Some(cap) = re.captures(&decoded) {
            stream = cap[1].to_string();
        }
    }
    if stream.is_empty() {
        if let Ok(re) = Regex::new("(https?://[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)") {
            if let Some(cap) = re.captures(&decoded) {
                stream = cap[1].to_string();
            }
        }
    }
    if stream.is_empty() {
        if let Ok(re) = Regex::new("(/[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*)") {
            if let Some(cap) = re.captures(&decoded) {
                stream = cap[1].to_string();
            }
        }
    }
    if stream.is_empty() {
        return Err(ApiError::Internal("懂色帝未取到播放地址".into()));
    }
    if stream.starts_with('/') {
        stream = format!("{base}{stream}");
    }
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{base}/"), "Origin": base},
    }))
}

/// ZakaAA.decode 的完整移植：AAEncode（颜文字混淆）解码器。
mod aa {
    use regex::Regex;

    #[derive(Clone, Debug, PartialEq)]
    enum Val {
        Num(i64),
        Str(String),
    }

    impl Val {
        fn to_num(&self) -> i64 {
            match self {
                Val::Num(n) => *n,
                Val::Str(s) => s.trim().parse().unwrap_or(0),
            }
        }

        fn to_str(&self) -> String {
            match self {
                Val::Num(n) => n.to_string(),
                Val::Str(s) => s.clone(),
            }
        }
    }

    #[derive(Clone, Debug)]
    enum Tok {
        Num(i64),
        Str(String),
        Op(char),
    }

    /// 入口：取含 ﾟ 且长度 >500 的 script，按长度降序逐个试解。
    pub fn decode(page: &str) -> Option<String> {
        let script_re = Regex::new("(?s)<script[^>]*>(.*?)</script>").unwrap();
        let mut candidates: Vec<String> = script_re
            .captures_iter(page)
            .map(|c| c[1].to_string())
            .filter(|s| s.contains('ﾟ') && s.len() > 500)
            .collect();
        candidates.sort_by_key(|s| std::cmp::Reverse(s.len()));
        for cand in candidates {
            if let Some(result) = eval_script(&cand) {
                return Some(result);
            }
        }
        None
    }

    pub(crate) fn eval_script(script: &str) -> Option<String> {
        let (base, theta) = vars(script);
        let inner = inner(script)?;
        let expr = to_expr(&inner, base, theta);
        let tokens = tokenize(&expr)?;
        let mut pos = 0usize;
        let val = parse_expr(&tokens, &mut pos)?;
        if pos != tokens.len() {
            return None;
        }
        match val {
            Val::Str(s) => Some(unescape_js(&s)),
            _ => None,
        }
    }

    /// vars：base 取 o=(ﾟｰﾟ)=_=数字（默认 3）；ﾟΘﾟ 为 1 当且
    /// 仅当含 (ﾟДﾟ)=(ﾟΘﾟ)=；含 (ﾟｰﾟ)+=(ﾟΘﾟ) 时 base+=theta。
    /// _ 与 o 保持原始 base，只有 ﾟｰﾟ 取 base+theta。
    fn vars(script: &str) -> (i64, i64) {
        let mut base: i64 = 3;
        if let Ok(re) = Regex::new("o=\\s*\\(ﾟｰﾟ\\)\\s*=\\s*_\\s*=\\s*(\\d+)") {
            if let Some(cap) = re.captures(script) {
                base = cap[1].parse().unwrap_or(3);
            }
        }
        let theta: i64 = if Regex::new("\\(ﾟДﾟ\\)\\s*=\\s*\\(ﾟΘﾟ\\)\\s*=")
            .ok()
            .map(|re| re.is_match(script))
            .unwrap_or(false)
        {
            1
        } else {
            0
        };
        if Regex::new("\\(ﾟｰﾟ\\)\\s*\\+=\\s*\\(ﾟΘﾟ\\)")
            .ok()
            .map(|re| re.is_match(script))
            .unwrap_or(false)
        {
            base += theta;
        }
        (base, theta)
    }

    /// inner：从两个 Java 原标记与转义/混合变体起，加减计数
    /// 大括号配对，归 0 时返回标记末 ( 之后的内容。
    fn inner(script: &str) -> Option<String> {
        const MARKERS: &[&str] = &[
            "(ﾟДﾟ) ['_'] ( (ﾟДﾟ) ['_'] (",
            "(ﾟДﾟ)['_']((ﾟДﾟ)['_'](",
            "(ﾟДﾟ) [\\'_\\'] ( (ﾟДﾟ) [\\'_\\'] (",
            "(ﾟДﾟ) ['_'] ((ﾟДﾟ) ['_'] (",
            "(ﾟДﾟ)['_']( (ﾟДﾟ)['_'](",
        ];
        for marker in MARKERS {
            let mut from = 0usize;
            while let Some(rel) = script[from..].find(marker) {
                let pos = from + rel + marker.len() - 1;
                let bytes = script.as_bytes();
                let mut depth: i64 = 0;
                let mut i = pos;
                while i < bytes.len() {
                    let c = bytes[i] as char;
                    if c == '(' {
                        depth += 1;
                    } else if c == ')' {
                        depth -= 1;
                        if depth == 0 {
                            return Some(script[pos + 1..i].to_string());
                        }
                    }
                    i += 1;
                }
                from += rel + 1;
            }
        }
        None
    }

    /// toExpr：按 jar 的替换表把颜文字变量换成数字与字符串。
    fn to_expr(inner: &str, base: i64, theta: i64) -> String {
        let b = base.to_string();
        let t = theta.to_string();
        let bt = (base + theta).to_string();
        let mut s = inner.to_string();
        s = s.replace("(ﾟДﾟ) [ﾟεﾟ]", "'\\\\'");
        s = s.replace("(ﾟДﾟ)[ﾟεﾟ]", "'\\\\'");
        s = s.replace("(ﾟДﾟ) [ﾟoﾟ]", "'\"'");
        s = s.replace("(ﾟДﾟ)[ﾟoﾟ]", "'\"'");
        s = s.replace("(ﾟДﾟ) [ﾟΘﾟ]", "'_'");
        s = s.replace("(ﾟДﾟ)[ﾟΘﾟ]", "'_'");
        s = s.replace("(c^_^o)", &format!("(0^{b}^{b})"));
        s = s.replace("(o^_^o)", &format!("({b}^{b}^{b})"));
        s = s.replace("ﾟεﾟ", "'r'");
        s = s.replace("ﾟoﾟ", "'c'");
        s = s.replace("oﾟｰﾟo", "'u'");
        s = s.replace("(ﾟｰﾟ)", &format!("({bt})"));
        s = s.replace("(ﾟΘﾟ)", &format!("({t})"));
        s = s.replace("(ﾟДﾟ)", "(0)");
        s
    }

    /// tokenize：数字、单/双引号字符串、+ - ^ ( ) 五类。
    fn tokenize(expr: &str) -> Option<Vec<Tok>> {
        let re = Regex::new(
            "\\s*(?:(\\d+)|'((?:\\\\.|[^'\\\\])*)'|\"((?:\\\\.|[^\"\\\\])*)\"|([+\\-^()]))",
        )
        .unwrap();
        let mut tokens = Vec::new();
        let mut pos = 0usize;
        while pos < expr.len() {
            let Some(cap) = re.captures(&expr[pos..]) else {
                return None;
            };
            let m = cap.get(0).unwrap();
            if m.end() == 0 {
                return None;
            }
            pos += m.end();
            if let Some(num) = cap.get(1) {
                tokens.push(Tok::Num(num.as_str().parse().ok()?));
            } else if let Some(s) = cap.get(2) {
                tokens.push(Tok::Str(unescape_token(s.as_str())));
            } else if let Some(s) = cap.get(3) {
                tokens.push(Tok::Str(unescape_token(s.as_str())));
            } else if let Some(op) = cap.get(4) {
                tokens.push(Tok::Op(op.as_str().chars().next()?));
            }
        }
        Some(tokens)
    }

    fn unescape_token(s: &str) -> String {
        let chars: Vec<char> = s.chars().collect();
        let mut out = String::new();
        let mut i = 0usize;
        while i < chars.len() {
            if chars[i] == '\\' && i + 1 < chars.len() {
                let n = chars[i + 1];
                match n {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    other => out.push(other),
                }
                i += 2;
            } else {
                out.push(chars[i]);
                i += 1;
            }
        }
        out
    }

    /// Eval 递归下降：expr→bitxor→add→unary→primary。
    fn parse_expr(tokens: &[Tok], pos: &mut usize) -> Option<Val> {
        parse_bitxor(tokens, pos)
    }

    fn parse_bitxor(tokens: &[Tok], pos: &mut usize) -> Option<Val> {
        let mut left = parse_add(tokens, pos)?;
        while let Some(Tok::Op('^')) = tokens.get(*pos) {
            *pos += 1;
            let right = parse_add(tokens, pos)?;
            left = Val::Num(left.to_num() ^ right.to_num());
        }
        Some(left)
    }

    fn parse_add(tokens: &[Tok], pos: &mut usize) -> Option<Val> {
        let mut left = parse_unary(tokens, pos)?;
        loop {
            match tokens.get(*pos) {
                Some(Tok::Op('+')) => {
                    *pos += 1;
                    let right = parse_unary(tokens, pos)?;
                    left = match (&left, &right) {
                        (Val::Str(_), _) | (_, Val::Str(_)) => {
                            Val::Str(left.to_str() + &right.to_str())
                        }
                        _ => Val::Num(left.to_num() + right.to_num()),
                    };
                }
                Some(Tok::Op('-')) => {
                    *pos += 1;
                    let right = parse_unary(tokens, pos)?;
                    left = Val::Num(left.to_num() - right.to_num());
                }
                _ => break,
            }
        }
        Some(left)
    }

    fn parse_unary(tokens: &[Tok], pos: &mut usize) -> Option<Val> {
        if let Some(Tok::Op('-')) = tokens.get(*pos) {
            *pos += 1;
            let v = parse_unary(tokens, pos)?;
            return Some(Val::Num(-v.to_num()));
        }
        parse_primary(tokens, pos)
    }

    fn parse_primary(tokens: &[Tok], pos: &mut usize) -> Option<Val> {
        match tokens.get(*pos) {
            Some(Tok::Num(n)) => {
                *pos += 1;
                Some(Val::Num(*n))
            }
            Some(Tok::Str(s)) => {
                *pos += 1;
                Some(Val::Str(s.clone()))
            }
            Some(Tok::Op('(')) => {
                *pos += 1;
                let v = parse_expr(tokens, pos)?;
                if let Some(Tok::Op(')')) = tokens.get(*pos) {
                    *pos += 1;
                    Some(v)
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    /// unescapeJs：八进制 \0–\777（最多 3 位）、\xHH、\uHHHH、
    /// \n \r \t，其余取反斜杠后字符本身。
    fn unescape_js(s: &str) -> String {
        let chars: Vec<char> = s.chars().collect();
        let mut out = String::new();
        let mut i = 0usize;
        while i < chars.len() {
            if chars[i] == '\\' && i + 1 < chars.len() {
                let n = chars[i + 1];
                match n {
                    'n' => {
                        out.push('\n');
                        i += 2;
                    }
                    'r' => {
                        out.push('\r');
                        i += 2;
                    }
                    't' => {
                        out.push('\t');
                        i += 2;
                    }
                    'x' if i + 3 < chars.len() => {
                        let hex: String = chars[i + 2..i + 4].iter().collect();
                        if let Ok(code) = u8::from_str_radix(&hex, 16) {
                            out.push(code as char);
                        }
                        i += 4;
                    }
                    'u' if i + 5 < chars.len() => {
                        let hex: String = chars[i + 2..i + 6].iter().collect();
                        if let Ok(code) = u32::from_str_radix(&hex, 16) {
                            if let Some(ch) = char::from_u32(code) {
                                out.push(ch);
                            }
                        }
                        i += 6;
                    }
                    '0'..='7' => {
                        let mut oct = String::new();
                        let mut j = i + 1;
                        while j < chars.len() && j < i + 4 && ('0'..='7').contains(&chars[j]) {
                            oct.push(chars[j]);
                            j += 1;
                        }
                        if let Ok(code) = u8::from_str_radix(&oct, 8) {
                            out.push(code as char);
                        }
                        i = j;
                    }
                    other => {
                        out.push(other);
                        i += 2;
                    }
                }
            } else {
                out.push(chars[i]);
                i += 1;
            }
        }
        out
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn inner_extracts_balanced() {
            let script = "(ﾟДﾟ) ['_'] ( (ﾟДﾟ) ['_'] ((1+2))";
            assert_eq!(inner(script).unwrap(), "(1+2)");
        }

        #[test]
        fn to_expr_replaces_vars() {
            let expr = to_expr("(ﾟｰﾟ)+(ﾟΘﾟ)+(ﾟДﾟ)", 3, 1);
            assert_eq!(expr, "(4)+(1)+(0)");
        }

        #[test]
        fn eval_string_concat() {
            let script = "o=(ﾟｰﾟ)=_=3;(ﾟДﾟ) ['_'] ( (ﾟДﾟ) ['_'] (('r'+'c'))";
            assert_eq!(eval_script(script).unwrap(), "rc");
        }

        #[test]
        fn unescape_js_octal_hex() {
            assert_eq!(unescape_js("\\x41\\101"), "AA");
            assert_eq!(unescape_js("a\\nb"), "a\nb");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_parse_play_links() {
        let page = "<a href=\"/index.php/vod/play/id/123/sid/1/nid/1.html\" class=\"video-item\"><img data-src=\"https://img.example.com/1.jpg\"><div class=\"video-desc\">标题</div></a>";
        let items = parse_cards(page, HOST);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "标题");
        assert_eq!(
            items[0]["id"],
            "https://www.dsd.com.se/index.php/vod/play/id/123/sid/1/nid/1.html"
        );
    }

    #[test]
    fn page_count_reads_max() {
        assert_eq!(page_count("/page/2.html /page/10.html /page/3.html"), 10);
    }
}
