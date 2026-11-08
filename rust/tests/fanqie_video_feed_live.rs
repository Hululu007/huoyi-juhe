//! Live verification for the fanqie plan -> cell/change chain (stage 2/3).
//!
//! - `live_fanqie_feed_combined`: the new `fanqie_video_feed` route
//!   (plan/v ranklist seed, then cell/change in the App first-page shape).
//! - `live_fanqie_plan_then_series_feed`: the same chain split across the
//!   two existing legs -- `fanqie_video_plan` for the seed, then the
//!   untouched `series_feed` route for the video flow.
//! - `live_fanqie_detail_play_danmaku`: detail/directory + stream URL +
//!   danmaku for the first video of the feed (reads /tmp/fanqie_vid.txt
//!   written by the first test; video_url is also saved for a curl HLS check).
//!
//! Run: cargo test --manifest-path rust/Cargo.toml --test fanqie_video_feed_live
//!      -- --ignored --nocapture --test-threads=1

mod common;

use std::time::Instant;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;

fn pairs(items: &[(&str, &str)]) -> Params {
    Params::from_pairs(
        items
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect(),
    )
}

/// Recursively collect every `video_data` entry's (vid, title, cover, series_id).
fn collect_videos(v: &serde_json::Value, out: &mut Vec<(String, String, String, String)>) {
    match v {
        serde_json::Value::Array(a) => {
            for it in a {
                collect_videos(it, out);
            }
        }
        serde_json::Value::Object(m) => {
            if let Some(serde_json::Value::Array(a)) = m.get("video_data") {
                for it in a {
                    if let Some(o) = it.as_object() {
                        let s =
                            |k: &str| o.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
                        out.push((s("vid"), s("title"), s("cover"), s("series_id")));
                    }
                }
            }
            for val in m.values() {
                collect_videos(val, out);
            }
        }
        _ => {}
    }
}

fn report_videos(tag: &str, v: &serde_json::Value) -> Vec<(String, String, String, String)> {
    let mut videos = Vec::new();
    collect_videos(v, &mut videos);
    println!("[{tag}] video_data items: {}", videos.len());
    for (i, (vid, title, cover, sid)) in videos.iter().take(3).enumerate() {
        println!(
            "[{tag}]   #{i} vid={vid} series_id={sid} title={title} cover={}",
            cover.chars().take(80).collect::<String>()
        );
    }
    videos
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_fanqie_feed_combined() {
    let dir = TempDir::new("fanqie-feed-combined");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("fanqie_video_feed")
        .expect("route fanqie_video_feed");
    let t = Instant::now();
    let res = feed(&srv.ctx, &pairs(&[("tab_type", "8"), ("offset", "0")])).await;
    match res {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_feed_combined.json", &s).ok();
            println!("[combined] ok in {:?}: len={}", t.elapsed(), s.len());
            let videos = report_videos("combined", &v);
            let data = v.get("data");
            println!(
                "[combined] has_more={} next_offset={} session_id={} cell_id_str={}",
                data.and_then(|d| d.get("has_more"))
                    .map(|x| x.to_string())
                    .unwrap_or_default(),
                data.and_then(|d| d.get("next_offset"))
                    .map(|x| x.to_string())
                    .unwrap_or_default(),
                data.and_then(|d| d.get("session_id"))
                    .and_then(|x| x.as_str())
                    .unwrap_or(""),
                data.and_then(|d| d.get("cell_id_str"))
                    .and_then(|x| x.as_str())
                    .unwrap_or(""),
            );
            assert!(!videos.is_empty(), "combined feed returned no videos");
            let (vid, _title, _cover, sid) = &videos[0];
            std::fs::write("/tmp/fanqie_vid.txt", format!("{vid}\n{sid}\n")).ok();
        }
        Err(e) => {
            println!("[combined] ERR in {:?}: {}", t.elapsed(), e.message());
            panic!("fanqie_video_feed failed: {}", e.message());
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_fanqie_plan_then_series_feed() {
    let dir = TempDir::new("fanqie-plan-split");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let plan = srv
        .handler("fanqie_video_plan")
        .expect("route fanqie_video_plan");
    let t = Instant::now();
    let seed = match plan(&srv.ctx, &pairs(&[])).await {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_plan_live.json", &s).ok();
            println!("[plan] ok in {:?}: len={}", t.elapsed(), s.len());
            let first = v
                .get("data")
                .and_then(|d| d.as_array())
                .and_then(|a| a.first())
                .cloned()
                .expect("plan data[0]");
            let cell = first
                .get("cell_id_str")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            let session = first
                .get("session_id")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            println!("[plan] cell_id_str={cell} session_id={session}");
            assert!(
                !cell.is_empty() && !session.is_empty(),
                "plan seed incomplete"
            );
            (cell, session)
        }
        Err(e) => {
            println!("[plan] ERR in {:?}: {}", t.elapsed(), e.message());
            panic!("fanqie_video_plan failed: {}", e.message());
        }
    };
    // Second leg: the untouched series_feed route, App first-page shape.
    let sf = srv.handler("series_feed").expect("route series_feed");
    let t2 = Instant::now();
    match sf(
        &srv.ctx,
        &pairs(&[
            ("cell_id", &seed.0),
            ("tab_type", "8"),
            ("client_template", "2"),
            ("client_req_type", "2"),
            ("offset", "0"),
            ("unlimited_selector_change_type", "2"),
            ("session_id", &seed.1),
            ("selected_items", "all"),
            ("sub_selected_items", "ranklist_hot_sc"),
        ]),
    )
    .await
    {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_series_feed_live.json", &s).ok();
            println!("[split-feed] ok in {:?}: len={}", t2.elapsed(), s.len());
            let videos = report_videos("split-feed", &v);
            if videos.is_empty() {
                println!("[split-feed] NOTE: cell/change returned no videos (plan first page is the fallback)");
            }
        }
        Err(e) => println!("[split-feed] ERR in {:?}: {}", t2.elapsed(), e.message()),
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_phoenix_raw_probe() {
    // The stream leg fails inside ParsedVideoResponse::parse with an empty
    // body. Probe the two raw POSTs directly to see which endpoint returns
    // empty (upstream/egress) and which returns JSON.
    use fqapi_core::endpoints::base::{
        dragon_read_json_headers, phoenix_player_headers, phoenix_player_url, Upstream,
        UpstreamMode, UpstreamRequestSpec,
    };
    let dir = TempDir::new("fanqie-phoenix-probe");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let vid = "7701937936731737112";

    let phoenix_body = serde_json::to_vec(&serde_json::json!({
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 3,
            "disable_digg_stat": false,
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "use_os_player": false,
            "use_server_dns": false,
            "video_platform": 1024,
        },
        "mixed_video_id_map": { "1004": [vid] },
    }))
    .unwrap();
    let t = Instant::now();
    match Upstream::new(srv.ctx.up.clone())
        .raw(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(phoenix_player_url()),
            body: Some(phoenix_body),
            headers: phoenix_player_headers(),
            ..Default::default()
        })
        .await
    {
        Ok(raw) => println!(
            "[phoenix-raw] ok in {:?}: len={} head={}",
            t.elapsed(),
            raw.len(),
            String::from_utf8_lossy(&raw[..raw.len().min(200)])
        ),
        Err(e) => println!("[phoenix-raw] ERR in {:?}: {}", t.elapsed(), e.message()),
    }

    let shortplay_body = serde_json::to_vec(&serde_json::json!({
        "video_id": vid,
        "content_type": 1004,
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 3,
            "disable_digg_stat": false,
            "disable_video_relate_book": false,
            "from_video_id": "",
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "source": 4,
            "use_os_player": false,
            "use_server_dns": false,
            "video_platform": 3,
        },
    }))
    .unwrap();
    let t2 = Instant::now();
    match Upstream::new(srv.ctx.up.clone())
        .raw(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some("https://api3-normal-sinfonlinea.fqnovel.com/novel/player/video_model/v1/?iid={install_id}&device_id={device_id}&aid=1967&app_name=novelapp&version_code=72132&version_name=7.2.1.32&device_platform=android&device_brand=Xiaomi&os_version=13&cdid={cdid}".to_string()),
            body: Some(shortplay_body),
            headers: dragon_read_json_headers(),
            ..Default::default()
        })
        .await
    {
        Ok(raw) => println!(
            "[shortplay-raw] ok in {:?}: len={} head={}",
            t2.elapsed(),
            raw.len(),
            String::from_utf8_lossy(&raw[..raw.len().min(200)])
        ),
        Err(e) => println!("[shortplay-raw] ERR in {:?}: {}", t2.elapsed(), e.message()),
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_fanqie_detail_play_danmaku() {
    let txt = std::fs::read_to_string("/tmp/fanqie_vid.txt")
        .expect("run live_fanqie_feed_combined first");
    let mut lines = txt.lines();
    let vid = lines.next().unwrap_or("").to_string();
    let sid = lines.next().unwrap_or("").to_string();
    assert!(
        !vid.is_empty() && !sid.is_empty(),
        "no vid in /tmp/fanqie_vid.txt"
    );
    println!("[detail] target: video_id={vid} series_id={sid}");

    let dir = TempDir::new("fanqie-detail-play");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    // Directory: the `directory` route Dart directoryChapters uses
    // (/api/v1/books/:id/directory), with the series id as book_id.
    let directory = srv.handler("directory").expect("route directory");
    let t = Instant::now();
    match directory(&srv.ctx, &pairs(&[("book_id", &sid)])).await {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_directory_live.json", &s).ok();
            println!("[directory] ok in {:?}: len={}", t.elapsed(), s.len());
            println!("[directory] head: {}", &s[..s.len().min(400)]);
        }
        Err(e) => println!("[directory] ERR in {:?}: {}", t.elapsed(), e.message()),
    }

    // Stream: first episode (the vid itself) in stream mode.
    let video = srv.handler("video").expect("route video");
    let t2 = Instant::now();
    match video(&srv.ctx, &pairs(&[("video_id", &vid), ("mode", "stream")])).await {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_video_live.json", &s).ok();
            println!("[stream] ok in {:?}: len={}", t2.elapsed(), s.len());
            let url = v
                .get("data")
                .and_then(|d| d.get("video_url"))
                .or_else(|| v.get("data").and_then(|d| d.get("main_url")))
                .and_then(|u| u.as_str())
                .unwrap_or("")
                .to_string();
            println!(
                "[stream] video_url: {}",
                if url.is_empty() {
                    "<empty>".into()
                } else {
                    format!(
                        "{}?... ({} chars)",
                        url.split('?').next().unwrap_or(""),
                        url.len()
                    )
                }
            );
            std::fs::write("/tmp/fanqie_play_url.txt", &url).ok();
            if url.is_empty() {
                println!("[stream] NOTE: no video_url (upstream video_model returns empty body; see live_phoenix_raw_probe)");
            }
        }
        Err(e) => {
            println!("[stream] ERR in {:?}: {} (upstream video_model returns empty body; see live_phoenix_raw_probe)", t2.elapsed(), e.message());
        }
    }

    // Danmaku still goes through the original endpoint.
    let dm = srv
        .handler("playlet_danmaku")
        .expect("route playlet_danmaku");
    let t3 = Instant::now();
    match dm(
        &srv.ctx,
        &pairs(&[
            ("vid", &vid),
            ("series_id", &sid),
            ("start_offset_time", "0"),
            ("playlet_item_duration", "60"),
        ]),
    )
    .await
    {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_danmaku_live.json", &s).ok();
            println!("[danmaku] ok in {:?}: len={}", t3.elapsed(), s.len());
            for k in ["comment_list", "danmaku_list", "comments"] {
                println!(
                    "[danmaku]   {k} occurrences: {}",
                    s.matches(&format!("\"{k}\"")).count()
                );
            }
            println!("[danmaku] head: {}", &s[..s.len().min(300)]);
        }
        Err(e) => println!("[danmaku] ERR in {:?}: {}", t3.elapsed(), e.message()),
    }
}
