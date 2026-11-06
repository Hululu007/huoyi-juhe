//! 喜马拉雅（ximalaya.com，主流有声平台，非成人）。
//!
//! 照搬 py 原文：10 个一级分类；目录走 category/v2/albums（默认
//! 最热、无题材筛选——py 的 sort/cat/tag 筛选走 metadata/info 接口，
//! 范式 catalog 签名里没有筛选参数，故固定 sort=0、无 meta）；专辑
//! 曲目走 mobile 端 track 接口（每页 200、最多 60 页），device 按
//! 缓存提示 → android → ios 试到有音源为止；取流先按集序定位页现
//! 取签名地址（_url_at），再依次兜 web 播放接口、同名免费音频；
//! VIP 专辑详情里另附站内同名免费专辑的曲目（标题带免费同书前缀，
//! video_id 里带的是免费专辑 id，取流同样走 _url_at）。
//! _get 带 3 次重试（退避 0.25s×次数）与 600 条 URL 缓存（无 TTL，
//! 与 py 一致——注意签名地址会过期，缓存命中时可能拿到过期地址，
//! 这是 py 原文就有的行为）；init 的 cookie/maxTracks/perPage/
//! split 核心签名里没有，固定 perPage=200、maxTracks=0（不限）、
//! split=0（不拆线路）。_dur 在 py 里定义后未被音频链路使用，不引。

use std::collections::HashMap;
use std::sync::Mutex;

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of,
};
use crate::error::{ApiError, ApiResult};

const HOST: &str = "https://www.ximalaya.com";
const MOBILE: &str = "https://mobile.ximalaya.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const UA_M: &str = "Mozilla/5.0 (Linux; Android 12; Build/SP1A.210812.016) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const IMG: &str = "https://imagev2.xmcdn.com/";
const PER_PAGE: i64 = 200;

const CATEGORIES: [(&str, &str); 10] = [
    ("3", "有声书"),
    ("2", "音乐"),
    ("12", "相声评书"),
    ("4", "娱乐"),
    ("6", "儿童"),
    ("9", "历史"),
    ("8", "商业财经"),
    ("13", "个人成长"),
    ("5", "外语"),
    ("15", "广播剧"),
];

static CACHE: Lazy<Mutex<HashMap<String, Value>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static DEV_HINT: Lazy<Mutex<HashMap<String, String>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static BRACKET_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"【[^】]*】|\[[^\]]*\]|（[^）]*）|\([^)]*\)").unwrap());
static PUNCT_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"[丨|｜·、,，.。:：!！?？\"'“”/\\-]+"#).unwrap());
static KW_DROP_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)vip|免费|多人有声剧|有声剧|有声书|演播|出品|独家|完结|全集|首发").unwrap()
});
static WS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());

/// py _fix_img：绝对地址强制 https，// 补 https:，相对地址拼图床。
fn fix_img(p: &str) -> String {
    if p.is_empty() {
        return String::new();
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return p.replacen("http://", "https://", 1);
    }
    if let Some(rest) = p.strip_prefix("//") {
        return format!("https://{rest}");
    }
    format!("{}{}", IMG, p.trim_start_matches('/'))
}

/// py urllib.parse.quote 默认 safe="/"。
fn quote(s: &str) -> String {
    let mut out = String::new();
    for &b in s.as_bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || "-_.~/".contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// py 的真值判断（isPaid/albumPayType 可能是布尔或数字）。
fn truthy(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_i64().is_some_and(|i| i != 0),
        Some(Value::String(s)) => !s.is_empty(),
        _ => false,
    }
}

async fn fetch_once(url: &str, mobile: bool) -> ApiResult<Value> {
    let mut req = client()?.get(url);
    if mobile {
        req = req
            .header("User-Agent", UA_M)
            .header("Accept", "application/json, text/plain, */*")
            .header("Accept-Language", "zh-CN,zh;q=0.9")
            .header("device", "android");
    } else {
        req = req
            .header("User-Agent", UA)
            .header("Referer", format!("{HOST}/"))
            .header("Accept", "application/json, text/plain, */*")
            .header("Accept-Language", "zh-CN,zh;q=0.9");
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("喜马拉雅请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    if !body.is_object() {
        return Err(ApiError::Internal("喜马拉雅数据格式无法识别".into()));
    }
    Ok(body)
}

/// py _get：URL 缓存（600 条封顶、无 TTL）+ 3 次重试（退避同 py）。
async fn get_json(url: &str, mobile: bool) -> ApiResult<Value> {
    if let Ok(cache) = CACHE.lock() {
        if let Some(v) = cache.get(url) {
            return Ok(v.clone());
        }
    }
    let mut last: Option<ApiError> = None;
    for attempt in 0..3 {
        match fetch_once(url, mobile).await {
            Ok(data) => {
                if let Ok(mut cache) = CACHE.lock() {
                    if cache.len() < 600 {
                        cache.insert(url.to_string(), data.clone());
                    }
                }
                return Ok(data);
            }
            Err(e) => {
                last = Some(e);
                tokio::time::sleep(std::time::Duration::from_millis(
                    (250 * (attempt + 1)) as u64,
                ))
                .await;
            }
        }
    }
    Err(last.unwrap_or_else(|| ApiError::Internal("喜马拉雅请求失败".into())))
}

async fn feed(cid: &str, pg: i64, size: i64, sort: &str) -> Vec<Value> {
    let url = format!(
        "{HOST}/revision/category/v2/albums?categoryId={cid}&pageNum={pg}&pageSize={size}&sort={sort}"
    );
    let data = match get_json(&url, false).await {
        Ok(v) => get(&v, "data").cloned().unwrap_or(Value::Null),
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    if let Some(albums) = get(&data, "albums").and_then(arr_of) {
        for a in albums {
            let paid = if truthy(get(a, "isPaid")) {
                "【VIP】"
            } else {
                ""
            };
            let title = format!("{paid}{}", text_of(a, &["albumTitle"]));
            let cover = fix_img(&text_of(a, &["albumCoverPath"]));
            let count = text_of(a, &["albumTrackCount"]);
            let count = if count.is_empty() {
                "?".to_string()
            } else {
                count
            };
            out.push(item_json(
                &text_of(a, &["albumId"]),
                &title,
                &cover,
                &format!("{count}集"),
            ));
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let tid = category_id.split('|').next().unwrap_or("");
    let pg = if page < 1 { 1 } else { page };
    let items = feed(tid, pg, 30, "0").await;
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let kw = quote(query.trim());
    let url = format!(
        "{HOST}/revision/search/seo?core=album&kw={kw}&page=1&spellchecker=true&rows=30&condition=relation&device=iPhone"
    );
    let docs = get_json(&url, false)
        .await
        .ok()
        .and_then(|v| {
            get(&v, "data")
                .and_then(|d| get(d, "album"))
                .and_then(|a| get(a, "docs"))
                .and_then(arr_of)
                .cloned()
        })
        .unwrap_or_default();
    let mut out = Vec::new();
    for a in &docs {
        let paid = if truthy(get(a, "isPaid")) {
            "【VIP】"
        } else {
            ""
        };
        out.push(item_json(
            &text_of(a, &["albumId"]),
            &format!("{paid}{}", text_of(a, &["title"])),
            &fix_img(&text_of(a, &["coverPath"])),
            &text_of(a, &["nickname"]),
        ));
    }
    Ok(json!({"items": out}))
}
/// py _pick_url：按顺序挑第一个 http 音源字段（VIP 集同样带这些字段）。
fn pick_url(t: &Value) -> String {
    for k in [
        "playUrl64",
        "playUrl32",
        "playPathAacv224",
        "playPathAacv164",
        "playPathHq",
    ] {
        let v = text_of(t, &[k]);
        if v.starts_with("http") {
            return v;
        }
    }
    String::new()
}

struct Track {
    id: String,
    title: String,
    idx: i64,
    url: String,
}

async fn fetch_page_tracks(
    aid: &str,
    page: i64,
    size: i64,
    dev: &str,
) -> (Option<Vec<Value>>, i64) {
    let url =
        format!("{MOBILE}/mobile/others/ca/album/track/{aid}/true/{page}/{size}?device={dev}");
    let d = match get_json(&url, true).await {
        Ok(v) => v,
        Err(_) => return (None, 0),
    };
    let tr = get(&d, "tracks").cloned().unwrap_or(Value::Null);
    let list = get(&tr, "list").and_then(arr_of).cloned();
    let maxp = int_of(&tr, &["maxPageId"]);
    (list, if maxp < 1 { 1 } else { maxp })
}

/// py _page_tracks：提示 device 优先，再 android、ios；有音源即定并记提示。
async fn page_tracks(aid: &str, page: i64) -> (Option<Vec<Value>>, i64) {
    let mut devs: Vec<String> = Vec::new();
    if let Ok(hint) = DEV_HINT.lock() {
        if let Some(h) = hint.get(aid) {
            devs.push(h.clone());
        }
    }
    for d in ["android", "ios"] {
        if !devs.iter().any(|x| x == d) {
            devs.push(d.to_string());
        }
    }
    let mut best: (Option<Vec<Value>>, i64) = (None, 0);
    for dev in &devs {
        let (lst, maxp) = fetch_page_tracks(aid, page, PER_PAGE, dev).await;
        let Some(lst) = lst else { continue };
        if best.0.is_none() {
            best = (Some(lst.clone()), maxp);
        }
        if lst.iter().any(|t| !pick_url(t).is_empty()) {
            if let Ok(mut hint) = DEV_HINT.lock() {
                hint.insert(aid.to_string(), dev.clone());
            }
            return (Some(lst), maxp);
        }
    }
    best
}

/// py _tracks：每页 200、最多 60 页；cap=0 表示不限（核心固定不限）。
async fn tracks(aid: &str, cap: i64) -> Vec<Track> {
    let mut out = Vec::new();
    let mut page = 1i64;
    while page <= 60 {
        let (lst, maxp) = page_tracks(aid, page).await;
        let Some(lst) = lst else { break };
        if lst.is_empty() {
            break;
        }
        for t in &lst {
            out.push(Track {
                id: text_of(t, &["trackId"]),
                title: text_of(t, &["title"]),
                idx: out.len() as i64,
                url: pick_url(t),
            });
            if cap > 0 && out.len() as i64 >= cap {
                return out;
            }
        }
        if page >= maxp {
            break;
        }
        page += 1;
    }
    out
}

struct AlbumMeta {
    title: String,
    cover: String,
    intro: String,
    total: i64,
    paid: bool,
    nick: String,
}

async fn album_meta(aid: &str) -> AlbumMeta {
    let mut meta = AlbumMeta {
        title: String::new(),
        cover: String::new(),
        intro: String::new(),
        total: 0,
        paid: false,
        nick: String::new(),
    };
    let url = format!("{HOST}/m-revision/page/album/queryAlbumPage/{aid}?page=1&pageSize=30");
    if let Ok(v) = get_json(&url, false).await {
        let d = get(&v, "data").cloned().unwrap_or(Value::Null);
        let info = get(&d, "albumDetailInfo")
            .and_then(|x| get(x, "albumInfo"))
            .cloned()
            .unwrap_or(Value::Null);
        meta.title = text_of(&info, &["title", "albumTitle"]);
        meta.cover = text_of(&info, &["cover"]);
        meta.intro = text_of(&info, &["shortIntro", "intro"]);
        meta.total = int_of(&info, &["trackCount"]);
        meta.paid = truthy(get(&d, "albumPayType")) || truthy(get(&d, "albumVipPayType"));
        meta.nick = get(&d, "anchorInfo")
            .map(|a| text_of(a, &["nickname"]))
            .unwrap_or_default();
    }
    if meta.title.is_empty() {
        let url = format!("{HOST}/tdk-web/seo/search/albumInfo?albumId={aid}");
        if let Ok(v) = get_json(&url, false).await {
            let t = get(&v, "data").cloned().unwrap_or(Value::Null);
            meta.title = text_of(&t, &["albumTitle"]);
            if meta.cover.is_empty() {
                meta.cover = text_of(&t, &["albumCoverPath"]);
            }
            if meta.intro.is_empty() {
                meta.intro = text_of(&t, &["albumIntro"]);
            }
        }
    }
    meta
}

/// py _clean_kw：去括号/标点/营销词，取前两个长度≥2 的词、截 16 字。
fn clean_kw(title: &str) -> String {
    let t = BRACKET_RE.replace_all(title, " ");
    let t = PUNCT_RE.replace_all(&t, " ");
    let t = KW_DROP_RE.replace_all(&t, " ");
    let parts: Vec<&str> = WS_RE
        .split(&t)
        .filter(|p| p.chars().count() >= 2)
        .take(2)
        .collect();
    let joined = parts.join(" ");
    joined.chars().take(16).collect()
}

async fn web_free_url(tid: &str) -> Option<String> {
    let url = format!("{HOST}/revision/play/tracks?trackIds={tid}");
    let v = get_json(&url, false).await.ok()?;
    let arr = get(&v, "data")
        .and_then(|d| get(d, "tracksForAudioPlay"))
        .and_then(arr_of)?;
    let first = arr.first()?;
    let src = text_of(first, &["src"]);
    if src.is_empty() {
        None
    } else {
        Some(src)
    }
}

async fn free_alt(title: &str) -> Option<String> {
    let kw = clean_kw(title);
    if kw.is_empty() {
        return None;
    }
    let url = format!(
        "{HOST}/revision/search/seo?core=track&kw={}&page=1&rows=20&spellchecker=true&condition=relation&device=iPhone",
        quote(&kw)
    );
    let docs = get_json(&url, false).await.ok().and_then(|v| {
        get(&v, "data")
            .and_then(|d| get(d, "track"))
            .and_then(|t| get(t, "docs"))
            .and_then(arr_of)
            .cloned()
    })?;
    for d in docs.iter().filter(|d| !truthy(get(d, "isPaid"))).take(6) {
        if let Some(src) = web_free_url(&text_of(d, &["id"])).await {
            return Some(src);
        }
    }
    None
}

/// py _alt_album：站内同名免费专辑（主书名靠前、试 4 个、可直听≥2 集）。
async fn alt_album(title: &str, self_id: &str) -> Option<(String, Vec<Track>, String)> {
    let kw = clean_kw(title);
    if kw.is_empty() {
        return None;
    }
    let url = format!(
        "{HOST}/revision/search/seo?core=album&kw={}&page=1&spellchecker=true&rows=20&condition=relation&device=iPhone",
        quote(&kw)
    );
    let docs = get_json(&url, false).await.ok().and_then(|v| {
        get(&v, "data")
            .and_then(|d| get(d, "album"))
            .and_then(|a| get(a, "docs"))
            .and_then(arr_of)
            .cloned()
    })?;
    let head = kw.split(' ').next().unwrap_or("");
    let mut tried = 0;
    for a in &docs {
        let aid = text_of(a, &["albumId"]);
        if aid.is_empty() || aid == self_id || truthy(get(a, "isPaid")) {
            continue;
        }
        let at = text_of(a, &["title"]);
        // py str.find 返回字符下标；Rust find 返回字节下标，这里换算成字符下标再比 8。
        let char_pos = at.char_indices().find_map(|(bi, _)| {
            if at[bi..].starts_with(head) {
                Some(at[..bi].chars().count())
            } else {
                None
            }
        });
        let Some(char_pos) = char_pos else { continue };
        if char_pos > 8 {
            continue;
        }
        tried += 1;
        if tried > 4 {
            break;
        }
        let tr = tracks(&aid, 2000).await;
        let live: Vec<Track> = tr.into_iter().filter(|t| !t.url.is_empty()).collect();
        if live.len() >= 2 {
            return Some((at, live, aid));
        }
    }
    None
}

fn track_label(t: &Track) -> String {
    let title: String = WS_RE.replace_all(&t.title, " ").chars().take(38).collect();
    format!("第{}集 {title}", t.idx + 1)
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let aid = series_id.trim();
    let meta = album_meta(aid).await;
    let list = tracks(aid, 0).await;
    let live = list.iter().filter(|t| !t.url.is_empty()).count();
    let mut content = meta.intro.clone();
    if !list.is_empty() {
        if live >= list.len() {
            content.push_str(&format!(
                "\n【共 {} 集，音源全部已解析，直接点就听】",
                list.len()
            ));
        } else if live == 0 {
            content.push_str(&format!("\n【共 {} 集，播放时自动解析音源】", list.len()));
        } else {
            content.push_str(&format!(
                "\n【共 {} 集，其中 {} 集可直接播放；其余为会员专属，填 cookie 后全解锁】",
                list.len(),
                live
            ));
        }
    } else {
        content.push_str("\n（未取到曲目，可能专辑已下架或在审核中）");
    }
    if !list.is_empty() && live < list.len() {
        content = format!("【VIP/付费专辑】\n{content}");
    }
    let mut episodes: Vec<Value> = list
        .iter()
        .map(|t| episode_json(&format!("{}_{}_{}", aid, t.idx, t.id), &track_label(t), aid))
        .collect();
    if !list.is_empty() && live < list.len() {
        if let Some((at, alt_tracks, alt_aid)) = alt_album(&meta.title, aid).await {
            for t in &alt_tracks {
                episodes.push(episode_json(
                    &format!("{}_{}_{}", alt_aid, t.idx, t.id),
                    &format!("【免费同书】{}", track_label(t)),
                    &alt_aid,
                ));
            }
            let alt_title: String = at.chars().take(26).collect();
            content.push_str(&format!(
                "\n【备用线路：站内同名免费专辑《{alt_title}》，{} 集可直听】",
                alt_tracks.len()
            ));
        }
    }
    let title = if meta.title.is_empty() {
        format!("专辑 {aid}")
    } else {
        meta.title.clone()
    };
    let remarks = format!(
        "{}{}集",
        if meta.nick.is_empty() {
            String::new()
        } else {
            format!("{} · ", meta.nick)
        },
        list.len()
    );
    Ok(json!({
        "id": aid,
        "title": title,
        "cover": fix_img(&meta.cover),
        "synopsis": content,
        "extra": {"anchor": meta.nick, "paid": meta.paid, "total": meta.total, "remarks": remarks},
        "episodes": episodes,
    }))
}

/// py _url_at：按集序定位页现取签名地址，找不到再全量翻页找。
async fn url_at(aid: &str, idx: Option<i64>, tid: &str) -> Option<String> {
    if let Some(idx) = idx {
        if idx >= 0 {
            let page = idx / PER_PAGE + 1;
            let (lst, _) = page_tracks(aid, page).await;
            if let Some(lst) = lst {
                for t in &lst {
                    if text_of(t, &["trackId"]) == tid {
                        let u = pick_url(t);
                        if !u.is_empty() {
                            return Some(u);
                        }
                    }
                }
            }
        }
    }
    let mut page = 1i64;
    while page <= 60 {
        let (lst, maxp) = page_tracks(aid, page).await;
        let Some(lst) = lst else { break };
        if lst.is_empty() {
            break;
        }
        for t in &lst {
            if text_of(t, &["trackId"]) == tid {
                let u = pick_url(t);
                if !u.is_empty() {
                    return Some(u);
                }
            }
        }
        if page >= maxp {
            break;
        }
        page += 1;
    }
    None
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let did = video_id.trim();
    let parts: Vec<&str> = did.split('_').collect();
    let (aid, idx, tid) = if parts.len() == 3 {
        (
            parts[0],
            if parts[1].chars().all(|c| c.is_ascii_digit()) && !parts[1].is_empty() {
                Some(parts[1].parse::<i64>().unwrap_or(-1))
            } else {
                None
            },
            parts[2],
        )
    } else if parts.len() == 2 {
        (parts[0], None, parts[1])
    } else {
        ("", None, did)
    };
    let header = json!({"User-Agent": UA, "Referer": format!("{HOST}/")});
    if tid.is_empty() || !tid.chars().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::BadRequest("喜马拉雅参数不对".into()));
    }
    if !aid.is_empty() && aid.chars().all(|c| c.is_ascii_digit()) {
        if let Some(url) = url_at(aid, idx, tid).await {
            return Ok(json!({"url": url, "header": header}));
        }
    }
    if let Some(url) = web_free_url(tid).await {
        return Ok(json!({"url": url, "header": header}));
    }
    let mut title = String::new();
    let url = format!("{HOST}/m-revision/page/track/queryTrackPage/{tid}");
    if let Ok(v) = get_json(&url, false).await {
        title = get(&v, "data")
            .and_then(|d| get(d, "trackDetailInfo"))
            .and_then(|x| get(x, "trackInfo"))
            .map(|t| text_of(t, &["title"]))
            .unwrap_or_default();
    }
    if !title.is_empty() {
        if let Some(url) = free_alt(&title).await {
            return Ok(json!({"url": url, "header": header}));
        }
    }
    Err(ApiError::Internal(
        "喜马拉雅这集没取到地址，退出详情页重进一次再试".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fix_img_rules() {
        assert_eq!(fix_img("http://a.com/x.jpg"), "https://a.com/x.jpg");
        assert_eq!(fix_img("//a.com/x.jpg"), "https://a.com/x.jpg");
        assert_eq!(
            fix_img("/group1/x.jpg"),
            "https://imagev2.xmcdn.com/group1/x.jpg"
        );
        assert_eq!(fix_img(""), "");
    }

    #[test]
    fn pick_url_order() {
        let t = json!({"playUrl32": "http://x/32", "playUrl64": "http://x/64"});
        assert_eq!(pick_url(&t), "http://x/64");
        let t = json!({"playPathHq": "http://x/hq"});
        assert_eq!(pick_url(&t), "http://x/hq");
        assert_eq!(pick_url(&json!({})), "");
    }

    #[test]
    fn clean_kw_rules() {
        assert_eq!(clean_kw("【VIP】三体（全集）有声剧"), "三体");
        assert_eq!(clean_kw("盗墓笔记 演播版"), "盗墓笔记");
    }
}
