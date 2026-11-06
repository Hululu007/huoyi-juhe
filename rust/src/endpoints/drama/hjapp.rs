//! 海角社区 App 版（hjapp）：AES-192 加密隧道站。
//!
//! - API 池两个域名，空响应时换池内另一域名；x-tp=(毫秒时间戳*1000+
//!   随机0–999)；x-ph=base64url(AES-192-CBC(K_PH, IV=x-tp 字节,
//!   明文 "<path>/<uuid>"))；POST {api}/enc/{md5(毫秒时间戳+随机
//!   0–999)}；body=base64(AES-192-CBC(K_BODY, IV=V_BODY, JSON))；
//!   JSON 里 deviceType=2、oauthType=pwa、oauthId；响应 data 为字
//!   符串时同密钥/IV 解密成 JSON。密钥均为 24 字节 ASCII 原串
//!   （不是 base64 解码后），K_PH/K_BODY 作密钥、V_BODY 作 IV。
//! - 会话：oauthId="p3"+16 位随机十六进制+"_"+毫秒时间戳；先调
//!   /user/visitors/register，再调 /user/login/v2 拿 token（长度
//!   >20 才采用），token 6 小时有效；code==401 时清 token、
//!   重登录、重试一次。
//! - 分类：5 个固定（免费视频帖/视频帖/最新帖子/热门帖子/仅预览·
//!   视频频道）+ 服务端 /post-category/all 下发的分类（cat:<id>）。
//! - 目录：rec 走 /video/recommendation；free 连取 3 页 /post/list
//!   只留免费且有视频的帖、截断 20 条；new/hot/cat:<id>/video
//!   走 /post/list 的不同参数组合。
//! - 详情：post:<n> 走 /post/detail（视频 N$videoUrl 或预览
//!   N$previewPath，无视频时单集“图片 1$首图”）；video:<n> 走
//!   /video/detail/v2（chargeAmount<=0 或 isFree==1 时标“完整”
//!   否则标“预览”，链接均为 previewVideoLink）。
//! - 注意：收费内容接口只下发预览流，完整片源要站内购买，本源
//!   不过这道墙；取流验门以免费/预览地址为准。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const API_POOL: [&str; 2] = ["https://bapi.pyvllsdyh3.com", "https://api.ww5api.com"];
const K_PH: &[u8] = b"WhtRldf4KJHUY22hlJRUSo==";
const K_BODY: &[u8] = b"BioItun4JIOFL78hlQECIb==";
const V_BODY: &[u8] = b"dfg2s8g9klc3jab1";
const CLOUD: &str = "https://d1o1h2djubc0nl.cloudfront.net";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MOBILE_UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const PAGE_SIZE: i64 = 20;
const TOKEN_TTL: Duration = Duration::from_secs(6 * 3600);

static API: Mutex<String> = Mutex::new(String::new());
static TOKEN: Mutex<Option<(String, Instant)>> = Mutex::new(None);
static OAUTH_ID: Mutex<String> = Mutex::new(String::new());

fn api_host() -> String {
    if let Ok(guard) = API.lock() {
        if !guard.is_empty() {
            return guard.clone();
        }
    }
    API_POOL[0].to_string()
}

fn set_api(host: &str) {
    if let Ok(mut guard) = API.lock() {
        *guard = host.to_string();
    }
}

fn cached_token() -> Option<String> {
    TOKEN.lock().ok().and_then(|g| match g.as_ref() {
        Some((t, exp)) if Instant::now() < *exp => Some(t.clone()),
        _ => None,
    })
}

fn set_token(token: &str) {
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = Some((token.to_string(), Instant::now() + TOKEN_TTL));
    }
}

fn clear_token() {
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = None;
    }
}

fn oauth_id() -> String {
    if let Ok(guard) = OAUTH_ID.lock() {
        if !guard.is_empty() {
            return guard.clone();
        }
    }
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let hex: String = (0..16)
        .map(|_| format!("{:x}", rand::random::<u8>() % 16))
        .collect();
    let id = format!("p3{hex}_{ms}");
    if let Ok(mut guard) = OAUTH_ID.lock() {
        *guard = id.clone();
    }
    id
}

fn ms_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn md5hex(s: &str) -> String {
    use md5::{Digest, Md5};
    hex::encode(Md5::digest(s.as_bytes()))
}

/// AES-192-CBC 加密（PKCS7 填充），输出 base64 标准编码。
fn aes192_cbc_encrypt(key: &[u8], iv: &[u8], plain: &[u8]) -> Vec<u8> {
    use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
    let cipher = aes::Aes192::new(GenericArray::from_slice(&key[..24]));
    let mut data = plain.to_vec();
    let pad = 16 - (data.len() % 16);
    data.extend(std::iter::repeat(pad as u8).take(pad));
    let mut out = Vec::with_capacity(data.len());
    let mut prev: [u8; 16] = iv[..16].try_into().unwrap();
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        for i in 0..16 {
            block[i] ^= prev[i];
        }
        cipher.encrypt_block(&mut block);
        prev.copy_from_slice(&block);
        out.extend_from_slice(&block);
    }
    out
}

/// AES-192-CBC 解密（去 PKCS7 填充）。
fn aes192_cbc_decrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if key.len() < 24 || iv.len() < 16 || data.len() % 16 != 0 || data.is_empty() {
        return None;
    }
    let cipher = aes::Aes192::new(GenericArray::from_slice(&key[..24]));
    let mut out = Vec::with_capacity(data.len());
    let mut prev: [u8; 16] = iv[..16].try_into().unwrap();
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        let cur: [u8; 16] = chunk.try_into().unwrap();
        cipher.decrypt_block(&mut block);
        for i in 0..16 {
            block[i] ^= prev[i];
        }
        prev = cur;
        out.extend_from_slice(&block);
    }
    if out.is_empty() {
        return None;
    }
    let pad = out[out.len() - 1] as usize;
    if (1..=16).contains(&pad)
        && pad <= out.len()
        && out[out.len() - pad..].iter().all(|&b| b as usize == pad)
    {
        out.truncate(out.len() - pad);
    }
    Some(out)
}

fn enc_b64(key: &[u8], iv: &[u8], plain: &str) -> String {
    base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        aes192_cbc_encrypt(key, iv, plain.as_bytes()),
    )
}

fn dec_b64(key: &[u8], iv: &[u8], s: &str) -> Option<String> {
    let raw = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, s).ok()?;
    let plain = aes192_cbc_decrypt(key, iv, &raw)?;
    String::from_utf8(plain).ok()
}

fn xtp() -> String {
    let r: u64 = rand::random::<u64>() % 1000;
    (ms_now() * 1000 + r).to_string()
}

/// x-ph：base64url(AES-192-CBC(K_PH, IV=x-tp, "<path>/<uuid>"))。
fn xph(path: &str, xtp: &str) -> String {
    let rand_bytes: [u8; 16] = rand::random();
    let uuid = format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-4{:01x}{:02x}-{:01x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        rand_bytes[0],
        rand_bytes[1],
        rand_bytes[2],
        rand_bytes[3],
        rand_bytes[4],
        rand_bytes[5],
        rand_bytes[6] & 0x0f,
        rand_bytes[7],
        0x8 | (rand_bytes[8] & 0x03),
        rand_bytes[9],
        rand_bytes[10],
        rand_bytes[11],
        rand_bytes[12],
        rand_bytes[13],
        rand_bytes[14],
        rand_bytes[15],
    );
    let plain = format!("{path}/{uuid}");
    enc_b64(K_PH, xtp.as_bytes(), &plain)
        .replace('+', "-")
        .replace('/', "_")
        .trim_end_matches('=')
        .to_string()
}

fn data_of(resp: &Value) -> Value {
    match get(resp, "data") {
        Some(d) => d.clone(),
        None => Value::Null,
    }
}

/// 加密隧道调用：空响应时换池内另一域名。
async fn call(path: &str, params: &Value, authed: bool) -> ApiResult<Value> {
    let xtp = xtp();
    let x_ph = xph(path, &xtp);
    let enc_path = format!(
        "/enc/{}",
        md5hex(&format!("{}{}", ms_now(), rand::random::<u64>() % 1000))
    );
    let mut body = json!({
        "deviceType": 2,
        "oauthType": "pwa",
        "oauthId": oauth_id(),
    });
    if let Some(m) = params.as_object() {
        for (k, v) in m {
            body[k] = v.clone();
        }
    }
    let payload = enc_b64(K_BODY, V_BODY, &body.to_string());
    let mut hosts: Vec<String> = API_POOL.iter().map(|s| s.to_string()).collect();
    hosts.sort_by_key(|h| if *h == api_host() { 0 } else { 1 });
    for host in hosts {
        let mut req = client()?
            .post(format!("{host}{enc_path}"))
            .header("Content-Type", "application/json")
            .header("x-tp", &xtp)
            .header("x-ph", &x_ph)
            .header("Accept", "application/json, text/plain, */*")
            .header("Origin", CLOUD)
            .header("Referer", format!("{CLOUD}/"))
            .header("User-Agent", UA);
        if authed {
            if let Some(t) = cached_token() {
                req = req.header("Authorization", format!("Bearer {t}"));
            }
        }
        let resp = req
            .body(payload.clone())
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()));
        let resp = match resp {
            Ok(r) => r,
            Err(_) => continue,
        };
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        if text.is_empty() {
            continue;
        }
        set_api(&host);
        let mut value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if let Some(d) = get(&value, "data") {
            if let Some(s) = d.as_str() {
                if let Some(dec) = dec_b64(K_BODY, V_BODY, s) {
                    if let Ok(v) = serde_json::from_str::<Value>(&dec) {
                        if let Some(m) = value.as_object_mut() {
                            m.insert("data".to_string(), v);
                        }
                    }
                }
            }
        }
        return Ok(value);
    }
    Err(ApiError::Internal("海角社区加密隧道无响应".into()))
}

async fn ensure_session() -> ApiResult<()> {
    if cached_token().is_some() {
        return Ok(());
    }
    let _ = call(
        "/user/visitors/register",
        &json!({
            "newDeviceNo": "",
            "platform": "android",
            "channelCode": "",
            "landingPageUrl": "https://img-res-19921.4cixm.com/",
            "inviteCode": "",
        }),
        false,
    )
    .await;
    let resp = call("/user/login/v2", &json!({}), false).await?;
    let token = text_of(&data_of(&resp), &["token"]);
    if token.len() > 20 {
        set_token(&token);
        return Ok(());
    }
    Err(ApiError::Internal("海角社区登录未返回 token".into()))
}

async fn api_call(path: &str, params: &Value) -> ApiResult<Value> {
    ensure_session().await?;
    let resp = call(path, params, true).await?;
    if int_of(&resp, &["code"]) == 401 {
        clear_token();
        ensure_session().await?;
        return call(path, params, true).await;
    }
    Ok(resp)
}

fn as_list(data: &Value) -> Vec<Value> {
    if let Some(arr) = arr_of(data) {
        return arr.clone();
    }
    Vec::new()
}

fn pic_of(cover: &str, rel: &str) -> String {
    let c = cover.trim();
    if !c.is_empty() {
        return c.to_string();
    }
    let r = rel.trim();
    if r.is_empty() {
        return String::new();
    }
    if r.starts_with("http") {
        r.to_string()
    } else {
        format!("{CLOUD}{r}")
    }
}

fn cards_post(rows: &[Value], free_only: bool) -> Vec<Value> {
    let mut items = Vec::new();
    for e in rows {
        let id = int_of(e, &["id"]);
        if id <= 0 {
            continue;
        }
        let mut title = text_of(e, &["title"]).replace('\n', " ").trim().to_string();
        if title.is_empty() {
            title = format!("海角社区 #{id}");
        }
        let charge = int_of(e, &["chargeAmount"]);
        let videos = get(e, "videoList")
            .and_then(arr_of)
            .map(|a| a.len())
            .unwrap_or(0);
        if free_only && !(charge <= 0 && videos > 0) {
            continue;
        }
        let pictures = get(e, "pictureList")
            .and_then(arr_of)
            .map(|a| a.len())
            .unwrap_or(0);
        let cover = get(e, "pictureList")
            .and_then(arr_of)
            .and_then(|a| a.first())
            .map(|v| v.as_str().unwrap_or("").trim().to_string())
            .unwrap_or_default();
        let mut remark = String::new();
        if videos > 0 {
            remark.push_str(&format!("{videos} 路视频"));
        } else if pictures > 0 {
            remark.push_str(&format!("{pictures} 图"));
        }
        if charge > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("需 {charge} 币"));
        } else if videos > 0 {
            remark.push_str(" · 免费");
        }
        items.push(item_json(&format!("post:{id}"), &title, &cover, &remark));
    }
    items
}

fn cards_video(rows: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in rows {
        let id = int_of(e, &["id"]);
        if id <= 0 {
            continue;
        }
        let mut title = text_of(e, &["title"]).replace('\n', " ").trim().to_string();
        if title.is_empty() {
            title = format!("海角视频 #{id}");
        }
        let charge = int_of(e, &["chargeAmount"]);
        let is_free = int_of(e, &["isFree"]) == 1;
        let dur = text_of(e, &["durationStr"]);
        let mut remark = String::new();
        if !dur.is_empty() {
            remark.push_str(&dur);
            remark.push_str(" · ");
        }
        if charge <= 0 || is_free {
            remark.push_str("预览免费");
        } else {
            remark.push_str(&format!("需 {charge} 币"));
        }
        let cover = pic_of(&text_of(e, &["cover"]), &text_of(e, &["coverRelativePath"]));
        items.push(item_json(&format!("video:{id}"), &title, &cover, &remark));
    }
    items
}

fn fixed_categories() -> Value {
    json!({"categories": [
        category_json("free", "免费视频帖"),
        category_json("video", "视频帖"),
        category_json("new", "最新帖子"),
        category_json("hot", "热门帖子"),
        category_json("rec", "仅预览·视频频道"),
    ]})
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match api_call("/post-category/all", &json!({})).await {
        Ok(resp) => {
            let mut list = vec![
                category_json("free", "免费视频帖"),
                category_json("video", "视频帖"),
                category_json("new", "最新帖子"),
                category_json("hot", "热门帖子"),
                category_json("rec", "仅预览·视频频道"),
            ];
            let rows = as_list(&data_of(&resp));
            for e in &rows {
                let name = text_of(e, &["name"]);
                let id = text_of(e, &["id"]);
                if !name.is_empty() && !id.is_empty() {
                    list.push(category_json(&format!("cat:{id}"), &name));
                }
            }
            if list.len() <= 5 {
                return Ok(fixed_categories());
            }
            Ok(json!({"categories": list}))
        }
        Err(_) => Ok(fixed_categories()),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    if category_id == "rec" {
        let resp = api_call(
            "/video/recommendation",
            &json!({"page": page, "pageSize": PAGE_SIZE}),
        )
        .await?;
        let rows = as_list(&data_of(&resp));
        let items = cards_video(&rows);
        let has_more = items.len() as i64 >= 19;
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    if category_id == "free" {
        let mut all: Vec<Value> = Vec::new();
        for i in 0..3 {
            let p = (page - 1) * 3 + 1 + i;
            let resp = api_call(
                "/post/list",
                &json!({"page": p, "pageSize": 30, "isLatest": true}),
            )
            .await?;
            let rows = as_list(&data_of(&resp));
            all.extend(cards_post(&rows, true));
            if all.len() >= PAGE_SIZE as usize {
                break;
            }
        }
        all.truncate(PAGE_SIZE as usize);
        let has_more = all.len() as i64 >= 19;
        return Ok(json!({"items": all, "has_more": has_more}));
    }
    let params = if category_id == "new" {
        json!({"page": page, "pageSize": PAGE_SIZE, "isLatest": true})
    } else if category_id == "hot" {
        json!({"page": page, "pageSize": PAGE_SIZE, "isHottest": true})
    } else if let Some(cid) = category_id.strip_prefix("cat:") {
        let cid_num: i64 = cid.parse().unwrap_or(0);
        json!({"page": page, "pageSize": PAGE_SIZE, "postCategoryId": cid_num, "isLatest": true})
    } else {
        json!({"page": page, "pageSize": PAGE_SIZE, "isVideo": true, "isLatest": true})
    };
    let resp = api_call("/post/list", &params).await?;
    let rows = as_list(&data_of(&resp));
    let items = cards_post(&rows, false);
    let has_more = items.len() as i64 >= 19;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    if let Some(vid) = series_id.strip_prefix("video:") {
        let id: i64 = vid
            .parse()
            .map_err(|_| ApiError::Internal("海角社区视频 id 非数字".into()))?;
        let resp = api_call("/video/detail/v2", &json!({"id": id})).await?;
        let data = data_of(&resp);
        let mut title = text_of(&data, &["title"]).trim().to_string();
        if title.is_empty() {
            title = format!("海角视频 #{id}");
        }
        let cover = pic_of(
            &text_of(&data, &["cover"]),
            &text_of(&data, &["coverRelativePath"]),
        );
        let charge = int_of(&data, &["chargeAmount"]);
        let is_free = int_of(&data, &["isFree"]) == 1;
        let link = text_of(&data, &["previewVideoLink"]);
        let mut episodes: Vec<Value> = Vec::new();
        if !link.is_empty() {
            let name = if charge <= 0 || is_free {
                "完整"
            } else {
                "预览"
            };
            episodes.push(episode_json(&link, name, series_id));
        }
        let synopsis = format!(
            "时长：{}\n收费：{}\n完整片源需站内购买，接口只下发预览流。",
            text_of(&data, &["durationStr"]),
            if charge > 0 {
                format!("需 {charge} 币")
            } else {
                "免费".to_string()
            }
        );
        return Ok(json!({
            "id": series_id,
            "title": title,
            "cover": cover,
            "synopsis": synopsis,
            "extra": {"vod_play_from": "海角社区"},
            "episodes": episodes,
        }));
    }
    let pid = series_id
        .strip_prefix("post:")
        .unwrap_or(series_id)
        .parse::<i64>()
        .map_err(|_| ApiError::Internal("海角社区帖子 id 非数字".into()))?;
    let resp = api_call("/post/detail", &json!({"id": pid})).await?;
    let data = data_of(&resp);
    let mut title = text_of(&data, &["title"]).trim().to_string();
    if title.is_empty() {
        title = format!("海角社区 #{pid}");
    }
    let charge = int_of(&data, &["chargeAmount"]);
    let mut pics: Vec<String> = Vec::new();
    if let Some(arr) = get(&data, "pictureList").and_then(arr_of) {
        for v in arr {
            let u = v.as_str().unwrap_or("").trim().to_string();
            if !u.is_empty() && !pics.contains(&u) {
                pics.push(u);
            }
        }
    }
    let mut body_text = text_of(&data, &["content"]).trim().to_string();
    if let Some(contents) = get(&data, "postContents").and_then(arr_of) {
        for c in contents {
            let t = text_of(c, &["content"]).trim().to_string();
            if !t.is_empty() {
                if !body_text.is_empty() {
                    body_text.push_str("\n\n");
                }
                body_text.push_str(&t);
            }
            if let Some(imgs) = get(c, "imagesList").and_then(arr_of) {
                for v in imgs {
                    let u = v.as_str().unwrap_or("").trim().to_string();
                    if !u.is_empty() && !pics.contains(&u) {
                        pics.push(u);
                    }
                }
            }
        }
    }
    let cover = pics.first().cloned().unwrap_or_default();
    let mut episodes: Vec<Value> = Vec::new();
    let mut previews: Vec<Value> = Vec::new();
    if let Some(videos) = get(&data, "videoList").and_then(arr_of) {
        for (i, v) in videos.iter().enumerate() {
            let url = text_of(v, &["videoUrl"]);
            let pre = text_of(v, &["previewPath"]);
            if !url.is_empty() {
                episodes.push(episode_json(&url, &format!("视频 {}", i + 1), series_id));
            } else if !pre.is_empty() {
                previews.push(episode_json(&pre, &format!("预览 {}", i + 1), series_id));
            }
        }
    }
    if episodes.is_empty() {
        episodes = previews;
    }
    if episodes.is_empty() {
        if let Some(first) = pics.first() {
            episodes.push(episode_json(first, "图片 1", series_id));
        }
    }
    let synopsis = if body_text.is_empty() {
        format!(
            "收费：{}",
            if charge > 0 {
                format!("需 {charge} 币")
            } else {
                "免费".to_string()
            }
        )
    } else {
        body_text
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"vod_play_from": "海角社区"},
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let url = if video_id.starts_with("//") {
        format!("https:{video_id}")
    } else if video_id.starts_with("http") {
        video_id.to_string()
    } else if video_id.starts_with('/') {
        format!("{CLOUD}{video_id}")
    } else {
        return Err(ApiError::Internal("海角社区该集没有播放地址".into()));
    };
    Ok(json!({
        "url": url,
        "header": {"User-Agent": MOBILE_UA, "Referer": format!("{CLOUD}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let resp = api_call(
        "/post/list",
        &json!({"page": 1, "pageSize": PAGE_SIZE, "title": query}),
    )
    .await?;
    let rows = as_list(&data_of(&resp));
    Ok(json!({"items": cards_post(&rows, false)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aes192_roundtrip() {
        let plain = b"{\"deviceType\":2}";
        let ct = aes192_cbc_encrypt(K_BODY, V_BODY, plain);
        let back = aes192_cbc_decrypt(K_BODY, V_BODY, &ct).unwrap();
        assert_eq!(back, plain);
        let b64 = enc_b64(K_BODY, V_BODY, "{\"deviceType\":2}");
        let dec = dec_b64(K_BODY, V_BODY, &b64).unwrap();
        assert_eq!(dec, "{\"deviceType\":2}");
    }

    #[test]
    fn md5hex_shape() {
        let h = md5hex("abc123");
        assert_eq!(h.len(), 32);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn xph_is_url_safe() {
        let x = xtp();
        let p = xph("/post/list", &x);
        assert!(!p.contains('+') && !p.contains('/') && !p.contains('='));
        assert!(!p.is_empty());
    }

    #[test]
    fn cards_post_free_filter() {
        let rows = vec![
            json!({"id": 1, "title": "免费有视频", "chargeAmount": 0, "videoList": [{"videoUrl": "u"}], "pictureList": ["p1"]}),
            json!({"id": 2, "title": "收费有视频", "chargeAmount": 58, "videoList": [{"videoUrl": "u"}]}),
            json!({"id": 3, "title": "免费无视频", "chargeAmount": 0, "videoList": [], "pictureList": ["p1", "p2"]}),
        ];
        assert_eq!(cards_post(&rows, true).len(), 1);
        assert_eq!(cards_post(&rows, false).len(), 3);
        assert_eq!(cards_post(&rows, false)[1]["remark"], "1 路视频 · 需 58 币");
        assert_eq!(cards_post(&rows, false)[2]["remark"], "2 图");
    }

    #[test]
    fn cards_video_remark() {
        let rows = vec![
            json!({"id": 9, "title": "免费片", "chargeAmount": 0, "isFree": 0, "durationStr": "00:52:21", "cover": "c"}),
            json!({"id": 10, "title": "收费片", "chargeAmount": 30, "isFree": 0, "durationStr": "", "cover": "c"}),
        ];
        let items = cards_video(&rows);
        assert_eq!(items[0]["remark"], "00:52:21 · 预览免费");
        assert_eq!(items[1]["remark"], "需 30 币");
    }
}
