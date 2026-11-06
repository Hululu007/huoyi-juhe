//! 妻社（qishe）：MD5 签名论坛帖站，游客态直出。
//!
//! - 双 host，默认第一个，失败换另一个。
//! - 签名：sign(方法名)=md5("url="+方法名+"&version=V1.1&time=DATA
//!   &domain=qs.qsh52693.org.cn")（小写十六进制）；请求为 GET
//!   {site}/source/plugin/qsts_app/index.php/{方法}?{参数}&sign=
//!   {sign}&version=V1.1；头带 Origin/Referer 为 SHELL 地址。
//! - 成功判定：响应长度≥20 且含 "code":200；响应可能带前缀杂质，
//!   取首个 {"code" 或 { 到最后 } 的子串再解析。
//! - 分类 13 个静态（与站导航一致，无萝莉分类）；home 走
//!   post.getIndexList，其余走 postlist.getThreadList?fid=。
//! - 列表卡片：附件里首个视频（.m3u8/.mp4/.mov/.m4v）为播放地址，
//!   首张图片为封面；封面回退：message 里首个 <img> →
//!   forumData.icon → 默认图。标题、播放地址、封面记入 MEMO 缓存，
//!   详情与取流只查 MEMO（没有则扫 home 第 1–4 页找回）。
//! - 搜索：站方 searchContent 直接返回空列表，这里同样返回空。
//! - 注意：站方 API 失败时 Java 会回退 CF 盾求解器，核心无此能力，
//!   直连被盾挡时如实报错。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const HOSTS: [&str; 2] = ["https://qs.qsh52693.org.cn", "https://h51.qisheh526222.org"];
const P_API: &str = "/source/plugin/qsts_app/index.php/";
const SIGN_DOM: &str = "qs.qsh52693.org.cn";
const SHELL: &str = "https://xn---253k3-vs4kz59r.qishegg56.com";
const DEF_PIC: &str = "https://img.qsimg26515.org.cn/img/fqjh.png";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PAGE_SIZE: i64 = 20;

static SITE: Mutex<String> = Mutex::new(String::new());
static MEMO: std::sync::LazyLock<Mutex<HashMap<String, (String, String, String)>>> =
    std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));

fn site() -> String {
    if let Ok(guard) = SITE.lock() {
        if !guard.is_empty() {
            return guard.clone();
        }
    }
    HOSTS[0].to_string()
}

fn set_site(host: &str) {
    if let Ok(mut guard) = SITE.lock() {
        *guard = host.to_string();
    }
}

/// md5("url="+方法+"&version=V1.1&time=DATA&domain="+SIGN_DOM)。
fn sign(method: &str) -> String {
    use md5::{Digest, Md5};
    let input = format!("url={method}&version=V1.1&time=DATA&domain={SIGN_DOM}");
    hex::encode(Md5::digest(input.as_bytes()))
}

fn fix_url(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("//") {
        format!("https:{rest}")
    } else {
        url.to_string()
    }
}

/// 响应可能带前缀杂质：取首个 {"code" 或 { 到最后 } 再解析。
fn json_in(text: &str) -> Value {
    let t = text.trim();
    if t.is_empty() {
        return Value::Null;
    }
    if t.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(t) {
            return v;
        }
    }
    let start = t.find("{\"code\"").or_else(|| t.find('{'));
    let end = t.rfind('}');
    match (start, end) {
        (Some(s), Some(e)) if e > s => serde_json::from_str(&t[s..=e]).unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

async fn api_raw(method: &str, params: &[(&str, &str)]) -> ApiResult<Value> {
    tokio::time::sleep(Duration::from_millis(320)).await;
    let hosts: Vec<String> = {
        let cur = site();
        let mut v: Vec<String> = HOSTS.iter().map(|s| s.to_string()).collect();
        v.sort_by_key(|h| if *h == cur { 0 } else { 1 });
        v
    };
    let mut last_err = String::new();
    for host in hosts {
        let sign_value = sign(method);
        let mut all: Vec<(&str, &str)> = params.to_vec();
        all.push(("sign", &sign_value));
        all.push(("version", "V1.1"));
        let url = with_query(&format!("{host}{P_API}{method}"), &all);
        let resp = client()?
            .get(&url)
            .header("User-Agent", UA)
            .header("Accept", "application/json, text/plain, */*")
            .header("Accept-Language", "en-US,en;q=0.9")
            .header("Origin", SHELL)
            .header("Referer", format!("{SHELL}/"))
            .send()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()));
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if resp.status().as_u16() != 200 {
            last_err = format!("妻社请求 HTTP {}", resp.status().as_u16());
            continue;
        }
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        if text.len() < 20 || !text.contains("\"code\":200") {
            last_err = "妻社响应未含 code 200".to_string();
            continue;
        }
        let value = json_in(&text);
        if value.is_null() || int_of(&value, &["code"]) != 200 {
            last_err = "妻社响应解析失败".to_string();
            continue;
        }
        set_site(&host);
        return Ok(value);
    }
    Err(ApiError::Internal(if last_err.is_empty() {
        "妻社请求失败".into()
    } else {
        last_err
    }))
}

fn is_video(url: &str) -> bool {
    let low = url.to_ascii_lowercase();
    ["m3u8", "mp4", "mov", "m4v"]
        .iter()
        .any(|e| low.contains(&format!(".{e}")))
}

fn is_image(url: &str) -> bool {
    let low = url.to_ascii_lowercase();
    [".jpg", ".jpeg", ".png", ".webp", ".gif"]
        .iter()
        .any(|e| low.contains(e))
}

/// 帖子转卡片，同时记入 MEMO（标题，播放地址，封面）。
fn card(entry: &Value) -> Option<Value> {
    let tid = text_of(entry, &["tid"]);
    if tid.is_empty() {
        return None;
    }
    let title = text_of(entry, &["subject"]);
    let title = if title.is_empty() {
        format!("帖子 {tid}")
    } else {
        title
    };
    let mut play = String::new();
    let mut cover = String::new();
    let mut n_att = 0;
    if let Some(att) = get(entry, "attachData")
        .and_then(|a| get(a, "data"))
        .and_then(arr_of)
    {
        for a in att {
            n_att += 1;
            let u = text_of(a, &["url", "attachment"]);
            if u.is_empty() {
                continue;
            }
            let u = fix_url(&u);
            if play.is_empty() && is_video(&u) {
                play = u.clone();
            } else if cover.is_empty() && (text_of(a, &["isimage"]) == "1" || is_image(&u)) {
                cover = u;
            }
        }
    }
    if cover.is_empty() {
        let msg = text_of(entry, &["message"]);
        if let Ok(re) = regex::Regex::new(r#"<img[^>]+src=["']([^"']+)["']"#) {
            if let Some(c) = re.captures(&msg) {
                cover = fix_url(&c[1]);
            }
        }
    }
    if cover.is_empty() {
        if let Some(fd) = get(entry, "forumData") {
            cover = text_of(fd, &["icon"]);
        }
    }
    if cover.is_empty() {
        cover = DEF_PIC.to_string();
    }
    let remark = if !play.is_empty() {
        "🎬 可播"
    } else if n_att > 0 {
        "图文"
    } else {
        "帖子"
    };
    if let Ok(mut guard) = MEMO.lock() {
        guard.insert(tid.clone(), (title.clone(), play.clone(), cover.clone()));
    }
    Some(item_json(&tid, &title, &cover, remark))
}

fn memo_get(tid: &str) -> Option<(String, String, String)> {
    MEMO.lock().ok().and_then(|g| g.get(tid).cloned())
}

async fn recover(tid: &str) -> Option<(String, String, String)> {
    for page in 1..=4 {
        let page_s = page.to_string();
        if let Ok(resp) = api_raw(
            "post.getIndexList",
            &[("page", &page_s), ("perpage", &PAGE_SIZE.to_string())],
        )
        .await
        {
            if let Some(list) = get(&resp, "data")
                .and_then(|d| get(d, "list"))
                .and_then(arr_of)
            {
                for e in list {
                    let _ = card(e);
                }
            }
        }
        if let Some(m) = memo_get(tid) {
            return Some(m);
        }
    }
    None
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(json!({"categories": [
        category_json("home", "🏠 首页推荐"),
        category_json("9", "淫妻分享"),
        category_json("11", "绿帽献妻"),
        category_json("5", "夫妻交换"),
        category_json("4", "夫妻认证交友"),
        category_json("6", "调教露出"),
        category_json("44", "妻社私密树洞"),
        category_json("22", "经验分享"),
        category_json("7", "素质单男"),
        category_json("25", "母狗公示榜"),
        category_json("18", "妻子原味"),
        category_json("19", "出租妻子认证"),
        category_json("53", "裸聊一对一认证"),
    ]}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page_s = page.to_string();
    let per = PAGE_SIZE.to_string();
    let resp = if category_id == "home" {
        api_raw("post.getIndexList", &[("page", &page_s), ("perpage", &per)]).await?
    } else {
        api_raw(
            "postlist.getThreadList",
            &[("fid", category_id), ("page", &page_s), ("perpage", &per)],
        )
        .await?
    };
    let rows = get(&resp, "data")
        .and_then(|d| get(d, "list"))
        .and_then(arr_of)
        .cloned()
        .unwrap_or_default();
    let items: Vec<Value> = rows.iter().filter_map(|e| card(e)).collect();
    Ok(json!({"items": items, "has_more": items.len() as i64 >= PAGE_SIZE}))
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let (title, play, cover) = match memo_get(series_id) {
        Some(m) => m,
        None => match recover(series_id).await {
            Some(m) => m,
            None => {
                return Err(ApiError::Internal("妻社未找到该帖".into()));
            }
        },
    };
    let synopsis = if play.is_empty() {
        "本帖为图文，无视频附件。".to_string()
    } else {
        "片源：列表接口直出（游客态）。".to_string()
    };
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {},
        "episodes": [episode_json(series_id, "正片", series_id)],
    }))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let (_, play, _) = match memo_get(video_id) {
        Some(m) => m,
        None => match recover(video_id).await {
            Some(m) => m,
            None => {
                return Err(ApiError::Internal("妻社未找到该帖的播放地址".into()));
            }
        },
    };
    if play.is_empty() {
        return Err(ApiError::Internal("妻社该帖无视频附件".into()));
    }
    Ok(json!({
        "url": play,
        "header": {"User-Agent": UA, "Referer": format!("{SHELL}/")},
    }))
}

pub(crate) async fn search(_query: &str) -> ApiResult<Value> {
    Ok(json!({"items": []}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_is_md5_hex() {
        let s = sign("post.getIndexList");
        assert_eq!(s.len(), 32);
        assert!(s.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(s, sign("post.getIndexList"));
        assert_ne!(s, sign("postlist.getThreadList"));
    }

    #[test]
    fn json_in_strips_prefix() {
        let v = json_in("junkprefix {\"code\":200,\"data\":{\"a\":1}} trailing");
        assert_eq!(int_of(&v, &["code"]), 200);
        let v2 = json_in("{\"code\":200}");
        assert_eq!(int_of(&v2, &["code"]), 200);
    }

    #[test]
    fn card_picks_video_and_cover() {
        let e = json!({
            "tid": "797935", "subject": "小骚妻",
            "attachData": {"data": [
                {"url": "https://x/a.jpg", "isimage": "1"},
                {"url": "https://x/b.m3u8"},
                {"url": "https://x/c.png"}
            ]},
            "message": ""
        });
        let item = card(&e).unwrap();
        assert_eq!(item["id"], "797935");
        assert_eq!(item["remark"], "🎬 可播");
        assert_eq!(item["cover"], "https://x/a.jpg");
        let m = memo_get("797935").unwrap();
        assert_eq!(m.1, "https://x/b.m3u8");
    }

    #[test]
    fn card_falls_back_to_def_pic() {
        let e = json!({"tid": "1", "subject": "无附件帖", "message": "纯文字"});
        let item = card(&e).unwrap();
        assert_eq!(item["cover"], DEF_PIC);
        assert_eq!(item["remark"], "帖子");
    }
}
