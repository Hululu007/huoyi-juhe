//! 腾讯动漫：漫画站，章节取图有 JS 解密。
//!
//! 基址 https://ac.qq.com，桌面 UA。搜索与分类列表解析各不相同：搜索用
//! mod_book_list，分类列表页（/Comic/all/…）用 ret-search-list；详情按
//! 章节出分集，video_id 为“{漫画id}/{cid}”，含 ui-icon-pay 的章节只在
//! 标题后标“（付费）”，不绕过；排行走移动站 m.ac.qq.com。
//!
//! 分类照站原样写（2026-11-05 用户铁律：不按站名/分类名/标题删站、
//! 删分类、删视频）：theme/finish/vip/1 与 4 个排行全列；vip/2（付费）
//! 不列是只做免费的付费边界，不是标签删除；付费章节只标不绕。
//!
//! 排行说明：旧地址 /rank/index?type={…}&page=%d 现已 301 跳转，且按
//! UA 分流——桌面 UA 跳到桌面端 Rank/comicRank（JS 渲染，无条目），
//! 移动 UA 跳到移动端直达地址（服务端渲染，可解析）。因此排行直接
//! 请求移动端直达地址并用移动 UA：rise→/rank/biaosheng、
//! pay→/rank/changxiao、new→/rank/xinzuo、hot→/rank/zhenxiang。
//! 排行是单页榜单（每榜 10 条），page=2 也会跳回同一页内容相同，
//! 故 page>1 直接返回空列表，不重复推第一页。
//!
//! 章节图片四步（与 MyComic 接口文档 5.3 一致）：
//! ① 章节页取 DATA='…' 密文 T；② 取 window[…] = …; 的最后一条赋值，
//! 用手写迷你 JS 求值器求值，得 32 位 hex 字符串 N（DATA 与 window[…]
//! 每次请求都变，不缓存）；③ decode(T, N) 按 token 从后往前删字符，
//! 再标准 Base64 解码、去全部反斜杠；④ 取解码文本里的 "url":"…" 为图。
//! 注意：解码文本里除 picture 数组的图外，ads.bottom.url 还有一条微博
//! 链接，原文的 tx_images.json 把它算作第 12 条；本模块按同一口径取
//! 全部 "url"，cid=2 得 12 条、cid=3 得 26 条，与样本一致。
//!
//! 迷你求值器只覆盖章节 nonce 表达式里出现过的算子：字符串/数字字面量、二元
//! + - * / %、一元 + - ! ~、括号、eval("…")、.toString()、parseInt、
//! Math.round/floor/ceil/pow/abs/max/min/sqrt、'…'.charCodeAt()、
//! String.fromCharCode、字符串 .length/substring/slice/charAt/indexOf、
//! 按位 & | ^ << >> >>>、window/document 成员（按真值处理，实测只出现在
//! !window.Array 这类真值判断里）。nonce 模板每次请求轮换，样本外的新算子
//! 会返回清晰报错，不硬编假 N。

use base64::Engine as _;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const BASE_URL: &str = "https://ac.qq.com";
const RANK_URL: &str = "https://m.ac.qq.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Safari/537.36";
const MOBILE_UA: &str = "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Mobile Safari/537.36";

/// 排行类型 → 移动端直达路径（实测确认，非猜测）。
fn rank_path(rank: &str) -> Option<&'static str> {
    match rank {
        "rise" => Some("biaosheng"),
        "pay" => Some("changxiao"),
        "new" => Some("xinzuo"),
        "hot" => Some("zhenxiang"),
        _ => None,
    }
}

const CATEGORIES: [(&str, &str); 23] = [
    ("vip/1", "免费"),
    ("finish/1", "连载"),
    ("finish/2", "完结"),
    ("theme/101", "玄幻"),
    ("theme/102", "奇幻"),
    ("theme/103", "异能"),
    ("theme/104", "冒险"),
    ("theme/105", "恋爱"),
    ("theme/106", "剧情"),
    ("theme/108", "科幻"),
    ("theme/109", "动作"),
    ("theme/110", "恐怖"),
    ("theme/111", "犯罪"),
    ("theme/112", "悬疑"),
    ("theme/113", "日常"),
    ("theme/114", "竞技"),
    ("theme/115", "武侠"),
    ("theme/116", "历史"),
    ("theme/117", "战争"),
    ("rank:rise", "飙升榜"),
    ("rank:pay", "畅销榜"),
    ("rank:new", "新作榜"),
    ("rank:hot", "真香榜"),
];

fn must_re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|_| Regex::new("$^").unwrap())
}

fn decode_entities(s: &str) -> String {
    let dec = must_re(r"&#(\d+);");
    let mut out = dec
        .replace_all(s, |caps: &regex::Captures| {
            caps[1]
                .parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    let hex = must_re(r"&#x([0-9a-fA-F]+);");
    out = hex
        .replace_all(&out, |caps: &regex::Captures| {
            u32::from_str_radix(&caps[1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();
    for (from, to) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&amp;", "&"),
    ] {
        out = out.replace(from, to);
    }
    out
}

fn strip_tags(raw: &str) -> String {
    must_re(r"<[^>]+>").replace_all(raw, "").to_string()
}

fn clean_collapse(raw: &str) -> String {
    let decoded = decode_entities(&strip_tags(raw));
    let collapsed = must_re(r"\s+").replace_all(&decoded, " ");
    collapsed.replace('\u{a0}', " ").trim().to_string()
}

fn pct_encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

async fn fetch(url: &str) -> ApiResult<String> {
    fetch_with_ua(url, UA, &format!("{BASE_URL}/")).await
}

/// 移动端请求（排行用）：移动 UA + 移动站 Referer。
async fn fetch_mobile(url: &str) -> ApiResult<String> {
    fetch_with_ua(url, MOBILE_UA, &format!("{RANK_URL}/")).await
}

async fn fetch_with_ua(url: &str, ua: &str, referer: &str) -> ApiResult<String> {
    let c = client()?;
    let resp = c
        .get(url)
        .header("User-Agent", ua)
        .header("Referer", referer)
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("腾讯动漫请求失败: {e}")))?;
    let status = resp.status();
    if !status.is_success() {
        return Err(ApiError::Internal(format!(
            "腾讯动漫请求失败: HTTP {status}"
        )));
    }
    resp.text()
        .await
        .map_err(|e| ApiError::Internal(format!("腾讯动漫读取响应失败: {e}")))
}

fn cap<'a>(re: &Regex, text: &'a str) -> Option<String> {
    re.captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

// ---------------------------------------------------------------------------
// 迷你 JS 求值器：只覆盖章节 nonce 表达式里出现过的算子。
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
enum JsVal {
    Num(f64),
    Str(String),
    Bool(bool),
    Null,
}

impl JsVal {
    fn truthy(&self) -> bool {
        match self {
            JsVal::Num(n) => *n != 0.0 && !n.is_nan(),
            JsVal::Str(s) => !s.is_empty(),
            JsVal::Bool(b) => *b,
            JsVal::Null => false,
        }
    }

    fn to_number(&self) -> f64 {
        match self {
            JsVal::Num(n) => *n,
            JsVal::Str(s) => js_parse_number(s),
            JsVal::Bool(b) => {
                if *b {
                    1.0
                } else {
                    0.0
                }
            }
            JsVal::Null => 0.0,
        }
    }

    fn to_js_string(&self) -> String {
        match self {
            JsVal::Num(n) => js_num_to_string(*n),
            JsVal::Str(s) => s.clone(),
            JsVal::Bool(b) => b.to_string(),
            JsVal::Null => "null".to_string(),
        }
    }

    fn to_i32(&self) -> i32 {
        let n = self.to_number();
        if n.is_nan() || n == 0.0 || n.is_infinite() {
            return 0;
        }
        let m = n.trunc() % 4_294_967_296.0;
        let m = if m < 0.0 { m + 4_294_967_296.0 } else { m };
        if m >= 2_147_483_648.0 {
            (m - 4_294_967_296.0) as i32
        } else {
            m as i32
        }
    }
}

fn js_num_to_string(n: f64) -> String {
    if n.is_nan() {
        "NaN".to_string()
    } else if n == f64::INFINITY {
        "Infinity".to_string()
    } else if n == f64::NEG_INFINITY {
        "-Infinity".to_string()
    } else if n == 0.0 {
        "0".to_string()
    } else if n.fract() == 0.0 && n.abs() < 1e21 {
        format!("{}", n as i64)
    } else {
        format!("{n}")
    }
}

fn js_parse_number(s: &str) -> f64 {
    let t = s.trim();
    if t.is_empty() {
        return 0.0;
    }
    if t.eq_ignore_ascii_case("infinity") || t == "+Infinity" {
        return f64::INFINITY;
    }
    if t == "-Infinity" {
        return f64::NEG_INFINITY;
    }
    if let Some(hex) = t
        .strip_prefix("0x")
        .or_else(|| t.strip_prefix("0X"))
    {
        if let Ok(v) = i64::from_str_radix(hex, 16) {
            return v as f64;
        }
        return f64::NAN;
    }
    t.parse::<f64>().unwrap_or(f64::NAN)
}

fn utf16_units(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

fn char_code_at(s: &str, idx: usize) -> f64 {
    utf16_units(s)
        .get(idx)
        .map(|c| *c as f64)
        .unwrap_or(f64::NAN)
}

fn utf16_substring(s: &str, start: f64, end: Option<f64>) -> String {
    let u = utf16_units(s);
    let len = u.len() as f64;
    let clamp = |v: f64| {
        if v.is_nan() {
            0.0
        } else {
            v.trunc().clamp(0.0, len)
        }
    };
    let mut a = clamp(start);
    let mut b = end.map(clamp).unwrap_or(len);
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    String::from_utf16_lossy(&u[a as usize..b as usize])
}

fn utf16_slice(s: &str, start: f64, end: Option<f64>) -> String {
    let u = utf16_units(s);
    let len = u.len() as i64;
    let rel = |v: f64| -> i64 {
        if v.is_nan() {
            0
        } else if v < 0.0 {
            (len + v.trunc() as i64).max(0)
        } else {
            (v.trunc() as i64).min(len)
        }
    };
    let a = rel(start);
    let b = end.map(rel).unwrap_or(len);
    if a >= b {
        return String::new();
    }
    String::from_utf16_lossy(&u[a as usize..b as usize])
}

fn utf16_char_at(s: &str, idx: f64) -> String {
    if idx.is_nan() || idx < 0.0 {
        return String::new();
    }
    utf16_units(s)
        .get(idx.trunc() as usize)
        .map(|c| String::from_utf16_lossy(&[*c]))
        .unwrap_or_default()
}

fn utf16_index_of(s: &str, pat: &str, from: f64) -> f64 {
    let u = utf16_units(s);
    let p = utf16_units(pat);
    if p.is_empty() {
        let f = if from.is_nan() || from < 0.0 {
            0usize
        } else {
            (from.trunc() as usize).min(u.len())
        };
        return f as f64;
    }
    let start = if from.is_nan() || from < 0.0 {
        0usize
    } else {
        from.trunc() as usize
    };
    if p.len() > u.len() || start > u.len() - p.len() {
        return -1.0;
    }
    for i in start..=u.len() - p.len() {
        if u[i..i + p.len()] == p[..] {
            return i as f64;
        }
    }
    -1.0
}

fn from_char_codes(codes: &[JsVal]) -> String {
    let units: Vec<u16> = codes
        .iter()
        .map(|v| {
            let n = v.to_number();
            if n.is_nan() || n == 0.0 || n.is_infinite() {
                0u16
            } else {
                let m = n.trunc() % 65536.0;
                (if m < 0.0 { m + 65536.0 } else { m }) as u16
            }
        })
        .collect();
    String::from_utf16_lossy(&units)
}

fn parse_int_value(v: &JsVal) -> JsVal {
    match v {
        JsVal::Num(n) => JsVal::Num(n.trunc()),
        JsVal::Str(s) => {
            let t = s.trim_start();
            let (neg, rest) = match t.strip_prefix('-') {
                Some(r) => (true, r),
                None => (false, t.strip_prefix('+').unwrap_or(t)),
            };
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if digits.is_empty() {
                return JsVal::Num(f64::NAN);
            }
            match digits.parse::<f64>() {
                Ok(n) => JsVal::Num(if neg { -n } else { n }),
                Err(_) => JsVal::Num(f64::NAN),
            }
        }
        _ => JsVal::Num(v.to_number().trunc()),
    }
}

struct JsParser {
    chars: Vec<char>,
    pos: usize,
}

impl JsParser {
    fn new(src: &str) -> Self {
        Self {
            chars: src.chars().collect(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek_at(&self, off: usize) -> Option<char> {
        self.chars.get(self.pos + off).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(c) if c.is_whitespace()) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, c: char) -> Result<(), String> {
        self.skip_ws();
        if self.peek() == Some(c) {
            self.pos += 1;
            Ok(())
        } else {
            Err(format!("JS 求值：期望 '{c}'，实际 {:?}", self.peek()))
        }
    }

    fn parse_expr(&mut self) -> Result<JsVal, String> {
        self.parse_bitor()
    }

    fn parse_bitor(&mut self) -> Result<JsVal, String> {
        let mut left = self.parse_bitxor()?;
        loop {
            self.skip_ws();
            if self.peek() == Some('|') && self.peek_at(1) != Some('|') {
                self.pos += 1;
                let right = self.parse_bitxor()?;
                left = JsVal::Num((left.to_i32() | right.to_i32()) as f64);
            } else {
                break;
            }
        }
        Ok(left)
    }

    fn parse_bitxor(&mut self) -> Result<JsVal, String> {
        let mut left = self.parse_bitand()?;
        loop {
            self.skip_ws();
            if self.peek() == Some('^') {
                self.pos += 1;
                let right = self.parse_bitand()?;
                left = JsVal::Num((left.to_i32() ^ right.to_i32()) as f64);
            } else {
                break;
            }
        }
        Ok(left)
    }

    fn parse_bitand(&mut self) -> Result<JsVal, String> {
        let mut left = self.parse_shift()?;
        loop {
            self.skip_ws();
            if self.peek() == Some('&') && self.peek_at(1) != Some('&') {
                self.pos += 1;
                let right = self.parse_shift()?;
                left = JsVal::Num((left.to_i32() & right.to_i32()) as f64);
            } else {
                break;
            }
        }
        Ok(left)
    }

    fn parse_shift(&mut self) -> Result<JsVal, String> {
        let mut left = self.parse_additive()?;
        loop {
            self.skip_ws();
            let op = if self.peek() == Some('<') && self.peek_at(1) == Some('<') {
                "<<"
            } else if self.peek() == Some('>')
                && self.peek_at(1) == Some('>')
                && self.peek_at(2) == Some('>')
            {
                ">>>"
            } else if self.peek() == Some('>') && self.peek_at(1) == Some('>') {
                ">>"
            } else {
                break;
            };
            self.pos += op.len();
            let right = self.parse_additive()?;
            let count = (right.to_i32() & 31) as u32;
            left = match op {
                "<<" => JsVal::Num(left.to_i32().wrapping_shl(count) as f64),
                ">>" => JsVal::Num(left.to_i32().wrapping_shr(count) as f64),
                _ => JsVal::Num(((left.to_i32() as u32).wrapping_shr(count)) as f64),
            };
        }
        Ok(left)
    }

    fn parse_additive(&mut self) -> Result<JsVal, String> {
        let mut left = self.parse_multiplicative()?;
        loop {
            self.skip_ws();
            let op = match self.peek() {
                Some('+') => '+',
                Some('-') => '-',
                _ => break,
            };
            self.pos += 1;
            let right = self.parse_multiplicative()?;
            left = if op == '+' {
                if matches!(left, JsVal::Str(_)) || matches!(right, JsVal::Str(_)) {
                    JsVal::Str(format!(
                        "{}{}",
                        left.to_js_string(),
                        right.to_js_string()
                    ))
                } else {
                    JsVal::Num(left.to_number() + right.to_number())
                }
            } else {
                JsVal::Num(left.to_number() - right.to_number())
            };
        }
        Ok(left)
    }

    fn parse_multiplicative(&mut self) -> Result<JsVal, String> {
        let mut left = self.parse_unary()?;
        loop {
            self.skip_ws();
            let op = match self.peek() {
                Some('*') => '*',
                Some('/') => '/',
                Some('%') => '%',
                _ => break,
            };
            self.pos += 1;
            let right = self.parse_unary()?;
            left = match op {
                '*' => JsVal::Num(left.to_number() * right.to_number()),
                '/' => JsVal::Num(left.to_number() / right.to_number()),
                _ => JsVal::Num(left.to_number() % right.to_number()),
            };
        }
        Ok(left)
    }

    fn parse_unary(&mut self) -> Result<JsVal, String> {
        self.skip_ws();
        match self.peek() {
            Some('+') => {
                self.pos += 1;
                Ok(JsVal::Num(self.parse_unary()?.to_number()))
            }
            Some('-') => {
                self.pos += 1;
                Ok(JsVal::Num(-self.parse_unary()?.to_number()))
            }
            Some('!') => {
                self.pos += 1;
                Ok(JsVal::Bool(!self.parse_unary()?.truthy()))
            }
            Some('~') => {
                self.pos += 1;
                Ok(JsVal::Num(!self.parse_unary()?.to_i32() as f64))
            }
            _ => self.parse_postfix(),
        }
    }

    fn parse_postfix(&mut self) -> Result<JsVal, String> {
        let mut val = self.parse_primary()?;
        loop {
            self.skip_ws();
            if self.peek() != Some('.') {
                break;
            }
            // '.' 后跟数字是小数的一部分，不应出现在这里；若出现则报错。
            if matches!(self.peek_at(1), Some(c) if c.is_ascii_digit()) {
                break;
            }
            self.pos += 1;
            let name = self.parse_ident()?;
            match name.as_str() {
                "toString" => {
                    self.skip_ws();
                    if self.peek() == Some('(') {
                        self.parse_args()?;
                    }
                    val = JsVal::Str(val.to_js_string());
                }
                "charCodeAt" => {
                    let args = self.parse_args()?;
                    let s = val.to_js_string();
                    let idx = args
                        .first()
                        .map(|v| {
                            let n = v.to_number();
                            if n.is_nan() || n <= 0.0 {
                                0usize
                            } else {
                                n.trunc() as usize
                            }
                        })
                        .unwrap_or(0);
                    val = JsVal::Num(char_code_at(&s, idx));
                }
                "length" => {
                    let s = val.to_js_string();
                    val = JsVal::Num(utf16_units(&s).len() as f64);
                }
                "substring" => {
                    let args = self.parse_args()?;
                    let s = val.to_js_string();
                    let start = args.first().map(|v| v.to_number()).unwrap_or(0.0);
                    let end = args.get(1).map(|v| v.to_number());
                    val = JsVal::Str(utf16_substring(&s, start, end));
                }
                "slice" => {
                    let args = self.parse_args()?;
                    let s = val.to_js_string();
                    let start = args.first().map(|v| v.to_number()).unwrap_or(0.0);
                    let end = args.get(1).map(|v| v.to_number());
                    val = JsVal::Str(utf16_slice(&s, start, end));
                }
                "charAt" => {
                    let args = self.parse_args()?;
                    let s = val.to_js_string();
                    let idx = args.first().map(|v| v.to_number()).unwrap_or(0.0);
                    val = JsVal::Str(utf16_char_at(&s, idx));
                }
                "indexOf" => {
                    let args = self.parse_args()?;
                    let s = val.to_js_string();
                    let pat = args
                        .first()
                        .map(|v| v.to_js_string())
                        .unwrap_or_default();
                    let from = args.get(1).map(|v| v.to_number()).unwrap_or(0.0);
                    val = JsVal::Num(utf16_index_of(&s, &pat, from));
                }
                other => return Err(format!("JS 求值：不支持的成员 .{other}")),
            }
        }
        Ok(val)
    }

    fn parse_args(&mut self) -> Result<Vec<JsVal>, String> {
        self.expect('(')?;
        let mut args = Vec::new();
        self.skip_ws();
        if self.peek() == Some(')') {
            self.pos += 1;
            return Ok(args);
        }
        loop {
            args.push(self.parse_expr()?);
            self.skip_ws();
            match self.peek() {
                Some(',') => {
                    self.pos += 1;
                }
                Some(')') => {
                    self.pos += 1;
                    break;
                }
                other => {
                    return Err(format!("JS 求值：参数列表期望 ',' 或 ')'，实际 {other:?}"));
                }
            }
        }
        Ok(args)
    }

    fn parse_ident(&mut self) -> Result<String, String> {
        self.skip_ws();
        let mut name = String::new();
        match self.peek() {
            Some(c) if c.is_ascii_alphabetic() || c == '_' || c == '$' => {
                name.push(c);
                self.pos += 1;
            }
            other => return Err(format!("JS 求值：期望标识符，实际 {other:?}")),
        }
        while let Some(c) = self.peek() {
            if c.is_ascii_alphanumeric() || c == '_' || c == '$' {
                name.push(c);
                self.pos += 1;
            } else {
                break;
            }
        }
        Ok(name)
    }

    fn parse_number(&mut self) -> Result<JsVal, String> {
        let mut text = String::new();
        while let Some(c) = self.peek() {
            if c.is_ascii_digit() || c == '.' {
                text.push(c);
                self.pos += 1;
            } else {
                break;
            }
        }
        if matches!(self.peek(), Some('e') | Some('E')) {
            text.push(self.bump().unwrap());
            if matches!(self.peek(), Some('+') | Some('-')) {
                text.push(self.bump().unwrap());
            }
            while let Some(c) = self.peek() {
                if c.is_ascii_digit() {
                    text.push(c);
                    self.pos += 1;
                } else {
                    break;
                }
            }
        }
        text.parse::<f64>()
            .map(JsVal::Num)
            .map_err(|_| format!("JS 求值：数字解析失败 {text}"))
    }

    fn parse_string(&mut self) -> Result<JsVal, String> {
        let quote = self.bump().unwrap();
        let mut out = String::new();
        loop {
            let Some(c) = self.bump() else {
                return Err("JS 求值：字符串未闭合".to_string());
            };
            if c == quote {
                break;
            }
            if c == '\\' {
                let Some(e) = self.bump() else {
                    return Err("JS 求值：字符串未闭合".to_string());
                };
                match e {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'b' => out.push('\u{0008}'),
                    'f' => out.push('\u{000C}'),
                    'v' => out.push('\u{000B}'),
                    '0' => {
                        if matches!(self.peek(), Some(d) if d.is_ascii_digit()) {
                            return Err("JS 求值：不支持的八进制转义".to_string());
                        }
                        out.push('\0');
                    }
                    'x' => {
                        let h1 = self.bump().unwrap_or('0');
                        let h2 = self.bump().unwrap_or('0');
                        let v = u32::from_str_radix(&format!("{h1}{h2}"), 16)
                            .map_err(|_| "JS 求值：\\x 转义非法".to_string())?;
                        out.push(char::from_u32(v).unwrap_or('\u{FFFD}'));
                    }
                    'u' => {
                        let mut hex = String::new();
                        if self.peek() == Some('{') {
                            self.pos += 1;
                            while let Some(c) = self.bump() {
                                if c == '}' {
                                    break;
                                }
                                hex.push(c);
                            }
                        } else {
                            for _ in 0..4 {
                                hex.push(self.bump().unwrap_or('0'));
                            }
                        }
                        let v = u32::from_str_radix(&hex, 16)
                            .map_err(|_| "JS 求值：\\u 转义非法".to_string())?;
                        out.push(char::from_u32(v).unwrap_or('\u{FFFD}'));
                    }
                    '\n' => {}
                    other => out.push(other),
                }
            } else {
                out.push(c);
            }
        }
        Ok(JsVal::Str(out))
    }

    fn parse_primary(&mut self) -> Result<JsVal, String> {
        self.skip_ws();
        match self.peek() {
            Some(c) if c.is_ascii_digit() => self.parse_number(),
            Some('.') if matches!(self.peek_at(1), Some(d) if d.is_ascii_digit()) => {
                self.parse_number()
            }
            Some('\'') | Some('"') => self.parse_string(),
            Some('(') => {
                self.pos += 1;
                let v = self.parse_expr()?;
                self.expect(')')?;
                Ok(v)
            }
            Some(c) if c.is_ascii_alphabetic() || c == '_' || c == '$' => {
                let name = self.parse_ident()?;
                match name.as_str() {
                    "true" => Ok(JsVal::Bool(true)),
                    "false" => Ok(JsVal::Bool(false)),
                    "null" | "undefined" => Ok(JsVal::Null),
                    "NaN" => Ok(JsVal::Num(f64::NAN)),
                    "Infinity" => Ok(JsVal::Num(f64::INFINITY)),
                    "window" | "document" => {
                        // 环境对象成员链按真值处理：window.Array、
                        // document.body 等在 nonce 里只作真值判断
                        //（如 !window.Array），对象本身恒为真值。
                        loop {
                            self.skip_ws();
                            if self.peek() == Some('.') {
                                self.pos += 1;
                                let _ = self.parse_ident()?;
                            } else {
                                break;
                            }
                        }
                        self.skip_ws();
                        if self.peek() == Some('(') {
                            let _ = self.parse_args()?;
                        }
                        Ok(JsVal::Bool(true))
                    }
                    "eval" => {
                        let args = self.parse_args()?;
                        let code = args
                            .first()
                            .map(|v| v.to_js_string())
                            .unwrap_or_default();
                        let mut sub = JsParser::new(&code);
                        let v = sub.parse_expr()?;
                        sub.skip_ws();
                        if sub.pos != sub.chars.len() {
                            return Err("JS 求值：eval 内层表达式有剩余内容".to_string());
                        }
                        Ok(v)
                    }
                    "parseInt" => {
                        let args = self.parse_args()?;
                        let v = args.first().cloned().unwrap_or(JsVal::Null);
                        Ok(parse_int_value(&v))
                    }
                    "Math" => {
                        self.skip_ws();
                        if self.peek() != Some('.') {
                            return Err("JS 求值：Math 后须跟成员".to_string());
                        }
                        self.pos += 1;
                        let member = self.parse_ident()?;
                        let args = self.parse_args()?;
                        let n = args.first().map(|v| v.to_number()).unwrap_or(f64::NAN);
                        match member.as_str() {
                            "round" => Ok(JsVal::Num((n + 0.5).floor())),
                            "floor" => Ok(JsVal::Num(n.floor())),
                            "ceil" => Ok(JsVal::Num(n.ceil())),
                            "abs" => Ok(JsVal::Num(n.abs())),
                            "sqrt" => Ok(JsVal::Num(n.sqrt())),
                            "pow" => {
                                let b = args
                                    .get(1)
                                    .map(|v| v.to_number())
                                    .unwrap_or(0.0);
                                Ok(JsVal::Num(n.powf(b)))
                            }
                            "max" => Ok(JsVal::Num(
                                args
                                    .iter()
                                    .map(|v| v.to_number())
                                    .fold(f64::NEG_INFINITY, f64::max),
                            )),
                            "min" => Ok(JsVal::Num(
                                args
                                    .iter()
                                    .map(|v| v.to_number())
                                    .fold(f64::INFINITY, f64::min),
                            )),
                            other => {
                                Err(format!("JS 求值：不支持的 Math.{other}"))
                            }
                        }
                    }
                    "String" => {
                        self.skip_ws();
                        if self.peek() != Some('.') {
                            return Err("JS 求值：String 后须跟成员".to_string());
                        }
                        self.pos += 1;
                        let member = self.parse_ident()?;
                        match member.as_str() {
                            "fromCharCode" => {
                                let args = self.parse_args()?;
                                Ok(JsVal::Str(from_char_codes(&args)))
                            }
                            other => {
                                Err(format!("JS 求值：不支持的 String.{other}"))
                            }
                        }
                    }
                    other => Err(format!("JS 求值：不支持的标识符 {other}")),
                }
            }
            other => Err(format!("JS 求值：无法解析的表达式开头 {other:?}")),
        }
    }
}

/// inner 里是否在字符串字面量之外出现 window/document 标识符。
/// preprocess 只应替换真正的 (window.xxx).toString() / (document.xxx).toString()，
/// 不能把 eval("...window...") 这种字符串里的 window 当成成员访问。
fn contains_bare_window_or_document(inner: &str) -> bool {
    let b = inner.as_bytes();
    let mut i = 0usize;
    let mut quote: Option<u8> = None;
    while i < b.len() {
        let c = b[i];
        if let Some(q) = quote {
            if c == b'\\' {
                i += 2;
                continue;
            }
            if c == q {
                quote = None;
            }
            i += 1;
            continue;
        }
        match c {
            b'"' | b'\'' => quote = Some(c),
            b'w' | b'd' => {
                let word = if c == b'w' { "window" } else { "document" };
                if inner[i..].starts_with(word) {
                    let after = i + word.len();
                    let before_ok = i == 0 || !is_ident_char(b[i - 1]);
                    let after_ok = after >= b.len() || !is_ident_char(b[after]);
                    if before_ok && after_ok {
                        return true;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
}

fn is_ident_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'$'
}

/// 求值前预处理：把含 (...document...).toString 或 (...window...).toString
/// 的括号片段整个替换为 0（文档 5.3 的做法）。
fn preprocess_js(expr: &str) -> String {
    let mut s = expr.to_string();
    let mut from = 0usize;
    loop {
        let Some(rel) = s[from..].find(".toString") else {
            break;
        };
        let idx = from + rel;
        let mut j = idx;
        while j > 0 && s.as_bytes()[j - 1].is_ascii_whitespace() {
            j -= 1;
        }
        if j == 0 || s.as_bytes()[j - 1] != b')' {
            from = idx + 9;
            continue;
        }
        // 找到与 j-1 处 ')' 配对的 '('。
        let bytes = s.as_bytes();
        let mut depth = 0i32;
        let mut open: Option<usize> = None;
        let mut k = j;
        while k > 0 {
            k -= 1;
            match bytes[k] {
                b')' => depth += 1,
                b'(' => {
                    depth -= 1;
                    if depth == 0 {
                        open = Some(k);
                        break;
                    }
                }
                _ => {}
            }
        }
        let Some(open) = open else {
            from = idx + 9;
            continue;
        };
        let inner = &s[open + 1..j - 1];
        if contains_bare_window_or_document(inner) {
            let mut end = idx + 9;
            let rest = &s[end..];
            let rest_trim = rest.trim_start();
            if rest_trim.starts_with("()") {
                end += rest.len() - rest_trim.len() + 2;
            }
            s.replace_range(open..end, "0");
            from = open + 1;
        } else {
            from = idx + 9;
        }
    }
    s
}

fn eval_js(expr: &str) -> Result<JsVal, String> {
    let cleaned = preprocess_js(expr);
    let mut p = JsParser::new(&cleaned);
    let v = p.parse_expr()?;
    p.skip_ws();
    if p.peek() == Some(';') {
        p.pos += 1;
        p.skip_ws();
    }
    if p.pos != p.chars.len() {
        return Err(format!(
            "JS 求值：表达式有剩余内容 {}",
            p.chars[p.pos..].iter().collect::<String>()
        ));
    }
    Ok(v)
}

/// 章节页里取 DATA 密文 T 与 window[…] 最后一条赋值求出的 N。
fn extract_nonce(page: &str) -> ApiResult<(String, String)> {
    let t = cap(
        &must_re(r"(?s)DATA[^=]*=\s*'(.*?)',"),
        page,
    )
    .ok_or_else(|| ApiError::Internal("腾讯章节页未找到 DATA 密文".into()))?;
    let assigns: Vec<String> = must_re(r"(?s)window\[.*?\] *=(.*?);")
        .captures_iter(page)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .collect();
    let last = assigns
        .last()
        .ok_or_else(|| ApiError::Internal("腾讯章节页未找到 window 赋值".into()))?;
    let n = eval_js(last)
        .map_err(|e| ApiError::Internal(format!("腾讯章节 JS 求值失败: {e}")))?
        .to_js_string();
    let ok = n.len() == 32 && n.chars().all(|c| c.is_ascii_hexdigit());
    if !ok {
        return Err(ApiError::Internal(
            "腾讯章节 JS 求值未得有效 N".into(),
        ));
    }
    Ok((t, n))
}

/// decode(T, N)：按“数字+字母”切 token，从后往前删字符，再 Base64 解码。
fn decode_t_n(t: &str, n: &str) -> ApiResult<String> {
    let mut chars: Vec<char> = t.chars().collect();
    let tokens: Vec<String> = must_re(r"\d+[a-zA-Z]+")
        .find_iter(n)
        .map(|m| m.as_str().to_string())
        .collect();
    for tok in tokens.iter().rev() {
        let digits: String = tok.chars().take_while(|c| c.is_ascii_digit()).collect();
        let locate = digits.parse::<i64>().unwrap_or(0) & 255;
        let del = tok.len() - digits.len();
        let locate = locate as usize;
        if locate < chars.len() && del > 0 {
            let end = (locate + del).min(chars.len());
            chars.drain(locate..end);
        }
    }
    let joined: String = chars.into_iter().collect();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(joined.as_bytes())
        .or_else(|_| {
            let mut padded = joined.clone();
            while padded.len() % 4 != 0 {
                padded.push('=');
            }
            base64::engine::general_purpose::STANDARD.decode(padded.as_bytes())
        })
        .map_err(|_| ApiError::Internal("腾讯章节 Base64 解码失败".into()))?;
    Ok(String::from_utf8_lossy(&decoded).replace('\\', ""))
}

/// 从解码文本取全部 "url":"…"。
fn extract_images(decoded: &str) -> Vec<String> {
    must_re(r#""url":"([^"]+)""#)
        .captures_iter(decoded)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .collect()
}

fn parse_cards(page: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    // 桌面列表（搜索 / 分类）：ul.mod_book_list li。
    if let Some(ul) = cap(
        &must_re(r#"(?s)<ul class="[^"]*mod_book_list[^"]*">(.*?)</ul>"#),
        page,
    ) {
        for li in must_re(r"(?s)<li>(.*?)</li>").captures_iter(&ul) {
            let block = &li[1];
            let Some(id) = cap(
                &must_re(r"/Comic/comicInfo/id/(\d+)"),
                block,
            ) else {
                continue;
            };
            if !seen.insert(id.clone()) {
                continue;
            }
            let title = cap(
                &must_re(r#"title="([^"]+)" class="mod_book_cover"#),
                block,
            )
            .or_else(|| {
                cap(
                    &must_re(r#"(?s)<h4 class="mod_book_name">.*?<a[^>]*>([^<]+)</a>"#),
                    block,
                )
            })
            .unwrap_or_default();
            if title.is_empty() {
                continue;
            }
            let cover = cap(&must_re(r#"data-original='([^']+)'"#), block)
                .or_else(|| {
                    cap(&must_re(r#"<img[^>]*src="([^"]+)""#), block)
                        .filter(|s| !s.contains("blank.gif"))
                })
                .unwrap_or_default();
            let cover = if cover.starts_with("//") {
                format!("https:{cover}")
            } else {
                cover
            };
            let remark = cap(
                &must_re(r#"<h3 class="mod_book_update[^"]*">([^<]+)</h3>"#),
                block,
            )
            .unwrap_or_default();
            items.push(item_json(&id, &clean_collapse(&title), &cover, &remark));
        }
    }
    // 分类列表页（/Comic/all/…）：ul.ret-search-list li.ret-search-item。
    if let Some(ul) = cap(
        &must_re(r#"(?s)<ul class="[^"]*ret-search-list[^"]*">(.*?)</ul>"#),
        page,
    ) {
        for li in must_re(r#"(?s)<li class="ret-search-item[^"]*">(.*?)</li>"#)
            .captures_iter(&ul)
        {
            let block = &li[1];
            let Some(id) = cap(&must_re(r"/Comic/comicInfo/id/(\d+)"), block) else {
                continue;
            };
            if !seen.insert(id.clone()) {
                continue;
            }
            let title = cap(
                &must_re(r#"title="([^"]+)" href="/Comic/comicInfo/id/\d+""#),
                block,
            )
            .unwrap_or_default();
            if title.is_empty() {
                continue;
            }
            let cover = cap(&must_re(r#"data-original="([^"]+)""#), block)
                .or_else(|| {
                    cap(&must_re(r#"<img[^>]*src="([^"]+)""#), block)
                        .filter(|s| !s.contains("blank.gif"))
                })
                .unwrap_or_default();
            let cover = if cover.starts_with("//") {
                format!("https:{cover}")
            } else {
                cover
            };
            let remark = cap(
                &must_re(r#"<span class="mod-cover-list-text">([^<]+)</span>"#),
                block,
            )
            .unwrap_or_default();
            items.push(item_json(&id, &clean_collapse(&title), &cover, &remark));
        }
    }
    // 移动排行：a.comic-link。
    for a in must_re(
        r#"(?s)<a class="comic-link" href="/comic/index/id/(\d+)">(.*?)</a>"#,
    )
    .captures_iter(page)
    {
        let id = a[1].to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let block = &a[2];
        let title = cap(
            &must_re(r#"<strong class="comic-title">([^<]+)</strong>"#),
            block,
        )
        .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let cover = cap(&must_re(r#"<img[^>]*src="([^"]+)""#), block).unwrap_or_default();
        let remark = cap(
            &must_re(r#"<small class="comic-update">([^<]+)</small>"#),
            block,
        )
        .unwrap_or_default();
        items.push(item_json(&id, &clean_collapse(&title), &cover, &remark));
    }
    items
}

fn parse_detail(series_id: &str, page: &str) -> Value {
    let title = cap(
        &must_re(r#"(?s)<h1[^>]*works-intro-title[^>]*>\s*<strong>([^<]+)</strong>"#),
        page,
    )
    .map(|t| clean_collapse(&t))
    .unwrap_or_default();
    let title = if title.is_empty() {
        series_id.to_string()
    } else {
        title
    };
    let cover = cap(
        &must_re(r#"(?s)works-cover[^>]*>.*?<img[^>]*src="([^"]+)""#),
        page,
    )
    .unwrap_or_default();
    let synopsis = cap(
        &must_re(r#"(?s)<p class="works-intro-short[^"]*">(.*?)</p>"#),
        page,
    )
    .map(|t| clean_collapse(&t))
    .unwrap_or_default();
    let author = cap(
        &must_re(r"作者：<em[^>]*>([^<]+)"),
        page,
    )
    .map(|t| clean_collapse(&t))
    .unwrap_or_default();
    let status = cap(
        &must_re(r#"<label class="works-intro-status">([^<]+)</label>"#),
        page,
    )
    .map(|t| clean_collapse(&t))
    .unwrap_or_default();
    // 章节：按 <span class='works-chapter-item'> 切段，段内取链接与付费标记。
    let span_re = must_re(r#"<span class=['"]works-chapter-item['"]>"#);
    let starts: Vec<usize> = span_re.find_iter(page).map(|m| m.start()).collect();
    let mut episodes: Vec<Value> = Vec::new();
    let mut paid = 0usize;
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(page.len());
        let seg = &page[start..end];
        let Some(caps) =
            must_re(r#"/ComicView/index/id/(\d+)/cid/(\d+)"#).captures(seg)
        else {
            continue;
        };
        let comic_id = caps[1].to_string();
        let cid = caps[2].to_string();
        let name = cap(
            &must_re(r#"(?s)<a[^>]*>([^<]+)</a>"#),
            seg,
        )
        .map(|t| clean_collapse(&t))
        .unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        let is_pay = seg.contains("ui-icon-pay");
        if is_pay {
            paid += 1;
        }
        let display = if is_pay {
            format!("{name}（付费）")
        } else {
            name
        };
        episodes.push(episode_json(
            &format!("{comic_id}/{cid}"),
            &display,
            series_id,
        ));
    }
    let total = episodes.len();
    let remark = if total > 0 {
        format!("共{total}话 · {paid}话付费")
    } else {
        String::new()
    };
    json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"author": author, "status": status, "remark": remark},
        "episodes": episodes,
    })
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": CATEGORIES.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    if let Some(rank) = category_id.strip_prefix("rank:") {
        // 排行是单页榜单，page>1 无新内容，直接返回空，不重复推第一页。
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let Some(path) = rank_path(rank) else {
            return Err(ApiError::Internal(format!("腾讯动漫未知排行 {rank}")));
        };
        let url = format!("{RANK_URL}/rank/{path}");
        let items = parse_cards(&fetch_mobile(&url).await?);
        let has_more = false;
        return Ok(json!({"items": items, "has_more": has_more}));
    }
    let cat = if category_id.is_empty() {
        "rank:hot"
    } else {
        category_id
    };
    if let Some(rank) = cat.strip_prefix("rank:") {
        if page > 1 {
            return Ok(json!({"items": [], "has_more": false}));
        }
        let Some(path) = rank_path(rank) else {
            return Err(ApiError::Internal(format!("腾讯动漫未知排行 {rank}")));
        };
        let url = format!("{RANK_URL}/rank/{path}");
        let items = parse_cards(&fetch_mobile(&url).await?);
        return Ok(json!({"items": items, "has_more": false}));
    }
    let url = format!("{BASE_URL}/Comic/all/{cat}/search/hot/page/{page}");
    let items = parse_cards(&fetch(&url).await?);
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let page = fetch(&format!("{BASE_URL}/Comic/comicInfo/id/{series_id}")).await?;
    if page.is_empty() {
        return Err(ApiError::Internal("腾讯动漫详情页为空".into()));
    }
    Ok(parse_detail(series_id, &page))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let url = format!(
        "{BASE_URL}/Comic/searchList?search={}",
        pct_encode_query(query)
    );
    let items = parse_cards(&fetch(&url).await?);
    Ok(json!({"items": items}))
}

fn strip_label(raw: &str) -> String {
    match raw.split_once('$') {
        Some((_, rest)) => rest.to_string(),
        None => raw.to_string(),
    }
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let id = strip_label(video_id);
    if let Some(rest) = id.strip_prefix("pics://") {
        return Ok(json!({"url": format!("pics://{rest}")}));
    }
    let mut parts = id.splitn(2, '/');
    let comic_id = parts.next().unwrap_or("");
    let cid = parts.next().unwrap_or("");
    if comic_id.is_empty() || cid.is_empty() {
        return Err(ApiError::Internal(
            "腾讯动漫播放 id 格式错误，应为 {漫画id}/{cid}".into(),
        ));
    }
    let page = fetch(&format!(
        "{BASE_URL}/ComicView/index/id/{comic_id}/cid/{cid}"
    ))
    .await?;
    let (t, n) = extract_nonce(&page)?;
    let decoded = decode_t_n(&t, &n)?;
    let images = extract_images(&decoded);
    if images.is_empty() {
        return Err(ApiError::Internal("腾讯章节未解出图片".into()));
    }
    Ok(json!({
        "url": format!("pics://{}", images.join("&&")),
        "header": {"User-Agent": UA, "Referer": format!("{BASE_URL}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHAPTER1: &str = include_str!(
        "../../../../../mycomic_re/probe/tx_chapter.bin"
    );
    const CHAPTER3: &str = include_str!("../../../../../mycomic_re/probe/tx_cid3.html");
    const CHAPTER1B: &str = include_str!("../../../../../mycomic_re/probe/tx_cid2b.html");
    const CHAPTER_LIVE: &str =
        include_str!("../../../../../mycomic_re/probe/tx_live_cid2.html");
    const DETAIL: &str = include_str!("../../../../../mycomic_re/probe/tx_detail.bin");
    const SEARCH: &str = include_str!(
        "../../../../../mycomic_re/probe/tengxun_search.bin"
    );
    const RANK: &str = include_str!("../../../../../mycomic_re/probe/tx_rank.bin");
    const THEME101: &str =
        include_str!("../../../../../mycomic_re/probe/tx_theme101.html");
    const IMAGES1: &str =
        include_str!("../../../../../mycomic_re/probe/tx_images.json");

    fn eval_str(expr: &str) -> String {
        eval_js(expr).unwrap().to_js_string()
    }

    #[test]
    fn eval_covers_sample_operators() {
        assert_eq!(eval_str("9 * 0"), "0");
        assert_eq!(eval_str("parseInt(7/3)"), "2");
        assert_eq!(eval_str("4 + !!!1"), "4");
        assert_eq!(eval_str("Math.round(.5) + ~~1.4"), "2");
        assert_eq!(eval_str("'1'.charCodeAt() - 45"), "4");
        assert_eq!(eval_str("'a' + 'b'"), "ab");
        assert_eq!(eval_str("1 + '2'"), "12");
        assert_eq!(eval_str("'x'.length"), "1");
        assert_eq!(eval_str("String.fromCharCode(104, 105)"), "hi");
        assert_eq!(eval_str("Math.floor(1.9)"), "1");
        assert_eq!(eval_str("Math.ceil(1.1)"), "2");
        assert_eq!(eval_str("~5"), "-6");
        assert_eq!(eval_str("!!0"), "false");
        assert_eq!(eval_str("2 * 3 % 4"), "2");
        assert_eq!(eval_str("10 / 4"), "2.5");
        assert_eq!(eval_str("'ab'.charCodeAt(1)"), "98");
        assert_eq!(eval_str("parseInt('42px')"), "42");
        assert_eq!(eval_str("+eval(\"9 * 0\")"), "0");
        assert_eq!(eval_str("(9 * 0).toString()"), "0");
        assert_eq!(eval_str("\"a\" + (+eval(\"9 * 0\")).toString() + \"b\""), "a0b");
    }

    #[test]
    fn eval_covers_live_template_variants() {
        // 真站轮换模板里出现过的新算子（Math.pow 在一次 live 跑撞见，
        // 其余在 2026-11-05 新抓的 tx_live_cid2.html 里）。
        assert_eq!(eval_str("Math.pow(2, 3)"), "8");
        assert_eq!(eval_str("Math.max(1, 9, 3)"), "9");
        assert_eq!(eval_str("Math.min(1, 9, 3)"), "1");
        assert_eq!(eval_str("Math.abs(0 - 5)"), "5");
        assert_eq!(eval_str("Math.sqrt(16)"), "4");
        assert_eq!(eval_str("5&5"), "5");
        assert_eq!(eval_str("5|2"), "7");
        assert_eq!(eval_str("5^3"), "6");
        assert_eq!(eval_str("1<<4"), "16");
        assert_eq!(eval_str("-8>>2"), "-2");
        assert_eq!(eval_str("-1>>>0"), "4294967295");
        assert_eq!(eval_str("'123'.substring(2)"), "3");
        assert_eq!(eval_str("'hello'.slice(1, 3)"), "el");
        assert_eq!(eval_str("'abc'.charAt(1)"), "b");
        assert_eq!(eval_str("'abc'.indexOf('b')"), "1");
        assert_eq!(eval_str("!window.Array"), "false");
        assert_eq!(eval_str("1 * (!window.Array) + 1"), "1");
        assert_eq!(eval_str("2 + 3 << 1"), "10");
        assert_eq!(eval_str("1 | 2 & 3"), "3");
    }

    #[test]
    fn eval_rejects_unsupported_operator() {
        assert!(eval_js("\"a\" && true").is_err());
        // 按位与已支持（见 eval_covers_live_template_variants），改用真正不支持的幂运算。
        assert!(eval_js("2 ** 3").is_err());
    }

    #[test]
    fn preprocess_replaces_document_tostring_with_zero() {
        let expr = "(window.foo).toString() + 'x'";
        assert_eq!(eval_str(&preprocess_js(expr)), "0x");
        let expr = "('a' + (document.bar).toString())";
        assert_eq!(eval_str(&preprocess_js(expr)), "a0");
        // 回归：eval 字符串里的 window 不是成员访问，不应触发替换。
        assert_eq!(eval_str("(+eval(\"1 * (!window.Array) + 1\")).toString()"), "1");
    }

    #[test]
    fn nonce_matches_three_samples() {
        let (_, n1) = extract_nonce(CHAPTER1).unwrap();
        assert_eq!(n1, "fcab167daf47b3d84ea96279a5da0f5d");
        let (_, n3) = extract_nonce(CHAPTER3).unwrap();
        assert_eq!(n3, "f0378bf3464b38a2ef3568df3d6dd049");
        let (_, n1b) = extract_nonce(CHAPTER1B).unwrap();
        assert_eq!(n1b, "849a6246a89b5ccc8af5083b2b40f39f");
    }

    #[test]
    fn nonce_matches_live_sample_with_new_operators() {
        // 2026-11-05 新抓的第 1 话：含 substring、按位与、!window.Array。
        // N 与 Node（window 垫片）实测的真值一致：预处理只认字符串字面量
        // 之外的裸 window/document 标识符，eval 串里的 window 一词不触发
        // 替换，故 (+eval("1 * (!window.Array) + 1")).toString() 得 "1"。
        let (t, n) = extract_nonce(CHAPTER_LIVE).unwrap();
        assert_eq!(n, "c09e0423431b8fb907e5949aa54bc815");
        let imgs = extract_images(&decode_t_n(&t, &n).unwrap());
        assert_eq!(imgs.len(), 12);
        assert_eq!(
            imgs[0],
            "https://manhua.acimg.cn/manhua_detail/0/03_14_08_a3f264f57dcc99251a8d1e9030b018e97_114823300.jpg/0"
        );
    }

    #[test]
    fn decode_matches_sample_image_counts() {
        let (t1, n1) = extract_nonce(CHAPTER1).unwrap();
        let imgs1 = extract_images(&decode_t_n(&t1, &n1).unwrap());
        assert_eq!(imgs1.len(), 12);
        assert_eq!(
            imgs1[0],
            "https://manhua.acimg.cn/manhua_detail/0/03_14_08_a3f264f57dcc99251a8d1e9030b018e97_114823300.jpg/0"
        );
        let expected: Vec<String> =
            serde_json::from_str(IMAGES1).unwrap();
        assert_eq!(imgs1, expected);

        let (t3, n3) = extract_nonce(CHAPTER3).unwrap();
        let imgs3 = extract_images(&decode_t_n(&t3, &n3).unwrap());
        assert_eq!(imgs3.len(), 26);
        assert_eq!(
            imgs3[0],
            "https://manhua.acimg.cn/manhua_detail/0/03_14_22_a116038f52897481a39a8449227623d2c_114823345.jpg/0"
        );

        let (t1b, n1b) = extract_nonce(CHAPTER1B).unwrap();
        let imgs1b = extract_images(&decode_t_n(&t1b, &n1b).unwrap());
        assert_eq!(imgs1b.len(), 12);
        assert_eq!(imgs1b, imgs1);
    }

    #[test]
    fn detail_parses_truncated_sample() {
        let d = parse_detail("649513", DETAIL);
        assert_eq!(d["title"], "斗罗大陆 II 绝世唐门");
        assert!(d["cover"].as_str().unwrap().starts_with("https://manhua.acimg.cn/vertical/"));
        assert!(d["synopsis"].as_str().unwrap().contains("唐门"));
        assert_eq!(d["extra"]["author"], "神漫君");
        assert_eq!(d["extra"]["status"], "连载中");
        let eps = d["episodes"].as_array().unwrap();
        assert_eq!(eps.len(), 396);
        let paid = eps
            .iter()
            .filter(|e| e["title"].as_str().unwrap().contains("（付费）"))
            .count();
        assert_eq!(paid, 342);
        assert_eq!(eps[0]["video_id"], "649513/2");
        assert!(eps[0]["title"].as_str().unwrap().contains("引子"));
        assert_eq!(eps[0]["series_id"], "649513");
    }

    #[test]
    fn search_parses_sample() {
        let items = parse_cards(SEARCH);
        assert_eq!(items.len(), 24);
        assert_eq!(items[0]["id"], "649513");
        assert_eq!(items[0]["title"], "斗罗大陆 II 绝世唐门");
        assert!(items[0]["remark"].as_str().unwrap().contains("625"));
    }

    #[test]
    fn catalog_parses_ret_search_list_sample() {
        // 分类列表页真站结构（2026-11-05 实抓 theme/101）：不是搜索那套
        // mod_book_list，而是 ul.ret-search-list，每页 12 条。
        let items = parse_cards(THEME101);
        assert_eq!(items.len(), 12);
        assert_eq!(items[0]["id"], "650445");
        assert_eq!(items[0]["title"], "我的徒弟都是大反派");
        assert!(items[0]["remark"].as_str().unwrap().contains("578"));
        assert!(items[0]["cover"]
            .as_str()
            .unwrap()
            .starts_with("https://manhua.acimg.cn/vertical/"));
    }

    #[test]
    fn rank_parses_sample() {
        let items = parse_cards(RANK);
        assert_eq!(items.len(), 10);
        assert_eq!(items[0]["id"], "540929");
        assert_eq!(items[0]["title"], "黑色四叶草");
        assert!(items.iter().any(|i| i["title"] == "绝世武神"));
        assert!(items.iter().any(|i| i["title"] == "星武神诀"));
    }

    #[test]
    fn rank_paths_match_live_redirects() {
        assert_eq!(rank_path("rise"), Some("biaosheng"));
        assert_eq!(rank_path("pay"), Some("changxiao"));
        assert_eq!(rank_path("new"), Some("xinzuo"));
        assert_eq!(rank_path("hot"), Some("zhenxiang"));
        assert_eq!(rank_path("bogus"), None);
    }

    #[test]
    fn categories_have_no_paid_category() {
        let ids: Vec<&str> = CATEGORIES.iter().map(|(id, _)| *id).collect();
        assert_eq!(ids.len(), 23);
        assert!(!ids.contains(&"vip/2"));
        assert!(ids.contains(&"theme/101"));
        assert!(ids.contains(&"rank:hot"));
    }

    /// 真站完整链冒烟（默认不跑：须联网，章节数会随更新增长，只断言下限）。
    /// 跑法：cargo test --lib tencent live_chain -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn live_chain_smoke() {
        let found = search("斗罗大陆").await.unwrap();
        let items = found["items"].as_array().unwrap();
        assert!(!items.is_empty(), "搜索无结果");
        assert!(
            items.iter().any(|i| i["id"] == "649513"),
            "搜索应含 649513"
        );

        let d = detail("649513").await.unwrap();
        assert_eq!(d["title"], "斗罗大陆 II 绝世唐门");
        let eps = d["episodes"].as_array().unwrap();
        assert!(eps.len() >= 390, "详情章节数 {}", eps.len());
        assert!(eps.iter().any(|e| e["video_id"] == "649513/2"));

        let p = play("649513/2").await.unwrap();
        let url = p["url"].as_str().unwrap();
        assert!(url.starts_with("pics://https://manhua.acimg.cn/"));
        let n = url.split("&&").count();
        assert_eq!(n, 12, "第 1 话应解出 12 条，实际 {n}");

        let rank = catalog("rank:hot", 1).await.unwrap();
        let rank_items = rank["items"].as_array().unwrap();
        assert_eq!(rank_items.len(), 10, "真香榜应为 10 条");
        assert!(rank_items.iter().any(|i| i["title"] == "黑色四叶草"));
        let rank_p2 = catalog("rank:hot", 2).await.unwrap();
        assert!(rank_p2["items"].as_array().unwrap().is_empty());
        let theme = catalog("theme/101", 1).await.unwrap();
        assert!(!theme["items"].as_array().unwrap().is_empty());
        println!(
            "live ok: search={} detail_eps={} play_imgs={} rank={} theme101={}",
            items.len(),
            eps.len(),
            n,
            rank["items"].as_array().unwrap().len(),
            theme["items"].as_array().unwrap().len()
        );
    }
}
