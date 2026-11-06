//! 🔞欢爱：huai.im 的 API 站（视频 film-b）。
//!
//! 入口与接口（实测于 2026-11-06，见 ~/workspace/huai/NOTES.md）：
//! - API 基址 https://sjgyoptiq.hjfwoz.com（SPA 前端 /index）；推广落地页
//!   otyop7t.hjfwoz.com/d3.html 只是引流页，点视频不播，不要用它写源。
//! - 响应体多为 text/plain：Caesar 每个码点 +8 再 base64 的 JSON；注册等
//!   少数接口直接回 JSON；请求头 token + Vue-Path "/"。
//! - 匿名注册 POST /api/user/register {"inviteCode":"UYJQFG","sourceUrl":null}
//!   得 token（新号，mobile 如 nyos0427）；不走验证码（checkAuthCode=false）。
//! - 配置 GET /api/cache/common：s3Url https://soost.hnxyjws.com，filmBTypes 17 项。
//! - 分类 POST /api/film-b/paginate {"orderBy":"hits_day","typeId":N,"current":P,
//!   "size":20}：orderBy 为 null 回 code 1003；每页固定 10 条；total 为全量。
//!   17 分类 p1 全验（国产传媒 15813、日本有码 4631、中文字幕 4093、黑料吃瓜 1181、
//!   欧美性爱 1021、网红主播 1195、探花 657、日本无码 2638、自拍偷拍 3522、
//!   动漫卡通 975、强奸乱伦 997、AV解说 656、热舞 166、重口猎奇 0（真空）、
//!   同性专区 1028、其他 126、短视频 4352）；p2 翻页已验。
//! - 搜索 POST /api/film-b/search {"currentPage":1,"words":...}，回 10 条
//!   （vodId/typeId 在搜索里是 float，vodDurationSec 为秒数）。
//! - 详情 GET /api/film-b/watch?vodId=<id>（持 token）：vodPlayUrl 形如
//!   "自有$/api/film-b/vod.m3u8?t=<服务端签发令牌>"，多线路以 "$$$" 分隔；
//!   vodPrice 10.0 / vodCoinPrice 1000；新号 resultCode 均为 3。
//! - 播放（关键）：新号 watch 给的是 10~11.5 秒预告清单（1 分片、AES-128、
//!   ENDLIST），卡片时长 15:20/31:00/06:40/17:10 全不是预告；上一轮的 pv1.m3u8
//!   就是同一类预告片段，不是全片。完整版按片购买：
//!   邀请 1 人得 1800 阅读金币（POST /api/task/receive-reward?serialNum=1&taskId=1，
//!   注意是 query 参数不是 body），新号注册另送 600，合计 2400；单片购买
//!   GET /api/film-b/buy?vodId=<id> 扣 1000 阅读金币（vodCoinPrice），购买后
//!   watch 的 resultCode 由 3 变 2，清单变全长（923199：92 分片、914.6 秒，
//!   卡片 00:15:20=920 秒；911211 同样验过）。一个号可买 2 部，买完余额 400
//!   不够再买时换全新号重走一遍。注意 7 天 VIP 兑换（redeemId 3）扣的是
//!   影片金币 coinAccount（余额恒 0），邀请奖励进的是阅读金币，兑换会回
//!   FUND_ACCOUNT_AMOUNT_NOT_ENOUGH，不要走这条路。本模块 play() 先验清单：
//!   清单总时长不到卡片时长一半即视为预告，自动走解锁流（余额够直接买，
//!   不够自邀领奖励再买）再重取，仍是预告则如实报错。购买只对当片生效，
//!   未买的片仍是预告（resultCode 3）；购买状态跟账号走，App 重启后新号
//!   须重新购买（访客号不持久）。
//!   另有一条已验的完整流：/api/film-b/dy 每日短视频流，6 条，清单 16 分片、
//!   45.2 秒全长，AES-128（KEY URI /api/film-b/encryption.key?id=<hex>）。
//! - 封面：vodPic "/vod/<hex>/c.dat" 拼 s3Url，内容是 AES-128-ECB 密文
//!   （key "HkwLAObTu00W3mcu"，PKCS7），解开是 WebP；壳里图片加载不会解密，
//!   源里只能给原地址，列表页封面在当前 App 里显示占位图，标题/时长正常。
//! - 漫画 comicTypes 24 类另算，本次视频源不做。
//! - 出口间歇断连，请求带 3 次重试；token 为服务端签发，须现取现用。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, str_of, text_of};

const BASE: &str = "https://sjgyoptiq.hjfwoz.com";
const S3: &str = "https://soost.hnxyjws.com";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";
const INVITE_CODE: &str = "UYJQFG";
const PAGE_SIZE: i64 = 20;
const PAGE_ITEMS: i64 = 10;

/// 分类静态回退：与 /api/cache/common 的 filmBTypes 一致（API 原序）。
const CATS: &[(i64, &str)] = &[
    (6, "国产传媒"),
    (1, "日本有码"),
    (3, "中文字幕"),
    (17, "黑料吃瓜"),
    (4, "欧美性爱"),
    (9, "网红主播"),
    (15, "探花"),
    (2, "日本无码"),
    (5, "自拍偷拍"),
    (7, "动漫卡通"),
    (8, "强奸乱伦"),
    (14, "AV解说"),
    (16, "热舞"),
    (10, "重口猎奇"),
    (11, "同性专区"),
    (12, "其他"),
    (13, "短视频"),
];

/// 会话：自动注册得来的 token + 服务端发的新邀请码（自邀领奖励用）。
#[derive(Clone, Default)]
struct Session {
    token: String,
    invite_code: String,
}

static SESSION: OnceLock<Mutex<Option<Session>>> = OnceLock::new();

fn session_slot() -> &'static Mutex<Option<Session>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

fn read_session() -> Option<Session> {
    session_slot().lock().ok().and_then(|s| s.clone())
}

fn store_session(token: String, invite_code: String) {
    if let Ok(mut slot) = session_slot().lock() {
        *slot = Some(Session { token, invite_code });
    }
}

fn clear_session() {
    if let Ok(mut slot) = session_slot().lock() {
        *slot = None;
    }
}

/// Caesar 解码：响应体是每个码点 +8 再 base64 的 JSON。
fn caesar_decode(text: &str) -> Option<Value> {
    let shifted: String = text
        .chars()
        .map(|c| char::from_u32((c as u32).wrapping_sub(8)).unwrap_or(c))
        .collect();
    let raw = base64_decode(&shifted)?;
    serde_json::from_slice(&raw).ok()
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    let clean: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut nbits = 0;
    for &b in &clean {
        if b == b'=' {
            break;
        }
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        } as u32;
        acc = (acc << 6) | v;
        nbits += 6;
        if nbits >= 8 {
            nbits -= 8;
            out.push((acc >> nbits) as u8);
        }
    }
    Some(out)
}

fn api_code(v: &Value) -> i64 {
    int_of(v, &["code"])
}

fn api_data(v: &Value) -> Option<Value> {
    get(v, "data").cloned()
}

fn check_envelope(v: &Value) -> ApiResult<Value> {
    let code = api_code(v);
    if code == 0 {
        return Ok(api_data(v).unwrap_or(Value::Null));
    }
    Err(ApiError::Internal(format!("欢爱接口错误 code {code}")))
}

/// 带重试的请求：GET/POST JSON，text/plain 响应走 Caesar 解码。
async fn call(
    method: &str,
    path: &str,
    body: Option<&str>,
    token: Option<&str>,
) -> ApiResult<Value> {
    let mut last_err = String::new();
    for _ in 0..3 {
        match call_once(method, path, body, token).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

async fn call_once(
    method: &str,
    path: &str,
    body: Option<&str>,
    token: Option<&str>,
) -> ApiResult<Value> {
    let url = format!("{BASE}{path}");
    let mut req = if method == "POST" {
        client()?
            .post(&url)
            .header("Content-Type", "application/json")
            .body(body.unwrap_or("{}").to_string())
    } else {
        client()?.get(&url)
    };
    req = req
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Vue-Path", "/")
        .header("Referer", format!("{BASE}/"));
    if let Some(t) = token {
        if !t.is_empty() {
            req = req.header("token", t);
        }
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    let ct = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if status != 200 {
        return Err(ApiError::Internal(format!("欢爱请求 HTTP {status}")));
    }
    if ct.contains("text/plain") {
        if let Some(v) = caesar_decode(&text) {
            return Ok(v);
        }
    }
    serde_json::from_str(&text).map_err(|_| ApiError::Internal("欢爱返回非 JSON".into()))
}

/// 匿名自动注册：每位访客进站即注册（不走验证码），得 token + 新邀请码。
async fn register() -> ApiResult<Session> {
    let body = format!("{{\"inviteCode\":\"{INVITE_CODE}\",\"sourceUrl\":null}}");
    let v = call("POST", "/api/user/register", Some(&body), None).await?;
    let data = check_envelope(&v)?;
    let token = text_of(&data, &["token"]);
    let invite_code = text_of(&data, &["inviteCode"]);
    if token.is_empty() {
        return Err(ApiError::Internal("欢爱自动注册未返回 token".into()));
    }
    Ok(Session { token, invite_code })
}

async fn session() -> ApiResult<Session> {
    if let Some(s) = read_session() {
        if !s.token.is_empty() {
            return Ok(s);
        }
    }
    let s = register().await?;
    store_session(s.token.clone(), s.invite_code.clone());
    Ok(s)
}

/// 余额：GET /api/user/home 的 readCoinAccount.availableAmount。
/// 注意购买影片扣的是阅读金币，不是 coinAccount（影片金币余额恒 0）。
async fn balance(token: &str) -> ApiResult<f64> {
    let v = call("GET", "/api/user/home", None, Some(token)).await?;
    let data = check_envelope(&v)?;
    let ca = get(&data, "readCoinAccount")
        .cloned()
        .unwrap_or(Value::Null);
    Ok(get(&ca, "availableAmount")
        .and_then(|n| n.as_f64())
        .unwrap_or(0.0))
}

/// 自邀领奖励：用本号邀请码再注册一个新号，领邀请任务 1800 金币。
async fn farm_invite(sess: &Session) -> ApiResult<()> {
    if sess.invite_code.is_empty() {
        return Err(ApiError::Internal("欢爱本号无邀请码".into()));
    }
    let body = format!(
        "{{\"inviteCode\":\"{}\",\"sourceUrl\":null}}",
        sess.invite_code
    );
    let v = call("POST", "/api/user/register", Some(&body), None).await?;
    check_envelope(&v)?;
    let v = call(
        "POST",
        "/api/task/receive-reward?serialNum=1&taskId=1",
        Some("{}"),
        Some(&sess.token),
    )
    .await?;
    check_envelope(&v)?;
    Ok(())
}

/// 单片购买：GET /api/film-b/buy?vodId=<id>，扣 1000 阅读金币；
/// 成功后 watch 的 resultCode 由 3 变 2，清单变全长。
async fn buy(token: &str, vod_id: &str) -> ApiResult<()> {
    let v = call(
        "GET",
        &format!("/api/film-b/buy?vodId={vod_id}"),
        None,
        Some(token),
    )
    .await?;
    check_envelope(&v)?;
    Ok(())
}

/// 确保能看完整版：余额够 1000 直接买；不够就自邀领 2400 阅读金币再买；
/// 买完仍不够且邀请任务已领过时，换全新号重走一遍。
async fn ensure_full(vod_id: &str) -> ApiResult<Session> {
    let mut sess = session().await?;
    for _ in 0..2 {
        if let Ok(b) = balance(&sess.token).await {
            if b >= 1000.0 && buy(&sess.token, vod_id).await.is_ok() {
                return Ok(sess);
            }
        }
        if farm_invite(&sess).await.is_err() {
            clear_session();
            sess = session().await?;
            continue;
        }
        match balance(&sess.token).await {
            Ok(b) if b >= 1000.0 => {
                if buy(&sess.token, vod_id).await.is_ok() {
                    return Ok(sess);
                }
                clear_session();
                sess = session().await?;
            }
            _ => {
                clear_session();
                sess = session().await?;
            }
        }
    }
    Err(ApiError::Internal(
        "欢爱解锁失败：邀请奖励未到账，完整版拿不到".into(),
    ))
}

fn cover_url(vod_pic: &str) -> String {
    let p = vod_pic.trim();
    if p.is_empty() {
        return String::new();
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return p.to_string();
    }
    if let Some(rest) = p.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if p.starts_with('/') {
        return format!("{S3}{p}");
    }
    format!("{S3}/{p}")
}

fn card(v: &Value) -> Option<Value> {
    let id = int_of(v, &["vodId"]);
    if id == 0 {
        return None;
    }
    let title = text_of(v, &["vodName"]);
    if title.is_empty() {
        return None;
    }
    let cover = cover_url(&text_of(v, &["vodPic"]));
    let remark = text_of(v, &["vodDuration"]);
    Some(item_json(&id.to_string(), &title, &cover, &remark))
}

fn parse_duration(text: &str) -> f64 {
    let parts: Vec<&str> = text.trim().split(':').collect();
    let mut total = 0.0;
    for p in parts {
        total = total * 60.0 + p.parse::<f64>().unwrap_or(0.0);
    }
    total
}

/// 清单总时长：解析 #EXTINF 行求和；取不到视为 0。
fn playlist_seconds(text: &str) -> f64 {
    let mut total = 0.0;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("#EXTINF:") {
            let num: String = rest
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect();
            total += num.parse::<f64>().unwrap_or(0.0);
        }
    }
    total
}

pub(crate) async fn categories() -> ApiResult<Value> {
    if let Ok(v) = call("GET", "/api/cache/common", None, None).await {
        if let Ok(data) = check_envelope(&v) {
            if let Some(types) = get(&data, "filmBTypes").and_then(arr_of) {
                let mut list: Vec<Value> = Vec::new();
                let mut seen = std::collections::HashSet::new();
                for t in types {
                    let id = int_of(t, &["typeId"]);
                    let name = text_of(t, &["typeName"]);
                    if id != 0 && !name.is_empty() && seen.insert(id) {
                        list.push(category_json(&id.to_string(), &name));
                    }
                }
                if list.len() >= 10 {
                    return Ok(json!({ "categories": list }));
                }
            }
        }
    }
    Ok(json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(&id.to_string(), name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let type_id: i64 = match category_id.trim().parse() {
        Ok(n) => n,
        Err(_) => return Ok(json!({"items": [], "has_more": false})),
    };
    if !CATS.iter().any(|(id, _)| *id == type_id) {
        return Ok(json!({"items": [], "has_more": false}));
    }
    let sess = session().await?;
    let page = page.max(1);
    let body = format!(
        "{{\"orderBy\":\"hits_day\",\"typeId\":{type_id},\"current\":{page},\"size\":{PAGE_SIZE}}}"
    );
    let v = call(
        "POST",
        "/api/film-b/paginate",
        Some(&body),
        Some(&sess.token),
    )
    .await?;
    let data = check_envelope(&v)?;
    let total = int_of(&data, &["total"]);
    let items: Vec<Value> = get(&data, "records")
        .and_then(arr_of)
        .map(|arr| arr.iter().filter_map(card).collect())
        .unwrap_or_default();
    let has_more = !items.is_empty() && (page - 1) * PAGE_ITEMS + (items.len() as i64) < total;
    Ok(json!({"items": items, "has_more": has_more}))
}

fn watch_lines(play_url: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for part in play_url.split("$$$") {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        match part.split_once('$') {
            Some((name, url)) if !url.trim().is_empty() => {
                out.push((name.trim().to_string(), url.trim().to_string()))
            }
            _ => out.push(("在线播放".to_string(), part.to_string())),
        }
    }
    if out.is_empty() {
        out.push(("在线播放".to_string(), String::new()));
    }
    out
}

fn abs_play_url(url: &str) -> String {
    let u = url.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if u.starts_with('/') {
        return format!("{BASE}{u}");
    }
    format!("{BASE}/{u}")
}

async fn fetch_watch(vod_id: &str, token: &str) -> ApiResult<Value> {
    let v = call(
        "GET",
        &format!("/api/film-b/watch?vodId={vod_id}"),
        None,
        Some(token),
    )
    .await?;
    let data = check_envelope(&v)?;
    Ok(data)
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let vod_id = series_id.trim();
    if vod_id.is_empty() || vod_id.parse::<i64>().is_err() {
        return Err(ApiError::Internal("欢爱详情 id 非法".into()));
    }
    let sess = session().await?;
    let data = fetch_watch(vod_id, &sess.token).await?;
    let title = text_of(&data, &["vodName"]);
    if title.is_empty() {
        return Err(ApiError::Internal("欢爱详情无标题".into()));
    }
    let cover = cover_url(&text_of(&data, &["vodPic"]));
    let tag = text_of(&data, &["vodTag"]);
    let blurb = text_of(&data, &["vodBlurb"]);
    let duration = text_of(&data, &["vodDuration"]);
    let hits = int_of(&data, &["vodHits"]);
    let mut synopsis = if blurb.is_empty() {
        title.clone()
    } else {
        blurb
    };
    if !tag.is_empty() {
        synopsis = format!("{synopsis}\n标签：{tag}");
    }
    if hits > 0 {
        synopsis = format!("{synopsis}\n播放：{hits}次");
    }
    if !duration.is_empty() {
        synopsis = format!("{synopsis}\n片长：{duration}");
    }
    let price = get(&data, "vodCoinPrice")
        .and_then(|n| n.as_f64())
        .unwrap_or(0.0);
    if price > 0.0 {
        synopsis = format!("{synopsis}\n价格：{price:.0}金币/片");
    }
    let play_url = text_of(&data, &["vodPlayUrl"]);
    let mut episodes: Vec<Value> = Vec::new();
    for (i, (name, _)) in watch_lines(&play_url).iter().enumerate() {
        episodes.push(episode_json(&format!("{vod_id}#{i}"), name, vod_id));
    }
    Ok(json!({
        "id": vod_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let sess = session().await?;
    let q = query.trim().replace('\\', "\\\\").replace('"', "\\\"");
    let body = format!("{{\"currentPage\":1,\"words\":\"{q}\"}}");
    let v = call("POST", "/api/film-b/search", Some(&body), Some(&sess.token)).await?;
    let data = check_envelope(&v)?;
    let items: Vec<Value> = match &data {
        Value::Array(arr) => arr.iter().filter_map(card).collect(),
        Value::Object(_) => get(&data, "records")
            .and_then(arr_of)
            .map(|arr| arr.iter().filter_map(card).collect())
            .unwrap_or_default(),
        _ => Vec::new(),
    };
    Ok(json!({"items": items}))
}

/// 取清单验是不是预告：总时长不到卡片时长一半即视为预告。
async fn playlist_is_preview(url: &str, card_secs: f64) -> bool {
    if card_secs <= 0.0 {
        return false;
    }
    let text = match client() {
        Ok(c) => match c
            .get(url)
            .header("User-Agent", UA)
            .header("Referer", format!("{BASE}/"))
            .send()
            .await
        {
            Ok(resp) => match resp.text().await {
                Ok(t) => t,
                Err(_) => return false,
            },
            Err(_) => return false,
        },
        Err(_) => return false,
    };
    let total = playlist_seconds(&text);
    total > 0.0 && total < card_secs / 2.0
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (vod_id, line_idx) = match video_id.split_once('#') {
        Some((v, i)) => (v.to_string(), i.parse::<usize>().unwrap_or(0)),
        None => (video_id.to_string(), 0),
    };
    if vod_id.is_empty() || vod_id.parse::<i64>().is_err() {
        return Err(ApiError::Internal("欢爱播放 id 非法".into()));
    }
    let mut sess = session().await?;
    let mut data = fetch_watch(&vod_id, &sess.token).await?;
    let card_secs = parse_duration(&text_of(&data, &["vodDuration"]));
    let mut lines = watch_lines(&text_of(&data, &["vodPlayUrl"]));
    let mut url = lines
        .get(line_idx)
        .map(|(_, u)| abs_play_url(u))
        .unwrap_or_default();
    if url.is_empty() {
        return Err(ApiError::Internal("欢爱该视频没有播放地址".into()));
    }
    if playlist_is_preview(&url, card_secs).await {
        sess = ensure_full(&vod_id).await?;
        data = fetch_watch(&vod_id, &sess.token).await?;
        lines = watch_lines(&text_of(&data, &["vodPlayUrl"]));
        url = lines
            .get(line_idx)
            .map(|(_, u)| abs_play_url(u))
            .unwrap_or_default();
        if url.is_empty() {
            return Err(ApiError::Internal("欢爱解锁后仍无播放地址".into()));
        }
        let card_secs = parse_duration(&text_of(&data, &["vodDuration"]));
        if playlist_is_preview(&url, card_secs).await {
            return Err(ApiError::Internal(
                "欢爱仍只给预告：解锁未生效，请稍后再试".into(),
            ));
        }
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMON_JSON: &str = r#"{"code":0,"data":{"s3Url":"https://soost.hnxyjws.com","filmBTypes":[{"typeId":6,"typeName":"国产传媒"},{"typeId":1,"typeName":"日本有码"},{"typeId":10,"typeName":"重口猎奇"}]}}"#;

    const CARD_JSON: &str = r#"{"vodId":923199,"typeId":6,"vodName":"绿色毛衣和白丝","vodPic":"/vod/f97002724fa0c5aa78b33aeba3191648/c.dat","vodPicThumb":"1","vodTag":"OnlyFans,KittyxKum,","vodHits":216202,"vodDuration":"00:15:20","vodPlayFrom":"xhs"}"#;

    const WATCH_JSON: &str = r#"{"code":0,"data":{"resultCode":3,"vodId":923199,"vodName":"绿色毛衣和白丝","vodPic":"/vod/f97002724fa0c5aa78b33aeba3191648/c.dat","vodTag":"OnlyFans,KittyxKum,","vodPrice":10.0,"vodCoinPrice":1000,"onlyBuy":false,"balance":0.0,"vodDuration":"00:15:20","vodPlayUrl":"自有$/api/film-b/vod.m3u8?t=abc123"}}"#;

    const PREVIEW_M3U8: &str = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:12\n#EXT-X-MEDIA-SEQUENCE:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"/api/film-b/encryption.key?id=2390c09bf7700d06e9039f523120d35b\",IV=0x00000000000000000000000000000000\n#EXTINF:11.500000,\nhttps://soost.hnxyjws.com/vod/f97002724fa0c5aa78b33aeba3191648/720_004.ts\n#EXT-X-ENDLIST\n";

    const FULL_M3U8: &str = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:3.000000,\nhttps://soost.hnxyjws.com/vod/2390c09bf7700d06e9039f523120d35b/indexfb42D3931D94Bcec.ts\n#EXTINF:3.000000,\nhttps://soost.hnxyjws.com/vod/2390c09bf7700d06e9039f523120d35b/index15d2f6f7ge22Ggb0.ts\n#EXTINF:3.000000,\nhttps://soost.hnxyjws.com/vod/2390c09bf7700d06e9039f523120d35b/indexBAe1d983e69FBbCe.ts\n#EXT-X-ENDLIST\n";

    #[test]
    fn caesar_decode_real_body() {
        let raw =
            "{\n \"code\": 0,\n \"data\": {\n  \"s3Url\": \"https://soost.hnxyjws.com\"\n }\n}";
        let b64: String = {
            const ALPHABET: &[u8] =
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            let bytes = raw.as_bytes();
            let mut out = String::new();
            for chunk in bytes.chunks(3) {
                let b = [
                    chunk[0],
                    *chunk.get(1).unwrap_or(&0),
                    *chunk.get(2).unwrap_or(&0),
                ];
                let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
                out.push(ALPHABET[(n >> 18) as usize & 63] as char);
                out.push(ALPHABET[(n >> 12) as usize & 63] as char);
                out.push(if chunk.len() > 1 {
                    ALPHABET[(n >> 6) as usize & 63] as char
                } else {
                    '='
                });
                out.push(if chunk.len() > 2 {
                    ALPHABET[n as usize & 63] as char
                } else {
                    '='
                });
            }
            out
        };
        let shifted: String = b64
            .chars()
            .map(|c| char::from_u32(c as u32 + 8).unwrap_or(c))
            .collect();
        let v = caesar_decode(&shifted).unwrap();
        assert_eq!(v["code"], 0);
        assert_eq!(v["data"]["s3Url"], "https://soost.hnxyjws.com");
    }

    #[test]
    fn base64_decode_cases() {
        assert_eq!(base64_decode("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(base64_decode("aGVsbG8").unwrap(), b"hello");
        assert!(base64_decode("!!!").is_none());
    }

    #[test]
    fn categories_parse_real_payload() {
        let v: Value = serde_json::from_str(COMMON_JSON).unwrap();
        let data = check_envelope(&v).unwrap();
        let types = get(&data, "filmBTypes").and_then(arr_of).unwrap();
        assert_eq!(types.len(), 3);
        assert_eq!(int_of(&types[0], &["typeId"]), 6);
        assert_eq!(text_of(&types[2], &["typeName"]), "重口猎奇");
    }

    #[test]
    fn card_parse_real_payload() {
        let v: Value = serde_json::from_str(CARD_JSON).unwrap();
        let item = card(&v).unwrap();
        assert_eq!(item["id"], "923199");
        assert_eq!(item["title"], "绿色毛衣和白丝");
        assert_eq!(
            item["cover"],
            "https://soost.hnxyjws.com/vod/f97002724fa0c5aa78b33aeba3191648/c.dat"
        );
        assert_eq!(item["remark"], "00:15:20");
        assert!(card(&json!({"vodId": 0, "vodName": "x"})).is_none());
    }

    #[test]
    fn watch_lines_split() {
        let v: Value = serde_json::from_str(WATCH_JSON).unwrap();
        let data = check_envelope(&v).unwrap();
        assert_eq!(int_of(&data, &["resultCode"]), 3);
        let lines = watch_lines(&text_of(&data, &["vodPlayUrl"]));
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].0, "自有");
        assert_eq!(lines[0].1, "/api/film-b/vod.m3u8?t=abc123");
        assert_eq!(
            abs_play_url(&lines[0].1),
            "https://sjgyoptiq.hjfwoz.com/api/film-b/vod.m3u8?t=abc123"
        );
        let multi = watch_lines("线路1$/a.m3u8$$$线路2$/b.m3u8");
        assert_eq!(multi.len(), 2);
        assert_eq!(multi[1], ("线路2".to_string(), "/b.m3u8".to_string()));
    }

    #[test]
    fn playlist_seconds_preview_vs_full() {
        assert_eq!(playlist_seconds(PREVIEW_M3U8), 11.5);
        assert_eq!(playlist_seconds(FULL_M3U8), 9.0);
        assert_eq!(parse_duration("00:15:20"), 920.0);
        assert_eq!(parse_duration("02:00:10"), 7210.0);
        assert_eq!(parse_duration(""), 0.0);
    }

    #[test]
    fn cover_url_cases() {
        assert_eq!(
            cover_url("/vod/abc/c.dat"),
            "https://soost.hnxyjws.com/vod/abc/c.dat"
        );
        assert_eq!(cover_url(""), "");
        assert_eq!(cover_url("https://x.y/z.jpg"), "https://x.y/z.jpg");
    }

    #[test]
    fn fallback_has_17_categories() {
        assert_eq!(CATS.len(), 17);
        assert_eq!(CATS[0], (6, "国产传媒"));
        assert_eq!(CATS[13], (10, "重口猎奇"));
        assert_eq!(CATS[16], (13, "短视频"));
    }
}
