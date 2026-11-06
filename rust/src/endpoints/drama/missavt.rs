//! MissAVt（missavt.com）：列表页解析 + 打包器解包 + AES 取流。
//!
//! - 分类：sort/hot 最热、sort/renew 最新；其余为 category/<slug>
//!   品牌分类，顶级 16 与品牌 32 按路径去重合并后共 35 个。
//! - 列表：/{分类路径}/?page=N；卡片按 <li> 切分，含 video-item
//!   的块取 /watch/ 链接、line-clamp-2 标题、data-src 封面（
//!   回退站内 /video/webp/<code>.webp）、时长备注。
//! - 详情：/watch/<code>/；标题取 title 去 MissAVt 后缀，封面
//!   og:image（回退 webp 规则），简介取 meta keywords；单集
//!   video_id 即 code（play 兼容 mvt@ 前缀）。
//! - 取流：详情页找 eval 打包器 → base62 解包 → 先把转义的
//!   单双引号还原，再取 url / api / key / iv 字段；api 返回
//!   base64 密文，AES-128-CBC 解密（key/iv 各取前 16 字节），
//!   明文里首个 m3u8；失败回退 config 的 url，再回退 og:video。

use regex::Regex;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{category_json, client, episode_json, item_json};

const HOST: &str = "https://missavt.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn headers(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    req.header("User-Agent", UA)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        .header("Referer", format!("{HOST}/"))
}

async fn get_text(url: &str) -> ApiResult<String> {
    let resp = headers(client()?.get(url))
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("MissAVt 请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    if text.len() < 1500 || text.contains("just a moment") || text.contains("cf_chl") {
        return Err(ApiError::Internal("MissAVt 页面异常（疑似盾拦截）".into()));
    }
    Ok(text)
}

fn clean(s: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    let ws_re = Regex::new(r"\s+").unwrap();
    let t = tag_re.replace_all(s, " ");
    let t = t
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace('\u{a0}', " ");
    ws_re.replace_all(&t, " ").trim().to_string()
}

fn enc_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

fn parse_cards(html: &str) -> Vec<Value> {
    let mut items = Vec::new();
    for chunk in html.split("<li") {
        if !chunk.contains("video-item") {
            continue;
        }
        let end = chunk.find("</li>").unwrap_or(chunk.len().min(3200));
        let seg = &chunk[..end.min(3200)];
        let href_re = Regex::new(r#"(/watch/[^"]+)"#).unwrap();
        let href = match href_re.captures(seg) {
            Some(c) => c[1].to_string(),
            None => continue,
        };
        let code = href
            .trim_start_matches("/watch/")
            .trim_end_matches('/')
            .to_string();
        let title_re = Regex::new(r#"class="[^"]*line-clamp-2[^"]*"[^>]*>([^<]{1,120})"#).unwrap();
        let mut title = title_re
            .captures(seg)
            .map(|c| clean(&c[1]))
            .unwrap_or_default();
        if title.is_empty() {
            let alt_re = Regex::new(r#"alt="([^"]+)""#).unwrap();
            title = alt_re
                .captures(seg)
                .map(|c| clean(&c[1]))
                .unwrap_or_default();
        }
        if title.is_empty() {
            title = code.to_uppercase();
        }
        let mut pic = {
            let ds_re = Regex::new(r#"data-src="([^"]+)""#).unwrap();
            ds_re
                .captures(seg)
                .map(|c| c[1].to_string())
                .unwrap_or_default()
        };
        if pic.is_empty() {
            pic = format!("{HOST}/video/webp/{code}.webp");
        }
        let dur_re = Regex::new(r">\s*(\d{1,2}:\d{2}:\d{2})\s*<").unwrap();
        let remark = dur_re
            .captures(seg)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        items.push(item_json(&href, &title, &pic, &remark));
    }
    items
}

/// AES-128-CBC 解密（PKCS7 去填充），手写块循环，只用 aes 基础接口。
fn aes_cbc_decrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
    if key.len() < 16 || iv.len() < 16 || data.is_empty() || data.len() % 16 != 0 {
        return None;
    }
    let cipher = aes::Aes128::new(GenericArray::from_slice(&key[..16]));
    let mut out = Vec::with_capacity(data.len());
    let mut prev: [u8; 16] = iv[..16].try_into().ok()?;
    for chunk in data.chunks_exact(16) {
        let mut block: [u8; 16] = chunk.try_into().ok()?;
        let cur: [u8; 16] = block;
        cipher.decrypt_block(GenericArray::from_mut_slice(&mut block));
        for i in 0..16 {
            out.push(block[i] ^ prev[i]);
        }
        prev = cur;
    }
    let pad = *out.last()? as usize;
    if pad == 0 || pad > 16 || pad > out.len() {
        return None;
    }
    if out[out.len() - pad..].iter().any(|b| *b as usize != pad) {
        return None;
    }
    out.truncate(out.len() - pad);
    Some(out)
}

const B62: &[u8; 62] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn enc_b62(mut n: u64, base: u64) -> String {
    if n < base {
        return (B62[n as usize] as char).to_string();
    }
    let mut out = String::new();
    while n >= base {
        out.insert(0, B62[(n % base) as usize] as char);
        n /= base;
    }
    out.insert(0, B62[n as usize] as char);
    out
}

/// 打包器解包：p/a/c/k，base62 词表逆序替换。
fn dean_unpack(p: &str, a: u64, c: u64, k: &[&str]) -> String {
    let mut out = p.to_string();
    let mut i = c;
    while i > 0 {
        i -= 1;
        let word = enc_b62(i, a);
        let kw = k.get(i as usize).copied().unwrap_or("");
        if kw.is_empty() {
            continue;
        }
        let wre = Regex::new(&format!(r"\b{}\b", regex::escape(&word))).unwrap();
        out = wre.replace_all(&out, kw).to_string();
    }
    out
}

/// 取 config 里单引号字段：'key':'value'。
fn cfg_field(unpacked: &str, key: &str) -> Option<String> {
    let re = Regex::new(&format!(r"'{}\s*'\s*:\s*'([^']*)'", regex::escape(key))).unwrap();
    re.captures(unpacked).map(|c| c[1].to_string())
}

/// api 地址取密文并 AES 解密，返回明文里首个 m3u8（或明文本身）。
async fn decrypt_api(api: &str, key: &str, iv: &str) -> Option<String> {
    let mut url = if api.starts_with("http") {
        api.to_string()
    } else {
        format!("{}{}", HOST, api.trim_start_matches('/'))
    };
    if !url.ends_with('/') {
        url.push('/');
    }
    let resp = headers(client().ok()?.get(&url)).send().await.ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let text = resp.text().await.ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    if value.get("code").and_then(|c| c.as_i64()) != Some(200) {
        return None;
    }
    let data = value.get("data").and_then(|d| d.as_str()).unwrap_or("");
    if data.len() < 16 {
        return None;
    }
    use base64::Engine;
    let cipher_bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .ok()?;
    let plain = aes_cbc_decrypt(key.as_bytes(), iv.as_bytes(), &cipher_bytes)?;
    let plain_s = String::from_utf8_lossy(&plain).to_string();
    let m3u8_re = Regex::new(r#"https?://[^\s"'\\]+\.m3u8[^\s"'\\]*"#).unwrap();
    if let Some(m) = m3u8_re.find(&plain_s) {
        return Some(m.as_str().to_string());
    }
    let t = plain_s.trim();
    if t.starts_with("http") {
        return Some(t.to_string());
    }
    None
}

/// 详情页打包器取流。
async fn pick_stream(code: &str) -> ApiResult<String> {
    let html = get_text(&format!("{HOST}/watch/{code}/")).await?;
    let pack_re = Regex::new(
        r"(?s)eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)",
    )
    .unwrap();
    if let Some(c) = pack_re.captures(&html) {
        let a: u64 = c[2].parse().unwrap_or(62);
        let count: u64 = c[3].parse().unwrap_or(0);
        let k: Vec<&str> = c[4].split('|').collect();
        let unpacked = dean_unpack(&c[1], a, count, &k);
        let unpacked = unpacked.replace("\\'", "'").replace("\\\"", "\"");
        if let Some(u) = cfg_field(&unpacked, "url") {
            if u.starts_with("http") {
                if let (Some(api), Some(key), Some(iv)) = (
                    cfg_field(&unpacked, "api"),
                    cfg_field(&unpacked, "key"),
                    cfg_field(&unpacked, "iv"),
                ) {
                    if let Some(m3u8) = decrypt_api(&api, &key, &iv).await {
                        return Ok(m3u8);
                    }
                }
                return Ok(u);
            }
        }
    }
    let og_re = Regex::new(r#"<meta[^>]*property="og:video"[^>]*content="([^"]+)""#).unwrap();
    if let Some(c) = og_re.captures(&html) {
        return Ok(c[1].to_string());
    }
    let og_re2 = Regex::new(r#"<meta[^>]*content="([^"]+)"[^>]*property="og:video""#).unwrap();
    if let Some(c) = og_re2.captures(&html) {
        return Ok(c[1].to_string());
    }
    Err(ApiError::Internal("MissAVt 未取到播放地址".into()))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = vec![
        category_json("sort/hot", "最热"),
        category_json("sort/renew", "最新"),
    ];
    let cats: [(&str, &str); 33] = [
        ("category/censored", "有码"),
        ("category/chinese-subtitle", "中文字幕"),
        ("category/uncensored-leak", "无码流出"),
        ("category/reducing-mosaic", "无码破解"),
        ("category/renqishunv", "人妻熟女"),
        ("category/zhifuyouhuo", "制服诱惑"),
        ("category/jiatingluanlun", "家庭乱伦"),
        ("category/madou", "麻豆传媒"),
        ("category/sweet-heart-vlog", "糖心Vlog"),
        ("category/91-studio", "91制片厂"),
        ("category/domestic-media", "国产传媒"),
        ("category/fc2", "FC2"),
        ("category/1pondo", "一本道"),
        ("category/tokyohot", "东京热"),
        ("category/ed-mosaic", "ED Mosaic"),
        ("category/marriedslash", "人妻斩"),
        ("category/xingbatanhua", "杏吧探花"),
        ("category/swag", "SWAG"),
        ("category/douyin", "抖阴"),
        ("category/mr-rabbit", "兔子先生"),
        ("category/heyzo", "HEYZO"),
        ("category/caribbeancom", "Caribbeancom"),
        ("category/caribbeancompr", "Caribbeancompr"),
        ("category/10musume", "10musume"),
        ("category/pacopacomama", "pacopacomama"),
        ("category/xxx-av", "XXX-AV"),
        ("category/siro", "SIRO"),
        ("category/s-cute", "S-CUTE"),
        ("category/ara", "ARA"),
        ("category/luxu", "luxu"),
        ("category/gana", "gana"),
        ("category/prestige-premium", "prestige-premium"),
        ("category/amateur", "amateur"),
    ];
    for (id, name) in cats {
        list.push(category_json(id, name));
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let html = get_text(&format!("{HOST}/{category_id}/?page={page}")).await?;
    let items = parse_cards(&html);
    Ok(json!({"items": items, "has_more": items.len() >= 24}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let code = series_id
        .trim_start_matches("/watch/")
        .trim_end_matches('/')
        .to_string();
    let html = get_text(&format!("{HOST}/watch/{code}/")).await?;
    let mut title = {
        let t_re = Regex::new(r"(?s)<title[^>]*>(.*?)</title>").unwrap();
        t_re.captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default()
    };
    for suf in [" - MissAVt", " | MissAVt", "- MissAVt", "| MissAVt"] {
        if let Some(t) = title.strip_suffix(suf) {
            title = t.trim().to_string();
            break;
        }
    }
    if title.is_empty() {
        title = code.to_uppercase();
    }
    let cover = {
        let og_re = Regex::new(r#"<meta[^>]*property="og:image"[^>]*content="([^"]+)""#).unwrap();
        let og_re2 = Regex::new(r#"<meta[^>]*content="([^"]+)"[^>]*property="og:image""#).unwrap();
        og_re
            .captures(&html)
            .or_else(|| og_re2.captures(&html))
            .map(|c| c[1].to_string())
            .unwrap_or_else(|| format!("{HOST}/video/webp/{code}.webp"))
    };
    let kw = {
        let kw_re = Regex::new(r#"<meta[^>]*name="keywords"[^>]*content="([^"]*)""#).unwrap();
        kw_re
            .captures(&html)
            .map(|c| clean(&c[1]))
            .unwrap_or_default()
    };
    let dur_re = Regex::new(r"(\d{1,2}:\d{2}:\d{2})").unwrap();
    let dur = dur_re
        .captures(&html)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    let mut syn = String::from(
        "站源：MissAVt（missavt.com），免登录直取\n取流：详情页打包器解包 + AES 接口解密取 m3u8",
    );
    if !dur.is_empty() {
        syn.push_str(&format!("\n时长：{dur}"));
    }
    if !kw.is_empty() {
        syn.push_str(&format!("\n简介：{kw}"));
    }
    let episode = episode_json(&code, "正片", series_id);
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": syn,
        "extra": {"vod_play_from": "MissAVt"},
        "episodes": [episode],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let code = video_id
        .strip_prefix("mvt@")
        .unwrap_or(video_id)
        .trim_start_matches("/watch/")
        .trim_end_matches('/')
        .to_string();
    let url = pick_stream(&code).await?;
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{HOST}/")},
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let html = get_text(&format!("{HOST}/search/{}", enc_path(query))).await?;
    Ok(json!({"items": parse_cards(&html)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aes_cbc_roundtrip() {
        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        let plain = b"hello world 1234";
        use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
        let cipher = aes::Aes128::new(GenericArray::from_slice(&key[..]));
        let mut data = plain.to_vec();
        data.extend(std::iter::repeat(16u8).take(16));
        let mut out = Vec::new();
        let mut prev: [u8; 16] = *iv;
        for chunk in data.chunks_exact(16) {
            let mut block: [u8; 16] = chunk.try_into().unwrap();
            for i in 0..16 {
                block[i] ^= prev[i];
            }
            cipher.encrypt_block(GenericArray::from_mut_slice(&mut block));
            // CBC 链下一块的 prev 是本次的密文块，不是异或后的明文块。
            prev = block;
            out.extend_from_slice(&block);
        }
        let dec = aes_cbc_decrypt(key, iv, &out).unwrap();
        assert_eq!(dec, plain);
    }

    #[test]
    fn dean_unpack_replaces() {
        let out = dean_unpack("0 1 2", 10, 3, &["x", "y", "z"]);
        assert_eq!(out, "x y z");
    }

    #[test]
    fn parse_cards_sample() {
        let html = r#"<li class="video-item"><a href="/watch/SILK-194/"><img data-src="https://img.example.com/a.jpg"><div class="my-1 md:my-2 line-clamp-2">标题</div><span>2:13:29</span></a></li>"#;
        let items = parse_cards(html);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "/watch/SILK-194/");
        assert_eq!(items[0]["remark"], "2:13:29");
    }
}
