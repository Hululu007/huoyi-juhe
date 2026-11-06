//! 正妹AV（goodav）：`https://goodav17.com`。
//!
//! jar 内 ZakaGoodavAmns 的移植。分类：最近更新/VR專區/本
//! 土自拍/女優作品 + 站内导航的 51 个類型（live 导航原有 52 个，
//! “蘿莉”一类按用户口径只删该分类、站照常写）+ 120 位女优
//! （live 导航快照，a:{女优名}，作品卡片形式）。
//! 列表每页 23 条，`/{页}/`、`/type/{类}/{页}/`、`/actor/{名}/{页}/`、
//! `/vr/{页}/`、`/local/{页}/`；卡片 id：html→数字、vr→vr+数字、
//! local→lc+数字。详情取 m_image/m_designation/m_actor/m_type/
//! m_seed_link 与剧照；取流三线：ggjav 内嵌（u= base64 解出 mp4
//! 再拼 /index.m3u8）、porn87 内嵌（扫 m3u8）、youjizz 内嵌、
//! VR 直链（vr.goodav17.com/media/...mp4|m3u8）。
//! 注意：VR 媒体域名本机出口连不上（RemoteDisconnected），VR 线
//! 须手机侧复验；yj 线本次未见活例，按 jar 同款写法实现、未实测。

use std::collections::HashSet;

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://goodav17.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 51 个類型（live 导航 52 个减去“蘿莉”，jar 的 TYPES 原文）。
const TYPES: &[&str] = &[
    "OL",
    "SM",
    "不能發聲",
    "中出",
    "乳交",
    "人妻",
    "兔女郎",
    "其他制服",
    "凌辱",
    "另類癖好",
    "可愛",
    "吞精",
    "和服",
    "多P",
    "多名女優",
    "女僕",
    "女優出租",
    "女友",
    "女醫生",
    "姐姐",
    "學生",
    "家政婦",
    "巨乳",
    "強迫",
    "感謝祭",
    "戶外",
    "打手槍",
    "搜查官",
    "教師或家教",
    "普通",
    "泡泡浴",
    "潮吹",
    "無毛",
    "無碼",
    "癡女",
    "癡漢",
    "秘書",
    "空姐",
    "突然插入",
    "素人",
    "絲襪",
    "美尻",
    "美腿",
    "肛交",
    "自慰",
    "護士",
    "足交",
    "輕熟女",
    "近親相姦",
    "顏射",
    "首次亮相",
];

/// 120 位女优（live 导航快照，jar 的 loadNav 同款）。
const ACTORS: &[&str] = &[
    "AIKA",
    "Julia",
    "三上悠亞",
    "上原亞衣",
    "乙白沙耶加",
    "二階堂夢",
    "仁美圓",
    "佐佐木明希",
    "佐佐波綾",
    "佐山愛",
    "佳苗琉華",
    "倉多真央",
    "冬月楓",
    "凛音桃花",
    "前田香織",
    "北川繪里香",
    "北条麻妃",
    "友田彩也香",
    "古川伊織",
    "吉澤明步",
    "園田美櫻",
    "堀北灣",
    "夏希栗",
    "夏目彩春",
    "大槻響",
    "大橋未久",
    "天使萌",
    "天海翼",
    "天音真比奈",
    "宇都宮紫苑",
    "小宵虎南",
    "小島南",
    "小早川憐子",
    "小花暖",
    "小野寺梨紗",
    "山岸逢花",
    "山手梨愛",
    "市川雅美",
    "希島愛理",
    "希崎杰西卡",
    "彩美旬果",
    "愛音麻里亞",
    "日向真凜",
    "日高千晶",
    "明日花綺羅",
    "明里紬",
    "星奈愛",
    "星宮一花",
    "星谷瞳",
    "春咲凉",
    "有坂深雪",
    "有栖花あか",
    "朝桐光",
    "朝比奈菜々子",
    "木下和津實",
    "木下日葵",
    "本田莉子",
    "東凜",
    "松嵨葵",
    "松本芽依",
    "林由奈",
    "桃乃木香奈",
    "桃谷繪里香",
    "椎名由奈",
    "楓可憐",
    "楪可憐",
    "橋本有菜",
    "橘美鈴",
    "櫻空桃",
    "水谷心音",
    "水野朝陽",
    "沖田杏梨",
    "沙月芽衣",
    "河北彩花",
    "河北麻衣",
    "波多野結衣",
    "深田詠美",
    "濱崎真緒",
    "白石茉莉奈",
    "相澤南",
    "真白愛梨",
    "神咲詩織",
    "神宮寺奈緒",
    "神波多一花",
    "神雪",
    "篠田優",
    "篠田步美",
    "美乃雀",
    "美咲佳奈",
    "美月優芽",
    "美谷朱里",
    "芽森滴",
    "若菜奈央",
    "菜菜葉",
    "葉風優莉亞",
    "葵",
    "蒂亞",
    "蓮實克萊兒",
    "蕾",
    "藍芽水月",
    "蜜美杏",
    "衣吹花音",
    "西野翔",
    "輝月杏梨",
    "都盛星空",
    "里美尤利婭",
    "鈴木心春",
    "鈴村愛里",
    "長谷川琉依",
    "霧島レオナ",
    "風見步",
    "飯岡加奈子",
    "香苗玲音",
    "高橋聖子",
    "高見怜奈",
    "麻倉憂",
    "麻生希",
    "麻生芽依",
    "麻美由真",
    "齋藤亞美里",
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
        .map_err(|e| ApiError::Internal(format!("正妹AV 请求失败：{e}")))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(format!("正妹AV 读响应失败：{e}")))?;
    if !status.is_success() {
        return Err(ApiError::Internal(format!(
            "正妹AV 请求失败：HTTP {status}"
        )));
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

/// 相对地址补成绝对地址（jar 的 abs）。
fn abs_url(u: &str) -> String {
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
    if let Some(rest) = u.strip_prefix('/') {
        return format!("{HOST}/{rest}");
    }
    format!("{HOST}/{u}")
}

/// jar 的 eu：URL 编码（空格变 %20）。
fn eu(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// jar 的 urlSafe：流地址里的空格编成 %20。
fn url_safe(u: &str) -> String {
    u.replace(' ', "%20")
}

/// jar 的 listPath：分类拼列表地址。
fn list_path(tid: &str, page: i64) -> String {
    if let Some(name) = tid.strip_prefix("t:") {
        format!("{HOST}/type/{}/{page}/", eu(name))
    } else if let Some(name) = tid.strip_prefix("a:") {
        format!("{HOST}/actor/{}/{page}/", eu(name))
    } else if tid == "actor" {
        format!("{HOST}/actor/{}/{page}/", eu(ACTORS[0]))
    } else if tid == "vr" {
        format!("{HOST}/vr/{page}/")
    } else if tid == "local" {
        format!("{HOST}/local/{page}/")
    } else {
        format!("{HOST}/{page}/")
    }
}

/// jar 的 detailUrl：卡片 id 还原成详情地址。
fn detail_url(vod_id: &str) -> String {
    if let Some(num) = vod_id.strip_prefix("vr") {
        format!("{HOST}/vr_html/{num}/")
    } else if let Some(num) = vod_id.strip_prefix("lc") {
        format!("{HOST}/local_html/{num}/")
    } else {
        format!("{HOST}/html/{vod_id}/")
    }
}

/// 列表解析：`<div class='movie'>` 块；id 取路径里的数字（前缀
/// vr/local 分别记 vr/lc），封面取 large_image 否则 img src，
/// 标题取详情链接文本（空则取 img alt，再空则“影片 {id}”）。
fn parse_list(html: &str, limit: usize) -> Vec<Value> {
    let block_re = Regex::new(r"<div class='movie'>").unwrap();
    let id_re = Regex::new(r"goodav17\.com/(vr_html/|local_html/|html/)(\d+)/").unwrap();
    let large_re = Regex::new(r"large_image='([^']+)'").unwrap();
    let img_re = Regex::new(r"<img\s+src='([^']+)'").unwrap();
    let title_re = Regex::new(
        r#"<a href="https://goodav17\.com/(?:vr_html/|local_html/|html/)\d+/">([^<]+)</a>"#,
    )
    .unwrap();
    let alt_re = Regex::new(r"alt='([^']{6,})'").unwrap();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let parts: Vec<&str> = block_re.split(html).collect();
    for part in parts.iter().skip(1) {
        let seg = &part[..part.len().min(2600)];
        let Some(cap) = id_re.captures(seg) else {
            continue;
        };
        let prefix = cap.get(1).unwrap().as_str();
        let num = cap.get(2).unwrap().as_str();
        let vod_id = match prefix {
            "vr_html/" => format!("vr{num}"),
            "local_html/" => format!("lc{num}"),
            _ => num.to_string(),
        };
        if !seen.insert(vod_id.clone()) {
            continue;
        }
        let title = title_re
            .captures(seg)
            .map(|c| clean(c.get(1).unwrap().as_str()))
            .filter(|t| !t.is_empty())
            .or_else(|| {
                alt_re
                    .captures(seg)
                    .map(|c| clean(c.get(1).unwrap().as_str()))
                    .filter(|t| !t.is_empty())
            })
            .unwrap_or_else(|| format!("影片 {vod_id}"));
        let pic = large_re
            .captures(seg)
            .map(|c| abs_url(c.get(1).unwrap().as_str()))
            .or_else(|| {
                img_re
                    .captures(seg)
                    .map(|c| abs_url(c.get(1).unwrap().as_str()))
            })
            .unwrap_or_default();
        out.push(item_json(&vod_id, &title, &pic, "正妹AV"));
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// 页内 `max_page = N`（总页数），没有则回 1。
fn max_page(html: &str) -> i64 {
    let re = Regex::new(r"max_page\s*=\s*(\d+)").unwrap();
    re.captures(html)
        .and_then(|c| c.get(1).unwrap().as_str().parse().ok())
        .unwrap_or(1)
}

/// jar 的 lineName：线路 id 前缀定线路名。
fn line_name(line_id: &str) -> &'static str {
    if line_id.starts_with("gv|") {
        "⚡ 線上播放"
    } else if line_id.starts_with("pr|") {
        "⚡ 本土自拍"
    } else if line_id.starts_with("vm|") {
        "VR播放"
    } else if line_id.starts_with("yj|") {
        "備用線路"
    } else {
        "線路"
    }
}

/// jar 的 embedPick：从详情页取内嵌源，拼成线路 id。
/// gg：u= base64 解出 mp4（去查询串）→ `gv|{mp4}`；
/// pr：porn87 id → `pr|{id}`；yj：youjizz id → `yj|{id}`。
fn embed_pick(html: &str) -> Vec<String> {
    let mut out = Vec::new();
    let gg_re = Regex::new(r"https://ggjav\.com/main/embed\?u=([A-Za-z0-9_\-=+/%]+)").unwrap();
    if let Some(cap) = gg_re.captures(html) {
        let b64 = cap
            .get(1)
            .unwrap()
            .as_str()
            .replace("%3D", "=")
            .replace("%3d", "=");
        if let Ok(decoded) =
            base64::Engine::decode(&base64::engine::general_purpose::STANDARD, b64.as_bytes())
        {
            let mp4 = String::from_utf8_lossy(&decoded).to_string();
            let mp4 = mp4.split('?').next().unwrap_or("").to_string();
            if mp4.starts_with("http") && mp4.contains(".mp4") {
                out.push(format!("gv|{}", url_safe(&mp4)));
            }
        }
    }
    let pr_re = Regex::new(r"porn87\.com/main/embed\?id=(\d+)").unwrap();
    if let Some(cap) = pr_re.captures(html) {
        out.push(format!("pr|{}", cap.get(1).unwrap().as_str()));
    }
    let yj_re = Regex::new(r"https?://(?:www\.)?youjizz\.com/videos/embed/(\d+)").unwrap();
    if let Some(cap) = yj_re.captures(html) {
        out.push(format!("yj|{}", cap.get(1).unwrap().as_str()));
    }
    out
}

/// 详情页的 m_* 字段（jar 的 D_* 正则同款）。
fn m_field(html: &str, id: &str) -> String {
    let re = Regex::new(&format!(r"id='{id}'>(.*?)</div>")).unwrap();
    re.captures(html)
        .map(|c| clean(c.get(1).unwrap().as_str()))
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("home", "最近更新"),
        category_json("vr", "VR專區"),
        category_json("local", "本土自拍"),
        category_json("actor", "女優作品"),
    ];
    for t in TYPES {
        list.push(category_json(&format!("t:{t}"), &format!("類型·{t}")));
    }
    for name in ACTORS {
        list.push(category_json(&format!("a:{name}"), &format!("女優·{name}")));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let url = list_path(category_id, page);
    let html = fetch_text(&url).await?;
    let total = max_page(&html);
    let items = parse_list(&html, 23);
    Ok(json!({
        "page": page,
        "pagecount": total.max(1),
        "limit": 23,
        "total": total,
        "has_more": page < total,
        "list": items,
    }))
}

pub(crate) async fn detail(video_id: &str) -> ApiResult<Value> {
    let url = detail_url(video_id);
    let html = fetch_text(&url).await?;
    let title_re = Regex::new(r"<title>(.*?)</title>").unwrap();
    let og_title_re = Regex::new(r#"og:title' content="([^"]+)""#).unwrap();
    let suffix_re = Regex::new(r"\s*[-|]\s*正妹AV.*$").unwrap();
    let title = title_re
        .captures(&html)
        .map(|c| clean(suffix_re.replace(c.get(1).unwrap().as_str(), "").as_ref()))
        .filter(|t| !t.is_empty())
        .or_else(|| {
            og_title_re
                .captures(&html)
                .map(|c| clean(suffix_re.replace(c.get(1).unwrap().as_str(), "").as_ref()))
                .filter(|t| !t.is_empty())
        })
        .unwrap_or_else(|| format!("影片 {video_id}"));
    let img_re = Regex::new(r"id='m_image'>\s*<img src='([^']+)'").unwrap();
    let og_img_re = Regex::new(r#"og:image['"]\s+content=['"]([^'"]+)['"]"#).unwrap();
    let cover = img_re
        .captures(&html)
        .map(|c| abs_url(c.get(1).unwrap().as_str()))
        .or_else(|| {
            og_img_re
                .captures(&html)
                .map(|c| abs_url(c.get(1).unwrap().as_str()))
        })
        .unwrap_or_default();
    let code = m_field(&html, "m_designation")
        .replace("番號:", "")
        .replace("番號：", "")
        .trim()
        .to_string();
    let actors = m_field(&html, "m_actor")
        .replace("女優:", "")
        .replace("女優：", "")
        .trim()
        .to_string();
    let types = m_field(&html, "m_type")
        .replace("類型:", "")
        .replace("類型：", "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" / ");
    let seed = m_field(&html, "m_seed_link");
    let mut synopsis = String::new();
    if !code.is_empty() {
        synopsis.push_str(&format!("番號：{code}\n"));
    }
    if !actors.is_empty() {
        synopsis.push_str(&format!("女優: {actors}\n"));
    }
    if !types.is_empty() {
        synopsis.push_str(&format!("類型: {types}\n"));
    }
    if !seed.is_empty() {
        synopsis.push_str(&format!("{seed}\n"));
    }
    let mut episodes = Vec::new();
    let mut seen = HashSet::new();
    for line_id in embed_pick(&html) {
        if !seen.insert(line_id.clone()) {
            continue;
        }
        let name = line_name(&line_id);
        episodes.push(episode_json(&line_id, &format!("正妹AV·{name}"), &url));
    }
    // VR 直链（jar 的 vrm 同款）。
    let vr_re =
        Regex::new(r"https://vr\.goodav17\.com/media/[A-Za-z0-9_\-]+\.(?:mp4|m3u8)").unwrap();
    for cap in vr_re.captures_iter(&html) {
        let media = cap.get(0).unwrap().as_str();
        let line_id = format!("vm|{media}");
        if !seen.insert(line_id.clone()) {
            continue;
        }
        episodes.push(episode_json(&line_id, "正妹AV·VR播放", &url));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(
            &format!("web|{url}"),
            "正妹AV·官方頁面（此片暫無站內源，可看圖集/簡介）",
            &url,
        ));
    }
    Ok(json!({
        "id": video_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim(),
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = eu(query.trim());
    let url = format!("{HOST}/search/{enc}/1/");
    let html = fetch_text(&url).await?;
    let items = parse_list(&html, 40);
    Ok(json!({"items": items}))
}

/// 内嵌页扫流：先取 `var videoSrc`，空则扫页内 m3u8/mp4。
fn scan_embed(html: &str) -> Option<String> {
    let vs_re = Regex::new(r#"var videoSrc="([^"]+)""#).unwrap();
    if let Some(cap) = vs_re.captures(html) {
        let u = unesc(cap.get(1).unwrap().as_str());
        if u.starts_with("http") {
            return Some(u);
        }
    }
    let re = Regex::new(r#"https?://[^"'<>\s]+\.m3u8[^"'<>\s]*"#).unwrap();
    if let Some(cap) = re.captures(html) {
        return Some(unesc(cap.get(0).unwrap().as_str()));
    }
    let re2 = Regex::new(r#"https?://[^"'<>\s]+\.mp4[^"'<>\s]*"#).unwrap();
    re2.captures(html)
        .map(|c| unesc(c.get(0).unwrap().as_str()))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if let Some(mp4) = video_id.strip_prefix("gv|") {
        // gg 线：mp4 去尾斜杠再拼 /index.m3u8（jar 的 play 同款）。
        let base = mp4.trim_end_matches('/');
        return Ok(json!({"url": format!("{base}/index.m3u8")}));
    }
    if let Some(id) = video_id.strip_prefix("pr|") {
        let html = fetch_text(&format!("https://porn87.com/main/embed?id={id}")).await?;
        if let Some(stream) = scan_embed(&html) {
            return Ok(json!({"url": stream}));
        }
        return Err(ApiError::Internal("正妹AV 本土自拍线无流".into()));
    }
    if let Some(id) = video_id.strip_prefix("yj|") {
        let html = fetch_text(&format!("https://www.youjizz.com/videos/embed/{id}")).await?;
        if let Some(stream) = scan_embed(&html) {
            return Ok(json!({"url": stream}));
        }
        return Err(ApiError::Internal("正妹AV 備用線路无流".into()));
    }
    if let Some(url) = video_id.strip_prefix("vm|") {
        if url.starts_with("http") {
            return Ok(json!({"url": url}));
        }
    }
    if let Some(url) = video_id.strip_prefix("web|") {
        if url.starts_with("http") {
            return Ok(json!({"url": url}));
        }
    }
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    Err(ApiError::Internal("正妹AV 该集没有播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detail_url_roundtrips_ids() {
        assert_eq!(detail_url("21075"), "https://goodav17.com/html/21075/");
        assert_eq!(detail_url("vr325"), "https://goodav17.com/vr_html/325/");
        assert_eq!(
            detail_url("lc4174"),
            "https://goodav17.com/local_html/4174/"
        );
    }

    #[test]
    fn list_path_builds_all_kinds() {
        assert_eq!(list_path("home", 2), "https://goodav17.com/2/");
        assert_eq!(list_path("vr", 1), "https://goodav17.com/vr/1/");
        assert_eq!(
            list_path("t:巨乳", 1),
            "https://goodav17.com/type/%E5%B7%A8%E4%B9%B3/1/"
        );
    }

    #[test]
    fn embed_pick_decodes_gg() {
        let html = r#"https://ggjav.com/main/embed?u=aHR0cHM6Ly92aWRlby04LmdnamF2LmNvbS92aWRlb18xLzE3OTgyMS1TT05FLTg4NC5tcDQ="#;
        let lines = embed_pick(html);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].starts_with("gv|https://video-8.ggjav.com/"));
    }
}
