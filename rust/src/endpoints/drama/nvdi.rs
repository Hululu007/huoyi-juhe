//! 女帝：成人视频聚合/播放站，uni-app SPA + JSON 接口。
//!
//! 入口 `https://nvdi496899299599.cc/pages/home`（实际 SPA 在
//! `https://web.nvdi496899299599.cc/index`），后端 API 藏在首页 HTML 里：
//! `api_url = 'https://greplhggmqxb8hcj.nvdi81ptfe3lhved.com/api'`。
//! 该 API 子域名形如随机串，两份首页 HTML 写的是同一个，若日后轮换，
//! 以首页 `api_url` / `window.baseURL` 为准换基址即可。
//!
//! 接口（均为 GET，CodeIgniter 式 `.html` 后缀，实测于 2026-11-06）：
//! - 首页 `GET /api/home.html`：top_banner、arrival_videos（最新 8）、
//!   popular_videos（热门 12）、top_actors（明星前十）、other_videos
//!   （12 分区 × 8 条，id 即分类 id）；
//! - 配置 `GET /api/config.html`：data.category（12 分类）+ data.tags
//!   （106 个喜好标签）；
//! - 分类列表 `GET /api/category.html?cat={id}&pageNo={页}&pageSize=20`，
//!   回 total + title + data（20 条/页）；
//! - 榜单 `GET /api/movieList.html?type={1新片|2热门|4收藏}&pageNo=&pageSize=20`，
//!   type 必传，只认 type，cat/tag/actor 等参数会被忽略；
//! - 专题列表 `GET /api/topic.html?pageNo=&pageSize=20`（共 48 个），
//!   专题内视频 `GET /api/topic.html?topic_id={id}&pageNo=&pageSize=10`，
//!   回 data.{topic, list}；
//! - 明星列表 `GET /api/actor.html?pageNo=&pageSize=20`（共 296 位，
//!   每位只带 4 条预览视频），明星内视频
//!   `GET /api/actor.html?actor_id={id}&pageNo=&pageSize=20`；
//! - 详情 `GET /api/movie.html?m_id={id}`（注意参数名是 m_id，不是 id），
//!   字段全在顶层：play_list、user{is_vip}、player_ad、cover、
//!   recommend/relate、title、watched、startdate、barcode；
//! - 猜你喜欢 `GET /api/MovieRelated.html?m_id={id}&pageSize=20`；
//! - 搜索 `GET /api/search.html?keyword={词}&pageNo=&pageSize=20`；
//! - 分页参数是 pageNo（不是 page），不传 pageNo 时 data 为空。
//!
//! 取流与 VIP 墙（实测，匿名）：
//! - 详情给的 play_list 是 Wowza HLS：
//!   `https://a1.ylqvoy.cn/{时间戳}/{hash}/free/_definst_/mp4:{分区}/{barcode}_try.mp4/chunklist.m3u8?play=0&v={v}&wowzasessionid={sid}`；
//! - 清单 200，4 分片共 60.011 秒，AES-128（密钥走
//!   `oauth.fqxb.vip/GetKey/free.html`，200/16 字节），首分片 200，
//!   解密后是真 TS（0x47 同步头）；
//! - play_list 是时签地址，每次调详情都会变（时间戳+hash 都换），
//!   旧地址约 20 分钟后 403，**必须现取现用，不可缓存**；
//! - 网页播放器是前端 JS 限流：未登录 10 秒弹“请前往登录后继续试看”，
//!   登录非 VIP 25 秒弹“非VIP会员只提供试看”，VIP 才全片；
//!   限流只在 JS 里，play_list 本身是完整的 60 秒试看流，
//!   直接拿 play_list 播就能拿到 60 秒（绕过前端 10/25 秒掐断）；
//! - 全片是另一个文件（`{barcode}.mp4`，不带 `_try`），
//!   匿名拼同款地址回 403，hash 是服务端签名的（常见 MD5 拼法都对不上），
//!   **全片拿不到**，须 VIP 会话；本站是用户自己的站，
//!   这条路子按实测写进代码，用户自己看代码学漏洞、自己补。
//! 写源照站原样写，不按站名/分类名/标题删任何内容（用户 22:40 铁律）。

use serde_json::{json, Value};

use crate::error::{ApiError, ApiResult};

use super::{
    arr_of, category_json, client, episode_json, get, int_of, item_json, text_of, with_query,
};

const API: &str = "https://greplhggmqxb8hcj.nvdi81ptfe3lhved.com/api";
const UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36";
const REFERER: &str = "https://nvdi496899299599.cc/pages/home";
const PAGE_SIZE: i64 = 20;

/// 12 个内容分类（config.category 的顺序），config 取不到时回退用。
const CATEGORIES: &[(&str, &str)] = &[
    ("17", "AI定制"),
    ("16", "国产剧情"),
    ("11", "网红模特"),
    ("10", "热门事件"),
    ("3", "国产精品"),
    ("2", "无码流出"),
    ("6", "成人动漫"),
    ("4", "欧美风情"),
    ("12", "韩国精品"),
    ("5", "独家CG"),
    ("1", "日本AV"),
    ("7", "经典三级"),
];

/// 榜单：最新 / 热门 / 收藏。
const RANKS: &[(&str, &str, &str)] = &[
    ("new", "最新影片", "1"),
    ("hot", "热门影片", "2"),
    ("fav", "收藏榜", "4"),
];

async fn fetch_json(url: &str) -> ApiResult<Value> {
    let resp = client()?
        .get(url)
        .header("User-Agent", UA)
        .header("Referer", REFERER)
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("女帝请求 HTTP {status}")));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    serde_json::from_str(&text)
        .map_err(|e| ApiError::Internal(format!("女帝 JSON 解析失败: {e}")))
}

/// 带重试的接口调用：站间歇性 502/超时，最多试 3 次，每次间隔 1 秒。
/// 接口回 {"status":1} 表成功，status!=1 时按 msg 报错。
async fn api_json(path: &str) -> ApiResult<Value> {
    let url = format!("{API}{path}");
    let mut last_err = String::new();
    for _ in 0..3 {
        match fetch_json(&url).await {
            Ok(v) => {
                let st = int_of(&v, &["status"]);
                if st != 0 && st != 1 {
                    let msg = text_of(&v, &["msg", "mgs"]);
                    return Err(ApiError::Internal(format!(
                        "女帝接口返回 status={st} {}",
                        if msg.is_empty() {
                            String::new()
                        } else {
                            format!("({msg})")
                        }
                    )));
                }
                if st == 0 {
                    let msg = text_of(&v, &["msg", "mgs"]);
                    return Err(ApiError::Internal(format!(
                        "女帝接口未找到：{}",
                        if msg.is_empty() {
                            "查无资料".to_string()
                        } else {
                            msg
                        }
                    )));
                }
                return Ok(v);
            }
            Err(e) => {
                last_err = e.to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(ApiError::Internal(last_err))
}

/// 封面：列表用 thumbnail（_sp 小图），没有时退 source（原图）。
fn cover_of(row: &Value) -> String {
    let Some(cover) = get(row, "cover") else {
        return text_of(row, &["cover", "img"]);
    };
    let t = text_of(cover, &["thumbnail"]);
    if !t.is_empty() {
        return t;
    }
    text_of(cover, &["source"])
}

/// 视频卡片：id、标题、封面、备注（播放量，退上架日期）。
fn card(row: &Value) -> Value {
    let id = text_of(row, &["id"]);
    let title = text_of(row, &["title"]);
    let cover = cover_of(row);
    let mut remark = text_of(row, &["watched"]);
    if remark.is_empty() {
        remark = text_of(row, &["startdate"]);
    }
    item_json(&id, &title, &cover, &remark)
}

fn folder(id: &str, name: &str, cover: &str, remark: &str) -> Value {
    let mut item = item_json(id, name, cover, remark);
    item["is_folder"] = json!(true);
    item
}

/// 列表响应的 data 数组（topic 详情是 data.list，普通列表是 data 本身）。
fn data_rows(body: &Value) -> Vec<Value> {
    if let Some(data) = get(body, "data") {
        if let Some(arr) = arr_of(data) {
            return arr.clone();
        }
        if let Some(list) = get(data, "list").and_then(arr_of) {
            return list.clone();
        }
        if let Some(videos) = get(data, "videos").and_then(arr_of) {
            return videos.clone();
        }
    }
    Vec::new()
}

fn list_total(body: &Value) -> i64 {
    int_of(body, &["total"])
}

fn has_more(body: &Value, page: i64, items: &[Value]) -> bool {
    let total = list_total(body);
    if total > 0 {
        page * PAGE_SIZE < total
    } else {
        items.len() as i64 >= PAGE_SIZE
    }
}

async fn config() -> ApiResult<Value> {
    api_json("/config.html").await
}

/// config.data.category：[{id, title}]，取不到时回退内置 12 分类。
fn config_categories(body: &Value) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    if let Some(data) = get(body, "data") {
        if let Some(arr) = get(data, "category").and_then(arr_of) {
            for row in arr {
                let id = text_of(row, &["id"]);
                let name = text_of(row, &["title"]);
                if !id.is_empty() && !name.is_empty() {
                    out.push((id, name));
                }
            }
        }
    }
    if out.is_empty() {
        out = CATEGORIES
            .iter()
            .map(|(id, name)| (id.to_string(), name.to_string()))
            .collect();
    }
    out
}

/// config.data.tags：[{id, title}]，106 个喜好标签。
fn config_tags(body: &Value) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    if let Some(data) = get(body, "data") {
        if let Some(arr) = get(data, "tags").and_then(arr_of) {
            for row in arr {
                let id = text_of(row, &["id"]);
                let name = text_of(row, &["title"]);
                if !id.is_empty() && !name.is_empty() {
                    out.push((id, name));
                }
            }
        }
    }
    out
}

fn tag_title_by_id(body: &Value, id: &str) -> String {
    config_tags(body)
        .into_iter()
        .find(|(tid, _)| tid == id)
        .map(|(_, name)| name)
        .unwrap_or_default()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    let mut list: Vec<Value> = RANKS
        .iter()
        .map(|(id, name, _)| category_json(id, name))
        .collect();
    let cats = match config().await {
        Ok(body) => config_categories(&body),
        Err(_) => CATEGORIES
            .iter()
            .map(|(id, name)| (id.to_string(), name.to_string()))
            .collect(),
    };
    for (id, name) in cats {
        list.push(category_json(&format!("c{id}"), &name));
    }
    list.push(category_json("topics", "专题"));
    list.push(category_json("actors", "明星"));
    list.push(category_json("tags", "喜好标签"));
    Ok(json!({"categories": list}))
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let page = page.max(1);
    let page_s = page.to_string();
    // 榜单：movieList?type={1,2,4}。
    if let Some((_, _, ty)) = RANKS.iter().find(|(id, _, _)| *id == category_id) {
        let body = api_json(&with_query(
            "/movieList.html",
            &[
                ("type", ty),
                ("pageNo", &page_s),
                ("pageSize", &PAGE_SIZE.to_string()),
            ],
        ))
        .await?;
        let items: Vec<Value> = data_rows(&body).iter().map(card).collect();
        let more = has_more(&body, page, &items);
        return Ok(json!({"items": items, "has_more": more}));
    }
    // 内容分类：category.html?cat={id}。
    if let Some(id) = category_id.strip_prefix('c') {
        if !id.is_empty() && id.chars().all(|c| c.is_ascii_digit()) {
            let body = api_json(&with_query(
                "/category.html",
                &[
                    ("cat", id),
                    ("pageNo", &page_s),
                    ("pageSize", &PAGE_SIZE.to_string()),
                ],
            ))
            .await?;
            let items: Vec<Value> = data_rows(&body).iter().map(card).collect();
            let more = has_more(&body, page, &items);
            return Ok(json!({"items": items, "has_more": more}));
        }
    }
    // 专题列表：每条是一个文件夹。
    if category_id == "topics" {
        let body = api_json(&with_query(
            "/topic.html",
            &[("pageNo", &page_s), ("pageSize", &PAGE_SIZE.to_string())],
        ))
        .await?;
        let mut items = Vec::new();
        for row in data_rows(&body) {
            let id = text_of(&row, &["id"]);
            let title = text_of(&row, &["title"]);
            let img = text_of(&row, &["img"]);
            let intro = text_of(&row, &["intro"]);
            if id.is_empty() || title.is_empty() {
                continue;
            }
            items.push(folder(&format!("topic:{id}"), &title, &img, &intro));
        }
        let more = has_more(&body, page, &items);
        return Ok(json!({"items": items, "has_more": more}));
    }
    // 专题内视频：topic.html?topic_id={id}，回 data.{topic, list}。
    if let Some(id) = category_id.strip_prefix("topic:") {
        let body = api_json(&with_query(
            "/topic.html",
            &[
                ("topic_id", id),
                ("pageNo", &page_s),
                ("pageSize", "10"),
            ],
        ))
        .await?;
        let items: Vec<Value> = data_rows(&body).iter().map(card).collect();
        let more = has_more(&body, page, &items);
        return Ok(json!({"items": items, "has_more": more}));
    }
    // 明星列表：每位是一个文件夹。
    if category_id == "actors" {
        let body = api_json(&with_query(
            "/actor.html",
            &[("pageNo", &page_s), ("pageSize", &PAGE_SIZE.to_string())],
        ))
        .await?;
        let mut items = Vec::new();
        for row in data_rows(&body) {
            let id = text_of(&row, &["id"]);
            let title = text_of(&row, &["title"]);
            let cover = text_of(&row, &["cover"]);
            let total = text_of(&row, &["list_total"]);
            if id.is_empty() || title.is_empty() {
                continue;
            }
            let remark = if total.is_empty() {
                String::new()
            } else {
                format!("{total} 部")
            };
            items.push(folder(&format!("actor:{id}"), &title, &cover, &remark));
        }
        let more = has_more(&body, page, &items);
        return Ok(json!({"items": items, "has_more": more}));
    }
    // 明星内视频：actor.html?actor_id={id}。
    if let Some(id) = category_id.strip_prefix("actor:") {
        let body = api_json(&with_query(
            "/actor.html",
            &[
                ("actor_id", id),
                ("pageNo", &page_s),
                ("pageSize", &PAGE_SIZE.to_string()),
            ],
        ))
        .await?;
        let items: Vec<Value> = data_rows(&body).iter().map(card).collect();
        let more = has_more(&body, page, &items);
        return Ok(json!({"items": items, "has_more": more}));
    }
    // 喜好标签列表：config.tags，每条是一个文件夹。
    if category_id == "tags" {
        let body = config().await?;
        let mut items = Vec::new();
        for (id, name) in config_tags(&body) {
            items.push(folder(&format!("tag:{id}"), &name, "", ""));
        }
        return Ok(json!({"items": items, "has_more": false}));
    }
    // 标签内视频：按标签名搜（站内标签没有单独的过滤接口，搜索即标签）。
    if let Some(id) = category_id.strip_prefix("tag:") {
        let body = config().await?;
        let title = tag_title_by_id(&body, id);
        if title.is_empty() {
            return Err(ApiError::BadRequest(format!("女帝未知标签 {id}")));
        }
        let enc = url::form_urlencoded::byte_serialize(title.as_bytes()).collect::<String>();
        let sbody = api_json(&format!(
            "/search.html?keyword={enc}&pageNo={page}&pageSize={PAGE_SIZE}"
        ))
        .await?;
        let items: Vec<Value> = data_rows(&sbody).iter().map(card).collect();
        let more = has_more(&sbody, page, &items);
        return Ok(json!({"items": items, "has_more": more}));
    }
    Err(ApiError::BadRequest(format!(
        "女帝未知分类 {category_id}"
    )))
}

fn names_of(rows: Option<&Vec<Value>>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(arr) = rows {
        for r in arr {
            let n = text_of(r, &["title"]);
            if !n.is_empty() {
                out.push(n);
            }
        }
    }
    out
}

pub(crate) async fn detail(series_id: &str) -> ApiResult<Value> {
    let body = api_json(&format!("/movie.html?m_id={series_id}")).await?;
    let title = text_of(&body, &["title"]);
    if title.is_empty() {
        return Err(ApiError::Internal("女帝详情无标题".into()));
    }
    let cover = cover_of(&body);
    let watched = text_of(&body, &["watched"]);
    let startdate = text_of(&body, &["startdate"]);
    let barcode = text_of(&body, &["barcode"]);
    let play_list = text_of(&body, &["play_list"]);
    if play_list.is_empty() {
        return Err(ApiError::Internal("女帝详情未返回播放地址".into()));
    }
    let is_vip = get(&body, "user")
        .map(|u| int_of(u, &["is_vip"]) == 1)
        .unwrap_or(false);
    let actors = names_of(get(&body, "actor").and_then(arr_of));
    let tags = names_of(get(&body, "tag").and_then(arr_of));
    let mut synopsis = String::new();
    if !watched.is_empty() {
        synopsis.push_str(&format!("播放 {watched}"));
    }
    if !startdate.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push_str(" · ");
        }
        synopsis.push_str(&format!("上架 {startdate}"));
    }
    if !barcode.is_empty() {
        if !synopsis.is_empty() {
            synopsis.push_str(" · ");
        }
        synopsis.push_str(&format!("编码 {barcode}"));
    }
    if !actors.is_empty() {
        synopsis.push_str(&format!("\n演员：{}", actors.join(" / ")));
    }
    if !tags.is_empty() {
        synopsis.push_str(&format!("\n标签：{}", tags.join(" / ")));
    }
    if is_vip {
        synopsis.push_str("\n已开通 VIP，全片可播");
    } else {
        synopsis.push_str("\n匿名试看 60 秒（网页端只放 10 秒，登录非 VIP 25 秒）；全片须 VIP");
    }
    let mut related: Vec<String> = Vec::new();
    if let Some(arr) = get(&body, "recommend").and_then(arr_of) {
        for r in arr.iter().take(5) {
            let t = text_of(r, &["title"]);
            if !t.is_empty() {
                related.push(t);
            }
        }
    }
    if !related.is_empty() {
        synopsis.push_str(&format!("\n猜你喜欢：{}", related.join(" / ")));
    }
    Ok(json!({
        "id": series_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": {"remark": watched, "actor": actors.join(" / "), "barcode": barcode},
        "episodes": [episode_json(&format!("{series_id}@0"), "在线播放", series_id)],
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(json!({"items": []}));
    }
    let enc = url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>();
    let body = api_json(&format!(
        "/search.html?keyword={enc}&pageNo=1&pageSize={PAGE_SIZE}"
    ))
    .await?;
    let items: Vec<Value> = data_rows(&body).iter().map(card).collect();
    Ok(json!({"items": items}))
}

pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let mid = video_id.split('@').next().unwrap_or(video_id);
    if mid.is_empty() || !mid.chars().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::BadRequest(format!("女帝未知视频 {video_id}")));
    }
    // play_list 是时签地址，每次现取详情，不可缓存。
    let body = api_json(&format!("/movie.html?m_id={mid}")).await?;
    let url = text_of(&body, &["play_list"]);
    if url.is_empty() {
        return Err(ApiError::Internal("女帝详情未返回播放地址".into()));
    }
    Ok(json!({"url": url}))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD_JSON: &str = r#"{"id":"18318","title":"秀人网 李丽莎 白茹雪 两女神合体 最新女同演绎 健身姐妹的淫荡日常","encoding":"N","barcode":"gcjp25050404","startdate":"2025-05-04","type":"video","url":null,"watched":"10.09万次播放","categories":[{"title":"国产精品"}],"actor":[{"title":"国产精品"}],"cover":{"thumbnail":"https://38.33.15.127:108/app_images/ch_image/gcjp25050404_sp.jpg","source":"https://38.33.15.127:108/app_images/ch_image/gcjp25050404.jpg"}}"#;

    const DETAIL_JSON: &str = r#"{"status":1,"mgs":"","favorite":0,"actor":[],"tag":[],"banner":[],"cover":{"thumbnail":"https://38.33.15.127:108/app_images/ch_image/gcjp25050404_sp.jpg","source":"https://38.33.15.127:108/app_images/ch_image/gcjp25050404.jpg"},"recommend":[{"id":"15735","title":"越南大奶性感模特","type":"video","url":null,"watched":"10.05万次播放","cover":{"thumbnail":"https://38.33.15.127:108/app_images/ch_image/zbzp2312246_sp.jpg","source":"https://38.33.15.127:108/app_images/ch_image/zbzp2312246.jpg"},"subtitle":""}],"relate":[],"player_ad":{"title":"播放器-650-366-1","click_url":"","img":"https://38.33.15.127:108/hb/nvdi/650u366u1.png","target":1,"duration":"3"},"play_list":"https://a1.ylqvoy.cn/202611060038/82c9f39cbc4f99f0e7ad49617671d83b/free/_definst_/mp4:ch/gcjp25050404_try.mp4/chunklist.m3u8?play=0&v=cf8edc6228d6e21b2eab7773a29de1fe&wowzasessionid=29319","id":18318,"barcode":"gcjp25050404","title":"秀人网 李丽莎 白茹雪 两女神合体 最新女同演绎 健身姐妹的淫荡日常","startdate":"2025-05-04","watched":"10.09万","user":{"is_vip":0,"user_id":null,"vip_expire_time":""}}"#;

    const CONFIG_JSON: &str = r#"{"status":1,"msg":"成功","data":{"category":[{"id":"17","title":"AI定制"},{"id":"1","title":"日本AV"}],"tags":[{"id":"1","title":"探花"},{"id":"2","title":"偷拍"}]}}"#;

    const TOPIC_LIST_JSON: &str = r#"{"status":1,"msg":"成功","total":48,"data":[{"id":"66","title":"全网爆火！重金定制AI短剧！","intro":"全网爆火！重金定制AI成人短剧！","code":"ZT-52","img":"https://38.33.15.127:108/zt/ZT-52.jpg","type":"topic"}],"ad":[]}"#;

    const TOPIC_DETAIL_JSON: &str = r#"{"status":1,"msg":"成功","total":20,"data":{"topic":{"code":"ZT-52","title":"全网爆火！重金定制AI短剧！","start_m":"2026-10-20","intro":"全网爆火！重金定制AI成人短剧！","img":"https://38.33.15.127:108/zt/ZT-52.jpg"},"list":[{"id":"20125","title":"末日寒潮我在庇护所美女环绕","type":"video","url":null,"watched":"10.01万次播放","cover":{"thumbnail":"https://38.33.15.127:108/app_images/ch_image/x_sp.jpg","source":"https://38.33.15.127:108/app_images/ch_image/x.jpg"}}]},"ad":[]}"#;

    const ACTOR_DETAIL_JSON: &str = r#"{"status":1,"msg":"成功","total":12,"data":{"id":"1","pinyin":"ATX","title":"奥田咲","birthday":"1992-06-15","height":"148","measurement":"B81 W55 H79","cup":"C","intro":"奥田咲，是日本演员，长得非常可爱。","cover":{"thumbnail":"https://38.33.15.127:108/ny/1_sp.jpg","source":"https://38.33.15.127:108/ny/1.jpg"},"videos":[{"id":"11839","title":"与H罩杯大姊爱爱时J罩杯大姊乱入W爆乳比较梦般逆3P 鹫尾芽衣 奥田咲","type":"video","url":null,"watched":"10.04万次播放","cover":{"thumbnail":"https://38.33.15.127:108/app_images/ch_image/90801_sp.jpg","source":"https://38.33.15.127:108/app_images/ch_image/90801.jpg"}}]}}"#;

    #[test]
    fn actor_detail_rows_from_videos() {
        let body: Value = serde_json::from_str(ACTOR_DETAIL_JSON).unwrap();
        let rows = data_rows(&body);
        assert_eq!(rows.len(), 1);
        let item = card(&rows[0]);
        assert_eq!(item["id"], "11839");
        assert_eq!(list_total(&body), 12);
        let data = get(&body, "data").unwrap();
        assert_eq!(text_of(data, &["title"]), "奥田咲");
        assert_eq!(
            cover_of(data),
            "https://38.33.15.127:108/ny/1_sp.jpg"
        );
    }

    #[test]
    fn card_real_sample() {
        let row: Value = serde_json::from_str(CARD_JSON).unwrap();
        let item = card(&row);
        assert_eq!(item["id"], "18318");
        assert_eq!(
            item["title"],
            "秀人网 李丽莎 白茹雪 两女神合体 最新女同演绎 健身姐妹的淫荡日常"
        );
        assert_eq!(
            item["cover"],
            "https://38.33.15.127:108/app_images/ch_image/gcjp25050404_sp.jpg"
        );
        assert_eq!(item["remark"], "10.09万次播放");
    }

    #[test]
    fn detail_real_sample() {
        let body: Value = serde_json::from_str(DETAIL_JSON).unwrap();
        let title = text_of(&body, &["title"]);
        assert!(title.contains("李丽莎"));
        let play_list = text_of(&body, &["play_list"]);
        assert!(play_list.contains("_try.mp4/chunklist.m3u8"));
        assert!(play_list.contains("play=0"));
        assert!(play_list.contains("a1.ylqvoy.cn"));
        assert_eq!(cover_of(&body), "https://38.33.15.127:108/app_images/ch_image/gcjp25050404_sp.jpg");
        let is_vip = get(&body, "user")
            .and_then(|u| get(u, "is_vip"))
            .map(|v| v.as_i64().unwrap_or(0) == 1)
            .unwrap_or(false);
        assert!(!is_vip);
    }

    #[test]
    fn config_categories_and_tags() {
        let body: Value = serde_json::from_str(CONFIG_JSON).unwrap();
        let cats = config_categories(&body);
        assert_eq!(cats.len(), 2);
        assert_eq!(cats[0], ("17".to_string(), "AI定制".to_string()));
        assert_eq!(cats[1], ("1".to_string(), "日本AV".to_string()));
        let tags = config_tags(&body);
        assert_eq!(tags.len(), 2);
        assert_eq!(tag_title_by_id(&body, "1"), "探花");
        assert_eq!(tag_title_by_id(&body, "99"), "");
    }

    #[test]
    fn fallback_categories_cover_12() {
        assert_eq!(CATEGORIES.len(), 12);
        assert_eq!(CATEGORIES[0], ("17", "AI定制"));
        assert_eq!(CATEGORIES[10], ("1", "日本AV"));
        assert_eq!(CATEGORIES[11], ("7", "经典三级"));
    }

    #[test]
    fn rank_types_cover_3() {
        assert_eq!(RANKS.len(), 3);
        assert_eq!(RANKS[0], ("new", "最新影片", "1"));
        assert_eq!(RANKS[1], ("hot", "热门影片", "2"));
        assert_eq!(RANKS[2], ("fav", "收藏榜", "4"));
    }

    #[test]
    fn topic_list_rows_are_folders() {
        let body: Value = serde_json::from_str(TOPIC_LIST_JSON).unwrap();
        let rows = data_rows(&body);
        assert_eq!(rows.len(), 1);
        let f = folder(
            "topic:66",
            &text_of(&rows[0], &["title"]),
            &text_of(&rows[0], &["img"]),
            &text_of(&rows[0], &["intro"]),
        );
        assert_eq!(f["id"], "topic:66");
        assert_eq!(f["is_folder"], true);
        assert_eq!(list_total(&body), 48);
    }

    #[test]
    fn topic_detail_rows_are_videos() {
        let body: Value = serde_json::from_str(TOPIC_DETAIL_JSON).unwrap();
        let rows = data_rows(&body);
        assert_eq!(rows.len(), 1);
        let item = card(&rows[0]);
        assert_eq!(item["id"], "20125");
        assert_eq!(list_total(&body), 20);
    }

    #[test]
    fn has_more_from_total() {
        let body: Value = serde_json::from_str(r#"{"status":1,"total":3948,"data":[]}"#).unwrap();
        assert!(has_more(&body, 1, &[]));
        assert!(!has_more(&body, 200, &[]));
    }

    #[test]
    fn play_rejects_non_numeric_id() {
        // play() 是 async，这里只验 id 切分逻辑：video_id 含 @ 时取 @ 前一段。
        let vid = "18318@0";
        let mid = vid.split('@').next().unwrap_or(vid);
        assert_eq!(mid, "18318");
        assert!(mid.chars().all(|c| c.is_ascii_digit()));
        assert!(!"topic:66".chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn folder_marks_is_folder() {
        let f = folder("actor:15", "波多野结衣", "", "70 部");
        assert_eq!(f["is_folder"], true);
        assert_eq!(f["remark"], "70 部");
    }
}
