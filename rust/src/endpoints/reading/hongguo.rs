//! 红果听书（hongguoduanju.com，番茄系主流有声，非成人）。
//!
//! 只译听书一侧（py 里 type_id=audio 的分支）：书城 tab=5 扫听书卡、
//! audio/detail + toneinfo + directory/all_items 取书与分集、取流给
//! hg_audio 标记地址。视频短剧、小说正文、搜索（py searchContent 只
//! 搜短剧）都不在此模块；search 按扫描卡片标题/作者子串过滤（与听
//! 友 search 同款做法，py 本无听书搜索接口）。
//!
//! 签名栈照搬 py（_params_74332、_get_params_encrypturl、变体 RC4、
//! Gorgon、Helios、SM3、Medusa protobuf 与 xmxor 流程、get_key_hash
//! 均已移植；hash_f13 三分支（2679-2931 行）与 AES_V3 定制 AES
//! （2291-2477 行，带 con 换位）亦已移植，medusa 外层帧走 AES_V3
//! 加密；device_id/install_id 初始为进程随机 18 位数（py
//! Spider.__init__ 的回退行为），首次请求前 _ensure_registered
//! 试一次 _hg_register_device（py 3892 行起）换下发号，失败仍用
//! 随机号且不再重试（与 py 一致）。
//!
//! 取流：py 的音频并非直链，而是 playurl 接口给加密地址 main_url +
//! encryption_key，整文件下载后 CENC 解密（_parse_track 526-613 行、
//! decrypt_mp4_cenc 639-711 行、derive_content_key 487-511 行、
//! _sample_table 856-896 行均已移植）再经本地中继播出；核心 play
//! 返回 hg_audio:书:集:音色 标记，分发须把标记改写成核心中继路由
//! 地址（见 reading/mod.rs 的 handle_hg_audio），中继回整文件
//! audio/mp4（3 条音频缓存）。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use md5::{Digest, Md5};
use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::endpoints::drama::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of,
};
use crate::error::{ApiError, ApiResult};

const APP_UA: &str =
    "com.phoenix.read/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)";
const BOOKMALL_TAB_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/bookmall/tab/v";
const AUDIO_DETAIL_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/audio/detail/";
const TONEINFO_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/audio/toneinfo/";
const DIRECTORY_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/directory/all_items/v";
const PLAYURL_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/audio/playurl/";
const MEDUSA_CONFIG_KEY: &[u8] = b"\xf1Y3vvn\xa9\x8d4\xf3\x1b\x05z\x9d[\xe4";
const MEDUSA_CONFIG_IV: [u8; 16] = *b"\x1f\xe1\t\xa4\x12R\x83\xf4\x18\xde\x9e\x05\x1a\x96\x9e\x12";
const MEDUSA_SIGN_KEY: &[u8] = b"\x8e\xbd\xfa8\x06\xec\xc5\xce\xe7\x94#\xe6\x02\x9e\xd8%@\xbc\"\x18\xbb~\xae\xf7\x1c\xb6\x91\xf7\xaa\x8a\xa2\xf5";
const MEDUSA_MAGIC: &[u8] = b"\xf7\xe8_\xfa\xd7\xd7\xdc;\xd6*\xc8pW\xcfa\x18";
const MEDUSA_VERSION: &[u8] =
    b"\x03\x00\x00\x00\xf7\xe8\x5f\xfa\xd7\xd7\xdc\x3b\xd6\x2a\xc8\x70\x57\xcf\x61\x18";

static NONCE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// 随机 18 位设备号（py Spider.__init__ 的回退行为：device_id 与
/// install_id 各一个 18 位数）。
fn random_device_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut x = nanos
        ^ (std::process::id() as u64) << 32
        ^ NONCE_COUNTER
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_mul(0x9e3779b97f4a7c15);
    x ^= x >> 30;
    x = x.wrapping_mul(0xbf58476d1ce4e5b9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94d049bb133111eb);
    x ^= x >> 31;
    (100_000_000_000_000_000u64 + x % 900_000_000_000_000_000u64).to_string()
}

/// 设备状态（py Spider 的 device_id / install_id / _device_registered /
/// _device_limited / _device_renew_cooldown_until）：进程级，首次请求前
/// ensure_registered 会试一次服务端注册，成功则换成下发的号，失败仍用
/// 随机号（与 py 回退行为一致）；注册后不再重复试，除非被标记受限。
struct DeviceState {
    device_id: String,
    install_id: String,
    registered: bool,
    limited: bool,
    renew_cooldown_until: i64,
}

static DEVICE_STATE: Lazy<Mutex<DeviceState>> = Lazy::new(|| {
    Mutex::new(DeviceState {
        device_id: random_device_id(),
        install_id: random_device_id(),
        registered: false,
        limited: false,
        renew_cooldown_until: 0,
    })
});

fn current_devices() -> (String, String) {
    let st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
    (st.device_id.clone(), st.install_id.clone())
}

static SCAN_CACHE: Lazy<Mutex<Option<(Vec<Value>, HashMap<String, String>)>>> =
    Lazy::new(|| Mutex::new(None));

/// 无 rand 依赖的伪随机：时间 + 进程 + 计数器过 splitmix64。
static TEST_NEXT_U64_QUEUE: std::sync::Mutex<std::collections::VecDeque<u64>> =
    std::sync::Mutex::new(std::collections::VecDeque::new());
static TEST_NOW_SECS_OVERRIDE: std::sync::Mutex<Option<i64>> = std::sync::Mutex::new(None);
static TEST_PRINT_PROTO: std::sync::Mutex<bool> = std::sync::Mutex::new(false);

fn next_u64() -> u64 {
    if let Ok(mut q) = TEST_NEXT_U64_QUEUE.lock() {
        if let Some(v) = q.pop_front() {
            return v;
        }
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut x = nanos
        ^ (std::process::id() as u64).rotate_left(32)
        ^ NONCE_COUNTER
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_mul(0x9e3779b97f4a7c15);
    x ^= x >> 30;
    x = x.wrapping_mul(0xbf58476d1ce4e5b9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94d049bb133111eb);
    x ^= x >> 31;
    x
}

fn now_secs() -> i64 {
    if let Ok(guard) = TEST_NOW_SECS_OVERRIDE.lock() {
        if let Some(v) = *guard {
            return v;
        }
    }
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// py _params_74332：固定设备/应用参数，extra 覆盖或追加（保序）。
fn params_74332(extra: &[(&str, &str)]) -> Vec<(String, String)> {
    let (device_id, install_id) = current_devices();
    let mut params: Vec<(String, String)> = [
        ("iid", install_id.as_str()),
        ("device_id", device_id.as_str()),
        ("ac", "wifi"),
        ("channel", "update_64"),
        ("aid", "8662"),
        ("app_name", "novelread"),
        ("version_code", "74332"),
        ("version_name", "7.4.3.32"),
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("device_type", "25053RT47C"),
        ("device_brand", "Redmi"),
        ("language", "zh"),
        ("os_api", "36"),
        ("os_version", "16"),
        ("manifest_version_code", "74332"),
        ("resolution", "1280*2772"),
        ("dpi", "520"),
        ("update_version_code", "74332"),
        ("host_abi", "arm64-v8a"),
        ("dragon_device_type", "phone"),
        ("pv_player", "74332"),
        ("compliance_status", "0"),
        ("need_personal_recommend", "1"),
        ("player_so_load", "1"),
        ("is_android_pad_screen", "0"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();
    for (k, v) in extra {
        if let Some(slot) = params.iter_mut().find(|(ek, _)| ek == k) {
            slot.1 = v.to_string();
        } else {
            params.push((k.to_string(), v.to_string()));
        }
    }
    params
}

/// py _url_encode：urlencode 后 + → %20、%2A → *（即空格 %20、* 不转）。
fn url_encode(params: &[(String, String)]) -> String {
    let mut parts = Vec::new();
    for (k, v) in params {
        let enc = |s: &str| -> String {
            let mut out = String::new();
            for &b in s.as_bytes() {
                let c = b as char;
                if c.is_ascii_alphanumeric() || "-_.~".contains(c) {
                    out.push(c);
                } else if c == ' ' {
                    out.push_str("%20");
                } else if c == '*' {
                    out.push('*');
                } else {
                    out.push_str(&format!("%{b:02X}"));
                }
            }
            out
        };
        parts.push(format!("{}={}", enc(k), enc(v)));
    }
    parts.join("&")
}

/// py _get_params_encrypturl：devices 覆盖同名参数，追加 ts 与 _rticket。
fn params_encrypturl(url: &str, params: &[(String, String)]) -> (String, Vec<(String, String)>) {
    let mut result = params.to_vec();
    let (device_id, install_id) = current_devices();
    let dev_pairs = [
        ("device_id", device_id.as_str()),
        ("iid", install_id.as_str()),
        ("install_id", install_id.as_str()),
    ];
    for (k, v) in dev_pairs {
        if let Some(slot) = result.iter_mut().find(|(ek, _)| ek == k) {
            slot.1 = v.to_string();
        }
    }
    let now = now_secs();
    result.push(("ts".to_string(), now.to_string()));
    result.push(("_rticket".to_string(), (now * 1000).to_string()));
    let base = url.split('?').next().unwrap_or(url);
    (format!("{base}?{}", url_encode(&result)), result)
}

/// py _json_body_md5：无 body 为空串；JSON 体按紧凑格式取 md5 大写 hex。
fn json_body_md5(body: Option<&Value>, data_type: &str) -> String {
    let raw: Vec<u8> = match body {
        None => return String::new(),
        Some(Value::String(s)) => s.as_bytes().to_vec(),
        Some(v) if data_type == "application/json; charset=UTF-8" => {
            serde_json::to_string(v).unwrap_or_default().into_bytes()
        }
        Some(v) => url_encode(
            &v.as_object()
                .map(|m| {
                    m.iter()
                        .map(|(k, val)| {
                            (
                                k.clone(),
                                match val {
                                    Value::String(s) => s.clone(),
                                    other => other.to_string(),
                                },
                            )
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default(),
        )
        .into_bytes(),
    };
    format!("{:X}", Md5::digest(&raw))
}

/// py _xg_rc4：注意这是变体 RC4——KSA 只写 table[i]=table[j] 不交换，
/// PRGA 同样只写 table[i]=y 不交换，密钥流下标取 (y+y)&0xFF。
fn xg_rc4(data: &[u8], key: &[u8]) -> Vec<u8> {
    let mut table: Vec<u8> = (0..=255u8).collect();
    let mut j = 0usize;
    for i in 0..256 {
        j = (j + table[i] as usize + key[i % key.len()] as usize) % 256;
        table[i] = table[j];
    }
    let mut i = 0usize;
    j = 0;
    let mut out = Vec::with_capacity(data.len());
    for &value in data {
        i = (i + 1) & 0xFF;
        let x = table[i];
        j = (j + x as usize) & 0xFF;
        let y = table[j];
        table[i] = y;
        out.push(value ^ table[((y as usize + y as usize) & 0xFF)]);
    }
    out
}

/// py _reverse_bits：8 位倒序。
fn reverse_bits(value: u8) -> u8 {
    value.reverse_bits()
}

/// py _encrypt_gorgon：md5(query) 前 4 字节 + 体 md5 前 4 字节（无体则
/// 4 个 0）+ 4 个 0 + 67503104 小端 + khronos 大端，过变体 RC4 再逐
/// 字节高低半字节互换、与后一字节异或、倒序、取反、异或 20。
fn encrypt_gorgon(
    body: Option<&Value>,
    query: &str,
    khronos: i64,
    xg_rand: u16,
    data_type: &str,
) -> String {
    let body_md5 = body
        .map(|b| json_body_md5(Some(b), data_type).to_lowercase())
        .unwrap_or_default();
    let mut data = Vec::new();
    data.extend_from_slice(&Md5::digest(query.as_bytes())[..4]);
    if body_md5.is_empty() {
        data.extend_from_slice(&[0u8; 4]);
    } else {
        let raw = hex::decode(&body_md5).unwrap_or_default();
        data.extend_from_slice(&raw[..4.min(raw.len())]);
    }
    data.extend_from_slice(&[0u8; 4]);
    data.extend_from_slice(&67503104u32.to_le_bytes());
    data.extend_from_slice(&(khronos as u32).to_be_bytes());
    let key = [
        0x4A,
        0x40,
        0x16,
        (xg_rand >> 8) as u8,
        0x47,
        0x6C,
        0x01,
        (xg_rand & 0xFF) as u8,
    ];
    let mut result = xg_rc4(&data, &key);
    for index in 0..result.len() {
        let value = result[index].rotate_left(4);
        let following = if index + 1 < result.len() {
            result[index + 1]
        } else {
            result[0]
        };
        result[index] = (!(reverse_bits(following ^ value) ^ 20)) & 0xFF;
    }
    let mut out = vec![0x84u8, 0x04];
    out.extend_from_slice(&xg_rand.to_le_bytes());
    out.extend_from_slice(&320u16.to_le_bytes());
    out.extend_from_slice(&result);
    hex::encode(out)
}

fn ror64(value: u64, count: u64) -> u64 {
    let count = count % 64;
    if count == 0 {
        value
    } else {
        (value >> count) | (value << (64 - count))
    }
}

/// py _encrypt_helios：md5 种子派生表 + 34 轮 Feistel（常量与 py 一致）。
fn encrypt_helios(khronos: i64, rand_value: u32) -> String {
    use base64::Engine as _;
    let value = if rand_value != 0 {
        rand_value
    } else {
        next_u64() as u32
    };
    let mut seed = value.to_le_bytes().to_vec();
    seed.extend_from_slice(b"8662");
    let digest = Md5::digest(&seed);
    let keys: Vec<u8> = digest
        .iter()
        .flat_map(|b| format!("{b:02x}").into_bytes())
        .collect();
    let mut table: Vec<u64> = vec![u64::from_le_bytes(keys[0..8].try_into().unwrap())];
    let mut words: Vec<u64> = (0..4)
        .map(|i| u64::from_le_bytes(keys[i * 8..i * 8 + 8].try_into().unwrap()))
        .collect();
    let mut first = words[0];
    let mut second = words[1];
    words = words[2..].to_vec();
    for index in 0..0x22u64 {
        let mut value2 = ror64(second, 8);
        value2 = value2.wrapping_add(first);
        value2 ^= index;
        words.push(value2);
        value2 ^= ror64(first, 61);
        table.push(value2);
        first = value2;
        second = words.remove(0);
    }
    let raw = format!("{khronos}-1588093228-8662").into_bytes();
    let pad = 16 - raw.len() % 16;
    let mut padded = raw.clone();
    padded.extend(std::iter::repeat(pad as u8).take(pad));
    let mut output = Vec::new();
    for chunk in padded.chunks_exact(16) {
        let mut left = u64::from_le_bytes(chunk[0..8].try_into().unwrap());
        let mut right = u64::from_le_bytes(chunk[8..16].try_into().unwrap());
        for index in 0..0x22usize {
            right = table[index] ^ (left.wrapping_add(ror64(right, 8)));
            left = right ^ ror64(left, 61);
        }
        output.extend_from_slice(&left.to_le_bytes());
        output.extend_from_slice(&right.to_le_bytes());
    }
    let mut prefixed = value.to_le_bytes().to_vec();
    prefixed.extend_from_slice(&output);
    base64::engine::general_purpose::STANDARD.encode(prefixed)
}

/// 标准 SM3（py 用库 SM3，与标准一致；含 abc 向量自测见 tests）。
fn sm3(data: &[u8]) -> [u8; 32] {
    const IV: [u32; 8] = [
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d,
        0xb0fb0e4e,
    ];
    fn t(j: usize) -> u32 {
        if j < 16 {
            0x79cc4519
        } else {
            0x7a879d8a
        }
    }
    fn ff(x: u32, y: u32, z: u32, j: usize) -> u32 {
        if j < 16 {
            x ^ y ^ z
        } else {
            (x & y) | (x & z) | (y & z)
        }
    }
    fn gg(x: u32, y: u32, z: u32, j: usize) -> u32 {
        if j < 16 {
            x ^ y ^ z
        } else {
            (x & y) | (!x & z)
        }
    }
    fn p0(x: u32) -> u32 {
        x ^ x.rotate_left(9) ^ x.rotate_left(17)
    }
    fn p1(x: u32) -> u32 {
        x ^ x.rotate_left(15) ^ x.rotate_left(23)
    }
    let bitlen = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    let mut v = IV;
    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 68];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for j in 16..68 {
            w[j] = p1(w[j - 16] ^ w[j - 9] ^ w[j - 3].rotate_left(15))
                ^ w[j - 13].rotate_left(7)
                ^ w[j - 6];
        }
        let mut w1 = [0u32; 64];
        for j in 0..64 {
            w1[j] = w[j] ^ w[j + 4];
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h) =
            (v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
        for j in 0..64 {
            let ss1 = a
                .rotate_left(12)
                .wrapping_add(e)
                .wrapping_add(t(j).rotate_left(j as u32 % 32))
                .rotate_left(7);
            let ss2 = ss1 ^ a.rotate_left(12);
            let tt1 = ff(a, b, c, j)
                .wrapping_add(d)
                .wrapping_add(ss2)
                .wrapping_add(w1[j]);
            let tt2 = gg(e, f, g, j)
                .wrapping_add(h)
                .wrapping_add(ss1)
                .wrapping_add(w[j]);
            d = c;
            c = b.rotate_left(9);
            b = a;
            a = tt1;
            h = g;
            g = f.rotate_left(19);
            f = e;
            e = p0(tt2);
        }
        v[0] ^= a;
        v[1] ^= b;
        v[2] ^= c;
        v[3] ^= d;
        v[4] ^= e;
        v[5] ^= f;
        v[6] ^= g;
        v[7] ^= h;
    }
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[i * 4..i * 4 + 4].copy_from_slice(&v[i].to_be_bytes());
    }
    out
}

/// py _proto_field：空/0/False 一律省略；sint 走 zigzag varint。
enum ProtoField {
    SInt32(i64),
    SInt64(i64),
    Float(f32),
    Bytes(Vec<u8>),
    Str(String),
    Msg(Vec<u8>),
}

fn varint(mut v: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
        }
        out.push(b);
        if v == 0 {
            break;
        }
    }
    out
}

fn zigzag(v: i64, bits: u32) -> u64 {
    if bits == 32 {
        ((v << 1) ^ (v >> 31)) as u32 as u64
    } else {
        ((v << 1) ^ (v >> 63)) as u64
    }
}

fn proto_field(field: u64, value: &ProtoField) -> Vec<u8> {
    let mut out = Vec::new();
    match value {
        ProtoField::SInt32(v) => {
            if *v == 0 {
                return out;
            }
            out.extend(varint((field << 3) | 0));
            out.extend(varint(zigzag(*v, 32)));
        }
        ProtoField::SInt64(v) => {
            if *v == 0 {
                return out;
            }
            out.extend(varint((field << 3) | 0));
            out.extend(varint(zigzag(*v, 64)));
        }
        ProtoField::Float(v) => {
            if *v == 0.0 {
                return out;
            }
            out.extend(varint((field << 3) | 5));
            out.extend_from_slice(&v.to_le_bytes());
        }
        ProtoField::Bytes(b) => {
            if b.is_empty() {
                return out;
            }
            out.extend(varint((field << 3) | 2));
            out.extend(varint(b.len() as u64));
            out.extend_from_slice(b);
        }
        ProtoField::Str(s) => {
            if s.is_empty() {
                return out;
            }
            out.extend(varint((field << 3) | 2));
            out.extend(varint(s.len() as u64));
            out.extend_from_slice(s.as_bytes());
        }
        ProtoField::Msg(m) => {
            if m.is_empty() {
                return out;
            }
            out.extend(varint((field << 3) | 2));
            out.extend(varint(m.len() as u64));
            out.extend_from_slice(m);
        }
    }
    out
}

fn proto(fields: &[(u64, ProtoField)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (f, v) in fields {
        out.extend(proto_field(*f, v));
    }
    out
}

/// py _encode_request：固定 4 个字段。
fn encode_request() -> Vec<u8> {
    proto(&[
        (1, ProtoField::SInt32(111)),
        (2, ProtoField::SInt32(10)),
        (3, ProtoField::SInt32(694367)),
        (5, ProtoField::SInt32(586952199)),
    ])
}

/// py _encode_device：字段 1-40，值取自 medusa device 字典（见 medusa_proto）。
#[allow(clippy::too_many_arguments)]
fn encode_device(
    device_id: &str,
    sec_device_token: &str,
    os_version: &str,
    report_ts: i64,
    device_model: &str,
    brand: &str,
    manufacturer: &str,
) -> Vec<u8> {
    proto(&[
        (1, ProtoField::SInt32(1)),
        (2, ProtoField::SInt32(2)),
        (3, ProtoField::Str("8662".to_string())),
        (4, ProtoField::Str(device_id.to_string())),
        (5, ProtoField::Str(sec_device_token.to_string())),
        (6, ProtoField::Str("!noperm!".to_string())),
        (7, ProtoField::SInt32(-888888)),
        (8, ProtoField::SInt32(-888888)),
        (9, ProtoField::SInt32(3)),
        (10, ProtoField::SInt32(-888888)),
        (11, ProtoField::Str("!notset!".to_string())),
        (12, ProtoField::Str("Asia/Shanghai,8".to_string())),
        (13, ProtoField::Str("zh_CN".to_string())),
        (14, ProtoField::SInt32(4)),
        (16, ProtoField::Float(255.24993896484375)),
        (17, ProtoField::Float(35.58599090576172)),
        (18, ProtoField::Float(3.467449188232422)),
        (19, ProtoField::Float(3.467449188232422)),
        (20, ProtoField::Float(255.1754913330078)),
        (21, ProtoField::Float(42.17544174194336)),
        (22, ProtoField::Str(os_version.to_string())),
        (23, ProtoField::SInt32(41)),
        (24, ProtoField::SInt32(36)),
        (25, ProtoField::SInt64(report_ts)),
        (26, ProtoField::SInt64(report_ts)),
        (27, ProtoField::SInt64(report_ts)),
        (28, ProtoField::SInt64(report_ts + 2)),
        (29, ProtoField::SInt32(-1)),
        (30, ProtoField::Str(device_model.to_string())),
        (31, ProtoField::Str(brand.to_string())),
        (32, ProtoField::Str(device_model.to_string())),
        (33, ProtoField::Str(device_model.to_string())),
        (34, ProtoField::Str(manufacturer.to_string())),
        (35, ProtoField::Str(brand.to_string())),
        (36, ProtoField::Str(brand.to_string())),
        (38, ProtoField::SInt32(31)),
        (40, ProtoField::SInt32(0)),
    ])
}

/// py _encode_env：字段见 py（report 里 times/unknown6 为 0 故被省略）。
fn encode_env(
    launch_time: i64,
    pid: i64,
    device_msg: Vec<u8>,
    report_time: i64,
    app_version: &str,
) -> Vec<u8> {
    let report = proto(&[
        (1, ProtoField::SInt64(report_time)),
        (2, ProtoField::SInt32(-2)),
        (4, ProtoField::SInt32(200)),
        (5, ProtoField::SInt32(0)),
        (6, ProtoField::SInt32(0)),
    ]);
    proto(&[
        (1, ProtoField::SInt32(launch_time)),
        (2, ProtoField::SInt32(146331399)),
        (3, ProtoField::SInt32(146331396)),
        (5, ProtoField::SInt32(7)),
        (6, ProtoField::Str("v04.06.04.03-bugfix".to_string())),
        (7, ProtoField::SInt32(pid)),
        (12, ProtoField::Msg(device_msg)),
        (13, ProtoField::Msg(report)),
        (14, ProtoField::Str(app_version.to_string())),
        (15, ProtoField::SInt32(0)),
        (16, ProtoField::SInt32(0)),
        (18, ProtoField::SInt32(0)),
        (19, ProtoField::SInt32(0)),
        (20, ProtoField::SInt32(0)),
        (21, ProtoField::SInt32(0)),
    ])
}

fn rl8(x: u8, k: u8) -> u8 {
    let s = (k & 7) as u16;
    (((x as u16) << s) | ((x as u16) >> (8 - s))) as u8
}

/// py _xmxor_two：逐字节用 key[(i*4)&28] 与下一字节混淆，结果倒序写回。
fn xmxor_two(data: &[u8], key: &[u8]) -> Vec<u8> {
    let mut encoded = vec![0u8; data.len()];
    for (index, &value) in data.iter().enumerate() {
        let position = (index * 4) & 28;
        let d0 = key[position];
        let d1 = key[position + 1];
        let mut d2 = rl8(value, 4).wrapping_add(d0) ^ d1;
        d2 = rl8(!d2, 3);
        d2 = d2.wrapping_add(d1) ^ d0;
        encoded[data.len() - 1 - index] = !d2;
    }
    encoded
}

fn xmxor(data: &[u8], key: &[u8]) -> Vec<u8> {
    let mut value = xmxor_two(data, key);
    if value.len() < 3 {
        return value;
    }
    let last_flag = value[value.len() - 1] ^ value[value.len() - 2];
    let data0 = value[0];
    value[0] = (!last_flag).wrapping_add(value[0]);
    value[1] = (value[0] ^ value[value.len() - 1] ^ 254).wrapping_add(value[1]);
    value[2] = value[2].wrapping_add(last_flag.wrapping_sub(data0) ^ rl8(value[1], 3) ^ 2);
    let n = value.len();
    for index in 0..n.saturating_sub(4) {
        let temp = rl8(value[index + 2], 3) ^ value[index + 1] ^ ((index + 3) as u8);
        value[index + 3] = (!temp).wrapping_add(value[index + 3]);
    }
    value[n - 1] ^= value[n - 2];
    let sum: u32 = value.iter().skip(1).map(|&b| b as u32).sum();
    value[0] = (((value[0] ^ value[1]) as u32 + sum) & 0xFF) as u8;
    value
}

/// py get_key_hash：68 字节 to_hash = key32 + rand 小端 + key32 的
/// SM3 摘要；seed d2 由 rand 派生（与 py 逐行一致，已读 2158-2170）。
fn get_key_hash(key: &[u8], rand: u32) -> ([u8; 32], [u8; 4]) {
    let mut to_hash = Vec::new();
    to_hash.extend_from_slice(key);
    to_hash.extend_from_slice(&rand.to_le_bytes());
    to_hash.extend_from_slice(key);
    let digest = sm3(&to_hash);
    let d1 = (rand >> 16) & 0xFF;
    let mut d2 = (d1 << 11) | (rand >> 24);
    d2 ^= (d1 >> 5) ^ d1;
    d2 = !d2 & 0xFFFF_FFFF;
    (digest, d2.to_le_bytes())
}

// branch_0 tables
const BRANCH0_TT01: [u32; 6] = [
    0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1,
];

const BRANCH0_TT02: [u32; 64] = [
    0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
    0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
    0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
    0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
    0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
    0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
    0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
    0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
];

const BRANCH0_INIT: [u32; 8] = [
    0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 0x3aab4d10, 0xb31d643a, 0xab4fabed, 0x804b3850,
];

const BRANCH1_TT1A: [u32; 5] = [0x808a9c79, 0xf079807e, 0xbadf79c5, 0xa785d3ff, 0x82d8438c];

const BRANCH1_ORDERS: [u8; 48] = [
    0x05, 0x07, 0x01, 0x02, 0x04, 0x00, 0x06, 0x03, 0x00, 0x05, 0x02, 0x04, 0x01, 0x03, 0x07, 0x06,
    0x05, 0x07, 0x02, 0x04, 0x01, 0x06, 0x03, 0x00, 0x03, 0x00, 0x02, 0x04, 0x06, 0x07, 0x01, 0x05,
    0x04, 0x05, 0x00, 0x03, 0x06, 0x02, 0x01, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

const BRANCH1_TT1B: [u64; 11] = [
    0x87aeea5dab37cd6b,
    0x7ff48becb4f54087,
    0xb0724c06706bbd5d,
    0x1fe5dfb1143e328d,
    0x1a2331d00af4f1f2,
    0xcaff7131bb1e71ba,
    0x33385e1042752218,
    0xff01ed65d4a441fb,
    0x0adb1ec8828c80e8,
    0x62475d12f4e06fe7,
    0x00bd0b238da4fe72,
];

const BRANCH2_T001: [u32; 5] = [0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4];

const BRANCH2_ORDERS: [u8; 320] = [
    0x0f, 0x07, 0x04, 0x00, 0x09, 0x08, 0x03, 0x0a, 0x06, 0x0b, 0x05, 0x0d, 0x0e, 0x01, 0x0c, 0x02,
    0x0f, 0x05, 0x08, 0x0c, 0x00, 0x09, 0x02, 0x01, 0x03, 0x07, 0x0e, 0x06, 0x0b, 0x0a, 0x0d, 0x04,
    0x06, 0x05, 0x00, 0x07, 0x0c, 0x00, 0x0a, 0x04, 0x08, 0x0f, 0x01, 0x0b, 0x0d, 0x09, 0x02, 0x0e,
    0x06, 0x0b, 0x02, 0x05, 0x04, 0x03, 0x08, 0x01, 0x01, 0x07, 0x0a, 0x00, 0x0d, 0x0c, 0x09, 0x0e,
    0x0d, 0x07, 0x0e, 0x0f, 0x0b, 0x02, 0x08, 0x03, 0x0c, 0x05, 0x09, 0x01, 0x00, 0x04, 0x06, 0x0a,
    0x0d, 0x09, 0x02, 0x06, 0x0f, 0x0b, 0x0a, 0x04, 0x08, 0x07, 0x00, 0x0c, 0x05, 0x03, 0x01, 0x0e,
    0x0c, 0x09, 0x0f, 0x07, 0x06, 0x0f, 0x03, 0x0e, 0x02, 0x0d, 0x04, 0x05, 0x01, 0x0b, 0x0a, 0x00,
    0x0c, 0x05, 0x0a, 0x09, 0x0e, 0x08, 0x02, 0x04, 0x04, 0x07, 0x03, 0x0f, 0x01, 0x06, 0x0b, 0x00,
    0x0b, 0x0f, 0x04, 0x08, 0x02, 0x0a, 0x07, 0x00, 0x09, 0x0d, 0x06, 0x01, 0x0e, 0x03, 0x05, 0x0c,
    0x0b, 0x06, 0x0a, 0x05, 0x08, 0x02, 0x0c, 0x03, 0x07, 0x0f, 0x0e, 0x09, 0x0d, 0x00, 0x01, 0x04,
    0x09, 0x06, 0x08, 0x0f, 0x05, 0x08, 0x00, 0x04, 0x0a, 0x0b, 0x03, 0x0d, 0x01, 0x02, 0x0c, 0x0e,
    0x09, 0x0d, 0x0c, 0x06, 0x04, 0x07, 0x0a, 0x03, 0x03, 0x0f, 0x00, 0x08, 0x01, 0x05, 0x02, 0x0e,
    0x01, 0x00, 0x0d, 0x0f, 0x09, 0x0a, 0x0b, 0x0e, 0x04, 0x02, 0x08, 0x07, 0x03, 0x06, 0x0c, 0x05,
    0x01, 0x08, 0x0a, 0x0c, 0x0f, 0x09, 0x05, 0x06, 0x0b, 0x00, 0x03, 0x04, 0x02, 0x0e, 0x07, 0x0d,
    0x04, 0x08, 0x0f, 0x00, 0x0c, 0x0f, 0x0e, 0x0d, 0x0a, 0x01, 0x06, 0x02, 0x07, 0x09, 0x05, 0x03,
    0x04, 0x02, 0x05, 0x08, 0x0d, 0x0b, 0x0a, 0x06, 0x06, 0x00, 0x0e, 0x0f, 0x07, 0x0c, 0x09, 0x03,
    0x0a, 0x08, 0x04, 0x0f, 0x00, 0x0b, 0x01, 0x06, 0x0d, 0x0c, 0x07, 0x09, 0x03, 0x0e, 0x05, 0x02,
    0x0a, 0x07, 0x0b, 0x05, 0x0f, 0x00, 0x02, 0x0e, 0x01, 0x08, 0x03, 0x0d, 0x0c, 0x06, 0x09, 0x04,
    0x0d, 0x07, 0x0f, 0x08, 0x05, 0x0f, 0x06, 0x04, 0x0b, 0x0a, 0x0e, 0x0c, 0x09, 0x00, 0x02, 0x03,
    0x0d, 0x0c, 0x02, 0x07, 0x04, 0x01, 0x0b, 0x0e, 0x0e, 0x08, 0x06, 0x0f, 0x09, 0x05, 0x00, 0x03,
];

const MD5_SV2: [u32; 64] = [
    0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef, 0xb2bbad73,
    0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64,
    0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e,
    0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28,
    0x66c4ff96, 0x51716443, 0x0dd2fc3b, 0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec,
    0xf4188ecf, 0xf7d793db, 0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754,
    0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da,
    0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7, 0xa5ab26a3,
];

const MD5_START: [u32; 4] = [0x79e0f2fb, 0xc8b52570, 0xebc2f8cd, 0x7c104d93];

const MD5_END: [u32; 4] = [0x19be4866, 0xe85986b4, 0xe19b326e, 0x71d1d7d4];

const AES_S_BOX: [u8; 1024] = [
    0xfa, 0x7d, 0x08, 0x6b, 0x9c, 0x59, 0xb3, 0x4b, 0x04, 0x5f, 0x39, 0xd0, 0x38, 0x4a, 0x91, 0x99,
    0x00, 0x67, 0xa6, 0x20, 0x9f, 0xf5, 0x4d, 0x82, 0x73, 0x26, 0xee, 0xdf, 0x18, 0x66, 0x83, 0x33,
    0x80, 0x03, 0x19, 0xfb, 0xd9, 0xfe, 0xae, 0xaa, 0xa9, 0xb0, 0x52, 0xc6, 0x0b, 0xf3, 0x79, 0x25,
    0x4e, 0x78, 0xb4, 0x36, 0xac, 0x5d, 0x1a, 0x27, 0x9e, 0x88, 0xdb, 0xbd, 0x3c, 0x63, 0xec, 0x49,
    0x15, 0xc1, 0x30, 0x1f, 0xdc, 0xb8, 0x56, 0xd4, 0x6c, 0xcd, 0xca, 0x09, 0x43, 0xc8, 0x35, 0xa3,
    0xef, 0x1e, 0xf4, 0x96, 0xd2, 0xfc, 0x0e, 0x72, 0x7b, 0x94, 0x84, 0xd1, 0xea, 0x45, 0x5a, 0x62,
    0x02, 0x3f, 0xd3, 0x12, 0x81, 0x34, 0x2b, 0xdd, 0x7e, 0xe6, 0x28, 0xf2, 0xa5, 0x46, 0x13, 0x01,
    0x3b, 0x21, 0xf6, 0x61, 0x37, 0x29, 0x2a, 0x0d, 0xed, 0x8c, 0xaf, 0xbf, 0x9d, 0x5c, 0xbb, 0x24,
    0x76, 0x0f, 0x75, 0xe4, 0x53, 0x89, 0xe1, 0x98, 0x8d, 0xb1, 0x9a, 0x65, 0x70, 0x4f, 0x54, 0x4c,
    0x58, 0xab, 0x6e, 0x6f, 0x8b, 0x23, 0xc4, 0x07, 0x11, 0x0c, 0xba, 0xcf, 0xa0, 0xa4, 0x8e, 0xd8,
    0x05, 0x3d, 0x14, 0xb2, 0xda, 0x74, 0xc3, 0xd7, 0xe7, 0xbe, 0xd6, 0x7f, 0xde, 0x48, 0x16, 0x3e,
    0x85, 0x90, 0xa1, 0x55, 0xb7, 0x77, 0x42, 0x22, 0xc9, 0x86, 0x50, 0x2e, 0x17, 0xf9, 0x64, 0x31,
    0x2c, 0x9b, 0xf1, 0x6d, 0x1c, 0x44, 0x68, 0xe3, 0xe9, 0xa8, 0x93, 0x97, 0xcb, 0x32, 0x57, 0xeb,
    0xe5, 0x71, 0x6a, 0xad, 0xc0, 0xcc, 0xc7, 0xc5, 0xfd, 0x60, 0x1d, 0xa2, 0x2d, 0x47, 0xa7, 0xe2,
    0x51, 0x69, 0x5e, 0x7a, 0xce, 0x0a, 0x41, 0xb6, 0x95, 0x8f, 0xf7, 0xb9, 0x87, 0xe0, 0x3a, 0x06,
    0x10, 0x8a, 0xb5, 0xf8, 0x5b, 0xd5, 0xf0, 0xbc, 0x92, 0xff, 0x7c, 0x2f, 0xc2, 0xe8, 0x1b, 0x40,
    0xec, 0x1b, 0xda, 0xbd, 0xba, 0x98, 0x91, 0x0c, 0xb2, 0x2b, 0x83, 0x41, 0x34, 0x67, 0xfb, 0x0a,
    0xd8, 0x76, 0xb5, 0x46, 0x05, 0x59, 0x61, 0x23, 0x75, 0x90, 0x87, 0x2a, 0xe3, 0x50, 0x15, 0x4c,
    0xac, 0xb1, 0x79, 0xeb, 0xae, 0xe5, 0x95, 0x47, 0x04, 0x68, 0xf0, 0x86, 0x3d, 0x51, 0x8b, 0x0f,
    0xca, 0x8e, 0xe4, 0xb9, 0x4e, 0xf2, 0x12, 0x82, 0xbc, 0x0e, 0xd5, 0xf7, 0xef, 0x28, 0x25, 0xcf,
    0x5b, 0x5d, 0xe9, 0x6a, 0x55, 0x02, 0xe1, 0x33, 0xbe, 0x93, 0xe7, 0xf5, 0xad, 0x9d, 0x3e, 0x39,
    0x24, 0xa8, 0xe2, 0xfa, 0x17, 0x57, 0xd0, 0x7a, 0x0d, 0x08, 0x30, 0xd6, 0xb8, 0xa3, 0x8d, 0xfd,
    0x07, 0x9a, 0xc4, 0x1e, 0x6e, 0x22, 0x64, 0x97, 0xd2, 0x1d, 0xb0, 0xbf, 0x45, 0x66, 0x3f, 0x6c,
    0xdd, 0xdb, 0x27, 0x80, 0xa7, 0x11, 0xdc, 0xa6, 0xc5, 0x52, 0xf8, 0xc0, 0xb6, 0xc8, 0x5c, 0x00,
    0x73, 0x60, 0x7b, 0xa0, 0x19, 0x13, 0xaa, 0xc9, 0x35, 0x48, 0x4b, 0xd3, 0xa4, 0xcd, 0x9f, 0x99,
    0xf3, 0x10, 0x44, 0x40, 0x54, 0x7e, 0x29, 0xf4, 0x06, 0x1f, 0xa2, 0xab, 0xa1, 0x2f, 0x3c, 0xf6,
    0xaf, 0x85, 0x62, 0x36, 0x21, 0x7f, 0x5e, 0xdf, 0x20, 0x1a, 0xb3, 0xb4, 0xe6, 0xff, 0x72, 0x84,
    0x8f, 0x65, 0x26, 0x94, 0x5a, 0x77, 0xea, 0x43, 0x78, 0xc7, 0x4a, 0xcc, 0x2c, 0x14, 0x6b, 0xc6,
    0xe8, 0x74, 0x53, 0xfc, 0xd4, 0x1c, 0xce, 0x31, 0x70, 0x03, 0x18, 0x8c, 0x96, 0x38, 0x32, 0x89,
    0xf1, 0x3a, 0x5f, 0xd7, 0xf9, 0xa9, 0x69, 0xb7, 0x63, 0x37, 0x58, 0xc2, 0x3b, 0xc3, 0x71, 0xcb,
    0x9e, 0x92, 0x01, 0x8a, 0x0b, 0x4d, 0x88, 0x9b, 0xbb, 0x4f, 0x6d, 0x6f, 0xe0, 0xfe, 0xa5, 0x49,
    0xde, 0x56, 0x16, 0x09, 0xed, 0x9c, 0xc1, 0x2d, 0xee, 0x81, 0x7d, 0xd9, 0x7c, 0xd1, 0x2e, 0x42,
    0x5b, 0x4d, 0xc1, 0xa6, 0x5d, 0xea, 0x44, 0xfd, 0x45, 0x4e, 0x1b, 0xa1, 0x3f, 0xd1, 0x89, 0xe1,
    0x7d, 0x2f, 0xaa, 0xdb, 0xab, 0xad, 0x59, 0xcb, 0xb1, 0xce, 0x9a, 0x28, 0xc9, 0xe0, 0xf6, 0x70,
    0x39, 0x4a, 0xd7, 0xff, 0x30, 0xf5, 0xdd, 0xbc, 0x57, 0x3b, 0x11, 0x8d, 0xb2, 0xee, 0x00, 0xb6,
    0xe6, 0x1a, 0x5a, 0x7c, 0xf9, 0xde, 0xc4, 0xcd, 0x2e, 0x80, 0xbb, 0xb9, 0x4c, 0xa5, 0x9f, 0x84,
    0x08, 0xc6, 0x6f, 0x42, 0x6c, 0xf0, 0x27, 0xe7, 0x8b, 0x3a, 0x9c, 0x51, 0xfb, 0x67, 0x21, 0x75,
    0x41, 0x31, 0xa7, 0xca, 0x20, 0x43, 0x2a, 0xb7, 0xbf, 0xd9, 0x7a, 0xf2, 0xb5, 0xf8, 0x8c, 0x2c,
    0x23, 0x83, 0x4f, 0x8f, 0x60, 0xa0, 0x04, 0x13, 0x37, 0x14, 0xe3, 0x01, 0xc5, 0x63, 0x66, 0x5c,
    0x74, 0x81, 0xdf, 0x58, 0xbd, 0x68, 0x90, 0x3d, 0xd2, 0xb3, 0x34, 0xf4, 0x19, 0x93, 0x32, 0x29,
    0xd6, 0x49, 0xae, 0x0d, 0x4b, 0xd8, 0x07, 0x9e, 0xac, 0x1e, 0x2d, 0x0b, 0x40, 0xb8, 0x72, 0xba,
    0x76, 0x10, 0x71, 0xa8, 0xe4, 0x56, 0x1d, 0x48, 0xfe, 0xe5, 0xc2, 0x47, 0x91, 0xda, 0x87, 0x26,
    0x9d, 0x1f, 0x88, 0x6b, 0xc0, 0x98, 0xbe, 0x25, 0x09, 0x97, 0x33, 0xa3, 0x85, 0x16, 0x5e, 0x7f,
    0xdc, 0x6e, 0x54, 0xe9, 0xf7, 0xa9, 0xc8, 0xe8, 0xc3, 0x77, 0xd0, 0x82, 0x2b, 0xec, 0x02, 0x62,
    0x8a, 0x92, 0x0e, 0x3e, 0xb0, 0x0f, 0x05, 0xf3, 0xf1, 0x96, 0x78, 0x38, 0x86, 0x36, 0x18, 0x3c,
    0x24, 0xcf, 0x0a, 0xb4, 0x53, 0xcc, 0x61, 0x65, 0xa4, 0xc7, 0x94, 0xd5, 0x15, 0x7e, 0x6d, 0xef,
    0x79, 0x22, 0x35, 0x12, 0x6a, 0x8e, 0x52, 0x06, 0x55, 0x7b, 0x46, 0x64, 0x50, 0x95, 0xe2, 0x0c,
    0xed, 0xd3, 0x17, 0x03, 0xa2, 0x9b, 0x99, 0xeb, 0x1c, 0xfc, 0xaf, 0xd4, 0x73, 0x69, 0xfa, 0x5f,
    0xf7, 0x2c, 0x1e, 0xbf, 0xc8, 0xe1, 0xf3, 0x9f, 0x76, 0x80, 0x71, 0x48, 0xaa, 0x94, 0xad, 0x64,
    0xfb, 0x89, 0xc6, 0x60, 0xc3, 0x32, 0xb3, 0x4d, 0xd2, 0xe0, 0x44, 0xdd, 0x5f, 0xa8, 0xb1, 0xc7,
    0x68, 0x23, 0x34, 0xc9, 0x6d, 0x12, 0x7f, 0xb7, 0xeb, 0x15, 0xbe, 0xa9, 0xd1, 0x78, 0x93, 0xa0,
    0x0c, 0x92, 0xa4, 0xd7, 0x47, 0xe3, 0x8a, 0xc2, 0x70, 0xab, 0x26, 0x41, 0x9a, 0x79, 0xa7, 0xd8,
    0x14, 0x85, 0x8f, 0xc0, 0x6f, 0x56, 0xd0, 0x8c, 0x11, 0xb9, 0x2e, 0x3c, 0xe2, 0x9d, 0xcf, 0x0e,
    0xde, 0x03, 0x5d, 0x46, 0x3e, 0xcd, 0x38, 0x43, 0x0f, 0x33, 0x5a, 0xd9, 0x1a, 0x65, 0x6c, 0x22,
    0x3b, 0xfc, 0x30, 0xa6, 0x88, 0xea, 0x37, 0xa2, 0xb4, 0x8d, 0x8e, 0x51, 0x9c, 0xd6, 0x40, 0xee,
    0xf9, 0xf8, 0x84, 0xf4, 0xae, 0x97, 0xe9, 0xca, 0x0a, 0x45, 0x67, 0x57, 0x04, 0x2f, 0x83, 0x5c,
    0xd5, 0xc5, 0xc4, 0x82, 0xb6, 0xa3, 0x91, 0x98, 0x1f, 0x4a, 0xac, 0x96, 0x81, 0x6e, 0xcb, 0x1b,
    0x09, 0x08, 0xaf, 0x18, 0x95, 0x49, 0x7d, 0x54, 0xed, 0xfa, 0x16, 0x31, 0x3a, 0xda, 0xb8, 0x66,
    0xf5, 0xa5, 0xf1, 0xfe, 0x10, 0x01, 0x06, 0x74, 0xcc, 0x63, 0xdf, 0x7c, 0x28, 0x25, 0xf6, 0xce,
    0xb2, 0x4f, 0x8b, 0xe5, 0xbc, 0x87, 0x69, 0xbb, 0x86, 0x21, 0x07, 0x00, 0x36, 0xe7, 0x0b, 0x50,
    0x59, 0x9b, 0x1c, 0xe8, 0x62, 0x58, 0x19, 0x61, 0xf2, 0xbd, 0x27, 0x5e, 0xba, 0x1d, 0xe6, 0x99,
    0x42, 0x3d, 0x0d, 0x2a, 0xb5, 0xdc, 0x5b, 0x29, 0xf0, 0x2d, 0x4c, 0x53, 0x7b, 0x6a, 0x73, 0x4e,
    0x3f, 0x75, 0xff, 0x4b, 0xa1, 0x35, 0x17, 0x55, 0x72, 0x39, 0x20, 0xd3, 0xb0, 0xfd, 0xef, 0x02,
    0xec, 0x77, 0x7e, 0xe4, 0x2b, 0xdb, 0x90, 0xc1, 0x05, 0x9e, 0x7a, 0xd4, 0x52, 0x6b, 0x24, 0x13,
];

const BRANCH_ONE_B64: &str = concat!(
    "V78Qi7edsGL53bizSke+6LO++Uq43ehHSuizuPm+R91hooEEM0U31wQ3YTOBotdFhEq045jq/RHj/YSYtEoR6uBnfeQr20Iv5ELg",
    "K31nL9srL+R94ELbZ33bK+DkL2dCf7VgCTIwiaMJiX8yYLWjMDKjCWB/iTC1iHd4l7obTDeleVAllaQqeiUqpZVQeXqklXolUKUq",
    "pHlQpJWlJXp5KnG3rQ/GSvd0D/dxxq23dErGdA+tcfdKt61KxnEPdLf319rXZG14NcBWBV7O3lO/Ss6/Vt5eBUpT3krOXla/UwXD",
    "x9dtk7JytW1yw5PXx7Wyk7Vt18NyssfXspPDbbXHchlsLK5vuPTJrvQZbyxsybhvya4sGfS4bCy4bxmuyWz0yoRF89ploNnzoMra",
    "RYTZZdrZ80XKoGWERWXayvPZhKCdQV4KFectsNBIPcyt4Xo9zHrQrT1IPeGtPcw90HrhSDs2abP+afHAs/E7/mk2wGn+wLNpO/Fp",
    "Nmlp/juzwDbx+0B9cRnQc31KgpIvFCmD6y+DShSSguspFOsvkkqDKYLh5pZhIM4g4WEg4SCW5uHOIOFhluEgzuaWziDhYeHmIOj1",
    "x/XD8TGPDnGVst4l/Iwx1Yw/c+ftBT/tMXOM1QXnu5PvQ29CbWBDbbtv75NgQm9gQ++7bUKT70Jvu0Ngk216hCLNjBpsvc1seowi",
    "hL0ajL3NInpsGoQiGox6zb2EbI08iaBoJy3/baGXBDTxk10Ek200l6Fd8TRdBJdtk/GhiI0jld+kccOVcYjfI43DpN/DlSOIcaSN",
    "I6TfiJXDjXHvgK14knpXL+2UYuNCAIIC44LtQmKUAgBCAuNi7YIAlNfWqlIV6Rci1ntaKSN2Ss4pStYjWnvOdiPOKVrWSnZ7fCDH",
    "CNdbay+Khj61UyIvGbUvilM+hhkiKXWvuqg1rvwATweDQYz5IIP5AEEHTyCMQSCDBwD5jE8HjEEAgyBP+U4MPOJoF8u84stOaDwM",
    "vBdovOI8TssXDDwXaE7ivAzL4D6sodPtNDuhNODTrD477dM7oazgNO0+rO3T4KE7PjQlutRi7TQtumItJe3Uuro07bpi1CUtNLrU",
    "NO0lYrq6LYHvw8KymYxiwoyBssPvYpkr7qABDQ0rLAErKw2g7iwNWMjIHb8d2S4d2Vi/yMguHb8uHchY2R3IyB2/WB0uyNlmG5vT",
    "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",
    "witW2jV9CSL/k+BXBJFLjmAPgRV6ivPQ7tIK/PrS1vIIjHvqL+VYN4FxYjCBDYmQE0xmB+zyiNN60v4KZXAy4TBfhykK1NKO+/Lo",
    "epLEG5haX94KKO1qmAy4PgkImLxuOOkqDVofwFuWnAra3FqewgsaWJcJaOi6Lp0MOA+aWh7YwpNcPbme7ApoCCjjGEF18VVKZk/5",
    "ba2W81sFCUfcBsXxdXj2RR1R4nBhS0hWchlhQ/XliWNnLxH2mM1lc1FCTR7h8M4p8WCfZY8TtEBfEY3VzeTVGvBiV9tFenT/heua",
    "2EMOjF1B17UQ5czI1BVF51yJtd6UhZpC/4mf5RTVXclEt4ifnvqBipfdRFOgc4yrDJQD8bztWfXDe4SDWcXrebz19Kt0pAtUiAOT",
    "kAuMowNzrFSA5+1VWFgOcgSLC3SUo1OocFBY7g3ihV/lPn1j0PlbDQQjqMNwfHdULZ2hqWQ2IizVeTv942YIXV79YzgNfdPhgmEs",
    "dDzRlZkJZfh7Wz3l1ply1C2UYYQ5AIj1v24k2RA4UYnjMUjxk0u+SFbluQLa7JXDR+1LYvTYILmOFfBvBKmKxAg4lfibZUxClfPE",
    "7+thyqhNbCM2c/9quwPS+6jMEGqjUMBEO9jVdEyIotEFf1oqM/ze3Ia9qvwAasu/0/s2upZUV/vADKJkcMtKXdiEl2x+ufhtQzZF",
    "eqBYNrrWy1EHrSqtQ4GWyBCu0lsgUpAi+MzxB/zuqdfEiwrMz5OT2m5AFmxJO3WD3S/vzIZDsb5V067IqI0sEswU3VyHiQZi0ipF",
    "qI/3E+Lm+x51K6HPK+F2ox/N+uYs3nbCil39Qo5jqvdHECrRzQSKXhcR3ITOKh35oud34yXIwCSO/tWCXepuMN0g3uGAk7+cCfVt",
    "r/eBC22frbyQka9sC72An/WA/SXC1MqMJsmA1Y7CJCT+r/SdvWyTC4E+GCvd08Xdtsc90N3etyoZlpbo5alAkVZAlaqQ5lXqlZVU",
    "kqroleZBtMbdK90a0z0Zt97SKT3cx1ZC5emRlqiUt03KytUOH18Ot9Uey13LTntZ/U4VeCs5eXsVKE05/1qTteHVAF9rX10Py8ke",
    "T9a2T14f18q2yQ05e0/9KlkVeM1rl4FmKxMWK89nE4IWlWlluCaz0bPgvrJk0OOyvSW7uL7h0idnsLEXKYOWEWpnz2sXEWaXzYMq",
    "vLGwJeO60mfN+qfFA+/YpO/MAtvEp6X590DrhSO19jC39iD1hDPrQSlUnLfAdgZ5pu3Ep9n4A8/4p9kAp83G7zC3huv1QCP1hoE4",
    "g4SHm1uEh4Wbg1g6g0gqDaYIUqy/UUgKrqe8DCrFZUDP9e0D9VmGgzibg4SHg1iahzuHgYS+UKQMrisJSg+9CbWB7U6+7Q6BTba9",
    "C73MMVYXnP+0x/7MnbcXxFQz1w/Hxzyi1x+977YJTb6BDb69T4IJDbXtynqX8DM6xFWCop20/DfyJFy2TcaH0nQR6jX3ErKJaDCL",
    "6LFpEDL2NjQzarD16hGK0VyGdsUTTLYS0MRPdrWFXjGKEPZqNLPp4knqXb28A7aLtQsCUAoJjCNWDjfGjZB+jiDGkTZ+D1dUfpPG",
    "DSM2jguJUQoAjAu2jQsBCAq0U4p+jzQOk1bGISNcb6298IEc6qLWuPKn1L1oWSvZ7Y04p49o7TnbpShZSlWkX4hcW6tO+RhmiNS+",
    "KNROibxkKBr6pYzYKTlb72mIo10s8zox8DmJ8zIs81ygAQyCPOUfMAYeAOQzPgWBDAwGMeaDADwd8zgtXzCg8Yqh8TDwXogvOwQd",
    "PIEwDuYDi7XTtOiW6FKXiOnqtlDTtIOH7vjQsLZPsoLTtPtM74SGTrfT7ID7sFGXtNDotuuKtFPr6tKItZRPs/rstIfSgHf8dmS7",
    "YCEjYnW4IGcjd/w0gLqzNASsrAY0NKywrLiDC8tmMooFvg8gY2V3IP+6dP0iI7t0dGRjyg6/i2UKMwZt9takc1YMYFZscg6kY9X0",
    "mjUA9Lme5POcmLnm9/ECNE6feo+Omm1sYlWk1wz0cm70Yg1w1mymV51ubox6T4+aXMTPmAIlUrwnXgBRmL7MxNhGeJ/afxaTfNra",
    "F5+SeEdGkBTbe9uefrwkms5QxANdxr9QAM1cmCaSfJ56F0fY28RzUONVX+nMXMVX6+DNUHODc5jHhQdz9wSDh3PH9Ztzc/Rzh5uD",
    "xwXPXOFR63BUx3HM6FRTx+Nd9wfHmXNzhIOWUopJGVo4klqUGjpKkYpRU2OeUJ6OXk6JIRgtIroE5+W5LBoFIyCKklpIiTlSGpZQ",
    "kjoaipVKWbiIIQYv5hkhhK0s+WCUjfDB8fSFflGhTYVV4KEJRjJ2RIYJMqJ14VWTl/x6ttpIpVDBfaGFTvXxTVGF9qHxfMGUpEu1",
    "/pJ72nCTZGX+54k55HH/i2U6ZJFDi+KVJIqgUvkUVPLJsQJMTLHyVQIUyPk75GVmiZH8c5E4iP1ncWfmsPrIAfBNVRZFpLw1Fevp",
    "kQHghAIghvqROii/haRX3CNXOKTfhyC+KSgj3qe/OYRUkOk1vemlFEelkOkVv0U06SBWhLzdK6c7Q+yRx5xm7E2O5YhJVfHW+wx1",
    "NqMYjOYiMDelzSWEY1fqbV5cVLIn2PCOVdVL+Yrl+fJKidXnVI1v2iZUXuhdsEDYZdLOQ8z/mfJLkL+oBv2X9AckmNHL01Z/JWyA",
    "OEJk2kXnkLt/+Rarmr4Ekf9J8P6pkksE8b+YbTQkHVjhFSt1fWlreQTGPQV2ecRpPWl/g8CGRMgJJrMKgsglR7CHwJiXcqybwDgx",
    "PQVqacd9eXR+PcV5aHdpBZQyOJlwmK/DBgRMXjecdJWcBDR0XZdOBktuLU/hBQ2sBUniDUytL29trQ/gLUtOBZSeXE92BTQEBJR2",
    "NUwGXJ+uB00tD2zhSbyEI26D4vg65sSxs5cIe8xyJCu5jLCh+rNxjKC6+ColJfuijihxuLAJ55R4sM+yx4Kn/LZWy/mt+LK5KKEm",
    "j3AHuv/CdU3sIU9vykJNof/EWmTqiqJzrsRyWqCviMbqZmbGrqDrWohyok9P/UDFy269ag14savtIsRyiuquZKJb+sGs4vU83no5",
    "wPP2KiwsByrIBcbRgTlWgSnQOcZVBsrJVTrSBSrEgS84KCz3BvHCwnje9qz64T1UgsUFOsrRKZaWztBUMhsRTMEwFjqe6Mpwr/4x",
    "nIa+6YZyn74x6Pytruq8nf5xM4ScTDnqFsowwiqCEdRhOL4764Qy/L2tnnLtJV8kq/JcAc1URWIEnEr8AmyQXMcK+DcIAMT6XzeS",
    "bHr2yuGj9iUxuTBl1Ca2EZtJnKjE8Rik+PUyJqHKeeL3v2o6JkTR6IIGG11Lqqt9YH1VfgC15d/p5n+13QHpfVReLZUZfm9uw5tL",
    "Nr9c/LYhbAi1UShgoh1CUTK4ZaUubEhkCFfpLRApOm03IAu2pJ3Ja+JFBebnyeUiPVAsG13rVBF85vgDfvcW36ppV2TURsuog1aV",
    "1qFA2MHul3dmw6FncfN9j7qV0GjHMdX7IwiVIRZvO2HFrn4DCWaKbq7DRPOVcLvRj2Z9cWeVjnzR87sJMWmVItTH+8JmAkWviwhu",
    "V8DJX86E+rYTwP4SYWplRvrIV7aFXsDPwRJkYBJH/2rI+8CFts9WXsBX+s5etsmF8C51N5huEO//ZMBqR2ESEitLS/TyVKBIHlrj",
    "7pVujemgSipJVfRK81sfjJXu6eJuSqBKVUjzKvVKK6Hy9EhLVIzjHuhu71uV44xbb+mUHu6cvax+pwq8lduuh+Vkjydrr8na8GqA",
    "r7Wv2yZl5WqHj628vQqUppx/vJy9p36VrAonh9tqj+WuZYYnr49rZdvk3zJck9noWXDni5RBywi1s1hc33DpkzPYi+a1y0CzlQld",
    "WTLocdnekjPeWNiScV3ptJXnswlBi8qVtYsIs8vmQZh7oPXCkVp7Z9N24tNs/IG8FCrOW2A7g9Jm/dPigXdsoFt7kHrCmfV6mFvD",
    "9Xqgkfx3ZoFt4tPSd/zTbIDTZuNfJJUGUwQp1sMsw0GczUHC+uIyoOf69oEtw0CcQcLDzZUoJAXXU14GJV8oUgbXlQRBwsPCzUEs",
    "ncJBLM3DncNAY+YYqwvOf9qG3nfbhCbfwI/rh+NjHtHr34fehNrAdicZf+bO2wtiqiplvUv4GR3i3naHwCbb3oV2394nwYSG2hj1",
    "mnsJ2UQ022guQ7viCSZFmhk12Hr1CBJB0U5a/ht5m0X02DQIGXv0GEUIezWa2Qgu2ybjQ2m6Lwlo4ie72kK/ESuHG+NGSNuFxCgF",
    "AMYFRyq/SeOGERtb8ST1rl7eAStHEONIG7+HEL9HGodJK+PGxdoFASiFBMXGhQAEBdopU7Sslez2RpwUp3wMM0RqX1WlKtIvRK6t",
    "jhGut9Ze+ECsR7T2nO1SlLRSRuyUnK33XnVRa1z5U+p9aqdEXjIUDYMABkGe8g8YxXmcli8Y0HgOBoMY80EAnnjE0S6WeZ0YBg8A",
    "8hmfgkABgg6eQBgH89CcxHkZlnkundB4GHgvxJenwUN3fGhY28WoS1podNt1WEOn22l2wH2pxdppWnRLdEJZwWnafaZ3wKdZfXba",
    "Q2naS8R0dVuoaUraqXV1acRaVhpA3VkaAlY6kLGyO5B/XYeFZTMZxQLfkTt+O7JdsJBBAxoaVlhW3ANlh9/FMoUZfrE6XJCzkTux",
    "fpGRXTo6snnNGgD6XE/yN7Eq0msGejk2p0+9R0fNNrA2e2vSOSsGGk7MXPP7eAHNTjc3Rr2nR3orNjkH0rFqK3qxBjhrNtNJbCO8",
    "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",
    "wdNr91u45mqONZToM1bQJlaMNSQy6pfQht3O9xSOgEJr9btqW+TC068rR2ayXWu8zp/ObBK2cfEqR2pcs62/Z/Juts0Qcs2fZl6v",
    "a7C9K0e/Z15HsmmsK2y2zXMR8p7Ons5wtRHO824Rt8Sv9OVLWmoLPKPJU2aetMRL5vcRW62colE+y2dqC6/kE0v2WbXEWK3kx/dJ",
    "EreJFgA7eTK1Wwk8Z1LKa5+ivWyZ5a5b6pctBhltHppc2G6Z6Vuuv5Tl2W2aGB1eLAblWr7or5dtmZXlWpqt679sbZosXhzaBRkG",
    "GV2YHC7abdfbHiRG3ZkZm5b7SvBuGo7aHpjdRdUbJyOs0iKr8AHKJN7Vm0UZ2x4aJ94dRJnV26/SAvKpIMgjyiPz0aoAIqz21jRI",
    "JyZFBo98gRxGJk6bJVqaA6u90lEDOjiamwuWW1IBv5qr0SVa0lEBW6qZvyY7OJYLmgNam1ibCzqalwM6HSVeE6lqQF2nfrIvnoOK",
    "myVeQ2moHl0Rmi+Csp+Lp34TaRxBqV4lXl4RaVyrQh0lL4Kmip+bf7J+souDnqeaLwTtSSLZQNcBox0jPFCaLFe1cVk4r3R4jFc/",
    "mCBQLqMdjTl3WKx4tHF5jDlzrVh0tDyYoC1TVh8jHCMsm1CiVT/WkM+7rx6Da4ieT/VkJecwVlvdVyru1w56TDj5i16DTTXNuowF",
    "WXdnC1l8tP7Q5Q5ib9ops+HgduN2Km+y2eFgZFjMdc8vpZG7J8Zk5b2cCLUQPk96E22A3/e2YJv+HEQe/XLenBVVo2yATRJ6PxO1",
    "gFZybt4Hmz80Ie89XCV07S+c09UD0Ji5W7V9q2AGPbeeIqChLfgrscOB56XS3znaUopK1kPy6MAJNvmnd/bPfMGVdse1vkoAbrfg",
    "qqsorwH07F7cKaVTf1x/1OkuVazzQol9kuvFiM/Nkst44oVPiYt9gs/oRcmSodsPyNXLXjiJz5KL7XXCSK/z7H4k1VlcKdlcVImP",
    "HG4ZblnZjF+ELCFM1+qyf+guJ+Fy2LrvLkyXjrXRy1v4yGxZiVyEHy7Z7C7hQrffeiiOLNlsiV9ZFHxxSPx0Ad+W0Zb8dHhBDH9z",
    "28sjdGZxX1sjZMFzdn/bqWooAhFP5MDvtONtoGtZPXtfI9R7xmNxw/e+GrNjzzGf2pNdsxvRDwbmcYYfaLFi3v+NQS5Qg5WdTl6D",
    "IYDV//6NgVUj0J9OA18Tkb3bn9qPlU7+LYBR07Zihu8ReGYBEk2AWZX1xe/N71JFkIX5FTFUguo9OcvGwuE9izrJNlRdgso2OznE",
    "4eBS9YWZxR9NxMbhXTKJOjv/FU3gklWFyRT+2j0BgNtXTNLN5PfFwPvov25PsD6o6O5IMGi/rui/sG6vOLju70icONYKN1OBxq/o",
    "SLC+bj/oPe6hN2+QQYkcrAKLmv6cTJxMjKqSDvscfIiLaJ2tEAELbK2AmB1xiL8NIpWp5uAxD44qOxrF6HYYAWyNm42ocPwcrEKc",
    "jgqb+yQ64QUqVH5UfuslCjoh9PTaiT4h5W2UmTThjS5l9NrRiW7kLfWaNHrrJTQBWv4kapQ00SmF7v0fz7BC3eACAt1PQxi/18j7",
    "z/sdT7NH2NjdipsimjZzU3pHsAhE7JFmYArksUicdkfzHd9IuMfbT3pTLYqbljLT29hP870XT8giEBr0oqqOWnHn5V1ica7KCstW",
    "BXsxL3EoWNnaD8asYWnYz9wKpiFYgrg+GEDrYKCwR3mYCwIYhafKUeJl4X1+ynExuYkpMeAx4Lp5gTkpwU2/eIn3l8pMSI2XevnH",
    "TL9MP1RmdjB2++G6KTGJOcBx4cYWIcqkE/IgwXHhirk5OUc4KBPFda5WqFYXNcglc066m4g2pDS3kkCF48hu/6FEQ8D+4WivRIVY",
    "F3Uuw6VGOLuSOpSohDa3dk44WMcVJaMGbR7v+4omMS0x5mv+Go8GsAiil5xbn3hykFyvl5u4CAyil1ifu3iQPuaLFv8qAW2YeJAM",
    "kqtXv4EGbT726hsvev2ag3zxzWLNYor8epHzfa3Tsj04UVfNwj1Ytz1RrdPYsl1dN6HDPWqK/J1zwXL9U8092DKxXafyff1qeoGc",
    "wxa7EyBPqUxeS14mv0MZoByrdFLwIagC0EKA8c28pBcMAcKs970UTIBTJq8cQEkeuwTQ+3EiWKCiDQD7GliSDPvuW7S2MEeI54vn",
    "vlA0t0boDMMpgX+5X7i5jL8vcVkIw88pUbh/CbOM5L5AuDaH51tTuIzPeSmxD0foW+Q+t7CGNqd+UFKKtfO381aiXnqANQG8nobc",
    "7OGRbkjCLPUpXc7CLiXN/FluSP5WgnVQujOn7JGBvN6c5gGDNaf+VlpysL5Lu75x00EOSw6+QXuz3rEYv/RhmrUjTERouvORJRy/",
    "uvQhvJMVT2gLvtGxfkO+Sy9MaLqU9bETAQBACz64j/a4KE6IqgNuqGioiCquQwi+FCXz3t8BynNz1A/63sETJS/zzgPaEXXUrogK",
    "TqhjuCjFc9Qv0/EOGoqLr5sPfRwy9BpnPdf3ZpdqlzQX12f99jUlY0LqLDG8s0UqYeI8PCUqYzIs4Ty1RSE6S4fcuSaGNbxFKuNs",
    "IjH39hqX1DdnbT2ppO9T2XYweTDto1Sp3zaO8NhLN3DvW1hOd9874Ivw99jrez+AUE407dOmX3kwqeBbTvc40HuP0DapNF3po3+v",
    "1e+qbZELTwVPr91v4ZqrWzHWkMioX0JGm6jfwFhSMTjWUKLPWEGbGXY731M4AgpRQps4xtigX5+r1U9voe0KeTrD1UY4z7vKu9k2",
    "Q8g1f/yeeR3JprGuqRypcc22/p6Zeb2uwfauHLPZNs9FyHs6vq4cmcl2rfE7fzqzSdjGxSbwnEkpr32KcIpG+SyfqS1itZIf3ydJ",
    "3NISL5nfR2y1v5JPLNln1RIlWgDs5MnUbkXcEr/Sly9pqi3wjCZPmXkZZHRhcrhot2S3aWJ0eLEYVZZrabau/7K7ZaZvuf5SlpZr",
    "+aK/XrZltGmyeHFoF2T2smWWu26pX7cYZLR5aHJhKo/MR6sCiLCPsEqLrMIHKGuceHcQZVZvaHtgdhdVb5yQeFdvFmVse7xKC8in",
    "giCPXG97kBh1Z2ZuWu4rwbtpOGBtLuhoXg7oDejgaG4uWG5IRwVsqWb+mpVoaQ6s9kpHSQX8aq5Gl2ju4FguaA5obdhb0yCdmBQZ",
    "PvIFchiZOG34yS4Oep5qvmm+CMp+Lp76eEWkca0KdZSUeA2loXp0RU2kcQSlepV4vgiaKn5u/sl1lHhNpKoBdZ76yb54DipucIyw",
    "bEKJVv1c/WCCQLmMduYx5sy1YtHR1sZl4bzS4TE15txhseLRxvBggrZMWX2MELQniWQDXQeNdozwQGmyXI3bqbzJZoeD6THh5C96",
    "DTYsZPHR+kOXO1htdV+puF871TTrMhZk3Z2JvWmnzIaD21lDPu++egyuIHo+1ZOVnMPThLz3cJXQtX3f24Jt+nMQsgE2Sej9TNTW",
    "Qvg86U20AXr0y3lzVlSNAFrJuXkfbP6SYTHXPb+URuyeGJOV93IiuN2Cq66ivAYPB56XSn/naCXY5J/e2T/zeoqAhrbgr8RLKSpZ",
    "D8mjAwRX2h3X+ioBvnBOVw9AY+Zu1fatghn03L3Os/uRVGdxNksu44kXPiWEbj8gVy974Qsl9kmuFyM+LvYJPqMXJUslPksuttcJ",
    "I9Gze3GnlE79c/1Rp7tUsc44smSzJX5lUZ2Ey2Hrvrsws2UlchF+uGSEMF2ry/6hu1861kYvb+EjsLuEC91+66GlZHNRJT5yuGS4",
    "ZWUzfhGyDN/7asyOPcdvjZAFz9n9bbzTjreBrmX1zW0vj9CZxX2nqqEIRDyRA+19jVDvGY/F8sUh8dMFfFtFW/LT4QUx/NiKGb5H",
    "4JkFdzp5DYYAVv8PfE1E9m5/anr/Nwa5QA1W+TcGVo1Afzo/Vjr5twBGTXxqT3bNbkQ/GZjHGX6gxYr/VzSBS1YVJgmH9yzqJNtQ",
    "gUvVF2YWfzTHUAmq9+QsG3cJKtvs5BCHEBuHd8kk6uxLNAFmVdYXvzS/SxVBFuZX9riH3rxBBiW6I8Gg/bqi/3PiWCvcTAUao/+6",
    "PcH6oKLBur3i4Lq/I7+iI8H6uv2gUfhr9wQAbl8zSTeT3xcD7/JzsApxOipsLrC1AmJ2xCE9OKrsaBSj2/AhLqJ1tkIE/DaIVKaa",
    "g8dhBLA1bjaiwnGwCixq+nMycDIxqko67HN8PMMKdYMLCGfShDe6lNFr6K2X0ARo+ZPSayf6hJS3UUQnupG31GvSq1HSRKcUuvft",
    "k+iEF6hQ+VP5rZco6ITQb2M/zfdePCHpHcEiELFHms13fCPhHm8/dStuimjazE2BKZDHInHaHetNtShuWspMdz8NYfxeI+8/73c8",
    "zR5hY50qR4mXhff5oWBlaz8Ys4YK4vpgAK2DgSksWxXsxbzEpWE/cyuYhmDCHuVhLghgFIlAaNCLqjpqx52Xd4nFuSqABMeFK+bm",
    "5CI1XurlHzP9heumxCTmAMc1/eIl3l8qMzP9UJnZwdjthxtbhCiTTsgrx8XkJqbEgMeA6+YF5qQE2jnhYB1XlIwBFY4ju/2HEmBd",
    "1LkMlxrh6m4i2pDS3EoOAfuHo70SFe5K6lCiEtrcHeGgTBTXuVqhWl3UIJfMOQQatPnYq2+8yEFyvV5u4iL5mC9a/KsEtMEiiF5y",
    "bn3iMoheYn3u4kFi4kEySK5e/Ri0ebzvK5rEtMSYr/lrPBrL9/Wr6QVyDgv3YN32RLVOqynyd84Fy/W3Tsv24ERdNWDLdnXdhA73",
    "TjX3YMvEdp3p9WsO8sU3izWLKfLrRc73NwDsa2BJMuwIAcY385JeME6ZvHIAJXnsr9JJwYegCkAGCLPe91IwARJA78eJYIGKWexO",
    "gDylMnkseZn8DmWAch6hb5H73MIa5zL+vsRlIQyR+wLh2hyebzIMpwT+5X7hPqdE4f4lzDJM4TI+56XEPrtv0drCHCGeL577QtHc",
    "GqEO1pz6W2nJwbshCbPUp3Q5+lsJ1kHpzpwG8HoacrOHRwm7lDTzZ7khsEcG8npzmgfbnPpBSSnWztzOW4l66QHWBwAALfjgPtoS",
    "oenOR5Zw/C34Rsf6DfkuYfzSh2nWjjDp0ofwTlY8obwwoelS1sdO+C7t+sZNBzkuOfgG7c16xyguvm4+9HHIzFE/6HsHT5S4Iio4",
    "oY7holGUzHt/ByjPv8w7D2hH1FEUz1G/TMc7aOKiOCGqDrihoqEiqrgOIfjd22tcUt+ctcwWqYSJ8/CUhugsHXLnmhjWlIwJqbPE",
    "8KmMybCE89QW1PAWqYyzicTSa5z1XN+bXatd0lxcn/XbQduk0nSlj/5jOd1974AvwtK0T5t+5cGkOcJjL93AvW/dY6/v/QBCOYJv",
    "Od3jQO899KSSvk9l28HkwbSPUqV+23yuVj+9hbYrGG2ifgNjScVk2O18T+EIKG3FWEMio34J4lhDiT5jBW1FCW3iGGODfr1Wv6u2",
    "RS48Fjy9dr+Fa67v/OnMJmEbF6ZypMY12/p7zGbbPBch7+nye+Z1JJvGumTm9boG27ty+7pyZCbbtcbm6QxXG+E87ynvZtsMIdf8",
    "qbbAM5o8ZeZKS7xkfh+x1ZVoAbCTJ1O7i9VKfnyfJHH8Sj6xZJ9VSxVxS/xKX76kmsBzJqW89inAKRrls3ymtt1ikNHmocmF7paZ",
    "vuX6S1nRpsnixaFdkFZZrqXZuv7LWa7li/562ZbZy5ZZ7rqlfmaQ0YXJ4aLdkN2midHhxWK4abmvBO+m4aLtgdldVL1x8iotIJ8K",
    "gjytceLdQZRZvUHiXb1ZlLHtcb3tQWLUnZmqPDIfrQogwjzCKi2yCh+g+cgXyGFk4rRVoqU5sNorHbmDY7mgOaC1Ih0VsKWa+Wsl",
    "FfCruRpdomBvTYN0YlJkg7W5oKN5OaA1oIOjublguXnqJ/viOai4UeI1lIbq0RX7Imiq+Ln5J+IVkca1KtRRNZHGEZTqVeLVUeI1",
    "kaoG1OInuzjoear5p/kiKPu5eOo12jHCA6XJclgbl4XzSofHwoMJ2jJl9TGbx5gz14pFR9eYc4fFikcbQNCeJJINdB3DMcKyCSVa",
    "9XH1gwkC5TLag+j5VE9Wcg5gtdV9peJ+7Sf2pp0yGw5usJDFR+sPXe5W06zLWJB1d2YN+bz76jG4Nm6n8iabHQ6kx4STv+g12LB7",
    "YkxW3suJWAvh86Q30QYDaCXn5n2w+csG2CSh9zNR6tEv581ZUTVJhsVc9/xSGk4T8t7DVULX9H1vC7bpz0G7Vdu3CmbQc+spAhra",
    "gr8SEFxpd1zrqwSXYJN/emf/zCylqGQ9JI8O+8I5XT0AjZngdguuuoryGj0ceF4q/Z2jz/VHne5SxToslNgnuV6M+JT4LLnYXieM",
    "E7r9gFy97IW52Cf4jF6ULEfP7sWdUjr19TrP7kdSncXYLLmMJ174lJLhlpXN+EXIEsJ0rS77h+7C7hIudPuth82WlchF+OGSfOlY",
    "G728hY+Wks1FlfjI4eHIks2W+JVFdBIuh6377sIXbclPhxfE8DW3vTxCZxb3t/c1Qr1nPBbzTjveBrqW1ZyqhiIQ8UQOyReHxE8X",
    "8G0zfO+rMTv2HL01QhY8Z/e3ZmAeZ/iBFivp/d8Y5AI1WP1Y6eTfAhg1PfA1Edm7/ank3xhYNQL96fCpPdk1uxH9YCtm+B6BZxbf",
    "6eQ1GAJY/dH8LlUEWZhfHEMlqN6Ts2xDbBzeJZOoswQuVV+YWfzR3iWobLOTQxwu0QSYVVlf/Pxf0QQuWVWYJRzes6iTbEPPJN1M",
    "fl8MvI7+6/YE64OK/oqOBOvr9oPMiWOtcDMVaATr9oqD6/6OReGv3RMAuH3Y4x568wYZlOuOBIP264r+wcnEqCrpsM/Ah7iI1tkK",
    "EYcRwNa42YgK9+CosqNRjG7z2yBSmWoOHsTBKrCo6c/Jyc/BKsTpqLC4wNYKiNkRh0/lt16ioBNCSa+d6BNS3kavRkkTnVLo3qK3",
    "XkIToOVPE53oRt5Sr0m3T6ITXqBC5fDxDCvUDS4gnUkT3uhSRq/9vN/xNHuEjdWtuCmiaTM3rTfVorhpKTM03/GNhHu8/QSmQB6L",
    "xGl33/00hPF7jby8jf0033vxhKZ3BItAxB5pHHde3iUW56qnsGxVsBfzEgh7lIe5IIBRKojrgwG0DgaVhv3MrWAagiUCoUEvquqo",
    "d6ocJV4W3ueGgpWt/WDMGhwDrpsXmJMS1PSLl3h/qcwfbmwRokw6IReumxKTmAMcz/RDZWYHY7euHBeTm5gSAwMSHBeumJuTi9R4",
    "qZd/zPSEanVRg1wy56m7iWhDSnMruyupQ4lKaHODdVHnMlxqhDgE7B+O9kpUdYSDMlFc52pq54SDdVxRMgRUOI7s9h9K0BJjvuav",
    "8WgHiyB6ybn1iYuJB8kguXr15mO+aPGvEtDJIHqJ9bmLB2PQ5vG+r2gSEmjQ5mOvvvEgB8n1ermJi9cspsivFznf3Dot24MTddU6",
    "1dyDLRPbda+myN85FyzXgy3b1XUTOtym1685yBffLCzf16+mF8g5LdyDddsT1Tqx5GXyO5QByr1KJwUfgioASgC9HyeCBSo7ZfLK",
    "AZTksRggzHrfS8EEZbE7AfKUyuTfALCvgSXJsCAEGN/MS3rBvnjuC0Vza4TLMJwS+Jf7hTCFy/iclxL7Re4LhGtzeL74nBKF+5cw",
    "y+6+RWsLc4R4eIS+Re5zC2ucy/j7EpeFMHM7byXqpQdYGcDracjNHh7AHhnI681pHupvJVgHpTtzJOxS0syf5YZvc+oHJaVYOztY",
    "c+pvpSUH7IYkzFKf0uW75OAbtDfrHYTxSx+mWTvC8cKEpktZHzu04Bsd6zfku6ZLH8I7WfGE4Lu06xs3HeQfAAC04IP7aEuEpjsf",
    "WcLxi4aKqOI6hOBHUTLv/R2gPFE8R/0yHe+g4oqo4IQ6hov9Mu88oB1RR4qL4oSoOuCGo7j4uvnQxyEyR/2g7x08Ua92SXNxfdZv",
    "W1MyJqTOEsNTw1ukMs4mEhiis3TInWtipDImwxLOU1tJr3HWc31vdnZvr3FJfXPWMlukEibOw1OTB9M+SpX6beUIj710A/e+CL7l",
    "dI8DvfdK0z5t+pUHk3SPvb73Awjl05NK+j6VbQcHbZNK05U++o/ldPe9A74IWvD02v0Wrrm0FWMNiYz6JRUltIljjA36kGG38z2F",
    "I6CJYw0l+owVtPRa/a7aFrnw8Lla/fQW2q5jtIn6DYwlFae8m20zhFzzyu+Z15FsGuvv68qRmWzXGjObbfNchLynkZnX6xps78qb",
    "pzNcbYTzvLzzpzObhG1cmcqRGtds6+8Cp2iUz/KZ2i1WK/nxfZLEVsQt8St9+ZJWogXATp5M7fEr+cSSfVYtaALPmZTy2qen2gLP",
    "aPKUmSst8ZL5fcRWQXabJkaHF4tbZbmWZuv6L2UvW2a565b6RpsmixeHdkFmuZYv+utlW5tBRhcmh4t2dotBRpuHJhe5W2b6lusv",
    "ZfIIq7TIKnyAtsaJdwdRZvXG9bYHiVF3ZsirtIB8KgjyB4l39WZRxrar8sh8tCqACOOm5b4SvJuGibYHZndR9cbWgA6O5uaC5Yl0",
    "VMCWauavgb01DdKJSZHmDo7lguaA1pZUwK/manSJDtbmgo7m5YDmI18gh5GJ01SJlubAaq90n+aLoOzn4qmJV0Qa16pQR1dHiddE",
    "qhpQ7IugqeLn5p/XRBpHUKpXiYuf7OKg56nm5qmf7IvnoOJEiddQGqpHV8fVDyYIlMtobR5jzlwrFh0AQXuSSDbQdQgPJmjLlNXH",
    "XGPOHRYrHm0PxwjLJpRo1dVoxwgPlCbLY21cFs4rHR6THhNO/qLXYMNCFh+tP3S5mjXk8+6rx+Cd2Jt2ymw4uFlNsy5jQdbd2Lid",
    "yptsdjgMoudTPVnJOYPVVveVivu10fe9LdimPwctG2CThN7PRCQZFnPd80tpD6CVnJv3weaoR7+cN2dF1TtNyHsPVwldwu6JMVl5",
    "LydgLYTPk95EG/Zw4Hmp9HeOX4JN/umd/TPuC+d09QA0ZkBwpd1xra8SsJSikvWQPDqA2y246irKa+1Wbd8qmEHPrKcIaGgL/kpi",
    "s+QynnjhU07o9gNy9bIXHz27F3dK6dRS4rPkYnudMORin+AzelGy1+s8ux9JdRY81x91uksV67NQYp/kejHi00m4HLbuuws2W1Yi",
    "F+GHS1tKNhdV4iOHCrtLuNDttx7ypWNt9PIWPoUjSzZb4lcWS4ZbVjbjFyFLCNO1uuwfuvbWCFnwnN3fzzvteBvoWlYlXxwSP13A",
    "t9ze1wj1nvFYcKoaikDEEznM8L2vxuzYc1+0JT8dXhDD19z28gidWdx/p5PXYAhg9fbA10Rk7/anw6f2ZNfsRvT0Y6WTfwtg1JN/",
    "Y2DVCPSngK2Y4XsEnlmYgXmc4QdarKX3f2OQC9RglXB4z6JOsg0TuFR9YWbxR7tEE2BWZX3xDrFxeJdMos54l6CyzU4OcfJ/RRO4",
    "ZFVhRfO7VBFkYX5xDJWgek/Osq87Egzaryv6MSeOtcLNVKAVhb92TwDg9vorOhKsr9sPEqzbKw6u+ztij3vozRtkUD6TdDP5fTHw",
    "Ovqv2xOsDyriAlsrIGZHHN2Do8qORjG6EwerwKKmPyccRgBb42YjKsxvg0hlqjl4Jj8HqxCno8IHJxOjqqTDPgAf4iJaZytEdiZN",
    "eKNLGb2J3noJTYCWP98+iU54gQqVvxolTXRKoXtNdKIbeUu9JsDHM6xQN7iAPZXfeomCTgglvXaiT0h5G5neESwCEXuk03zHNxLu",
    "8fZ+99MQxu818rTeVIvipqXMEZgCeSwSp93yNvbTfO/FE/bzfsfT7BE2VLfipoimzdwYCla29oMxa6ggrg8G0DoYlgiEBr2oqqMh",
    "7FEe5oIARlYa9jO3gmkI36lylHhZeJ9y3Hl5l1icq5zCslXBXsxLL1LjpV7+MdNcuG5KTGIOcLhyXExuYkoMfLixRYgy6YQ+0w+V",
    "mR2M3Q5IcFy4Ym5OcAy4bl5gTkpT0y9e4v2lMhFQ4Tiy238oDtZFnctwqRHVEQ7KRHGdq+2upA4lKqHN4RCwfzjaK1GonRMO1nFF",
    "yROq1UUNcsmcpO4mog0pza2CHCTX6+UmLpuP+aLFv0pAjEGbx/u+okkvJh4kg+Tq1SSD6CXW5y4eS6BBm4+9+sZBS4z5mr/Gox4s",
    "gugl59YntHAP1m1PVOu/miJ/51ywXJhev+YgX3yz6VRzD7ZMbNcPtmxX103ocLB8X7+aXiDnX7OYIr9e5Hxz67RsD07UVYMQYHwz",
    "L+kF7pTJKwdQkseXxe4EyFMqkygB9H6cCBaoYIAw630vBRN+A8C+BpYkw8eSl8nvUAYo9CqdFHwIqgBwLuPvS1wWwha5LxCuzeH5",
    "ufsWrS3MEeLDFC7jc15K7ONzShTuX8Is4RH6FrnPLaz64rkvFM2tES7DcErgX+4XsxuSMEt9Spepv5VgHZTuzLzNqR+UlGLtAHtk",
    "IK83p3mSsEtJM3+WG+xgzam/lZYcze28laiXHmBkAK+nITd7eC8Rmu58ZAnH0oJvdKzfkO+D79Kub9x0kMQLE5ouZX3smi59CO9k",
    "xRN9AADQgg/uo+ySg2/Q3qx3E8YvfZhm7QjJHPWDvnfwRIorooIT6hguKi6KE6LqgBtG8Rz1y3S8g/XLvPOAdkQdjOLi6+ZDH4cv",
    "GiqiiusQghxFybz3d4DyyWyRSpg4D09hiM7SIXeuiSW9xlnP9b3ZTA1vkco4m0iRypgMSzhPbdu9vcYl9c1ZvdolzcX1Wb9vTcmY",
    "kDpLDDyW0933DvgiKk37tOlXHkxMTyrp+1S2HSP4ltM9DvTe0z32+t4PIJQftE0qTVf66E0eTPsoVeq3liM89tIN3PuM0SbqNzCW",
    "VEKG3c73FI6A02v1u2pb5MJXlNAmjjE26CaONZToM1bQwudq9dNbaLtqwdNr91u45tBWjDUkMuqXZypHalyzrb/ObLbNcxHynm6e",
    "znC1Ec7zvK8rR2ayXWtHZl6va7C9K/HOn85sErZxn/Juts0Qcs0rv2deR7JprK20xEvm9xFbW4kWADt5MrWiCTxnUsprn1oRt8Sv",
    "9OVLxK/kE0v2WbWeags8o8lTZgucolE+y2dqt1it5Mf3SRLlbpnpW66/lBltmixeHNoFbQYZXZgcLtqXvWyZ5a5b6pnlWr7or5dt",
    "2C0GGW0emlwG2W2aGB1eLGyV5Vqareu/J9oemN1F1Rsjr9IC8qkgyKzKI/PRqgAiGdfbHiRG3ZkeJN7Vm0UZ246blvtK8G4ayiOs",
    "0iKr8AHbGifeHUSZ1VElWpoDq73Smzs4lguaA1o6WJsLOpqXAwb21jRIJyZFWlIBv5qr0SWbj3yBHEYmTlsDOjiamwuWJtJRAVuq",
    "mb8RJV5DaageXbIvgqaKn5t/L36yi4Oep5pdHSVeE6lqQF4TaRxBqV4lm6d+si+eg4p+mi+Csp+LpyVeEWlcq0IdjLVxWTivdHgj",
    "PJigLVNWHz8cIyybUKJVAQTtSSLZQNdxjTl3WKx4tFejHSM8UJosHVc/mCBQLqO0eYw5c61YdA5WW91XKu7XdmJv2imz4eBg43Yq",
    "b7LZ4WvWkM+7rx6DZzXNuowFWXcwiJ5P9WQl5016TDj5i16DDgtZfLT+0OWAtRA+T3oTbT+AVnJu3geb7TQh7z1cJXSRZFjMdc8v",
    "paMe/XLenBVVCLsnxmTlvZxE3/e2YJv+HLVsgE0Sej8TsZ4ioKEt+CsAwZV2x7W+SgFut+CqqyivuS+c09UD0JjAUopK1kPy6Ldb",
    "tX2rYAY92sOB56XS3zl8CTb5p3f2z89CiX2S68WISInPkovtdcJcr/PsfiTVWX/07F7cKaVTkot9gs/oRcnzXH/U6S5VrInNkst4",
    "4oVPOKHbD8jVy14uIUzX6rJ/6CjsLuFCt996FI4s2WyJX1luKdlcVImPHMiXjrXRy1v4LBluWdmMX4RMJ+Fy2LrvLtlsWYlchB8u",
    "X3PbyyN0ZnFxe18j1HvGYzHD974as2PPlnxxSPx0Ad/AqWooAhFP5H/Rlvx0eEEM21sjZMFzdn8977TjbaBrWZXe/41BLlCD04+V",
    "Tv4tgFEBtmKG7xF4Zg+f2pNdsxvRTv6NgVUj0J9iBuZxhh9osf+dTl6DIYDV2gNfE5G925/GMVSC6j05yzvExuFdMok6yf8VTeCS",
    "VYXvEk2AWZX1xeFdgso2OznEFc3vUkWQhflUwuE9izrJNk3gUvWFmcUf6Oi/bk+wPqjor+hIsL5uP4k97qE3b5BBVxT+2j0BgNtI",
    "sG6vOLju7/tM0s3k98XAv+5IMGi/rujGnDjWCjdTgQF8iItona0QcBgBbI2bjaib/BysQpyOCkwcrAKLmv6cMb8NIpWp5uAcnEyM",
    "qpIO+4gLbK2AmB1xdg+OKjsaxeiU9NqJPiHlbf1qlDTRKYXuAh/PsELd4AJ++yQ64QUqVDTRiW7kLfWa9FR+6yUKOiHamTThjS5l",
    "9CR66yU0AVr+U92KmyKaNnPTelMtipuWMsjb2E/zvRdP+91PQxi/18hHYArksUicdtjP+x1Ps0fYZnpHsAhE7JFP8x3fSLjH23EK",
    "y1YFezEvhbBHeZgLAhh+p8pR4mXhfVoiEBr0oqqOWGnYz9wKpiHKceflXWJxrmEoWNnaD8asoIK4PhhA62BMTb94ifeXyvLhxhYh",
    "yqQTOSDBceGKuTngynExuYkpMftMP1RmdjB2wTHgunmBOSm/SI2XevnHTHHhuikxiTnAkrqbiDakNLe3u5I6lKiENqN2TjhYxxUl",
    "Vkc4KBPFda6FQ8D+4WivRE6oVhc1yCVzRECF48hu/6E4WBd1LsOlRniwCKKXnFufv5h4kAySq1cvgQZtPvbqGzEGbR7v+4omkAyi",
    "l1ifu3gGLTHma/4ajwhykFyvl5u4bT7mixb/KgHNrdOyPThRV6dTzT3YMrFdw/J9/Wp6gZxiev2ag3zxzT3Ysl1dN6HDfc1iivx6",
    "kfPTwj1Ytz1Rrf1qivydc8Fy0Kt0UvAhqAKiBND7cSJYoPsNAPsaWJIMXha7EyBPqUyAAcKs970UTBxLXia/QxmgDEKA8c28pBe7",
    "UyavHEBJHrgMwymBf7lfD1O4jM95KbGGR+hb5D63sOfuW7S2MEeIjM8pUbh/CbPoi+e+UDS3RsO5jL8vcVkIW+S+QLg2h+eRAbye",
    "htzs4QHskYG83pzmsIM1p/5WWnLzNqd+UFKKtUjCLiXN/FluNbfzVqJeeoDObkjCLPUpXaf+VoJ1ULozTBi/9GGatSMTL0xoupT1",
    "sfYBAEALPriPDr5Lu75x00FouvQhvJMVT7FLDr5Be7Pev0RouvORJRxLC77RsX5DvnMUJfPe3wHKGsVz1C/T8Q4yiouvmw99HKi4",
    "KE6IqgNu1C/zzgPaEXW+aKiIKq5DCCVz1A/63sETKK6ICk6oY7i8NSVjQuosMTE1vEUq42wibff2GpfUN2eX9BpnPdf3ZkUqYzIs",
    "4Ty19mqXNBfXZ/0ls0UqYeI8PIYhOkuH3LkmW47w2Es3cO+P4FtO9zjQe3/QNqk0XemjMD2ppO9T2XZO99jrez+AUDZ5MO2jVKnf",
    "8FhOd9874IupNO3Tpl95MEJbMdaQyKhfX1FCmzjG2KAKn6vVT2+h7U+v1e+qbZELmzjWUKLPWEGrBU+v3W/hmjFGm6jfwFhSChl2",
    "O99TOAKu/J55HcmmsfG+rhyZyXatxTt/OrNJ2Ma7eTrD1UY4zxyZeb2uwfauf8q72TZDyDWeqRypcc22/jqz2TbPRch73GK1kh/f",
    "J0lpRdwSv9KXL3mqLfCMJk+ZiibwnEkpr30Sv5JPLNln1S1wikb5LJ+ptdISL5nfR2xuJVoA7OTJ1LJVlmtptq7/X/ayZZa7bqlh",
    "txhktHlocrcZZHRhcrhoZZZr+aK/XrYYZLdpYnR4sZa7ZaZvuf5SZLRpsnhxaBdva5x4dxBlVmZcb3uQGHVnOG5a7ivBu2mwKo/M",
    "R6sCiHuQeFdvFmVsKI+wSouswgecaHtgdhdVb4+8SgvIp4IgmkhHBWypZv4Z2FvTIJ2YFG0+8gVyGJk46GBtLuhoXg5oSQX8aq5G",
    "l24N6OBobi5YR5VoaQ6s9kpt7uBYLmgOaJR4RaRxrQp1dXWUeE2kqgFunvrJvngOKr74yS4Oep5qeE2kcQSlepX6ab4Iyn4unkWU",
    "eA2loXp0yb4Imip+bv7R5jHmzLVi0QcQtCeJZANdXI12jPBAabL9cIywbEKJVsY15txhseLRdlz9YIJAuYwx1sZl4bzS4YzwYIK2",
    "TFl9Oyxk8dH6Q5euWUM+7756DMMgej7Vk5Wcg43bqbzJZoed1TTrMhZk3TbpMeHkL3oNO1htdV+puF/bib1pp8yGg9SyATZJ6P1M",
    "RpJhMdc9v5Qi7J4Yk5X3crXThLz3cJXQjXr0y3lzVlQQfd/bgm36cwHWQvg86U20/gBaybl5H2zzJdjkn97ZP+a+cE5XD0Bj3G7V",
    "9q2CGfQGuN2Cq66ivANLKSpZD8mjaA8HnpdKf+fEeoqAhrbgrwEEV9od1/oq4YRuPyBXL3v90bN7caeUTs5z/VGnu1Sxcb3Os/uR",
    "VGdLLvYJPqMXJSU2Sy7jiRc+Pgsl9kmuFyMjJT5LLrbXCWSzZSVyEX64uKVkc1ElPnKyZLhlZTN+EVE4smSzJX5lI1861kYvb+Ew",
    "nYTLYeu+u7uEMF2ry/6hobC7hAvdfuv1vNOOt4GuZVvyxSHx0wV8/EVb8tPhBTHHDN/7asyOPQOnqqEIRDyRbW+NkAXP2f19zW0v",
    "j9CZxcXtfY1Q7xmPag98TUT2bn8/fGpPds1uRIoZmMcZfqDFBdiKGb5H4Jk6+TcGVo1Af/93OnkNhgBWVnr/Nwa5QA1NP1Y6+bcA",
    "RjSBS9UXZhZ/v0s0AWZV1hdXNL9LFUEW5ib/VzSBS1YVh3cJKtvs5BBQCYf3LOok2xvHUAmq9+Qs7BAbh3fJJOoac+JYK9xMBV9R",
    "+Gv3BABu7zNJN5PfFwMl9riH3rxBBiPBur3i4Lq//7ojwaD9uqKio/+6PcH6oKC/oiPB+rr92z04quxoFKMycbAKLGr6c3NwMjGq",
    "SjrsbPJzsApxOirH/DaIVKaagyEusLUCYnbEBPAhLqJ1tkLCYQSwNW42opPorZfQBGj5+e2T6IQXqFDQU/mtlyjohAh8PMMKdYML",
    "0kQnupG31GtrZ9KEN7qU0VHSayf6hJS396tR0kSnFLo/zXd8I+Eeb+93Pw1h/F4jYz/vdzzNHmEhb2M/zfdePB2BKZDHInHamukd",
    "wSIQsUdNdStuimjazEzrTbUoblrKgQri+mAArYNqiUBo0IuqOirHnZd3icW5+Z0qR4mXhfdgpWE/cyuYhoahYGVrPxizxCksWxXs",
    "xbwUwh7lYS4IYMeF66bEJOYAgCvHxeQmpsQEx4Dr5gXmpOSABMeFK+bm7TP9UJnZwdj9IjVe6uUfMzM1/eIl3l8qyIcbW4Qok07h",
    "YF3UuQyXGlod4aBMFNe5OaFaXdQgl8yM2jnhYB1XlBUOAfuHo70SEgEVjiO7/YdK6m4i2pDS3NzuSupQohLatPmYL1r8qwTEGLR5",
    "vO8rmhq0xJiv+Ws8vAQatPnYq29BMoheYn3u4iLIQXK9Xm7i4sEiiF5ybn39YuJBMkiuXvWrKfJ3zgXLi+n1aw7yxTf3NYsp8utF",
    "zg7L9/Wr6QVy92DLdnXdhA5OC/dg3fZEtTW3Tsv24ERdnU4192DLxHbsTpm8cgAleXlZ7E6APKUycix5mfwOZYDsNwDsa2BJMgEG",
    "CLPe91IwMAgBxjfzkl5Ar9JJwYegCooSQO/HiWCBb5H7AuHaHJ6eu2/R2sIcIaEvnvtC0dwaGh6hb5H73MIyPqdE4f4lzAznMv6+",
    "xGUh4TIMpwT+5X4+TOEyPuelxJz6WwnWQenOztuc+kFJKdbW3M5biXrpAcEO1pz6W2nJIQm7lDTzZ7k5uyEJs9SndEcG8HoacrOH",
    "B7BHBvJ6c5ouLfhGx/oN+Tn4Lu36xk0Hxy45+AbtzXraBwAALfjgPqHp0ofwTlY8/BKh6c5HlnAwYfzSh2nWjk68MKHpUtbHorgi",
    "KjihjuGh4qI4IaoOuPiioSKquA4hyCguvm4+9HFRv8w7D2hH1JTMUT/oewdPz1GUzHt/ByhoFM9Rv0zHOxiG6CwdcueaXdJrnPVc",
    "35vbq13SXFyf9bXd22tcUt+cFqmMybCE89SUzBaphInz8PDWlIwJqbPExNTwFqmMs4mk0rRPm37lwcH0pJK+T2Xb2+TBtI9SpX7+",
    "Qduk0nSljzndY6/v/QBCwmM53X3vgC9vOcJjL93AvT2Cbznd40DvKGTY7XxP4Qg8vVa/q7ZFLq4WPL12v4VrK3yuVj+9hbZt4lhD",
    "iT5jBcUYbaJ+A2NJCW3FWEMio35+RQlt4hhjg+nMZts8FyHv7+bpDFcb4Tz8Ke9m2wwh1xfv/OnMJmEbcmTm9boG27t7pnKkxjXb",
    "+rrye+Z1JJvGxvu6cmQm27W7lWgBsJMnUymawHMmpbz2tsApGuWzfKbmqbbAM5o8ZUv8Sj6xZJ9V1UpLvGR+H7Fxi9VKfnyfJKQV",
    "cUv8Sl++kNGmyeLFoV3dZpDRhcnhomKQ3aaJ0eHFhd1ikNHmocmWWa7li/562Vnulpm+5fpLy1ZZrqXZuv5+2cuWWe66pTzyKi0g",
    "nwqCwqo8Mh+tCiCgPMIqLbIKH+G4abmvBO+m7UHiXb1ZlLFxou2B2V1Uvb2tceLdQZRZmXG97UFi1J21uYNjuaA5oKCDtbmgo3k5",
    "uTWgg6O5uWC0+cgXyGFk4qIlFfCruRpdHVWipTmw2itrIh0VsKWa+WRgb02DdGJSJ/siaKr4ufn54ie7OOh5quqn+SIo+7l4uHnq",
    "J/viOajiNZHGEZTqVRVR4jWUhurRUeIVkca1KtTU1VHiNZGqBjHCgwnaMmX19cMxwrIJJVracfWDCQLlMnI12jHCA6XJG9eYc4fF",
    "ikfHWBuXhfNKh0ebx5gz14pFHUDQniSSDXRuJ/amnTIbDg42bqfyJpsd2KTHhJO/6DUOg+j5VE9WcndW06zLWJB17WC11X2l4n7u",
    "sJDFR+sPXbhmDfm8++ox+QNoJefmfbDXThPy3sNVQkH0fW8LtunPibB7YkxW3ss16tEv581ZUQZYC+HzpDfRUcsG2CSh9zMaSYbF",
    "XPf8UgQQXGl3XOurGuB2C666ivKjPRx4Xir9nXO7Vdu3CmbQDiylqGQ9JI8S6ykCGtqCv8yXYJN/emf/mfvCOV09AI11+wG4e9kL",
    "Jp/dizukdOuOnzvr3aSLjnSf3Y47pOt0i3ja6a+xmg3neK8N2rHp55p42uevsQ2a6Xivmtqx5+kNRLfh0XWXFBFE0RS3deERl0lt",
    "oDiSju87STjvbZKgO44c7Nvp40ncDRzp3Ozj2w1JHOwN6ePcSdsc6Uns4w3b3PvCROnkYWkhKv3etwVVtigqt7b9Bd4oVYrGpqvp",
    "bbw9IxHBlsIVRO7lMO/4r33TNpBvxyHrPiLKkCEib+vHyj7Maf/vft9IfkLU7IIKdAYFQoIG1ArsBXRC1AWCCgZ07Ji61o7YIhbn",
    "mI4WutjW5yKYuueO2BYi1piOIrrY59YWPkFOHIKLjBE+HIxBgk4Riz5BERyCjItOPhyLQYIRToy7Fq/D3e/A3rvDwBbdr97vuxbe",
    "w93A76+7w+8W3d6vwBBA23c3ofv0AfzFASbHdi0BAXb8JsUtxwH8LQEmdsfF3uVs8lzVQ7Te8kPlXGy01WXzajGBgzrDZTE684Fq",
    "w4PtsiovxdsDmu0vA7LFKprb7ih3AMaxHgDuAB4oxncAsRKtybc58WxxXKvuJrXYT+1cJk+rte7t2G0qbhx2KunUyrZVJtPciBHK",
    "Joi201UR3Mq2ESbTiNxVyibcttMRVYhI6RVgClP7Zkhg++kKFWZTSOlmYAr7UxVIYFPpCmYV+6RUJ2gy/WZcwjSkYJZHyrrCYMo0",
    "lqS6R8I0umCWykek0vjI2oKr03PS2tP4gshzq7Skse4msz2PtO49pCaxj7Ol9ZYqjIXaIaUq2vWMliGFpfUhKozahZZt8AdeX1JE",
    "ABc1y3Hs3Cv853Z1ar6P/Msf6DQFFcFvPh8Fb+gVND7BVVxIXXsJGO8RXQ9psDkD1UwSCkVfHog2TEWIEl8KNh5qNafJuqIONz7u",
    "ZgdHwWtgPgdr7kdmYME+7mAHR2vBZhFz0wGN78tdEQHLc43TXe8Rc10Bjcvv0xEB73ONXdPLOHXbGuvPJOg4GiR169vozzh16Brr",
    "JM/bOBrPdevo2yQ4aYkSyyNwuzgScGnLibsjOGm7EstwI4k4EiNpy7uJcNsa8scxI9fN28fXGjHyzSPbGs3HMdcj8tvHIxoxzfLX",
    "yTnynNW7mPPJnJg51fLzu8k585zVmLvyyZy7OdXz8pg5fFIanScJATkaCXydUgEnOXwBGp0JJ1JJc+z1JiJqYPv1jtM4SVio+9NY",
    "9TiOqEn79ajTOFhJjvvTSfU4qI5Y2dDyJD6FxDzZJMTQPvI8hdnQPCQ+xIXy2SSF0D488sSS1vN5PqCc1JJ5nNY+89SgktbUeT6c",
    "oPOSeaDWPtTznK3voNXb7KZCrdWm79ugQuyt70LV26bsoK3V7O/bQqCmgbuOweYM26CBwdu75o6gDIG7oMHm2wyOgcEMu+agjtug",
    "E0O7cjCh6aC7oRNyQ+kwoBPpu3KhMEOguzATculDoTbq5lm2oA/Q3L9WXBbpAHzcXAC/FlZ86dy/fFwWAOlWVvv9grIz2RFWgtn7",
    "sv0RM0W4qvCCeNpdRfDauIKqXXhVFhSXvQtUMlWXVBa9FDILVRYyl71UCxRVlwsWvTIUVEB69wCxZ/senL+HJqf39zGcJve/p4cx",
    "95y/MSan9/eHRs2EJpTnoNFGJqDNlITR50bN0SaUoOeERibnzZTRhKBlJTSgrF420mWgNiWsNNJeuZqE/LrfXki5/F6auoRI3+vI",
    "KwhykeE76wjhyHIrO5HryDsIcuGRK+sIkchyOyvhmOqBH9dpOoyYHzrq14GMaZjqjB/XOmmBmB9p6teMgTrknNdkI4alMORkpZwj",
    "1zCG5JwwZCOlhtfkZIacIzDXpZDyjaSHvtWckKTV8oeNnL6Q8pykh9W+jZCkvvKHnI3VnS3rRVbf83WdRfMtVut1350tdUVW89/r",
    "nUXfLVZ16/OpgghC9RksaalCLIL1CGkZqYJpQvUsGQipQhmC9WkILBlYVp2DZhZBGZ0WWINWQWYZWEGdgxZmVhmdZliDQVYW5T4B",
    "+y5W7YLl++0+LgGCVuU+gvsu7VYB5ftWPi6CAe1tvYL+YS/v4m3+771hguIvbb3i/mHvL4Jt/i+9YeKC79ZbQVm7IlWr1llVW7tB",
    "qyLWW6tZu1UiQdZZIlu7q0FVcqH/Z36mdMByZ3Shfv/ApnKhwGd+dKb/cmemoX7A/3QN0IBMNjwCgw1MAtA2gIM88hAlPpfCW/6p",
    "hRq7tfOlaR0I5igXwNMFHSjTCBfmBcAdCAUoF9PA5h0owAgXBebT8cp36PC5QRPeVSAocpjF4vz+nv4rm7e6hye82LRDMaDmhe6g",
    "Sy2bOeagm4VL7jktJuJH1O1kX4lH+7AAgLlm2WTEgz2ic3EBZD1xxKKDAXNkxAE9onFzg2Q9c8SiAYNxb6ZaR1Dkde5vR3WmUFru",
    "5G+m7kdQdeRab0fkplDuWnX7R75wT0jBtftwwUdPvrVI+0e1cE/BSL77cEhHT7W+wfa8O12xdnPrTiaqt5ekNv1OtzYml6r9pE4m",
    "/beXNqSq60qjYrneU9rN/Y7BggeuNRy0OemTyuQTAAA4WHDiHoNTbMpTgEzO2BqI0oXJJjtB9MJr/S2ILmHPtBYtQPnBs55rGTSS",
    "2kCXlRLfthkiM65KACowKnHkIv4myUDT65HvtOi/29kEG4Fn7YuHHp5qOrgxc88tJXCeM0hur0dJJhQ4fhwCnREdFomYEJnlsxvL",
    "P2QeRs1FQXVw+PQsNlnANdsPwN3LXjCp7HbcIV2nW/x7bdCOTT/XxOxe3CGlW3f8005/jdVsOMd71dSOPU9vwNxZ7yZddKT70z5/",
    "jW3QTMe6DY+uu6SIIMJ5b5ME3XFMSOdmH99uSOKKpritC4+4JGDfTh9P4m7gSE9iH2/Y5uZqA8WRdHzfSWBvSB/nTtrmFyZKJw9L",
    "C9k0Nl1Nb+PtUYd5x3/tm7Yp6fe+LaiyRVGJCLYUriByHwwReVs/VvaBubXtL/BGqVJ8Ow5Z9xFRhk77f/f7RvJjoi4QVDCgYxd0",
    "tNDFtj4XwaJmF1SgMygQ1LV2xBaxOMd0FNHFPre2wBI0oFZgL6AT1D13xLYQscYJcuIQXGSM8OFYDBKMcGL0HQa26H71ft/hYAwS",
    "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",
    "NA+JD3GhfDYJMbSPPE9hNj3qNA5WkuN+9XyeDygntaQep7XPPDWoZDX7+7YQqGlrHqi1D/U8p2Q7aPU2u6lQ67tQ9bYpO2jrten7",
    "NqgQe2s1dZ4PJ+i8pK5jsDnDNmjg8PauuSMoQ2AuzIRc+lAo6DDDrjmo43ZgxNCuHExoOuhE+q5cKMwQ6G7ohNxQOgzoLmiw+TaD",
    "Y+C6eZYt6AO0ja8Vl0U6AB/3vDauoGoXXhEvH5cFQLoV936/oOxMdoTVriq8IJ52VxFg9r5sf8SMlRfAr4UVXzo3BcVl7wKVTJUl",
    "lUUvhcxC1W+Myen9/SHn5YJFrwwFVdXePUDs2b4HkMn97+lhzD2n76HJ6f19DOeFzGUv1QJFlTOhCeU5aLRRCWgzJWH0uZG/l6Yu",
    "IdJ3Lsl5M2U0IaiRCQ0oq5eNdFkmIb/utxdSrqhNCSuNtFcZc7QJJeg5oVHyCoJcZPjOOkI4stzKTuQ6R5r6NWOgDuZCJLLczkr4",
    "Onrgx3WaDiOmOuPHtU5aIKaHjvp1IGMa5vIOglx45Mo65zXZiGEpDDlZKefINYwhOamv/CFnYzUkmSHnCMx1KTl8I+mhbzUnpDwn",
    "6WG1byOkabX8YSOnLyQnDNlIqeE1Oct6kdX3fF1n0XyL1Xrdd2dQhmB9GgJLqtF3i1Xd+nxnIIJQfQZLWqpgmlA9SwZCqhCLYD1C",
    "WkaqS12R1fz3emeWVeegmUVQBqcF1qBVkFlGvpWPi2BAe/mnGdZgkJVFRk/AvotVu2C5j+C+S7tVQLl+u49LgKBV+VZQ56CFmVUG",
    "r6B/2Mu7eFv/e2+YoPhLm5bI1u5qUJV1/0tvmLjge5tWUNauSNWq9dZq1m6VSJD1VtXWbtCqiHWvuH/Y+4tgW+j/mZ8pHbBcGV2o",
    "3z+wqdyhxm7tfGlaaplpqB/wP53cNCCTDY/AYANEic+l8Ja/PJMAtA3gIE8DKPCZH53pv1yCOcoF8HRBB8o0woV5AXAHCS827VAM",
    "6OEKMMJFgfl0B/IdOnxu0ES8v6f/yuatLr8VCIocZrG4d0IBysU0sHkHoTvoUstmjnnoZuGSe06LOc8csWjAYBxZPiwAYK5Z9tHx",
    "YI/oXFwAGXFAj2jc3CAZTxyx6GDAHFn4EXU72VeiianWERR5nfubUZ0plJY7+dsc0tFTrW/wPhG5KZS7Vt3bkS/cE1Jw7f5RLdxT",
    "MJLv/lzw0ZNvLdI+qfsRVB251pvvTles3dy6PYnq7SWpTb+TAA4WnLjHIABJ/+2lDamqk9KoWK73lPa6bU76pDL5BAe/Y7DggWtN",
    "c62NyaVqP6nTm/IUIJMz9hSidGGyyU6QBkky0PR65Lu/rUULUH7w7DNaBo2kNtCl54AKjEocuYgSxLdthsiMa6XwWn8LoksYvfrv",
    "djbBRiAt++Khh6eazlk+PYtNFnANHJLb61GSCcUMH4dAZ0SHBY6Zh1FzUVDdDyZEZvnsxnIizNxzSwmcJ24DcPeyF0zq9h13SNfp",
    "Fj+7z19jGzTT8bQXd0jp1h0/u9NfYzUbzvG01rtJFx3pPnc1tWPP0xvwXhu0Y9PPNfFew6PrLikiiG7e2yRBdxyTcBvSx7mTtjnY",
    "KW7rwiMuiaK308eTuBs42EBxJB3fd5Lak9jHG7a5OdK52ce3G5I40onSycPSQvaFTVfT23h7FI2OQ9Z9RJQh371vC6psUVT6gi2F",
    "K4jcRyJt+wu8UapUbkTe1o+VfSBD3vFf+6ZtymH+3/2+kfyY0wsEFQzo2IWozx2xLUSsMXXZBRXoDAqEqK0dsUUszjF1DagV2Avo",
    "hARFdLHPrS0wHS10sa3PRTAdnDgEFxkjfIIWgwQjnBh9OLyHu4HfX3ctGIMEnSIWfTheh7vfgb13LSI4BBkXnXyC3y26vV+Bd4eB",
    "Lbpfvd93h7bvbkL36SGAWwJM7I6LA/jVYgIHdYbL5osDTI7tWgL42eS5qodovcvs+E2KW44DAnTmA9WGB8tih8q52GirveVVXoq3",
    "BzTbZTxQjO8AYt0BnlZr3duxuUwGZItVNLfbX5Nvc+LZ4iRa7gCMYz0A3FHcOOxU0qnbVN1NarGf2rlWq0ymuREjlG24bacjqhCV",
    "Tc3AFPanKpDSEG2nqyK4lU0rwBSm9s2Q0iNMphG5q5RtptIVzCr2kcD20xUqzKaQwE7QZPrNuEipdMEslY9IhWlj3U1mex5pSUjB",
    "LI+UdYVpkbUFV6fnpPGUaSxJdY+EwXtITWIfZ2ndp/EFkedWpbUtVRgLtUNK6w+8vqSIANrgaQoqgt98PtC06xktQwpLVZbj2LlX",
    "+C9qQ1QYtQstS+ve0CtofII/CurUfB/5l8/tkLr2EjDeq7gQJb4UbDyYitbcj8zAgn0OHtJgcwaqI7pOk3VFHW7UahSKvjwQbZgk",
    "wQ6O1oLNfNzNDo6C18B83KYDGt+XuyLm3ucau6aXIwLQNdZJnrdx6pbnGqe73iMCtjXWn0nQceq6AhqX36cj5p7r1tG3SXA0SOrW",
    "t9GfcTQSJZZH4HZx0kbSlncT4XAkmo9jrkfktzXg0pYTd0dwJOSPY0aum7c1diWW4UYScdJHNGKa5a+3j681YuSbR7aP5DmrdzHn",
    "k3N3c6rn5TGTOQI0OhNOpHL4MXOq5ed3kzmkNDpPEgJy+OY5qzF35ZNz2OtNRNTAkuYS+DqlAk5yNB2ncZKwUPfrk+pxUB2x9qd5",
    "SHyIC+WzobHqcRxRk/an5Ul8Col5sqFRp3Gwkhz36wqhfXjkibNJiKF95HkKs0nn83xAOaklrUCtfajnOSXzhaq3TdlBW984rX3m",
    "qUEl80Grt9lNhVrfqfN8OEHnJa3Z37eFQE1bq03ft0GF2FurHYPNGbZBA3cZds1BHbcDg9J35UJhhkAnt3fNHUEZAoOGduVgQtNB",
    "J0GDzbcZHAN3YSbk0odCQXdDJ+SG0mFAd82zbEEfoG3U+bgsANKtuH9V4QXxtLuKcK24LNIB+Lh/+wVlZ7IjrPYAfi2s+NK5ubVx",
    "BVW78Irgs/dl+yNmrAQoLnsXqGSqLBcsemUoqKou7n9PD2PuOU2pLHopZBaqLu4BYs/2PYD0ZC57qRYoqixjTE7v7w85fw9NTu/v",
    "Yzh/CU0oz0GjjZrOmymjCUGNTAn5db+9kHI1QJspCaPPjUxoQFm9bKTLSqNNKEHPCY2avTR1CZG+c/ltSlhppL3KQFcQ5CLDd9aR",
    "IpHldlbC1xEZP6510gIx1cKR5VZ2ItcRAz+u03QYMdV3EOTCI1fWkdLUrxkDdTA/dNSvAxnTMD+vyUYMS2HIOQw5R2CuS8nJOUkP",
    "q30bIeVKOUeuYQzJyRtJD32rOSHlYchGSg2vyTl95Q85G6shSavlDxs5fSFJ1ousvufrOlu+W6zq1uc7i9OE6lkyEFIF5lus1uu+",
    "O4sRhOozWNJSBeqKrOa/1ztbMgTr0xBYUoVYBOsR0jJShaw6B80sgjKwzbAGg6wsMjoE913arQLKfS2wBq2CzDI6AvZdrNoFy32C",
    "OgctzKwysK18XAQD2sv3231cAgStyvcF/cNe3sXbel96w8QF39v8VrN2q0SCrLffe8MExV/a/IKydkWqVq23xf3D3l8E23pEtnZX",
    "g6qss6q2doNWRayz/8/8TOmA5UJMQ/2A/+nkzkp8LoW3/OUh6EL9/oFN5c4BmWx4BAYboIHP/OhM/+VCNXZr50vTUgsEoG0AB3ka",
    "mMxRLoCnCzoQgBEuCsynO1A9/Vc2b3X5/aYRLswLgDtQ79Dhc4Mm4pUKUC6mgc07EHixaYdiQA9PQFDkMIvFvavdQZdaNnPMC2EB",
    "AHPNso/2A3pE4+YGyYg3C5fcc1rMQQd7ROfiAsiIj6jbyb4STcTmiEUDBuPIeuKIRQcD5sh6tY6gyOvc30zITaHcterejmrhnoKR",
    "fPeP6kyhtNzJ34584Z6Qgmv3j92PoOrItd5MkI6ean2D9+GCj558a5H24Xe6Yu3m1u15+m8vbUhVnUxz0ieVySc4aFRvL0lt+p1M",
    "RsVyvae015VtTC5V+0mdbnCw4MQ9BgEAHYMFD1xrmvuUpwCZnLGn2C1agPKDZ59pVGBU4shFlAClC5NNdoI0EDJoJLWBLj3X1/pb",
    "EF3C6IWSgabXI9/9Tb5tM0RmXCslf7ezCTYCadHcXo+STChmkDyMmouC6n7IFw89PNV0zto4BDojOixw/OaeW0rgPHFj6VlssoBr",
    "4PAhMstnN5YTMYC7l71gUrcfuENKt+742b3eTbroSPe5s7hDuk63+Nnt/hqr2XCOp52gHZt+ron32v4a26CZjqd9qR17nt6A96oe",
    "XXdJEUF0G3FbFx5xSRRNiiPp+L6T1AbeJgm645iE850+nsTdwMG+zT6+3ZDEkc6QPs6dtM3B3sQ+3rDNzZGelE4elhayL0x9W1Bl",
    "i6LS79tf4I1SpXJruprextujaGxsKVxB5D4SEY7/2jdtUw7zHLLuI6IM+Xbytn6s7AMZIv/u943kx5z2LqhAZ1AgRM1ArcBeQCck",
    "aCCoYEDHLkRd7YgtYnGOqWuhi219LoLpaO6IbSFijal7oot9bm2B6SjEIbjIGOET5Bgk6BSx6MPBwSHIuOjkExQYJBjhxOjDsTrc",
    "/Q7svWvxbNH96v2+Oww93A38/rpr4W7R7f0KvDv8fXcTuk8PAbQcYHJs1xLAX8dvUtxyHBBgEmBid1wcwN8mz1U9ROtdzlTOxUZb",
    "7S0/FhM4qDNcNq8zH6g2PFgWo/JSvD2g2S6rIFusornd/jIHYBzrAeCOcoFifAcQ6w7gfJsTzxYn0ZpuUov91M616rRa696OzWXy",
    "xmGnkk7dpuJlMs2NGKFsW2g7XRXBrWyCYTKNyF2lbBttOx1RhahswgGmMLVvhpRen65QYTaFBLYGprA/VYGUbpWuYFaxjwQ2gibT",
    "b8ZFSnUKZnmkrCtMQ0xjSap7JAymC2apfEQqTKOsLbg6PSeNj40viDy3Kq09624y2/NISxpDahL7OEvr3qnCWKgdUlpvXc9oGVJY",
    "qqKiwqhdaFlaH+D1JUUE0AZ/HMfOvcJ/UbOn5vvIv3xuV1NQEfzm84FOhl5B4xP8UfDUtZeA8V7FhZAGmzNQHdH1UPTlgWjDJKEo",
    "8aVg48FUhJqsK+pwo1ZzdnAUvAbm427mfmQGFuxzsHZwtBZs5uMOHdD4vtwVMTc81zjd9R4RsBXQuPw+HTHXPtfYNb0cEfCtsf5M",
    "go5Tt1K3vo3+jKNBrrFO8ryNU4dct46+TYKj8SixPAK3i5OWl7acuDuCIwErsQw3koiTtpK2vJsIhyMxfxwzct28rSGtESPfPLJ9",
    "fHwccz0iv63RohHTLH+9fTzPWb2LOZ+cI5lTLT+/m8yJz1mNuSufnDObUz0vj5nMuaXReZIQkMMnwNcpFXCSo5Gg0ZlwIpXDF15v",
    "IqIGljTHOI2ThIW6X+9Vj+OImrQ/jTqNg5XkuF+PVI+D6oi1P51P4lNIzJMNLQztI89TmE1CQ+JDXCifDc0I7cMjT5xNUp/nA8pJ",
    "LWk9ae0zTw0qmced58MJOi9pTWrtQz3PKZkHWr3NbirU+g76vg0qxN5abVS9bcoO2vou/r4tBGraWs0YbM6wDRq4671r7gjKEBi8",
    "Gmy+zeAYuAuwaw7quB0YzLQrBxOaDjoxOiE3lA4Duhu+KxcKMwQ6kTMhlz4UCroLnmUL+gBto27FZZEOwMf9a/BrYcWXzs0Fx2UB",
    "kG7F/csvKDuTHWG1370v2x8xYyWYCi+Ip91VhKuNK6jahVcEr3HZu0AlU2VBZdFLIbNQdUlz2Uu1QFFlIWDRK0NBVXW5DxB7tu8B",
    "pHdocnp/H8P5e/97ehhzz2lyY3J6f3/I+RtoQnkOGm3UTNpMSRh9bmQCbUIJek5o1BzeTBlNCGpkcgPK6mUjXVZCU8JKI+1VBmrI",
    "r/vthZSrSaWpS4j0ncvvgiAXGb6zjryOLLeyE7mOEIMgFx65so68iSy3sxK+jhD4cZ2mw4ipHqN+HciYhvmh+HGtkxaIqc6mfs0Y",
    "qIP5kU02YlgKQ855yjlyDWNITlZDNlJqeE3OCcg5AnNdSk5mSHroW80JKd8tf9jI6QtJWkl6WO3bCCnPK3/I2VgNSepeZPU9X9fZ",
    "st9itV733Vk0V2Q1/73e2VLdYlW3Pt9Z9CBUn8GSliqIIliPkJaRKsQmVM+SgZAqmCFYn4bAkiqU1TloZhGUgWWBNWgVZJbRadQ5",
    "aGFmlYEVhjUYZGWR0Wmw72LVLljuE+7jEiBoVb7fuO/SbhVQ7iPl4yIY0F6+b+gf9vIu3tYr3hsmKP7S5v/uH/b+ItjWK9IbJi74",
    "3ub/lLUrUrVqvRW1tRu0KmKdVZq1WyUSZL21srW7GlRlnSV/5mdKBywX+hfq9w9sKndGfOZHZ/ovFwoa6gf8Tyd3ZshkwyMw2AAN",
    "AG0DOMjTwCTicym85S8PUbFbO1+allqojnIBPF3QgWCNcGFeANyBMoByMQ1s3oFQjHBRYD7dgQKHDp8bNBGvfIIih1ks7l0F6b+y",
    "eavL7++LTTsUA3p4wg661LKZY17oWbjkntNiDrpE3U72lWgifgsAmGuWfbQP2CM6FxdARjxHLDoYMEfWE9AjGjc3SEYcRywaMBhH",
    "1jN1BEVe5/5mqmcKpeVO/nZUfgRVR671ZupuCuWuVfd2RAv3hBRcu3/kfPTkW4u0DxcL9xSM5Lt/VHT0VOsbvA+H0xVrN7duz7t6",
    "e0lq0+9komNyqdpP6nRrf3tpQ6rqZNIqlus9pb2uNBgseOBa09zvkz6pTD7BQZuDBSfuMQgAgDwFyOSMPcWmXZhsshOkgSjW34Lo",
    "EkYvvNEClB88+0xrQSOpDXTpuZZtmyEy41op8QKjEkcuogSgDDS9Hvnub5K7nU2wEUiL/njo4ammc9a+99xSAueJGzP2epRkQjGD",
    "5CHQGdFhgePHkVk+u7GciAlh1FwUVPdD5s9ikwVcA4dP3L3sBZO6/QAd0nW6xc9ux+3Y9HNNvNcGHVK6dcfP7sXXWM2Gczzt9O3Y",
    "8/QGvFdNbtJFR7rPnfXX2AbNdDzt8+i6S4oIotvwNknQHccknPf28e2GJI50btu68IhLomiK9PEk7gYO9u328YZtbo70JBxJx/ed",
    "pDZQ9HHupG0O9oZ08rC0kH1hotX0Nt4eRWPT/Ne+aZtymHfbgipbFJV+70vhCiL3kYhgt/VjZR/IEJH+Am+UKpVb25B1HxFlyLfj",
    "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",
    "JnNi5puIqIElzbHXVM/LYyZz7uZ0niQE5PBJaXQmnEjl8AVodUoFnORoJPBWY+7KJ+fMc+MkYaHu1ztO4ziiJu1PY9X78MgTZ5MU",
    "QuOgOmLtTyfV+BQS82RDy5P4EBfKZ0PzkPvI8xRmkxBD42AlOe7Xo075gHJSS1rP5/vMU4NK5nFabwuBmrZWs7/7UM9zSuaBWm+z",
    "mwq1voNWb5uyg7a+C1Vvgwqxt1abvvlwgs5LWlPnmzNsgwbuOgaaO4IyBAZv78ilD4WC7sJMmoM6bgcGM+zKwYSmg04M7cqFwgyB",
    "TqTvyA2lw4Duhk6bbzM4Bu6CBtmCPkDbqJtnWaQD8HH/WnEKqnbhFcFr41kApFtx//Jxys5kR1jt9wsL4ml3FeGqwsv2R8xYCWbv",
    "WljxpXNzAfz2LlDJVFlQXPRSyCxUXVJZnN7fH3L+xpj0ylBQVV0uWMSe7XsA6d0Dnh7G3HOa3P+c3t/HcP4emvZSLVBUWchcUJ6D",
    "Rhs1E5pTEkafG5mANuoSIn3n8ntpU0YTghqZnDeyetlIl5XQgOt+eyHlahLysNJIe5WB2pRQgp4TGjVHm8hFhu+sI68gy63sRK4j",
    "hCNfMwbqYH6kqcvtrISvI0QiXKfpMGKqB35c66QFYqozfl8HMqZhfuioyIVHrqwj7yCNGJbCkHNek45cwxiSk5VyH3I2VkOS+sqO",
    "wFyXkpMZch76VnNCyjeSHlb7NkLKc5IfNnL6QpJWy42UGl6Tc8KQWX3P13W2rBdYrdd9dxbNt9anIbCkCmUIWNWtz3cWfbfVZ7Ck",
    "pQoiCNWzZCCkCqYJ1iOkZaQKsQhZzX+vd7bUFQ6aWQRlYFl1DVoFmWV0WmC4CAa0l+9b+Q0GWVlkdJphu1i1C5b7BOy7tFsFlPsI",
    "7rgECFqV77f7DlqYWWVgBXWHvbyLt/UK+oYJir+0+b/37a4GVVlniWyGiQu+t/m/9O2KVK1abwVl7VaJBFlvrWbtBq2KWGdVbYe9",
    "vwi29Yr7+ZnSAcuF/p/6/QObyp3RhdbOl6alFmrs+gH/08mdmYbZ8AgMNkADMlwKb/nLQ5T42wAO8jQwCUD50Zn+y4UCn1wATxd0",
    "IJijXJgXAHegTCPTDsWAHp7wYlwUmE93oAAjw+cGTcQr36GvbN7q8vt7+shhFot7V4GgXEwDm3cgFKAutWzmmBe6gy6557SYg24W",
    "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",
    "F0UslnCFNbK4LfDjCeshxy85Kso1hLNwueMs8Hr99v+tFfdEqjl8HGoAZrH3/BRFrHv/9xX9RPas93v///169633RBRr1v0NvcN2",
    "zH04HKprsABmADiwZmt8qh2tNZqNi1YUYTpTFbTZ/jGLFTVWYIusjZtXNGAVi5qtjXPI1mwm4yVDMFP/i9g6tRUJLo0nc+FOMf9T",
    "izDZFDq1L8XLAIInvR4ahddMJMH1R3h3CNSz+z4xJsUfvYLLLgE+d/owsnnVCfSFwUckG03W14RNGiVHwPXAhUf0JdcaTeh47aDz",
    "7Pzg8664VqOR6GL8eO3g8uig7e144fzy7OigoHnp7PL84OzorpBio/NWubiuVvOiY5Hoka5i6aK58lbsochEpkiCVVu/y3bH4jlb",
    "gqFIVKbsRchIoFSCp8jsRf1IumZU4OzqOL/jW8dad8uFPRRTH872KR9ft8W/J7qFaMiE5ut+7NNJkv+jP3kMCezJftLqaOaFf8jS",
    "7OuEaObmyWiE6uzTfg2TeQg/SaL/PtSHUnPfY4l5kgkNP/9Jogg/7lutZxlEETkgSZzrpQMZPmZFrAlb72c/RBis7wlbWz8I760Z",
    "RGalOeoDnRFJICE5SBCdA+ul6jkCpZ0hEUns8UTC0UFFFyNTB4Q8/kMVRPFAF9Dtw0VB8RZE0UXsw8Px7EXQRRdAQlP/FT0ihQY4",
    "Wt7NNE9SrFNaTqw0Ocze6PCXS+XkXBv+DY7LIfrRUV3x5Rrk6EqX5fAbXOWW6UpK8emW5Vwb5NEN+lEg/suPys8bPNAUFjwWzhU8",
    "0Mo9GruYYu6qtoB9VmwBGzFEx5uAmbZ8q7ruYraYfIGrYrru7pi6YqqAfbfHbUWbMFYaAQFtG1cwmkTHRW2bxjEAVxpPDxYGdGSv",
    "F5yyg1BT9Ek7jYPfzrsj2JRkDxavdRZOB+MAcWAm3Z5sSLP1O1KcUIODslGdUjr0SfWzO0hTgpxQ7vzaNI3bRJr7M7blv9dvYNEj",
    "AtSvbY8U2/yaRIzb7jSOImwVr9HVA28y1mG/++W3NYG1Zu1bIybXM2Bvvrf75cY8vTYGOwkh4dQeoHBVTsEIPTshBsc2vDo9IQgH",
    "vcY2NzzHvAYJITpO1VTAceGgHh/UoOBwwVVOVNTAT3Ef4KBKxrDSv4h4YFQqDtr2DPVYLBJIL89VMhGJxmB4vrBK0jMTVBDOLS5J",
    "9CoMWfZU2g4OKtpU9lgM9QwrWPT2DlTaXyF+NihdAoH2mojIu3OvfgIhXIApXzd+XCCAAyl/Xjc2IF5/KAOBXa6acn+698iJiJrI",
    "97p/cq9zm36uuon2yNAfdRpwV+1TApPuQsq7sd8kls2l+GvSg1YfU+xxddAb05drgvglpMywk7rfygND7u+SQgLL37qxupPesMvv",
    "AkMLyenIpCGNNzIq6JD+Ae8jjMkhN6ULyehVGSxjjukpN3K3pWHaI61T7isAI/4zkOiDvBPgB+4lSyS970sHguATyuwPvi/aQ3Wf",
    "p2eg331iMULt23Uuyr4P2+11Qi8Oyr6/7csOLkJ12mKnfTDfn6FnZ6ahn98xfWJ9pjFj32eeoaG0VceVuthg5WUFEPwyGn/ZtLtg",
    "laDGVd6lhSTqZ7sBxrWhVJXYYLsaZTN+/eQRBAVkEeT9fjMaMmR/G/0E5BHRUegAcH1JwUDqLdyvcQhJGDGtKGH5lhF8UcBJcenQ",
    "AZYx+RBgGSmt1iwQ7XcVZ7m5MhvgzvzLssoy/bPPuOAarhwQ5vA1K5tSv+yD+QfOMiodNJvwr+YQNB2aKvERrubnHK4Q8CubNM++",
    "BjL4U4Pt7L+CU/kzBs4HvjLO+O1TgzyFwjnbIo9/QUKqSIxhDw2PhSJ/2jw5wyOFfo7bwj05OYU8w9uOfyLAWYDxlqF6E+OIer0/",
    "wtnvYEMMD42rQEjTeznAm4fpKY5v6hAdAifA6HuHKZvTwTmHeynpmznSwcF70zma6SmHJm4CwRyOEevqbhCPHcACJwNvwCYc6o4R",
    "koV4T/n+C97i+F9j4HJqr2WYFM/ptcGS/4XeCvh4k0/BmLST6WXOFRgbk8SDRDynX/lj4uCucmpy+K9q4V7jYiW3u9bLPPpo7ku/",
    "+MTruXElXJajwuGmAz22afvKuiTXp13gAsMlopat/iQUoHcRLX+qTXev3gjLCavfyq9+dk1g8IiAuJIHwLIYfwPjeoWVzElNbxKL",
    "ifmS8cAGuIhggIlJi/kSzW9MhRl7leKyAn/d2+IV4bHNPnsZlYTjfrMCzMIDqCwBM82Gfoc1XmxPp8Ac397zE7XDAMPNMi0DzKi0",
    "HRPD8sHe309/badehjSGaJOpQ5Ej0VzRkiNdkGlDqXmmS+t1NfJecH0AjluAGGKAgASXO/QLOTWmX/N0S3nqC4H0OTqAlgUYfIBi",
    "WnCPARy9UK6bvHPHcr28x5ocr1F431k/YW+2K8sY0x5ok9ZOac2w66BlzJrUIqrq3bT9LJtg744s8nCFbciNCOKliDjH6JpX7MoI",
    "3/kYKWZo63p4pia2nHBaq+AeXQERMR5uokVjTFBdMAuTO8huhoLGI/UwZ6dmWNPQzW9cH6IwHhEBsfsbjcgB5z13XF1V6v4ey/wD",
    "tHUABOnTnt+JO6d06I92+QO5eNsJJ+kDBNEA/He0LKHd1Bd1jT7eoNUvFT10jT2gjXYV1d8sd6E9jBbdLNUT1kOOX3JUlFkIx+Fz",
    "a+Bm4QprZHFb4MdrCGfhcsdZ4GNL3tMuilgs3EvSYi8ui1gvS1qILNLeY4pILlss3mPT+nA4VNdgAcxVc/g41ADMYtes+xt6h+2Y",
    "AHBgzdb4VDv++/XuW++JKPT67f9bK+6JK/qJ7Fnv9/7v+SmKWPf+7xJcGk/mwp1idaYqaLP9YxZgpv4XsXVqK/+nFmGyKXRq5pCt",
    "2UzGS4ZaazQbF60owq9owCoWNVsbK2qswBZZGzevCZs0So6A6zQKr5lIguuP6QuDj0g2mqyAC4/oS641mnzu9GFk86oTXoqXAQRP",
    "ej1Mij96BZddAvDuEKhn931icV2t5kXHItHmXXGtRiPRxdFdIcVG561yIl3F0kVz5a1B89LZ5fnB2dHx2kHn2fnB2/HC+eXZ0UH5",
    "8drB5dFB2wp7KKY+nO1Ttn6X7Y7Fc7Zxfse3jrXulj++bot/T3QL+5F0zajA2dXYQ5GJTJEEq5BAqQRPkdmLBUORqEzZi5B9qA+l",
    "5r7HEpIk/0d/8hgSGybzEH6SRP/zJBMafv6TRMyT0QjV2af90ZAJzdf92Kf/kKXZ1wnRzNmT/aTV0cwLQ3KQIDoH1ksickCSONdL",
    "B0pz1Ac6I5JA1HMESjtDIpK2fhDeWzOIzBB+3LdazzKIzn6IMFjfE7YzfMyKWBO23nG0vJtpnqRYRqYOCHn8hyqEpv4rekQKDae0",
    "nFhpcpi9huPZi6CLLoDY44mEo4OKLoPiLYiii9iHiOKBLqDbh4uUnzd4oCksePwbHJdD9KOjoxv0o0D8lx8snCt4oJV7NJXi0y3L",
    "uTbI0OEvl8rJuTbK4Te4yi3TlbviyzXI0ZUuA9o2rmA0iY6t2AI2YoiON47bijZhrDQCito2jWMArjTdMXXFVAH7bnYxxdxVbQH7",
    "bTH5AlfFdN0AM235VnXdxQZlozqldOiTOGUHoabok3aRZut3pDihBupnd5CmBDmhxgHiwEy6PdmeHiwM6MheL8geLF7rLJwOGwe/",
    "nXdHsClqAmvN2rdGTPZnbMt/r9/A32Ssw373y2+vZ8DefG/3yxxF2Cpeo6sH3fm1aRq3iTS2+TWJGLfdaaJHBKhf2x4pPqhBweGC",
    "q5zDqT1A4aqcgpyqqYDjwkE9qaiBn+I+wEFueI55DRJCdIx5em0MdhJCdHpCEA56jW0RenZCDI5teB1UtKnssRjqqFQctO0Z6rHo",
    "VRiy7Km0HRlWsOjtHai0ZiaoIJxbXJKUjGGlfxHxwBONwfB8YZWkWCSQXp6rZCIRNZHvdf/kXuw1EZF35179XTXl/nTvkRPnNv1c",
    "dRPtkWxAvP5QBgK7v0L8bFC6BAK4QAAHUv68bgRCuABTvm783yWFBJa/dWMFJt2FlHdjv2Endb+VB4bcdCe9YZffBYanL9cE8UtI",
    "maA/6jTgrtqnrD6m2OPqoDdJLJtL8dekBwZ5J8AP3EuWZFTQIf0D3kfdVwBG/Gcg0Uh635cOBMEn5G5Lw7RHWqcWktORSUMab6oy",
    "WMYc01NuGZNDbkoXktHOTEM/v2P6xD5Pz0C/+8RixE77YL4/Q8/7TGPGvs88Q3/blx1chOq0lNkffF+0h+q32+uEXhyUfYTat+tc",
    "lH0fCsgiyPv9ZjTKywog+GU0/jTKZvz6ySMIZMj+NvoJyCONa0OpKrHBdkJpq44rdbHBvEsLSdTPdgOyaXfBKkGNq3NlNsCd+Zdl",
    "gNRbuF/jEJKtWSDa7yrOcpRl+mefccE1LWPyIcAyUlqjo9AB4PqSgviigJPi0qEDMGJaUcLyLSPZfwWn8mcMnKR+2QfzD5xln30N",
    "ZPCnBtsPfGWc8dunBs45XCHgVzZpXTkgzOFrVjZpOjRV4iNczVQ6aDbhX80hxxH1en+Es9+ChFSRGMMeGoCzAOMtQ/UmwIYYHhpX",
    "gZByCnmGtx3/RHgKhXO2RR7/Rgr9HLeFe3IfC0X+tHlyhtTdIB47gAVOHd/UIToEToBN3ASCORwj1gbegE041B0jg/emczTTUw6m",
    "93KANw/TUw/3UtI3c6SD0PcOUzang3O+8sfEwV3l1MXxv8bA5dReMTYmiQeJeE7k8F/Vwr3GxYIxaSfTy5wrJQvxnvL9F7z+C70V",
    "8PEmn8swKZ7Ta4Ml/1Sb7l69EZbcl37xiddz41r9SShA7yJaEla/lV/97JpPu8AFhktELUpud62XefTRe2zT9pV1Sa5KuCxHhcNN",
    "B7q3xSvCY5t9ZTH+Bsb1CisKM/YqxWUF/vYyKgnH/WYFEpMW8yWa35jB4BEBcSUPgCXjgQ1wEcEAmZOa3iQWE/PQJlOHIkeiuQ39",
    "Dmu82J5On/7aTr0MaQyjJUe6INOGUmk7Joblg72/mYUHUFkCZpoBhptlWgaYUYE5vr3nJ2qHOXqhXDd5547g+gActwAxxDD4AMW0",
    "4B4D5Hp5jzU5XqMWAulzdAAtC/JMl9brauS9a0y/5umW8tQAAQkud+gXco/RNa/YlRG+ljGmPdAmrZ3akBsRxEsRcfIxUszQ1vXw",
    "N8HeHVnk4QrwvrN+wt5sV6hFVNW7aftZ05ph10HLmDVi9zcakQPOez26AiJiPNxE3rg+RGE8IgLvuLqq1P09lmHOTs2wpqGbTU1s",
    "OeG0VsF3kN0MBY1H6ovGmKC6YBYmekAb7Sqqv1k9vxN3TunQH71Bq18qeuga70J7GC26WapYQrupL+oaffkHaOsACNKn0wcIogH4",
    "72js8gdy8bYTTl6WtBBZpL3HshCOw+fWwM24l6TFXlwWsRWRXLZYvMemxpa8p10UsVgnrIccv+SoKNcQzsLljrPAwxXWyOK2wI9X",
    "9BPZs97v/arm8HGoAZjF6fXb/7dW3BPf81MUse793/z369233hNR9eFwqK7BApgA4MCarfGpdq9Z9zf0DtsxXtGAVSxqtjbqTFXQ",
    "ZvvHLLXWaDYuWlGEVtRYgS2yNm7NIVuzmYyXDCS4NJ7MhTvF/k8twmRT6NTATP0vYuvUVpgUf/QKLrsEaRReM5EE1x+8FC8DCJ70",
    "euDdIVDP7vvE+Nzpw8jmVSdfEzZplBwB1wEXHtGXXGs00xcGH5FsNFm244Xzy7Ojg8274lqNRqKLo+O1g86z84Pz47WDy6ODtoPm",
    "pbPL84Oz47pazYuORaJFuoqli+bKW6K7QoqNzlvlIYFSCZ4isxdt/S7bHYvnbLGHIhOZIglWC4YiUZmyFyH3I+maUYGzqxT2UEx9",
    "ONunfnzdFv+e6Bbj/I5vHWvdLf8hS7OvE6KZJEn+j/7kMSSjIROar/uxT7In+0mro5kXmSejEaqzT/v6UB9KzX2PJeZJJjT8/CeJ",
    "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",
    "NRnLRHT+rEN5YYygoP6sjEN0YXl5/qxhjKB0Q/9p/kHloQjCwmn+CEH/oeXlaf6hCML/QdaStrCaRA/RtwdN+dLy2fW2kLaRtoxT",
    "Hx+QtlORtoy2tpC2jFMftpFvh/US8AO/9fWH9b8SbwPw8If1A7/1bxISh/VvA/D1v9aQHCX6Y1qwsJAcWiXWY/r6kBxjWrDWJSWQ",
    "HNZj+rBaME0zIP9rvxERTTO/IDBr//9NM2u/ETAgIE0zMGv/Eb/Tzb5Q+2MGOAiAjSavuNzqz6UdwPBrQh8fpR1CwM9r8OtEEhMj",
    "JUlzc0QSSRPrJSOcVSIFaT7YIyNVItgFnD5pxd0qDshvPpSU3So+DsVvyMjdKm8+lMUODt0qxW/IlD4+Uu101t+A4eFS7YB0Pt/W",
    "1lLt34DhPnR0Uu0+39bhgM7fz013iZz9/d/PnE3OiXd338+JnP3OTU3fz86Jd/2cl5HD14el2Hx8kcPY15elh4eRw6XYfJfX15HD",
    "l6WHfNgmlDlasDcDFxeUOQNaJjewsJQ5NwMXJlqCQ66DsDeGwLN8LKRx7qE/P3wsoaSz7nFxfCzuoT+zpKR8LLPucT+hBA6TOBYC",
    "bwICDpNvOAQCFhYOkwJvAgQ4OA6TBAIWAm/GiHH0zLa3Dw+Icbf0xrbMOETHAbgAToWFRMdOATgAuCC9H0bFqPmenr0f+UYgqMXF",
    "vR+o+Z4gRtFqyLFrUjt+22/ynBvWUXR0b/JRnNvWGxtv8tZRdNucnG/y29YbdFF6d6u7/jqQ5+d3q5C7ejr+/nerOpDneru7d6t6",
    "Ov7nkCnkQwhvvwqIiORDCggpv2+Lp0vQtYKhgKlDCKm/NIg95MzMeEItoYKCzMyheOQtQkLMzC2hguR4VW1OAFUX7++64s6VCbe5",
    "vb3izrmVurcJCeLOt7m9upWV4s66twm9ub6R9payI134+JH2XZa+I7KykfYjXfi+lpaR9r4jsvhd3tfxhWpkA0BA1/EDhd5kamK4",
    "Tm6LyDrGxrhOOm5iyItKdeGo8L1mBwd14WaoSr3w8HXhvWYHSqiodeFKvfAHZmC0r64TOCb4+LSvJq5gOBMTtK84Jvhgrq60r2A4",
    "E/gmNFdK/wCNDKOjV0oM/zSNAABXSo0MozT//1dKNI0AowxZeFDiY4Zx+vp4UHHiWYZjY3hQhnH6WeLieFBZhmP6cYIkPt3PjQuw",
    "sCQ+C92Cjc/PJD6NC7CC3d0kPoKNz7ALS1TQldQVfT09VNB9lUsV1N/kYDFDNpYXF+RgljHfNkNbgBc0y3yyKqdPp7l/D6xeXk+n",
    "rLmnD39/T6cPrF6nuZzFtikyhHYYGMW2dimchDJrJ1T8JkEaSkonVBr8a0EmlTH6wDrrFQAprX4nq7K/xsatfr8nKbKrq61+sr/G",
    "KSfDhYhbbhUY1kpAPjFpR2N2dkA+YzFKR2lpQD5HY3ZKMdvmr22Mcjbf3+avNm3bcoyM5q9yNt/bbW3mr9tyjN82t3e5h5RuJume",
    "zj6y6ZGHCgrOPoeynpHp6c4+kYcKnrIdAyJ174X4398DIvh1HYXv7wMihfjfHXV1AyIdhe/f+O2afnng0zdubpp+N3nt0+Dgmn7T",
    "N27teXmafu3T4G43qv3+mhOkw9bW/f7DmqqkE/OTyQ4+KDCJiZPJMA7zKD5WzZuE6t+Nf3/Nm42EVt/q3bR2DG2fzPr6tHbMDN2f",
    "bZ1cXvltajwDP19hY5j+8pOTX2HyYz/+mJhfYf7ykz9jeggNjU8namlpCA1qjXonT5K8eysH9rZ3d7x7tiuS9ge59QrZxJfdAQH1",
    "Ct3ZuZfExPUKl90BudnZ9Qq5l8QB3fMjevB6gLB1dSN6sPDzgHp6I3qAsHXz8PAjevOAenWwh4Ql5HkH5eTkhCXl5IcHeQMElXKQ",
    "x/1UVASV/XIDx5DYRwDeob+x9vZHALHe2L+hoUcAv7H22N7eRwDYv6H2sTg3trKlb+bi4je25rI4b6WlN7Zv5uI4srI3tjhvpeLm",
    "kJgk9grQUrK4SHbgTtim6upIdqbguNhOpL90qVBZrqwEzLWiwsJjz4e6VS16oigoKLpVKC2HonrIgjoHjR8xQtOQkfY5wAktz6cn",
    "70Trr5ycpyev78/rRMMdcsbVPufHTFsX3+yec9XVWxdz30ye7OxbF55z1Uzf31sXTJ7s1XM0RRAdNEjolZVFEOgdNEg0NEUQSOiV",
    "NB0dRRA0SDSV6Od4c3gLMBYJCXhzFnjnMAsLeHMwFgnneHh4c+cwCwkW9Ggv7/33L0hIaC8v7/T3/f1oL/cvSPTv72gv9Pf9SC88",
    "N1+QjMF8y8s3X3yQPMGMLc7PHi6ZORdhhyfuAzAiOWFCUhQ2Yc5sbEJSzhRhYTY2QlJhzmxhFK9VhRde3iWH9gB8hroZvWN8H+wL",
    "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",
    "9h/xC9I0A7MCs/Yf0TTzCxsBA/LfNLP2v/YbAdM0A/KKy62OANho8j9mgDPd7Au1/LwG/1HaIQS/JvTxXNoBDMDpkzZSJYJdsV4y",
    "MkckkTTmgz3CWSVSkFKSNLdOJDExUPyGTNmt4uP85kNZ3K3igIZM6ePQrVL8Q1nsgNyt8uZtHQ5IJ9Xu8+fzbR0u1Q5IGO5DZy3V",
    "/g39DRjuI9VOZ+SceNf//czZl8jZ7/z93HR418/Z9P3snNnv3HT3/ZzIesiHfR05fFl9WXrIFzmMfc13eX0YOVyKWIrNdxk5fH1l",
    "cgN7QZkzoHszcGFCmaMFe2MILDjkOghwYaIFS5lzMx73E0rKxzLrOuse98PHEkr6M0sax8fiHuce+jPLx0IaQyBgIeAw+YYh8CZA",
    "4DCJY2Ah8IbjMEkgJkCAY+EwKfCAA4BbSHTsFG9sy/yAGHdLC+BUiEN0HIBse/tgjBhHzwSCWuzZ+5FvjJrvCdL7YVQmteMXrYYc",
    "u+8JYlTc+4GavUEXxfkmv225bb1B9yYfxUW3zbnxJm8dYR1Ft/0mz7mrp+N/frcKua8Dea53t7rr438OuXu3qqd5rrfrf7eqA0uD",
    "2JM6hJD6kPL7hkg+pIArGAq4eLoEXfargJhCPoTwR94iJMjMHIrUEipIzsyMJ3Xx/l7V5gRQKkiOJ8TM3BKb0JtbKe6se6l7m9Ar",
    "7pxb26tbmSDufJtwm9urK+5cmek7Iosfad9lO9KF7xtpbykii99lGWnvO4XvaykbaT/SJoa8aIzrpOPoTaYGdB0/UIisYyyG6+S2",
    "RjYA5H0dX6iq1At/UBduht9rdqBUF44KC39ghloXrtR2oIQKXxfeazOBb+JK+wqGCoYzgU/7auKCD+Y6QfuKY4Fjgg9G++o6T9MI",
    "MHqlxPDQyDBKc6X0DwgwyvB/pUTTMErzD3Cl1Mg4ph8njgeVZZ5lOKaPBxUnp58lPoYHZRhmGKefhQclPi3Y+AxL4rPQ3LgAK0ji",
    "0/34DLvQTeIj2AAr2P1M4tO4820zdEEOZhm5VEHdQwXdV2RjefFNDhYzXdHXs0QFXUn3wOp1+nSa+8wnq7IFeEGz6nWa+/d0+sB7",
    "+vDn9XTKmr8WZKJ0QqXBwkkog1Fsa5cSpKG0dkLFb0Noh8FZbJsiKvtrnNLqd7KzXgFQGaMPrGuccrLa6if7kiK7atzq93tmpxST",
    "BuRzNHY0ZqcE5BOTo3SUZgfkMxZWgWE9XIi45bYtx/ht/mrTKGfzvW3+2sbH+G3TZv66LfO93cZo/ipnqOApm+7sE3keeajg6ewj",
    "m+sZma7g7HMo6WaSfnuXe0jXUfj+PSCCX16I/90xIFL3+P6NXzcg0lH/3VH3PiBSiA3udpOn6dc+1z4N7qbpd5Pj1p4Hruk3fT59",
    "49au6ZcHqUo6Yd3vP6xBOmyt2u+vOTCP4pM4mQzjgwKTOD+Z7ODQ/dmmT2vHzGj1rf7XvNlI9sms301rx9D+3fhn1bxJqOkvP/nz",
    "FTaGpsYz0Mnlld8/+TOG+RXmL/bjjzn5FSY/Iml/cMe7Z7uod/KUhtCg1mBveyfJu7dydKKWpofQ0Pide0kcUK/QnXzZHZBbr5BN",
    "SRzQnV2vkHsdkJtNXK9w2ahXBws/ojcPPw+oVzeiBwtbNw+vN6IHCAcIWzc/ogevfniQR05YUk53UE5+SFhCnjdwDElFUNkvedxP",
    "NUBQKQcbah/rfQSA/Y39G2p/BBDra4/tHXoE8Bv6G2uPfQTgHYvzVip+Y2su+mYujnNjK1tWKm4ue2OL8y6OI1t6Y/tmleXKSvpL",
    "lwqEbaqOi2QH7o6L7aSOZGcKAC0lC4lJYq8nioJyqFvVoiw89kzAXCsq+BEjhCyoc9ByKKqHoluF0u1zfjzcIWdctP7K+Xx68k7+",
    "vE7EeXry+gOc0DINGWmfzeTJXr11MffuOVfNtHXxzclePfe9dcHkV830zb514TlEU4neUQRBg0GDRFNZBIHeXknTQVMEgYSDhF5J",
    "UwTRQXcOs5CAN2eBAGORcI43h7ezkGCBhzd3DpFwjreANwdj34/08o72Qn9Of9+PhPby8oJE/96P9nL/f/+CRI/28t7JE8y4fPPF",
    "BxjMt8xz8wXJACOSE3Z44j6SmXPR4vzs4eVdcvhaVXjhERZmwyYk5UzMFkZhIyQV5hPmzBYmJEVhffZqw/fBvlCb0TtmD8BnqABw",
    "nMn4LHeR2I17iKxR8cPfh4WSdInMJGugWFNkkl9zgsWU1HeJLI+owc4LS78gNNcyfmDAO1PBB1lS5JZi6r7gv5ZGoazbJpCzBcC7",
    "uk2DQ5V8MJJziG3XHT+7F3ZJ6OhJHbsX13Y/bYiVMJJDc3x8c4gwkm1DlZVDczCSfG2IFkzq9wJx9rM/dkm7F+jXHex2BJR5GjRs",
    "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",
    "1uGAdN/PTXeJnP3O38+cTc6Jd/3fz4mc/c5Nd9/Pzol3/ZxNkcPXh6XYfJeRw9jXl6WHfJHDpdh8l9eHkcOXpYd82NeUOVqwNwMX",
    "JpQ5A1omN7AXlDk3AxcmWrBDroOwN4bAgnwspHHuoT+zfCyhpLPucT98LO6hP7OkcXwss+5xP6GkDpM4FgJvAgQOk284BAIWAg6T",
    "Am8CBDgWDpMEAhYCbziIcfTMtrcPxohxt/TGtswPRMcBuABOhThEx04BOAC4hb0fRsWo+Z4gvR/5RiCoxZ69H6j5niBGxWrIsWtS",
    "O37Rb/KcG9ZRdNtv8lGc29YbdG/y1lF025wbb/Lb1ht0UZx3q7v+OpDnenerkLt6Ov7nd6s6kOd6u/53q3o6/ueQu+RDCG+/Cogp",
    "5EMKCCm/b4inS9C1gqGAi0MIqb80iD2pzMx4Qi2hguTMzKF45C1CgszMLaGC5HhCbU4AVRfv71XizpUJt7m9uuLOuZW6twm94s63",
    "ub26lQnizrq3Cb25lZH2lrIjXfi+kfZdlr4jsviR9iNd+L6WspH2viOy+F2W1/GFamQDQN7X8QOF3mRqQLhObovIOsZiuE46bmLI",
    "i8Z14ajwvWYHSnXhZqhKvfAHdeG9ZgdKqPB14Uq98AdmqLSvrhM4JvhgtK8mrmA4E/i0rzgm+GCuE7SvYDgT+CauV0r/AI0MozRX",
    "Sgz/NI0Ao1dKjQyjNP8AV0o0jQCjDP94UOJjhnH6WXhQceJZhmP6eFCGcfpZ4mN4UFmGY/px4iQ+3c+NC7CCJD4L3YKNz7AkPo0L",
    "sILdzyQ+go3PsAvdVNCV1BV9PUtU0H2VSxXUPeRgMUM2lhff5GCWMd82QxeAFzTLfLIqW0+nuX8PrF6nT6esuacPf15Ppw+sXqe5",
    "f8W2KTKEdhicxbZ2KZyEMhgnVPwmQRpKaydUGvxrQSZKMfrAOusVAJWtfiersr/GKa1+vycpsqvGrX6yv8YpJ6uFiFtuFRjWw0A+",
    "MWlHY3ZKQD5jMUpHaXZAPkdjdkoxaeavbYxyNt/b5q82bdtyjN/mr3I239ttjOav23KM3zZtd7mHlG4m6bfOPrLpkYcKns4+h7Ke",
    "kekKzj6RhwqesukDInXvhfjfHQMi+HUdhe/fAyKF+N8dde8DIh2F79/4dZp+eeDTN27tmn43ee3T4G6aftM3bu154Jp+7dPgbjd5",
    "/f6aE6TD1qr9/sOaqqQT1pPJDj4oMInzk8kwDvMoPonNm4Tq341/Vs2bjYRW3+p/tHYMbZ/M+t20dswM3Z9t+lxe+W1qPAOdX2Fj",
    "mP7ykz9fYfJjP/6Yk19h/vKTP2OYCA2NTydqaXoIDWqNeidPabx7Kwf2tneSvHu2K5L2B3f1CtnEl90BufUK3dm5l8QB9QqX3QG5",
    "2cT1CrmXxAHd2SN68HqAsHXzI3qw8POAenUjeoCwdfPweiN684B6dbDwhCXkeQfl5IeEJeXkhwd55ASVcpDH/VQDBJX9cgPHkFRH",
    "AN6hv7H22EcAsd7Yv6H2RwC/sfbY3qFHANi/ofax3je2sqVv5uI4N7bmsjhvpeI3tm/m4jiypTe2OG+l4uaymCT2CtBSspBIduBO",
    "2KbquEh2puC42E7qv3SpUFmurKTMtaLCwmPPBLpVLXqiKCiHulUoLYeieiiCOgeNHzFCyJCR9jnACS3TpyfvROuvnM+nJ6/vz+tE",
    "nB1yxtU+58fDWxff7J5z1UxbF3PfTJ7s1VsXnnPVTN/sWxdMnuzVc99FEB00SOiVNEUQ6B00SDSVRRBI6JU0HTRFEDRINJXoHXhz",
    "eAswFgnneHMWeOcwCwl4czAWCed4C3hz5zALCRZ4aC/v/fcvSPRoLy/v9Pf9SGgv9y9I9O/9aC/09/1IL+83X5CMwXzLPDdffJA8",
    "wYzLzs8eLpk5Fy2HJ+4DMCI5YUJSFDZhzmxhQlLOFGFhNmxCUmHObGEUNlWFF17eJYevAHyGuhm9Y/Yf7AvVZ682fBoVP4zduIfI",
    "z3IXCQDHmYz0C0KDGuy8sCb5NbcGijVFl8jyKFhMSX2XyEzyfVgoSSmm7nuQJUVuvDMVfC3jBwar2zQIOVsAvMq6bQL+a2kUOTTH",
    "14ZYCSNhl4R+3fGze3Ft94Oe1LF7OYfYNlTJByPJ14ZYOTQHI9k2VMk3hwgjgX7d8WOXtHsQZz9rwaR+L8euQcBGY0eZ1Px0GbqT",
    "vY8U2px9+bSzj6dBw8ZuR0CZR8BGY8euQZnHxm5HoEFDmXQZupPd/LSP9LQT2px9uY86lBfGCErnz3kY+i0lVZAPKXVY8B0qlQ9N",
    "UZOxTCTC9hrGCEo3lOfPyjhEF5YH6s/5LSVVcBiaD4PX0aHkjxQbG2nLOPVhC2mPEPQfWi6c5h+KIPwfVJ7mlC8tn11/e9DLOPVh",
    "G2kLaTsVacto+wFpC6tJ9BBtLWkfVB6KIPyf5qFVYj2mDwvJ/yvxNgBff1g/8Fv/JgF/WFGiP6YFaw3JYT2mD6tVAskxpgVrXaIP",
    "yf82AF//K3FYLwE/8Fv/dlho8orLrY4A2PMLArP2H9E0s/YbAQPy3zQLtT9mgDPd7CEE/LwG/1HaAQy/JvTxXNoDs/Yf8QvSNAPy",
    "v/YbAdM04uNQ/IZM2a2RNLFeMjJHJFKQ5oM9wlkl4oD85kNZ3K1S/IZM6ePQrfLmQ1nsgNytgl3A6ZM2UiUxMVKSNLdOJMzZ5Jx4",
    "1//9Dkjn820dLtX+DRjuQ2ct1dx0l8jZ7/z97Jx418/Z9P2cyNnv3HT3/e7zbR0OSCfVTmf9DRjuI9UzoGVyA3tBmYx9fVl6yBc5",
    "XIrNd3l9GDmjBXszcGFCmToIe2MILDjkczNwYaIFS5l8WXrIh30dOXx9WIrNdxk5+YZDIGAh4DASSjrrHvfDx+Ie+jNLGsfHiWMh",
    "8CZA4DBJIGAh8IbjMCnwJkCAY+EwMuse9xNKysdCGuce+jPLx5FvBIJa7Nn7d0tvbMv8gBgcgAvgVIhDdGFUjJrvCdL7HLsmteMX",
    "rYaBmu8JYlTc++wUgAOAW0h0R89se/tgjBgKuaun439+tx/FuW29Qfcmbx1Ft8258Sa6668Dea53t6qn438OuXu3qgN5rrfrf7e/",
    "bb1BF8X5Js+5YR1Ft/0mHIpH3iIkyMykgJDy+4ZIPgRdKxgKuHi6jCfUEipIzswEUHXx/l7V5twSKkiOJ8TMkPpLg9iTOoSE8Par",
    "gJhCPt9l6Tsiix9pnFupe5vQK+58m9urW5kg7m8pO9KF7xtp7zsii99lGWk/0oXvaykbaax7m9CbWynuXJlwm9urK+5uhqrUC39Q",
    "Fz9Q6E2mBnQd5LaIrGMshuuOCt9rdqBUF67UC39ghloX3mt2oIQKXxek4yaGvGiM61+oRjYA5H0dxPBP0wgweqVq4gqGM4FP+4pj",
    "gg/mOkH79A/QyDBKc6VE0wgwyvB/pdTIMErzD3ClCoYzgW/iSvvqOoFjgg9G+7PQLdj4DEviFSeeZTimjwdlGKefJT6GB9P93LgA",
    "K0jiI9j4DLvQTeLTuAAr2P1M4pVlOKYfJ44HJT5mGKefhQea+/fA6nX6dN1XuVRB3UMFFjNkY3nxTQ5Bs8wnq7IFePrA6nWa+/d0",
    "ypp7+vDn9XRmGfNtM3RBDl1JXdHXs0QFd7Iq+2uc0uprl8JJKINRbMVvEqShtHZCD6yzXgFQGaMn+2uccrLa6vd7kiK7atzqpcG/",
    "FmSidEKbIkNoh8FZbGrTti3H+G3+E5N2NGanBOQzFqN0lGYH5NrGKGfzvW3+ui3H+G3TZv4qZ/O93cZo/nM0ZqcUkwbkuOVWgWE9",
    "XIiCX9dR+P49ICObHnmo4OnscyjrGZmu4OxS916I/90xINJR+P6NXzcgUoj/3VH3PiATeajgKZvu7HtI6WaSfnuXP6ypSjph3e93",
    "k9c+De6m6Td949aeB67przlBOmyt2u8M4zCP4pM4mezggwKTOD+Z1z4N7naTp+mXBz5949au6TaG6S8/+fMV2Uho9a3+17zH0PbJ",
    "rN9Na5XfpsYz0Mnl5i8/+TOG+RUmP/bjjzn5FcfM0P3Zpk9rSaj+3fhn1bzQnZ17SRxQr6DWqHfylIbQt3Jgb3snybuQTXzZHZBb",
    "r5B7SRzQnV2vcNkdkJtNXK9nuyJpf3DHu9D4dKKWpofQUk5+eJBHTlgHCz8PqFc3ogcIWzcPrzeiQp53UE5+SFjZLzdwDElFUCkH",
    "edxPNUBQNw+oVwcLP6IHrwcIWzc/omsui/NWKn5jEOuN/RtqfwTwG2uP7R16BCtb+mYujnNji/NWKm4ue2P7Zi6OI1t6Y4D9G2of",
    "630E4B36G2uPfQTVoieKgnKoWwfuhG2qjotkZwqOi+2kjmQrKiw89kzAXHPQ+BEjhCyohdJyKKqHoluXCpXlykr6S2KvAC0lC4lJ",
    "MffN5MlevXXyTrT+yvl8evL6/rxOxHl68c3uOVfNtHXB5MlePfe9deE5V830zb51Z1ztc3483CFpnwOc0DINGWeBdw6zkIA3gd5B",
    "g0RTWQSBhF5J00FTBIe3AGORcI43dw6zkGCBhzcHY5FwjreAN0GDRFOJ3lEE0UGDhF5JUwTFB8kTzLh88/LyTn/fj4T2cv+CRP/e",
    "j/YFyRjMt8xz8+I+ACOSE3Z47OGSmXPR4vxCf9+P9PKO9vLef/+CRI/2vlB99mrD98HlTBEWZsMmJBXmzBZGYSMkZ6ib0TtmD8B3",
    "kQBwnMn4LPHD2I17iKxReOHlXXL4WlVFYRPmzBYmJFPB1zJ+YMA7X3NroFhTZJIsj4LFlNR3ieq+B1lS5JZi2ybgv5ZGoaxNg5Cz",
    "BcC7uswk34eFknSJIDSowc4LS7+btEeBh1cfraCqCsku0Aeo",
);
// py hash_f13 一系（2679-3060 行）与 AES_V3（2291-2477 行）的移植。
// 常量表（tt01/tt02、分支 orders、SV2、S_BOX、branch_one 大表）由
// 脚本从 py 原文逐值提取，见文件内 __HG_TABLES__ 段（勿手改）。

fn rol32(v: u32, shift: u32) -> u32 {
    v.rotate_left(shift % 32)
}

fn ror32(v: u32, count: u32) -> u32 {
    v.rotate_right(count % 32)
}

/// py get_iv：逐字节混 iv（偶字节与奇字节两条式子，u32 回绕）。
fn get_iv(mut iv: u32, data: &[u8]) -> u32 {
    for (i, &b) in data.iter().enumerate() {
        if i & 1 == 0 {
            iv = (iv >> 4) ^ iv ^ iv.wrapping_shl(6) ^ b as u32;
        } else {
            iv = !((iv >> 7) ^ iv ^ ((b as u32) | iv.wrapping_shl(12)));
        }
    }
    iv
}

/// py sum_md5：12 轮校验（偶/奇两条式子，最后置位 4 并异或 0x1000000）。
fn sum_md5(data: &[u8]) -> u32 {
    let mut cs: u32 = 0x20220420;
    for i in 0..12 {
        if i % 2 == 0 {
            let temp = (cs >> 3) ^ cs;
            cs = (data[i] as u32) ^ cs.wrapping_shl(7);
            cs ^= temp;
        } else {
            let temp = (cs >> 5) ^ cs;
            cs = (data[i] as u32) | cs.wrapping_shl(11);
            cs ^= 0xffffffff;
            cs ^= temp;
        }
    }
    cs |= 4;
    cs ^= 0x1000000;
    cs
}

fn bxor_bytes(b1: &[u8], b2: &[u8]) -> Vec<u8> {
    b1.iter().zip(b2.iter()).map(|(x, y)| x ^ y).collect()
}

/// py branch0_xor：8 元状态轮转（先算 n1-n7、再右旋一位、再写 x10/x8，
/// 顺序与 py 一致；x8 与 x1 重合时后写的 x8 胜出）。
#[allow(clippy::too_many_arguments)]
fn branch0_xor(
    data: &[u32; 8],
    base: u32,
    di: &[u32],
    tt03: &[u32; 64],
    round: usize,
    x1: usize,
    x2: usize,
    x3: usize,
    x4: usize,
    x5: usize,
    x6: usize,
    x7: usize,
    x8: usize,
    x9: usize,
    x10: usize,
) -> [u32; 8] {
    let mut d = *data;
    for i in 0..round {
        let offset = base.wrapping_add(i as u32);
        let n0 = di[(offset & 127) as usize];
        let n1 = ((d[x3] ^ d[x4]) & d[x1]) ^ d[x3];
        let n2 = rol32(d[x1], 26) ^ rol32(d[x1], 21) ^ rol32(d[x1], 7);
        let n3 = tt03[(offset & 63) as usize];
        let n4 = n0
            .wrapping_add(n1)
            .wrapping_add(n2)
            .wrapping_add(n3)
            .wrapping_add(d[x5]);
        let n5 = rol32(d[x2], 30) ^ rol32(d[x2], 19) ^ rol32(d[x2], 10);
        let n6 = (d[x2] & d[x6]) | ((d[x2] | d[x6]) & d[x7]);
        let n7 = n5.wrapping_add(n6);
        let o = d[x9];
        let old = d;
        d[0] = old[7];
        d[1] = old[0];
        d[2] = old[1];
        d[3] = old[2];
        d[4] = old[3];
        d[5] = old[4];
        d[6] = old[5];
        d[7] = old[6];
        d[x10] = n7.wrapping_add(n4);
        d[x8] = o.wrapping_add(n4);
    }
    d
}

/// py branch_0：tt01/tt02/tt03、pad、init_value、di 展开 112 轮、
/// iv_v0 分 6 组 branch0_xor 参数，末尾 32 字节折半异或 + sum。
fn branch_0(
    iv_v0: usize,
    khronos: i64,
    query_sm3: &[u8],
    body_md5: &[u8],
    ts_bytes: &[u8],
) -> Vec<u8> {
    let iv_v1 = BRANCH0_TT01[iv_v0];
    let count_v1 = iv_v1.wrapping_add(khronos as u32).wrapping_add(1) & 0xff;
    let count_v2_full = iv_v1.wrapping_add(khronos as u32);
    let mut tt03 = [0u32; 64];
    for i in 0..64 {
        tt03[i] = ror32(BRANCH0_TT02[i], count_v1);
    }
    let n0 = count_v2_full.wrapping_add(2) & 7;
    let seed = [0xfa_u8, 0x45, 0x61, 0xd7];
    let mut pad = [0u8; 4];
    for i in 0..4 {
        let v = (seed[i] as u16) | ((seed[i] as u16) << 8);
        pad[i] = ((v >> n0) & 0xff) as u8;
    }
    let count_v2 = count_v2_full & 0xff;
    let mut init_value = [0u32; 8];
    for i in 0..8 {
        init_value[i] = ror32(BRANCH0_INIT[i], count_v2);
    }
    let mut data = Vec::with_capacity(64);
    data.extend_from_slice(query_sm3);
    data.extend_from_slice(body_md5);
    data.extend_from_slice(ts_bytes);
    data.extend_from_slice(&pad);
    data.extend_from_slice(&[0u8, 0, 0, 0, 0, 0, 1, 0xa0]);
    let mut di = Vec::with_capacity(128);
    for i in 0..16 {
        di.push(u32::from_be_bytes([
            data[i * 4],
            data[i * 4 + 1],
            data[i * 4 + 2],
            data[i * 4 + 3],
        ]));
    }
    let mut di0 = di[0];
    for i in 0..112 {
        let di1 = di[i + 1];
        let di14 = di[i + 14];
        let r_di1 = rol32(di1, 14) ^ rol32(di1, 25) ^ (di1 >> 3);
        let r_di2 = rol32(di14, 13) ^ rol32(di14, 15) ^ (di14 >> 10);
        di0 = di0
            .wrapping_add(di[i + 9])
            .wrapping_add(r_di1)
            .wrapping_add(r_di2);
        di.push(di0);
        di0 = di1;
    }
    let v_j = match iv_v0 {
        5 => branch0_xor(
            &init_value,
            iv_v1,
            &di,
            &tt03,
            100,
            2,
            0,
            3,
            5,
            4,
            6,
            7,
            2,
            1,
            5,
        ),
        4 => branch0_xor(
            &init_value,
            iv_v1,
            &di,
            &tt03,
            96,
            0,
            5,
            6,
            7,
            3,
            1,
            2,
            5,
            4,
            4,
        ),
        3 => branch0_xor(
            &init_value,
            iv_v1,
            &di,
            &tt03,
            99,
            3,
            6,
            2,
            4,
            5,
            1,
            0,
            0,
            7,
            6,
        ),
        2 => branch0_xor(
            &init_value,
            iv_v1,
            &di,
            &tt03,
            96,
            7,
            6,
            2,
            1,
            4,
            0,
            5,
            4,
            3,
            5,
        ),
        1 => branch0_xor(
            &init_value,
            iv_v1,
            &di,
            &tt03,
            96,
            0,
            6,
            7,
            5,
            3,
            2,
            1,
            5,
            4,
            4,
        ),
        _ => branch0_xor(
            &init_value,
            iv_v1,
            &di,
            &tt03,
            101,
            5,
            7,
            6,
            3,
            2,
            1,
            0,
            5,
            4,
            3,
        ),
    };
    let mut ret = [0u8; 32];
    for i in 0..8 {
        ret[i * 4..i * 4 + 4].copy_from_slice(&v_j[i].wrapping_add(init_value[i]).to_be_bytes());
    }
    let first = bxor_bytes(&ret[..16], &ret[16..]);
    let sum = sum_md5(&first);
    let mut out = first;
    out.extend_from_slice(&sum.to_le_bytes());
    out
}

/// branch_one 大表（py _branch_one_bytes 的 lzma+b85 解包结果，81936 字
/// 节）：base64 存，首次用时解一次；table_f 在 iv_v0 切片内读 8 字节。
static BRANCH_ONE_TABLE: Lazy<Vec<u8>> = Lazy::new(|| {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD
        .decode(BRANCH_ONE_B64)
        .unwrap_or_default()
});

fn branch_one_read(base: usize, x: u64) -> u64 {
    let table = &*BRANCH_ONE_TABLE;
    let off = base + x as usize;
    if off + 8 <= table.len() {
        u64::from_le_bytes([
            table[off],
            table[off + 1],
            table[off + 2],
            table[off + 3],
            table[off + 4],
            table[off + 5],
            table[off + 6],
            table[off + 7],
        ])
    } else {
        0
    }
}

/// py r00：8 元查表混（table_f 索引皆为 8 的倍数，最高 16376）。
fn r00(r: &[u64; 8], tt: u64, table_f: &dyn Fn(u64) -> u64) -> u64 {
    let mut x = table_f(8 * (r[0] >> 56));
    let r1 = (r[1] >> 45) & 2040;
    if tt > 0 {
        x ^= tt;
    }
    x ^= table_f(r1 + 2048);
    let r2 = (r[2] >> 37) & 2040;
    x ^= table_f(r2 + 4096);
    let r3 = (r[3] >> 29) & 2040;
    x ^= table_f(r3 + 6144);
    let r4 = (r[4] >> 21) & 2040;
    x ^= table_f(r4 + 8192);
    let r5 = (r[5] >> 13) & 2040;
    x ^= table_f(r5 + 10240);
    let r6 = (r[6] >> 8) & 255;
    x ^= table_f(8 * r6 + 12288);
    let r7 = r[7] & 255;
    x ^= table_f(8 * r7 + 14336);
    x
}

/// py swap_v0：10 轮 8 元混（rr 由 ha0 旋出、da0 用旧值算、末尾按
/// typ 分两式回填；回填右值一律取旧 src，typ 分支的 src[6] 用旧 src[7]）。
fn swap_v0(
    src: &mut [u64; 8],
    src_xor: &[u64; 8],
    tt2: &[u64; 11],
    table_f: &dyn Fn(u64) -> u64,
    order1: &[u8],
    typ: Option<&[u64; 8]>,
) {
    let mut da0 = [0u64; 8];
    let mut ha0 = *src_xor;
    for i in 0..8 {
        da0[i] = src[order1[i] as usize] ^ src_xor[i];
    }
    for round in 0..10 {
        let mut rr = [0u64; 8];
        for k in 0..8 {
            let mut r = [0u64; 8];
            for j in 0..8 {
                r[j] = ha0[(k + j) % 8];
            }
            rr[k] = r00(&r, 0, table_f);
        }
        rr[7] ^= tt2[round + 1];
        let d = da0;
        let mut next = [0u64; 8];
        for k in 0..8 {
            let mut r = [0u64; 8];
            for j in 0..8 {
                r[j] = d[(k + j) % 8];
            }
            next[k] = r00(&r, rr[k], table_f);
        }
        da0 = next;
        ha0 = rr;
    }
    let old = *src;
    match typ {
        None => {
            src[0] = da0[0] ^ src_xor[0] ^ old[0];
            src[1] = da0[7] ^ src_xor[1] ^ old[1];
            src[2] = da0[6] ^ src_xor[2] ^ old[2];
            src[3] = da0[5] ^ src_xor[3] ^ old[3];
            src[4] = da0[4] ^ src_xor[4] ^ old[4];
            src[5] = da0[3] ^ src_xor[5] ^ old[5];
            src[6] = da0[2] ^ src_xor[6] ^ old[6];
            src[7] = da0[1] ^ src_xor[7] ^ old[7];
        }
        Some(t) => {
            src[0] = da0[7] ^ t[1];
            src[1] = da0[6] ^ t[2];
            src[2] = da0[5] ^ t[3];
            src[3] = da0[4] ^ t[4];
            src[4] = da0[3] ^ t[5];
            src[5] = da0[2] ^ t[6];
            src[6] = da0[1] ^ t[7] ^ old[7];
            src[7] = da0[0] ^ t[0];
        }
    }
}

/// py branch_1：tt1A 定 c_v1（ror64 后作 8 元 xor）、orders 切片、
/// tt1B 转 tt2、两次 swap_v0（第二次 typ 取首次结果），末尾取字节
/// 1/3/5/6 位折半 + sum。
fn branch_1(
    iv_v0: usize,
    khronos: i64,
    query_sm3: &[u8],
    body_md5: &[u8],
    ts_bytes: &[u8],
) -> Vec<u8> {
    let tt1a = BRANCH1_TT1A[iv_v0];
    let c_v1 = ror64(khronos as u64, ((tt1a as i64 + khronos) & 0xff) as u64);
    let order1 = &BRANCH1_ORDERS[iv_v0 * 8..iv_v0 * 8 + 8];
    let rot = ((tt1a as i64 + khronos + 1) & 63) as u64;
    let mut tt2 = [0u64; 11];
    for i in 0..11 {
        tt2[i] = ror64(BRANCH1_TT1B[i], rot);
    }
    let mut to_sign = Vec::with_capacity(64);
    to_sign.extend_from_slice(query_sm3);
    to_sign.extend_from_slice(body_md5);
    to_sign.extend_from_slice(ts_bytes);
    to_sign.extend_from_slice(&[0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    let mut src = [0u64; 8];
    for i in 0..8 {
        src[i] = u64::from_be_bytes([
            to_sign[i * 8],
            to_sign[i * 8 + 1],
            to_sign[i * 8 + 2],
            to_sign[i * 8 + 3],
            to_sign[i * 8 + 4],
            to_sign[i * 8 + 5],
            to_sign[i * 8 + 6],
            to_sign[i * 8 + 7],
        ]);
    }
    let src_xor = [c_v1; 8];
    let base = iv_v0 << 14;
    let table_f = |x: u64| branch_one_read(base, x);
    swap_v0(&mut src, &src_xor, &tt2, &table_f, order1, None);
    let mut data = [0u64; 8];
    data[7] = 416;
    let src_xor2 = [
        src[4], src[3], src[2], src[1], src[0], src[7], src[6], src[5],
    ];
    let first = src;
    swap_v0(&mut data, &src_xor2, &tt2, &table_f, order1, Some(&first));
    let mut ret = [0u8; 32];
    let mut n = 0;
    for i in (0..8).rev() {
        let pp = data[i].to_le_bytes();
        ret[n] = pp[1];
        ret[n + 1] = pp[3];
        ret[n + 2] = pp[5];
        ret[n + 3] = pp[6];
        n += 4;
    }
    for i in 0..16 {
        ret[i] ^= ret[i + 16];
    }
    let sum = sum_md5(&ret[..16]);
    let mut out = ret[..16].to_vec();
    out.extend_from_slice(&sum.to_le_bytes());
    out
}

/// py leftCircularShift：先把 k 压到 32 位再旋（bits=0 时即 k 本身）。
fn lcs64(k: u64, bits: u32) -> u64 {
    let bits = bits % 32;
    let k = k % (1u64 << 32);
    let upper = (k << bits) % (1u64 << 32);
    upper | (k >> (32 - bits))
}

fn md5_f(x: u64, y: u64, z: u64) -> u64 {
    (x & y) | ((!x) & z)
}

fn md5_g(x: u64, y: u64, z: u64) -> u64 {
    (x & z) | (y & (!z))
}

fn md5_h(x: u64, y: u64, z: u64) -> u64 {
    x ^ y ^ z
}

fn md5_i(x: u64, y: u64, z: u64) -> u64 {
    (y ^ (x | (!z))) & 0xffffffff
}

/// py FF/GG/HH/II：b + 旋（a + 函数 + M + t）；中间值可超 32 位，
/// 故用 u64 跑全程（py 亦不逐轮压 32 位，仅 I 自带掩码、末尾压 32 位）。
fn md5_ff(a: u64, b: u64, c: u64, d: u64, m: u64, s: u32, t: u64) -> u64 {
    b.wrapping_add(lcs64(
        a.wrapping_add(md5_f(b, c, d))
            .wrapping_add(m)
            .wrapping_add(t),
        s,
    ))
}

fn md5_gg(a: u64, b: u64, c: u64, d: u64, m: u64, s: u32, t: u64) -> u64 {
    b.wrapping_add(lcs64(
        a.wrapping_add(md5_g(b, c, d))
            .wrapping_add(m)
            .wrapping_add(t),
        s,
    ))
}

fn md5_hh(a: u64, b: u64, c: u64, d: u64, m: u64, s: u32, t: u64) -> u64 {
    b.wrapping_add(lcs64(
        a.wrapping_add(md5_h(b, c, d))
            .wrapping_add(m)
            .wrapping_add(t),
        s,
    ))
}

fn md5_ii(a: u64, b: u64, c: u64, d: u64, m: u64, s: u32, t: u64) -> u64 {
    b.wrapping_add(lcs64(
        a.wrapping_add(md5_i(b, c, d))
            .wrapping_add(m)
            .wrapping_add(t),
        s,
    ))
}

/// py md5sum_v3：SV2 转 sv、start/end 转常量、标准四轮（FF/GG/HH/II
/// 移位表与 py 一致）、末尾加 end 异或 + sum。
fn md5sum_v3(msg: &[u8], count_v2: u32, orders: &[u8], count_v1: u32) -> Vec<u8> {
    let mut sv = [0u32; 64];
    for i in 0..64 {
        sv[i] = ror32(MD5_SV2[i], count_v1);
    }
    let count_start = count_v2 & 0xff;
    let mut start = [0u32; 4];
    for i in 0..4 {
        start[i] = ror32(MD5_START[i], count_start);
    }
    let count_end = count_v2.wrapping_add(6) & 0xff;
    let mut end = [0u32; 4];
    for i in 0..4 {
        end[i] = ror32(MD5_END[i], count_end);
    }
    let (mut a, mut b, mut c, mut d) = (
        start[0] as u64,
        start[1] as u64,
        start[2] as u64,
        start[3] as u64,
    );
    let mut m = [0u64; 16];
    for i in 0..16 {
        m[i] =
            u32::from_le_bytes([msg[i * 4], msg[i * 4 + 1], msg[i * 4 + 2], msg[i * 4 + 3]]) as u64;
    }
    let o1 = &orders[..16];
    let o2 = &orders[16..32];
    let o3 = &orders[32..48];
    let o4 = &orders[48..64];
    let ff_s = [7u32, 12, 17, 22];
    for k in 0..16 {
        let (na, nb, nc, nd) = match k % 4 {
            0 => (
                md5_ff(a, b, c, d, m[o1[k] as usize], ff_s[k % 4], sv[k] as u64),
                b,
                c,
                d,
            ),
            1 => (
                a,
                b,
                c,
                md5_ff(d, a, b, c, m[o1[k] as usize], ff_s[k % 4], sv[k] as u64),
            ),
            2 => (
                a,
                b,
                md5_ff(c, d, a, b, m[o1[k] as usize], ff_s[k % 4], sv[k] as u64),
                d,
            ),
            _ => (
                a,
                md5_ff(b, c, d, a, m[o1[k] as usize], ff_s[k % 4], sv[k] as u64),
                c,
                d,
            ),
        };
        a = na;
        b = nb;
        c = nc;
        d = nd;
    }
    let gg_s = [5u32, 9, 14, 20];
    for k in 0..16 {
        let (na, nb, nc, nd) = match k % 4 {
            0 => (
                md5_gg(
                    a,
                    b,
                    c,
                    d,
                    m[o2[k] as usize],
                    gg_s[k % 4],
                    sv[16 + k] as u64,
                ),
                b,
                c,
                d,
            ),
            1 => (
                a,
                b,
                c,
                md5_gg(
                    d,
                    a,
                    b,
                    c,
                    m[o2[k] as usize],
                    gg_s[k % 4],
                    sv[16 + k] as u64,
                ),
            ),
            2 => (
                a,
                b,
                md5_gg(
                    c,
                    d,
                    a,
                    b,
                    m[o2[k] as usize],
                    gg_s[k % 4],
                    sv[16 + k] as u64,
                ),
                d,
            ),
            _ => (
                a,
                md5_gg(
                    b,
                    c,
                    d,
                    a,
                    m[o2[k] as usize],
                    gg_s[k % 4],
                    sv[16 + k] as u64,
                ),
                c,
                d,
            ),
        };
        a = na;
        b = nb;
        c = nc;
        d = nd;
    }
    let hh_s = [4u32, 11, 16, 23];
    for k in 0..16 {
        let (na, nb, nc, nd) = match k % 4 {
            0 => (
                md5_hh(
                    a,
                    b,
                    c,
                    d,
                    m[o3[k] as usize],
                    hh_s[k % 4],
                    sv[32 + k] as u64,
                ),
                b,
                c,
                d,
            ),
            1 => (
                a,
                b,
                c,
                md5_hh(
                    d,
                    a,
                    b,
                    c,
                    m[o3[k] as usize],
                    hh_s[k % 4],
                    sv[32 + k] as u64,
                ),
            ),
            2 => (
                a,
                b,
                md5_hh(
                    c,
                    d,
                    a,
                    b,
                    m[o3[k] as usize],
                    hh_s[k % 4],
                    sv[32 + k] as u64,
                ),
                d,
            ),
            _ => (
                a,
                md5_hh(
                    b,
                    c,
                    d,
                    a,
                    m[o3[k] as usize],
                    hh_s[k % 4],
                    sv[32 + k] as u64,
                ),
                c,
                d,
            ),
        };
        a = na;
        b = nb;
        c = nc;
        d = nd;
    }
    let ii_s = [6u32, 10, 15, 21];
    for k in 0..16 {
        let (na, nb, nc, nd) = match k % 4 {
            0 => (
                md5_ii(
                    a,
                    b,
                    c,
                    d,
                    m[o4[k] as usize],
                    ii_s[k % 4],
                    sv[48 + k] as u64,
                ),
                b,
                c,
                d,
            ),
            1 => (
                a,
                b,
                c,
                md5_ii(
                    d,
                    a,
                    b,
                    c,
                    m[o4[k] as usize],
                    ii_s[k % 4],
                    sv[48 + k] as u64,
                ),
            ),
            2 => (
                a,
                b,
                md5_ii(
                    c,
                    d,
                    a,
                    b,
                    m[o4[k] as usize],
                    ii_s[k % 4],
                    sv[48 + k] as u64,
                ),
                d,
            ),
            _ => (
                a,
                md5_ii(
                    b,
                    c,
                    d,
                    a,
                    m[o4[k] as usize],
                    ii_s[k % 4],
                    sv[48 + k] as u64,
                ),
                c,
                d,
            ),
        };
        a = na;
        b = nb;
        c = nc;
        d = nd;
    }
    let fa = (((start[0] as u64).wrapping_add(a)) % (1u64 << 32)) ^ end[0] as u64;
    let fb = (((start[1] as u64).wrapping_add(b)) % (1u64 << 32)) ^ end[1] as u64;
    let fc = (((start[2] as u64).wrapping_add(c)) % (1u64 << 32)) ^ end[2] as u64;
    let fd = (((start[3] as u64).wrapping_add(d)) % (1u64 << 32)) ^ end[3] as u64;
    let mut result = Vec::with_capacity(20);
    result.extend_from_slice(&(fa as u32).to_le_bytes());
    result.extend_from_slice(&(fb as u32).to_le_bytes());
    result.extend_from_slice(&(fc as u32).to_le_bytes());
    result.extend_from_slice(&(fd as u32).to_le_bytes());
    let sum = sum_md5(&result);
    result.extend_from_slice(&sum.to_le_bytes());
    result
}

/// py branch_2：注意 `iv & 15 - 2` 在 py 里是 `iv & (15 - 2)` =
/// `iv & 13`（减法优先级高于按位与），不是 `(iv & 15) - 2`。
fn branch_2(iv: u32, khronos: i64, query_sm3: &[u8], body_md5: &[u8], ts_bytes: &[u8]) -> Vec<u8> {
    let n0 = (iv & 13).wrapping_mul(86);
    let iv_v0 = (((n0 >> 15) & 0xff) + ((n0 >> 8) & 0xff)) as usize;
    let n1 = BRANCH2_T001[iv_v0];
    let count_v1 = n1.wrapping_add(khronos as u32).wrapping_add(1) & 0xff;
    let count_v2 = n1.wrapping_add(khronos as u32);
    let n0 = (count_v2.wrapping_add(5)) & 7;
    let seed = [0x84_u8, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8];
    let mut pad = [0u8; 8];
    for i in 0..8 {
        let v = (seed[i] as u16) | ((seed[i] as u16) << 8);
        pad[i] = ((v >> n0) & 0xff) as u8;
    }
    let mut data = Vec::with_capacity(64);
    data.extend_from_slice(query_sm3);
    data.extend_from_slice(body_md5);
    data.extend_from_slice(ts_bytes);
    data.extend_from_slice(&pad);
    data.extend_from_slice(&[0xa0, 0x01, 0x00, 0x00]);
    let idx = iv_v0 << 6;
    md5sum_v3(&data, count_v2, &BRANCH2_ORDERS[idx..idx + 64], count_v1)
}

/// py hash_f13：三段 get_iv 定 iv，iv_v0 定分支（0/1/2 全覆盖，
/// 其余值按 py 抛错）。
fn hash_f13(
    query_sm3: &[u8],
    body_md5: &[u8],
    ts_bytes: &[u8],
    khronos: i64,
) -> ApiResult<Vec<u8>> {
    let mut iv = get_iv(0x20230928, query_sm3);
    iv = get_iv(iv, body_md5);
    iv = get_iv(iv, ts_bytes);
    let iv_v0 = (((iv & 15) * 171) >> 9) as usize;
    let branch = (iv & 15) as i64 - ((iv_v0 * 3) & 0xff) as i64;
    match branch {
        0 => Ok(branch_0(iv_v0, khronos, query_sm3, body_md5, ts_bytes)),
        1 => Ok(branch_1(iv_v0, khronos, query_sm3, body_md5, ts_bytes)),
        2 => Ok(branch_2(iv, khronos, query_sm3, body_md5, ts_bytes)),
        _ => Err(ApiError::Internal(format!(
            "红果 hash_f13 无分支：{branch}"
        ))),
    }
}

/// py AES_V3 定制 AES（带 con 换位，不是标准 AES）：word_size 取
/// khronos 低 2 位，S 盒取全局表对应 256 字节段，密钥扩展 12 字，
/// 块加密为初轮 con2 + 两轮（Sub/Shift/轮1加 ShiftCon+Mix）+ 末轮
/// 4-7 字（与 py 的 [4:] 首 4 字一致）。
const AES_R_CON: [[usize; 4]; 4] = [[1, 0, 2, 3], [1, 3, 0, 2], [0, 1, 3, 2], [1, 0, 2, 3]];

const AES_R_CON2: [[usize; 4]; 4] = [[1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3]];

const AES_R_ORDERS: [[usize; 16]; 4] = [
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
    [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
];

fn aes_v3_sbox(word_size: usize, byte: u8) -> u8 {
    AES_S_BOX[word_size * 256 + byte as usize]
}

fn aes_v3_expand_key(aes_key: &[u8], word_size: usize) -> [u8; 48] {
    let init_values = [0xca025ddc_u32, 0x823dc546, 0xc9420583, 0xc298225f];
    let init_value = init_values[word_size];
    let mut mk = [0u8; 48];
    let seed = init_value.to_le_bytes();
    for i in 0..4 {
        mk[i * 4..i * 4 + 4].copy_from_slice(&seed);
    }
    for i in 0..16 {
        mk[i] ^= aes_key[i];
    }
    let mut rounds: u32 = 8;
    for i in 4..12 {
        let idx = 4 * (i - 1);
        let (mut k0, mut k1, mut k2, mut k3) = (mk[idx], mk[idx + 1], mk[idx + 2], mk[idx + 3]);
        if i & 3 == 0 {
            let k00 = (init_value >> (rounds & 24)) ^ aes_v3_sbox(word_size, k1) as u32;
            k1 = aes_v3_sbox(word_size, k2);
            k2 = aes_v3_sbox(word_size, k3);
            k3 = aes_v3_sbox(word_size, k0);
            k0 = (k00 & 0xff) as u8;
        }
        rounds += 2;
        mk[idx + 4] = k0 ^ mk[idx - 12];
        mk[idx + 5] = k1 ^ mk[idx - 11];
        mk[idx + 6] = k2 ^ mk[idx - 10];
        mk[idx + 7] = k3 ^ mk[idx - 9];
    }
    mk
}

/// py AES_V3.sum_data：每 8 字节取 8 个指定位拼 1 字节（共 31 字节），
/// 末字节固定 1。
fn aes_v3_sum_data(data: &[u8]) -> [u8; 32] {
    let mut key = [0u8; 32];
    for i in 0..31 {
        let idx = i * 8;
        key[i] = ((data[idx] >> 4) & 2)
            | (data[idx + 1] & 64)
            | ((data[idx + 2] >> 2) & 1)
            | ((data[idx + 3] & 16) << 3)
            | ((data[idx + 4] >> 1) & 4)
            | ((data[idx + 5] & 2) << 3)
            | ((data[idx + 6] & 1) << 5)
            | ((data[idx + 7] >> 4) & 8);
    }
    key[31] = 1;
    key
}

/// py AES_V3.mix_columns（静态方法，位翻转）：按 key 前 31 字节改
/// data 前 248 字节的指定位（清位后按 key 位填）。
fn aes_v3_mix_columns_bits(data: &mut [u8], key: &[u8]) {
    for i in 0..31 {
        let kk = key[i];
        let idx = i * 8;
        data[idx] = (data[idx] & !32) | ((kk & 2) << 4);
        data[idx + 1] = (data[idx + 1] & !64) | (kk & 64);
        data[idx + 2] = (data[idx + 2] & !4) | ((kk & 1) << 2);
        data[idx + 3] = (data[idx + 3] & !16) | ((kk >> 3) & 16);
        data[idx + 4] = (data[idx + 4] & !8) | ((kk & 4) << 1);
        data[idx + 5] = (data[idx + 5] & !2) | ((kk >> 3) & 2);
        data[idx + 6] = (data[idx + 6] & !1) | ((kk >> 5) & 1);
        data[idx + 7] = (data[idx + 7] & 127) | ((kk & 8) << 4);
    }
}

fn aes_xtime(a: u8) -> u8 {
    if a & 0x80 != 0 {
        (((a as u16) << 1) ^ 0x1b) as u8 & 0xff
    } else {
        a << 1
    }
}

fn aes_mix_single_column(s: &mut [[u8; 4]; 4], col: usize) {
    let t = s[0][col] ^ s[1][col] ^ s[2][col] ^ s[3][col];
    let u = s[0][col];
    s[0][col] ^= t ^ aes_xtime(s[0][col] ^ s[1][col]);
    s[1][col] ^= t ^ aes_xtime(s[1][col] ^ s[2][col]);
    s[2][col] ^= t ^ aes_xtime(s[2][col] ^ s[3][col]);
    s[3][col] ^= t ^ aes_xtime(s[3][col] ^ u);
}

fn aes_mix_columns(s: &mut [[u8; 4]; 4]) {
    for col in 0..4 {
        aes_mix_single_column(s, col);
    }
}

fn aes_add_round_key_con(s: &mut [[u8; 4]; 4], k: &[[u8; 4]], con: &[usize; 4]) {
    for i in 0..4 {
        for j in 0..4 {
            s[i][j] ^= k[i][con[j]];
        }
    }
}

fn aes_add_round_key(s: &mut [[u8; 4]; 4], k: &[[u8; 4]]) {
    for i in 0..4 {
        for j in 0..4 {
            s[i][j] ^= k[i][j];
        }
    }
}

fn aes_sub_bytes(s: &mut [[u8; 4]; 4], word_size: usize, con2: &[usize; 4]) {
    for i in 0..4 {
        for j in 0..4 {
            s[i][j] = aes_v3_sbox(word_size, s[i][j]);
        }
    }
    let rows = [s[con2[0]], s[con2[1]], s[con2[2]], s[con2[3]]];
    s[0] = rows[0];
    s[1] = rows[1];
    s[2] = rows[2];
    s[3] = rows[3];
}

fn aes_shift_rows(s: &mut [[u8; 4]; 4], order: &[usize; 16]) {
    let mut bs = [0u8; 16];
    for i in 0..4 {
        bs[i * 4..i * 4 + 4].copy_from_slice(&s[i]);
    }
    for i in 0..4 {
        for j in 0..4 {
            s[i][j] = bs[order[i * 4 + j]];
        }
    }
}

fn aes_shift_rows_con(s: &mut [[u8; 4]; 4], c: &[usize; 4]) {
    for i in 0..4 {
        let row = [s[i][c[0]], s[i][c[1]], s[i][c[2]], s[i][c[3]]];
        s[i] = row;
    }
}

fn aes_v3_encrypt_block(
    plaintext: &[u8; 16],
    key_matrices: &[[u8; 4]],
    word_size: usize,
    con2: &[usize; 4],
    order: &[usize; 16],
) -> [u8; 16] {
    let mut state = [[0u8; 4]; 4];
    for i in 0..4 {
        state[i].copy_from_slice(&plaintext[i * 4..i * 4 + 4]);
    }
    aes_add_round_key_con(&mut state, &key_matrices[0..4], con2);
    for i in 1..3 {
        aes_sub_bytes(&mut state, word_size, con2);
        aes_shift_rows(&mut state, order);
        if i == 1 {
            aes_shift_rows_con(&mut state, con2);
            aes_mix_columns(&mut state);
        }
        aes_add_round_key_con(&mut state, &key_matrices[i * 4..i * 4 + 4], con2);
    }
    aes_add_round_key(&mut state, &key_matrices[4..8]);
    let mut out = [0u8; 16];
    for i in 0..4 {
        out[i * 4..i * 4 + 4].copy_from_slice(&state[i]);
    }
    out
}

/// py AES_V3.encrypt：sum_data 得 32 字节明文 → CBC（iv 起）加密两块 →
/// key 前 31 字节位翻原 data → 回 key 末字节 + 改后 data。
/// py 的 decrypt 未被任何调用使用（且 inv_s_box 全零），故不移植。
fn aes_v3_encrypt(data: &[u8], iv: &[u8; 16], aes_key: &[u8], khronos: i64) -> ApiResult<Vec<u8>> {
    if data.len() < 248 || aes_key.len() < 16 {
        return Err(ApiError::Internal("红果 AES_V3 输入过短".to_string()));
    }
    let word_size = (khronos & 3) as usize;
    let con2 = &AES_R_CON2[word_size];
    let order = &AES_R_ORDERS[word_size];
    let master_key = aes_v3_expand_key(aes_key, word_size);
    let mut key_matrices = [[0u8; 4]; 12];
    for i in 0..12 {
        key_matrices[i].copy_from_slice(&master_key[i * 4..i * 4 + 4]);
    }
    let plaintext = aes_v3_sum_data(data);
    let mut previous = *iv;
    let mut key = Vec::with_capacity(32);
    for block in plaintext.chunks_exact(16) {
        let mut x = [0u8; 16];
        for i in 0..16 {
            x[i] = block[i] ^ previous[i];
        }
        let enc = aes_v3_encrypt_block(&x, &key_matrices, word_size, con2, order);
        key.extend_from_slice(&enc);
        previous = enc;
    }
    let mut out_data = data.to_vec();
    aes_v3_mix_columns_bits(&mut out_data, &key);
    let mut out = vec![key[31]];
    out.extend_from_slice(&out_data);
    Ok(out)
}

/// py _gen_medusa：Medusa 完整流程（proto 编码 + xmxor + 帧格式）；
/// hash_f13 与 AES_V3 两步调用上方占位，故最终在此报错。
#[allow(clippy::too_many_arguments)]
fn medusa(
    url: &str,
    params: &[(String, String)],
    data: Option<&Value>,
    data_type: &str,
    khronos: i64,
) -> ApiResult<String> {
    use base64::Engine as _;
    let query = url.split('?').nth(1).unwrap_or("");
    let body_md5_hex = json_body_md5(data, data_type).to_lowercase();
    let body_md5 = if body_md5_hex.is_empty() {
        [0u8; 16]
    } else {
        let raw = hex::decode(&body_md5_hex).unwrap_or_default();
        let mut b = [0u8; 16];
        b.copy_from_slice(&raw[..16.min(raw.len())]);
        b
    };
    let query_sm3 = sm3(query.as_bytes());
    let mut body_input = query.as_bytes().to_vec();
    body_input.extend_from_slice(&body_md5);
    body_input.extend_from_slice(b"none");
    let body_sm3 = sm3(&body_input);
    let ts_bytes = (khronos as u32).to_le_bytes();
    let query_body_ts_hash = hash_f13(&query_sm3, &body_md5, &ts_bytes, khronos)?;
    let version_name = params
        .iter()
        .find(|(k, _)| k == "version_name")
        .map(|(_, v)| v.clone())
        .unwrap_or_else(|| "7.4.3.32".to_string());
    let os_version = params
        .iter()
        .find(|(k, _)| k == "os_version")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    let device_model = params
        .iter()
        .find(|(k, _)| k == "device_type")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    let brand = params
        .iter()
        .find(|(k, _)| k == "device_brand")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    let manufacturer = brand.clone();
    let report_ts = 1728388016635i64;
    let (device_id, _) = current_devices();
    let device_msg = encode_device(
        &device_id,
        "",
        &os_version,
        report_ts,
        &device_model,
        &brand,
        &manufacturer,
    );
    let env_msg = encode_env(
        100 + (next_u64() % 21) as i64,
        10001 + (next_u64() % 2000) as i64,
        device_msg,
        now_secs(),
        &version_name,
    );
    let proto = proto(&[
        (1, ProtoField::Bytes(MEDUSA_MAGIC.to_vec())),
        (2, ProtoField::SInt32(3)),
        (3, ProtoField::SInt32(next_u64() as u32 as i64)),
        (4, ProtoField::Str("8662".to_string())),
        (5, ProtoField::Str(device_id.clone())),
        (6, ProtoField::Str("1588093228".to_string())),
        (7, ProtoField::Str(version_name)),
        (8, ProtoField::Str("v04.06.04-ml-android".to_string())),
        (9, ProtoField::SInt32(67503104)),
        (10, ProtoField::Bytes(320u64.to_le_bytes().to_vec())),
        (12, ProtoField::SInt32(khronos)),
        (13, ProtoField::Bytes(query_body_ts_hash.clone())),
        (14, ProtoField::Bytes(query_sm3[..6].to_vec())),
        (15, ProtoField::Msg(encode_request())),
        (16, ProtoField::Str(String::new())),
        (17, ProtoField::SInt32(khronos)),
        (18, ProtoField::Bytes(Vec::new())),
        (19, ProtoField::Bytes(body_sm3.to_vec())),
        (20, ProtoField::Str("none".to_string())),
        (21, ProtoField::SInt32(312)),
        (23, ProtoField::Msg(env_msg)),
        (24, ProtoField::Str("{\"cmr\":16777216,\"cmr2\":16777216,\"un_h\":1879194040,\"vpn\":0,\"kd\":0,\"fkd\":3672518972,\"pd\":-1872573247,\"dyn\":\"\",\"do\":0,\"tk\":true}".to_string())),
        (26, ProtoField::Str(String::new())),
    ]);
    if let Ok(flag) = TEST_PRINT_PROTO.lock() {
        if *flag {
            eprintln!("RUST_PROTO_HEX={}", hex::encode(&proto));
        }
    }
    let hash_rand = next_u64() as u32;
    let xm_rand = next_u64() as u32;
    let (key, seed) = get_key_hash(MEDUSA_SIGN_KEY, hash_rand);
    let mut mixed = xmxor(&proto, &key);
    let mut prefixed = 320u64.to_le_bytes().to_vec();
    prefixed.extend_from_slice(&mixed);
    mixed = prefixed;
    mixed.reverse();
    for (index, byte) in mixed.iter_mut().enumerate() {
        *byte ^= seed[(!index) & 3];
    }
    if let Ok(flag) = TEST_PRINT_PROTO.lock() {
        if *flag {
            eprintln!("RUST_MIXED_HEX={}", hex::encode(&mixed));
        }
    }
    let hash_bytes = hash_rand.to_le_bytes();
    let check_bit = ((query_sm3[0] as u32 & 63) << 14)
        | 0x18000001u32
        | ((query_body_ts_hash[0] as u32 & 63) << 8);
    let mut framed = vec![0x35u8];
    framed.extend_from_slice(&xm_rand.to_le_bytes());
    framed.extend_from_slice(&check_bit.to_le_bytes());
    framed.extend_from_slice(&mixed);
    framed.extend_from_slice(&hash_bytes[2..]);
    if let Ok(flag) = TEST_PRINT_PROTO.lock() {
        if *flag {
            eprintln!("RUST_FRAMED_HEX={}", hex::encode(&framed));
        }
    }
    let encrypted = aes_v3_encrypt(&framed, &MEDUSA_CONFIG_IV, &MEDUSA_CONFIG_KEY, khronos)?;
    let mut version_or = Vec::new();
    for chunk in MEDUSA_VERSION.chunks_exact(4) {
        let v = u32::from_le_bytes(chunk.try_into().unwrap()) ^ (khronos as u32);
        version_or.extend_from_slice(&v.to_le_bytes());
    }
    let mut result = version_or;
    result.extend_from_slice(&hash_bytes[..2]);
    result.extend_from_slice(&256u16.to_le_bytes());
    result.extend_from_slice(&encrypted);
    Ok(base64::engine::general_purpose::STANDARD.encode(result))
}

/// py _core_sixgod：gorgon/helios/medusa + ladon/argus/khronos，
/// 数据体类型由 data_type 决定 x-ss-stub。
fn sixgod(
    url: &str,
    params: &[(String, String)],
    data: Option<&Value>,
    data_type: &str,
) -> ApiResult<(Vec<(String, String)>, String)> {
    let (encrypted_url, url_params) = params_encrypturl(url, params);
    let khronos = now_secs();
    let query = encrypted_url.split('?').nth(1).unwrap_or("");
    let xg_rand = (next_u64() % 0x10000) as u16;
    let gorgon = encrypt_gorgon(data, query, khronos, xg_rand, data_type);
    let helios = encrypt_helios(khronos, 0);
    let medusa_value = medusa(&encrypted_url, &url_params, data, data_type, khronos)?;
    let mut headers: Vec<(String, String)> = vec![
        ("x-ladon".to_string(), {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD.encode((khronos as u32).to_be_bytes())
        }),
        ("x-khronos".to_string(), khronos.to_string()),
        ("x-argus".to_string(), {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD.encode((khronos as u32).to_le_bytes())
        }),
        ("x-gorgon".to_string(), gorgon),
        ("x-helios".to_string(), helios),
        ("x-medusa".to_string(), medusa_value),
        ("x-tt-dt".to_string(), String::new()),
    ];
    if let Some(body) = data {
        headers.push((
            "x-ss-stub".to_string(),
            json_body_md5(Some(body), data_type),
        ));
    }
    Ok((headers, encrypted_url))
}

/// py _signed_json_get：签名 GET（HTTP 400+ 报错），响应 code 非 0 报错。
/// py _hg_register_device（3892 行起）：向 log.snssdk.com 注册设备，
/// 成功返回下发的 (device_id_str, install_id_str)；两者须全数字且非
/// "0"，否则回 None；任何异常（网络、非 200、字段缺）都回 None。
/// 注册头按 py 原文固定值（app_version 7.3.5.32、package
/// com.phoenix.read、aid 8662 等），openudid 为 16 位随机 hex，
/// clientudid/cdid/req_id 为 uuid4。
const REGISTER_UA: &str = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";

fn uuid4_str() -> String {
    let a = next_u64();
    let b = next_u64();
    let mut bytes = [0u8; 16];
    bytes[..8].copy_from_slice(&a.to_be_bytes());
    bytes[8..].copy_from_slice(&b.to_be_bytes());
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn device_id_field(data: &Value, keys: &[&str]) -> String {
    for key in keys {
        if let Some(v) = data.get(key) {
            if let Some(s) = v.as_str() {
                if !s.is_empty() {
                    return s.to_string();
                }
            } else if let Some(n) = v.as_u64() {
                return n.to_string();
            } else if let Some(n) = v.as_i64() {
                return n.to_string();
            }
        }
    }
    String::new()
}

async fn hg_register_device() -> Option<(String, String)> {
    let openudid = format!("{:016x}", next_u64());
    let clientudid = uuid4_str();
    let cdid = uuid4_str();
    let req_id = uuid4_str();
    let ms = now_millis();
    let header = json!({
        "display_name": "红果免费短剧",
        "aid": 8662,
        "app_version": "7.3.5.32",
        "version_code": 73532,
        "manifest_version_code": 73532,
        "update_version_code": 73532,
        "channel": "update_64",
        "package": "com.phoenix.read",
        "app_language": "zh",
        "os": "Android",
        "os_version": "16",
        "os_api": 36,
        "device_model": "25053RT47C",
        "device_brand": "Redmi",
        "device_manufacturer": "Xiaomi",
        "cpu_abi": "arm64-v8a",
        "density_dpi": 520,
        "display_density": "xxhdpi",
        "resolution": "2772x1280",
        "language": "zh",
        "timezone": 8,
        "access": "wifi",
        "openudid": openudid,
        "clientudid": clientudid,
        "cdid": cdid,
        "region": "CN",
        "tz_name": "Asia/Shanghai",
        "tz_offset": 28800,
        "sim_region": "cn",
        "device_platform": "android",
        "not_request_sender": 0,
        "is_system_app": 0,
        "sdk_flavor": "china",
        "rom": "OS2.0",
        "rom_version": "BP2A.250605.031.A3"
    });
    let body = json!({
        "magic_tag": "ss_app_log",
        "header": header,
        "_gen_time": ms
    });
    let url =
        format!("https://log.snssdk.com/service/2/device_register/?req_id={req_id}&_rticket={ms}");
    let resp = client()
        .ok()?
        .post(&url)
        .header("User-Agent", REGISTER_UA)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let data: Value = resp.json().await.ok()?;
    let device_id = device_id_field(&data, &["device_id_str", "device_id"]);
    let install_id = device_id_field(&data, &["install_id_str", "install_id"]);
    if !device_id.is_empty()
        && !install_id.is_empty()
        && device_id != "0"
        && install_id != "0"
        && device_id.chars().all(|c| c.is_ascii_digit())
        && install_id.chars().all(|c| c.is_ascii_digit())
    {
        Some((device_id, install_id))
    } else {
        None
    }
}

fn clear_scan_cache() {
    if let Ok(mut guard) = SCAN_CACHE.lock() {
        *guard = None;
    }
    if let Ok(mut guard) = AUDIO_CACHE.lock() {
        guard.clear();
    }
}

/// py _ensure_registered：已注册且不限直接返回；已注册但受限调
/// renew；未注册调一次 register（成则换号，不成也标 registered
/// 不再重试），并清扫描缓存。
async fn ensure_registered() {
    let (registered, limited) = {
        let st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
        (st.registered, st.limited)
    };
    if registered && !limited {
        return;
    }
    if registered && limited {
        renew_device().await;
        return;
    }
    if let Some((did, iid)) = hg_register_device().await {
        let mut st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
        st.device_id = did;
        st.install_id = iid;
    }
    {
        let mut st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
        st.registered = true;
    }
    clear_scan_cache();
}

/// py _renew_device：受限且在 600 秒冷却内回 false；否则调
/// register，成则换号、清限、标 registered、清缓存回 true，不成则
/// 冷却 = now + 600 回 false。
async fn renew_device() -> bool {
    let now = now_secs();
    {
        let st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
        if st.limited && now < st.renew_cooldown_until {
            return false;
        }
    }
    if let Some((did, iid)) = hg_register_device().await {
        let mut st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
        st.device_id = did;
        st.install_id = iid;
        st.limited = false;
        st.registered = true;
        drop(st);
        clear_scan_cache();
        true
    } else {
        let mut st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
        st.renew_cooldown_until = now + 600;
        false
    }
}

async fn signed_get(url: &str, extra: &[(&str, &str)]) -> ApiResult<Value> {
    ensure_registered().await;
    let params = params_74332(extra);
    let (signs, signed_url) = sixgod(url, &params, None, "")?;
    let mut header_map = reqwest::header::HeaderMap::new();
    let mut push = |k: &str, v: &str| {
        if let (Ok(name), Ok(val)) = (
            reqwest::header::HeaderName::from_bytes(k.as_bytes()),
            reqwest::header::HeaderValue::from_str(v),
        ) {
            header_map.insert(name, val);
        }
    };
    push("User-Agent", APP_UA);
    push("Accept", "application/json");
    for (k, v) in &signs {
        push(k, v);
    }
    drop(push);
    let resp = client()?
        .get(&signed_url)
        .headers(header_map)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("红果请求失败：{e}")))?;
    let status = resp.status().as_u16();
    if status >= 400 {
        return Err(ApiError::Internal(format!("红果接口 HTTP {status}")));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("红果响应解析失败：{e}")))?;
    let code = body
        .get("code")
        .or_else(|| body.get("Code"))
        .cloned()
        .unwrap_or(json!(0));
    let ok = code == json!(0) || code == json!("0");
    if !ok {
        return Err(ApiError::Internal(format!("红果接口返回异常 code={code}")));
    }
    Ok(body)
}

/// py _signed_json_post：签名 POST（JSON 体），响应 code 非 0 报错。
async fn signed_post(url: &str, payload: &Value) -> ApiResult<Value> {
    ensure_registered().await;
    let params = params_74332(&[]);
    let data_type = "application/json; charset=UTF-8";
    let (signs, signed_url) = sixgod(url, &params, Some(payload), data_type)?;
    let mut headers: Vec<(String, String)> = vec![
        ("User-Agent".to_string(), APP_UA.to_string()),
        ("Accept".to_string(), "application/json".to_string()),
        ("Content-Type".to_string(), data_type.to_string()),
    ];
    headers.extend(signs);
    let resp = client()?
        .post(&signed_url)
        .headers({
            let mut map = reqwest::header::HeaderMap::new();
            for (k, v) in &headers {
                if let (Ok(name), Ok(val)) = (
                    reqwest::header::HeaderName::from_bytes(k.as_bytes()),
                    reqwest::header::HeaderValue::from_str(v),
                ) {
                    map.insert(name, val);
                }
            }
            map
        })
        .json(payload)
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("红果请求失败：{e}")))?;
    if resp.status().as_u16() >= 400 {
        return Err(ApiError::Internal(format!(
            "红果接口 HTTP {}",
            resp.status()
        )));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(format!("红果响应解析失败：{e}")))?;
    let code = body
        .get("code")
        .or_else(|| body.get("Code"))
        .cloned()
        .unwrap_or(json!(0));
    let ok = code == json!(0) || code == json!("0");
    if !ok {
        return Err(ApiError::Internal(format!("红果接口返回异常 code={code}")));
    }
    Ok(body)
}

/// py _collect_book_cards：递归收集含 book_id + book_name 的节点，
/// book_id 去重（首见为准），遍历顺序与 py 一致（dict 值 / list 项）。
fn collect_book_cards(node: &Value, out: &mut Vec<Value>, seen: &mut Vec<String>) {
    if let Some(obj) = node.as_object() {
        if let (Some(bid), Some(name)) = (obj.get("book_id"), obj.get("book_name")) {
            let bid = bid.to_string().trim_matches('"').to_string();
            if !bid.is_empty() && !seen.contains(&bid) {
                seen.push(bid);
                out.push(node.clone());
            }
            let _ = name;
        }
        for value in obj.values() {
            collect_book_cards(value, out, seen);
        }
    } else if let Some(list) = node.as_array() {
        for item in list {
            collect_book_cards(item, out, seen);
        }
    }
}

/// py _book_card：听书卡（vod_id=audio#书号，备注 N 章）。
fn book_card(b: &Value) -> Option<Value> {
    let bid = text_of(b, &["book_id"]);
    if bid.is_empty() {
        return None;
    }
    let name = text_of(b, &["book_name"]);
    let name = if name.is_empty() {
        text_of(b, &["book_short_name"])
    } else {
        name
    };
    let pic = text_of(b, &["thumb_url"]);
    let pic = if pic.is_empty() {
        text_of(b, &["detail_page_thumb_url"])
    } else {
        pic
    };
    let desc = text_of(b, &["abstract"]);
    let desc = if desc.is_empty() {
        text_of(b, &["book_abstract_v2"])
    } else {
        desc
    };
    let serial = int_of(b, &["serial_count"]);
    let serial = if serial == 0 {
        int_of(b, &["content_chapter_number"])
    } else {
        serial
    };
    let remark = if serial > 0 {
        format!("{serial}章")
    } else {
        String::new()
    };
    let category = text_of(b, &["category"]);
    Some(json!({
        "id": format!("audio#{bid}"),
        "title": name,
        "cover": pic,
        "remark": remark,
        "author": text_of(b, &["author"]),
        "desc": desc,
        "category": category,
    }))
}

/// py _bookmall_tab_books：书城 tab=5 一次取书（卡片已去重）。
async fn bookmall_tab_books(tab_type: &str) -> ApiResult<Vec<Value>> {
    let resp = signed_get(BOOKMALL_TAB_URL, &[("tab_type", tab_type)]).await?;
    let mut raw = Vec::new();
    let mut seen = Vec::new();
    collect_book_cards(&resp, &mut raw, &mut seen);
    let mut cards = Vec::new();
    for b in raw {
        if let Some(c) = book_card(&b) {
            cards.push(c);
        }
    }
    Ok(cards)
}

/// py _audio_scan_cards：调 4 次去重，空则再调 1 次（该次不去重，
/// 与 py 兜底分支一致）；进程内缓存结果与 vod_id→分类表。
async fn audio_scan_cards() -> ApiResult<(Vec<Value>, HashMap<String, String>)> {
    if let Some(cached) = SCAN_CACHE.lock().unwrap().clone() {
        return Ok(cached);
    }
    let mut cards: Vec<Value> = Vec::new();
    let mut cat_map: HashMap<String, String> = HashMap::new();
    let mut seen: Vec<String> = Vec::new();
    for _ in 0..4 {
        for card in bookmall_tab_books("5").await? {
            let id = text_of(&card, &["id"]);
            if seen.contains(&id) {
                continue;
            }
            seen.push(id.clone());
            cat_map.insert(id, text_of(&card, &["category"]));
            cards.push(card);
        }
    }
    if cards.is_empty() {
        for card in bookmall_tab_books("5").await? {
            let id = text_of(&card, &["id"]);
            cat_map.insert(id, text_of(&card, &["category"]));
            cards.push(card);
        }
    }
    let result = (cards, cat_map);
    *SCAN_CACHE.lock().unwrap() = Some(result.clone());
    Ok(result)
}

/// 听书分类：首项“全部”（id=audio），其余为扫描卡片里首次出现
/// 顺序的分类值（id 与 name 均为该分类名，catalog 按此过滤）。
/// py CENC 一系：_b64、derive_content_key（487-511 行）、_find_box、
/// _box_body、_parse_track（526-613 行）、_aes_ctr_decrypt、
/// _restore_cenc_codecs、_replace_sinf、_replace_box_type、
/// _rewrite_moov、decrypt_mp4_cenc（639-711 行）、_sample_table
/// （856-896 行）。音频中继走整文件 decrypt；_sample_table 供视频
/// 流式会话用，此处先移植备而不用。

fn b64_decode(input: &str) -> ApiResult<Vec<u8>> {
    use base64::Engine as _;
    let padded = {
        let mut s = input.to_string();
        while s.len() % 4 != 0 {
            s.push('=');
        }
        s
    };
    base64::engine::general_purpose::STANDARD
        .decode(&padded)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(&padded))
        .map_err(|_| ApiError::Internal("红果 spade base64 解码失败".to_string()))
}

/// py derive_content_key：raw 首 3 字节异或定 v8，取 raw[1..1+v8]
/// 逐字节混（偶数用 vb、奇数用 va，异或后减 21 再减 popcount），
/// 回 value[1..33] 的 32 位 hex 串解出的 16 字节密钥。
fn derive_content_key(spade: &str) -> ApiResult<[u8; 16]> {
    let raw = b64_decode(spade)?;
    if raw.len() < 3 {
        return Err(ApiError::Internal("红果 spade 过短".to_string()));
    }
    let mut v8 = raw.len() as i64 - (raw[0] ^ raw[1] ^ raw[2]) as i64 + 47;
    if v8 <= 0 || 1 + v8 > raw.len() as i64 {
        v8 = raw.len() as i64 - 1;
    }
    if v8 < 33 {
        return Err(ApiError::Internal("红果 spade v8 不足".to_string()));
    }
    let mut value = raw[1..1 + v8 as usize].to_vec();
    let (mut va, mut vb) = (85u8, 246u8);
    for index in 0..v8 as usize {
        let previous = if index & 1 == 1 { va } else { vb };
        if index & 1 == 1 {
            va = value[index];
        } else {
            vb = value[index];
        }
        let orig = value[index];
        value[index] = (previous ^ orig)
            .wrapping_sub(21)
            .wrapping_sub((index as u32).count_ones() as u8);
    }
    let hex_str = String::from_utf8(value[1..33].to_vec())
        .map_err(|_| ApiError::Internal("红果 spade 密钥非 ascii".to_string()))?;
    let key = hex::decode(&hex_str)
        .map_err(|_| ApiError::Internal("红果 spade 密钥非 hex".to_string()))?;
    if key.len() != 16 {
        return Err(ApiError::Internal("红果 spade 密钥非 16 字节".to_string()));
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&key);
    Ok(out)
}

/// py _find_box：从 max(4, start) 线性扫 fourcc，size 取 fourcc 前
/// 4 字节大端（==1 时取后 8 字节大端），仅 8<=size<=5_000_000 且
/// offset+size<=len 才回 (offset, size)，否则继续扫。
fn find_box(data: &[u8], name: &[u8; 4], start: usize) -> (i64, usize) {
    let mut offset = start.max(4);
    while offset + 8 <= data.len() {
        if &data[offset + 4..offset + 8] == name {
            let mut size = u32::from_be_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]) as usize;
            if size == 1 && offset + 16 <= data.len() {
                size = u64::from_be_bytes([
                    data[offset + 8],
                    data[offset + 9],
                    data[offset + 10],
                    data[offset + 11],
                    data[offset + 12],
                    data[offset + 13],
                    data[offset + 14],
                    data[offset + 15],
                ]) as usize;
            }
            if (8..=5_000_000).contains(&size) && offset + size <= data.len() {
                return (offset as i64, size);
            }
        }
        offset += 1;
    }
    (-1, 0)
}

/// py _box_body：回 [offset+8..offset+size]（largesize 也按 +8，
/// 照抄 py 的怪癖）。
fn box_body<'a>(data: &'a [u8], offset: i64, size: usize) -> &'a [u8] {
    if offset < 0 {
        return &[];
    }
    let start = offset as usize + 8;
    let end = offset as usize + size;
    if start > end || end > data.len() {
        return &[];
    }
    &data[start..end]
}

struct TrackInfo {
    sizes: Vec<u32>,
    chunks: Vec<u64>,
    chunk_samples: Vec<usize>,
    aux_sizes: Vec<u8>,
    aux_offset: u64,
}

/// py _parse_track：从 track_offset+8 起找 stbl，取 stsz/stco/co64/
/// stsc/saiz/saio，缺 stsz/stsc/saiz/saio 任一或 stco/co64 全缺回
/// None；stsz 默认尺寸或逐条，stco/co64 宽 4/8，stsc 1 基转 0 基
/// 覆盖，saiz 默认尺寸或逐字节，saio 只取首项。
fn parse_track(moov: &[u8], track_offset: usize) -> Option<TrackInfo> {
    let (stbl_offset, _) = {
        let (off, size) = find_box(moov, b"stbl", track_offset + 8);
        if off < 0 {
            return None;
        }
        (off as usize, size)
    };
    let stsz_body = {
        let (off, size) = find_box(moov, b"stsz", stbl_offset);
        if off < 0 {
            return None;
        }
        box_body(moov, off, size).to_vec()
    };
    let stsc_body = {
        let (off, size) = find_box(moov, b"stsc", stbl_offset);
        if off < 0 {
            return None;
        }
        box_body(moov, off, size).to_vec()
    };
    let saiz_body = {
        let (off, size) = find_box(moov, b"saiz", stbl_offset);
        if off < 0 {
            return None;
        }
        box_body(moov, off, size).to_vec()
    };
    let saio_body = {
        let (off, size) = find_box(moov, b"saio", stbl_offset);
        if off < 0 {
            return None;
        }
        box_body(moov, off, size).to_vec()
    };
    let (stco_body, co64) = {
        let (off, size) = find_box(moov, b"stco", stbl_offset);
        if off >= 0 {
            (box_body(moov, off, size).to_vec(), false)
        } else {
            let (off2, size2) = find_box(moov, b"co64", stbl_offset);
            if off2 < 0 {
                return None;
            }
            (box_body(moov, off2, size2).to_vec(), true)
        }
    };
    if stsz_body.len() < 12 || stsc_body.len() < 8 || saiz_body.len() < 5 {
        return None;
    }
    let sample_count =
        u32::from_be_bytes([stsz_body[8], stsz_body[9], stsz_body[10], stsz_body[11]]) as usize;
    let default_size = u32::from_be_bytes([stsz_body[4], stsz_body[5], stsz_body[6], stsz_body[7]]);
    let mut sizes = Vec::with_capacity(sample_count);
    if default_size != 0 {
        sizes.resize(sample_count, default_size);
    } else {
        for i in 0..sample_count {
            let off = 12 + i * 4;
            if off + 4 > stsz_body.len() {
                return None;
            }
            sizes.push(u32::from_be_bytes([
                stsz_body[off],
                stsz_body[off + 1],
                stsz_body[off + 2],
                stsz_body[off + 3],
            ]));
        }
    }
    let chunk_count =
        u32::from_be_bytes([stco_body[4], stco_body[5], stco_body[6], stco_body[7]]) as usize;
    let width = if co64 { 8 } else { 4 };
    let mut chunks = Vec::with_capacity(chunk_count);
    for i in 0..chunk_count {
        let off = 8 + i * width;
        if off + width > stco_body.len() {
            return None;
        }
        let v = if co64 {
            u64::from_be_bytes([
                stco_body[off],
                stco_body[off + 1],
                stco_body[off + 2],
                stco_body[off + 3],
                stco_body[off + 4],
                stco_body[off + 5],
                stco_body[off + 6],
                stco_body[off + 7],
            ])
        } else {
            u32::from_be_bytes([
                stco_body[off],
                stco_body[off + 1],
                stco_body[off + 2],
                stco_body[off + 3],
            ]) as u64
        };
        chunks.push(v);
    }
    let entry_count =
        u32::from_be_bytes([stsc_body[4], stsc_body[5], stsc_body[6], stsc_body[7]]) as usize;
    let mut chunk_samples = vec![0usize; chunk_count];
    for e in 0..entry_count {
        let base = 8 + e * 12;
        if base + 12 > stsc_body.len() {
            return None;
        }
        let first_chunk = u32::from_be_bytes([
            stsc_body[base],
            stsc_body[base + 1],
            stsc_body[base + 2],
            stsc_body[base + 3],
        ]) as usize;
        let samples_per_chunk = u32::from_be_bytes([
            stsc_body[base + 4],
            stsc_body[base + 5],
            stsc_body[base + 6],
            stsc_body[base + 7],
        ]) as usize;
        let next_first = if e + 1 < entry_count {
            let nb = 8 + (e + 1) * 12;
            u32::from_be_bytes([
                stsc_body[nb],
                stsc_body[nb + 1],
                stsc_body[nb + 2],
                stsc_body[nb + 3],
            ]) as usize
        } else {
            chunk_count + 1
        };
        let start_idx = first_chunk.saturating_sub(1);
        let end_idx = (next_first.saturating_sub(1)).min(chunk_count);
        for ci in start_idx..end_idx {
            chunk_samples[ci] = samples_per_chunk;
        }
    }
    let saiz_flags = if saiz_body.len() >= 4 {
        u32::from_be_bytes([0, saiz_body[1], saiz_body[2], saiz_body[3]])
    } else {
        0
    };
    let cursor = if saiz_flags & 1 != 0 { 12 } else { 4 };
    if saiz_body.len() < cursor + 5 {
        return None;
    }
    let saiz_default = saiz_body[cursor];
    let saiz_count = u32::from_be_bytes([
        saiz_body[cursor + 1],
        saiz_body[cursor + 2],
        saiz_body[cursor + 3],
        saiz_body[cursor + 4],
    ]) as usize;
    let mut aux_sizes = Vec::with_capacity(saiz_count);
    if saiz_default != 0 {
        aux_sizes.resize(saiz_count, saiz_default);
    } else {
        for i in 0..saiz_count {
            let off = cursor + 5 + i;
            if off >= saiz_body.len() {
                return None;
            }
            aux_sizes.push(saiz_body[off]);
        }
    }
    let saio_flags = if saio_body.len() >= 4 {
        u32::from_be_bytes([0, saio_body[1], saio_body[2], saio_body[3]])
    } else {
        0
    };
    let saio_cursor = if saio_flags & 1 != 0 { 12 } else { 4 };
    let saio_width = if saio_body.is_empty() {
        4
    } else if saio_body[0] == 1 {
        8
    } else {
        4
    };
    if saio_body.len() < saio_cursor + 4 + saio_width {
        return None;
    }
    let saio_count = u32::from_be_bytes([
        saio_body[saio_cursor],
        saio_body[saio_cursor + 1],
        saio_body[saio_cursor + 2],
        saio_body[saio_cursor + 3],
    ]) as usize;
    if saio_count < 1 {
        return None;
    }
    let aux_offset = if saio_width == 8 {
        u64::from_be_bytes([
            saio_body[saio_cursor + 4],
            saio_body[saio_cursor + 5],
            saio_body[saio_cursor + 6],
            saio_body[saio_cursor + 7],
            saio_body[saio_cursor + 8],
            saio_body[saio_cursor + 9],
            saio_body[saio_cursor + 10],
            saio_body[saio_cursor + 11],
        ])
    } else {
        u32::from_be_bytes([
            saio_body[saio_cursor + 4],
            saio_body[saio_cursor + 5],
            saio_body[saio_cursor + 6],
            saio_body[saio_cursor + 7],
        ]) as u64
    };
    Some(TrackInfo {
        sizes,
        chunks,
        chunk_samples,
        aux_sizes,
        aux_offset,
    })
}

/// py _aes_ctr_decrypt：AES-128 CTR，计数器作大端 u128 逐块 +1。
fn aes_ctr_decrypt(data: &mut [u8], key: &[u8; 16], iv: &[u8; 16]) {
    use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
    let cipher = aes::Aes128::new(GenericArray::from_slice(key));
    let mut counter = u128::from_be_bytes(*iv);
    for chunk in data.chunks_mut(16) {
        let mut keystream = GenericArray::clone_from_slice(&counter.to_be_bytes());
        cipher.encrypt_block(&mut keystream);
        for (i, byte) in chunk.iter_mut().enumerate() {
            *byte ^= keystream[i];
        }
        counter = counter.wrapping_add(1);
    }
}

fn original_format_near(data: &[u8], pos: usize) -> Option<[u8; 4]> {
    let end = (pos + 800).min(data.len());
    let mut i = pos;
    while i + 8 <= end {
        if &data[i..i + 4] == b"frma" {
            let fmt = [data[i + 4], data[i + 5], data[i + 6], data[i + 7]];
            let printable = fmt.iter().all(|&b| (32..=126).contains(&b));
            let zero = fmt.iter().all(|&b| b == 0);
            if printable && !zero && &fmt != b"encv" && &fmt != b"enca" {
                return Some(fmt);
            }
        }
        i += 1;
    }
    None
}

/// py _restore_cenc_codecs：全文找 encv/enca，按附近 frma 换回原编
/// 码（无 frma 则默认 avc1/mp4a），换后 pos+=4。
fn restore_cenc_codecs(data: &mut Vec<u8>) {
    let mut pos = 0usize;
    while pos + 4 <= data.len() {
        if &data[pos..pos + 4] == b"encv" {
            let fmt = original_format_near(data, pos).unwrap_or(*b"avc1");
            data[pos..pos + 4].copy_from_slice(&fmt);
            pos += 4;
        } else if &data[pos..pos + 4] == b"enca" {
            let fmt = original_format_near(data, pos).unwrap_or(*b"mp4a");
            data[pos..pos + 4].copy_from_slice(&fmt);
            pos += 4;
        } else {
            pos += 1;
        }
    }
}

/// py _replace_sinf：找 sinf，size 在 [8,50000) 且 end<=len 才把
/// 类型改 free 并把体清零，pos=end，否则 pos+=4。
fn replace_sinf(data: &mut Vec<u8>) {
    let mut pos = 0usize;
    while pos + 8 <= data.len() {
        if &data[pos + 4..pos + 8] == b"sinf" {
            let size = u32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]])
                as usize;
            let end = pos + size;
            if size >= 8 && size < 50000 && end <= data.len() {
                data[pos + 4..pos + 8].copy_from_slice(b"free");
                for b in &mut data[pos + 8..end] {
                    *b = 0;
                }
                pos = end;
                continue;
            }
        }
        pos += 4;
    }
}

/// py _replace_box_type：找 name，size>=8 且 end<=len 才把类型改
/// free（不改体），pos=end，否则 pos+=4。
fn replace_box_type(data: &mut Vec<u8>, name: &[u8; 4]) {
    let mut pos = 0usize;
    while pos + 8 <= data.len() {
        if &data[pos + 4..pos + 8] == name {
            let size = u32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]])
                as usize;
            let end = pos + size;
            if size >= 8 && end <= data.len() {
                data[pos + 4..pos + 8].copy_from_slice(b"free");
                pos = end;
                continue;
            }
        }
        pos += 4;
    }
}

/// py _rewrite_moov：restore → sinf → senc → pssh 连用。
fn rewrite_moov(data: &[u8]) -> Vec<u8> {
    let mut out = data.to_vec();
    restore_cenc_codecs(&mut out);
    replace_sinf(&mut out);
    replace_box_type(&mut out, b"senc");
    replace_box_type(&mut out, b"pssh");
    out
}

/// py decrypt_mp4_cenc：全文件找 moov，线性找全部 trak，每轨
/// parse 后按 chunk/样本遍历（样本区原地 AES-CTR 解密，iv 取
/// aux 首 min(entry_size,8) 字节右补零到 8 再加 8 零），解密样本
/// 数为 0 报错，末尾 moov 区换成 _rewrite_moov 结果。
fn decrypt_mp4_cenc(data: &[u8], key: &[u8; 16]) -> ApiResult<Vec<u8>> {
    if data.len() < 16 {
        return Err(ApiError::Internal("红果 CENC 文件过短".to_string()));
    }
    let (moov_offset, moov_size) = find_box(data, b"moov", 0);
    if moov_offset < 0 || moov_size < 8 {
        return Err(ApiError::Internal("红果 CENC 未找到 moov".to_string()));
    }
    let moov_offset = moov_offset as usize;
    let moov_end = moov_offset + moov_size;
    if moov_end > data.len() {
        return Err(ApiError::Internal("红果 CENC moov 超出文件".to_string()));
    }
    let moov = data[moov_offset..moov_end].to_vec();
    let mut result = data.to_vec();
    let mut track = 0usize;
    let mut decrypted_samples = 0usize;
    while track + 8 <= moov.len() {
        let (track_offset, track_size) = find_box(&moov, b"trak", track);
        if track_offset < 0 {
            break;
        }
        let track_offset = track_offset as usize;
        let next = track_offset + track_size.max(8);
        if let Some(info) = parse_track(&moov, track_offset) {
            let aux_size: usize = info.aux_sizes.iter().map(|&s| (s as usize).max(8)).sum();
            let aux_offset = info.aux_offset as usize;
            if info.sizes.is_empty() || aux_offset + aux_size > data.len() {
                track = next;
                continue;
            }
            let aux = data[aux_offset..aux_offset + aux_size].to_vec();
            let mut sample_index = 0usize;
            let mut aux_index = 0usize;
            for (chunk_idx, &chunk_offset) in info.chunks.iter().enumerate() {
                let mut current = chunk_offset as usize;
                let per = info.chunk_samples.get(chunk_idx).copied().unwrap_or(0);
                for _ in 0..per {
                    if sample_index >= info.sizes.len() {
                        break;
                    }
                    let size = info.sizes[sample_index] as usize;
                    if current + size > data.len() {
                        return Err(ApiError::Internal("红果 CENC 样本超出文件".to_string()));
                    }
                    if sample_index >= info.aux_sizes.len() {
                        return Err(ApiError::Internal("红果 CENC aux 不足".to_string()));
                    }
                    let entry_size = (info.aux_sizes[sample_index] as usize).max(8);
                    let mut iv = [0u8; 16];
                    let take = entry_size.min(8);
                    if aux_index + take <= aux.len() {
                        iv[..take].copy_from_slice(&aux[aux_index..aux_index + take]);
                    }
                    aes_ctr_decrypt(&mut result[current..current + size], key, &iv);
                    decrypted_samples += 1;
                    current += size;
                    sample_index += 1;
                    aux_index += entry_size;
                }
            }
        }
        track = next;
    }
    if decrypted_samples == 0 {
        return Err(ApiError::Internal("红果 CENC 未解密任何样本".to_string()));
    }
    let rewritten = rewrite_moov(&moov);
    result[moov_offset..moov_end].copy_from_slice(&rewritten);
    Ok(result)
}

/// py _sample_table：与 decrypt 同款遍历，但要求 aux 在 moov 内
/// （否则报“不能流式解密”），产 (文件偏移, 尺寸, iv) 列表后按
/// 元组排序，空则报错。视频流式会话用，音频整文件路不走它。
fn sample_table(moov: &[u8], moov_start: usize) -> ApiResult<Vec<(u64, u32, [u8; 16])>> {
    let mut table = Vec::new();
    let mut track = 0usize;
    while track + 8 <= moov.len() {
        let (track_offset, track_size) = find_box(moov, b"trak", track);
        if track_offset < 0 {
            break;
        }
        let track_offset = track_offset as usize;
        let next = track_offset + track_size.max(8);
        if let Some(info) = parse_track(moov, track_offset) {
            let aux_size: usize = info.aux_sizes.iter().map(|&s| (s as usize).max(8)).sum();
            let aux_local = info.aux_offset as i64 - moov_start as i64;
            if aux_local < 0 || aux_local as usize + aux_size > moov.len() {
                return Err(ApiError::Internal(
                    "红果 CENC aux 不在 moov 内，不能流式解密".to_string(),
                ));
            }
            let aux = moov[aux_local as usize..aux_local as usize + aux_size].to_vec();
            let mut sample_index = 0usize;
            let mut aux_index = 0usize;
            for (chunk_idx, &chunk_offset) in info.chunks.iter().enumerate() {
                let mut current = chunk_offset;
                let per = info.chunk_samples.get(chunk_idx).copied().unwrap_or(0);
                for _ in 0..per {
                    if sample_index >= info.sizes.len() {
                        break;
                    }
                    let size = info.sizes[sample_index];
                    if sample_index >= info.aux_sizes.len() {
                        return Err(ApiError::Internal("红果 CENC aux 不足".to_string()));
                    }
                    let entry_size = (info.aux_sizes[sample_index] as usize).max(8);
                    let mut iv = [0u8; 16];
                    let take = entry_size.min(8);
                    if aux_index + take <= aux.len() {
                        iv[..take].copy_from_slice(&aux[aux_index..aux_index + take]);
                    }
                    table.push((current, size, iv));
                    current += size as u64;
                    sample_index += 1;
                    aux_index += entry_size;
                }
            }
        }
        track = next;
    }
    if table.is_empty() {
        return Err(ApiError::Internal("红果 CENC 样本表为空".to_string()));
    }
    table.sort();
    Ok(table)
}

/// 音频会话缓存（py _audio_session_bytes 的 3 条 FIFO）：key 为
/// (book_id, item_id, tone_id)，命中直接回字节，不再重下载/解密。
static AUDIO_CACHE: Lazy<Mutex<Vec<((String, String, String), Vec<u8>)>>> =
    Lazy::new(|| Mutex::new(Vec::new()));

static AUDIO_DL_CLIENT: crate::egress_proxy::ClientSlot = crate::egress_proxy::ClientSlot::new();

/// py _audio_session_bytes：签名 POST playurl 取 main_url +
/// encryption_key → derive 密钥 → 120 秒下载整文件 → CENC 解密
/// → 入 3 条缓存回字节。
pub(crate) async fn hg_audio_bytes(book: &str, item: &str, tone: &str) -> ApiResult<Vec<u8>> {
    let key = (book.to_string(), item.to_string(), tone.to_string());
    if let Ok(guard) = AUDIO_CACHE.lock() {
        for (k, v) in guard.iter() {
            if *k == key {
                return Ok(v.clone());
            }
        }
    }
    let payload = json!({
        "book_id": book.parse::<i64>().unwrap_or(0),
        "item_id": item.parse::<i64>().unwrap_or(0),
        "tone_id": tone.parse::<i64>().unwrap_or(0),
        "req_type": 0
    });
    let body = signed_post(PLAYURL_URL, &payload).await?;
    let data = body.get("data").cloned().unwrap_or(json!({}));
    let main_url = text_of(&data, &["main_url"]);
    let encryption_key = text_of(&data, &["encryption_key"]);
    if main_url.is_empty() || encryption_key.is_empty() {
        return Err(ApiError::Internal(
            "红果音频 playurl 未给 main_url 或 encryption_key".to_string(),
        ));
    }
    let key16 = derive_content_key(&encryption_key)?;
    let dl = AUDIO_DL_CLIENT
        .get_or_build(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
            crate::egress_proxy::apply_to_builder(
                reqwest::Client::builder().timeout(std::time::Duration::from_secs(120)),
            )
            .build()
            .ok()
        })
        .ok_or_else(|| ApiError::Internal("红果音频下载客户端建失败".to_string()))?;
    let raw = dl
        .get(&main_url)
        .header("User-Agent", "Mozilla/5.0")
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("红果音频下载失败：{e}")))?
        .bytes()
        .await
        .map_err(|e| ApiError::Internal(format!("红果音频下载失败：{e}")))?;
    let decrypted = decrypt_mp4_cenc(&raw, &key16)?;
    if let Ok(mut guard) = AUDIO_CACHE.lock() {
        guard.retain(|(k, _)| *k != key);
        guard.push((key, decrypted.clone()));
        while guard.len() > 3 {
            guard.remove(0);
        }
    }
    Ok(decrypted)
}

/// play() 的 hg_audio 标记 → 核心中继绝对地址（供 reading/mod.rs
/// 的 handle_play 收尾改写用；port 为核心监听端口）。
pub(crate) fn hg_audio_relay_url(port: u16, marker: &str) -> Option<String> {
    let rest = marker.strip_prefix("hg_audio:")?;
    let mut parts = rest.split(':');
    let book = parts.next()?;
    let item = parts.next()?;
    let tone = parts.next()?;
    if book.is_empty() || item.is_empty() || tone.is_empty() {
        return None;
    }
    Some(format!(
        "http://127.0.0.1:{port}/api/v1/reading/hg_audio?book={book}&item={item}&tone={tone}"
    ))
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let (cards, cat_map) = audio_scan_cards().await?;
    let mut list = vec![category_json("audio", "全部")];
    let mut seen: Vec<String> = Vec::new();
    for card in &cards {
        let cat = cat_map
            .get(&text_of(card, &["id"]))
            .cloned()
            .unwrap_or_default();
        if cat.is_empty() || seen.contains(&cat) {
            continue;
        }
        seen.push(cat.clone());
        list.push(category_json(&cat, &cat));
    }
    Ok(json!({ "categories": list }))
}

/// 目录：扫描卡按分类过滤，每页 24 条（py _page_slice/_pagecount）。
pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let (cards, cat_map) = audio_scan_cards().await?;
    let pg = if page < 1 { 1 } else { page };
    let filtered: Vec<Value> = cards
        .iter()
        .filter(|c| {
            if category_id.is_empty() || category_id == "audio" {
                return true;
            }
            cat_map.get(&text_of(c, &["id"])).map(|v| v.as_str()) == Some(category_id)
        })
        .cloned()
        .collect();
    let total = filtered.len() as i64;
    let page_count = ((total + 23) / 24).max(1);
    let start = ((pg - 1) * 24) as usize;
    let items: Vec<Value> = filtered
        .iter()
        .skip(start)
        .take(24)
        .map(|c| {
            item_json(
                &text_of(c, &["id"]),
                &text_of(c, &["title"]),
                &text_of(c, &["cover"]),
                &text_of(c, &["remark"]),
            )
        })
        .collect();
    Ok(json!({ "items": items, "has_more": pg < page_count }))
}

/// py _audio_tone_id：toneinfo 的 tts_tones 首个 id 或 recommend_tone，
/// 失败再从详情 tones 逗号串取首个数字，仍失败报错。
async fn audio_tone_id(book_id: &str, detail: &Value) -> ApiResult<i64> {
    let tone_resp = signed_get(TONEINFO_URL, &[("book_id", book_id)]).await;
    if let Ok(resp) = tone_resp {
        let data = resp.get("data").cloned().unwrap_or(Value::Null);
        let tones = get(&data, "tts_tones").and_then(arr_of);
        if let Some(first) = tones.and_then(|t| t.first()) {
            let id = int_of(first, &["id"]);
            if id != 0 {
                return Ok(id);
            }
        }
        let rec = int_of(&data, &["recommend_tone"]);
        if rec != 0 {
            return Ok(rec);
        }
    }
    let tones = text_of(detail, &["tones"]);
    for part in tones.split(',') {
        let digits: String = part.chars().filter(|c| c.is_ascii_digit()).collect();
        if let Ok(id) = digits.parse::<i64>() {
            if id != 0 {
                return Ok(id);
            }
        }
    }
    Err(ApiError::Internal(format!("红果听书 {book_id} 取不到音色")))
}

/// py _book_directory：目录分页（count=500，最多 40 页，offset 取
/// 末条 item_id，去重；返回 item_id 顺序表）。
async fn book_directory(book_id: &str) -> ApiResult<Vec<Value>> {
    let mut items: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let mut offset = 0i64;
    for _ in 0..40 {
        let offset_s = offset.to_string();
        let resp = signed_get(
            DIRECTORY_URL,
            &[
                ("book_id", book_id),
                ("offset", offset_s.as_str()),
                ("count", "500"),
            ],
        )
        .await?;
        let data = resp.get("data").cloned().unwrap_or(Value::Null);
        let page_items = get(&data, "item_data_list")
            .and_then(arr_of)
            .cloned()
            .unwrap_or_default();
        if page_items.is_empty() {
            break;
        }
        let mut last_id = offset;
        for item in &page_items {
            let iid = text_of(item, &["item_id"]);
            if iid.is_empty() || seen.contains(&iid) {
                continue;
            }
            seen.push(iid);
            last_id = text_of(item, &["item_id"]).parse::<i64>().unwrap_or(offset);
            items.push(item.clone());
        }
        if last_id == offset {
            break;
        }
        offset = last_id;
    }
    Ok(items)
}

/// py _audio_detail：详情 + 音色 + 目录，分集 video_id 为
/// hg_audio:书:集:音色 标记（见模块头取流说明）。
pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let book_id = series_id.strip_prefix("audio#").unwrap_or(series_id);
    if book_id.is_empty() {
        return Err(ApiError::BadRequest("红果听书书号为空".to_string()));
    }
    let resp = signed_get(AUDIO_DETAIL_URL, &[("book_id", book_id)]).await?;
    let data = resp.get("data").cloned().unwrap_or(Value::Null);
    let title = text_of(&data, &["book_name"]);
    let title = if title.is_empty() {
        text_of(&data, &["book_short_name"])
    } else {
        title
    };
    let cover = text_of(&data, &["thumb_url"]);
    let cover = if cover.is_empty() {
        text_of(&data, &["detail_page_thumb_url"])
    } else {
        cover
    };
    let desc = text_of(&data, &["abstract"]);
    let desc = if desc.is_empty() {
        text_of(&data, &["book_abstract_v2"])
    } else {
        desc
    };
    let serial = int_of(&data, &["serial_count"]);
    let serial = if serial == 0 {
        int_of(&data, &["content_chapter_number"])
    } else {
        serial
    };
    let tone = audio_tone_id(book_id, &data).await?;
    let items = book_directory(book_id).await?;
    let mut episodes = Vec::new();
    for item in &items {
        let item_id = text_of(item, &["item_id"]);
        let chapter = text_of(item, &["title"]);
        let chapter = if chapter.is_empty() {
            text_of(item, &["chapter_title"])
        } else {
            chapter
        };
        episodes.push(episode_json(
            &format!("hg_audio:{book_id}:{item_id}:{tone}"),
            &chapter,
            series_id,
        ));
    }
    let mut synopsis = desc;
    if serial > 0 {
        synopsis.push_str(&format!("\n\n共{serial}章"));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": { "author": text_of(&data, &["author"]), "tone_id": tone },
        "episodes": episodes,
    }))
}

/// 搜索：py 本无听书搜索接口；按扫描卡片标题/作者子串过滤
/// （大小写不敏感，与听友 search 同款做法）。
pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let (cards, _) = audio_scan_cards().await?;
    let q = query.to_lowercase();
    let items: Vec<Value> = cards
        .iter()
        .filter(|c| {
            text_of(c, &["title"]).to_lowercase().contains(&q)
                || text_of(c, &["author"]).to_lowercase().contains(&q)
        })
        .map(|c| {
            item_json(
                &text_of(c, &["id"]),
                &text_of(c, &["title"]),
                &text_of(c, &["cover"]),
                &text_of(c, &["remark"]),
            )
        })
        .collect();
    Ok(json!({ "items": items }))
}

/// 取流：分集标记 hg_audio:书:集:音色，或 py 旧式中继地址
/// 127.0.0.1/hg_audio.mp4?book=..&item=..&tone=.. 的查询参数；
/// 返回标记地址，分发须改写成核心中继路由地址（见模块头说明），
/// 中继本身不需要播放头，故 header 为空字典。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let marker = if let Some(rest) = video_id.strip_prefix("hg_audio:") {
        let parts: Vec<&str> = rest.split(':').collect();
        if parts.len() < 3 {
            return Err(ApiError::BadRequest("红果听书参数不对".to_string()));
        }
        video_id.to_string()
    } else if video_id.contains("hg_audio.mp4") {
        let query = video_id.split('?').nth(1).unwrap_or("");
        let params: HashMap<String, String> = url::form_urlencoded::parse(query.as_bytes())
            .into_owned()
            .collect();
        let book = params.get("book").cloned().unwrap_or_default();
        let item = params.get("item").cloned().unwrap_or_default();
        let tone = params.get("tone").cloned().unwrap_or_default();
        if book.is_empty() || item.is_empty() || tone.is_empty() {
            return Err(ApiError::BadRequest("红果听书参数不对".to_string()));
        }
        format!("hg_audio:{book}:{item}:{tone}")
    } else {
        return Err(ApiError::BadRequest("红果听书参数不对".to_string()));
    };
    Ok(json!({ "url": marker, "header": {} }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sm3_abc_vector() {
        assert_eq!(
            hex::encode(sm3(b"abc")),
            "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
        );
    }

    #[test]
    fn url_encode_space_and_star() {
        assert_eq!(
            url_encode(&[("q".to_string(), "a b*c".to_string())]),
            "q=a%20b*c"
        );
    }

    #[test]
    fn params_74332_starts_with_device_ids() {
        let params = params_74332(&[]);
        assert_eq!(params[0].0, "iid");
        assert_eq!(params[1].0, "device_id");
        assert!(params.iter().any(|(k, v)| k == "aid" && v == "8662"));
    }

    #[test]
    fn hash_f13_branch_2_vector() {
        let q = hex::decode("3a36963bbdf05b259afaad54a9983992ac76346e7a56611d17befe96b81f7e10")
            .unwrap();
        let b = hex::decode("301251acb61102bf3ce58237e5dabb2f").unwrap();
        let t = hex::decode("b01b0567").unwrap();
        assert_eq!(
            hex::encode(hash_f13(&q, &b, &t, 1728388016).unwrap()),
            "f2df5fc318ff33cb44e0dc82ee77ba0a4fab29a3"
        );
    }

    #[test]
    fn hash_f13_branch_1_vector() {
        let q = hex::decode("2e87d494473e31662aa53ea6c88696f74581895a8ae0daa86ed9f59e1f6b8682")
            .unwrap();
        let b = hex::decode("d6ed8ba2adae5a938c5a3757bcccf4dd").unwrap();
        let t = hex::decode("b11b0567").unwrap();
        assert_eq!(
            hex::encode(hash_f13(&q, &b, &t, 1728388017).unwrap()),
            "f288e85dae68c3baa33f83959009d80b6fb248c6"
        );
    }

    #[test]
    fn hash_f13_branch_0_vector() {
        let q = hex::decode("956b457c8df6b6ef62e8041cbd43f51e170be4a45c8c68f8c6233ec8b2a0063e")
            .unwrap();
        let b = hex::decode("0039fc0a2fa335c82bfd08f6a068ee1c").unwrap();
        let t = hex::decode("b41b0567").unwrap();
        assert_eq!(
            hex::encode(hash_f13(&q, &b, &t, 1728388020).unwrap()),
            "7fec43e6d4803646b230819f079b9eb9ef497537"
        );
    }

    #[test]
    fn hash_f13_deterministic() {
        let q = hex::decode("3a36963bbdf05b259afaad54a9983992ac76346e7a56611d17befe96b81f7e10")
            .unwrap();
        let b = hex::decode("301251acb61102bf3ce58237e5dabb2f").unwrap();
        let t = hex::decode("b01b0567").unwrap();
        assert_eq!(
            hash_f13(&q, &b, &t, 1728388016).unwrap(),
            hash_f13(&q, &b, &t, 1728388016).unwrap()
        );
    }

    #[test]
    fn aes_v3_encrypt_vector() {
        let mixed = hex::decode(
            "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7fe050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930",
        )
        .unwrap();
        let key = hex::decode("f1593376766ea98d34f31b057a9d5be4").unwrap();
        let iv = hex::decode("1fe109a4125283f418de9e051a969e12").unwrap();
        let mut iv_arr = [0u8; 16];
        iv_arr.copy_from_slice(&iv);
        let out = aes_v3_encrypt(&mixed, &iv_arr, &key, 1728388016).unwrap();
        assert_eq!(out.len(), 1 + mixed.len());
        assert_eq!(
            hex::encode(&out),
            "a6234a11081f242db41b424d40575c64ec537a859887969da48bf2bdd0c7ced5dce3aaf1f8ff040c141b6229203f3c444c735a65686f767d848b9299b0afacb53ce38ad5c8d7e6ecf4db4209101f1c25ac337a45584f545ce44b727d90878c949ca3eab5b8bfc6cc54dbe2edf0fffc058c135a21382f363d444b5259606f6e74fc83ca91989fa6ad349bc2cdc0dfdce5ecd3ba05180f161c242b323d50474e555c436a75787f868c94bbe2adb0b7bec4ccf39ae5f8eff6fc040b121d202f2c353c430a51485f646df45b828980979ea42c93fac1d8cfd4dd64ebf2f9100f0c141c232a313837464cd45b226970777c850cb39aa5b8afb4bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930"
        );
    }

    #[test]
    fn derive_content_key_vector() {
        let key = derive_content_key("g6AT5luhEuhZoRLqX6YR6EGlDupfuibDXbomwVu9JcOlvw==").unwrap();
        assert_eq!(hex::encode(key), "00112233445566778899aabbccddeeff");
    }

    #[test]
    fn md5sum_v3_vector() {
        let msg = hex::decode(
            "05101b26313c47525d68737e89949faab5c0cbd6e1ecf7020d18232e39444f5a65707b86919ca7b2bdc8d3dee9f4ff0a15202b36414c57626d78838e99a4afba",
        )
        .unwrap();
        let orders = hex::decode(
            "0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e",
        )
        .unwrap();
        assert_eq!(
            hex::encode(md5sum_v3(&msg, 0x12345678, &orders, 0x5a)),
            "fe162858f24848ed82be46e3ea56ff3487838666"
        );
    }

    #[test]
    fn sum_md5_vector() {
        let input: Vec<u8> = (0u8..16).collect();
        assert_eq!(sum_md5(&input), 0xd9379a5d);
    }

    #[test]
    fn hg_audio_relay_url_maps_marker() {
        assert_eq!(
            hg_audio_relay_url(18921, "hg_audio:100:200:1").as_deref(),
            Some("http://127.0.0.1:18921/api/v1/reading/hg_audio?book=100&item=200&tone=1")
        );
        assert_eq!(hg_audio_relay_url(18921, "hg_audio:100:200"), None);
        assert_eq!(hg_audio_relay_url(18921, "other:100:200:1"), None);
    }

    /// 真请求链路（默认跳过，只跑 --ignored 时跑）：分类→目录→详情→
    /// 取流标记→中继下载解密，全程走真实红果接口。出口到不了红果
    /// 接口时直接报网络错（不是签名错）。
    #[tokio::test]
    #[ignore = "live network: hits hongguo api and downloads audio"]
    async fn live_chain_categories_to_relay() {
        let cats = categories().await.expect("hongguo categories");
        let first_cat = cats["categories"][0]["id"]
            .as_str()
            .expect("first category id")
            .to_string();
        assert!(!first_cat.is_empty());
        let page = catalog(&first_cat, 1).await.expect("hongguo catalog");
        let first_item = page["items"][0]["id"]
            .as_str()
            .expect("first item id")
            .to_string();
        assert!(!first_item.is_empty());
        let det = detail(&first_item).await.expect("hongguo detail");
        let first_video = det["episodes"][0]["video_id"]
            .as_str()
            .expect("first episode video_id")
            .to_string();
        assert!(first_video.starts_with("hg_audio:"));
        let play_out = play(&first_video).await.expect("hongguo play");
        let marker = play_out["url"].as_str().expect("play url").to_string();
        let parts: Vec<&str> = marker
            .strip_prefix("hg_audio:")
            .expect("marker prefix")
            .split(':')
            .collect();
        assert!(parts.len() >= 3);
        let bytes = hg_audio_bytes(parts[0], parts[1], parts[2])
            .await
            .expect("hongguo relay bytes");
        assert!(bytes.len() > 8);
        let size = u32::from_be_bytes(bytes[0..4].try_into().unwrap()) as usize;
        let box_type = std::str::from_utf8(&bytes[4..8]).unwrap_or("");
        assert!(size > 0 && size <= bytes.len());
        assert!(matches!(box_type, "ftyp" | "moov" | "free" | "skip"));
    }

    #[tokio::test]
    #[ignore = "diagnostic: raw signed tab/v response"]
    async fn diag_signed_tab_raw() {
        ensure_registered().await;
        let params = params_74332(&[("tab_type", "5")]);
        let (signs, signed_url) = sixgod(BOOKMALL_TAB_URL, &params, None, "").expect("sixgod");
        let mut header_map = reqwest::header::HeaderMap::new();
        let mut push = |k: &str, v: &str| {
            if let (Ok(name), Ok(val)) = (
                reqwest::header::HeaderName::from_bytes(k.as_bytes()),
                reqwest::header::HeaderValue::from_str(v),
            ) {
                header_map.insert(name, val);
            }
        };
        push("User-Agent", APP_UA);
        push("Accept", "application/json");
        for (k, v) in &signs {
            push(k, v);
        }
        drop(push);
        eprintln!("https_proxy env: {:?}", std::env::var("HTTPS_PROXY"));
        let resp = crate::endpoints::drama::client()
            .expect("client")
            .get(&signed_url)
            .headers(header_map)
            .send()
            .await
            .expect("send");
        eprintln!("status: {}", resp.status());
        eprintln!(
            "content-encoding: {:?}",
            resp.headers().get("content-encoding")
        );
        eprintln!("content-type: {:?}", resp.headers().get("content-type"));
        eprintln!(
            "content-length header: {:?}",
            resp.headers().get("content-length")
        );
        let bytes = resp.bytes().await.expect("bytes");
        eprintln!("body len: {}", bytes.len());
        let head = &bytes[..bytes.len().min(32)];
        eprintln!("body head hex: {}", hex::encode(head));
        eprintln!("body head text: {}", String::from_utf8_lossy(head));
    }

    #[test]
    #[ignore]
    fn medusa_fixed_input_print() {
        {
            let mut st = DEVICE_STATE.lock().unwrap_or_else(|e| e.into_inner());
            st.device_id = "1234567890123456".to_string();
            st.install_id = "1234567890123457".to_string();
        }
        {
            let mut q = TEST_NEXT_U64_QUEUE.lock().unwrap();
            q.clear();
            q.push_back(10);
            q.push_back(999);
            q.push_back(0x12345678);
            q.push_back(0xabcdef01);
            q.push_back(0x23456789);
        }
        {
            let mut t = TEST_NOW_SECS_OVERRIDE.lock().unwrap();
            *t = Some(1793855126);
        }
        {
            let mut f = TEST_PRINT_PROTO.lock().unwrap();
            *f = true;
        }
        let params: Vec<(String, String)> = [
            ("iid", "1234567890123457"),
            ("device_id", "1234567890123456"),
            ("ac", "wifi"),
            ("channel", "update_64"),
            ("aid", "8662"),
            ("app_name", "novelread"),
            ("version_code", "74332"),
            ("version_name", "7.4.3.32"),
            ("device_platform", "android"),
            ("os", "android"),
            ("ssmix", "a"),
            ("device_type", "25053RT47C"),
            ("device_brand", "Redmi"),
            ("language", "zh"),
            ("os_api", "36"),
            ("os_version", "16"),
            ("manifest_version_code", "74332"),
            ("resolution", "1280*2772"),
            ("dpi", "520"),
            ("update_version_code", "74332"),
            ("host_abi", "arm64-v8a"),
            ("dragon_device_type", "phone"),
            ("pv_player", "74332"),
            ("compliance_status", "0"),
            ("need_personal_recommend", "1"),
            ("player_so_load", "1"),
            ("is_android_pad_screen", "0"),
            ("tab_type", "1"),
            ("ts", "1793855126"),
            ("_rticket", "1793855126000"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        let base = "https://api5-normal-lq.snssdk.com/lq/bookmall/tab/v";
        let url = format!("{}?{}", base, url_encode(&params));
        let out = medusa(&url, &params, None, "", 1793855126).expect("medusa");
        eprintln!("MEDUSA_FIXED_URL={}", url);
        eprintln!("MEDUSA_FIXED_OUT={}", out);
        {
            let mut q = TEST_NEXT_U64_QUEUE.lock().unwrap();
            q.clear();
        }
        {
            let mut t = TEST_NOW_SECS_OVERRIDE.lock().unwrap();
            *t = None;
        }
        {
            let mut f = TEST_PRINT_PROTO.lock().unwrap();
            *f = false;
        }
    }
}
