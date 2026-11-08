//! `homepage_recommend` and `series_feed` endpoints.
//! The `reading724Params` bag lives in `endpoints::base`; the wrapper below
//! only adapts it to `Params` for this module and `search`.

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::base::HOST_FQNOVEL;
use crate::endpoints::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::session::{record_device_session, session_id_from_response};
use crate::endpoints::util::{default_val, raw_json};
use crate::endpoints::{Ctx, Params, Server, INTERNAL_DEVICE_PIN_KEY};
use crate::error::{ApiError, ApiResult};

const HOMEPAGE_RECOMMEND_PATH: &str = "/reading/bookapi/bookmall/tab/v";
const SERIES_FEED_PATH: &str = "/reading/bookapi/bookmall/cell/change/v";
const SERIES_RELATED_PATH: &str = "/reading/bookapi/plan/v";

/// Go's `reading724Params` (content_util.go), in `Params` form.
pub(crate) fn reading724_params() -> Params {
    Params::from_pairs(crate::endpoints::base::reading724_params())
}
/// 顶栏选中下标 `(tab_index, last_tab_index)`。
///
/// 上游按 `tab_index` 决定回哪个 tab 的 `cell_data`，只带 `tab_type` 不够：
/// 这里曾经把它写死成 `"0"`，于是任何分类都拿回推荐流的区块——客户端表现为
/// 「听书」里显示推荐榜/猜你喜欢。官方请求模型里 `tabIndex` / `lastTabIndex`
/// 是正式字段（J:rpc/model/BookstoreTabRequest.java:130,182），选中下标由
/// `m0.java:3091` 的 `setBookMallTabDataList(arrayList, i)` 维护。
///
/// 缺省时两者都退化成 "0"（老调用方只发 `tab_type`，与改动前一致）。
fn strip_indexes(params: &Params) -> (String, String) {
    let tab_index = default_val(&params.get_str("tab_index"), "0");
    let last_tab_index = default_val(&params.get_str("last_tab_index"), tab_index.as_str());
    (tab_index, last_tab_index)
}

fn homepage_recommend<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let client_template = default_val(&params.get_str("client_template"), "0");
        let tab_type = default_val(&params.get_str("tab_type"), "2");
        let offset = default_val(&params.get_str("offset"), "0");
        let (tab_index, last_tab_index) = strip_indexes(params);
        let session_id = params.get_str("session_id");
        // 冷启动标记：默认保持原值；调用方（联调探针）可显式覆盖。
        // 2026-11-07 实测：全关冷启动也改不了条带（仍只回推荐/男生/
        // 女生），所以条带不是这几个参数决定的，覆盖口只留作诊断用。
        let cold_start_session = default_val(&params.get_str("cold_start_session"), "1");
        let cold_start_session_cnt_in_day =
            default_val(&params.get_str("cold_start_session_cnt_in_day"), "2");
        let cold_start_session_cnt_in_life =
            default_val(&params.get_str("cold_start_session_cnt_in_life"), "2");
        let video_tab_cold_start = default_val(&params.get_str("video_tab_cold_start"), "0");
        let last_session_video_tab_type =
            default_val(&params.get_str("last_session_video_tab_type"), "0");

        let mut p = reading724_params();
        p.set("last_search_query_from_rec", "false");
        p.set("ClickedContent", "");
        p.set("client_template", client_template);
        p.set("last_tab_index", last_tab_index);
        p.set("screen_width_px", "1281");
        p.set("classic_tab_style", "v3");
        p.set("tab_type", tab_type);
        p.set("first_use_category_select", "false");
        p.set("last_session_video_tab_type", last_session_video_tab_type);
        p.set("current_name", "");
        p.set("disable_digg_stat", "false");
        p.set("ecom_refresh_type", "0");
        p.set("pad_column_cover", "0");
        p.set("last_tab_type", "0");
        p.set("req_rank_category_id", "0");
        p.set("video_tab_cold_start", video_tab_cold_start);
        p.set("offset", offset);
        if !session_id.is_empty() {
            p.set("session_id", session_id.clone());
        }
        p.set("video_type_preferences_str", "[]");
        p.set("auth_aweme", "false");
        p.set("cold_start_is_double_gd", "false");
        p.set("page_entry_time", "0");
        p.set("cold_start_session", cold_start_session);
        p.set("tab_index", tab_index);
        p.set("lore_tab_style", "v5");
        p.set("device_level", "3");
        p.set("unlimited_short_series_change_type", "0");
        p.set("book_id", "0");
        p.set("ecom_impression_start_time", "0");
        p.set("enable_search_box_collapse", "false");
        p.set("landing_bottom_tab_type", "0");
        p.set("bottom_tab_type", "0");
        p.set("top_tab_extra", "");
        p.set("migration_top_tab_enable", "false");
        p.set("auth_backward", "true");
        p.set("pad_column_detail", "0");
        p.set("after_genre_preference_popup", "0");
        p.set("client_req_type", "1");
        p.set("req_rank_algo", "101");
        p.set("unlimited_short_series_next_offset", "0");
        p.set("normal_session_cnt_in_day", "6");
        p.set(
            "cold_start_session_cnt_in_day",
            cold_start_session_cnt_in_day,
        );
        p.set("sys_mini_window", "1");
        p.set("app_mini_window", "0");
        p.set("har_status", "0");
        p.set(
            "cold_start_session_cnt_in_life",
            cold_start_session_cnt_in_life,
        );
        p.set("charging", "0");
        p.set("normal_session_cnt_in_life", "6");
        p.set("is_power_save_mode", "0");
        p.set("app_dark_mode", "0");
        p.set("screen_brightness", "36");
        p.set("battery_pct", "10");
        p.set("down_speed", "51430");
        p.set("sys_dark_mode", "0");
        p.set("font_scale", "100");
        p.set("network_type", "4");
        p.set("current_volume", "0");

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: HOMEPAGE_RECOMMEND_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };

        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
            if !session_id.is_empty() {
                record_device_session(&session_id, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

/// `bookmall/cell/change` 请求参数（与 `series_feed` 路由同一套）。
///
/// App 首页面 `ShortSeriesDistributeListRepository.n()` 的形状：
/// clientTemplate=VideoFlow(2)、clientReqType=LoadMore(2)、
/// unlimitedSelectorChangeType=ChangeFilter(2)，selectedItems 取 plan 回包
/// cell_selector 里 is_selected 的那组（排行榜落地页默认 all / ranklist_hot_sc）。
#[allow(clippy::too_many_arguments)]
fn cell_change_params(
    cell_id: &str,
    session_id: &str,
    tab_type: &str,
    client_template: &str,
    client_req_type: &str,
    selector_change_type: &str,
    screen_width_px: &str,
    offset: &str,
    cell_name: &str,
    cell_sub_id: &str,
    selected_items: &str,
    sub_selected_items: &str,
    filter_ids: &str,
) -> Params {
    let mut p = reading724_params();
    p.set("cell_id", cell_id);
    p.set("last_search_query_from_rec", "false");
    p.set("ClickedContent", "");
    p.set("client_template", client_template);
    p.set("last_tab_index", "0");
    p.set("screen_width_px", screen_width_px);
    p.set("classic_tab_style", "v3");
    p.set("tab_type", tab_type);
    p.set("first_use_category_select", "false");
    p.set("last_session_video_tab_type", "0");
    p.set("current_name", "");
    p.set("disable_digg_stat", "false");
    p.set("ecom_refresh_type", "0");
    p.set("pad_column_cover", "0");
    p.set("last_tab_type", "0");
    p.set("req_rank_category_id", "0");
    p.set("video_tab_cold_start", "0");
    p.set("offset", offset);
    if !cell_name.is_empty() {
        p.set("cell_name", cell_name);
    }
    if !cell_sub_id.is_empty() {
        p.set("cell_sub_id", cell_sub_id);
    }
    if !selected_items.is_empty() {
        p.set("selected_items", selected_items);
    }
    if !sub_selected_items.is_empty() {
        p.set("sub_selected_items", sub_selected_items);
    }
    if !session_id.is_empty() {
        p.set("session_id", session_id);
    }
    if !filter_ids.is_empty() {
        p.set("filter_ids", filter_ids);
    }
    p.set("video_type_preferences_str", "[]");
    p.set("auth_aweme", "false");
    p.set("cold_start_is_double_gd", "false");
    p.set("page_entry_time", "0");
    p.set("cold_start_session", "1");
    p.set("tab_index", "0");
    p.set("lore_tab_style", "v5");
    p.set("device_level", "3");
    p.set("unlimited_short_series_change_type", "0");
    p.set("unlimited_selector_change_type", selector_change_type);
    p.set("book_id", "0");
    p.set("ecom_impression_start_time", "0");
    p.set("enable_search_box_collapse", "false");
    p.set("landing_bottom_tab_type", "0");
    p.set("bottom_tab_type", "0");
    p.set("top_tab_extra", "");
    p.set("migration_top_tab_enable", "false");
    p.set("auth_backward", "true");
    p.set("pad_column_detail", "0");
    p.set("after_genre_preference_popup", "0");
    p.set("client_req_type", client_req_type);
    p.set("req_rank_algo", "101");
    p.set("unlimited_short_series_next_offset", "0");
    p.set("normal_session_cnt_in_day", "6");
    p.set("cold_start_session_cnt_in_day", "2");
    p.set("sys_mini_window", "1");
    p.set("app_mini_window", "0");
    p.set("har_status", "0");
    p.set("cold_start_session_cnt_in_life", "2");
    p.set("charging", "0");
    p.set("normal_session_cnt_in_life", "6");
    p.set("is_power_save_mode", "0");
    p.set("app_dark_mode", "0");
    p.set("screen_brightness", "36");
    p.set("battery_pct", "10");
    p.set("down_speed", "51430");
    p.set("sys_dark_mode", "0");
    p.set("font_scale", "100");
    p.set("network_type", "4");
    p.set("current_volume", "0");
    p
}

fn series_feed<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let cell_id = params.get_str("cell_id");
        if cell_id.is_empty() {
            return Err(ApiError::BadRequest("缺少cell_id参数".to_string()));
        }

        let tab_type = default_val(&params.get_str("tab_type"), "16");
        let client_template = default_val(&params.get_str("client_template"), "2");
        let client_req_type = default_val(&params.get_str("client_req_type"), "2");
        let selector_change_type =
            default_val(&params.get_str("unlimited_selector_change_type"), "2");
        let screen_width_px = default_val(&params.get_str("screen_width_px"), "1281");
        let offset = default_val(&params.get_str("offset"), "0");
        let session_id = params.get_str("session_id");
        let cell_name = params.get_str("cell_name");
        let cell_sub_id = params.get_str("cell_sub_id");
        let selected_items = params.get_str("selected_items");
        let sub_selected_items = params.get_str("sub_selected_items");
        let filter_ids = params.get_str("filter_ids");

        let p = cell_change_params(
            &cell_id,
            &session_id,
            &tab_type,
            &client_template,
            &client_req_type,
            &selector_change_type,
            &screen_width_px,
            &offset,
            &cell_name,
            &cell_sub_id,
            &selected_items,
            &sub_selected_items,
            &filter_ids,
        );

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: SERIES_FEED_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };

        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
            if !session_id.is_empty() {
                record_device_session(&session_id, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

/// 新鲜 UUID v4（plan 的 session_uuid，每启动随机一个）。
///
/// 注意：不要对 `/dev/urandom` 用 `fs::read`——那是无限流，会一直读到
/// OOM 被杀（2026-11-08 探针实证 exit 137）；只 `read_exact` 16 字节。
/// 打不开时退化成时间 + 进程号混成的 v4 形状，仍合法。
fn fresh_uuid_v4() -> String {
    use std::io::Read;
    let mut b = [0u8; 16];
    let filled = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .is_ok();
    if !filled {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        b.copy_from_slice(&nanos.to_le_bytes());
        b[0] ^= (std::process::id() & 0xff) as u8;
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12],
        b[13], b[14], b[15]
    )
}

/// 番茄视频 plan 请求参数（KMP 形状，2026-11-08 00:33 活体实测能通）。
///
/// 关键：`from` 是必填项（无 from → 101116），且 Java 模型的 `source`
/// 在 KMP 模型里就是 `from`——两者只能留一个，`source` 绝不能再加
/// （S4 对照：重加 source 即回 101116）。`from=video_ranklist` +
/// `bookstore_tab_type=26`（ranklist_landpage）一次即回真视频 cell；
/// `video_topic_landpage` / type 29 仍 101116（缺专题 id，另找来源再试）。
/// 全程匿名：App 自己的视频 plan 调用方根本不设 userIsLogin。
fn fanqie_plan_params(session_uuid: &str) -> Params {
    let mut p = reading724_params();
    p.set("scene", "10");
    p.set("from", "video_ranklist");
    p.set("bookstore_tab_type", "26");
    p.set("selected_items", "");
    p.set("sub_selected_items", "");
    p.set("session_uuid", session_uuid);
    p.set("stick_ids", "");
    p
}

/// 递归找任意一处非空 `video_data` 数组（plan / cell/change 两种回包都适用）。
fn has_video_items(v: &Value) -> bool {
    match v {
        Value::Array(a) => a.iter().any(has_video_items),
        Value::Object(m) => {
            if let Some(Value::Array(a)) = m.get("video_data") {
                if !a.is_empty() {
                    return true;
                }
            }
            m.values().any(has_video_items)
        }
        _ => false,
    }
}

/// plan/v 原样透传：返回上游 JSON（含 data[0] 的视频 cell：cell_id_str、
/// session_id、首屏 10 条 video_data、cell_selector）。
fn fanqie_video_plan<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let uuid = fresh_uuid_v4();
        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: SERIES_RELATED_PATH.to_string(),
            params: fanqie_plan_params(&uuid).to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };
        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

/// plan → cell/change 合并链路（短剧流的新第一段）。
///
/// 没带 cell_id 时先打 plan/v 取排行榜视频 cell（cell_id_str +
/// session_id）；再按 App 首页面形状打 cell/change（VideoFlow=2、
/// LoadMore=2、ChangeFilter=2，selectedItems 取 plan 种子里 is_selected
/// 的 all / ranklist_hot_sc）。change 回了视频就原样返回；change 为空
/// 时回 plan 自带的首屏（data[0] 本身已含 10 条真视频），不再出空白页。
/// 已带 cell_id（翻页）时跳过 plan，直打 change（ChangeFilter 改 GetMore=1）。
fn fanqie_video_feed<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let offset = default_val(&params.get_str("offset"), "0");
        let tab_type = default_val(&params.get_str("tab_type"), "8");
        let pin = params.get_str(INTERNAL_DEVICE_PIN_KEY);
        let mut cell_id = params.get_str("cell_id");
        let mut session_id = params.get_str("session_id");
        let mut plan_first_page: Option<Value> = None;

        if cell_id.is_empty() {
            let uuid = fresh_uuid_v4();
            let spec = UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: SERIES_RELATED_PATH.to_string(),
                params: fanqie_plan_params(&uuid).to_pairs(),
                headers: dragon_read_headers(),
                pin_device: pin.clone(),
                ..Default::default()
            };
            let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
            let plan = raw_json(&raw)?;
            let code = plan.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
            if code != 0 {
                return Err(ApiError::Internal(format!(
                    "番茄 plan 回 code {code}，未拿到视频 cell"
                )));
            }
            let first = plan
                .get("data")
                .and_then(|d| d.as_array())
                .and_then(|a| a.first())
                .cloned();
            let first = match first {
                Some(f) => f,
                None => {
                    return Err(ApiError::Internal("番茄 plan 未回视频 cell".to_string()));
                }
            };
            let seed_cell = first
                .get("cell_id_str")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let seed_session = first
                .get("session_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if seed_cell.is_empty() || seed_session.is_empty() {
                return Err(ApiError::Internal(
                    "番茄 plan 的视频 cell 缺 cell_id/session_id".to_string(),
                ));
            }
            if !dev.device_id.is_empty() {
                record_device_session(&seed_session, &dev.device_id);
            }
            cell_id = seed_cell;
            session_id = seed_session;
            plan_first_page = Some(first);
        }

        // 首屏 ChangeFilter(2)，翻页 GetMore(1)：与 Dart _seriesFlowUrl 同款规则。
        let selector_change_type = if offset == "0" { "2" } else { "1" };
        let p = cell_change_params(
            &cell_id,
            &session_id,
            &tab_type,
            "2",
            "2",
            selector_change_type,
            "1281",
            &offset,
            "",
            "",
            "all",
            "ranklist_hot_sc",
            "",
        );
        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: SERIES_FEED_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: pin,
            ..Default::default()
        };
        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        let change = raw_json(&raw)?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
            if !session_id.is_empty() {
                record_device_session(&session_id, &dev.device_id);
            }
        }
        if has_video_items(&change) {
            // change 回包的 data 里没有 cell_id_str，Dart 翻页就没法接着换流：
            // 把这次用的 cell_id / session_id 盖进 data 再返回，Dart 侧
            // _fanqieFeedPage 直接从 data 里取到、缓存下来供翻页用。
            let mut change = change;
            if let Some(data) = change.get_mut("data").and_then(|d| d.as_object_mut()) {
                data.entry("cell_id_str".to_string())
                    .or_insert_with(|| Value::from(cell_id.clone()));
                if data
                    .get("session_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .is_empty()
                {
                    data.insert("session_id".to_string(), Value::from(session_id.clone()));
                }
            }
            return Ok(change);
        }
        if let Some(first) = plan_first_page {
            return Ok(serde_json::json!({
                "code": 0,
                "message": "SUCCESS",
                "data": first,
            }));
        }
        Ok(change)
    })
}

/// 频道表（官方 `GET /reading/bookapi/bookmall/tab/v`，`BookstoreTabResponse`
/// 的 `data: TabDataList`，其 `tab_item` 是 `Vec<BookstoreTabData>`）。
///
/// 官方**不用静态频道表**：`m0.java:3051-3089` 把 `tab_item` 逐条转成
/// `BookMallTabData`，名字直接取 `bookstoreTabData.title`（`:3058`），
/// 类型取 `tab_type`（`:3086`）。本路由把这两段原样透传，客户端的频道条
/// 就由服务端配置驱动。
///
/// 参数是 `tab_type`（当前选中的频道）与 `last_tab_type`（上次选中的频道，
/// 官方存 SP `last_tab_type`，无值 -1）：与 `homepage_recommend` 不同的地方
/// 是这里**必须**原样返回整个 `tab_item`，不能只挑一个 tab。
///
/// `bottom_tab_type` 必须是 7（官方 `BottomTabBarItemType.VideoSeriesFeedTab`
/// = 7，书城才是 0）：服务端靠它区分语境，0 会拿到**书城**频道条
///（书城把 video_feed=16 那条叫「视频」，且没有最近/收藏），短剧页的频道条
/// 就会塌成「看剧/视频」两条。`client_req_type` 同理对齐官方进页语义
/// `ClientReqType.Open` = 3（我们此前发 1 = Refresh）。
/// 证据：J:seriesmall/SeriesMallVM.java:141-176、J:rpc/model/BottomTabBarItemType.java、
/// J:rpc/model/ClientReqType.java。
fn channel_tabs<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let tab_type = default_val(&params.get_str("tab_type"), "16");
        let last_tab_type = default_val(&params.get_str("last_tab_type"), "-1");
        let mut p = reading724_params();
        p.set("tab_type", tab_type);
        p.set("last_tab_type", last_tab_type);
        p.set("client_template", "0");
        p.set("bottom_tab_type", "7");
        p.set("landing_bottom_tab_type", "0");
        p.set("client_req_type", "3");
        p.set("app_mode", "0");
        p.set("classic_tab_style", "v3");
        p.set("lore_tab_style", "v5");
        p.set("migration_top_tab_enable", "false");
        p.set("auth_aweme", "false");
        p.set("auth_backward", "true");
        p.set("cold_start_is_double_gd", "false");
        p.set("after_genre_preference_popup", "0");
        p.set("first_use_category_select", "false");
        p.set("current_name", "");
        p.set("book_id", "0");
        p.set("last_tab_index", "0");
        p.set("enable_search_box_collapse", "false");
        p.set("top_tab_extra", "");

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: HOMEPAGE_RECOMMEND_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };
        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

// Official lo3/f.java:281-285 uses scene=10, not a general recommendation.
// Note: .agents/notes/implemented/feature/2026-10-15-related-series.md
fn series_related<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let series_id = params.get_str("series_id");
        if series_id.is_empty() || !series_id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(ApiError::BadRequest("缺少有效的series_id参数".to_string()));
        }
        let mut p = reading724_params();
        p.set("scene", "10");
        p.set("from", "series_short_play_info");
        p.set("book_id", series_id.clone());
        p.set("filter_ids", series_id);
        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: SERIES_RELATED_PATH.to_string(),
                params: p.to_pairs(),
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("homepage_recommend", homepage_recommend);
    s.add_route("channel_tabs", channel_tabs);
    s.add_route("series_feed", series_feed);
    s.add_route("series_related", series_related);
    s.add_route("fanqie_video_plan", fanqie_video_plan);
    s.add_route("fanqie_video_feed", fanqie_video_feed);
}

#[cfg(test)]
mod tests {
    use super::strip_indexes;
    use crate::endpoints::Params;

    fn params(pairs: &[(&str, &str)]) -> Params {
        Params::from_pairs(
            pairs
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect(),
        )
    }

    #[test]
    fn audio_tab_reports_its_own_index() {
        // 「听书」在本地六分类里是第 5 项。以前这里写死 "0"，上游就回推荐流
        // 的区块，「听书」里画出推荐榜——真机复现过的那条路径。
        let (tab_index, last_tab_index) =
            strip_indexes(&params(&[("tab_type", "5"), ("tab_index", "5")]));
        assert_eq!(tab_index, "5");
        assert_eq!(last_tab_index, "5", "没带 last 时跟上当前下标");
    }

    #[test]
    fn the_previous_index_is_forwarded_as_sent() {
        let (tab_index, last_tab_index) = strip_indexes(&params(&[
            ("tab_type", "5"),
            ("tab_index", "5"),
            ("last_tab_index", "0"),
        ]));
        assert_eq!(tab_index, "5");
        assert_eq!(last_tab_index, "0");
    }

    #[test]
    fn legacy_callers_still_land_on_the_first_tab() {
        let (tab_index, last_tab_index) = strip_indexes(&params(&[("tab_type", "2")]));
        assert_eq!(tab_index, "0");
        assert_eq!(last_tab_index, "0");
    }

    #[test]
    fn fresh_uuid_v4_has_the_right_shape() {
        let uuid = super::fresh_uuid_v4();
        assert_eq!(uuid.len(), 36, "uuid={uuid}");
        let parts: Vec<&str> = uuid.split('-').collect();
        assert_eq!(
            parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
            [8, 4, 4, 4, 12]
        );
        assert_eq!(&uuid[14..15], "4", "version nibble must be 4: {uuid}");
        assert!(
            ["8", "9", "a", "b"].contains(&&uuid[19..20]),
            "variant nibble must be 8/9/a/b: {uuid}"
        );
        assert!(
            uuid.chars().all(|c| c.is_ascii_hexdigit() || c == '-'),
            "uuid={uuid}"
        );
    }

    #[test]
    fn fanqie_plan_params_use_the_kmp_ranklist_shape() {
        let p = super::fanqie_plan_params("11111111-2222-4333-8444-555555555555");
        // KMP 模型有 from、无 source；重加 source 即 101116（S4 对照）。
        assert_eq!(p.get_str("scene"), "10");
        assert_eq!(p.get_str("from"), "video_ranklist");
        assert_eq!(p.get_str("bookstore_tab_type"), "26");
        assert_eq!(p.get_str("selected_items"), "");
        assert_eq!(p.get_str("sub_selected_items"), "");
        assert_eq!(p.get_str("stick_ids"), "");
        assert_eq!(
            p.get_str("session_uuid"),
            "11111111-2222-4333-8444-555555555555"
        );
        assert!(
            !p.to_pairs().iter().any(|(k, _)| k == "source"),
            "KMP plan must not carry Java-model `source`"
        );
    }

    #[test]
    fn has_video_items_finds_nested_video_data() {
        let with_items = serde_json::json!({
            "data": [{ "cell_data": [{ "video_data": [{ "vid": "1" }] }] }]
        });
        assert!(super::has_video_items(&with_items));
        let empty = serde_json::json!({
            "data": { "cell_view": [], "cell_data": [{ "video_data": [] }] }
        });
        assert!(!super::has_video_items(&empty));
    }
}
