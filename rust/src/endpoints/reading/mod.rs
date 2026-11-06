//! 阅读区：火蚁TV 内置阅读源的核心实现（小说 / 漫画 / 听书）。
//!
//! 不是直接内置 py 文件或种子数据，是按芽果核心范式写的 Rust 模块，
//! 每站一个文件，各自实现 categories / catalog / detail / search / play。
//! 共 31 站：小说 14（1000novel、69story、aabook、buliang、canovel、
//! cheniyo、cjg、h528、hwg4、jywx2、lbwen、ssxxs、ylxs、yinse），
//! 漫画 11（55comics、csmanhua、dongmanla、ho5ho、kmh001、kuaikan、
//! kxmanhua、mhbl、modu18、nnhanman、tencent），听书 6（tingyou、
//! hsvoice31、hysxs、ximalaya、hongguo、shuyinfm）。
//!
//! 路由（全部走 query，与书旗、影视区一致）：
//! - `/api/v1/reading/categories?site_id=...`
//! - `/api/v1/reading/catalog?site_id=...&category_id=...&page=...`
//! - `/api/v1/reading/detail?site_id=...&id=...`
//! - `/api/v1/reading/search?site_id=...&query=...`
//! - `/api/v1/reading/play?site_id=...&episode_id=...`
//!
//! 返回形状与 Dart 的 DramaSite* 模型一一对应（id/title/cover/remark、
//! episodes 的 video_id/title/series_id），Dart 侧只做直译。取流回
//! `{"url": ..., "header": {...}}`，url 是 novel://、pics:// 或音频直链
//! （parse=0 + 该字典头），Dart 侧按既有 novel://、pics:// 分流播出。
//!
//! 注意：红果听书（hongguo）的签名内核（hash_f13、AES_V3）、设备注册
//! 与 CENC 解密均已移植进 hongguo.rs；play 回 hg_audio:书:集:音色
//! 标记，handle_play 收尾把它改写成核心中继绝对地址
//! `/api/v1/reading/hg_audio?book=..&item=..&tone=..`（handle_hg_audio），
//! 中继回整文件 audio/mp4（3 条音频缓存，Range 头目前只给 /src
//! 静态路用，此路无 Range，播放器在缓冲内 seek）。

#[path = "1000novel.rs"]
mod novel1000;
#[path = "55comics.rs"]
mod comics55;
#[path = "69story.rs"]
mod story69;
mod aabook;
mod buliang;
mod canovel;
mod cheniyo;
mod cjg;
mod csmanhua;
mod dongmanla;
mod h528;
mod ho5ho;
mod hongguo;
mod hsvoice31;
mod hwg4;
mod hysxs;
mod jywx2;
mod kmh001;
mod kuaikan;
mod kxmanhua;
mod lbwen;
mod mhbl;
mod modu18;
mod nnhanman;
mod ssxxs;
mod shuyinfm;
mod tencent;
mod tingyou;
mod ximalaya;
mod yinse;
mod ylxs;

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::{Ctx, Params, RawOut, Server};
use crate::error::{ApiError, ApiResult};

pub fn register(s: &mut Server) {
    s.add_route("reading_categories", handle_categories);
    s.add_route("reading_catalog", handle_catalog);
    s.add_route("reading_detail", handle_detail);
    s.add_route("reading_search", handle_search);
    s.add_route("reading_play", handle_play);
    s.add_raw("reading_hg_audio", handle_hg_audio);
}

fn site_id(params: &Params) -> ApiResult<String> {
    let id = params.get_str("site_id");
    if id.is_empty() {
        return Err(ApiError::BadRequest("missing site_id parameter".into()));
    }
    Ok(id)
}

fn page_of(params: &Params) -> i64 {
    let page = params.get_str("page").parse::<i64>().unwrap_or(1);
    if page < 1 {
        1
    } else {
        page
    }
}

fn handle_categories<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    Box::pin(async move {
        match site?.as_str() {
            "1000novel" => novel1000::categories().await,
            "69story" => story69::categories().await,
            "aabook" => aabook::categories().await,
            "buliang" => buliang::categories().await,
            "canovel" => canovel::categories().await,
            "cheniyo" => cheniyo::categories().await,
            "cjg" => cjg::categories().await,
            "h528" => h528::categories().await,
            "hwg4" => hwg4::categories().await,
            "jywx2" => jywx2::categories().await,
            "lbwen" => lbwen::categories().await,
            "ssxxs" => ssxxs::categories().await,
            "shuyinfm" => shuyinfm::categories().await,
            "ylxs" => ylxs::categories().await,
            "yinse" => yinse::categories().await,
            "55comics" => comics55::categories().await,
            "csmanhua" => csmanhua::categories().await,
            "dongmanla" => dongmanla::categories().await,
            "ho5ho" => ho5ho::categories().await,
            "kmh001" => kmh001::categories().await,
            "kuaikan" => kuaikan::categories().await,
            "kxmanhua" => kxmanhua::categories().await,
            "mhbl" => mhbl::categories().await,
            "modu18" => modu18::categories().await,
            "nnhanman" => nnhanman::categories().await,
            "tencent" => tencent::categories().await,
            "tingyou" => tingyou::categories().await,
            "hsvoice31" => hsvoice31::categories().await,
            "hysxs" => hysxs::categories().await,
            "ximalaya" => ximalaya::categories().await,
            "hongguo" => hongguo::categories().await,
            other => Err(ApiError::BadRequest(format!("unknown reading site: {other}"))),
        }
    })
}

fn handle_catalog<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let category_id = params.get_str("category_id");
    let page = page_of(params);
    Box::pin(async move {
        match site?.as_str() {
            "1000novel" => novel1000::catalog(&category_id, page).await,
            "69story" => story69::catalog(&category_id, page).await,
            "aabook" => aabook::catalog(&category_id, page).await,
            "buliang" => buliang::catalog(&category_id, page).await,
            "canovel" => canovel::catalog(&category_id, page).await,
            "cheniyo" => cheniyo::catalog(&category_id, page).await,
            "cjg" => cjg::catalog(&category_id, page).await,
            "h528" => h528::catalog(&category_id, page).await,
            "hwg4" => hwg4::catalog(&category_id, page).await,
            "jywx2" => jywx2::catalog(&category_id, page).await,
            "lbwen" => lbwen::catalog(&category_id, page).await,
            "ssxxs" => ssxxs::catalog(&category_id, page).await,
            "shuyinfm" => shuyinfm::catalog(&category_id, page).await,
            "ylxs" => ylxs::catalog(&category_id, page).await,
            "yinse" => yinse::catalog(&category_id, page).await,
            "55comics" => comics55::catalog(&category_id, page).await,
            "csmanhua" => csmanhua::catalog(&category_id, page).await,
            "dongmanla" => dongmanla::catalog(&category_id, page).await,
            "ho5ho" => ho5ho::catalog(&category_id, page).await,
            "kmh001" => kmh001::catalog(&category_id, page).await,
            "kuaikan" => kuaikan::catalog(&category_id, page).await,
            "kxmanhua" => kxmanhua::catalog(&category_id, page).await,
            "mhbl" => mhbl::catalog(&category_id, page).await,
            "modu18" => modu18::catalog(&category_id, page).await,
            "nnhanman" => nnhanman::catalog(&category_id, page).await,
            "tencent" => tencent::catalog(&category_id, page).await,
            "tingyou" => tingyou::catalog(&category_id, page).await,
            "hsvoice31" => hsvoice31::catalog(&category_id, page).await,
            "hysxs" => hysxs::catalog(&category_id, page).await,
            "ximalaya" => ximalaya::catalog(&category_id, page).await,
            "hongguo" => hongguo::catalog(&category_id, page).await,
            other => Err(ApiError::BadRequest(format!("unknown reading site: {other}"))),
        }
    })
}

fn handle_detail<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let id = params.get_str("id");
    Box::pin(async move {
        if id.is_empty() {
            return Err(ApiError::BadRequest("missing id parameter".into()));
        }
        match site?.as_str() {
            "1000novel" => novel1000::detail(&id).await,
            "69story" => story69::detail(&id).await,
            "aabook" => aabook::detail(&id).await,
            "buliang" => buliang::detail(&id).await,
            "canovel" => canovel::detail(&id).await,
            "cheniyo" => cheniyo::detail(&id).await,
            "cjg" => cjg::detail(&id).await,
            "h528" => h528::detail(&id).await,
            "hwg4" => hwg4::detail(&id).await,
            "jywx2" => jywx2::detail(&id).await,
            "lbwen" => lbwen::detail(&id).await,
            "ssxxs" => ssxxs::detail(&id).await,
            "shuyinfm" => shuyinfm::detail(&id).await,
            "ylxs" => ylxs::detail(&id).await,
            "yinse" => yinse::detail(&id).await,
            "55comics" => comics55::detail(&id).await,
            "csmanhua" => csmanhua::detail(&id).await,
            "dongmanla" => dongmanla::detail(&id).await,
            "ho5ho" => ho5ho::detail(&id).await,
            "kmh001" => kmh001::detail(&id).await,
            "kuaikan" => kuaikan::detail(&id).await,
            "kxmanhua" => kxmanhua::detail(&id).await,
            "mhbl" => mhbl::detail(&id).await,
            "modu18" => modu18::detail(&id).await,
            "nnhanman" => nnhanman::detail(&id).await,
            "tencent" => tencent::detail(&id).await,
            "tingyou" => tingyou::detail(&id).await,
            "hsvoice31" => hsvoice31::detail(&id).await,
            "hysxs" => hysxs::detail(&id).await,
            "ximalaya" => ximalaya::detail(&id).await,
            "hongguo" => hongguo::detail(&id).await,
            other => Err(ApiError::BadRequest(format!("unknown reading site: {other}"))),
        }
    })
}

fn handle_search<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let query = params.get_str("query");
    Box::pin(async move {
        if query.is_empty() {
            return Err(ApiError::BadRequest("missing query parameter".into()));
        }
        match site?.as_str() {
            "1000novel" => novel1000::search(&query).await,
            "69story" => story69::search(&query).await,
            "aabook" => aabook::search(&query).await,
            "buliang" => buliang::search(&query).await,
            "canovel" => canovel::search(&query).await,
            "cheniyo" => cheniyo::search(&query).await,
            "cjg" => cjg::search(&query).await,
            "h528" => h528::search(&query).await,
            "hwg4" => hwg4::search(&query).await,
            "jywx2" => jywx2::search(&query).await,
            "lbwen" => lbwen::search(&query).await,
            "ssxxs" => ssxxs::search(&query).await,
            "shuyinfm" => shuyinfm::search(&query).await,
            "ylxs" => ylxs::search(&query).await,
            "yinse" => yinse::search(&query).await,
            "55comics" => comics55::search(&query).await,
            "csmanhua" => csmanhua::search(&query).await,
            "dongmanla" => dongmanla::search(&query).await,
            "ho5ho" => ho5ho::search(&query).await,
            "kmh001" => kmh001::search(&query).await,
            "kuaikan" => kuaikan::search(&query).await,
            "kxmanhua" => kxmanhua::search(&query).await,
            "mhbl" => mhbl::search(&query).await,
            "modu18" => modu18::search(&query).await,
            "nnhanman" => nnhanman::search(&query).await,
            "tencent" => tencent::search(&query).await,
            "tingyou" => tingyou::search(&query).await,
            "hsvoice31" => hsvoice31::search(&query).await,
            "hysxs" => hysxs::search(&query).await,
            "ximalaya" => ximalaya::search(&query).await,
            "hongguo" => hongguo::search(&query).await,
            other => Err(ApiError::BadRequest(format!("unknown reading site: {other}"))),
        }
    })
}

fn handle_play<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let episode_id = params.get_str("episode_id");
    let video_id = if episode_id.is_empty() {
        params.get_str("video_id")
    } else {
        episode_id
    };
    let port = {
        let p = ctx.cfg.port;
        if p == 0 {
            18921
        } else {
            p
        }
    };
    Box::pin(async move {
        if video_id.is_empty() {
            return Err(ApiError::BadRequest("missing episode_id parameter".into()));
        }
        let site_name = site?;
        let result = match site_name.as_str() {
            "1000novel" => novel1000::play(&video_id).await,
            "69story" => story69::play(&video_id).await,
            "aabook" => aabook::play(&video_id).await,
            "buliang" => buliang::play(&video_id).await,
            "canovel" => canovel::play(&video_id).await,
            "cheniyo" => cheniyo::play(&video_id).await,
            "cjg" => cjg::play(&video_id).await,
            "h528" => h528::play(&video_id).await,
            "hwg4" => hwg4::play(&video_id).await,
            "jywx2" => jywx2::play(&video_id).await,
            "lbwen" => lbwen::play(&video_id).await,
            "ssxxs" => ssxxs::play(&video_id).await,
            "shuyinfm" => shuyinfm::play(&video_id).await,
            "ylxs" => ylxs::play(&video_id).await,
            "yinse" => yinse::play(&video_id).await,
            "55comics" => comics55::play(&video_id).await,
            "csmanhua" => csmanhua::play(&video_id).await,
            "dongmanla" => dongmanla::play(&video_id).await,
            "ho5ho" => ho5ho::play(&video_id).await,
            "kmh001" => kmh001::play(&video_id).await,
            "kuaikan" => kuaikan::play(&video_id).await,
            "kxmanhua" => kxmanhua::play(&video_id).await,
            "mhbl" => mhbl::play(&video_id).await,
            "modu18" => modu18::play(&video_id).await,
            "nnhanman" => nnhanman::play(&video_id).await,
            "tencent" => tencent::play(&video_id).await,
            "tingyou" => tingyou::play(&video_id).await,
            "hsvoice31" => hsvoice31::play(&video_id).await,
            "hysxs" => hysxs::play(&video_id).await,
            "ximalaya" => ximalaya::play(&video_id).await,
            "hongguo" => hongguo::play(&video_id).await,
            other => Err(ApiError::BadRequest(format!("unknown reading site: {other}"))),
        };
        let mut value = result?;
        if site_name == "hongguo" {
            if let Some(url) = value
                .get("url")
                .and_then(|u| u.as_str())
                .map(|s| s.to_string())
            {
                if url.starts_with("hg_audio:") {
                    if let Some(relay) = hongguo::hg_audio_relay_url(port, &url) {
                        value["url"] = json!(relay);
                    }
                }
            }
        }
        Ok(value)
    })
}

/// 红果听书中继：book/item/tone 三参 → hg_audio_bytes（签名
/// playurl → 下载整文件 → CENC 解密 → 3 条缓存）→ 整文件
/// audio/mp4 流出（无 Range，见模块头说明）。
fn handle_hg_audio<'a>(
    _ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<RawOut>> {
    let book = params.get_str("book");
    let item = params.get_str("item");
    let tone = params.get_str("tone");
    Box::pin(async move {
        if book.is_empty() || item.is_empty() || tone.is_empty() {
            return Err(ApiError::BadRequest(
                "missing book/item/tone parameter".into(),
            ));
        }
        let bytes = hongguo::hg_audio_bytes(&book, &item, &tone).await?;
        Ok(RawOut {
            status: 200,
            content_type: "audio/mp4".to_string(),
            body: bytes,
        })
    })
}
