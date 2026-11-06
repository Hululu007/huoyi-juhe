//! 黄果短剧 v1（hgdjh58.com）：H5/PC 新版 API。
//!
//! 与 hgdj（huangguoai.com HTML 站）、hgdjv（旧版 App API
//! `/api/video/*`，2026-11-06 实测登录/分类/列表/详情/canWatch 全通）
//! 同品牌不同代接口，不共用模块。两个入口链接同站不同入口，根域
//! 同为 hgdjh58.com，H5 在 punycode 子域，apex 根只跳 GoDaddy 停放页。
//! 线路：`api-routes-v1.json`（R2 与腾讯云 COS 双源），primary a2，
//! 线路 1–5 为 a2..a6.hgdjapN.com，按优先级 failover。
//! 分类 GET `/api/v1/categories`（4 项，实测 2026-11-06：黄果原创🔥、
//! AI成人短剧、AI成人漫剧、AI魔改）。
//! 列表 GET `/api/v1/dramas/home?page=&category_id=&order=hot`
//! （60 条/页，实测 p1/p2 均 60 条）；推荐
//! GET `/api/v1/dramas/recommend?page=&page_size=10&tab=hot`；
//! 搜索 GET `/api/v1/dramas/search?q=&page=&page_size=`（搜“大小姐”
//! 60 条）；详情 GET `/api/v1/dramas/{id}`（517《与纯阴圣体大小姐双修》
//! 10 集，play_count 529256）；分集
//! GET `/api/v1/dramas/{id}/episodes`（预告 free + 各集 vip/paid，
//! locked，video_url 为空，须调 play 接口现取）。
//! 取流 POST `/api/v1/episodes/{id}/play?playback_client=pc`（无 body）；
//! 解锁报价 POST `/api/v1/dramas/{id}/unlock-quote {episode_id}`；
//! 解锁购买 POST `/api/v1/dramas/{id}/unlock-purchase {quote_id, mode}`。
//! 请求头 `X-Device-Id` + `X-Client-Platform: h5`，登录后加
//! `Authorization: Bearer <token>`；游客登录
//! POST `/api/v1/auth/guest {requestKey, automatic, guestDeviceKey}`，
//! requestKey 为 32 随机字节 base64url（43 字符）。
//! 封面：列表只给 cover_thumb_url（相对路径，指向描述 JSON），须再取
//! GET `/api/v1/public/dramas/{id}/cover[/thumb]` 得
//! `{routes:[{id, route_id, name, url}], expires_at, ...}`，取
//! routes[0].url 作真封面（encrypted=false 时即原图）；并发解析。
//! 2026-11-06 本机出口 POST 到 v1 全线被静默丢弃（TCP+TLS 通，POST
//! 发出后 0 字节、60 秒超时；a2/a3/a4、带/不带 Origin、空 body 均同；
//! 同机 GET 正常），故 play/unlock-quote/unlock-purchase 按 H5 bundle
//! （PC main.DRzoe055.js 与移动 main.7YI9ZiiO.js）契约实现，未能本机
//! 验通，须手机实测。GET 面全部实测通过。

use std::sync::Mutex;

use base64::Engine as _;
use futures::future::join_all;
use once_cell::sync::Lazy;
use rand::Rng;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const ORIGINS: &[&str] = &[
    "https://a2.hgdjap2.com",
    "https://a3.hgdjap3.com",
    "https://a4.hgdjap4.com",
    "https://a5.hgdjap5.com",
    "https://a6.hgdjap6.com",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const H5_ORIGIN: &str = "https://xn---176198876-wj2q194rql3bfw9g.hgdjh58.com";

struct Session {
    device_id: String,
    token: String,
}

static SESSION: Lazy<Mutex<Session>> = Lazy::new(|| {
    let mut rng = rand::thread_rng();
    let mut b = [0u8; 16];
    rng.fill(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let device_id = format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12],
        b[13], b[14], b[15]
    );
    Mutex::new(Session {
        device_id,
        token: String::new(),
    })
});

fn request_key() -> String {
    let mut rng = rand::thread_rng();
    let mut b = [0u8; 32];
    rng.fill(&mut b);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b)
}

fn token() -> String {
    SESSION.lock().unwrap().token.clone()
}

fn device_id() -> String {
    SESSION.lock().unwrap().device_id.clone()
}

fn headers() -> Vec<(String, String)> {
    let mut h: Vec<(String, String)> = vec![
        ("Accept".into(), "application/json".into()),
        ("X-Device-Id".into(), device_id()),
        ("X-Client-Platform".into(), "h5".into()),
        ("User-Agent".into(), UA.into()),
    ];
    let t = token();
    if !t.is_empty() {
        h.push(("Authorization".into(), format!("Bearer {t}")));
    }
    h
}

fn err_code(v: &Value) -> i64 {
    int_of(v, &["code"])
}

/// 单源 GET，返回 (http_status, json)。非 200 也尽量解析 body。
async fn get_once(origin: &str, path: &str) -> (u16, Value) {
    let url = format!("{origin}/api/v1{path}");
    let mut req = match client() {
        Ok(c) => c.get(&url),
        Err(_) => return (0, Value::Null),
    };
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    let resp = match req.send().await {
        Ok(r) => r,
        Err(_) => return (0, Value::Null),
    };
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    (status, v)
}

/// 单源 POST，body 为 JSON 字符串或空。
async fn post_once(origin: &str, path: &str, body: Option<&str>) -> (u16, Value) {
    let url = format!("{origin}/api/v1{path}");
    let mut req = match client() {
        Ok(c) => c.post(&url),
        Err(_) => return (0, Value::Null),
    };
    for (k, v) in headers() {
        req = req.header(k, v);
    }
    req = req.header("Content-Type", "application/json");
    if let Some(b) = body {
        req = req.body(b.to_string());
    }
    let resp = match req.send().await {
        Ok(r) => r,
        Err(_) => return (0, Value::Null),
    };
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    (status, v)
}

/// 游客登录：POST /auth/guest，成功后缓存 token。
async fn guest_login() -> bool {
    let rk = request_key();
    let body = json!({
        "requestKey": rk,
        "automatic": true,
        "guestDeviceKey": device_id(),
    })
    .to_string();
    for origin in ORIGINS {
        let (status, v) = post_once(origin, "/auth/guest", Some(&body)).await;
        if status == 200 {
            let t = text_of(&v, &["token"]);
            let t = if t.is_empty() {
                text_of(get(&v, "data").unwrap_or(&Value::Null), &["token"])
            } else {
                t
            };
            if !t.is_empty() {
                SESSION.lock().unwrap().token = t;
                return true;
            }
        }
    }
    false
}

/// GET：按线路优先级 failover；401/403 时游客登录后重试一次。
async fn api_get(path: &str) -> Value {
    for origin in ORIGINS {
        let (status, v) = get_once(origin, path).await;
        if status == 200 {
            return v;
        }
        if (status == 401 || status == 403) && (err_code(&v) == 4005 || err_code(&v) == 4003) {
            if guest_login().await {
                let (s2, v2) = get_once(origin, path).await;
                if s2 == 200 {
                    return v2;
                }
            }
        }
    }
    Value::Null
}

/// POST：按线路优先级 failover；401/403 时游客登录后重试一次。
async fn api_post(path: &str, body: Option<&str>) -> (u16, Value) {
    for origin in ORIGINS {
        let (status, v) = post_once(origin, path, body).await;
        if status != 0 {
            if status == 200 {
                return (status, v);
            }
            if (status == 401 || status == 403) && (err_code(&v) == 4005 || err_code(&v) == 4003) {
                if guest_login().await {
                    let (s2, v2) = post_once(origin, path, body).await;
                    if s2 != 0 {
                        return (s2, v2);
                    }
                }
            }
        }
    }
    (0, Value::Null)
}

/// 封面描述 JSON -> 首条路由直链（绝对地址；相对则拼 origin）。
fn descriptor_url(v: &Value, origin: &str) -> String {
    if let Some(arr) = arr_of(get(v, "routes").unwrap_or(&Value::Null)) {
        if let Some(first) = arr.first() {
            let u = text_of(first, &["url"]);
            if !u.is_empty() {
                if u.starts_with("http://") || u.starts_with("https://") {
                    return u;
                }
                if let Some(rest) = u.strip_prefix('/') {
                    return format!("{origin}/{rest}");
                }
                return format!("{origin}/{u}");
            }
        }
    }
    String::new()
}

/// 取封面描述（thumb 优先），返回直链；失败返回空串。
async fn resolve_cover(thumb_path: &str) -> String {
    if thumb_path.is_empty() {
        return String::new();
    }
    let path = if thumb_path.starts_with("/api/v1/") {
        thumb_path.trim_start_matches("/api/v1").to_string()
    } else if thumb_path.starts_with('/') {
        thumb_path.to_string()
    } else {
        format!("/{thumb_path}")
    };
    for origin in ORIGINS {
        let (status, v) = get_once(origin, &path).await;
        if status == 200 {
            let u = descriptor_url(&v, origin);
            if !u.is_empty() {
                return u;
            }
        }
    }
    String::new()
}

fn card_fields(v: &Value) -> (String, String, String, String) {
    let id = text_of(v, &["id"]);
    let title = text_of(v, &["title"]);
    let thumb = text_of(v, &["cover_thumb_url", "cover_url"]);
    let ep = int_of(v, &["episode_count"]);
    let remark = if ep > 0 {
        format!("{ep}集")
    } else {
        String::new()
    };
    (id, title, thumb, remark)
}

async fn cards_with_covers(list: &[Value]) -> Vec<Value> {
    let fields: Vec<(String, String, String, String)> = list.iter().map(card_fields).collect();
    let covers = join_all(fields.iter().map(|(_, _, thumb, _)| resolve_cover(thumb))).await;
    fields
        .into_iter()
        .zip(covers.into_iter())
        .filter_map(|((id, title, _, remark), cover)| {
            if id.is_empty() || title.is_empty() {
                return None;
            }
            Some(item_json(&id, &title, &cover, &remark))
        })
        .collect()
}

fn list_of(v: &Value) -> Vec<Value> {
    arr_of(get(v, "list").unwrap_or(&Value::Null))
        .cloned()
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let v = api_get("/categories").await;
    let mut cats: Vec<Value> = vec![category_json("home", "推荐")];
    for item in list_of(&v) {
        let id = text_of(&item, &["id"]);
        let name = text_of(&item, &["name"]);
        if !id.is_empty() && !name.is_empty() {
            cats.push(category_json(&id, &name));
        }
    }
    Ok(json!({"categories": cats}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let mut path = format!("/dramas/home?page={page}&page_size=30&order=hot");
    if category_id != "home" && !category_id.is_empty() {
        let enc = url::form_urlencoded::byte_serialize(category_id.as_bytes()).collect::<String>();
        path.push_str(&format!("&category_id={enc}"));
    }
    let v = api_get(&path).await;
    let items = list_of(&v);
    let total = int_of(&v, &["total"]);
    let cards = cards_with_covers(&items).await;
    let has_more = if total > 0 {
        page * 30 < total
    } else {
        items.len() >= 30
    };
    Ok(json!({"items": cards, "has_more": has_more}))
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    let v = api_get(&format!(
        "/dramas/{}",
        url::form_urlencoded::byte_serialize(id.as_bytes()).collect::<String>()
    ))
    .await;
    let title = text_of(&v, &["title"]);
    let synopsis = text_of(&v, &["description"]);
    let cover_path = text_of(&v, &["cover_url", "cover_thumb_url"]);
    let cover = resolve_cover(&cover_path).await;
    let category = text_of(&v, &["category"]);
    let tags = arr_of(get(&v, "tags").unwrap_or(&Value::Null))
        .map(|a| {
            a.iter()
                .map(|t| t.as_str().unwrap_or("").to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_default();
    let ep_count = int_of(&v, &["episode_count"]);
    let play_count = int_of(&v, &["play_count"]);
    let mut remark = String::new();
    if ep_count > 0 {
        remark = format!("{ep_count}集");
    }
    if play_count > 0 {
        if !remark.is_empty() {
            remark.push_str(" | ");
        }
        remark.push_str(&format!("{play_count}播放"));
    }
    let ev = api_get(&format!(
        "/dramas/{}/episodes",
        url::form_urlencoded::byte_serialize(id.as_bytes()).collect::<String>()
    ))
    .await;
    let mut episodes: Vec<Value> = Vec::new();
    for e in list_of(&ev) {
        let eid = text_of(&e, &["id"]);
        if eid.is_empty() {
            continue;
        }
        let number = int_of(&e, &["number"]);
        let etitle = text_of(&e, &["title"]);
        let access = text_of(&e, &["access_type"]);
        let locked = get(&e, "locked").and_then(|b| b.as_bool()).unwrap_or(false);
        let coin = int_of(&e, &["coin_price"]);
        let mut name = if number == 0 {
            "预告".to_string()
        } else if !etitle.is_empty() {
            etitle
        } else {
            format!("第{number}集")
        };
        if locked {
            if access == "paid" && coin > 0 {
                name = format!("{name}（{coin}金币）");
            } else {
                name = format!("{name}（VIP）");
            }
        }
        episodes.push(episode_json(&eid, &name, id));
    }
    if episodes.is_empty() {
        episodes.push(episode_json(id, "正片", id));
    }
    let stills = if cover.is_empty() {
        Vec::new()
    } else {
        vec![cover.clone()]
    };
    Ok(json!({
        "id": id,
        "title": title,
        "cover": cover,
        "synopsis": if synopsis.is_empty() { title.clone() } else { synopsis },
        "extra": {"category": category, "tags": tags, "remarks": remark, "stills": stills},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let v = api_get(&format!("/dramas/search?q={enc}&page=1&page_size=30")).await;
    let items = list_of(&v);
    let cards = cards_with_covers(&items).await;
    Ok(json!({"items": cards}))
}

/// play 响应取流：media_routes[0].url -> video_url -> routes[0].url -> url。
fn play_url_of(v: &Value) -> String {
    if let Some(arr) = arr_of(get(v, "media_routes").unwrap_or(&Value::Null)) {
        if let Some(first) = arr.first() {
            let u = text_of(first, &["url"]);
            if !u.is_empty() {
                return u;
            }
        }
    }
    let u = text_of(v, &["video_url"]);
    if !u.is_empty() {
        return u;
    }
    if let Some(arr) = arr_of(get(v, "routes").unwrap_or(&Value::Null)) {
        if let Some(first) = arr.first() {
            let u = text_of(first, &["url"]);
            if !u.is_empty() {
                return u;
            }
        }
    }
    text_of(v, &["url"])
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let path = format!(
        "/episodes/{}/play?playback_client=pc",
        url::form_urlencoded::byte_serialize(video_id.as_bytes()).collect::<String>()
    );
    let (status, v) = api_post(&path, None).await;
    if status == 0 {
        return Err(ApiError::Internal(
            "hgdj58 取流无响应（本机出口 POST 被丢弃，须手机实测）".into(),
        ));
    }
    let url = play_url_of(&v);
    if url.is_empty() {
        let msg = text_of(&v, &["message"]);
        let msg = if msg.is_empty() {
            format!("hgdj58 该集没有播放地址（HTTP {status}）")
        } else {
            format!("hgdj58 {msg}")
        };
        return Err(ApiError::Internal(msg));
    }
    Ok(json!({"url": url, "header": {"User-Agent": UA, "Referer": format!("{H5_ORIGIN}/")}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_categories_real() {
        let v: Value = serde_json::from_str(
            r#"{"list":[{"id":6,"name":"黄果原创🔥"},{"id":7,"name":"AI成人短剧"},{"id":8,"name":"AI成人漫剧"},{"id":9,"name":"AI魔改"}]}"#,
        )
        .unwrap();
        let items = list_of(&v);
        assert_eq!(items.len(), 4);
        assert_eq!(text_of(&items[0], &["name"]), "黄果原创🔥");
        assert_eq!(text_of(&items[3], &["id"]), "9");
    }

    #[test]
    fn parse_drama_detail_real() {
        let v: Value = serde_json::from_str(
            r#"{"category":"黄果原创🔥","cover_thumb_url":"/api/v1/public/dramas/517/cover/thumb","cover_url":"/api/v1/public/dramas/517/cover","description":"拥有纯阳之体的男主","episode_count":10,"id":517,"play_count":529256,"tags":["修仙","逆袭"],"title":"与纯阴圣体大小姐双修"}"#,
        )
        .unwrap();
        assert_eq!(text_of(&v, &["title"]), "与纯阴圣体大小姐双修");
        assert_eq!(int_of(&v, &["episode_count"]), 10);
        let (id, title, thumb, remark) = card_fields(&v);
        assert_eq!(id, "517");
        assert_eq!(title, "与纯阴圣体大小姐双修");
        assert_eq!(thumb, "/api/v1/public/dramas/517/cover/thumb");
        assert_eq!(remark, "10集");
    }

    #[test]
    fn parse_episodes_labels() {
        let v: Value = serde_json::from_str(
            r#"{"list":[{"access_type":"free","coin_price":0,"drama_id":517,"id":2061,"locked":false,"number":0,"title":"预告","video_url":""},{"access_type":"vip","coin_price":0,"drama_id":517,"id":2051,"locked":true,"number":1,"title":"第1集","video_url":""},{"access_type":"paid","coin_price":49,"drama_id":517,"id":2323,"locked":true,"number":6,"title":"第6集","video_url":""}]}"#,
        )
        .unwrap();
        let items = list_of(&v);
        assert_eq!(items.len(), 3);
        assert_eq!(text_of(&items[0], &["access_type"]), "free");
        assert!(!get(&items[0], "locked")
            .and_then(|b| b.as_bool())
            .unwrap_or(true));
        assert_eq!(int_of(&items[2], &["coin_price"]), 49);
    }

    #[test]
    fn cover_descriptor_first_route() {
        let v: Value = serde_json::from_str(
            r#"{"encrypted":false,"schema_version":2,"encoding":"xor-prefix-v1","drama_id":517,"mime":"image/webp","expires_at":1793908744,"routes":[{"id":"r2:0","route_id":"r2","name":"R2","url":"https://img.hgspr226103.com/covers/abc/cover.enc"}]}"#,
        )
        .unwrap();
        assert_eq!(
            descriptor_url(&v, "https://a2.hgdjap2.com"),
            "https://img.hgspr226103.com/covers/abc/cover.enc"
        );
    }

    #[test]
    fn play_url_variants() {
        let a: Value = serde_json::from_str(
            r#"{"media_routes":[{"id":"r2:0","route_id":"r2","name":"R2","url":"https://example.com/a.m3u8"}],"media_expires_at":1793908744}"#,
        )
        .unwrap();
        assert_eq!(play_url_of(&a), "https://example.com/a.m3u8");
        let b: Value =
            serde_json::from_str(r#"{"video_url":"https://example.com/b.m3u8"}"#).unwrap();
        assert_eq!(play_url_of(&b), "https://example.com/b.m3u8");
        let c: Value = serde_json::from_str(
            r#"{"routes":[{"id":"r2:0","route_id":"r2","name":"R2","url":"https://example.com/c.m3u8"}]}"#,
        )
        .unwrap();
        assert_eq!(play_url_of(&c), "https://example.com/c.m3u8");
        let d: Value = serde_json::from_str(r#"{"message":"需要 VIP"}"#).unwrap();
        assert_eq!(play_url_of(&d), "");
    }

    #[test]
    fn request_key_shape() {
        let k = request_key();
        assert_eq!(k.len(), 43);
        assert!(k
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }
}
