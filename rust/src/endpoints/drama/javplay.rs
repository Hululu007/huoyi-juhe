//! JavPlay（ja6play.com）：Next.js 站 + hid 取流接口。
//!
//! - 分类：latest 最新上传、popular 热门影片、tag 标签、series 系列、
//!   man 片商；子分类平铺为正式分类，id 用 tag:<值> / series:<值>
//!   / man:<值>（列表 URL 里 man 写作 manufacturer）。
//! - 列表：latest → /cn/latest?page=N；popular → /cn/popular；
//!   子分类 → /cn/category/{tag|series|manufacturer}/{编码}?page=N；
//!   无子值时 /cn/category?page=N。
//! - 卡片：<a href="/cn/video/..."> 锚点，其后 </a> 前取
//!   h3.video-title 标题、番号（番号…</span>…）、封面优先
//!   https://pic.ja6play.com/{番号}.webp。
//! - 详情：RSC 数据里找转义形态 \"hid\":\"，往回取最后一个 {、
//!   配对括号取 JSON（NEST3 三重转义先占位还原），字段 hid、
//!   barcode、title、thumbnail_large/small、description、
//!   manufacturer、upload_date、views、actors、tags；无 hid 时
//!   剧集为“正片$<详情 URL>”。
//! - 取流：GET {api.javplay.tv|av188.live}/api/get_m3u8.php?hid=，
//!   取 url（回退 url_cn），须以 http 开头。
//! - 说明：本层为站方自有免费播放层（高清试看片段），全长片在
//!   AV18 侧需站内授权。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://ja6play.com";
const API: &str = "https://api.javplay.tv";
const API_BAK: &str = "https://av188.live";
const PIC: &str = "https://pic.ja6play.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

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
        return Err(ApiError::Internal(format!("JavPlay 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 1500 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("JavPlay 页面异常（疑似盾拦截）".into()));
    }
    Ok(text)
}

/// 去标签 + 反转义 + 压空白。
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

/// URLEncoder 编码后 + 改 %20。
fn enc_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

fn list_url(category_id: &str, page: i64) -> String {
    let page_q = if page > 1 {
        format!("?page={page}")
    } else {
        String::new()
    };
    match category_id {
        "latest" => format!("{HOST}/cn/latest{page_q}"),
        "popular" => format!("{HOST}/cn/popular{page_q}"),
        "tag" | "series" | "man" => format!("{HOST}/cn/category{page_q}"),
        _ => {
            if let Some(v) = category_id.strip_prefix("tag:") {
                format!("{HOST}/cn/category/tag/{}{page_q}", enc_path(v))
            } else if let Some(v) = category_id.strip_prefix("series:") {
                format!("{HOST}/cn/category/series/{}{page_q}", enc_path(v))
            } else if let Some(v) = category_id.strip_prefix("man:") {
                format!("{HOST}/cn/category/manufacturer/{}{page_q}", enc_path(v))
            } else {
                format!("{HOST}/cn/latest{page_q}")
            }
        }
    }
}

fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let re = Regex::new(r#"<a\b[^>]*href="(/cn/video/[^"]+)"[^>]*>"#).unwrap();
    for c in re.captures_iter(html) {
        let href = c[1].to_string();
        let m = c.get(0).unwrap();
        let end = html[m.end()..]
            .find("</a>")
            .map(|i| m.end() + i)
            .unwrap_or((m.end() + 3000).min(html.len()));
        let seg = &html[m.end()..end];
        let title_re =
            Regex::new(r#"<h3[^>]*class="[^"]*video-title[^"]*"[^>]*>(.*?)</h3>"#).unwrap();
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
            continue;
        }
        let code_re = Regex::new(
            r"番号(?:\s*<!--\s*-->)?\s*[^<]{0,10}</span>\s*(?:<!--\s*-->)?\s*([^<\s]{2,32})",
        )
        .unwrap();
        let barcode = code_re
            .captures(seg)
            .map(|x| x[1].to_string())
            .unwrap_or_default();
        let pic = if !barcode.is_empty() {
            format!("{PIC}/{}.webp", enc_path(&barcode))
        } else {
            let img_re =
                Regex::new(r#"(?:data-src|src)="(https?://[^"]+?\.(?:webp|jpg|jpeg|png)[^"]*)""#)
                    .unwrap();
            img_re
                .captures(seg)
                .map(|x| x[1].to_string())
                .unwrap_or_default()
        };
        let tag_re =
            Regex::new(r#"<span[^>]*class="[^"]*\btag\b[^"]*"[^>]*>([^<]{1,24})</span>"#).unwrap();
        let mut remark = if barcode.is_empty() {
            "高清".to_string()
        } else {
            barcode.clone()
        };
        if let Some(t) = tag_re.captures(seg) {
            remark.push_str(" · ");
            remark.push_str(&t[1]);
        }
        if remark.chars().count() > 40 {
            remark = remark.chars().take(40).collect();
        }
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

/// RSC 数据里的 videoJson：找转义形态，往回取最后一个 {、配对
/// 括号取 JSON，三重转义先占位还原。
fn video_json(html: &str) -> Option<Value> {
    let needle = r#"\"hid\":\""#;
    let idx = html.find(needle)?;
    let start = html[..idx].rfind('{')?;
    let bytes = html.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = start;
    let mut end = None;
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
                end = Some(i);
                break;
            }
            depth -= 1;
        }
        i += 1;
    }
    let end = end?;
    let raw = &html[start..=end];
    let nest3 = r#"\\\""#;
    let step = raw.replace(nest3, "\u{0001}");
    let step = step.replace(r#"\""#, "\"");
    let step = step.replace("\u{0001}", r#"\""#);
    serde_json::from_str::<Value>(&step).ok()
}

async fn pick_stream(hid: &str) -> ApiResult<String> {
    for api in [API, API_BAK] {
        let url = format!("{api}/api/get_m3u8.php?hid={}", enc_path(hid));
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Accept-Encoding", "gzip, deflate")
            .header("Referer", format!("{HOST}/"))
            .header("Origin", HOST)
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()));
        let resp = match resp {
            Ok(r) => r,
            Err(_) => continue,
        };
        if resp.status().as_u16() != 200 {
            continue;
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        if text.len() < 10 {
            continue;
        }
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let mut url = value
            .get("url")
            .and_then(|u| u.as_str())
            .unwrap_or("")
            .to_string();
        if url.is_empty() {
            url = value
                .get("url_cn")
                .and_then(|u| u.as_str())
                .unwrap_or("")
                .to_string();
        }
        let url = clean(&url);
        if url.starts_with("http") {
            return Ok(url);
        }
    }
    Err(ApiError::Internal("JavPlay 未取到播放地址".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("latest", "最新上传"),
        category_json("popular", "热门影片"),
        category_json("tag", "标签"),
        category_json("series", "系列"),
        category_json("man", "片商"),
    ];
    let tags = [
        "人妻",
        "熟女",
        "巨乳",
        "美少女",
        "中出",
        "丝袜",
        "制服",
        "女教师",
        "护士",
        "痴女",
        "肛交",
        "颜射",
        "口交",
        "潮吹",
        "3P",
        "乱交",
        "义母",
        "不伦",
        "拘束",
        "SM",
        "调教",
        "按摩",
        "温泉",
        "泳装",
        "体操服",
        "眼镜",
        "爆乳",
        "素人",
        "中文",
        "独占配信",
        "4K",
        "偶像",
        "偷拍",
        "时间停止",
        "角色扮演",
        "户外",
        "OL",
        "秘书",
        "美腿",
    ];
    for t in tags {
        list.push(category_json(&format!("tag:{t}"), t));
    }
    let series = [
        "SNOS", "IPZZ", "JUR", "MIDA", "START", "JUL", "MIDV", "FSDSS", "MOGI", "PRED", "SONE",
        "CJOD", "MIAB", "JUQ", "MIMK", "DASS", "ROE", "FERA", "ALDN", "MOIL", "UZU", "JJGG",
        "LUCY", "NACT", "OAE", "WAAA", "XVSR", "MIZD", "MKMP", "ADN",
    ];
    for s in series {
        list.push(category_json(&format!("series:{s}"), s));
    }
    let mans = [
        "S1 Style",
        "MOODYZ",
        "IDEA POCKET",
        "SOD",
        "ATTACKERS",
        "ダスッ！",
        "センタービレッジ",
        "プラネットプラス",
        "瑪丹娜",
        "無資料",
        "ながえスタイル",
        "Fitch",
        "OPPAI",
        "E-BODY",
        "Kawaii",
        "PRESTIGE",
        "Alice Japan",
        "MAX-A",
        "GIGA",
        "Hunter",
        "DANDY",
        "人妻花園劇場",
        "BabyEntertainment",
    ];
    for m in mans {
        list.push(category_json(&format!("man:{m}"), m));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = get_text(&list_url(category_id, page)).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": items.len() >= 20}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let url = if series_id.starts_with("http") {
        series_id.to_string()
    } else {
        format!("{HOST}{series_id}")
    };
    let html = get_text(&url).await?;
    let vj = video_json(&html);
    let tail = url
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string();
    let mut title = vj
        .as_ref()
        .map(|v| {
            v.get("title")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default();
    if title.is_empty() {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").unwrap();
        if let Some(c) = t_re.captures(&html) {
            title = clean(&c[1]);
            if let Some(pos) = title.find(" | JavPlay") {
                title.truncate(pos);
            }
        }
    }
    if title.is_empty() {
        title = "JavPlay".to_string();
    }
    let mut cover = vj
        .as_ref()
        .map(|v| {
            let large = v
                .get("thumbnail_large")
                .and_then(|t| t.as_str())
                .unwrap_or("");
            if !large.is_empty() {
                return large.to_string();
            }
            v.get("thumbnail_small")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default();
    let barcode = vj
        .as_ref()
        .map(|v| {
            v.get("barcode")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default();
    let barcode = if barcode.is_empty() {
        tail.clone()
    } else {
        barcode
    };
    if cover.is_empty() && !barcode.is_empty() {
        cover = format!("{PIC}/{}.webp", enc_path(&barcode));
    }
    let hid = vj
        .as_ref()
        .map(|v| {
            v.get("hid")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default();
    let episode = if !hid.is_empty() {
        episode_json(&format!("j6p@{hid}@{barcode}"), "正片", series_id)
    } else {
        episode_json(&url, "正片", series_id)
    };
    let mut syn = String::from("站源：JavPlay（ja6play.com），免登录直取\n取流：站内 hid 接口，720p HLS 章节清单，无 DRM\n说明：本层为站方自有免费播放层（高清试看片段），全长片在 AV18 侧需站内授权");
    if !barcode.is_empty() {
        syn.push_str(&format!("\n番号：{barcode}"));
    }
    if let Some(v) = vj.as_ref() {
        let man = v.get("manufacturer").and_then(|t| t.as_str()).unwrap_or("");
        if !man.is_empty() {
            syn.push_str(&format!("\n片商：{man}"));
        }
        let up = v.get("upload_date").and_then(|t| t.as_str()).unwrap_or("");
        if up.len() >= 10 {
            syn.push_str(&format!("\n上架：{}", &up[..10]));
        }
        let views = v.get("views").and_then(|n| n.as_i64()).unwrap_or(0);
        if views > 0 {
            syn.push_str(&format!("\n点击：{views}"));
        }
        let actors = v.get("actors");
        let actors_s = match actors {
            Some(Value::Array(a)) => a
                .iter()
                .filter_map(|x| x.as_str())
                .collect::<Vec<_>>()
                .join("、"),
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        if !actors_s.is_empty() {
            syn.push_str(&format!("\n女优：{actors_s}"));
        }
        let desc = v.get("description").and_then(|t| t.as_str()).unwrap_or("");
        if !desc.is_empty() {
            syn.push_str(&format!("\n简介：{}", clean(desc)));
        }
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": syn,
        "extra": {"vod_play_from": "JavPlay"},
        "episodes": [episode],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(rest) = video_id.strip_prefix("j6p@") {
        let hid = rest.split('@').next().unwrap_or("");
        if hid.is_empty() {
            return Err(ApiError::Internal("JavPlay 缺少 hid".into()));
        }
        let url = pick_stream(hid).await?;
        return Ok(json!({
            "url": url,
            "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let url = if video_id.starts_with("http") {
        video_id.to_string()
    } else {
        format!("{HOST}{video_id}")
    };
    let html = get_text(&url).await?;
    let hid = video_json(&html)
        .and_then(|v| v.get("hid").and_then(|t| t.as_str()).map(|s| s.to_string()))
        .unwrap_or_default();
    if hid.is_empty() {
        return Err(ApiError::Internal("JavPlay 详情页未找到 hid".into()));
    }
    let stream = pick_stream(&hid).await?;
    Ok(json!({
        "url": stream,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let html = get_text(&format!("{HOST}/cn/category/search/{}", enc_path(query))).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_url_shapes() {
        assert_eq!(list_url("latest", 1), "https://ja6play.com/cn/latest");
        assert_eq!(
            list_url("latest", 2),
            "https://ja6play.com/cn/latest?page=2"
        );
        assert_eq!(
            list_url("tag:人妻", 1),
            "https://ja6play.com/cn/category/tag/%E4%BA%BA%E5%A6%BB"
        );
        assert_eq!(
            list_url("man:S1 Style", 1),
            "https://ja6play.com/cn/category/manufacturer/S1%20Style"
        );
    }

    #[test]
    fn video_json_unescapes() {
        let html =
            r#"x{\"video\":{\"hid\":\"QC-BT-4751412\",\"barcode\":\"YMDS-332\",\"title\":\"T\"}}y"#;
        let v = video_json(html).unwrap();
        assert_eq!(v["hid"], "QC-BT-4751412");
        assert_eq!(v["barcode"], "YMDS-332");
    }

    #[test]
    fn parse_cards_sample() {
        let html = r#"<a class="relative block" href="/cn/video/YMDS-332"><h3 class="video-title font-medium line-clamp-2">标题</h3><div class="video-meta"><p><span class="font-semibold">番号<!-- -->:</span> <!-- -->YMDS-332</p></div></a>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["cover"], "https://pic.ja6play.com/YMDS-332.webp");
        assert_eq!(items[0]["remark"], "YMDS-332");
    }
}
