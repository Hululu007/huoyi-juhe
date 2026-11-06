//! thePorny：核心里的影视区站点。
//!
//! Angular/Ionic SPA：首页 curl 只回 5.7KB 空壳，数据全走 JS 接口。
//! 接口 POST `https://v2.cdn199.com/js`（另有 7 个备用 host），
//! 请求体 `{app, isStandalone, theLink, uuid, url, version, deviceInfo}`
//!（app=theporny.com、version=260901、uuid 为站内自生成格式
//! `U+UTC时间+4位随机数`、theLink 为资源测速链路），响应
//! `{"r": "<base64>"}`，CryptoJS AES 解密：口令 `xxx`，Salted__
//! 格式，EVP_BytesToKey（MD5）取 32 字节密钥 + 16 字节 IV，
//! AES-256-CBC/PKCS7。
//! 列表 `/sevenVideos?page=<N>&type=<type>`（每页 24 条）；详情
//! `/sevenVideos/<id>`，体加 `url_search="?server=<线路>"`，回
//! `m3u8s[0]`（`https://tm.xiaoxx.com/<token>,<expiry>/<id>/index.m3u8`，
//! expiry 约请求时 +6800 秒，须现取现用）；搜索
//! `/searchSevenVideos`（固定过滤：全部/全部/全部/全部，按时间）。
//! 线路 default1 免费线路、default2 国内线路、hd1/hd2/hd3 高速线路，
//! 本模块取流用 hd1（高速线路1），匿名实测 5 条线路都回签名地址，
//! tvideo 与 cvideo 的清单均为全长（免费片 92 秒、cvideo 1629 秒）。
//! 分类与站内 tvideoCategories 配置 1:1（30 项），全部 p1 实测 24 条。

use aes::Aes256;
use base64::engine::{general_purpose::STANDARD, Engine};
use cbc::{
    cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit},
    Decryptor,
};
use md5::{Digest, Md5};
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, get, item_json, str_of, text_of};

const HOSTS: [&str; 8] = [
    "https://v2.cdn199.com",
    "https://v2.kekecdn.net",
    "https://v2.luchu.org",
    "https://v2.madou.ws",
    "https://v2.papapa.biz",
    "https://v2.tianmtv.com",
    "https://v2.xiaoshuo.info",
    "https://v2.xiaoshuo.la",
];
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const APP: &str = "theporny.com";
const VERSION: &str = "260901";
const THELINK: &str = "https://rs.xiaoxx.com";
const LINE: &str = "hd1";
const PAGE_SIZE: i64 = 24;

/// 分类：与站内 tvideoCategories 配置一致，实测于 2026-11-06。
const CATS: &[(&str, &str)] = &[
    ("hot", "当前最热"),
    ("recent", "最近更新"),
    ("high", "站长推荐"),
    ("hd", "会员专享视频"),
    ("recent_hot", "最近加精"),
    ("10mins", "10分钟以上"),
    ("20mins", "20分钟以上"),
    ("month_discuss", "本月讨论"),
    ("month_favs", "本月收藏"),
    ("favs", "收藏最多"),
    ("month_hot", "本月最热"),
    ("last_month_hot", "上月最热"),
    ("c0", "国产传媒全集"),
    ("c1", "麻豆视频"),
    ("c2", "91制片厂"),
    ("c3", "玩偶姐姐"),
    ("c4", "小鸟酱专题"),
    ("c5", "糖心Vlog"),
    ("c6", "天美传媒"),
    ("c7", "蜜桃传媒"),
    ("c8", "皇家华人"),
    ("c9", "星空传媒"),
    ("ca", "精东影业"),
    ("cc", "成人头条"),
    ("cd", "乌鸦传媒"),
    ("cl", "开心鬼传媒"),
    ("japan", "日本高清AV"),
    ("banana", "汝工作室"),
    ("swag", "台湾Swag全集"),
    ("torture_all", "重口系列"),
];

/// CryptoJS 口令加密的 EVP_BytesToKey（MD5，1 轮）：取 32 字节密钥 + 16 字节 IV。
fn evp_key_iv(password: &[u8], salt: &[u8]) -> (Vec<u8>, Vec<u8>) {
    let mut out: Vec<u8> = Vec::new();
    let mut prev: Vec<u8> = Vec::new();
    while out.len() < 48 {
        let mut h = Md5::new();
        h.update(&prev);
        h.update(password);
        h.update(salt);
        prev = h.finalize().to_vec();
        out.extend_from_slice(&prev);
    }
    (out[..32].to_vec(), out[32..48].to_vec())
}

/// 解密接口响应里的 r 字段：Salted__ 格式，AES-256-CBC/PKCS7，口令 xxx。
fn cryptojs_decrypt(b64: &str) -> ApiResult<String> {
    let raw = STANDARD
        .decode(b64)
        .map_err(|e| ApiError::Internal(format!("thePorny密文解码失败：{e}")))?;
    if raw.len() < 16 || &raw[..8] != b"Salted__" {
        return Err(ApiError::Internal("thePorny密文头异常".into()));
    }
    let (key, iv) = evp_key_iv(b"xxx", &raw[8..16]);
    let plain = Decryptor::<Aes256>::new_from_slices(&key, &iv)
        .map_err(|e| ApiError::Internal(format!("thePorny解密器初始化失败：{e}")))?
        .decrypt_padded_vec_mut::<Pkcs7>(&raw[16..])
        .map_err(|e| ApiError::Internal(format!("thePorny解密失败：{e}")))?;
    String::from_utf8(plain).map_err(|e| ApiError::Internal(format!("thePorny解密结果非文本：{e}")))
}

/// 站内 uuid 格式：U + UTC 时间（YYYYMMDDHHMMSS）+ 4 位随机数。
fn make_uuid() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let days = (secs / 86400) as i64;
    let tod = secs % 86400;
    let (y, m, d) = civil_from_days(days);
    let hh = tod / 3600;
    let mm = (tod % 3600) / 60;
    let ss = tod % 60;
    let rnd = 1000 + (nanos % 9000);
    format!("U{y:04}{m:02}{d:02}{hh:02}{mm:02}{ss:02}{rnd}")
}

/// Howard Hinnant 民用日期算法：自 epoch 起的天数转年月日。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

async fn post_once(host: &str, url_path: &str, extra: &Value) -> ApiResult<Value> {
    let mut body = json!({
        "app": APP,
        "isStandalone": false,
        "theLink": THELINK,
        "uuid": make_uuid(),
        "url": url_path,
        "version": VERSION,
        "deviceInfo": {},
    });
    if let Some(m) = extra.as_object() {
        for (k, v) in m {
            body[k] = v.clone();
        }
    }
    let resp = client()?
        .post(format!("{host}/js"))
        .header("User-Agent", UA)
        .header("Content-Type", "application/json")
        .header("Authorization", "Bearer undefined")
        .header("Referer", "https://theporny.com/")
        .header("Origin", "https://theporny.com")
        .json(&body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("thePorny请求 HTTP {status}")));
    }
    let raw: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let r = text_of(&raw, &["r"]);
    if r.is_empty() {
        return Ok(raw);
    }
    let plain = cryptojs_decrypt(&r)?;
    serde_json::from_str(&plain)
        .map_err(|e| ApiError::Internal(format!("thePorny内层 JSON 解析失败：{e}")))
}

/// 调 /js 接口：按序换 host 重试。
async fn js_call(url_path: &str, extra: &Value) -> ApiResult<Value> {
    let mut last_err = String::new();
    for host in HOSTS {
        match post_once(host, url_path, extra).await {
            Ok(v) => return Ok(v),
            Err(e) => last_err = e.to_string(),
        }
    }
    Err(ApiError::Internal(last_err))
}

fn cover_of(v: &Value) -> String {
    match get(v, "thumbnails") {
        Some(t) => match t.as_array().and_then(|a| a.first()) {
            Some(c) => str_of(c).trim().to_string(),
            None => String::new(),
        },
        None => String::new(),
    }
}

fn parse_items(data: &Value) -> Vec<Value> {
    let mut items = Vec::new();
    let arr = match data.as_array() {
        Some(a) => a,
        None => return items,
    };
    for v in arr {
        let id = text_of(v, &["id", "vId"]);
        let title = text_of(v, &["title"]);
        if id.is_empty() || title.is_empty() {
            continue;
        }
        let remark = text_of(v, &["durationStr"]);
        items.push(item_json(&id, &title, &cover_of(v), &remark));
    }
    items
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({
        "categories": CATS
            .iter()
            .map(|(id, name)| category_json(id, name))
            .collect::<Vec<Value>>(),
    }))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let data = js_call(
        &format!("/sevenVideos?page={page}&type={category_id}"),
        &json!({}),
    )
    .await?;
    let items = parse_items(&data);
    let has_more = items.len() as i64 >= PAGE_SIZE;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.trim();
    let data = js_call(
        &format!("/sevenVideos/{id}"),
        &json!({"url_search": format!("?server={LINE}")}),
    )
    .await?;
    let title = text_of(&data, &["title"]);
    let m3u8 = match get(&data, "m3u8s") {
        Some(m) => match m.as_array().and_then(|a| a.first()) {
            Some(u) => u.as_str().unwrap_or("").to_string(),
            None => String::new(),
        },
        None => String::new(),
    };
    if title.is_empty() || m3u8.is_empty() {
        return Err(ApiError::Internal("thePorny未返回可播放地址".into()));
    }
    let cover = cover_of(&data);
    let keywords = text_of(&data, &["keywords_gem"]);
    let tags = text_of(&data, &["tags"]);
    let user = text_of(&data, &["user"]);
    let synopsis = format!("{keywords}\n{tags}\n作者：{user}").trim().to_string();
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "episodes": [episode_json(&m3u8, "高速线路1", series_id)],
    }))
}

fn play_check(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        Ok(json!({"url": video_id}))
    } else {
        Err(ApiError::Internal("thePorny该集没有播放地址".into()))
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    play_check(video_id)
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let data = js_call(
        "/searchSevenVideos",
        &json!({
            "page": 1,
            "keywords": query,
            "filterCategory": "all",
            "filterTimeInDays": "all",
            "filterViews": "all",
            "filterDurationInMins": "all",
            "sortBy": "time",
            "keywordLogic": "or",
        }),
    )
    .await?;
    let items = parse_items(&data);
    Ok(json!({"items": items}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypt_va_response() {
        let plain = cryptojs_decrypt("U2FsdGVkX1/uBO1QSHdgYVV8GLkco37RjRDTNzsMsSA=").unwrap();
        assert_eq!(plain, "{\"value\":\"s\"}");
    }

    #[test]
    fn decrypt_bad_header_errors() {
        assert!(cryptojs_decrypt("aGVsbG8=").is_err());
    }

    #[test]
    fn uuid_format() {
        let u = make_uuid();
        assert!(u.starts_with('U'));
        assert_eq!(u.len(), 19);
        assert!(u[1..].chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn civil_from_days_epoch() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20376), (2025, 10, 15));
    }

    #[test]
    fn parse_list_real_sample() {
        let data: Value = serde_json::from_str(
            r#"[{"id":"TjNSpcDZL","vId":"TjNSpcDZL","title":"178极品空姐休假期间","durationStr":"10:45","thumbnails":["https://tp.xiaoxx.com/TjNSpcDZL.jpg"],"videoType":"tvideo","vip":false},{"id":"sPfhOMMDy","title":"高壮健身少妇想要释放的性欲","durationStr":"05:40","thumbnails":["https://tp.xiaoxx.com/sPfhOMMDy.jpg"],"videoType":"tvideo","vip":false}]"#,
        )
        .unwrap();
        let items = parse_items(&data);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["id"], "TjNSpcDZL");
        assert_eq!(items[0]["cover"], "https://tp.xiaoxx.com/TjNSpcDZL.jpg");
        assert_eq!(items[0]["remark"], "10:45");
    }

    #[test]
    fn categories_has_30() {
        assert_eq!(CATS.len(), 30);
        assert_eq!(CATS[0], ("hot", "当前最热"));
        assert_eq!(CATS[3], ("hd", "会员专享视频"));
        assert_eq!(CATS[29], ("torture_all", "重口系列"));
    }

    #[test]
    fn play_passthrough() {
        let ok = play_check("https://tm.xiaoxx.com/abc,1793902401/x/index.m3u8").unwrap();
        assert_eq!(
            ok["url"],
            "https://tm.xiaoxx.com/abc,1793902401/x/index.m3u8"
        );
        assert!(play_check("zEbhgmHgI").is_err());
    }

    #[test]
    fn detail_m3u8_extract() {
        let data: Value = serde_json::from_str(
            r#"{"id":"zEbhgmHgI","title":"安徽淮南调教眼镜妹","m3u8s":["https://tm.xiaoxx.com/S53lm_RKUGil9ux1amRv9Q==,1793902401/6ae7000afaf50f3f74b68a8b/index.m3u8"],"thumbnails":["https://tp.xiaoxx.com/zEbhgmHgI.jpg"],"keywords_gem":"调教, 眼镜妹","tags":"13 小时前 | 20951次播放","user":"安徽淮南哥"}"#,
        )
        .unwrap();
        let m3u8 = match get(&data, "m3u8s") {
            Some(m) => match m.as_array().and_then(|a| a.first()) {
                Some(u) => u.as_str().unwrap_or("").to_string(),
                None => String::new(),
            },
            None => String::new(),
        };
        assert!(m3u8.starts_with("https://tm.xiaoxx.com/"));
        assert!(m3u8.ends_with("/index.m3u8"));
    }
}
