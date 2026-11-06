//! XX9（xx9.com · 金币站）：免登录免注册直取。
//!
//! 与 jar 的 `ZakaXx9Amns` 1:1：网关发现（BOOT 两地址取网关池，30 分钟
//! 缓存）→ jwt（app/jwt-token）→ 免注册（user/register/free）→ 内容接口
//! （config/query、cms/group-in-packages、cms/vod/search、cms/vod/detail）。
//! 内层请求 JSON 用 AES-128-ECB 加密（密钥 16 字节 ASCII）再 Base64，
//! 外层只带 data 与 time；服务端按时间轮换 9 把密钥，客户端按 jar 原样
//! 轮询密钥与网关（每试 ≥1 秒，带抖动破锁步）。
//!
//! 两处修好再写（jar 原样在本机出口不通）：
//! ① 注册接口的 method 字段与槽位：jar 调 raw 时传 method 2、载荷放 body
//! 槽（params 放 null），按 params 槽发会回 BSC10003“请求方式错误”；
//! ② 详情接口要真 accessToken，jwt 冒充 accessToken 只偶然通、随后一律
//! 回 1019“Token过期”，必须走注册拿真令牌（令牌有效期见注册回包）。
//! 另：包分类（g{id}）不带 groupIds——jar 的 list() 只在首字符为 s/t
//! 时才置 groupIds/themeIds（且为整型），包分支不置任何过滤条件，
//! 即包分类走全局 explore 列表；实测多值 groupIds 一律被服务端拒绝
//! （逗号串回 total 0、JSON 数组回 SYS9999），故本文件照 jar 原样不置过滤。
//!
//! 封面是 XOR 掩码图（首字节为密钥、去掉首字节后其余字节逐字节异或，
//! 见 jar 的 `$Xx9Proxy.unmask`）：核心无图片路由，无法在核心内解掩码，
//! 这里只回直链封面地址，显示需等核心补图片路由或 Dart 侧解掩码；播
//! 放本身是直链 m3u8（清单、分片、密钥三者全可直取），不需要本地代理。
//! 分组 3“国产JK萝莉”与 26“欧美萝莉cos”按用户口径不进分类，站照常写。
//! 取流地址带 CDN 鉴权时效戳，play() 每次现取详情，不缓存旧地址。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aes::Aes128;
use base64::Engine as _;
use cipher::generic_array::GenericArray;
use cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use serde_json::{json, Value};

use crate::crypto::{pkcs7_pad, pkcs7_unpad_strict};
use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, int_of, item_json, text_of};

const BOOT: &[&str] = &[
    "https://k5p0vw2fgfvc.xyz/",
    "https://k4irke3n6xcwdpc.xyz/zbtip.txt",
];
const GW_BUILTIN: &[&str] = &[
    "https://pl5kjl.jas49cht5sqrwet.xyz",
    "https://pl5kjl.m93abv5upsv4s8f.xyz",
    "https://api.y7hvaad8g.xyz",
];
const KEYS: &[&str] = &[
    "6eIZ4cxM5pqzUXcF",
    "1Yy1KOa75R7cnmkg",
    "4MVTQQAJlMpUIAiL",
    "84UZNK33cSVylz6Y",
    "jeSWRcTwHyAKwJDB",
    "ugvseZc5Kkj8ecmV",
    "i1hvJx9vuRt5zEBS",
    "8HbPxhX6fjhhhwok",
    "G7i3OPcfNhBnAYpc",
];
const UA: &str = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const SITE: &str = "https://xx9.com/";
const PIC_BASE: &str = "https://qv1tx2.shoupingxz.com";
const LINE_DEFAULT: &str = "https://allmusiclub.almusiclub.com";
const H5_LINES_FALLBACK: &[(&str, &str)] = &[
    ("国线1", "https://rr.rxjhwl.com"),
    ("国线2", "https://ww.wealwelloa.com"),
    ("国线3", "https://cc.cloudworki.com"),
    ("国线4", "https://gg.gmdalian.com"),
    ("海线1", "https://allmusiclub.almusiclub.com"),
    ("海线2", "https://allmusiclub.almusiclub.com"),
];
const LOLI_GROUPS: &[i64] = &[3, 26];
const FALLBACK_PACKAGES: &[(&str, &str)] = &[
    ("1", "国产精选"),
    ("2", "日韩精选"),
    ("3", "欧美精选"),
    ("4", "动漫精选"),
    ("5", "其他分类"),
];
const GW_TTL: Duration = Duration::from_secs(30 * 60);
const CFG_TTL: Duration = Duration::from_secs(30 * 60);

static GATEWAYS: Mutex<Option<(Vec<String>, Instant)>> = Mutex::new(None);
static AUTH: Mutex<Option<(String, String, Instant)>> = Mutex::new(None);
static LINES: Mutex<Option<(Vec<(String, String)>, Instant)>> = Mutex::new(None);

/// AES-128-ECB 加密（PKCS7 填充，与 jar 的 cipher 一致）。
fn aes_ecb_encrypt(data: &[u8], key: &[u8]) -> Vec<u8> {
    let cipher = Aes128::new_from_slice(key).expect("XX9 密钥须为 16 字节");
    let padded = pkcs7_pad(data, 16);
    let mut out = Vec::with_capacity(padded.len());
    for chunk in padded.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.encrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    out
}

/// AES-128-ECB 解密（去 PKCS7 填充，失败返回原因）。
fn aes_ecb_decrypt(data: &[u8], key: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() % 16 != 0 {
        return Err("XX9 解密数据长度不是 16 的倍数".into());
    }
    let cipher = Aes128::new_from_slice(key).map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(data.len());
    for chunk in data.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    let plain = pkcs7_unpad_strict(&out, 16).map_err(|e| e.to_string())?;
    Ok(plain.to_vec())
}

fn b64_encode(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

fn b64_decode(text: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(text)
        .map_err(|e| e.to_string())
}

/// 内层 JSON 加密成 Base64（与 jar 的 enc 一致）。
fn enc_json(obj: &Value, key: &str) -> Result<String, String> {
    let raw = serde_json::to_string(obj).map_err(|e| e.to_string())?;
    Ok(b64_encode(&aes_ecb_encrypt(raw.as_bytes(), key.as_bytes())))
}

/// 外层 data 字段解密成 JSON（与 jar 的 dec 一致）。
fn dec_json(text: &str, key: &str) -> Result<Value, String> {
    let raw = b64_decode(text)?;
    let plain = aes_ecb_decrypt(&raw, key.as_bytes())?;
    let text = String::from_utf8(plain).map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

/// 32 位随机字母数字串（jar 的 rnd(32)，注册 sign 用）。
fn rnd32() -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15);
    let mut out = String::with_capacity(32);
    for _ in 0..32 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        out.push(ALPHABET[(seed % ALPHABET.len() as u64) as usize] as char);
    }
    out
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 从 JWT 中间段读 exp（秒）；读不到按 1 小时计。
fn jwt_exp_secs(token: &str) -> u64 {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return 3600;
    }
    let mut payload = parts[1].to_string();
    while payload.len() % 4 != 0 {
        payload.push('=');
    }
    let decoded = match base64::engine::general_purpose::URL_SAFE.decode(&payload) {
        Ok(v) => v,
        Err(_) => return 3600,
    };
    let value: Value = match serde_json::from_slice(&decoded) {
        Ok(v) => v,
        Err(_) => return 3600,
    };
    let exp = int_of(&value, &["exp"]);
    if exp > 0 {
        exp as u64
    } else {
        3600
    }
}

fn trim_slash(raw: &str) -> String {
    raw.trim().trim_end_matches('/').to_string()
}

/// 网关池：BOOT 两地址轮询取 result 与 pool，30 分钟缓存，失败回内置。
async fn gateways() -> Vec<String> {
    if let Ok(guard) = GATEWAYS.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires && !cached.is_empty() {
                return cached.clone();
            }
        }
    }
    let mut found: Vec<String> = Vec::new();
    for boot in BOOT {
        let req = match client() {
            Ok(c) => c
                .get(*boot)
                .header("User-Agent", UA)
                .header("Referer", *boot),
            Err(_) => continue,
        };
        let resp = match req.send().await {
            Ok(r) => r,
            Err(_) => continue,
        };
        if resp.status().as_u16() != 200 {
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(_) => continue,
        };
        let body: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let result = trim_slash(&text_of(&body, &["result"]));
        if !result.is_empty() && !found.contains(&result) {
            found.push(result);
        }
        for part in text_of(&body, &["pool"]).split(',') {
            let gw = trim_slash(part);
            if !gw.is_empty() && !found.contains(&gw) {
                found.push(gw);
            }
        }
        if !found.is_empty() {
            break;
        }
    }
    if found.is_empty() {
        found = GW_BUILTIN.iter().map(|s| s.to_string()).collect();
    }
    if let Ok(mut guard) = GATEWAYS.lock() {
        *guard = Some((found.clone(), Instant::now() + GW_TTL));
    }
    found
}

/// 节流：两次网关请求之间至少等 1 秒，再加 0～900 毫秒抖动破锁步
/// （服务端按时间轮换密钥，固定间隔会与轮换锁步、整轮错过）。
async fn pace(last: &mut Instant) {
    let elapsed = last.elapsed();
    let mut wait_ms: u64 = 1000;
    if elapsed < Duration::from_millis(1000) {
        wait_ms = 1000 - elapsed.as_millis() as u64;
    }
    let jitter = (now_millis() % 900) as u64;
    tokio::time::sleep(Duration::from_millis(wait_ms + jitter)).await;
    *last = Instant::now();
}

/// 发一次网关请求：外层 {data, time}，头带 jwtToken/accessToken。
/// 密钥与网关按 jar 原样轮询（密钥 9 把轮换、每网关试两把）；响应先用
/// 请求密钥解，失败再试下一把密钥；code 非 0000 也原样返回给调用方。
async fn gateway_call(inner: &Value, jwt: Option<&str>, token: Option<&str>) -> ApiResult<Value> {
    let gws = gateways().await;
    let mut last = Instant::now() - Duration::from_secs(2);
    let mut last_err = String::new();
    for att in 0..12usize {
        let key = KEYS[att % KEYS.len()];
        let gw = &gws[(att / 2) % gws.len().max(1)];
        let outer = match enc_json(inner, key) {
            Ok(data) => json!({"data": data, "time": now_millis()}),
            Err(e) => {
                last_err = e;
                continue;
            }
        };
        pace(&mut last).await;
        let mut req = match client() {
            Ok(c) => c
                .post(format!("{gw}/fast-endecode/main/request"))
                .header("User-Agent", UA)
                .header("Accept", "application/json, text/plain, */*")
                .header("Content-Type", "application/json")
                .json(&outer),
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if let Some(j) = jwt {
            if !j.is_empty() {
                req = req.header("jwtToken", j);
            }
        }
        if let Some(t) = token {
            if !t.is_empty() {
                req = req.header("accessToken", t);
            }
        }
        let resp = match req.send().await {
            Ok(r) => r,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if resp.status().as_u16() != 200 {
            last_err = format!("XX9 网关 HTTP {}", resp.status().as_u16());
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let text = text.trim().to_string();
        if text.is_empty() {
            last_err = "XX9 网关回空".into();
            continue;
        }
        let body: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let data = text_of(&body, &["data"]);
        if data.is_empty() {
            last_err = "XX9 网关回包无 data".into();
            continue;
        }
        let next_key = KEYS[(att + 1) % KEYS.len()];
        match dec_json(&data, key).or_else(|_| dec_json(&data, next_key)) {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e;
                continue;
            }
        }
    }
    Err(ApiError::Internal(format!(
        "XX9 网关 12 次尝试均未通：{last_err}"
    )))
}

/// 业务码校验：code 须为 0000，否则按服务端 code 与 message 报错。
fn check_code(body: &Value, action: &str) -> ApiResult<()> {
    let code = text_of(body, &["code"]);
    if code == "0000" {
        return Ok(());
    }
    let detail = text_of(body, &["message"]);
    let mut message = format!("XX9{action}失败");
    if !code.is_empty() {
        message.push_str(&format!("（{code}）"));
    }
    if !detail.is_empty() {
        message.push_str(&format!("：{detail}"));
    }
    Err(ApiError::Internal(message))
}

/// 认证：jwt 与注册令牌双缓存，取两者较早过期时间减 60 秒余量。
async fn auth() -> ApiResult<(String, String)> {
    if let Ok(guard) = AUTH.lock() {
        if let Some((jwt, token, expires)) = guard.as_ref() {
            if Instant::now() < *expires {
                return Ok((jwt.clone(), token.clone()));
            }
        }
    }
    let jwt_body = gateway_call(
        &json!({"method": 1, "params": Value::Null, "uri": "app/jwt-token"}),
        None,
        None,
    )
    .await?;
    check_code(&jwt_body, "取 jwt")?;
    let jwt = text_of(&jwt_body, &["result"]);
    if jwt.is_empty() {
        return Err(ApiError::Internal("XX9 未返回 jwt".into()));
    }
    let jwt_valid = jwt_exp_secs(&jwt);
    let reg_body = gateway_call(
        &json!({
            "method": 2,
            "body": {
                "osType": "h5",
                "sign": rnd32(),
                "machineCode": "chrome",
                "version": "xx9.com",
            },
            "params": Value::Null,
            "uri": "user/register/free",
        }),
        Some(&jwt),
        None,
    )
    .await?;
    check_code(&reg_body, "免注册")?;
    let result = get(&reg_body, "result").cloned().unwrap_or(Value::Null);
    let token = text_of(&result, &["accessToken"]);
    if token.is_empty() {
        return Err(ApiError::Internal("XX9 免注册未返回令牌".into()));
    }
    let token_valid_ms = int_of(&result, &["tokenValidDate"]);
    let now_ms = now_millis() as i64;
    let token_valid_secs = if token_valid_ms > now_ms {
        (token_valid_ms - now_ms) / 1000
    } else {
        3000
    };
    let ttl = jwt_valid
        .min(token_valid_secs.max(0) as u64)
        .saturating_sub(60);
    let ttl = ttl.max(60);
    if let Ok(mut guard) = AUTH.lock() {
        *guard = Some((
            jwt.clone(),
            token.clone(),
            Instant::now() + Duration::from_secs(ttl),
        ));
    }
    Ok((jwt, token))
}

/// 内容接口：method 1 走 params 槽，method 2 有 params 走 params 槽、
/// 无 params 走 body 槽（与 jar 的 raw 分支一致）。
async fn api(
    uri: &str,
    method: i64,
    body: Option<Value>,
    params: Option<Value>,
) -> ApiResult<Value> {
    let (jwt, token) = auth().await?;
    let inner = if method == 1 {
        json!({"method": method, "params": params.unwrap_or(Value::Null), "uri": uri})
    } else if let Some(p) = params {
        json!({"method": method, "params": p, "uri": uri})
    } else {
        json!({"method": method, "body": body.unwrap_or(Value::Null), "uri": uri})
    };
    let resp = gateway_call(&inner, Some(&jwt), Some(&token)).await?;
    check_code(&resp, "请求")?;
    Ok(resp)
}

/// 播放线路：config 的 h5_play_line（JSON 串），30 分钟缓存，失败回内置。
async fn play_lines() -> Vec<(String, String)> {
    if let Ok(guard) = LINES.lock() {
        if let Some((cached, expires)) = guard.as_ref() {
            if Instant::now() < *expires && !cached.is_empty() {
                return cached.clone();
            }
        }
    }
    let mut lines: Vec<(String, String)> = Vec::new();
    let resp = api(
        "config/query",
        1,
        None,
        Some(json!({
            "groupKey": "APP",
            "key": "picBaseUrl,newPicBaseUrl,playLines,h5_play_line,mp4Domain",
        })),
    )
    .await;
    if let Ok(resp) = resp {
        let result = get(&resp, "result").cloned().unwrap_or(Value::Null);
        let raw = text_of(&result, &["h5_play_line"]);
        if let Ok(parsed) = serde_json::from_str::<Value>(&raw) {
            if let Some(arr) = arr_of(&parsed) {
                let mut seen: HashSet<String> = HashSet::new();
                for entry in arr {
                    let name = text_of(entry, &["name"]);
                    let line = trim_slash(&text_of(entry, &["line"]));
                    if line.is_empty() || !seen.insert(line.clone()) {
                        continue;
                    }
                    let name = if name.is_empty() {
                        format!("线路{}", lines.len() + 1)
                    } else {
                        name
                    };
                    lines.push((name, line));
                }
            }
        }
    }
    if lines.is_empty() {
        lines = H5_LINES_FALLBACK
            .iter()
            .map(|(n, l)| (n.to_string(), l.to_string()))
            .collect();
    }
    if let Ok(mut guard) = LINES.lock() {
        *guard = Some((lines.clone(), Instant::now() + CFG_TTL));
    }
    lines
}

/// 分组包：cms/group-in-packages 的 data 数组。
async fn packages() -> ApiResult<Vec<Value>> {
    let resp = api("cms/group-in-packages", 1, None, None).await?;
    match get(&resp, "data").and_then(arr_of) {
        Some(list) => Ok(list.clone()),
        None => Ok(Vec::new()),
    }
}

fn pic(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() {
        return String::new();
    }
    if raw.starts_with("http") {
        return raw.to_string();
    }
    if let Some(rest) = raw.strip_prefix('/') {
        return format!("{PIC_BASE}/{rest}");
    }
    format!("{PIC_BASE}/{raw}")
}

/// 备注：时长分钟 ＋ VIP 或免费直取（与 jar 的 cards 一致）。
fn card_remark(item: &Value) -> String {
    let duration = int_of(item, &["vodDuration"]);
    let mut remark = if duration > 0 {
        format!("{duration} 分钟")
    } else {
        String::new()
    };
    let is_vip = matches!(get(item, "isVip"), Some(Value::Bool(true)));
    let gold = int_of(item, &["gold"]);
    if is_vip {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("VIP");
    } else if gold > 0 {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("VIP");
    } else {
        if !remark.is_empty() {
            remark.push_str(" · ");
        }
        remark.push_str("免费直取");
    }
    remark
}

fn card(item: &Value) -> Option<Value> {
    let id = text_of(item, &["id"]);
    if id.is_empty() {
        return None;
    }
    let title = text_of(item, &["title"]);
    if title.is_empty() {
        return None;
    }
    let cover = pic(&text_of(item, &["vodPic"]));
    Some(item_json(&id, &title, &cover, &card_remark(item)))
}

fn cards(rows: &[Value]) -> Vec<Value> {
    rows.iter().filter_map(card).collect()
}

/// 分组过滤：萝莉分组（id 3、26）不进分类，站照常写。
fn visible_groups(pkg: &Value) -> Vec<Value> {
    match get(pkg, "groups").and_then(arr_of) {
        Some(groups) => groups
            .iter()
            .filter(|g| !LOLI_GROUPS.contains(&int_of(g, &["id"])))
            .cloned()
            .collect(),
        None => Vec::new(),
    }
}

fn categories_from_packages(pkgs: &[Value]) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out: Vec<Value> = Vec::new();
    for pkg in pkgs {
        let pid = text_of(pkg, &["id"]);
        if pid.is_empty() {
            continue;
        }
        let name = text_of(pkg, &["name"]);
        if !name.is_empty() && seen.insert(format!("g{pid}")) {
            out.push(category_json(&format!("g{pid}"), &name));
        }
        for group in visible_groups(pkg) {
            let gid = text_of(&group, &["id"]);
            if gid.is_empty() {
                continue;
            }
            let gname = text_of(&group, &["groupName"]);
            if gname.is_empty() {
                continue;
            }
            if seen.insert(format!("s{gid}")) {
                out.push(category_json(
                    &format!("s{gid}"),
                    &format!("{name}·{gname}"),
                ));
            }
        }
    }
    out
}

fn fallback_categories() -> Value {
    let list: Vec<Value> = FALLBACK_PACKAGES
        .iter()
        .map(|(id, name)| category_json(&format!("g{id}"), name))
        .collect();
    json!({"categories": list})
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list = match packages().await {
        Ok(pkgs) if !pkgs.is_empty() => categories_from_packages(&pkgs),
        _ => return Ok(fallback_categories()),
    };
    if let Ok(resp) = api(
        "theme/list",
        2,
        None,
        Some(json!({"page": 1, "pageSize": 20})),
    )
    .await
    {
        if let Some(rows) = get(&resp, "data")
            .and_then(|d| get(d, "list"))
            .and_then(arr_of)
        {
            for entry in rows {
                let id = text_of(entry, &["id"]);
                let title = text_of(entry, &["title"]);
                if id.is_empty() || title.is_empty() {
                    continue;
                }
                list.push(category_json(&format!("t{id}"), &title));
            }
        }
    }
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let mut params = json!({
        "page": page,
        "pageSize": 20,
        "explore": true,
        "sortType": 0,
    });
    let first = category_id.chars().next().unwrap_or('\0');
    let num = category_id
        .get(1..)
        .unwrap_or("")
        .parse::<i64>()
        .unwrap_or(0);
    {
        let obj = params.as_object_mut().expect("XX9 目录参数须为对象");
        match first {
            'g' => {
                // 包分类：jar 的 list() 没有 g 分支，不置 groupIds，
                // 即包分类返回全局 explore 列表（照 jar 原样）。
            }
            's' => {
                if num > 0 {
                    obj.insert("groupIds".to_string(), json!(num));
                }
            }
            't' => {
                if num > 0 {
                    obj.insert("themeIds".to_string(), json!(num));
                }
            }
            _ => {}
        }
    }
    let resp = api("cms/vod/search", 2, None, Some(params)).await?;
    let total = int_of(&resp, &["total"]);
    let items = match get(&resp, "data").and_then(arr_of) {
        Some(rows) => cards(rows),
        None => Vec::new(),
    };
    let has_more = !items.is_empty() && total > page * 20;
    Ok(json!({"items": items, "has_more": has_more}))
}

/// 取详情里的播放地址（vodFullPlayUrl 首条 addr，缺省用 newAddr）。
fn detail_addr(vod: &Value) -> String {
    if let Some(arr) = get(vod, "vodFullPlayUrl").and_then(arr_of) {
        if let Some(first) = arr.first() {
            let addr = text_of(first, &["addr"]);
            if !addr.is_empty() {
                return addr;
            }
        }
    }
    if let Some(url) = get(vod, "vodFullPlayUrl").and_then(|v| v.as_str()) {
        if !url.is_empty() {
            return url.to_string();
        }
    }
    text_of(vod, &["newAddr", "addr"])
}

async fn fetch_vod(vod_id: &str) -> ApiResult<Value> {
    let resp = api(
        &format!("cms/vod/detail/{vod_id}"),
        1,
        Some(json!({"needCdnAuth": 1})),
        None,
    )
    .await?;
    let vod = get(&resp, "result")
        .and_then(|r| get(r, "vod"))
        .cloned()
        .unwrap_or(Value::Null);
    if !vod.is_object() {
        return Err(ApiError::Internal("XX9 未返回视频资料".into()));
    }
    Ok(vod)
}

pub(crate) async fn detail(vod_id: &str) -> ApiResult<Value> {
    let vod = fetch_vod(vod_id).await?;
    let title = text_of(&vod, &["title"]);
    let cover = pic(&text_of(&vod, &["vodPic"]));
    let duration = int_of(&vod, &["vodDuration"]);
    let gold = int_of(&vod, &["gold"]);
    let author = text_of(&vod, &["authorName"]);
    let tags = match get(&vod, "tags").and_then(arr_of) {
        Some(list) => list
            .iter()
            .map(|t| t.as_str().unwrap_or_default().to_string())
            .filter(|s| !s.is_empty())
            .collect::<Vec<String>>()
            .join(" / "),
        None => String::new(),
    };
    let lines = play_lines().await;
    let line_names: Vec<String> = lines.iter().map(|(n, _)| n.clone()).collect();
    let mut synopsis = String::new();
    if duration > 0 {
        synopsis.push_str(&format!("时长：{duration} 分钟\n"));
    }
    if gold > 0 {
        synopsis.push_str(&format!("金币：{gold}\n"));
    }
    if !author.is_empty() {
        synopsis.push_str(&format!("作者：{author}\n"));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("标签：{tags}\n"));
    }
    if !line_names.is_empty() {
        synopsis.push_str(&format!("线路：{}\n", line_names.join("、")));
    }
    synopsis.push_str("取流：直链 m3u8（AES-128 分片加密，播放器原生解密）");
    let addr = detail_addr(&vod);
    if addr.is_empty() {
        return Err(ApiError::Internal("XX9 未返回播放地址".into()));
    }
    let episodes: Vec<Value> = if addr.starts_with("http") {
        vec![episode_json(&addr, "正片", vod_id)]
    } else {
        lines
            .iter()
            .enumerate()
            .map(|(i, (name, _))| {
                episode_json(&format!("v:{vod_id}:{i}"), &format!("正片·{name}"), vod_id)
            })
            .collect()
    };
    if episodes.is_empty() {
        return Err(ApiError::Internal("XX9 未返回可播放分集".into()));
    }
    Ok(json!({
        "id": vod_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis.trim_end().to_string(),
        "extra": {},
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let resp = api(
        "cms/vod/search",
        2,
        None,
        Some(json!({
            "keyword": query,
            "page": 1,
            "pageSize": 20,
            "explore": 0,
            "sortType": 0,
        })),
    )
    .await?;
    let items = match get(&resp, "data").and_then(arr_of) {
        Some(rows) => cards(rows),
        None => Vec::new(),
    };
    Ok(json!({"items": items}))
}

fn join_line(line: &str, addr: &str) -> String {
    if addr.starts_with("http") {
        return addr.to_string();
    }
    let line = line.trim_end_matches('/');
    if let Some(rest) = addr.strip_prefix('/') {
        format!("{line}/{rest}")
    } else {
        format!("{line}/{addr}")
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        return Ok(json!({"url": video_id}));
    }
    let (vod_id, line_idx) = if let Some(rest) = video_id.strip_prefix("v:") {
        match rest.rsplit_once(':') {
            Some((id, idx)) => (id.to_string(), idx.parse::<usize>().unwrap_or(0)),
            None => (rest.to_string(), 0),
        }
    } else {
        (video_id.to_string(), 0)
    };
    let vod = fetch_vod(&vod_id).await?;
    let addr = detail_addr(&vod);
    if addr.is_empty() {
        return Err(ApiError::Internal("XX9 未返回播放地址".into()));
    }
    let lines = play_lines().await;
    let line = lines
        .get(line_idx)
        .map(|(_, l)| l.clone())
        .unwrap_or_else(|| LINE_DEFAULT.to_string());
    Ok(json!({"url": join_line(&line, &addr)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ecb_known_vector() {
        let key = hex::decode("000102030405060708090a0b0c0d0e0f").unwrap();
        let plain = hex::decode("00112233445566778899aabbccddeeff").unwrap();
        let cipher = aes_ecb_encrypt(&plain, &key);
        assert_eq!(cipher.len(), 32);
        assert_eq!(
            hex::encode(&cipher[..16]),
            "69c4e0d86a7b0430d8cdb78070b4c55a"
        );
        let back = aes_ecb_decrypt(&cipher, &key).unwrap();
        assert_eq!(back, plain);
    }

    #[test]
    fn enc_dec_json_roundtrip() {
        let obj = json!({"method": 1, "params": Value::Null, "uri": "app/jwt-token"});
        let enc = enc_json(&obj, KEYS[0]).unwrap();
        let dec = dec_json(&enc, KEYS[0]).unwrap();
        assert_eq!(dec, obj);
        assert!(dec_json(&enc, KEYS[1]).is_err());
    }

    #[test]
    fn jwt_exp_reads_payload() {
        let payload = base64::engine::general_purpose::URL_SAFE.encode(r#"{"exp":1793952473}"#);
        let token = format!("aaa.{payload}.bbb");
        assert_eq!(jwt_exp_secs(&token), 1793952473);
        assert_eq!(jwt_exp_secs("not-a-jwt"), 3600);
    }

    #[test]
    fn card_remark_free_and_vip() {
        let free = json!({"id": "1", "title": "t", "vodDuration": 49, "gold": 0, "isVip": false});
        assert_eq!(card_remark(&free), "49 分钟 · 免费直取");
        let vip = json!({"id": "1", "title": "t", "vodDuration": 49, "gold": 0, "isVip": true});
        assert_eq!(card_remark(&vip), "49 分钟 · VIP");
        let no_dur = json!({"id": "1", "title": "t", "vodDuration": 0, "gold": 0, "isVip": false});
        assert_eq!(card_remark(&no_dur), "免费直取");
    }

    #[test]
    fn categories_skip_loli_groups() {
        let pkgs = json!([
            {"id": 1, "name": "国产精选", "groups": [
                {"id": 7, "groupName": "国产街拍街顶"},
                {"id": 3, "groupName": "国产JK萝莉"},
            ]},
            {"id": 3, "name": "欧美精选", "groups": [
                {"id": 26, "groupName": "欧美萝莉cos"},
                {"id": 29, "groupName": "欧美大厂剧情"},
            ]},
        ]);
        let list = categories_from_packages(pkgs.as_array().unwrap());
        let ids: Vec<String> = list
            .iter()
            .map(|c| c["id"].as_str().unwrap_or_default().to_string())
            .collect();
        assert!(ids.contains(&"g1".to_string()));
        assert!(ids.contains(&"s7".to_string()));
        assert!(ids.contains(&"s29".to_string()));
        assert!(!ids.contains(&"s3".to_string()));
        assert!(!ids.contains(&"s26".to_string()));
    }

    #[test]
    fn join_line_forms() {
        assert_eq!(
            join_line("https://allmusiclub.almusiclub.com", "/2026/a/index.m3u8"),
            "https://allmusiclub.almusiclub.com/2026/a/index.m3u8"
        );
        assert_eq!(
            join_line("https://allmusiclub.almusiclub.com/", "2026/a/index.m3u8"),
            "https://allmusiclub.almusiclub.com/2026/a/index.m3u8"
        );
        assert_eq!(
            join_line("https://allmusiclub.almusiclub.com", "https://x/y.m3u8"),
            "https://x/y.m3u8"
        );
    }

    #[test]
    fn detail_addr_prefers_first_entry() {
        let vod = json!({
            "vodFullPlayUrl": [{"addr": "/2026/a/index.m3u8", "type": "高清"}],
            "newAddr": "/2026/b/index.m3u8",
        });
        assert_eq!(detail_addr(&vod), "/2026/a/index.m3u8");
        let vod2 = json!({"vodFullPlayUrl": [], "newAddr": "/2026/b/index.m3u8"});
        assert_eq!(detail_addr(&vod2), "/2026/b/index.m3u8");
        let vod3 = json!({"vodFullPlayUrl": "https://x/y.m3u8"});
        assert_eq!(detail_addr(&vod3), "https://x/y.m3u8");
    }
}
