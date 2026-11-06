//! XLook中文大全：核心里的影视区站点。
//!
//! 与 py 版 xlook.py 同一套分类、同一条已验播放链。站为 Vue 单页，
//! 入口 zw.mmjvlook.top 301 跳到轮换镜像域名，数据接口固定走
//! zdap.gkquu.cn:4438/zd/（GET + 自定义签名头，响应 returnData 为
//! AES-128-CBC 加密的 base64，密钥与 IV 见下）。url 头必须用当前
//! 镜像域名（目录/详情/搜索接口会校验，入口域名回参数异常），由
//! 入口 301 动态解析，失败用上次已验镜像兜底。导航 getTabList 共
//! 7 个版块，其中视频型（plateType 1）4 个：短视频（4）目录报参
//! 数异常、动漫（7）目录报 HTTP 500，两版块实测不通故不列入；只
//! 列能播的两成人版块：成人天堂（19）与成人视频（22），每版块各
//! 仅一个标签“每日更新”。取流为详情 videoUrlOne 直链 mp4（已验
//! Range 206 + ftyp），videoUrlTwo 为同源镜像；搜索结果里部分
//! videoUrlOne 为 m3u8，详情统一回 mp4。站内有 VIP 开通提示，但
//! 已验链路的视频均带免费直链，未触付费墙；标题为空的单片用发
//! 布者昵称兜底。

use aes::Aes128;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::{
    cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit},
    Decryptor,
};
use md5::{Digest, Md5};
use rand::Rng;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const API: &str = "https://zdap.gkquu.cn:4438/zd/";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const ENTRY: &str = "http://zw.mmjvlook.top/";
const MIRROR_FALLBACK: &str = "ifbbgjob.jvlookdp05.cn";
const SIGN_SALT: &str = "@1243asd31**21#";
const AES_KEY: &[u8] = b"mh_aes=19@#$@%@#";
const AES_IV: &[u8] = b"5e1y6w452uqw9jq8";
const NONCE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678";

/// 已验能播的视频版块：[plateId, 名]，与站 getTabList 导航一致。
/// 短视频（4）与动漫（7）同链路实测不通（参数异常 / HTTP 500），
/// 不列入；短剧合集与两动态专区非视频型，不进影视区。
const CATS: &[(&str, &str)] = &[("19", "成人天堂"), ("22", "成人视频")];
const PLATES: &[i64] = &[19, 22];

fn new_uuid() -> String {
    let mut rng = rand::thread_rng();
    let mut b = [0u8; 16];
    rng.fill(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
    )
}

fn new_nonce() -> String {
    let mut rng = rand::thread_rng();
    (0..16)
        .map(|_| {
            let idx = rng.gen_range(0..NONCE_ALPHABET.len());
            NONCE_ALPHABET[idx] as char
        })
        .collect()
}

fn millis_now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// url 头必须用当前镜像域名：目录/详情/搜索接口会校验，入口域名回
/// returnValue 3 参数异常（getPlateList/getTabList 不校验，之前误
/// 判为不校验）。入口 301 的 Location 即当前镜像，解析失败时用上
/// 次已验的镜像域名兜底；解析成功的结果进程内缓存一次。
async fn url_host() -> String {
    static MIRROR: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    if let Some(host) = MIRROR.get() {
        return host.clone();
    }
    let mut host = MIRROR_FALLBACK.to_string();
    if let Ok(c) = client() {
        if let Ok(resp) = c.get(ENTRY).send().await {
            if let Some(h) = resp.url().host_str() {
                host = h.to_string();
                let _ = MIRROR.set(host.clone());
            }
        }
    }
    host
}

/// 签名：MD5(时间戳 + guid + nonce + 盐) 的大写 hex，与站内 JS 同款。
fn sign(timestamp: &str, guid: &str, nonce: &str) -> String {
    let mut h = Md5::new();
    h.update(timestamp.as_bytes());
    h.update(guid.as_bytes());
    h.update(nonce.as_bytes());
    h.update(SIGN_SALT.as_bytes());
    hex::encode_upper(h.finalize())
}

/// AES-128-CBC 解密 returnData：base64 解码后 PKCS7 去垫。
fn aes_decrypt(ciphertext_b64: &str) -> ApiResult<String> {
    let raw = STANDARD
        .decode(ciphertext_b64.trim())
        .map_err(|e| ApiError::Internal(format!("XLook 返回数据 base64 解码失败：{e}")))?;
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Err(ApiError::Internal("XLook 返回数据长度异常".into()));
    }
    let plain = Decryptor::<Aes128>::new_from_slices(AES_KEY, AES_IV)
        .map_err(|e| ApiError::Internal(format!("XLook 解密器初始化失败：{e}")))?
        .decrypt_padded_vec_mut::<Pkcs7>(&raw)
        .map_err(|e| ApiError::Internal(format!("XLook AES 解密失败：{e}")))?;
    String::from_utf8(plain).map_err(|e| ApiError::Internal(format!("XLook 解密结果非 UTF-8：{e}")))
}

/// 带签名头的 GET：响应 {returnValue, returnData}，returnData 为加密
/// 串时解密成 JSON，本身已是对象时直接用（与站内拦截器同款）。
async fn api_json(path: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    let guid = new_uuid();
    let nonce = new_nonce();
    let timestamp = millis_now().to_string();
    let url = with_query(&format!("{API}{path}"), params);
    let resp = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("token", guid.as_str())
        .header("sign", sign(&timestamp, &guid, &nonce))
        .header("timestamp", timestamp.as_str())
        .header("nonce", nonce.as_str())
        .header("url", url_host().await)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("XLook 请求失败：{e}")))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("XLook 请求 HTTP {status}")));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("XLook 响应非 JSON：{e}")))?;
    let code = int_of(&body, &["returnValue"]);
    if code != 1 {
        let msg = text_of(&body, &["msg"]);
        return Err(ApiError::Internal(format!(
            "XLook 接口返回 {code}{}",
            if msg.is_empty() {
                String::new()
            } else {
                format!("：{msg}")
            }
        )));
    }
    match get(&body, "returnData") {
        Some(Value::String(s)) => {
            let plain = aes_decrypt(s)?;
            serde_json::from_str(&plain)
                .map_err(|e| ApiError::Internal(format!("XLook 解密结果非 JSON：{e}")))
        }
        Some(v) => Ok(v.clone()),
        None => Ok(json!({})),
    }
}

/// 标题兜底：videoTitle 为空时用昵称，再空用用户名，最后用 videoId。
fn video_title(v: &Value) -> String {
    let title = text_of(v, &["videoTitle"]);
    if !title.is_empty() {
        return title;
    }
    let nick = text_of(v, &["nickName"]);
    if !nick.is_empty() {
        return nick;
    }
    let user = text_of(v, &["userName"]);
    if !user.is_empty() {
        return user;
    }
    text_of(v, &["videoId"])
}

fn video_remark(v: &Value) -> String {
    let dur = text_of(v, &["duration"]);
    if dur.is_empty() || dur == "0" {
        String::new()
    } else {
        dur
    }
}

/// 视频卡片：id 编成 “版块:videoId”，详情靠它拆回两个参数。
fn video_item(plate_id: i64, v: &Value) -> Option<Value> {
    let vid = text_of(v, &["videoId"]);
    if vid.is_empty() {
        return None;
    }
    let title = video_title(v);
    if title.is_empty() {
        return None;
    }
    let cover = text_of(v, &["videoCover"]);
    if cover.is_empty() {
        return None;
    }
    Some(item_json(
        &format!("{plate_id}:{vid}"),
        &title,
        &cover,
        &video_remark(v),
    ))
}

fn parse_video_list(plate_id: i64, data: &Value) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    if let Some(list) = get(data, "videoList").and_then(arr_of) {
        for v in list {
            if let Some(item) = video_item(plate_id, v) {
                let id = item["id"].as_str().unwrap_or_default().to_string();
                if seen.insert(id) {
                    items.push(item);
                }
            }
        }
    }
    items
}

fn fallback_categories() -> Value {
    json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    match api_json("sp/getTabList", &[]).await {
        Ok(data) => {
            let mut list = Vec::new();
            if let Some(plates) = get(&data, "plateList").and_then(arr_of) {
                for p in plates {
                    if int_of(p, &["plateType"]) != 1 {
                        continue;
                    }
                    let id = int_of(p, &["plateId"]);
                    if !PLATES.contains(&id) {
                        continue;
                    }
                    let name = text_of(p, &["plateName"]);
                    if name.is_empty() {
                        continue;
                    }
                    list.push(category_json(&id.to_string(), &name));
                }
            }
            if list.is_empty() {
                Ok(fallback_categories())
            } else {
                Ok(json!({"categories": list}))
            }
        }
        Err(_) => Ok(fallback_categories()),
    }
}

/// 版块首个标签 id：两成人版块各仅一个标签“每日更新”。
async fn first_label_id(plate_id: i64) -> ApiResult<i64> {
    let data = api_json(
        "sp/getPlateLabelList",
        &[("plateId", &plate_id.to_string())],
    )
    .await?;
    let labels = get(&data, "plateCenter")
        .and_then(|c| get(c, "plateLabelList"))
        .and_then(arr_of);
    match labels {
        Some(list) if !list.is_empty() => Ok(int_of(&list[0], &["exploreLabelId"])),
        _ => Err(ApiError::Internal(format!(
            "XLook 版块 {plate_id} 无可用标签"
        ))),
    }
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let plate_id: i64 = category_id
        .parse()
        .map_err(|_| ApiError::Internal("XLook 分类 id 非法".into()))?;
    if !PLATES.contains(&plate_id) {
        return Err(ApiError::Internal("XLook 分类未收录".into()));
    }
    let label_id = first_label_id(plate_id).await?;
    let data = api_json(
        "sp/getLabelVideoList",
        &[
            ("plateId", &plate_id.to_string()),
            ("labelId", &label_id.to_string()),
            ("page", &page.to_string()),
            ("size", "25"),
        ],
    )
    .await?;
    let items = parse_video_list(plate_id, &data);
    let total = int_of(&data, &["total"]);
    let has_more = if total > 0 {
        page * 25 < total
    } else {
        items.len() >= 25
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let (plate_s, video_id) = series_id
        .split_once(':')
        .ok_or_else(|| ApiError::Internal("XLook 详情 id 非法".into()))?;
    let plate_id: i64 = plate_s
        .parse()
        .map_err(|_| ApiError::Internal("XLook 详情 id 非法".into()))?;
    let data = api_json(
        "sp/getVideoDetail",
        &[("plateId", &plate_id.to_string()), ("videoId", video_id)],
    )
    .await?;
    let v =
        get(&data, "videoDetail").ok_or_else(|| ApiError::Internal("XLook 未返回详情".into()))?;
    let title = video_title(v);
    let cover = text_of(v, &["videoCover"]);
    let synopsis = text_of(v, &["videoDes"]);
    let mut url = text_of(v, &["videoUrlOne"]);
    if url.is_empty() {
        url = text_of(v, &["videoUrlTwo"]);
    }
    if title.is_empty() || url.is_empty() {
        return Err(ApiError::Internal("XLook 该片无可播地址".into()));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(&url, "播放", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("XLook 该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let mut items: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for plate_id in PLATES {
        let data = match api_json(
            "sp/getSearchList",
            &[
                ("plateId", &plate_id.to_string()),
                ("searchName", query),
                ("page", "1"),
                ("size", "25"),
            ],
        )
        .await
        {
            Ok(d) => d,
            Err(_) => continue,
        };
        for item in parse_video_list(*plate_id, &data) {
            let id = item["id"].as_str().unwrap_or_default().to_string();
            if seen.insert(id) {
                items.push(item);
            }
        }
    }
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 实测密文：sp/getPlateList 的 returnData（2026-11-05），明文
    /// 为 {"plateList":[{"id":1,"plateName":"铁粉空间|抖音"}, ...]}。
    const PLATE_CT: &str = "/+ogzBvOSnSiJGbC7Ow6APnx84KKV2Hxky0HjKO8HxznBZyYvbyEqc6vnZJU4KiGgSBNJsaQu9GxW4ok1YeAnRIdX/Kj3LXrMkGe2xUwK+E/er084uhRexpCeWYOzkIdUJbCFWlnFLm1wd2zsbfy/j+i5RgMjAnH3H4cr+aJoEsVKfKSwgDKy0YMcnRzf1a993FS4VX28rlMeDwfWEj2KFB+FNtA5KjjExIX8awha3R3a3Jg5orcj+XwIOHWiPJ5/lxbyRm1IbmqOja6eYuQtGpb8qNfrC/OGn4j5o/QpUbGhWCF4IahgGcRRIKhFjPy73kj2nkQXHXMcPuHCwOrpLCXik6R8Qf0+sYVaA0TY5Y=";

    #[test]
    fn decrypt_known_plate_list() {
        let plain = aes_decrypt(PLATE_CT).unwrap();
        assert!(plain.contains("\"plateList\""));
        assert!(plain.contains("铁粉空间|抖音"));
        assert!(plain.contains("微密圈"));
    }

    #[test]
    fn sign_is_upper_hex32() {
        let s = sign(
            "1793880000000",
            "11111111-2222-4333-8444-555555555555",
            "ABCDEFGHJKMNPQRS",
        );
        assert_eq!(s.len(), 32);
        assert!(s.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(s, s.to_uppercase());
        assert_eq!(
            sign(
                "1793880000000",
                "11111111-2222-4333-8444-555555555555",
                "ABCDEFGHJKMNPQRS"
            ),
            s
        );
    }

    #[test]
    fn guid_and_nonce_shape() {
        let g = new_uuid();
        assert_eq!(g.len(), 36);
        assert_eq!(&g[8..9], "-");
        assert_eq!(&g[14..15], "4");
        let n = new_nonce();
        assert_eq!(n.len(), 16);
        assert!(n.bytes().all(|b| NONCE_ALPHABET.contains(&b)));
    }

    #[test]
    fn first_label_from_sample() {
        let data = json!({"plateCenter": {"plateLabelList": [
            {"exploreLabelId": 36, "exploreLabel": "每日更新"},
        ]}});
        let labels = get(&data, "plateCenter")
            .and_then(|c| get(c, "plateLabelList"))
            .and_then(arr_of)
            .unwrap();
        assert_eq!(int_of(&labels[0], &["exploreLabelId"]), 36);
    }

    #[test]
    fn video_item_falls_back_to_nickname() {
        let v = json!({
            "videoId": "2081851742661358963",
            "videoTitle": "",
            "nickName": "bslVXBUvBMbFssw",
            "userName": "bslVXBUvBMbFssw",
            "videoCover": "https://7pmgbs.jehih2z.xyz/media/HJ5JMc_bAAAeD72.jpg",
            "videoUrlOne": "https://video.twimg.com/amplify_video/2060560367630127110/vid/avc1/1920x1080/-fxmNXgEBHCJiMKX.mp4",
            "duration": "0",
        });
        let item = video_item(19, &v).unwrap();
        assert_eq!(item["id"], "19:2081851742661358963");
        assert_eq!(item["title"], "bslVXBUvBMbFssw");
        assert_eq!(item["remark"], "");
    }

    #[test]
    fn video_item_keeps_real_title() {
        let v = json!({
            "videoId": "lwmZ5-nOd5AdVM-GO1x3t",
            "videoTitle": "妮迪·马哈万 《Shaadi Vivah》",
            "nickName": "aznude Nidhi Mahawan",
            "userName": "aznude-nidhimahawan",
            "videoCover": "https://cdn2.aznude.com/x.jpg",
            "videoUrlOne": "https://cdn2.aznude.com/x.mp4",
            "duration": "04:19",
        });
        let item = video_item(22, &v).unwrap();
        assert_eq!(item["id"], "22:lwmZ5-nOd5AdVM-GO1x3t");
        assert_eq!(item["title"], "妮迪·马哈万 《Shaadi Vivah》");
        assert_eq!(item["remark"], "04:19");
    }

    #[test]
    fn fallback_has_two_categories() {
        let value = fallback_categories();
        let list = value["categories"].as_array().unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "19");
        assert_eq!(list[0]["name"], "成人天堂");
        assert_eq!(list[1]["id"], "22");
        assert_eq!(list[1]["name"], "成人视频");
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://video.twimg.com/x.mp4").unwrap();
        assert_eq!(ok["url"], "https://video.twimg.com/x.mp4");
        assert!(play_check("19:2081851742661358963").is_err());
    }
}
