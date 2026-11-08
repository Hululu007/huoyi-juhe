//! 书音FM（www.shuyinfm.com，帝国CMS 纯 HTML 站，听书/有声聚合）。
//!
//! 落地范围（2026-11-05 对真站实测）：官网 HTML 路线。分类列表、
//! 专辑详情、搜索 POST 均已验通；章节取流两步（章节页 `#jp-Lines
//! li` 的 data-code → `/e/extend/url.php?code=` → JSON 直链）按
//! MusicFree 公开插件流程原样实现，但服务端 HTML 里目前没有
//! `#jp-Lines` 元素（桌面站与手机站皆无，data-code 数量为 0），
//! play 会干净报错（未验通，别当已播通）。只做免费内容：VIP 章节
//! 不绕、不登录、不破解。
//!
//! 源前缀：本模块走官网（web），不冒充 hmct_（HMCT 没接）。专辑 id
//! 即官网专辑链接 `/album/{分类}-{id}.html`，章节 id 即官网章节
//! 链接 `/audio/{分类}-{专辑id}-{序号}.html`。
//!
//! HMCT 自有 JSON API（基址由远程配置
//! `shuyinfmapi.oss-cn-guangzhou.aliyuncs.com/shuyinfm.json` 下发
//! `api.mekui.com` / `api.chuaxu.com`，已验通配置本身）只静态提取
//! 了路径，参数与 sign 算法未定，一律不调、不猜。端点目录（仅备查）：
//! `/api/app/home`、`/api/app/slideshow`、`/api/app/hotSearch`、
//! `/api/app/hotList`、`/api/app/searchList`、`/api/app/topicIndexList`、
//! `/api/app/vodClass`、`/api/app/vodList`、`/api/vod/details`、
//! `/api/vod/play`、`/api/mw-movie/anonymous/get/filer/type`、
//! `/api/mw-movie/anonymous/v1/get/filer/list`、
//! `/api/mw-movie/anonymous/v1/home/all/list`、
//! `/api/mw-movie/anonymous/home/hotSearch`、
//! `/api/mw-movie/anonymous/video/list`、
//! `/api/mw-movie/anonymous/video/detail`、
//! `/api/mw-movie/anonymous/video/searchByWord`、
//! `/api/mw-movie/anonymous/v2/video/episode/url`、
//! `/api/reader/directory/detail?bookId=`、`/book/search_albums`、
//! `/book/album_info`、`/book/album_tracks`、`/book/batch_play_urls`、
//! `/user/guest_login`（sign 算法在混淆 Dart 里，静态无法还原）。
//! 须动态抓包补齐参数与响应样例后才能第二批落地。

use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::drama::{category_json, client, episode_json, item_json};
use crate::error::{ApiError, ApiResult};

const HOST: &str = "https://www.shuyinfm.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36 Edg/116.0.1938.69";

/// 分类表（文档 4.2 原样，51 项；7 与 36 都是“穿越”，id 不同）。
const CATS: &[(&str, &str)] = &[
    // 有声小说
    ("1", "言情"),
    ("2", "玄幻"),
    ("5", "恐怖"),
    ("7", "穿越"),
    ("8", "都市"),
    ("16", "历史"),
    ("33", "悬疑"),
    ("36", "穿越"),
    ("38", "文学"),
    ("39", "推理"),
    ("40", "军事"),
    ("41", "职场言情"),
    ("56", "反腐"),
    ("58", "人物"),
    ("60", "修真"),
    ("63", "网游"),
    ("92", "武侠"),
    // 广播剧
    ("10", "耽美剧"),
    ("12", "爱情剧"),
    ("51", "古风剧"),
    ("54", "现代剧"),
    // 评书
    ("42", "单田芳"),
    ("43", "刘兰芳"),
    ("44", "田连元"),
    ("45", "袁阔成"),
    ("46", "连丽如"),
    ("47", "张少佐"),
    ("48", "田战义"),
    ("49", "孙一"),
    ("50", "其他"),
    ("53", "袁田"),
    ("55", "王玥波"),
    ("57", "郭德纲"),
    ("62", "关勇超"),
    ("65", "王传林"),
    // 车载
    ("67", "资讯"),
    ("68", "短剧"),
    ("69", "娱乐"),
    ("70", "音乐"),
    ("71", "情感"),
    ("72", "搞笑"),
    ("73", "相声小品"),
    ("74", "汽车"),
    ("75", "公开课"),
    ("76", "生活"),
    ("77", "旅游"),
    // 其它
    ("31", "百家讲坛"),
    ("35", "娱乐"),
    ("59", "粤语"),
    ("98", "音乐"),
    ("99", "古风"),
];

/// 每页条数（站实测 24 条，少于 24 条即末页）。
const PAGE_SIZE: usize = 24;

fn cat_name(id: &str) -> Option<&'static str> {
    CATS.iter()
        .find(|(cid, _)| *cid == id)
        .map(|(_, name)| *name)
}

/// 站方对本机出口间歇性空回复（TLS 通后直接断连，reqwest 报
/// "error sending request"；2026-11-08 探针两分类连着失败，
/// 当天首页曾 200/163KB）：只对传输错重试，最多 3 次、间隔 1 秒
/// 逐个来（同 1000novel 等 9 站的范式），每次新连接即换出口 IP
/// （用户 2026-11-06 轮换令）。非 200 是站方明确拒绝，不重试。
async fn get_text(url: &str, referer: Option<&str>) -> ApiResult<String> {
    let mut last_err: Option<ApiError> = None;
    for attempt in 0..3 {
        let tried = async {
            let mut req = client()?
                .get(url)
                .header("User-Agent", UA)
                .header("Accept", "text/html,application/xhtml+xml,*/*")
                .header("Accept-Language", "zh-CN,zh;q=0.9");
            if let Some(r) = referer {
                req = req.header("Referer", r);
            }
            let resp = req
                .send()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))?;
            let status = resp.status().as_u16();
            if status != 200 {
                return Err(ApiError::Internal(format!("书音FM请求 HTTP {status}")));
            }
            resp.text()
                .await
                .map_err(|e| ApiError::Internal(e.to_string()))
        }
        .await;
        match tried {
            Ok(data) => return Ok(data),
            Err(ApiError::Internal(msg)) if msg.starts_with("书音FM请求 HTTP") => {
                return Err(ApiError::Internal(msg));
            }
            Err(e) => {
                last_err = Some(e);
                if attempt == 2 {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
    Err(last_err.unwrap_or_else(|| ApiError::Internal("书音FM请求失败".into())))
}

/// 去标签 + 解常见实体 + 压空白（与 123av 的 strip_tags 同款，
/// 多解 `&nbsp;` 等实体，列表页的 `&nbsp;&nbsp;` 才不会残留）。
fn strip_tags(raw: &str) -> String {
    let tag = Regex::new("<[^>]+>").unwrap();
    let no_tag = tag.replace_all(raw, " ");
    let decoded = no_tag
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">");
    let ws = Regex::new("\\s+").unwrap();
    ws.replace_all(&decoded, " ").trim().to_string()
}

/// 正则取第 1 个捕获组并去标签；无匹配回空串。
fn pick(block: &str, pattern: &str) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    match re.captures(block) {
        Some(cap) => strip_tags(&cap[1]),
        None => String::new(),
    }
}

/// 地址归一：绝对地址原样，协议相对补 https，站内相对补基址。
fn fix_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if let Some(rest) = u.strip_prefix("//") {
        return format!("https://{rest}");
    }
    if let Some(rest) = u.strip_prefix("https:/") {
        if !rest.starts_with('/') {
            return format!("https://{rest}");
        }
        return u.to_string();
    }
    if u.starts_with('/') {
        return format!("{HOST}{u}");
    }
    format!("{HOST}/{u}")
}

/// 专辑/章节链接归一：绝对地址原样，`/album/...`、`/audio/...`
/// 补基址，裸 `1-126558` 这类当专辑 id 补成 `/album/{id}.html`。
fn fix_page_url(raw: &str) -> String {
    let u = raw.trim();
    if u.is_empty() {
        return String::new();
    }
    if u.starts_with("http://") || u.starts_with("https://") {
        return u.to_string();
    }
    if u.starts_with('/') {
        return format!("{HOST}{u}");
    }
    format!("{HOST}/album/{u}.html")
}

/// 列表块：`<ul ... qm-pic-txt ...>...</ul>` 的内侧（class 后面还
/// 跟着 pic-110-146-classify 等，按 qm-pic-txt 子串匹配）。
fn list_block(html: &str) -> &str {
    let Ok(re) = Regex::new("(?s)<ul[^>]*qm-pic-txt[^>]*>(.*?)</ul>") else {
        return "";
    };
    match re.captures(html) {
        Some(cap) => cap.get(1).map(|m| m.as_str()).unwrap_or(""),
        None => "",
    }
}

/// 一条列表项的原始字段：专辑链接、标题、封面、主播串、
/// 状态日期串、搜索结果的附加行（作者/主播/更新时间）。
struct ListRow {
    id: String,
    title: String,
    cover: String,
    tags: String,
    name: String,
    txts: Vec<String>,
}

fn parse_list_rows(html: &str) -> Vec<ListRow> {
    let block = list_block(html);
    if block.is_empty() {
        return Vec::new();
    }
    let Ok(li_re) = Regex::new("(?s)<li>(.*?)</li>") else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    for cap in li_re.captures_iter(block) {
        let item = &cap[1];
        // 专辑链接：li 里第一个 /album/ 链接（pic 与 s-tit 是同一地址）。
        let Ok(href_re) = Regex::new("href=\"(/album/[^\"]+)\"") else {
            continue;
        };
        let Some(href) = href_re.captures(item).map(|c| c[1].to_string()) else {
            continue;
        };
        let cover = pick(item, "(?s)<img[^>]*src=\"([^\"]+)\"");
        // 标题：s-tit 里 a 的文本；搜索结果缺闭合 </a>，只取到下一个
        // `<` 为止即可，不依赖闭合标签。
        let title = pick(item, "(?s)<span class=\"s-tit\"><a[^>]*>([^<]*)");
        if title.is_empty() {
            continue;
        }
        let tags = pick(item, "(?s)<span class=\"s-tags[^>]*>(.*?)</span>");
        let name = pick(item, "(?s)<span class=\"s-name\">(.*?)</span>");
        let Ok(txt_re) = Regex::new("(?s)<span class=\"s-txt\">(.*?)</span>") else {
            continue;
        };
        let txts: Vec<String> = txt_re
            .captures_iter(item)
            .map(|c| strip_tags(&c[1]))
            .filter(|s| !s.is_empty())
            .collect();
        rows.push(ListRow {
            id: href,
            title,
            cover: fix_url(&cover),
            tags,
            name,
            txts,
        });
    }
    rows
}

/// 详情页标题：JSON-LD 的 name 优先（“有声小说花颜策”），去
/// 掉“有声小说”前缀；退到 h1；再退到 <title> 第一段。
fn detail_title(html: &str, album_id: &str) -> String {
    let strip_prefix = |t: &str| -> String {
        let t = t.trim();
        let t = t.strip_prefix("有声小说").unwrap_or(t);
        // <title> 形如“言情有声小说花颜策_主播…”，分类名前缀也去掉。
        if let Some((cat, _)) = album_id.trim_start_matches("/album/").split_once('-') {
            if let Some(name) = cat_name(cat) {
                let prefixed = format!("{name}有声小说");
                if let Some(rest) = t.strip_prefix(prefixed.as_str()) {
                    return rest.trim().to_string();
                }
            }
        }
        t.to_string()
    };
    let from_ld = pick(html, "(?s)\"name\"\\s*:\\s*\"([^\"]+)\"");
    if !from_ld.is_empty() {
        let t = strip_prefix(&from_ld);
        if !t.is_empty() {
            return t;
        }
    }
    let from_h1 = pick(html, "(?s)<h1[^>]*>(.*?)</h1>");
    if !from_h1.is_empty() {
        let t = strip_prefix(&from_h1);
        if !t.is_empty() {
            return t;
        }
    }
    let from_title = pick(html, "(?s)<title>([^<]*)</title>");
    if !from_title.is_empty() {
        let head = from_title.split('_').next().unwrap_or("").trim();
        let t = strip_prefix(head);
        if !t.is_empty() {
            return t;
        }
    }
    album_id.to_string()
}

/// 章节列表：`#fansinfo` 内 playlist 的 `<li><a href=...>标题</a>`。
fn parse_chapters(html: &str) -> Vec<(String, String)> {
    let Ok(block_re) = Regex::new("(?s)id=\"fansinfo\".*?<ul>(.*?)</ul>") else {
        return Vec::new();
    };
    let Some(block) = block_re.captures(html).map(|c| c[1].to_string()) else {
        return Vec::new();
    };
    let Ok(a_re) = Regex::new("(?s)<li[^>]*>\\s*<a\\s+href=\"([^\"]+)\"[^>]*>(.*?)</a>") else {
        return Vec::new();
    };
    a_re.captures_iter(&block)
        .map(|c| (c[1].to_string(), strip_tags(&c[2])))
        .filter(|(href, title)| href.starts_with("/audio/") && !title.is_empty())
        .collect()
}

pub(crate) async fn categories() -> ApiResult<Value> {
    Ok(
        json!({"categories": CATS.iter().map(|(id, name)| category_json(id, name)).collect::<Vec<_>>()}),
    )
}

pub(crate) async fn catalog(category_id: &str, page: i64) -> ApiResult<Value> {
    let cat = if category_id.is_empty() {
        "1"
    } else {
        category_id
    };
    // 站页码从 0 起，Dart 页码从 1 起。
    let page = if page < 1 { 1 } else { page };
    let site_page = page - 1;
    let url = format!("{HOST}/listinfo-{cat}-{site_page}.html");
    let html = get_text(&url, None).await?;
    let rows = parse_list_rows(&html);
    let items: Vec<Value> = rows
        .iter()
        .map(|r| {
            let remark = if r.name.is_empty() {
                r.tags.clone()
            } else {
                r.name.clone()
            };
            item_json(&r.id, &r.title, &r.cover, &remark)
        })
        .collect();
    // 每页 24 条，少于 24 条即末页。
    let has_more = items.len() == PAGE_SIZE;
    Ok(json!({"items": items, "has_more": has_more}))
}

pub(crate) async fn detail(album_id: &str) -> ApiResult<Value> {
    let url = fix_page_url(album_id);
    if url.is_empty() {
        return Err(ApiError::BadRequest("书音FM专辑 id 为空".into()));
    }
    let html = get_text(&url, None).await?;
    let title = detail_title(&html, album_id);
    // 封面：JSON-LD 的 thumbnailUrl 优先，退到第一张专辑封面图。
    let cover = {
        let from_ld = pick(&html, "\"thumbnailUrl\"\\s*:\\s*\"([^\"]+)\"");
        if !from_ld.is_empty() {
            fix_url(&from_ld)
        } else {
            match Regex::new("src=\"([^\"]*albumcover[^\"]*)\"") {
                Ok(img_re) => img_re
                    .captures(&html)
                    .map(|c| fix_url(&c[1]))
                    .unwrap_or_default(),
                Err(_) => String::new(),
            }
        }
    };
    // 简介：JSON-LD 的 description 优先，退到 #book_intro dd。
    let synopsis = {
        let from_ld = pick(&html, "(?s)\"description\"\\s*:\\s*\"([^\"]+)\"");
        if !from_ld.is_empty() {
            from_ld
        } else {
            pick(&html, "(?s)id=\"book_intro\".*?<dd>(.*?)</dd>")
        }
    };
    // 主播：JSON-LD 的 creator.name 优先，退到 .sub-tags 的 a 链接。
    let teller = {
        let from_ld = pick(
            &html,
            "(?s)\"creator\"\\s*:\\s*\\{[^}]*\"name\"\\s*:\\s*\"([^\"]+)\"",
        );
        if !from_ld.is_empty() {
            from_ld
        } else {
            match Regex::new("(?s)class=\"sub-tags\".*?</p>") {
                Ok(tags_re) => match tags_re.captures(&html) {
                    Some(cap) => match Regex::new("<a[^>]*>([^<]+)</a>") {
                        Ok(a_re) => a_re
                            .captures_iter(&cap[0])
                            .map(|c| c[1].trim().to_string())
                            .filter(|s| !s.is_empty())
                            .collect::<Vec<_>>()
                            .join(","),
                        Err(_) => String::new(),
                    },
                    None => String::new(),
                },
                Err(_) => String::new(),
            }
        }
    };
    let chapters = parse_chapters(&html);
    let count = chapters.len();
    let episodes: Vec<Value> = chapters
        .iter()
        .map(|(href, raw_title)| {
            // Dart 用 $ 作分隔，标题里的 #、$ 先换空格（与听友同款处理）。
            let title = raw_title
                .replace('#', " ")
                .replace('$', " ")
                .trim()
                .to_string();
            episode_json(href, &title, album_id)
        })
        .collect();
    let extra = json!({
        "teller": teller,
        "remarks": format!("{count}集"),
    });
    Ok(json!({
        "id": album_id,
        "title": title,
        "cover": cover,
        "synopsis": synopsis,
        "extra": extra,
        "episodes": episodes,
    }))
}

pub(crate) async fn search(query: &str) -> ApiResult<Value> {
    // EmpireCMS 搜索：POST 后 302 到 /e/search/result/?searchid=xxx，
    // reqwest 默认跟随跳转（302 后改 GET），直接解析结果页。
    let body = format!(
        "keyboard={}&show=title,newstext,player,playadmin,movietime,filetype",
        url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
    );
    let url = format!("{HOST}/e/search/index.php");
    let resp = client()?
        .post(&url)
        .header("User-Agent", UA)
        .header("Accept", "text/html,application/xhtml+xml,*/*")
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .header("Referer", format!("{HOST}/"))
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("书音FM搜索 HTTP {status}")));
    }
    let html = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let rows = parse_list_rows(&html);
    let items: Vec<Value> = rows
        .iter()
        .map(|r| {
            // 搜索结果的 .s-tags 是“分类 状态 N人”，比简介更有区分度。
            let remark = if r.tags.is_empty() {
                r.txts.join(" ")
            } else {
                r.tags.clone()
            };
            item_json(&r.id, &r.title, &r.cover, &remark)
        })
        .collect();
    Ok(json!({"items": items}))
}

/// 章节取流（未验通）：按 MusicFree 插件流程，章节页取 `#jp-Lines
/// li` 第 0 个的 data-code，再用 `url : '...'` 取 path，GET
/// `{path}{code}` 拿 JSON 直链。实测服务端 HTML 里没有 `#jp-Lines`
///（桌面站与手机站皆无），code 拿不到时干净报错，不猜 code、不编
/// 假地址；站方改版开始渲染线路列表后，这条流程无需改代码即可通。
pub(crate) async fn play(video_id: &str) -> ApiResult<Value> {
    let chapter_url = fix_page_url(video_id);
    if chapter_url.is_empty() {
        return Err(ApiError::BadRequest("书音FM章节 id 为空".into()));
    }
    let html = get_text(&chapter_url, None).await?;
    let Ok(lines_re) = Regex::new("(?s)id=\"jp-Lines\".*?<li[^>]*data-code=\"([^\"]+)\"") else {
        return Err(ApiError::Internal("书音FM该章节暂无可用的播放线路".into()));
    };
    let Some(code) = lines_re.captures(&html).map(|c| c[1].to_string()) else {
        return Err(ApiError::Internal("书音FM该章节暂无可用的播放线路".into()));
    };
    let path = pick(&html, "url\\s*:\\s*'([^']*)'");
    if path.is_empty() {
        return Err(ApiError::Internal("书音FM未找到播放地址".into()));
    }
    let api_url = format!("{HOST}{path}{code}");
    let resp = client()?
        .get(&api_url)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", chapter_url.clone())
        .send()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(ApiError::Internal(format!("书音FM取流 HTTP {status}")));
    }
    let final_url = resp.url().to_string();
    let body = resp
        .text()
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    // 正常是 JSON {"url": "..."}；若上游改成 302 直链，兜底用最终地址。
    if let Ok(v) = serde_json::from_str::<Value>(&body) {
        if let Some(u) = v.get("url").and_then(|u| u.as_str()) {
            if !u.is_empty() {
                return Ok(json!({
                    "url": u,
                    "header": {"User-Agent": UA, "Referer": chapter_url},
                }));
            }
        }
    }
    let lower = final_url.to_lowercase();
    if lower.ends_with(".mp3") || lower.ends_with(".m4a") || lower.ends_with(".aac") {
        return Ok(json!({
            "url": final_url,
            "header": {"User-Agent": UA, "Referer": chapter_url},
        }));
    }
    Err(ApiError::Internal("书音FM未返回播放地址".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 样本：分类列表第 1 条（/tmp/sy_list.html 原样截取）。
    const LIST_ITEM: &str = r#"<li>
                                    <div class="pic">
                                        <a href="/album/1-126558.html"><img src="https://img1.kuwo.cn/star/albumcover/240/s4s45/49/181749152.jpg" alt="https://img1.kuwo.cn/star/albumcover/240/s4s45/49/181749152.jpg" width="110" height="146"></a>
                                    </div>
                                    <div class="txt">
                                            <span class="s-tit"><a href="/album/1-126558.html">花颜策</a></span>
                                        <span class="s-tags qm-tags clearfix">月白花繁,药仰,晏绥,郸子邯,元墨,小龟香,鹿千万,小小韓,cv风雨竹,宇粥,夜冥,飞鱼,凡尘_悍匪剧社,cv安期生,江沉</span>
                                        <span class="s-des">太子云迟选妃选中花颜，消息令京城碎心。</span>
                                        <p class="p-bottom-inline">
                                            <span class="s-name">连载中&nbsp;&nbsp;2026-09-04更新</span>
                                        </p>
                                    </div>
                                </li>"#;

    /// 样本：搜索结果第 1 条（/tmp/sy_search2.html 原样截取，s-tit 缺闭合 </a>）。
    const SEARCH_ITEM: &str = r#"<li>
  <div class="pic"><a href="/album/1-126558.html"><img src="https://img1.kuwo.cn/star/albumcover/240/s4s45/49/181749152.jpg"></a></div>
<div class="txt">
 <span class="s-tit"><a href="/album/1-126558.html">花颜策</span>
<span class="s-tags qm-tags clearfix" size="14"> <a href="/listinfo-1-0.html">言情</a>&nbsp;&nbsp;&nbsp;&nbsp;连载中&nbsp;&nbsp;&nbsp;&nbsp;2996人</span>
<span class="s-des">太子云迟选妃选中花颜，消息令京城碎心。</span>   <span class="s-txt"><em>作者：</em>未知&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; 主播：月白花繁,药仰</span> <span class="s-txt">   <em>更新时间：</em>2026-09-04</em> </span> </p> </div>
  <div class="btn">
  <a href="/album/1-126558.html" class="qm-btn gradient block js-start-read-btn" size="40">立即收听</a> </div>
</li>"#;

    fn wrap_list(items: &str) -> String {
        format!("<ul class=\"qm-pic-txt pic-110-146-classify width-1220 clearfix\">{items}</ul>")
    }

    #[test]
    fn categories_count_and_dupes() {
        assert_eq!(CATS.len(), 51);
        // 7 与 36 都是“穿越”，id 不同，都保留。
        assert_eq!(cat_name("7"), Some("穿越"));
        assert_eq!(cat_name("36"), Some("穿越"));
        assert_eq!(cat_name("42"), Some("单田芳"));
        assert_eq!(cat_name("99"), Some("古风"));
        assert_eq!(cat_name("999"), None);
    }

    #[test]
    fn parse_list_item_fields() {
        let rows = parse_list_rows(&wrap_list(LIST_ITEM));
        assert_eq!(rows.len(), 1);
        let r = &rows[0];
        assert_eq!(r.id, "/album/1-126558.html");
        assert_eq!(r.title, "花颜策");
        assert_eq!(
            r.cover,
            "https://img1.kuwo.cn/star/albumcover/240/s4s45/49/181749152.jpg"
        );
        assert!(r.tags.starts_with("月白花繁,药仰"));
        assert_eq!(r.name, "连载中 2026-09-04更新");
    }

    #[test]
    fn parse_search_item_tolerates_unclosed_anchor() {
        let rows = parse_list_rows(&wrap_list(SEARCH_ITEM));
        assert_eq!(rows.len(), 1);
        let r = &rows[0];
        assert_eq!(r.id, "/album/1-126558.html");
        assert_eq!(r.title, "花颜策");
        assert!(r.tags.contains("言情"));
        assert!(r.tags.contains("连载中"));
        assert!(r.tags.contains("2996人"));
        assert_eq!(r.txts.len(), 2);
        assert!(r.txts[0].contains("主播：月白花繁"));
        // `</em>` 去标签时换成空格，日期前带一个空格是正常形态。
        assert!(r.txts[1].contains("更新时间"));
        assert!(r.txts[1].contains("2026-09-04"));
    }

    #[test]
    fn parse_chapters_first_and_last() {
        let html = r#"<div class="bd cl" id="fansinfo"><section class="compress" id="playlist"><ul> <li><a href="/audio/1-126558-0.html" target="_blank">花颜策 001 我算哪门子的贤良淑德</a></li><li><a href="/audio/1-126558-1.html" target="_blank">花颜策 002 折枝而送</a></li></ul></section></div>"#;
        let chs = parse_chapters(html);
        assert_eq!(chs.len(), 2);
        assert_eq!(chs[0].0, "/audio/1-126558-0.html");
        assert_eq!(chs[0].1, "花颜策 001 我算哪门子的贤良淑德");
        assert_eq!(chs[1].0, "/audio/1-126558-1.html");
        assert!(parse_chapters("<div></div>").is_empty());
    }

    #[test]
    fn detail_title_strips_prefix() {
        let html = r#"<script type="application/ld+json">{"@type":"AudioObject","name":"有声小说花颜策","description":"简介","thumbnailUrl":"https://img1.kuwo.cn/x.jpg"}</script><h1>有声小说花颜策</h1>"#;
        assert_eq!(detail_title(html, "/album/1-126558.html"), "花颜策");
        // 无 JSON-LD 时退到 h1；无前缀时原样返回。
        let html2 = "<h1>白眉大侠</h1>";
        assert_eq!(detail_title(html2, "/album/42-1.html"), "白眉大侠");
    }

    #[test]
    fn fix_url_cases() {
        assert_eq!(
            fix_url("https://img1.kuwo.cn/x.jpg"),
            "https://img1.kuwo.cn/x.jpg"
        );
        assert_eq!(
            fix_url("//img1.kuwo.cn/x.jpg"),
            "https://img1.kuwo.cn/x.jpg"
        );
        assert_eq!(
            fix_url("/css/logo.png"),
            "https://www.shuyinfm.com/css/logo.png"
        );
        assert_eq!(fix_url(""), "");
        assert_eq!(
            fix_url("https:/img1.kuwo.cn/x.jpg"),
            "https://img1.kuwo.cn/x.jpg"
        );
    }

    #[test]
    fn fix_page_url_cases() {
        assert_eq!(
            fix_page_url("/album/1-126558.html"),
            "https://www.shuyinfm.com/album/1-126558.html"
        );
        assert_eq!(
            fix_page_url("/audio/1-126558-0.html"),
            "https://www.shuyinfm.com/audio/1-126558-0.html"
        );
        assert_eq!(
            fix_page_url("1-126558"),
            "https://www.shuyinfm.com/album/1-126558.html"
        );
        assert_eq!(fix_page_url(""), "");
    }

    #[test]
    fn strip_tags_decodes_entities() {
        assert_eq!(
            strip_tags("连载中&nbsp;&nbsp;2026-09-04更新"),
            "连载中 2026-09-04更新"
        );
        assert_eq!(strip_tags("<b>花</b>颜策"), "花 颜策");
    }
}
