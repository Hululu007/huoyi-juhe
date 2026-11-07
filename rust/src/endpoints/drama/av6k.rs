//! AV6K（正妹AV）：`https://av6k.com`。
//!
//! jar 内 ZakaAv6kAmns 的移植。分类：最新影片（home）+ 8 个 c: 分
//! 类 + 女优索引（jar 里是 act 分类 + 女优筛选器，核心没有筛选器，
//! 按“女优做正式分类、作品卡片形式”的口径把 63 位女优展开成
//! act:{女优名} 分类，目录走站内搜索 /search/{女优名}-{页}.html）。
//! 分页：首页取尾页链接 `(\d+)_(\d+)\.html` 得到前缀与总页数，
//! home 走 /page/{前缀}_{页}.html，分类走 /{key}/{前缀}_{页}.html。
//! 详情取 data-hls-src 直给 m3u8（parse=0 透传，带 UA + Referer）。
//! 注意：本机出口取该 m3u8 回 451（CDN 法律原因拒绝），取流须手机
//! 侧复验；列表/详情/搜索本机已验通。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://av6k.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// jar 内 ACTRESSES 名单（buildFilters 的“女優”筛选值）。
const ACTRESSES: &[&str] = &[
    "春咲凉",
    "斎藤亞美里",
    "波多野結衣",
    "Julia",
    "篠田優",
    "明里紬",
    "深田詠美",
    "濱崎真緒",
    "神宮寺奈緒",
    "葵司",
    "櫻空桃",
    "伊藤舞雪",
    "桃乃木香奈",
    "天使萌",
    "橋本有菜",
    "北條麻妃",
    "白石茉莉奈",
    "本庄鈴",
    "星宮一花",
    "三上悠亞",
    "河北彩花",
    "相澤南",
    "涼森玲夢",
    "楓可憐",
    "希崎潔西卡",
    "松下紗榮子",
    "新井里真",
    "山手梨愛",
    "小宵虎南",
    "蒂亞",
    "朝桐光",
    "吉澤明步",
    "天海翼",
    "大橋未久",
    "明日花綺羅",
    "椎名由奈",
    "AIKA",
    "大槻響",
    "鈴木心春",
    "上原亞衣",
    "園田美櫻",
    "西野翔",
    "友田彩也香",
    "彩美旬果",
    "有坂深雪",
    "麻生希",
    "桃谷繪里香",
    "古川伊織",
    "市川雅美",
    "高橋聖子",
    "小島南",
    "東凜",
    "夏目彩春",
    "水野朝陽",
    "麻倉憂",
    "風見步",
    "佐山愛",
    "日向真凜",
    "鈴村愛里",
    "麻美由真",
    "佐佐木明希",
    "美谷朱里",
    "山岸逢花",
];

/// 8 个 c: 分类（key，中文名）。
const CATS: &[(&str, &str)] = &[
    ("rihanwuma", "日韓無碼"),
    ("rihanyouma", "日韓有碼"),
    ("jxny", "中文字幕"),
    ("chinese-av-porn", "國產AV"),
    ("fc2", "FC2無碼"),
    ("surenzipai", "自拍偷拍"),
    ("oumeiwuma", "歐美無碼"),
    ("chengrendongman", "成人動漫"),
];

/// 带头取页（jar 的 ZakaHttp.get 同款头）。
async fn fetch_text(url: &str) -> ApiResult<String> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-TW,zh;q=0.9,ja;q=0.8,en;q=0.7")
        .header("Referer", format!("{HOST}/"))
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("AV6K 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("AV6K 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!("AV6K 请求失败：HTTP {status}")));
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

/// 相对地址补成绝对地址（jar 的 abs）。
fn abs_url(u: &str) -> String {
    let u = u.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https:{rest}");
    }
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{u}")
}

/// jar 的 stripSuffix：去掉标题末尾的 | AV6K / | … 后缀。
fn strip_suffix(s: &str) -> String {
    let re = Regex::new(r"\s*[|｜]\s*.*$").unwrap();
    let s = re.replace(s, "");
    let re2 = Regex::new(r"\s*[|｜]\s*AV6K.*$").unwrap();
    re2.replace(&s, "").trim().to_string()
}

/// jar 的 clean：去标签、去 \u{a0}、去首尾空白。
fn clean(s: &str) -> String {
    let tag = Regex::new(r"<[^>]+>").unwrap();
    tag.replace_all(s, "")
        .replace('\u{a0}', " ")
        .trim()
        .to_string()
}

/// jar 的 toUrl：视频 id/路径归一成详情页完整地址。
fn to_url(id: &str) -> String {
    let id = id.trim();
    if id.starts_with("http") {
        return id.to_string();
    }
    if let Some(rest) = id.strip_prefix('/') {
        let rest = rest.to_string();
        if rest.ends_with(".html") {
            return format!("{HOST}/{rest}");
        }
        return format!("{HOST}/{rest}.html");
    }
    if id.ends_with(".html") {
        format!("{HOST}/{id}")
    } else {
        format!("{HOST}/{id}.html")
    }
}

/// 列表页解析：卡片 `<a href="...html" title="...">` + `<img src>` + 时长。
/// 段内按 jar 的 parseList：标题取 title 属性（空则“影片 {编号}”），
/// 封面取首个 img src，时长取 fa-play-circle-o 后文本，空则“AV6K”。
fn parse_list(html: &str, limit: usize) -> Vec<Value> {
    let link_re =
        Regex::new(r#"<a href="(/[A-Za-z0-9\-]+/[0-9/]*[0-9]+\.html)"\s+title="([^"]*)""#).unwrap();
    let img_re = Regex::new(r#"<img src="([^"]+)""#).unwrap();
    let dur_re = Regex::new(r#"fa fa-play-circle-o\s*"[^>]*></i>\s*([^<]{2,})"#).unwrap();
    let code_re = Regex::new(r"([A-Za-z]{2,8}-\d{2,6}(?:-\d{2,6})?)").unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for cap in link_re.captures_iter(html) {
        let path = cap.get(1).unwrap().as_str();
        if !seen.insert(path.to_string()) {
            continue;
        }
        let whole = cap.get(0).unwrap();
        // 按字节切 1200 窗口会切在中文字符中间导致 panic（与 99jj
        // 同款 bug）；把末尾退到字符边界再切。
        let mut seg_end = (whole.end() + 1200).min(html.len());
        while seg_end > whole.start() && !html.is_char_boundary(seg_end) {
            seg_end -= 1;
        }
        let seg = &html[whole.start()..seg_end];
        let raw_title = unesc(cap.get(2).unwrap().as_str()).trim().to_string();
        let title = if raw_title.is_empty() {
            code_re
                .captures(path)
                .map(|c| c[1].to_string())
                .unwrap_or_else(|| "AV6K 影片".to_string())
        } else {
            clean(&raw_title)
        };
        let pic = img_re
            .captures(seg)
            .map(|c| abs_url(&unesc(c.get(1).unwrap().as_str())))
            .unwrap_or_default();
        let remark = dur_re
            .captures(seg)
            .map(|c| clean(c.get(1).unwrap().as_str()))
            .filter(|d| !d.is_empty())
            .unwrap_or_else(|| "AV6K".to_string());
        out.push(item_json(&format!("{HOST}{path}"), &title, &pic, &remark));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// jar 的 catPager：从尾页链接 `(\d+)_(\d+)\.html` 取（前缀，总页数）。
fn cat_pager(html: &str) -> (String, i64) {
    let last_re =
        Regex::new(r#"href=['"]?([^'"\s>]+)['"]?[^>]*>\s*<i class=['"]fa fa-angle-double-right"#)
            .unwrap();
    let num_re = Regex::new(r"(\d+)_(\d+)\.html").unwrap();
    if let Some(cap) = last_re.captures(html) {
        let href = cap.get(1).unwrap().as_str();
        if let Some(nc) = num_re.captures(href) {
            let prefix = nc.get(1).unwrap().as_str().to_string();
            let total: i64 = nc.get(2).unwrap().as_str().parse().unwrap_or(1);
            return (prefix, total);
        }
    }
    (String::new(), 1)
}

/// 分类第 1 页地址；第 1 页之后用 cat_pager 拼 `{前缀}_{页}.html`。
fn page_one_url(id: &str) -> String {
    if id == "home" {
        format!("{HOST}/")
    } else if let Some(key) = id.strip_prefix("c:") {
        format!("{HOST}/{key}/")
    } else {
        format!("{HOST}/")
    }
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![category_json("home", "最新影片")];
    for name in ACTRESSES {
        list.push(category_json(
            &format!("act:{name}"),
            &format!("女優·{name}"),
        ));
    }
    for (key, name) in CATS {
        list.push(category_json(&format!("c:{key}"), name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let (items, has_more, total) = if let Some(name) = category_id.strip_prefix("act:") {
        let enc = urlencoding_name(name);
        let url = format!("{HOST}/search/{enc}-{page}.html");
        let html = fetch_text(&url).await?;
        let items = parse_list(&html, 24);
        let (_, total) = cat_pager(&html);
        (items, page < total, total)
    } else if category_id == "act" {
        // 裸 act 无女优名时走第一位女优（jar 里 act 须配筛选值）。
        let name = ACTRESSES.first().copied().unwrap_or("波多野結衣");
        let enc = urlencoding_name(name);
        let url = format!("{HOST}/search/{enc}-{page}.html");
        let html = fetch_text(&url).await?;
        let items = parse_list(&html, 24);
        let (_, total) = cat_pager(&html);
        (items, page < total, total)
    } else {
        let base = page_one_url(category_id);
        let (html, total) = if page == 1 {
            let html = fetch_text(&base).await?;
            let (_, total) = cat_pager(&html);
            (html, total)
        } else {
            let first = fetch_text(&base).await?;
            let (prefix, total) = cat_pager(&first);
            let dir = if category_id == "home" {
                format!("{HOST}/page/")
            } else if let Some(key) = category_id.strip_prefix("c:") {
                format!("{HOST}/{key}/")
            } else {
                format!("{HOST}/page/")
            };
            let url = format!("{dir}{prefix}_{page}.html");
            (fetch_text(&url).await?, total)
        };
        let items = parse_list(&html, 24);
        (items, page < total, total)
    };
    Ok(json!({
    "page": page,
    "pagecount": total.max(1),
    "limit": 24,
    "total": total,
    "has_more": has_more,
    // Dart 侧只认 "items"，原先只返 "list" 时应用层判“核心未返回
    // 目录”直接跳过本站；"list" 留着兼容旧调用（照 xx01 修法）。
    "items": items.clone(),
    "list": items,
    }))
}

/// 女优名/关键词做 URL 编码（空格变 %20，与 jar 的 eu 同款）。
fn urlencoding_name(name: &str) -> String {
    percent_encoding::utf8_percent_encode(name, percent_encoding::NON_ALPHANUMERIC).to_string()
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    let url = to_url(video_id);
    let html = fetch_text(&url).await?;
    let h2_re = Regex::new(r"<h2>(.*?)</h2>").unwrap();
    let title_re = Regex::new(r"<title>(.*?)</title>").unwrap();
    let title = h2_re
        .captures(&html)
        .map(|c| strip_suffix(&clean(c.get(1).unwrap().as_str())))
        .filter(|t| !t.is_empty())
        .or_else(|| {
            title_re
                .captures(&html)
                .map(|c| strip_suffix(&clean(c.get(1).unwrap().as_str())))
                .filter(|t| !t.is_empty())
        })
        .unwrap_or_else(|| "AV6K 影片".to_string());
    let img_re = Regex::new(r#"class="video-img">\s*<img src="([^"]+)""#).unwrap();
    let poster_re = Regex::new(r#"\sposter="([^"]+)""#).unwrap();
    let cover = img_re
        .captures(&html)
        .map(|c| abs_url(&unesc(c.get(1).unwrap().as_str())))
        .or_else(|| {
            poster_re
                .captures(&html)
                .map(|c| abs_url(&unesc(c.get(1).unwrap().as_str())))
        })
        .unwrap_or_default();
    let desc_re = Regex::new(r#"class="title">(.*?)</div>"#).unwrap();
    let synopsis = desc_re
        .captures(&html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .unwrap_or_default();
    let hls_re = Regex::new(r#"data-hls-src="([^"]+)""#).unwrap();
    let mp4_re = Regex::new(r#"https?://[^"'<>\s]+\.mp4[^"'<>\s]*"#).unwrap();
    let mut episodes = Vec::new();
    if let Some(cap) = hls_re.captures(&html) {
        let hls = abs_url(&unesc(cap.get(1).unwrap().as_str()));
        if !hls.is_empty() {
            episodes.push(episode_json(&format!("h|{hls}"), "AV6K·在線播放", &url));
        }
    }
    if let Some(cap) = mp4_re.captures(&html) {
        let mp4 = unesc(cap.get(0).unwrap().as_str());
        episodes.push(episode_json(&format!("m|{mp4}"), "AV6K·直連文件", &url));
    }
    Ok(json!({
    "id": url,
    "title": title,
    "cover": cover,
    "synopsis": synopsis,
    "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = urlencoding_name(query.trim());
    let url = format!("{HOST}/search/{enc}-1.html");
    let html = fetch_text(&url).await?;
    let items = parse_list(&html, 40);
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = video_id
        .strip_prefix("h|")
        .or_else(|| video_id.strip_prefix("m|"))
        .unwrap_or(video_id);
    if url.starts_with("http") {
        Ok(json!({"url": url}))
    } else {
        Err(ApiError::Internal("AV6K 该集没有播放地址".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_suffix_removes_site_suffix() {
        assert_eq!(strip_suffix("SDAM-126 影片 | 成人網"), "SDAM-126 影片");
        assert_eq!(strip_suffix("SDAM-126 影片 | AV6K"), "SDAM-126 影片");
    }

    #[test]
    fn cat_pager_reads_last_page() {
        let html = r#"<a href="/page/7_394.html"><i class="fa fa-angle-double-right"></i></a>"#;
        let (prefix, total) = cat_pager(html);
        assert_eq!(prefix, "7");
        assert_eq!(total, 394);
    }

    #[test]
    fn parse_list_reads_cards() {
        let html = r#"<div class="listAC"><a href="/rihanyouma/5370.html" title="SDAM-126 影片"><img src="/thumbnails/a.jpg"><i class="fa fa-play-circle-o"></i> 45:32</a></div>"#;
        let items = parse_list(html, 24);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "SDAM-126 影片");
        assert_eq!(items[0]["cover"], "https://av6k.com/thumbnails/a.jpg");
    }

    #[test]
    fn parse_list_window_does_not_panic_on_multibyte_tail() {
        // whole.end()+1200 落在中文字符中间时旧代码 panic；构造：
        // 链接后 1 个 ASCII + 400 个“中”（3 字节），1200 字节处正好
        // 切在第 400 个“中”中间。
        let pad = format!("x{}", "中".repeat(400));
        let html = format!(
            r#"<a href="/rihanyouma/5370.html" title="SDAM-126 影片"><img src="/thumbnails/a.jpg"><i class="fa fa-play-circle-o"></i> 45:32</a>{pad}"#
        );
        let items = parse_list(&html, 24);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "SDAM-126 影片");
    }

    #[tokio::test]
    #[ignore]
    async fn live_home_catalog_returns_items() {
        let r = catalog("home", 1).await.unwrap();
        let items = r["items"].as_array().unwrap();
        let list = r["list"].as_array().unwrap();
        eprintln!("LIVE av6k home items={} list={}", items.len(), list.len());
        assert!(!items.is_empty(), "av6k home catalog empty");
        assert_eq!(items.len(), list.len());
        assert!(!items[0]["id"].as_str().unwrap_or("").is_empty());
    }
}
