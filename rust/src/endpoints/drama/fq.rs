//! 番茄视频：API 站（sm-api.wieuc.com），响应带 x-data 时为
//! Fernet 密文（FKEY 前 16 字节签名、后 16 字节 AES 加密，
//! token = 0x80 + 时间戳 + IV + 密文 + HMAC-SHA256）。
//! 分类走 /api/vod/tag_group，列表走 /api/vod/video，详情走
//! /api/vod/video/<id>，三条线路拼 LINE_HOST。

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const API: &str = "sm-api.wieuc.com";
const IMG: &str = "hm-img.hdstfb.com";
const SITE_ID: i64 = 107;
const PER: i64 = 24;
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
/// ZakaFqAmns 自有 s(1) 解出的 Fernet key（base64）。
const FKEY_B64: &str = "NyGRG56A8i5J2JMqh7da83r2MMfgbM7Ppw1aCF8YnAY=";
const LINE_HOSTS: &[&str] = &[
    "hm-vip.hdstfb.com",
    "hm-img.hdstfb.com",
    "hm-img.aa66cc.live",
];
const LINE_NAMES: &[&str] = &["线路1", "线路2", "海外专线"];

fn fernet_key() -> Option<([u8; 16], [u8; 16])> {
    let raw = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, FKEY_B64).ok()?;
    if raw.len() != 32 {
        return None;
    }
    let mut signing = [0u8; 16];
    let mut encryption = [0u8; 16];
    signing.copy_from_slice(&raw[..16]);
    encryption.copy_from_slice(&raw[16..]);
    Some((signing, encryption))
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut k_ipad = [0x36u8; BLOCK];
    let mut k_opad = [0x5cu8; BLOCK];
    for i in 0..key.len().min(BLOCK) {
        k_ipad[i] ^= key[i];
        k_opad[i] ^= key[i];
    }
    let mut inner = Sha256::new();
    inner.update(k_ipad);
    inner.update(msg);
    let inner_hash = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(k_opad);
    outer.update(inner_hash);
    let out = outer.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

/// Fernet 解包：验签后 AES-128-CBC 解密，得内层 JSON 文本。
fn fernet_decrypt(token: &str) -> Option<String> {
    let (signing, encryption) = fernet_key()?;
    let raw =
        base64::Engine::decode(&base64::engine::general_purpose::URL_SAFE, token.trim()).ok()?;
    if raw.len() < 57 || raw[0] != 0x80 {
        return None;
    }
    let (body, tag) = raw.split_at(raw.len() - 32);
    if !ct_eq(&hmac_sha256(&signing, body), tag) {
        return None;
    }
    let iv = &body[9..25];
    let cipher_text = &body[25..];
    if cipher_text.len() % 16 != 0 {
        return None;
    }
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    let cipher = aes::Aes128::new(GenericArray::from_slice(&encryption));
    let mut out = Vec::with_capacity(cipher_text.len());
    let mut prev = iv.to_vec();
    for chunk in cipher_text.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        for i in 0..16 {
            out.push(block[i] ^ prev[i]);
        }
        prev = chunk.to_vec();
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
    String::from_utf8(out).ok()
}

async fn api_json(path: &str) -> ApiResult<Value> {
    let url = format!("https://{API}{path}");
    let req = client()?
        .get(&url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Origin", format!("https://{API}/"))
        .header("Referer", format!("https://{API}/"));
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("番茄视频请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let body: Value = serde_json::from_str(&text)?;
    let xdata = text_of(&body, &["x-data"]);
    if !xdata.is_empty() {
        let inner = fernet_decrypt(&xdata)
            .ok_or_else(|| ApiError::Internal("番茄视频 x-data 解不开".into()))?;
        let inner: Value = serde_json::from_str(&inner)?;
        return Ok(inner);
    }
    Ok(body)
}

fn data_of(body: &Value) -> Value {
    match get(body, "data") {
        Some(d) => d.clone(),
        None => body.clone(),
    }
}

fn abs_url(host: &str, path: &str) -> String {
    if path.starts_with("http") {
        path.to_string()
    } else if path.starts_with('/') {
        format!("https://{host}{path}")
    } else {
        format!("https://{host}/{path}")
    }
}

fn mmss(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m:02}:{s:02}")
    }
}

fn cards(list: &[Value]) -> Vec<Value> {
    let mut items = Vec::new();
    for e in list {
        let id = text_of(e, &["id"]);
        let name = text_of(e, &["name", "title"]);
        if id.is_empty() || name.is_empty() {
            continue;
        }
        let pic = text_of(e, &["pic", "pic_thumb"]);
        let dur = int_of(e, &["duration"]);
        let paid = int_of(e, &["is_paid"]);
        let mut remark = mmss(dur);
        if let Some(tags) = get(e, "tags").and_then(arr_of) {
            for t in tags.iter().take(2) {
                let n = text_of(t, &["name"]);
                if !n.is_empty() {
                    if !remark.is_empty() {
                        remark.push_str(" · ");
                    }
                    remark.push_str(&n);
                }
            }
        }
        if paid == 1 {
            if !remark.is_empty() {
                remark.push_str(" · ");
            }
            remark.push_str("💎会员");
        }
        items.push(item_json(&id, &name, &abs_url(IMG, &pic), &remark));
    }
    items
}

/// 取 tag_group，返回 (组 id, 组名, tag id 串) 列表。
async fn tag_groups() -> ApiResult<Vec<(String, String, String)>> {
    let body = api_json(&format!("/api/vod/tag_group?site_id={SITE_ID}")).await?;
    let data = data_of(&body);
    let groups = get(&data, "items")
        .and_then(arr_of)
        .cloned()
        .or_else(|| arr_of(&data).cloned())
        .unwrap_or_default();
    let mut out = Vec::new();
    for g in groups {
        if int_of(&g, &["purpose"]) != 8 {
            continue;
        }
        let tag_type = int_of(&g, &["tag_type"]);
        if tag_type != 2 && tag_type != 3 {
            continue;
        }
        let gid = text_of(&g, &["id"]);
        let name = text_of(&g, &["name"]);
        let mut tags: Vec<String> = Vec::new();
        if let Some(list) = get(&g, "tags").and_then(arr_of) {
            for t in list {
                let tid = text_of(t, &["id"]);
                if !tid.is_empty() {
                    tags.push(tid);
                }
            }
        }
        if !gid.is_empty() && !name.is_empty() {
            out.push((gid, name, tags.join(",")));
        }
    }
    Ok(out)
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("new", "最新更新"),
        category_json("hot", "热门排行"),
    ];
    if let Ok(groups) = tag_groups().await {
        for (gid, name, _) in groups {
            list.push(category_json(&format!("g{gid}"), &name));
        }
    }
    Ok(json!({"categories": list}))
}

async fn list_path(category_id: &str, page: i64) -> ApiResult<String> {
    let page_s = page.to_string();
    let per_s = PER.to_string();
    let site_s = SITE_ID.to_string();
    Ok(match category_id {
        "hot" => format!("/api/vod/video/top/hits?site_id={site_s}"),
        "new" => with_query(
            "/api/vod/video",
            &[
                ("page", &page_s),
                ("per_page", &per_s),
                ("site_id", &site_s),
            ],
        ),
        _ => {
            let gid = category_id.strip_prefix('g').unwrap_or(category_id);
            let groups = tag_groups().await?;
            let tag = groups
                .iter()
                .find(|(id, _, _)| id == gid)
                .map(|(_, _, t)| t.clone())
                .unwrap_or_default();
            let mut url = with_query(
                "/api/vod/video",
                &[
                    ("page", &page_s),
                    ("per_page", &per_s),
                    ("site_id", &site_s),
                ],
            );
            if !tag.is_empty() {
                url.push_str(&format!("&tag={}", tag.replace(',', "%2C")));
            }
            url
        }
    })
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let path = list_path(category_id, page).await?;
    let body = api_json(&path).await?;
    let data = data_of(&body);
    // 修：live 列表行在 "items" 下，jar 假定的 "list" 键不存在，
    // 旧写法恒返回空列表；先取 items，再退 "list"、数组本身。
    let rows = get(&data, "items")
        .and_then(arr_of)
        .cloned()
        .or_else(|| get(&data, "list").and_then(arr_of).cloned())
        .or_else(|| arr_of(&data).cloned())
        .unwrap_or_default();
    let items = cards(&rows);
    let total = int_of(&data, &["total"]);
    let pages = int_of(&data, &["pages"]);
    let has_more = if pages > 0 {
        page < pages
    } else {
        total > page * PER
    };
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let body = api_json(&format!("/api/vod/video/{series_id}?site_id={SITE_ID}")).await?;
    let data = data_of(&body);
    let name = text_of(&data, &["name", "title"]);
    if name.is_empty() {
        return Err(ApiError::Internal("番茄视频未返回影片资料".into()));
    }
    let pic = text_of(&data, &["pic", "pic_thumb"]);
    let play_url = text_of(&data, &["play_url"]);
    let desc = text_of(&data, &["description"]);
    let pubdate = text_of(&data, &["pubdate"]);
    let year = pubdate.get(..4).unwrap_or("").to_string();
    let dur = int_of(&data, &["duration"]);
    let mut tags = Vec::new();
    if let Some(list) = get(&data, "tags").and_then(arr_of) {
        for t in list {
            let n = text_of(t, &["name"]);
            if !n.is_empty() {
                tags.push(n);
            }
        }
    }
    let mut episodes: Vec<Value> = Vec::new();
    if !play_url.is_empty() {
        for (i, host) in LINE_HOSTS.iter().enumerate() {
            let url = abs_url(host, &play_url);
            episodes.push(episode_json(&url, LINE_NAMES[i], series_id));
        }
    } else {
        episodes.push(episode_json(
            &format!("https://{API}/api/vod/video/{series_id}"),
            "暂无可用线路",
            series_id,
        ));
    }
    let mut extra = serde_json::Map::new();
    if !year.is_empty() {
        extra.insert("year".to_string(), json!(year));
    }
    let d = mmss(dur);
    if !d.is_empty() {
        extra.insert("duration".to_string(), json!(d));
    }
    if !tags.is_empty() {
        extra.insert("tag".to_string(), json!(tags.join(" # ")));
    }
    Ok(json!({
        "id": series_id,
        "title": name,
        "cover": abs_url(IMG, &pic),
        "synopsis": desc,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mut vid = video_id.to_string();
    if let Some(p) = vid.rfind('$') {
        vid = vid[..p].to_string();
    }
    if vid.contains(".m3u8") || vid.contains(".mp4") {
        return Ok(json!({
            "url": vid,
            "header": {"User-Agent": UA, "Referer": format!("https://{IMG}/")},
        }));
    }
    if vid.contains("/api/vod/video/") {
        let id = vid.rsplit('/').next().unwrap_or("").to_string();
        let body = api_json(&format!("/api/vod/video/{id}?site_id={SITE_ID}")).await?;
        let data = data_of(&body);
        let play_url = text_of(&data, &["play_url"]);
        if !play_url.is_empty() {
            return Ok(json!({
                "url": abs_url(IMG, &play_url),
                "header": {"User-Agent": UA, "Referer": format!("https://{IMG}/")},
            }));
        }
        return Err(ApiError::Internal("番茄视频该片无播放地址".into()));
    }
    Ok(json!({
        "url": vid,
        "header": {"User-Agent": UA, "Referer": format!("https://{IMG}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let path = format!("/search/vod/?search={encoded}&page=1&per_page={PER}&site_id={SITE_ID}");
    let body = api_json(&path).await?;
    let data = data_of(&body);
    // 同 catalog：live 行在 "items" 下。
    let rows = get(&data, "items")
        .and_then(arr_of)
        .cloned()
        .or_else(|| get(&data, "list").and_then(arr_of).cloned())
        .or_else(|| arr_of(&data).cloned())
        .unwrap_or_default();
    Ok(json!({"items": cards(&rows)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fernet_key_splits() {
        let (signing, encryption) = fernet_key().unwrap();
        assert_eq!(signing.len(), 16);
        assert_eq!(encryption.len(), 16);
    }

    #[test]
    fn mmss_formats() {
        assert_eq!(mmss(90), "01:30");
        assert_eq!(mmss(3661), "1:01:01");
        assert_eq!(mmss(0), "");
    }

    #[test]
    fn fernet_roundtrip() {
        // 用同一把 key 手工封一个 token 再解，验证验签 + 解密链路。
        use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
        let (signing, encryption) = fernet_key().unwrap();
        let iv = [7u8; 16];
        let plain = b"{\"code\":0}";
        let mut padded = plain.to_vec();
        let pad = 16 - (plain.len() % 16);
        padded.extend(std::iter::repeat(pad as u8).take(pad));
        let cipher = aes::Aes128::new(GenericArray::from_slice(&encryption));
        let mut ct = Vec::new();
        let mut prev = iv.to_vec();
        for chunk in padded.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            for i in 0..16 {
                block[i] ^= prev[i];
            }
            cipher.encrypt_block(&mut block);
            ct.extend_from_slice(&block);
            prev = block.to_vec();
        }
        let mut token: Vec<u8> = vec![0x80];
        token.extend_from_slice(&[0u8; 8]);
        token.extend_from_slice(&iv);
        token.extend_from_slice(&ct);
        let tag = hmac_sha256(&signing, &token);
        token.extend_from_slice(&tag);
        let encoded = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE, &token);
        assert_eq!(fernet_decrypt(&encoded).unwrap(), "{\"code\":0}");
    }
}
