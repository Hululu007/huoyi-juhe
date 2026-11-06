//! K站：API 站（kfzedwc.com:2087），响应为 RSA+AES 加密信封：
//! key 经 RSA 私钥指数解密（PKCS#1 v1.5 去填充），反转后前
//! 16 字为 IV，data 经 AES/CBC 解密得内层 JSON。分类走
//! /v1/vod/category，列表走 /v1/vod，详情走 /v1/vod/<id>；
//! 取流每次现取 fresh m3u8（清单签名 1 小时一换）；封面
//! enc_img 返回原地址（jar 的中继会对图片字节做 XOR -120
//! 解混淆，核心不包本地代理，待手机侧验证）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use num_bigint::BigUint;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const HOST: &str = "https://www.kfzedwc.com:2087";
const BRANCH: &str = "t1";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_LIMIT: i64 = 30;
const CACHE_TTL: Duration = Duration::from_secs(180);

/// RSA 模数与私钥指数（512 位，jar 原文）。
const N_HEX: &str = "d04f4db2ecfa8d817e25e2ea29a2f52e46728345a5e313c8c04ce50eb3b850e318197d561be9ea7fda2fa699604e180b732a11335605b211853ab900887119ab";
const D_HEX: &str = "1bc47677035fe2bd0033ccabaa212ecd9c5667694153a3af7ef2c115d49f1d28eac923337620e39bb0de5a686eb91c91ea74371aab20d792b2b636f61037641";

const FALLBACK_CATS: &[(&str, &str)] = &[
    ("1", "国产"),
    ("3", "日韩"),
    ("2", "传媒"),
    ("4", "欧美"),
    ("5", "动漫"),
];

static RESP_CACHE: Mutex<Vec<(String, String, Instant)>> = Mutex::new(Vec::new());

fn cache_get(url: &str) -> Option<String> {
    if let Ok(guard) = RESP_CACHE.lock() {
        for (u, body, at) in guard.iter() {
            if u == url && Instant::now() < *at + CACHE_TTL {
                return Some(body.clone());
            }
        }
    }
    None
}

fn cache_put(url: &str, body: &str) {
    if let Ok(mut guard) = RESP_CACHE.lock() {
        guard.retain(|(u, _, _)| u != url);
        guard.push((url.to_string(), body.to_string(), Instant::now()));
    }
}

/// RSA 私钥解密 + PKCS#1 v1.5 去填充。
fn rsa_dec(data: &[u8]) -> Option<Vec<u8>> {
    let n = BigUint::parse_bytes(N_HEX.as_bytes(), 16)?;
    let d = BigUint::parse_bytes(D_HEX.as_bytes(), 16)?;
    let c = BigUint::from_bytes_be(data);
    let m = c.modpow(&d, &n);
    let mut fixed = m.to_bytes_be();
    if fixed.len() < 64 {
        let mut padded = vec![0u8; 64 - fixed.len()];
        padded.append(&mut fixed);
        fixed = padded;
    } else if fixed.len() > 64 {
        fixed = fixed[fixed.len() - 64..].to_vec();
    }
    if fixed[0] != 0 || fixed[1] != 2 {
        return None;
    }
    let mut i = 2;
    while i < fixed.len() && fixed[i] != 0 {
        i += 1;
    }
    if i >= fixed.len() - 1 {
        return None;
    }
    Some(fixed[i + 1..].to_vec())
}

fn aes_cbc_decrypt(data: &[u8], key: &[u8], iv: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if iv.len() < 16 || data.len() % 16 != 0 {
        return None;
    }
    fn run<C>(data: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8>
    where
        C: BlockDecrypt + KeyInit,
    {
        use aes::cipher::generic_array::GenericArray;
        let cipher = C::new(GenericArray::from_slice(key));
        let mut out = Vec::with_capacity(data.len());
        let mut prev = iv[..16].to_vec();
        for chunk in data.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.decrypt_block(&mut block);
            for i in 0..16 {
                out.push(block[i] ^ prev[i]);
            }
            prev = chunk.to_vec();
        }
        out
    }
    let out = match key.len() {
        16 => run::<aes::Aes128>(data, &key[..16], iv),
        24 => run::<aes::Aes192>(data, &key[..24], iv),
        32 => run::<aes::Aes256>(data, &key[..32], iv),
        _ => return None,
    };
    if out.is_empty() {
        return Some(out);
    }
    let mut out = out;
    let pad = out[out.len() - 1] as usize;
    if (1..=16).contains(&pad)
        && pad <= out.len()
        && out[out.len() - pad..].iter().all(|&b| b as usize == pad)
    {
        out.truncate(out.len() - pad);
    }
    Some(out)
}

/// 解信封：无 data/key 时返回外层 JSON 原样。
fn unwrap(text: &str) -> ApiResult<Value> {
    let outer: Value = serde_json::from_str(text.trim())?;
    let data_b64 = text_of(&outer, &["data"]);
    let key_b64 = text_of(&outer, &["key"]);
    if data_b64.is_empty() || key_b64.is_empty() {
        return Ok(outer);
    }
    let key_ct = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &key_b64)
        .map_err(|_| ApiError::Internal("K站 key base64 解码失败".into()))?;
    let key_plain =
        rsa_dec(&key_ct).ok_or_else(|| ApiError::Internal("K站 RSA 解 key 失败".into()))?;
    let key_str =
        String::from_utf8(key_plain).map_err(|_| ApiError::Internal("K站 key 不是文本".into()))?;
    let reversed: String = key_str.chars().rev().collect();
    if reversed.len() < 16 {
        return Err(ApiError::Internal("K站 key 反转后不足 16 字".into()));
    }
    let iv = reversed[..16].as_bytes().to_vec();
    let data_ct = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &data_b64)
        .map_err(|_| ApiError::Internal("K站 data base64 解码失败".into()))?;
    let plain = aes_cbc_decrypt(&data_ct, key_str.as_bytes(), &iv)
        .ok_or_else(|| ApiError::Internal("K站 AES 解 data 失败".into()))?;
    let inner =
        String::from_utf8(plain).map_err(|_| ApiError::Internal("K站内层不是文本".into()))?;
    let inner: Value = serde_json::from_str(inner.trim())?;
    Ok(inner)
}

fn headers() -> Vec<(&'static str, String)> {
    vec![
        ("User-Agent", UA.to_string()),
        ("Accept", "application/json, text/plain, */*".to_string()),
        ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
        ("X-Requested-With", "XMLHttpRequest".to_string()),
        ("Referer", format!("{HOST}/")),
    ]
}

async fn get_text(url: &str) -> ApiResult<String> {
    if let Some(cached) = cache_get(url) {
        return Ok(cached);
    }
    let mut last_err = ApiError::Internal("K站请求失败".into());
    for attempt in 0..2 {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_millis(700)).await;
        }
        let mut req = client()?.get(url);
        for (k, v) in headers() {
            req = req.header(k, v);
        }
        match req.send().await {
            Ok(resp) => {
                let status = resp.status().as_u16();
                if status != 200 {
                    last_err = ApiError::Internal(format!("K站请求 HTTP {status}"));
                    continue;
                }
                match resp.text().await {
                    Ok(t) if !t.is_empty() => {
                        cache_put(url, &t);
                        return Ok(t);
                    }
                    Ok(_) => continue,
                    Err(e) => last_err = ApiError::Internal(e.to_string()),
                }
            }
            Err(e) => last_err = ApiError::Internal(e.to_string()),
        }
    }
    Err(last_err)
}

async fn api(path: &str, query: &str) -> ApiResult<Value> {
    let url = if query.is_empty() {
        format!("{HOST}/v1{path}")
    } else {
        format!("{HOST}/v1{path}?{query}")
    };
    let text = get_text(&url).await?;
    unwrap(&text)
}

fn data_of(body: &Value) -> Value {
    match get(body, "data") {
        Some(d) => d.clone(),
        None => body.clone(),
    }
}

fn human(n: i64) -> String {
    if n >= 100_000_000 {
        format!("{}.{}亿", n / 10_000_000, (n % 10_000_000) / 1_000_000)
    } else if n >= 10_000 {
        format!("{}.{}万", n / 1000, (n % 1000) / 100)
    } else {
        n.to_string()
    }
}

fn cards(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let id = int_of(e, &["id"]);
        if id <= 0 {
            continue;
        }
        let name = text_of(e, &["name"]).trim().to_string();
        let cover = text_of(e, &["enc_img"]);
        let time = text_of(e, &["time"]).trim().to_string();
        let eye = int_of(e, &["eye"]);
        let mut remark = time;
        if eye > 0 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str(&format!("{}次", human(eye)));
        }
        if remark.is_empty() {
            remark = text_of(e, &["create_time"]);
        }
        items.push(item_json(&id.to_string(), &name, &cover, &remark));
    }
    items
}

async fn fetch_video(id: &str) -> Option<Value> {
    let id = id.strip_prefix('v').unwrap_or(id);
    let body = api(&format!("/vod/{id}"), &format!("c={BRANCH}"))
        .await
        .ok()?;
    let data = data_of(&body);
    match get(&data, "video") {
        Some(v) if v.is_object() => Some(v.clone()),
        _ => None,
    }
}

async fn home_list() -> Vec<Value> {
    if let Ok(body) = api("/relist", &format!("c={BRANCH}")).await {
        let data = data_of(&body);
        for key in ["recommend_videos", "rank_videos"] {
            if let Some(obj) = get(&data, key) {
                let rows = get(obj, "videos")
                    .and_then(arr_of)
                    .cloned()
                    .or_else(|| get(obj, "list").and_then(arr_of).cloned())
                    .or_else(|| arr_of(obj).cloned())
                    .unwrap_or_default();
                if !rows.is_empty() {
                    return cards(&rows);
                }
            }
        }
    }
    if let Ok(body) = api(
        "/vod",
        &format!("c={BRANCH}&cate_id=1&page=1&limit={PAGE_LIMIT}"),
    )
    .await
    {
        let data = data_of(&body);
        let rows = get(&data, "videos")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        return cards(&rows);
    }
    Vec::new()
}

fn cate_of(category_id: &str) -> i64 {
    let s = category_id
        .strip_prefix('c')
        .or_else(|| category_id.strip_prefix('s'))
        .unwrap_or(category_id);
    s.parse::<i64>().unwrap_or(1).max(1)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = Vec::new();
    if let Ok(body) = api("/vod/category", &format!("c={BRANCH}")).await {
        let data = data_of(&body);
        if let Some(cates) = get(&data, "cates").and_then(arr_of) {
            for c in cates {
                let id = int_of(c, &["id"]);
                let name = text_of(c, &["name"]).trim().to_string();
                if id <= 0 || name.is_empty() {
                    continue;
                }
                list.push(category_json(&format!("c{id}"), &name));
                if let Some(subs) = get(c, "sub_cates").and_then(arr_of) {
                    for s in subs {
                        let sid = int_of(s, &["id"]);
                        let sname = text_of(s, &["name"]).trim().to_string();
                        if sid <= 0 || sname.is_empty() {
                            continue;
                        }
                        list.push(category_json(
                            &format!("s{sid}"),
                            &format!("{name}·{sname}"),
                        ));
                    }
                }
            }
        }
    }
    if list.is_empty() {
        for (id, name) in FALLBACK_CATS {
            list.push(category_json(&format!("c{id}"), name));
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page_s = page.to_string();
    let query = with_query(
        "",
        &[
            ("c", BRANCH),
            ("cate_id", &cate_of(category_id).to_string()),
            ("page", &page_s),
            ("limit", &PAGE_LIMIT.to_string()),
        ],
    );
    let query = query.trim_start_matches('?').to_string();
    let body = api("/vod", &query).await?;
    let data = data_of(&body);
    let rows = get(&data, "videos")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let items = cards(&rows);
    let current = int_of(&data, &["current_page"]);
    let last = int_of(&data, &["last_page"]);
    let cur = if current > 0 { current } else { page };
    let last = if last > 0 { last } else { page };
    Ok(json!({"items": items, "has_more": cur < last}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let id = series_id.strip_prefix('v').unwrap_or(series_id);
    let body = api(&format!("/vod/{id}"), &format!("c={BRANCH}")).await?;
    let data = data_of(&body);
    let video = match get(&data, "video") {
        Some(v) if v.is_object() => v.clone(),
        _ => return Err(ApiError::Internal("K站未返回影片资料".into())),
    };
    let name = text_of(&video, &["name"]).trim().to_string();
    let name = if name.is_empty() {
        "K站".to_string()
    } else {
        name
    };
    let url = text_of(&video, &["url"]).trim().to_string();
    let cover = text_of(&video, &["enc_img"]).trim().to_string();
    let cate = get(&video, "cate")
        .map(|c| text_of(c, &["name"]))
        .unwrap_or_default();
    let mut tags = Vec::new();
    if let Some(list) = get(&data, "hot_tags").and_then(arr_of) {
        for t in list.iter().take(12) {
            let s = super::str_of(t);
            if !s.is_empty() {
                tags.push(s);
            }
        }
    }
    let play_url = if url.is_empty() {
        format!("正片${HOST}/")
    } else {
        format!("正片$kfz:{id}")
    };
    let mut content = String::from(
"K站（kfzedwc 站群）· 免登录免费直取\nHLS / AES-128 标准加密（非 Widevine DRM）；清单签名 1 小时一换，播放时自动换新签名\n",
);
    if !cate.is_empty() {
        content.push_str(&format!("{cate}\n"));
    }
    if !tags.is_empty() {
        content.push_str(&format!("{}\n", tags.join(" / ")));
    }
    content.push_str("/v1/vod/<id>（响应为 RSA+AES 加密信封，源内已解）");
    let mut extra = serde_json::Map::new();
    if !cate.is_empty() {
        extra.insert("category".to_string(), json!(cate));
    } else {
        extra.insert("remark".to_string(), json!("免费直取"));
    }
    if !tags.is_empty() {
        extra.insert("tag".to_string(), json!(tags.join(" / ")));
    }
    Ok(json!({
    "id": id,
    "title": name,
    "cover": cover,
    "synopsis": content,
    "extra": extra,
    "episodes": [episode_json(&play_url, "正片", id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({
        "url": video_id,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
        }));
    }
    let id = video_id
        .strip_prefix("kfz:")
        .or_else(|| video_id.strip_prefix('v'))
        .unwrap_or(video_id);
    if !id.is_empty() {
        if let Some(video) = fetch_video(id).await {
            let url = text_of(&video, &["url"]).trim().to_string();
            if !url.is_empty() {
                return Ok(json!({
                "url": url,
                "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
                }));
            }
        }
    }
    Ok(json!({
    "url": format!("{HOST}/"),
    "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let query_str = format!("c={BRANCH}&name={encoded}&page=1&limit={PAGE_LIMIT}");
    let body = api("/vod", &query_str).await?;
    let data = data_of(&body);
    let rows = get(&data, "videos")
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let items = cards(&rows);
    let current = int_of(&data, &["current_page"]);
    let last = int_of(&data, &["last_page"]);
    Ok(json!({
    "items": items,
    "has_more": current > 0 && last > 0 && current < last,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_formats() {
        assert_eq!(human(150_000_000), "15.0亿");
        assert_eq!(human(25_000), "25.0万");
        assert_eq!(human(999), "999");
    }

    #[test]
    fn cate_of_prefixes() {
        assert_eq!(cate_of("c3"), 3);
        assert_eq!(cate_of("s5"), 5);
        assert_eq!(cate_of("x"), 1);
    }

    #[test]
    fn rsa_dec_roundtrip() {
        // 用公钥指数 e=65537 加密一小段，再用 jar 的 D 解回，验证
        // 去填充逻辑（N 为 512 位，消息须小于 N）。
        use num_bigint::BigUint;
        let n = BigUint::parse_bytes(N_HEX.as_bytes(), 16).unwrap();
        let e = BigUint::from(65537u32);
        let msg = b"test-key-1234567";
        let mut padded = vec![0u8, 2];
        padded.extend(std::iter::repeat(0xabu8).take(64 - msg.len() - 3));
        padded.push(0);
        padded.extend_from_slice(msg);
        let c = BigUint::from_bytes_be(&padded).modpow(&e, &n);
        let dec = rsa_dec(&c.to_bytes_be()).unwrap();
        assert_eq!(dec, msg);
    }
}
