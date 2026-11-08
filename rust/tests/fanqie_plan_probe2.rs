//! Round 2 probe: plan/v 101116 root cause.
//!
//! Stage 1 sent GetPlanRequest fields in camelCase (bookstoreTabType,
//! sessionUuid, selectedItems...). The core's own live paths use snake_case
//! query keys everywhere (selected_items, session_id, bookstore_tab,
//! user_is_login), and the tab/v reflection builds keys from gson
//! @SerializedName (snake_case). Hypothesis A: the server ignores unknown
//! camelCase params, sees required plan fields missing -> 101116.
//!
//! Variants (all DeviceSigned, reading724 clean bag, 2 attempts each):
//!   A1 snake topic, no session_id, b host, /reading/bookapi/plan/v
//!   A2 snake topic + fresh session_id taken live from tab/v
//!   A3 snake ranklist (type 26)
//!   A4 snake topic, literal path /reading/bookapi/plan/v:version/
//!   A5 snake topic, c host (api5-normal-sinfonlinec)
//!   A6 snake topic + user_is_login=0 + bookstore_tab=29
//!   A7 snake short_series_feed (type 37)
//!   R1 control: series_related shape (scene=10, from=series_short_play_info,
//!      book_id/filter_ids = first real book_id from live tab/v)
//!   B1 POST plan/v, JSON body with snake keys, clean bag as query
//!   C1 GET /reading/bookapi/my_tab/plan/v, clean bag
//!   D1 GET /reading/playlet/shortbuy_api/get_feed/v1/, clean bag
//!   E1/E2/E3 GET /reading/bookapi/video_tab/{video_detail,video_model,
//!      multi_video_detail}/v, clean bag (diagnostic: what does it ask for)
//!
//! Run: cargo test --manifest-path rust/Cargo.toml --test fanqie_plan_probe2
//!      -- --ignored --nocapture --test-threads=1

mod common;

use std::time::Instant;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::base::{
    dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec, HOST_FQNOVEL,
    HOST_FQNOVELC,
};
use fqapi_core::endpoints::Params;

fn clean_bag() -> Params {
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
    Params::from_pairs(pairs)
}

fn fresh_uuid() -> String {
    // NOTE: never fs::read /dev/urandom (infinite stream -> OOM-kill);
    // read exactly 16 bytes.
    use std::io::Read;
    let mut b = [0x11u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut b);
    }
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-4{:01x}{:02x}-{:01x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6] & 0x0f, b[7],
        0x8 | (b[8] & 0x03), b[9], b[10], b[11], b[12], b[13], b[14], b[15]
    )
}

fn plan_params(source: &str, tab_type: &str, session_id: Option<&str>) -> Vec<(String, String)> {
    let mut p = clean_bag();
    p.set("scene", "10");
    p.set("source", source);
    p.set("bookstore_tab_type", tab_type);
    p.set("selected_items", "");
    p.set("sub_selected_items", "");
    p.set("session_uuid", fresh_uuid());
    p.set("stick_ids", "");
    if let Some(s) = session_id {
        p.set("session_id", s);
    }
    p.to_pairs()
}

fn report(tag: &str, raw: &[u8], elapsed: std::time::Duration) {
    let path = format!("/tmp/fanqie_plan2_{tag}.bin");
    std::fs::write(&path, raw).ok();
    match serde_json::from_slice::<serde_json::Value>(raw) {
        Ok(v) => {
            let code = v.get("code").map(|c| c.to_string()).unwrap_or_default();
            let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
            let data = v.get("data");
            let data_desc = match data {
                None => "no data key".to_string(),
                Some(serde_json::Value::Null) => "data=null".to_string(),
                Some(serde_json::Value::Object(o)) => format!(
                    "data=obj keys={:?}",
                    o.keys().collect::<Vec<_>>()
                ),
                Some(serde_json::Value::Array(a)) => format!("data=array len={}", a.len()),
                Some(other) => format!("data={}", other),
            };
            println!(
                "[{tag}] JSON in {:?}: len={} code={} message={:?} {}",
                elapsed,
                raw.len(),
                code,
                msg,
                data_desc
            );
            if let Some(d) = data {
                if d.is_object() || d.is_array() {
                    let s = serde_json::to_string(d).unwrap_or_default();
                    println!("[{tag}] data head: {}", &s[..s.len().min(600)]);
                }
            }
        }
        Err(_) => {
            println!(
                "[{tag}] NON-JSON in {:?}: len={} head={:02x?}",
                elapsed,
                raw.len(),
                &raw[..raw.len().min(24)]
            );
        }
    }
}

async fn fetch(
    tag: &str,
    host: &str,
    path: &str,
    params: Vec<(String, String)>,
    extra_headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
) {
    let dir = TempDir::new(&format!("fanqie-plan2-{tag}"));
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let mut headers = dragon_read_headers();
    headers.extend(extra_headers);
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::DeviceSigned,
        host: host.to_string(),
        path: path.to_string(),
        params,
        headers,
        body,
        ..Default::default()
    };
    let t = Instant::now();
    for attempt in 1..=2 {
        match Upstream::new(srv.ctx.up.clone())
            .raw_with_device(&spec)
            .await
        {
            Ok((raw, _dev)) => {
                report(tag, &raw, t.elapsed());
                return;
            }
            Err(e) => {
                println!("[{tag}] attempt {attempt} ERR in {:?}: {}", t.elapsed(), e);
                if attempt < 2 {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }
        }
    }
    println!("[{tag}] ERR after 2 attempts in {:?}", t.elapsed());
}

/// One live tab/v call: returns (fresh session_id, first real book_id).
async fn tab_seed() -> (String, String) {
    let dir = TempDir::new("fanqie-plan2-seed");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let mut p = clean_bag();
    p.set("tab_type", "2");
    p.set("tab_index", "0");
    p.set("bottom_tab_type", "0");
    p.set("client_req_type", "1");
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::DeviceSigned,
        host: HOST_FQNOVEL.to_string(),
        path: "/reading/bookapi/bookmall/tab/v".to_string(),
        params: p.to_pairs(),
        headers: dragon_read_headers(),
        ..Default::default()
    };
    let t = Instant::now();
    for attempt in 1..=2 {
        match Upstream::new(srv.ctx.up.clone())
            .raw_with_device(&spec)
            .await
        {
            Ok((raw, _)) => {
                let v: serde_json::Value = serde_json::from_slice(&raw).unwrap_or_default();
                let mut session = String::new();
                let mut book = String::new();
                if let Some(items) = v
                    .get("data")
                    .and_then(|d| d.get("tab_item"))
                    .and_then(|t| t.as_array())
                {
                    for it in items {
                        if session.is_empty() {
                            if let Some(s) = it.get("session_id").and_then(|s| s.as_str()) {
                                session = s.to_string();
                            }
                        }
                    }
                }
                // collect real id values anywhere in the payload
                fn walk_ids(
                    v: &serde_json::Value,
                    book: &mut String,
                    series: &mut String,
                ) {
                    match v {
                        serde_json::Value::Object(o) => {
                            for (k, val) in o {
                                if book.is_empty() && k == "book_id" {
                                    if let Some(s) = val.as_str() {
                                        if !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()) {
                                            *book = s.to_string();
                                        }
                                    } else if let Some(n) = val.as_i64() {
                                        *book = n.to_string();
                                    }
                                }
                                if series.is_empty() && k == "series_id" {
                                    if let Some(s) = val.as_str() {
                                        if !s.is_empty() {
                                            *series = s.to_string();
                                        }
                                    }
                                }
                                walk_ids(val, book, series);
                            }
                        }
                        serde_json::Value::Array(a) => {
                            for it in a {
                                walk_ids(it, book, series);
                            }
                        }
                        _ => {}
                    }
                }
                let mut series = String::new();
                walk_ids(&v, &mut book, &mut series);
                std::fs::write("/tmp/fanqie_plan2_seed.json", &raw).ok();
                println!("[seed] first series_id={}", series);
                println!(
                    "[seed] tab/v ok in {:?}: session_id={} book_id={}",
                    t.elapsed(),
                    session,
                    book
                );
                return (session, book);
            }
            Err(e) => {
                println!("[seed] attempt {attempt} ERR in {:?}: {}", t.elapsed(), e);
            }
        }
    }
    (String::new(), String::new())
}

// Round 3: bisect the 101116 poison. R1 control (scene=10,
// from=series_short_play_info, book_id+filter_ids) returns code 0, so add
// one suspect at a time to the working base and watch for 101116.
#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_p_bisect() {
    let (session_id, book_id) = tab_seed().await;
    if book_id.is_empty() {
        println!("[bisect] SKIPPED: no seed book_id");
        return;
    }
    let base = |p: &mut Params| {
        p.set("scene", "10");
        p.set("from", "series_short_play_info");
        p.set("book_id", book_id.clone());
        p.set("filter_ids", book_id.clone());
    };
    // P1: base + source + bookstore_tab_type
    {
        let mut p = clean_bag();
        base(&mut p);
        p.set("source", "video_topic_landpage");
        p.set("bookstore_tab_type", "29");
        fetch(
            "p1_base_plus_source",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // P2: base + session_uuid
    {
        let mut p = clean_bag();
        base(&mut p);
        p.set("session_uuid", fresh_uuid());
        fetch(
            "p2_base_plus_uuid",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // P3: base + empty selected/sub/stick
    {
        let mut p = clean_bag();
        base(&mut p);
        p.set("selected_items", "");
        p.set("sub_selected_items", "");
        p.set("stick_ids", "");
        fetch(
            "p3_base_plus_empty",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // P4: full A1 topic set WITHOUT session_uuid
    {
        let mut p = clean_bag();
        p.set("scene", "10");
        p.set("source", "video_topic_landpage");
        p.set("bookstore_tab_type", "29");
        p.set("selected_items", "");
        p.set("sub_selected_items", "");
        p.set("stick_ids", "");
        fetch(
            "p4_topic_no_uuid",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // P5: full A1 topic set + book_id/filter_ids
    {
        let mut p = clean_bag();
        p.set("scene", "10");
        p.set("source", "video_topic_landpage");
        p.set("bookstore_tab_type", "29");
        p.set("selected_items", "");
        p.set("sub_selected_items", "");
        p.set("session_uuid", fresh_uuid());
        p.set("stick_ids", "");
        p.set("book_id", book_id.clone());
        p.set("filter_ids", book_id.clone());
        fetch(
            "p5_topic_plus_book",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // P6: base + fresh session_id (isolates session_id)
    if !session_id.is_empty() {
        let mut p = clean_bag();
        base(&mut p);
        p.set("session_id", session_id);
        fetch(
            "p6_base_plus_sid",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
}

// Round 4: is `from` the missing key for the topic call? P1 (base+source)
// was code 0; P4 (topic set, no from/book) was 101116. P7 drops the book
// from P1, P8 tries a topic-flavoured from value.
#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_p_round4() {
    // P7: A1 + from=series_short_play_info (no book_id)
    {
        let mut p = plan_params("video_topic_landpage", "29", None);
        // plan_params returns pairs; rebuild as Params to add `from`
        let mut pp = Params::from_pairs(p);
        pp.set("from", "series_short_play_info");
        fetch(
            "p7_topic_from_related",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // P8: A1 + from=video_topic_landpage
    {
        let mut pp = Params::from_pairs(plan_params("video_topic_landpage", "29", None));
        pp.set("from", "video_topic_landpage");
        fetch(
            "p8_topic_from_topic",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
}

// Round 5: with from=series_short_play_info (known-good), try the other
// plan callers' shapes: ranklist (needs no selection), double-col,
// listen-mode, plus two more `from` candidates for the topic call.
#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_p_round5() {
    // Q1: ranklist + from=series_short_play_info
    {
        let mut pp = Params::from_pairs(plan_params("video_ranklist", "26", None));
        pp.set("from", "series_short_play_info");
        fetch(
            "q1_rank_from_related",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // Q3: double-col shape + from
    {
        let mut p = clean_bag();
        p.set("scene", "10");
        p.set("source", "double_col_enter_single_outflow");
        p.set("session_uuid", fresh_uuid());
        p.set("filter_ids", "");
        p.set("bookstore_tab_type", "35");
        p.set("session_id", "");
        p.set("from", "series_short_play_info");
        fetch(
            "q3_doublecol_from_related",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // Q4: listen shape + from
    {
        let mut p = clean_bag();
        p.set("scene", "10");
        p.set("source", "listen_video_playlist");
        p.set("book_id", "0");
        p.set("offset", "0");
        p.set("session_id", "");
        p.set("session_uuid", fresh_uuid());
        p.set("from", "series_short_play_info");
        fetch(
            "q4_listen_from_related",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // Q5: topic + from=topic
    {
        let mut pp = Params::from_pairs(plan_params("video_topic_landpage", "29", None));
        pp.set("from", "topic");
        fetch(
            "q5_topic_from_topic",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // Q6: topic + from=ranking
    {
        let mut pp = Params::from_pairs(plan_params("video_topic_landpage", "29", None));
        pp.set("from", "ranking");
        fetch(
            "q6_topic_from_ranking",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
}

// Round 6: KMP shape. The live video plan caller (Lsl4/j;->e) builds the
// KMP GetPlanRequest, which has `from` but NO `source` (Java `source` maps
// to KMP `from`). So: topic params with from=video_topic_landpage and NO
// source param at all. S4 re-adds source as a control (expect 101116).
#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_p_round6() {
    let kmp_params = |from: &str, tab_type: &str, session_id: Option<&str>| {
        let mut p = clean_bag();
        p.set("scene", "10");
        p.set("from", from);
        p.set("bookstore_tab_type", tab_type);
        p.set("selected_items", "");
        p.set("sub_selected_items", "");
        p.set("session_uuid", fresh_uuid());
        p.set("stick_ids", "");
        if let Some(s) = session_id {
            p.set("session_id", s);
        }
        p.to_pairs()
    };
    // S1: KMP topic, no session_id, no source
    fetch(
        "s1_kmp_topic",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        kmp_params("video_topic_landpage", "29", None),
        vec![],
        None,
    )
    .await;
    // S2: KMP topic + fresh tab/v session_id
    let (session_id, _book_id) = tab_seed().await;
    if !session_id.is_empty() {
        fetch(
            "s2_kmp_topic_sid",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            kmp_params("video_topic_landpage", "29", Some(&session_id)),
            vec![],
            None,
        )
        .await;
    }
    // S3: KMP ranklist
    fetch(
        "s3_kmp_rank",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        kmp_params("video_ranklist", "26", None),
        vec![],
        None,
    )
    .await;
    // S4: control — KMP topic + source re-added
    {
        let mut pp = Params::from_pairs(kmp_params("video_topic_landpage", "29", None));
        pp.set("source", "video_topic_landpage");
        fetch(
            "s4_kmp_topic_plus_source",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
}

// Round 7 (verification): T1 cell/change with the S3 seed (cell_id +
// session_id observed live in /tmp/fanqie_plan2_s3_kmp_rank.bin); T2 KMP
// topic with a REAL selector id from the ranklist response.
#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_verify_seed() {
    // T1: cell/change first page from the ranklist seed
    {
        let mut p = clean_bag();
        p.set("cell_id", "7470092475068071998");
        p.set("session_id", "202611080040003EDE1A443A64B3D65394");
        p.set("tab_type", "8");
        p.set("client_template", "0");
        p.set("offset", "0");
        p.set("client_req_type", "1");
        p.set("last_tab_index", "0");
        p.set("last_tab_type", "0");
        fetch(
            "t1_cell_change_seed",
            HOST_FQNOVEL,
            "/reading/bookapi/bookmall/cell/change/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
    // T2: KMP topic + real selector ids
    {
        let mut pp = Params::from_pairs({
            let mut p = clean_bag();
            p.set("scene", "10");
            p.set("from", "video_topic_landpage");
            p.set("bookstore_tab_type", "29");
            p.set("selected_items", "all");
            p.set("sub_selected_items", "ranklist_hot_sc");
            p.set("session_uuid", fresh_uuid());
            p.set("stick_ids", "");
            p.to_pairs()
        });
        let _ = &mut pp;
        fetch(
            "t2_kmp_topic_selected",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            pp.to_pairs(),
            vec![],
            None,
        )
        .await;
    }
}

// Split into small tests: the VM OOM-kills long-lived probe processes while
// other sessions run heavy Flutter tests, so each test stays short.
#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_a1_a2() {
    let (session_id, _book_id) = tab_seed().await;
    fetch(
        "a1_snake_topic",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        plan_params("video_topic_landpage", "29", None),
        vec![],
        None,
    )
    .await;
    if !session_id.is_empty() {
        fetch(
            "a2_snake_topic_sid",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            plan_params("video_topic_landpage", "29", Some(&session_id)),
            vec![],
            None,
        )
        .await;
    } else {
        println!("[a2_snake_topic_sid] SKIPPED: no seed session_id");
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_a3_a4() {
    fetch(
        "a3_snake_rank",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        plan_params("video_ranklist", "26", None),
        vec![],
        None,
    )
    .await;
    fetch(
        "a4_snake_version_lit",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v:version/",
        plan_params("video_topic_landpage", "29", None),
        vec![],
        None,
    )
    .await;
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_a5_a6_a7() {
    fetch(
        "a5_snake_chost",
        HOST_FQNOVELC,
        "/reading/bookapi/plan/v",
        plan_params("video_topic_landpage", "29", None),
        vec![],
        None,
    )
    .await;
    let mut pairs = plan_params("video_topic_landpage", "29", None);
    pairs.push(("user_is_login".to_string(), "0".to_string()));
    pairs.push(("bookstore_tab".to_string(), "29".to_string()));
    fetch(
        "a6_snake_login0_tab",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        pairs,
        vec![],
        None,
    )
    .await;
    fetch(
        "a7_snake_short37",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        plan_params("short_series_feed", "37", None),
        vec![],
        None,
    )
    .await;
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_r1_control() {
    let (_session_id, book_id) = tab_seed().await;
    if !book_id.is_empty() {
        let mut p = clean_bag();
        p.set("scene", "10");
        p.set("from", "series_short_play_info");
        p.set("book_id", book_id.clone());
        p.set("filter_ids", book_id);
        fetch(
            "r1_control_related",
            HOST_FQNOVEL,
            "/reading/bookapi/plan/v",
            p.to_pairs(),
            vec![],
            None,
        )
        .await;
    } else {
        println!("[r1_control_related] SKIPPED: no seed book_id");
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_b1_c1() {
    let body = serde_json::json!({
        "scene": 10,
        "source": "video_topic_landpage",
        "bookstore_tab_type": 29,
        "selected_items": "",
        "sub_selected_items": "",
        "session_uuid": fresh_uuid(),
        "stick_ids": "",
    });
    fetch(
        "b1_post_json",
        HOST_FQNOVEL,
        "/reading/bookapi/plan/v",
        clean_bag().to_pairs(),
        vec![(
            "Content-Type".to_string(),
            "application/json; charset=utf-8".to_string(),
        )],
        Some(serde_json::to_vec(&body).unwrap()),
    )
    .await;
    fetch(
        "c1_mytab_plan",
        HOST_FQNOVEL,
        "/reading/bookapi/my_tab/plan/v",
        clean_bag().to_pairs(),
        vec![],
        None,
    )
    .await;
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn t_d1_e() {
    fetch(
        "d1_get_feed",
        HOST_FQNOVEL,
        "/reading/playlet/shortbuy_api/get_feed/v1/",
        clean_bag().to_pairs(),
        vec![],
        None,
    )
    .await;
    for (tag, path) in [
        ("e1_video_detail", "/reading/bookapi/video_tab/video_detail/v"),
        ("e2_video_model", "/reading/bookapi/video_tab/video_model/v"),
        (
            "e3_multi_video_detail",
            "/reading/bookapi/video_tab/multi_video_detail/v",
        ),
    ] {
        fetch(tag, HOST_FQNOVEL, path, clean_bag().to_pairs(), vec![], None).await;
    }
}
