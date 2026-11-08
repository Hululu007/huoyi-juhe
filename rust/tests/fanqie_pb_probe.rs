//! Live probe: does bookmall/tab/v answer protobuf when asked?
//!
//! Same signed param bag as `homepage_recommend` (tab_type=8), but with
//! `Accept: application/x-protobuf` instead of the default. Dumps raw bytes
//! and a generic protobuf field walk + extracted strings to /tmp.
//!
//! Run: cargo test --manifest-path rust/Cargo.toml --test fanqie_pb_probe
//!      -- --ignored --nocapture --test-threads=1

mod common;

use std::time::Instant;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::base::{
    dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec, HOST_FQNOVEL,
};
use fqapi_core::endpoints::Params;

fn bag() -> Params {
    let pairs: Vec<(String, String)> = [
        ("iid", "{install_id}"),
        ("device_id", "{device_id}"),
        ("ac", "wifi"),
        ("channel", "xiaomi_1967_64"),
        ("aid", "1967"),
        ("app_name", "novelapp"),
        ("version_code", "72432"),
        ("version_name", "7.2.4.32"),
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("device_type", "25053RT47C"),
        ("device_brand", "Redmi"),
        ("language", "zh"),
        ("os_api", "36"),
        ("os_version", "16"),
        ("manifest_version_code", "72432"),
        ("resolution", "1280*2620"),
        ("dpi", "520"),
        ("update_version_code", "72432"),
        ("host_abi", "arm64-v8a"),
        ("dragon_device_type", "phone"),
        ("pv_player", "72432"),
        ("compliance_status", "0"),
        ("need_personal_recommend", "1"),
        ("player_so_load", "1"),
        ("is_android_pad_screen", "0"),
        ("rom_version", "miui_V816_OS3.0.9.0.WOLCNXM"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();
    let mut p = Params::from_pairs(pairs);
    p.set("last_search_query_from_rec", "false");
    p.set("ClickedContent", "");
    p.set("client_template", "0");
    p.set("last_tab_index", "2");
    p.set("screen_width_px", "1281");
    p.set("classic_tab_style", "v3");
    p.set("tab_type", "8");
    p.set("first_use_category_select", "false");
    p.set("last_session_video_tab_type", "0");
    p.set("current_name", "");
    p.set("disable_digg_stat", "false");
    p.set("ecom_refresh_type", "0");
    p.set("pad_column_cover", "0");
    p.set("last_tab_type", "0");
    p.set("req_rank_category_id", "0");
    p.set("video_tab_cold_start", "0");
    p.set("offset", "0");
    p.set("video_type_preferences_str", "[]");
    p.set("auth_aweme", "false");
    p.set("cold_start_is_double_gd", "false");
    p.set("page_entry_time", "0");
    p.set("cold_start_session", "1");
    p.set("tab_index", "2");
    p.set("lore_tab_style", "v5");
    p.set("device_level", "3");
    p.set("unlimited_short_series_change_type", "0");
    p.set("book_id", "0");
    p.set("ecom_impression_start_time", "0");
    p.set("enable_search_box_collapse", "false");
    p.set("landing_bottom_tab_type", "0");
    p.set("top_tab_extra", "");
    p.set("migration_top_tab_enable", "false");
    p.set("auth_backward", "true");
    p.set("pad_column_detail", "0");
    p.set("after_genre_preference_popup", "0");
    p.set("client_req_type", "1");
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

fn hex_head(b: &[u8], n: usize) -> String {
    b.iter()
        .take(n)
        .map(|x| format!("{:02x}", x))
        .collect::<Vec<_>>()
        .join(" ")
}

fn varint(b: &[u8], mut i: usize) -> Option<(u64, usize)> {
    let mut v: u64 = 0;
    let mut shift = 0;
    loop {
        if i >= b.len() || shift >= 70 {
            return None;
        }
        let x = b[i];
        i += 1;
        v |= ((x & 0x7f) as u64) << shift;
        if x & 0x80 == 0 {
            return Some((v, i));
        }
        shift += 7;
    }
}

fn walk(b: &[u8], depth: usize, out: &mut Vec<String>) {
    if depth > 4 || out.len() > 200 {
        return;
    }
    let mut i = 0;
    let mut n = 0;
    while i < b.len() && n < 60 {
        let Some((key, ni)) = varint(b, i) else { break };
        i = ni;
        let field = key >> 3;
        let wire = key & 7;
        if field == 0 || field > 100000 {
            break;
        }
        n += 1;
        match wire {
            0 => {
                let Some((v, ni2)) = varint(b, i) else { break };
                i = ni2;
                out.push(format!("{}f{} varint {}", "  ".repeat(depth), field, v));
            }
            1 => {
                if i + 8 > b.len() {
                    break;
                }
                out.push(format!("{}f{} fixed64", "  ".repeat(depth), field));
                i += 8;
            }
            5 => {
                if i + 4 > b.len() {
                    break;
                }
                out.push(format!("{}f{} fixed32", "  ".repeat(depth), field));
                i += 4;
            }
            2 => {
                let Some((len, ni2)) = varint(b, i) else {
                    break;
                };
                i = ni2;
                let len = len as usize;
                if i + len > b.len() {
                    break;
                }
                let chunk = &b[i..i + len];
                if let Ok(s) = std::str::from_utf8(chunk) {
                    let t = s.trim();
                    if t.len() >= 2 && t.chars().all(|c| !c.is_control()) {
                        let shown: String = t.chars().take(80).collect();
                        out.push(format!(
                            "{}f{} len {} str {:?}",
                            "  ".repeat(depth),
                            field,
                            len,
                            shown
                        ));
                    } else {
                        out.push(format!(
                            "{}f{} len {} bytes",
                            "  ".repeat(depth),
                            field,
                            len
                        ));
                        walk(chunk, depth + 1, out);
                    }
                } else {
                    out.push(format!(
                        "{}f{} len {} bytes",
                        "  ".repeat(depth),
                        field,
                        len
                    ));
                    walk(chunk, depth + 1, out);
                }
                i += len;
            }
            _ => break,
        }
    }
}

fn strings_of(b: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur: Vec<u8> = Vec::new();
    let flush = |cur: &mut Vec<u8>, out: &mut Vec<String>| {
        if cur.len() >= 4 {
            if let Ok(s) = String::from_utf8(cur.clone()) {
                out.push(s);
            }
        }
        cur.clear();
    };
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if (0x20..0x7f).contains(&c) || c >= 0x80 {
            cur.push(c);
        } else {
            flush(&mut cur, &mut out);
        }
        i += 1;
    }
    flush(&mut cur, &mut out);
    out
}

async fn fetch(
    tag: &str,
    accept_pb: bool,
    content_type_pb: bool,
    bottom_tab: &str,
    req_type: &str,
    path: &str,
    cold: bool,
) {
    let dir = TempDir::new(&format!("fanqie-pb-{tag}"));
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let mut p = bag();
    p.set("bottom_tab_type", bottom_tab);
    p.set("client_req_type", req_type);
    if cold {
        p.set("video_tab_cold_start", "1");
        p.set("is_video_feed_tab_first_request_cold_start", "true");
        p.set("client_req_type", "7");
    }
    let mut headers = dragon_read_headers();
    if accept_pb {
        headers.push(("Accept".to_string(), "application/x-protobuf".to_string()));
    }
    if content_type_pb {
        headers.push((
            "Content-Type".to_string(),
            "application/x-protobuf".to_string(),
        ));
    }
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::DeviceSigned,
        host: HOST_FQNOVEL.to_string(),
        path: path.to_string(),
        params: p.to_pairs(),
        headers,
        ..Default::default()
    };
    let t = Instant::now();
    let mut last_err = String::new();
    for attempt in 1..=3 {
        match Upstream::new(srv.ctx.up.clone())
            .raw_with_device(&spec)
            .await
        {
            Ok((raw, dev)) => {
                let path = format!("/tmp/fanqie_pb_{tag}.bin");
                std::fs::write(&path, &raw).ok();
                let as_json: Result<serde_json::Value, _> = serde_json::from_slice(&raw);
                println!(
                    "[{tag}] ok attempt {attempt} in {:?}: len={} device={} json={} head={}",
                    t.elapsed(),
                    raw.len(),
                    dev.device_id,
                    as_json.is_ok(),
                    hex_head(&raw, 24),
                );
                if let Ok(v) = as_json {
                    let s = serde_json::to_string(&v).unwrap_or_default();
                    println!("[{tag}] json head: {}", &s[..s.len().min(300)]);
                    return;
                }
                let mut fields = Vec::new();
                walk(&raw, 0, &mut fields);
                println!("[{tag}] proto walk ({} lines):", fields.len());
                for f in fields.iter().take(80) {
                    println!("  {}", f);
                }
                let strs = strings_of(&raw);
                println!("[{tag}] printable runs: {}", strs.len());
                for key in [
                    "看剧", "视频", "推荐", "短剧", "男生", "女生", "video", "series",
                ] {
                    let n = strs.iter().filter(|s| s.contains(key)).count();
                    println!("  contains {:?}: {} runs", key, n);
                }
                for s in strs.iter().take(30) {
                    println!("  str: {}", s.chars().take(100).collect::<String>());
                }
                return;
            }
            Err(e) => {
                last_err = e.to_string();
                println!(
                    "[{tag}] attempt {attempt} ERR in {:?}: {}",
                    t.elapsed(),
                    last_err
                );
                if attempt < 3 {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }
        }
    }
    println!(
        "[{tag}] ERR after 3 attempts in {:?}: {}",
        t.elapsed(),
        last_err
    );
}

async fn fetch_plan(tag: &str, tab_type_val: &str, source: &str, pb_headers: bool) {
    let dir = TempDir::new(&format!("fanqie-pb-{tag}"));
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let mut p = bag();
    p.set("scene", "10");
    p.set("source", source);
    p.set("bookstoreTabType", tab_type_val);
    p.set("selectedItems", "");
    p.set("subSelectedItems", "");
    p.set("sessionUuid", "a1b2c3d4-e5f6-4789-abcd-ef0123456789");
    p.set("sessionId", "20261107234945658B338A565402D0D489");
    p.set("stickIds", "");
    let mut headers = dragon_read_headers();
    if pb_headers {
        headers.push(("Accept".to_string(), "application/x-protobuf".to_string()));
        headers.push((
            "Content-Type".to_string(),
            "application/x-protobuf".to_string(),
        ));
    }
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::DeviceSigned,
        host: HOST_FQNOVEL.to_string(),
        path: "/reading/bookapi/plan/v".to_string(),
        params: p.to_pairs(),
        headers,
        ..Default::default()
    };
    let t = Instant::now();
    let mut last_err = String::new();
    for attempt in 1..=3 {
        match Upstream::new(srv.ctx.up.clone())
            .raw_with_device(&spec)
            .await
        {
            Ok((raw, dev)) => {
                let path = format!("/tmp/fanqie_pb_{tag}.bin");
                std::fs::write(&path, &raw).ok();
                let as_json: Result<serde_json::Value, _> = serde_json::from_slice(&raw);
                println!(
                    "[{tag}] ok attempt {attempt} in {:?}: len={} device={} json={} head={}",
                    t.elapsed(),
                    raw.len(),
                    dev.device_id,
                    as_json.is_ok(),
                    hex_head(&raw, 24),
                );
                if let Ok(v) = as_json {
                    let s = serde_json::to_string(&v).unwrap_or_default();
                    println!("[{tag}] json head: {}", &s[..s.len().min(300)]);
                    return;
                }
                let mut fields = Vec::new();
                walk(&raw, 0, &mut fields);
                println!("[{tag}] proto walk ({} lines):", fields.len());
                for f in fields.iter().take(80) {
                    println!("  {}", f);
                }
                let strs = strings_of(&raw);
                println!("[{tag}] printable runs: {}", strs.len());
                for key in [
                    "看剧", "视频", "推荐", "短剧", "男生", "女生", "video", "series",
                ] {
                    let n = strs.iter().filter(|s| s.contains(key)).count();
                    println!("  contains {:?}: {} runs", key, n);
                }
                for s in strs.iter().take(30) {
                    println!("  str: {}", s.chars().take(100).collect::<String>());
                }
                return;
            }
            Err(e) => {
                last_err = e.to_string();
                println!(
                    "[{tag}] attempt {attempt} ERR in {:?}: {}",
                    t.elapsed(),
                    last_err
                );
                if attempt < 3 {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }
        }
    }
    println!(
        "[{tag}] ERR after 3 attempts in {:?}: {}",
        t.elapsed(),
        last_err
    );
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn probe_accept_protobuf() {
    // Round 6: the plan API is served by the JSON-model service (Lu35/c),
    // so the app sends it WITHOUT the protobuf headers; forcing PB headers
    // onto it returned SERVICE_ERROR (code 101116) in round 5.
    fetch_plan("m_plan_json", "29", "video_topic_landpage", false).await;
    fetch_plan("n_plan_rank", "26", "video_ranklist", false).await;
}
