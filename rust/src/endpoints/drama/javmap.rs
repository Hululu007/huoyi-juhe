//! JAVMAP：`https://javmap.com/`。
//!
//! 来源 jar 类 `ZakaJavmapAmns`。列表页按 `<div class="th">` 切块，
//! 封面走 `images.x6av.com/getimages.php?src=<编码>&w=430&h=240`；
//! 详情取 `vid/cid`（`var vid = <n>, cid = <n>`）与 `data-pathid`
//! 三条线路（SW/SP/VH Server），分集 video_id 为
//! `jm|<vid>|<cid>|<pathid>`；取流 `resolve`：POST
//! `/e/DownSys/Player/`（`classid/id/pathid`）取 iframe 地址，
//! 抓 iframe 页、eval 打包解包（Dean Edwards packer）、再取 m3u8
//! 直链。搜索 POST `/e/search/index.php`。
//!
//! 实测（2026-11-05）：首页 200（32 条）、ListInfo 200、popular
//! 200、搜索 POST 200（12 条）；详情页当前无 `links = {...}`、
//! 无 eval 打包 JS，分集只走 data-pathid；pathid=0 的 iframe
//! （mmsi02）含 eval 包可解，已验出签名 m3u8 地址（标题/时长与详情
//! 一致），但清单本机出口 403；pathid=1（7mmtv）本机只回 477 字节
//! 空壳（无视频数据），取流一项须手机侧复验。详情日期正则取页内首个 `YYYY-MM-DD`。

use std::collections::HashMap;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const BASE: &str = "https://javmap.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const CATEGORIES: &[(&str, &str, &str)] = &[
    ("h:home", "★最新", ""),
    ("p:popular", "🔥热门", ""),
    ("c:censored", "有码 Censored", "1"),
    ("c:uncensored", "无码 Uncensored", "2"),
    ("c:amateur", "素人 Amateur", "3"),
    ("c:europe", "欧美 Europe", "4"),
    ("c:chinese-subtitles", "中文字幕", "5"),
    ("t:Over4Hours", "标签·Over4Hours", ""),
    ("t:DigitalMosaic", "标签·DigitalMosaic", ""),
    ("t:FeaturedActress", "标签·FeaturedActress", ""),
    ("t:Hi-Def", "标签·Hi-Def", ""),
    ("t:BigTits", "标签·BigTits", ""),
    ("t:Slender", "标签·Slender", ""),
    ("t:MarriedWoman", "标签·MarriedWoman", ""),
    ("t:Creampie", "标签·Creampie", ""),
    ("t:Drama", "标签·Drama", ""),
    ("t:Solowork", "标签·Solowork", ""),
    ("t:MatureWoman", "标签·MatureWoman", ""),
    ("t:Beautifulgirl", "标签·Beautifulgirl", ""),
];

/// 分类 id 拼列表页地址（jar 目录分支原样）。
fn cat_url(tid: &str, page: i64) -> String {
    match tid {
        "h:home" => format!("{BASE}/"),
        "p:popular" => {
            if page <= 1 {
                format!("{BASE}/popular/")
            } else {
                format!("{BASE}/popular/index_{page}.html")
            }
        }
        _ => {
            if let Some(tag) = tid.strip_prefix("t:") {
                let enc: String = url::form_urlencoded::byte_serialize(tag.as_bytes()).collect();
                return format!(
                    "{BASE}/e/tags/index.php?page={page}&tagname={enc}&line=20&tempid=2"
                );
            }
            if let Some(slug) = tid.strip_prefix("c:") {
                let classid = CATEGORIES
                    .iter()
                    .find(|(id, _, _)| *id == tid)
                    .map(|(_, _, c)| *c)
                    .unwrap_or("1");
                let _ = slug;
                return format!("{BASE}/e/action/ListInfo/?classid={classid}&page={page}");
            }
            format!("{BASE}/e/action/ListInfo/?classid=1&page={page}")
        }
    }
}

/// 去 HTML 标签与空白。
fn strip_tags(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let out = tag_re.replace_all(s, " ");
    let out = out
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ");
    ws_re.replace_all(out.trim(), " ").to_string()
}

/// 封面包装（jar `pic`）。
fn pic(src: &str) -> String {
    let src = src.trim();
    if src.is_empty() {
        return String::new();
    }
    if src.starts_with("http://") || src.starts_with("https://") {
        let enc: String = url::form_urlencoded::byte_serialize(src.as_bytes()).collect();
        return format!("https://images.x6av.com/getimages.php?src={enc}&w=430&h=240");
    }
    if let Some(rest) = src.strip_prefix("//") {
        return pic(&format!("https:{rest}"));
    }
    pic(&format!("{BASE}{src}"))
}

async fn fetch_html(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{BASE}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAVMAP 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// POST（jar 的搜索/取流共用头）。
async fn post_form(url: &str, body: &str) -> ApiResult<String> {
    let resp = client()?
        .post(url)
        .header("User-Agent", UA)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Accept", "application/json, text/javascript, */*; q=0.01")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("Referer", format!("{BASE}/"))
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("JAVMAP 请求 HTTP {status}")));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))
}

/// 列表解析（jar `parseList`）。
fn parse_list(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let list_re =
        Regex::new(r#"(?s)<div class="th">(.*?)<a class="th-description"[^>]*>(.*?)</a>"#).unwrap();
    let link_re = Regex::new(r#"href="(/[a-z0-9-]+/(\d+)\.html)""#).unwrap();
    let pic_re = Regex::new(r#"<img[^>]*src="([^"]+)""#).unwrap();
    let hd_re = Regex::new(r#"<span class="th-hd">([^<]*)</span>"#).unwrap();
    let dur_re = Regex::new(r#"class="th-duration"[^>]*>\s*<i[^>]*></i>([^<]*)<"#).unwrap();
    for c in list_re.captures_iter(html) {
        let block = &c[1];
        let title = strip_tags(&c[2]);
        let Some(lc) = link_re.captures(block) else {
            continue;
        };
        let id = lc[1].trim_start_matches('/').trim_end_matches(".html");
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let cover = pic_re
            .captures(block)
            .map(|p| pic(&p[1]))
            .unwrap_or_default();
        let hd = hd_re
            .captures(block)
            .map(|h| h[1].trim().to_string())
            .unwrap_or_default();
        let dur = dur_re
            .captures(block)
            .map(|d| d[1].trim().to_string())
            .unwrap_or_default();
        let mut remark = String::new();
        if !hd.is_empty() {
            remark.push_str(&hd);
        }
        if !dur.is_empty() {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&dur);
        }
        items.push(item_json(id, &title, &cover, &remark));
    }
    items
}

/// 分类名（jar `catName`）：classid → 分类名。
fn cat_name(cid: &str) -> &'static str {
    match cid {
        "1" => "有码",
        "2" => "无码",
        "3" => "素人",
        "4" => "欧美",
        "5" => "中文字幕",
        _ => "",
    }
}

/// 详情解析：标题/封面/日期/标签/简介/分集。
fn parse_detail(html: &str, id: &str) -> Value {
    let vid_re = Regex::new(r"var\s+vid\s*=\s*(\d+)\s*,\s*cid\s*=\s*(\d+)").unwrap();
    let (mut vid, mut cid) = (String::new(), String::new());
    if let Some(c) = vid_re.captures(html) {
        vid = c[1].to_string();
        cid = c[2].to_string();
    }
    if cid.is_empty() {
        let num_re = Regex::new(r"(\d+)\.html?$").unwrap();
        if let Some(c) = num_re.captures(id) {
            cid = c[1].to_string();
        }
    }
    if vid.is_empty() {
        vid = cid.clone();
    }
    let title_re = Regex::new(r#"(?s)<span class="inner-title">(.*?)</span>"#).unwrap();
    let mut title = title_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title>(.*?)</title>").unwrap();
        title = t_re
            .captures(html)
            .map(|c| strip_tags(&c[1]))
            .unwrap_or_default();
        if let Some(pos) = title.find(" - Javmap") {
            title = title[..pos].trim().to_string();
        }
    }
    let bg_re = Regex::new(r#"https://n[0-9]\.[0-9]+cdn\.sx/[^"'&)\s]+"#).unwrap();
    let mut cover = bg_re
        .captures(html)
        .map(|c| c[0].to_string())
        .unwrap_or_default();
    if cover.is_empty() {
        let bg2_re = Regex::new(r"background:\s*url\(([^)]+)\)").unwrap();
        cover = bg2_re
            .captures(html)
            .map(|c| pic(c[1].trim().trim_matches(|ch| ch == '\'' || ch == '"')))
            .unwrap_or_default();
    }
    let date_re = Regex::new(r"(\d{4}-\d{2}-\d{2})").unwrap();
    let date = date_re
        .captures(html)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let info_re = Regex::new(r#"(?s)<div id="av-data-info"[^>]*>(.*?)</div>"#).unwrap();
    let mut synopsis = info_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .unwrap_or_default();
    let tag_re = Regex::new(r#"<span class="tag">([^<]+)</span>"#).unwrap();
    let mut tags: Vec<String> = Vec::new();
    for c in tag_re.captures_iter(html) {
        let t = c[1].trim().to_string();
        if !t.is_empty() && !tags.contains(&t) && tags.len() < 24 {
            tags.push(t);
        }
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("\n标签：{}", tags.join(" / ")));
    }
    let path_re = Regex::new(r#"data-pathid="(\d+)"[^>]*>(?:.*?<span>([^<]*)</span>)?"#).unwrap();
    let mut episodes = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for c in path_re.captures_iter(html) {
        let pathid = c[1].to_string();
        if seen.contains(&pathid) {
            continue;
        }
        seen.push(pathid.clone());
        let label = c
            .get(2)
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let title = if label.is_empty() {
            "正片".to_string()
        } else {
            format!("正片·{label}")
        };
        episodes.push(episode_json(
            &format!("jm|{vid}|{cid}|{pathid}"),
            &title,
            id,
        ));
    }
    let mut extra = serde_json::Map::new();
    if !date.is_empty() {
        extra.insert("date".to_string(), json!(date));
    }
    let area = cat_name(&cid);
    if !area.is_empty() {
        extra.insert("area".to_string(), json!(area));
    }
    json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim().to_string(),
        "extra": extra,
        "episodes": episodes,
    })
}

/// Dean Edwards packer 解包：按 `encode(c, a)` 建词典替换。
fn unpack(p: &str, radix: u32, count: usize, keys: &[String]) -> String {
    const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    fn encode(mut n: usize, radix: u32, alphabet: &[u8]) -> String {
        if n == 0 {
            return (alphabet[0] as char).to_string();
        }
        let mut out = String::new();
        while n > 0 {
            out.insert(0, alphabet[(n % radix as usize)] as char);
            n /= radix as usize;
        }
        out
    }
    let mut dict: HashMap<String, String> = HashMap::new();
    for c in 0..count {
        let word = encode(c, radix, ALPHABET);
        let val = keys.get(c).cloned().unwrap_or_default();
        dict.insert(
            word,
            if val.is_empty() {
                encode(c, radix, ALPHABET)
            } else {
                val
            },
        );
    }
    let word_re = Regex::new(r"\b\w+\b").unwrap();
    word_re
        .replace_all(p, |caps: &regex::Captures| {
            dict.get(&caps[0])
                .cloned()
                .unwrap_or_else(|| caps[0].to_string())
        })
        .to_string()
}

/// 从文本里取 m3u8 直链（jar `pickLinks` 的正则）。
fn pick_m3u8(text: &str) -> String {
    let re =
        Regex::new(r#"https?://[^"'\\\s]+(?:master\.txt|master\.m3u8|\.m3u8)[^"'\\\s]*"#).unwrap();
    re.find(text)
        .map(|m| m.as_str().trim_end_matches(['"', '\'', '\\']).to_string())
        .unwrap_or_default()
}

/// 取流解析（jar `resolve`）：POST 取 iframe，抓页解包取 m3u8。
async fn resolve(play_id: &str) -> ApiResult<String> {
    let parts: Vec<&str> = play_id.split('|').collect();
    if parts.len() < 4 {
        return Err(ApiError::Internal("JAVMAP 分集编号格式错误".into()));
    }
    let (vid, cid, line) = (parts[1], parts[2], parts[3]);
    let body = format!(
        "classid={}&id={}&pathid={}",
        url::form_urlencoded::byte_serialize(cid.as_bytes()).collect::<String>(),
        url::form_urlencoded::byte_serialize(vid.as_bytes()).collect::<String>(),
        url::form_urlencoded::byte_serialize(line.as_bytes()).collect::<String>(),
    );
    let resp = post_form(&format!("{BASE}/e/DownSys/Player/"), &body).await?;
    let resp_json: Value = serde_json::from_str(&resp).unwrap_or(Value::Null);
    let player = text_of(&resp_json, &["player"]);
    if player.is_empty() {
        let direct = pick_m3u8(&resp);
        if !direct.is_empty() {
            return Ok(direct);
        }
        return Err(ApiError::Internal("JAVMAP 未返回播放器".into()));
    }
    let iframe_re = Regex::new(r#"<iframe[^>]*src=\\?"([^"\\]+)"#).unwrap();
    let iframe = iframe_re
        .captures(&player)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    if iframe.is_empty() {
        return Err(ApiError::Internal("JAVMAP 未找到嵌页地址".into()));
    }
    let iframe_url = if iframe.starts_with("//") {
        format!("https:{iframe}")
    } else if iframe.starts_with("http") {
        iframe
    } else {
        format!("{BASE}{iframe}")
    };
    let page = fetch_html(&iframe_url).await?;
    // 先直接找 m3u8，再解 eval 包找。
    let direct = pick_m3u8(&page);
    if !direct.is_empty() {
        return Ok(direct);
    }
    let eval_re = Regex::new(
        r#"eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)"#,
    )
    .unwrap();
    if let Some(c) = eval_re.captures(&page) {
        let packed = c[1].to_string();
        let radix: u32 = c[2].parse().unwrap_or(62);
        let count: usize = c[3].parse().unwrap_or(0);
        let keys: Vec<String> = c[4].split('|').map(|s| s.to_string()).collect();
        let unpacked = unpack(&packed, radix, count, &keys);
        let direct = pick_m3u8(&unpacked);
        if !direct.is_empty() {
            return Ok(direct);
        }
    }
    Err(ApiError::Internal("JAVMAP 未解析出播放地址".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATEGORIES
            .iter()
            .map(|(id, name, _)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = fetch_html(&cat_url(category_id, page)).await?;
    let items = parse_list(&html);
    let has_more = items.len() >= 15;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let url = format!("{BASE}/{id}.html");
    let html = fetch_html(&url).await?;
    Ok(parse_detail(&html, id))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let body = format!(
        "keyboard={}&show=title&tempid=1",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let resp = post_form(&format!("{BASE}/e/search/index.php"), &body).await?;
    let items = parse_list(&resp);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(rest) = video_id.strip_prefix("jm|") {
        let direct = resolve(&format!("jm|{rest}")).await?;
        return Ok(json!({"url": direct}));
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("JAVMAP 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cat_url_forms() {
        assert_eq!(cat_url("h:home", 1), "https://javmap.com/");
        assert_eq!(cat_url("p:popular", 1), "https://javmap.com/popular/");
        assert_eq!(
            cat_url("p:popular", 3),
            "https://javmap.com/popular/index_3.html"
        );
        assert_eq!(
            cat_url("c:uncensored", 2),
            "https://javmap.com/e/action/ListInfo/?classid=2&page=2"
        );
        assert_eq!(
            cat_url("t:Hi-Def", 1),
            "https://javmap.com/e/tags/index.php?page=1&tagname=Hi-Def&line=20&tempid=2"
        );
    }

    #[test]
    fn parse_list_blocks() {
        let html = r#"<div class="th"><a href="/censored/279311.html"><img src="https://n3.1024cdn.sx/censored/b/433331_34ID-019.jpg"></a><span class="th-hd">HD</span><div class="th-duration"><i></i>4:00:00</div><a class="th-description" href="/censored/279311.html">34ID-019 测试标题</a></div>"#;
        let items = parse_list(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "censored/279311");
        assert_eq!(items[0]["title"], "34ID-019 测试标题");
        assert_eq!(items[0]["remark"], "HD · 4:00:00");
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://images.x6av.com/getimages.php?src="));
    }

    #[test]
    fn unpack_roundtrip() {
        // packer 示例：p="0 1 2", a=62, c=3, k=["var","x","="] → "var x ="
        let out = unpack(
            "0 1 2",
            62,
            3,
            &["var".to_string(), "x".to_string(), "=".to_string()],
        );
        assert_eq!(out, "var x =");
    }

    #[test]
    fn pick_m3u8_links() {
        let text = "file: 'https://cdn.example.com/hls/master.m3u8?token=1'";
        assert_eq!(
            pick_m3u8(text),
            "https://cdn.example.com/hls/master.m3u8?token=1"
        );
        assert_eq!(pick_m3u8("nothing here"), "");
    }

    #[test]
    fn parse_detail_episodes() {
        let html = r#"var vid = 279311, cid = 1;<span class="inner-title">测试标题</span><div data-pathid="0"><span>SW Server</span></div><div data-pathid="1"><span>SP Server</span></div><div data-pathid="0"><span>SW Server</span></div><div id="av-data-info">简介文字</div><span class="tag">Big Tits</span>"#;
        let detail_value = parse_detail(html, "censored/279311");
        let eps = detail_value["episodes"].as_array().unwrap();
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0]["video_id"], "jm|279311|1|0");
        assert_eq!(eps[0]["title"], "正片·SW Server");
        assert!(detail_value["synopsis"]
            .as_str()
            .unwrap()
            .contains("标签：Big Tits"));
    }
}
