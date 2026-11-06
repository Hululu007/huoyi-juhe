//! 香蕉视频：`https://lw7k481j3l003h95pnwf.xjspapps.com`（默认基址，可发现）。
//!
//! 来源 jar 类 `ZakaXjAmns`。默认基址
//! `https://lw7k481j3l003h95pnwf.xjspapps.com`；
//! `DISCOVER_DOMAINS = {ios.bxguwen.com, 025vslo7kf.com, 5usaoh4t88.com,
//! xzjgz.com, hm789.top}`；`ensureBase`：先用默认基址，逐个试
//! `https://<域名>/getGlobalData`（含 `ios` 的域名直拼，其余拼 12 位随机
//! 小写字母数字子域名），`retcode == 0` 即锁定，15 秒超时；响应 gzip
//! 时 gunzip。UA 为 Chrome 126 Android Pixel 7。
//!
//! 分类写死 17 类：`home:latestrows` 首页·最新视频、
//! `home:likerows` 首页·猜你喜欢、`home:a_vodrows` 首页·偷拍自拍、
//! `home:b_vodrows` 首页·成人动漫、`home:c_vodrows` 首页·经典伦理、
//! `home:d_vodrows` 首页·中文字幕、`home:tagvodrows` 首页·不雅视频、
//! `home:hotrows` 首页·热片视频、`vod:recommend` 榜单·推荐、
//! `vod:hot` 榜单·热点、`vod:latest` 榜单·最新、`specials` 专题、
//! `mini:topzan` 短视频·点赞榜、`mini:topcomment` 短视频·评论榜、
//! `mini:topplay` 短视频·播放榜、`mini:topnew` 短视频·最新榜、
//! `mini:topcoin` 短视频·投币榜。
//! 列表：`home:` 类只第 1 页有内容，调 `/index` 取
//! `data.<去掉 home: 后的键>`；`vod:<名>` 调
//! `/vod/<名>-0-0-0-0-0-0-0-0-0-<页>` 取 `data.vodrows`；`mini:<名>`
//! 调 `/minivod/<名>-0-0-0-0-0-0-0-0-0-0-<页>`；`specials` 只第 1 页，
//! 调 `/special/listing-0-0-1` 取 `data.rows[]`（`vod_id=dir:special:<spid>`，
//! 备注 `itemcount`）；其余调
//! `/vod/recommend-0-0-0-0-0-0-0-0-0-<页>`；`dir:actor:<名>` 转搜索。
//! 卡片：`vodid`/`title` 必有；付费判定 `isvip == "1"`，先排除、全空
//! 时才放回；备注为付费或 `catename`（空则 `definition`）；封面
//! `coverpic`；内容 `intro`；写入进程缓存。
//! 详情：`dir:special:<id>` 调 `/special/detail/<id>` 取
//! `data.row.spname/coverpic/intro` 与 `data.vodrows[]`，分集为
//! `片名$<vod_id>` 串；普通视频先查缓存，查不到则在
//! `/vod/recommend|hot|latest`（各第 1 页）里按 `vodid` 找；付费时
//! `vod_play_url` 为空，否则 `正片$<id>`；演员取 `actor_tags`。
//! 搜索：GET `/search?page=<页>&wd=<编码词>`，取 `data.vodrows`，空则
//! 取 `data.hotrows`。
//! 取流：GET `/vod/reqplay/<id>`，带头 `X-Forwarded-For: <随机 IP>`
//! （每段 1–254/0–255/0–255/0–255），`retcode != 6` 时取
//! `data.httpurl`；头为 UA + Referer `<base>/`。

use std::sync::Mutex;

use once_cell::sync::Lazy;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{arr_of, category_json, client, episode_json, get, item_json, text_of};

const DEFAULT_BASE: &str = "https://lw7k481j3l003h95pnwf.xjspapps.com";
const DISCOVER_DOMAINS: &[&str] = &[
    "ios.bxguwen.com",
    "025vslo7kf.com",
    "5usaoh4t88.com",
    "xzjgz.com",
    "hm789.top",
];
const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";

const CATS: &[(&str, &str)] = &[
    ("home:latestrows", "首页·最新视频"),
    ("home:likerows", "首页·猜你喜欢"),
    ("home:a_vodrows", "首页·偷拍自拍"),
    ("home:b_vodrows", "首页·成人动漫"),
    ("home:c_vodrows", "首页·经典伦理"),
    ("home:d_vodrows", "首页·中文字幕"),
    ("home:tagvodrows", "首页·不雅视频"),
    ("home:hotrows", "首页·热片视频"),
    ("vod:recommend", "榜单·推荐"),
    ("vod:hot", "榜单·热点"),
    ("vod:latest", "榜单·最新"),
    ("specials", "专题"),
    ("mini:topzan", "短视频·点赞榜"),
    ("mini:topcomment", "短视频·评论榜"),
    ("mini:topplay", "短视频·播放榜"),
    ("mini:topnew", "短视频·最新榜"),
    ("mini:topcoin", "短视频·投币榜"),
];

struct BaseState {
    base: Option<String>,
    ready: bool,
}

static BASE_STATE: Lazy<Mutex<BaseState>> = Lazy::new(|| {
    Mutex::new(BaseState {
        base: None,
        ready: false,
    })
});
static CACHE: Lazy<Mutex<std::collections::HashMap<String, Value>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

fn rand_sub() -> String {
    const CH: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    use rand::Rng;
    (0..12)
        .map(|_| CH[rng.gen_range(0..CH.len())] as char)
        .collect()
}

fn rand_ip() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    format!(
        "{}.{}.{}.{}",
        rng.gen_range(1..=254),
        rng.gen_range(0..=255),
        rng.gen_range(0..=255),
        rng.gen_range(0..=255)
    )
}

async fn http_get_json(url: &str, headers: &[(&str, String)]) -> ApiResult<Value> {
    let mut req = client()?.get(url).header("User-Agent", UA);
    for (k, v) in headers {
        req = req.header(*k, v.clone());
    }
    let resp = req
        .send()
        .await
        .map_err(|e| ApiError::Internal(format!("xj http: {e}")))?;
    if !resp.status().is_success() {
        return Err(ApiError::Internal(format!("xj http {}", resp.status())));
    }
    let encoding = resp
        .headers()
        .get("content-encoding")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| ApiError::Internal(format!("xj body: {e}")))?;
    let bytes = if encoding.to_lowercase().contains("gzip") {
        crate::crypto::gunzip(&bytes).unwrap_or_else(|| bytes.to_vec())
    } else {
        bytes.to_vec()
    };
    serde_json::from_slice(&bytes).map_err(|e| ApiError::Internal(format!("xj json: {e}")))
}

async fn ensure_base() -> String {
    {
        let st = BASE_STATE.lock().unwrap();
        if st.ready {
            if let Some(b) = st.base.clone() {
                return b;
            }
        }
    }
    {
        let mut st = BASE_STATE.lock().unwrap();
        st.ready = true;
        st.base = Some(DEFAULT_BASE.to_string());
    }
    for domain in DISCOVER_DOMAINS {
        let cand = if domain.contains("ios") {
            format!("https://{domain}")
        } else {
            format!("https://{}.{domain}", rand_sub())
        };
        if let Ok(v) = http_get_json(&format!("{cand}/getGlobalData"), &[]).await {
            if get(&v, "retcode").and_then(|x| x.as_i64()) == Some(0) {
                BASE_STATE.lock().unwrap().base = Some(cand.clone());
                return cand;
            }
        }
    }
    DEFAULT_BASE.to_string()
}

async fn call(path: &str, headers: &[(&str, String)]) -> ApiResult<Value> {
    let base = ensure_base().await;
    http_get_json(&format!("{base}{path}"), headers).await
}

fn is_paid(v: &Value) -> bool {
    text_of(v, &["isvip"]) == "1"
}

fn card(v: &Value, include_paid: bool) -> Option<Value> {
    let id = text_of(v, &["vodid"]);
    let title = text_of(v, &["title"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let paid = is_paid(v);
    if paid && !include_paid {
        return None;
    }
    let mut remark = if paid {
        "付费".to_string()
    } else {
        text_of(v, &["catename"])
    };
    if remark.is_empty() && !paid {
        remark = text_of(v, &["definition"]);
    }
    CACHE.lock().unwrap().insert(id.clone(), v.clone());
    let mut it = item_json(&id, &title, &text_of(v, &["coverpic"]), &remark);
    it["content"] = json!(text_of(v, &["intro"]));
    it["type_name"] = json!(text_of(v, &["catename"]));
    Some(it)
}

fn cards(arr: Option<&Vec<Value>>) -> Vec<Value> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut list: Vec<Value> = Vec::new();
    if let Some(arr) = arr {
        list = arr.clone();
    }
    for v in &list {
        if let Some(c) = card(v, false) {
            let id = c["id"].as_str().unwrap_or("").to_string();
            if seen.insert(id) {
                out.push(c);
            }
        }
    }
    if out.is_empty() {
        for v in &list {
            if let Some(c) = card(v, true) {
                let id = c["id"].as_str().unwrap_or("").to_string();
                if seen.insert(id) {
                    out.push(c);
                }
            }
        }
    }
    out
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = if page < 1 { 1 } else { page };
    let items: Vec<Value> = if let Some(key) = category_id.strip_prefix("home:") {
        if page > 1 {
            Vec::new()
        } else {
            match call("/index", &[]).await {
                Ok(resp) => {
                    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                    cards(arr_of(get(&data, key).unwrap_or(&Value::Null)))
                }
                Err(_) => Vec::new(),
            }
        }
    } else if let Some(name) = category_id.strip_prefix("vod:") {
        match call(&format!("/vod/{name}-0-0-0-0-0-0-0-0-0-{page}"), &[]).await {
            Ok(resp) => {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                cards(arr_of(get(&data, "vodrows").unwrap_or(&Value::Null)))
            }
            Err(_) => Vec::new(),
        }
    } else if category_id == "specials" {
        if page > 1 {
            Vec::new()
        } else {
            match call("/special/listing-0-0-1", &[]).await {
                Ok(resp) => {
                    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                    let mut out = Vec::new();
                    if let Some(rows) = arr_of(get(&data, "rows").unwrap_or(&Value::Null)) {
                        for r in rows {
                            let spid = text_of(r, &["spid"]);
                            let name = text_of(r, &["spname"]);
                            if spid.is_empty() || name.is_empty() {
                                continue;
                            }
                            let mut it = item_json(
                                &format!("dir:special:{spid}"),
                                &name,
                                &text_of(r, &["coverpic"]),
                                &text_of(r, &["itemcount"]),
                            );
                            it["tag"] = json!("folder");
                            it["type_name"] = json!("专题");
                            out.push(it);
                        }
                    }
                    out
                }
                Err(_) => Vec::new(),
            }
        }
    } else if let Some(name) = category_id.strip_prefix("mini:") {
        match call(&format!("/minivod/{name}-0-0-0-0-0-0-0-0-0-0-{page}"), &[]).await {
            Ok(resp) => {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                cards(arr_of(get(&data, "vodrows").unwrap_or(&Value::Null)))
            }
            Err(_) => Vec::new(),
        }
    } else if let Some(name) = category_id.strip_prefix("dir:actor:") {
        return search_inner(name, 1).await;
    } else {
        match call(&format!("/vod/recommend-0-0-0-0-0-0-0-0-0-{page}"), &[]).await {
            Ok(resp) => {
                let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
                cards(arr_of(get(&data, "vodrows").unwrap_or(&Value::Null)))
            }
            Err(_) => Vec::new(),
        }
    };
    let has_more = !items.is_empty();
    Ok(json!({"items": items, "has_more": has_more}))
}

async fn find_video(id: &str) -> Option<Value> {
    for path in [
        "/vod/recommend-0-0-0-0-0-0-0-0-0-1",
        "/vod/hot-0-0-0-0-0-0-0-0-0-1",
        "/vod/latest-0-0-0-0-0-0-0-0-0-1",
    ] {
        if let Ok(resp) = call(path, &[]).await {
            let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
            if let Some(arr) = arr_of(get(&data, "vodrows").unwrap_or(&Value::Null)) {
                for v in arr {
                    if text_of(v, &["vodid"]) == id {
                        return Some(v.clone());
                    }
                }
            }
        }
    }
    None
}

pub(crate) async fn detail(id: &str) -> ApiResult<Value> {
    if let Some(spid) = id.strip_prefix("dir:special:") {
        let resp = match call(&format!("/special/detail/{spid}"), &[]).await {
            Ok(r) => r,
            Err(_) => {
                return Ok(
                    json!({"id": id, "title": "", "cover": "", "synopsis": "", "extra": {}, "episodes": []}),
                );
            }
        };
        let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
        let row = get(&data, "row").cloned().unwrap_or(Value::Null);
        let mut title = text_of(&row, &["spname"]);
        if title.is_empty() {
            title = spid.to_string();
        }
        let items = cards(arr_of(get(&data, "vodrows").unwrap_or(&Value::Null)));
        let mut episodes: Vec<Value> = Vec::new();
        for c in &items {
            let vid = c["id"].as_str().unwrap_or("").to_string();
            let t = c["title"].as_str().unwrap_or("").to_string();
            episodes.push(episode_json(&vid, &t, id));
        }
        return Ok(json!({
            "id": id, "title": title,
            "cover": text_of(&row, &["coverpic"]),
            "synopsis": text_of(&row, &["intro"]),
            "extra": {"type_name": "专题"},
            "episodes": episodes,
        }));
    }
    let found = CACHE.lock().unwrap().get(id).cloned();
    let found = match found {
        Some(v) => Some(v),
        None => find_video(id).await,
    };
    let title = found
        .as_ref()
        .map(|v| text_of(v, &["title"]))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("视频{id}"));
    let cover = found
        .as_ref()
        .map(|v| text_of(v, &["coverpic"]))
        .unwrap_or_default();
    let remark = found
        .as_ref()
        .map(|v| text_of(v, &["catename"]))
        .unwrap_or_default();
    let content = found
        .as_ref()
        .map(|v| text_of(v, &["intro"]))
        .unwrap_or_default();
    let actor = found
        .as_ref()
        .map(|v| text_of(v, &["actor_tags"]))
        .unwrap_or_default();
    let paid = found.as_ref().map(|v| is_paid(v)).unwrap_or(false);
    let mut episodes: Vec<Value> = Vec::new();
    if !paid {
        episodes.push(episode_json(id, "正片", id));
    }
    Ok(json!({
        "id": id, "title": title, "cover": cover, "synopsis": content,
        "extra": {"vod_actor": actor, "vod_remarks": if paid { "付费" } else { remark.as_str() }},
        "episodes": episodes,
    }))
}

async fn search_inner(query: &str, page: i64) -> ApiResult<Value> {
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    let resp = match call(&format!("/search?page={page}&wd={enc}"), &[]).await {
        Ok(r) => r,
        Err(_) => return Ok(json!({"items": [], "has_more": false})),
    };
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let mut arr = arr_of(get(&data, "vodrows").unwrap_or(&Value::Null)).cloned();
    if arr.as_ref().map(|a| a.is_empty()).unwrap_or(true) {
        arr = arr_of(get(&data, "hotrows").unwrap_or(&Value::Null)).cloned();
    }
    let items = cards(arr.as_ref());
    Ok(json!({"items": items, "has_more": !items.is_empty()}))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    search_inner(query, 1).await
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    if video_id.starts_with("http") {
        let base = ensure_base().await;
        return Ok(json!({
            "url": video_id,
            "header": {"User-Agent": UA, "Referer": format!("{base}/")},
        }));
    }
    let id = match video_id.find('$') {
        Some(pos) => &video_id[pos + 1..],
        None => video_id,
    };
    let base = ensure_base().await;
    let resp = call(
        &format!("/vod/reqplay/{id}"),
        &[("X-Forwarded-For", rand_ip())],
    )
    .await?;
    if get(&resp, "retcode").and_then(|x| x.as_i64()) == Some(6) {
        return Err(ApiError::Internal("xj reqplay retcode 6".into()));
    }
    let data = get(&resp, "data").cloned().unwrap_or(Value::Null);
    let url = text_of(&data, &["httpurl"]);
    if url.is_empty() {
        return Err(ApiError::Internal("xj no httpurl".into()));
    }
    Ok(json!({
        "url": url,
        "header": {"User-Agent": UA, "Referer": format!("{base}/")},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cats_seventeen() {
        assert_eq!(CATS.len(), 17);
    }

    #[test]
    fn rand_ip_shape() {
        let ip = rand_ip();
        let parts: Vec<&str> = ip.split('.').collect();
        assert_eq!(parts.len(), 4);
        assert!(parts[0].parse::<u8>().unwrap() >= 1);
    }

    #[test]
    fn rand_sub_len() {
        assert_eq!(rand_sub().len(), 12);
    }

    #[test]
    fn card_paid_fallback() {
        let v: Value = serde_json::from_str(
            r#"{"vodid":"1","title":"t","coverpic":"c","isvip":"1","catename":"伦理"}"#,
        )
        .unwrap();
        assert!(card(&v, false).is_none());
        let c = card(&v, true).unwrap();
        assert_eq!(c["remark"], "付费");
    }
}
