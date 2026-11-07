//! Live repro for the 11:42 screenshot: short drama titled "朝云", 8 episodes,
//! episode 1 fails with "视频解析失败" (decoding) on the round-15 build.
//!
//! Default ignored: hits the live fanqie upstream.
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test chaoyun_live -- --ignored --nocapture
//! ```
//!
//! Prints, per step, wall time + outcome so the network question can be
//! answered from the request layer (sent / stalled / error / bad payload).
//! Stream URLs are printed shape-only (host + suffix), never the full
//! signed query string.

mod common;

use std::time::Instant;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;

fn url_shape(url: &str) -> String {
    let no_query = url.split('?').next().unwrap_or(url);
    let host_end = no_query.find("://").map(|i| i + 3).unwrap_or(0);
    let rest = &no_query[host_end..];
    let host = rest.split('/').next().unwrap_or(rest);
    let suffix = if no_query.ends_with(".m3u8") {
        ".m3u8"
    } else if no_query.ends_with(".mp4") {
        ".mp4"
    } else {
        "(no media suffix)"
    };
    let has_query = if url.contains('?') { "+query" } else { "" };
    format!("{host} ... {suffix}{has_query}")
}

fn count_chapters(value: &serde_json::Value) -> (usize, Vec<(String, String)>) {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut total = 0usize;
    // parseDirectory fallback order: episodes, item_data_list, lists, item_list
    for key in ["episodes", "item_data_list", "lists", "item_list"] {
        if let Some(arr) = value
            .pointer(&format!("/data/{key}"))
            .and_then(|v| v.as_array())
        {
            if arr.is_empty() {
                continue;
            }
            total = arr.len();
            for ch in arr.iter().take(10) {
                let id = ch
                    .get("item_id")
                    .or_else(|| ch.get("itemId"))
                    .map(|v| v.to_string().trim_matches('"').to_string())
                    .unwrap_or_default();
                let title = ch
                    .get("chapter_name")
                    .or_else(|| ch.get("chapterName"))
                    .or_else(|| ch.get("title"))
                    .map(|v| v.to_string().trim_matches('"').to_string())
                    .unwrap_or_default();
                let extra = ch
                    .get("video_id")
                    .or_else(|| ch.get("videoId"))
                    .map(|v| format!(" video_id={v}"))
                    .unwrap_or_default();
                out.push((format!("{id}{extra}"), title));
            }
            println!("  entries from data.{key}: {total}");
            break;
        }
    }
    // also report the other lists' lengths for the record
    for key in [
        "episodes",
        "item_data_list",
        "lists",
        "item_list",
        "catalog_data",
    ] {
        if let Some(v) = value.pointer(&format!("/data/{key}")) {
            let n = v
                .as_array()
                .map(|a| a.len().to_string())
                .unwrap_or_else(|| {
                    v.as_object()
                        .map(|o| format!("map:{}", o.len()))
                        .unwrap_or_else(|| "?".into())
                });
            println!("  data.{key} = {n}");
        }
    }
    (total, out)
}

#[tokio::test]
#[ignore = "hits the live aisxpc upstream"]
async fn aisxpc_chaoyun_ep1() {
    let dir = TempDir::new("aisxpc-chaoyun");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    let detail = srv.handler("drama_detail").expect("route drama_detail");
    let t = Instant::now();
    let params = Params::from_pairs(vec![
        ("site_id".to_string(), "aisxpc".to_string()),
        ("id".to_string(), "/detail/1895/".to_string()),
    ]);
    let ep1 = match detail(&srv.ctx, &params).await {
        Ok(v) => {
            let title = v.get("title").and_then(|t| t.as_str()).unwrap_or("");
            let eps = v
                .get("episodes")
                .and_then(|e| e.as_array())
                .cloned()
                .unwrap_or_default();
            println!(
                "detail ok in {:?}: title={} episodes={}",
                t.elapsed(),
                title,
                eps.len()
            );
            for e in eps.iter().take(10) {
                println!(
                    "  ep title={} video_id={}",
                    e.get("title").and_then(|t| t.as_str()).unwrap_or(""),
                    e.get("video_id").and_then(|t| t.as_str()).unwrap_or("")
                );
            }
            eps.first()
                .and_then(|e| e.get("video_id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        }
        Err(e) => {
            println!("detail ERR in {:?}: {}", t.elapsed(), e.message());
            return;
        }
    };
    if ep1.is_empty() {
        println!("no episode video_id");
        return;
    }
    let play = srv.handler("drama_play").expect("route drama_play");
    let t = Instant::now();
    let params = Params::from_pairs(vec![
        ("site_id".to_string(), "aisxpc".to_string()),
        ("video_id".to_string(), ep1.clone()),
    ]);
    match play(&srv.ctx, &params).await {
        Ok(v) => {
            let url = v.get("url").and_then(|u| u.as_str()).unwrap_or("");
            let headers = v.get("headers").cloned().unwrap_or(serde_json::Value::Null);
            println!(
                "play({}) ok in {:?}: url_shape={} headers={}",
                ep1,
                t.elapsed(),
                url_shape(url),
                headers
            );
            assert!(
                headers.get("User-Agent").and_then(|h| h.as_str()).is_some_and(|h| !h.is_empty()),
                "aisxpc play must return a User-Agent header so Dart routes it through the local proxy"
            );
            // Full URL goes to stdout only in shape form; write the real
            // URL to a file for the follow-up curl probe (not printed).
            std::fs::write("/tmp/aisxpc_ep1_url.txt", url).ok();
        }
        Err(e) => {
            println!("play({}) ERR in {:?}: {}", ep1, t.elapsed(), e.message());
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn chaoyun_feed_scan() {
    let dir = TempDir::new("chaoyun-feed");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    let mut offset = "0".to_string();
    let mut session = String::new();
    for page in 0..6 {
        let t = Instant::now();
        let mut pairs = vec![
            ("tab_type".to_string(), "8".to_string()),
            ("offset".to_string(), offset.clone()),
        ];
        if !session.is_empty() {
            pairs.push(("session_id".to_string(), session.clone()));
        }
        let params = Params::from_pairs(pairs);
        match feed(&srv.ctx, &params).await {
            Ok(value) => {
                let s = serde_json::to_string(&value).unwrap_or_default();
                println!("feed page {page} ok in {:?}: len={}", t.elapsed(), s.len());
                let mut found = 0;
                for (i, _) in s.match_indices("朝云") {
                    found += 1;
                    let lo = i.saturating_sub(220);
                    let hi = (i + 220).min(s.len());
                    println!("  hit: ...{}...", &s[lo..hi].replace('\n', " "));
                    if found >= 4 {
                        break;
                    }
                }
                if found == 0 {
                    println!("  no 朝云 on this page");
                }
                // advance cursor from the tab_type=8 tab item
                let mut next: Option<(String, String)> = None;
                if let Some(tabs) = value
                    .get("data")
                    .and_then(|d| d.get("tab_item"))
                    .and_then(|v| v.as_array())
                {
                    for tab in tabs {
                        if tab.get("tab_type").and_then(|v| v.as_i64()) == Some(8) {
                            let no = tab
                                .get("next_offset")
                                .map(|v| v.to_string())
                                .unwrap_or_default();
                            let se = tab
                                .get("session_id")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            next = Some((no, se));
                        }
                    }
                }
                match next {
                    Some((no, se)) if !no.is_empty() && no != "0" => {
                        offset = no;
                        session = se;
                    }
                    _ => {
                        println!("  no next cursor, stop");
                        break;
                    }
                }
            }
            Err(e) => {
                println!("feed page {page} ERR in {:?}: {}", t.elapsed(), e.message());
                break;
            }
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn chaoyun_ep1_stream() {
    let dir = TempDir::new("chaoyun-live");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    let book_ids = ["7356889319191104574", "7593171429269441561"];
    for book_id in book_ids {
        println!("=== book {book_id} ===");
        // (b) fanqie web directory detail: /api/v1/books/<id>/directory/fanqie
        let book = srv.handler("book").expect("route book");
        let t = Instant::now();
        let params = Params::from_pairs(vec![("book_id".to_string(), book_id.to_string())]);
        match book(&srv.ctx, &params).await {
            Ok(value) => {
                let s = serde_json::to_string(&value).unwrap_or_default();
                let data_keys: Vec<&str> = value
                    .get("data")
                    .and_then(|d| d.as_object())
                    .map(|m| m.keys().map(|k| k.as_str()).collect())
                    .unwrap_or_default();
                println!(
                    "book(fanqie-dir) ok in {:?}: data_keys={data_keys:?} len={} head={}",
                    t.elapsed(),
                    s.len(),
                    &s[..s.len().min(400)]
                );
            }
            Err(e) => {
                println!("book(fanqie-dir) ERR in {:?}: {}", t.elapsed(), e.message());
            }
        }
        // (c) series video detail: /api/v1/videos/<id>/detail
        let vdetail = srv.handler("video_detail").expect("route video_detail");
        let t = Instant::now();
        let params = Params::from_pairs(vec![("series_id".to_string(), book_id.to_string())]);
        match vdetail(&srv.ctx, &params).await {
            Ok(value) => {
                let s = serde_json::to_string(&value).unwrap_or_default();
                println!(
                    "video_detail ok in {:?}: len={} head={}",
                    t.elapsed(),
                    s.len(),
                    &s[..s.len().min(400)]
                );
            }
            Err(e) => {
                println!("video_detail ERR in {:?}: {}", t.elapsed(), e.message());
            }
        }
        let directory = srv.handler("directory").expect("route directory");
        let t = Instant::now();
        let params = Params::from_pairs(vec![("book_id".to_string(), book_id.to_string())]);
        match directory(&srv.ctx, &params).await {
            Ok(value) => {
                let shape = {
                    let s = serde_json::to_string(&value).unwrap_or_default();
                    let keys: Vec<&str> = value
                        .as_object()
                        .map(|m| m.keys().map(|k| k.as_str()).collect())
                        .unwrap_or_default();
                    let data_keys: Vec<&str> = value
                        .get("data")
                        .and_then(|d| d.as_object())
                        .map(|m| m.keys().map(|k| k.as_str()).collect())
                        .unwrap_or_default();
                    format!(
                        "top_keys={keys:?} data_keys={data_keys:?} len={} head={}",
                        s.len(),
                        &s[..s.len().min(600)]
                    )
                };
                println!("directory(reading) ok in {:?}: {}", t.elapsed(), shape);
                let (total, first) = count_chapters(&value);
                println!(
                    "directory(reading) ok in {:?}: chapters={} first={:?}",
                    t.elapsed(),
                    total,
                    first
                );
                if total > 0 {
                    let (item_id, _) = first[0].clone();
                    let video = srv.handler("video").expect("route video");
                    let t2 = Instant::now();
                    let params = Params::from_pairs(vec![
                        ("video_id".to_string(), item_id.clone()),
                        ("mode".to_string(), "stream".to_string()),
                    ]);
                    match video(&srv.ctx, &params).await {
                        Ok(v) => {
                            let url = v.get("video_url").and_then(|u| u.as_str()).unwrap_or("");
                            let key = v.get("key_hex").and_then(|u| u.as_str()).unwrap_or("");
                            let variants = v
                                .get("variants")
                                .and_then(|u| u.as_array())
                                .map(|a| a.len())
                                .unwrap_or(0);
                            println!(
                                "video(mode=stream) ok in {:?}: url_shape={} key_hex_len={} variants={}",
                                t2.elapsed(),
                                url_shape(url),
                                key.len(),
                                variants
                            );
                            if let Some(vars) = v.get("variants").and_then(|u| u.as_array()) {
                                for var in vars.iter().take(5) {
                                    println!(
                                        "  variant name={} height={} url_shape={} key_hex_len={}",
                                        var.get("name").and_then(|n| n.as_str()).unwrap_or(""),
                                        var.get("height").and_then(|n| n.as_i64()).unwrap_or(-1),
                                        url_shape(
                                            var.get("url").and_then(|n| n.as_str()).unwrap_or("")
                                        ),
                                        var.get("key_hex")
                                            .and_then(|n| n.as_str())
                                            .map(|s| s.len())
                                            .unwrap_or(0),
                                    );
                                }
                            }
                        }
                        Err(e) => {
                            println!(
                                "video(mode=stream) ERR in {:?}: {}",
                                t2.elapsed(),
                                e.message()
                            );
                        }
                    }
                }
            }
            Err(e) => {
                println!(
                    "directory(reading) ERR in {:?}: {}",
                    t.elapsed(),
                    e.message()
                );
            }
        }
        let t = Instant::now();
        let params = Params::from_pairs(vec![
            ("book_id".to_string(), book_id.to_string()),
            ("api_type".to_string(), "novel".to_string()),
        ]);
        match directory(&srv.ctx, &params).await {
            Ok(value) => {
                let (total, first) = count_chapters(&value);
                println!(
                    "directory(novel) ok in {:?}: chapters={} first={:?}",
                    t.elapsed(),
                    total,
                    first
                );
            }
            Err(e) => {
                println!("directory(novel) ERR in {:?}: {}", t.elapsed(), e.message());
            }
        }
    }
}
