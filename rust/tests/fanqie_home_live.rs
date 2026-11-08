//! 番茄原始短剧真站冒烟：首页 tab_type=8 的封面与耗时 + 取流。
//!
//! 默认不跑（`#[ignore]`），只在联调时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test fanqie_home_live -- --ignored --nocapture --test-threads=1
//! ```
//!
//! 查用户报的“原始版番茄不显示图片还卡”：首页回不回封面、回多少、
//! 耗时多久；再取第一条视频的流地址，看取流本身慢不慢。

mod common;

use std::time::Instant;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;

fn pairs(items: &[(&str, &str)]) -> Params {
    Params::from_pairs(
        items
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
    )
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_homepage_tab8() {
    let dir = TempDir::new("fanqie-home-tab8");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    let t = Instant::now();
    // App 实际发的就是本地顶栏下标：短剧在本地表 ['全部','小说','短剧',...]
    // 里是下标 2；只带 tab_type 不带 tab_index 时上游默认 0，只回推荐。
    let value = feed(
        &srv.ctx,
        &pairs(&[("tab_type", "8"), ("tab_index", "2"), ("offset", "0")]),
    )
    .await
    .expect("homepage tab_type=8 must succeed");
    let raw = serde_json::to_string(&value).unwrap_or_default();
    std::fs::write("/tmp/fanqie_home_tab8.json", &raw).ok();
    println!("homepage tab8 ok in {:?}: len={}", t.elapsed(), raw.len());

    // tab_item 标题一览
    if let Some(tabs) = value
        .get("data")
        .and_then(|d| d.get("tab_item"))
        .and_then(|v| v.as_array())
    {
        for tab in tabs {
            println!(
                "  tab: type={} title={}",
                tab.get("tab_type")
                    .map(|v| v.to_string())
                    .unwrap_or_default(),
                tab.get("title").and_then(|v| v.as_str()).unwrap_or("")
            );
        }
    }

    // tab_type=8 这一 tab 的 cell_data 里 video_data / series_cover 统计
    let mut tab8: Option<&serde_json::Value> = None;
    if let Some(tabs) = value
        .get("data")
        .and_then(|d| d.get("tab_item"))
        .and_then(|v| v.as_array())
    {
        for tab in tabs {
            if tab.get("tab_type").and_then(|v| v.as_i64()) == Some(8) {
                tab8 = Some(tab);
                break;
            }
        }
    }
    let Some(tab8) = tab8 else {
        println!("NO tab_type=8 tab_item in response");
        return;
    };
    let tab8s = serde_json::to_string(tab8).unwrap_or_default();
    std::fs::write("/tmp/fanqie_home_tab8_only.json", &tab8s).ok();
    let cells = tab8
        .get("cell_data")
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0);
    let video_data_n = tab8s.match_indices("\"video_data\"").count();
    let series_cover_n = tab8s.match_indices("series_cover").count();
    let thumb_url_n = tab8s.match_indices("thumb_url").count();
    let video_detail_n = tab8s.match_indices("video_detail").count();
    println!(
        "tab8: cell_data={} video_data_occ={} video_detail_occ={} series_cover_occ={} thumb_url_occ={}",
        cells, video_data_n, video_detail_n, series_cover_n, thumb_url_n
    );

    // 取前 3 个 video_id 与封面样例
    let mut shown = 0;
    if let Some(cells) = tab8.get("cell_data").and_then(|v| v.as_array()) {
        for cell in cells {
            if shown >= 3 {
                break;
            }
            if let Some(vds) = cell.get("video_data").and_then(|v| v.as_array()) {
                for vd in vds {
                    let vid = vd
                        .get("video_id")
                        .or_else(|| vd.get("series_id"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let cover = vd
                        .get("video_detail")
                        .and_then(|d| d.get("series_cover"))
                        .or_else(|| vd.get("series_cover"))
                        .or_else(|| vd.get("thumb_url"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if !vid.is_empty() {
                        println!("  sample: video_id={} cover={}", vid, cover);
                        shown += 1;
                        if shown >= 3 {
                            break;
                        }
                    }
                }
            }
        }
    }
    println!("samples shown: {}", shown);
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_video_content_first() {
    let raw = std::fs::read_to_string("/tmp/fanqie_home_tab8_only.json")
        .expect("run live_homepage_tab8 first");
    let tab8: serde_json::Value = serde_json::from_str(&raw).expect("parse tab8");
    let mut first_vid = String::new();
    if let Some(cells) = tab8.get("cell_data").and_then(|v| v.as_array()) {
        'outer: for cell in cells {
            if let Some(vds) = cell.get("video_data").and_then(|v| v.as_array()) {
                for vd in vds {
                    if let Some(vid) = vd.get("video_id").and_then(|v| v.as_str()) {
                        first_vid = vid.to_string();
                        break 'outer;
                    }
                }
            }
        }
    }
    assert!(!first_vid.is_empty(), "no video_id in tab8 payload");
    println!("first video_id={}", first_vid);

    let dir = TempDir::new("fanqie-video-first");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let video = srv.handler("video").expect("route video");
    let t = Instant::now();
    match video(
        &srv.ctx,
        &pairs(&[("video_id", &first_vid), ("mode", "stream")]),
    )
    .await
    {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_video_first.json", &s).ok();
            println!("video ok in {:?}: len={}", t.elapsed(), s.len());
            let url = v
                .get("data")
                .and_then(|d| d.get("video_url"))
                .or_else(|| v.get("data").and_then(|d| d.get("main_url")))
                .and_then(|u| u.as_str())
                .unwrap_or("");
            println!("video_url shape: {}", url_shape(url));
        }
        Err(e) => {
            println!("video ERR in {:?}: {}", t.elapsed(), e.message());
        }
    }
}

fn url_shape(url: &str) -> String {
    if url.is_empty() {
        return "<empty>".to_string();
    }
    match url.find('?') {
        Some(i) => format!("{}?... ({} chars)", &url[..i], url.len()),
        None => format!("{} ({} chars)", url, url.len()),
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_search_video_id() {
    // 搜一个短剧高频词，取一条 video_id + series_id，供弹幕/取流实测用。
    let dir = TempDir::new("fanqie-search-vid");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let search = srv.handler("search").expect("route search");
    let t = Instant::now();
    match search(
        &srv.ctx,
        &pairs(&[
            ("query", "重生"),
            ("search_type", "fanqie"),
            ("offset", "0"),
        ]),
    )
    .await
    {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_search.json", &s).ok();
            println!("search ok in {:?}: len={}", t.elapsed(), s.len());
            for k in [
                "video_id",
                "series_id",
                "series_cover",
                "thumb_url",
                "series_title",
                "book_id",
            ] {
                println!(
                    "  {} occurrences: {}",
                    k,
                    s.matches(&format!("\"{k}\"")).count()
                );
            }
            let mut found: Option<(String, String, String)> = None;
            fn walk(v: &serde_json::Value, out: &mut Option<(String, String, String)>) {
                if out.is_some() {
                    return;
                }
                match v {
                    serde_json::Value::Object(m) => {
                        let vid = m
                            .get("video_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let sid = match m.get("series_id") {
                            Some(serde_json::Value::String(s)) => s.clone(),
                            Some(serde_json::Value::Number(n)) => n.to_string(),
                            _ => String::new(),
                        };
                        let cover = m
                            .get("video_detail")
                            .and_then(|d| d.get("series_cover"))
                            .or_else(|| m.get("series_cover"))
                            .or_else(|| m.get("thumb_url"))
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        if !vid.is_empty() && !sid.is_empty() {
                            *out = Some((vid, sid, cover));
                            return;
                        }
                        for (_, val) in m {
                            walk(val, out);
                            if out.is_some() {
                                return;
                            }
                        }
                    }
                    serde_json::Value::Array(a) => {
                        for val in a {
                            walk(val, out);
                            if out.is_some() {
                                return;
                            }
                        }
                    }
                    _ => {}
                }
            }
            walk(&v, &mut found);
            match found {
                Some((vid, sid, cover)) => {
                    println!(
                        "  found: video_id={} series_id={} cover={}",
                        vid, sid, cover
                    );
                    std::fs::write("/tmp/fanqie_vid.txt", format!("{}\n{}", vid, sid)).ok();
                }
                None => println!("  no video_id+series_id in search response"),
            }
        }
        Err(e) => {
            println!("search ERR in {:?}: {}", t.elapsed(), e.message());
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_channel_tabs_video() {
    // 视频频道表（tab_type=16）：看上游还给不给视频流 cell。
    let dir = TempDir::new("fanqie-channel-tabs");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let tabs = srv.handler("channel_tabs").expect("route channel_tabs");
    let t = Instant::now();
    match tabs(
        &srv.ctx,
        &pairs(&[("tab_type", "16"), ("last_tab_type", "-1")]),
    )
    .await
    {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_channel_tabs.json", &s).ok();
            println!("channel_tabs ok in {:?}: len={}", t.elapsed(), s.len());
            for k in ["cell_id_str", "cell_id", "video", "tab_type", "title"] {
                println!(
                    "  {} occurrences: {}",
                    k,
                    s.matches(&format!("\"{k}\"")).count()
                );
            }
            println!("  head: {}", &s[..s.len().min(500)]);
        }
        Err(e) => {
            println!("channel_tabs ERR in {:?}: {}", t.elapsed(), e.message());
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_homepage_tab8_warm() {
    // 同 tab8，但把冷启动标记关掉（cold_start_session=0，
    // video_tab_cold_start=1，last_session_video_tab_type=8）：
    // 验证性别条带（推荐/男生/女生）是不是冷启动设备才回的默认条带。
    let dir = TempDir::new("fanqie-home-tab8-warm");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    let t = Instant::now();
    let value = feed(
        &srv.ctx,
        &pairs(&[
            ("tab_type", "8"),
            ("tab_index", "2"),
            ("offset", "0"),
            ("cold_start_session", "0"),
            ("cold_start_session_cnt_in_day", "0"),
            ("cold_start_session_cnt_in_life", "0"),
            ("video_tab_cold_start", "1"),
            ("last_session_video_tab_type", "8"),
        ]),
    )
    .await
    .expect("homepage tab_type=8 warm must succeed");
    let raw = serde_json::to_string(&value).unwrap_or_default();
    std::fs::write("/tmp/fanqie_home_tab8_warm.json", &raw).ok();
    println!(
        "homepage tab8 warm ok in {:?}: len={}",
        t.elapsed(),
        raw.len()
    );
    if let Some(tabs) = value
        .get("data")
        .and_then(|d| d.get("tab_item"))
        .and_then(|v| v.as_array())
    {
        for tab in tabs {
            let tt = tab.get("tab_type").and_then(|v| v.as_i64()).unwrap_or(-1);
            let title = tab.get("title").and_then(|v| v.as_str()).unwrap_or("");
            let s = serde_json::to_string(tab).unwrap_or_default();
            println!(
                "  tab: type={} title={} video_data_occ={} video_id_occ={}",
                tt,
                title,
                s.matches("\"video_data\"").count(),
                s.matches("\"video_id\"").count()
            );
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_homepage_client_template2() {
    // client_template=2（series_feed 用的模板值）：看 bookmall/tab
    // 在这个模板下回不回全量条带 / 视频 tab。
    let dir = TempDir::new("fanqie-home-ct2");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    for (tab_type, tab_index) in [("8", "2"), ("2", "0")] {
        let t = Instant::now();
        match feed(
            &srv.ctx,
            &pairs(&[
                ("tab_type", tab_type),
                ("tab_index", tab_index),
                ("offset", "0"),
                ("client_template", "2"),
            ]),
        )
        .await
        {
            Ok(v) => {
                let raw = serde_json::to_string(&v).unwrap_or_default();
                std::fs::write(format!("/tmp/fanqie_home_ct2_tab{tab_type}.json"), &raw).ok();
                println!(
                    "homepage tab_type={tab_type} ct2 ok in {:?}: len={}",
                    t.elapsed(),
                    raw.len()
                );
                if let Some(tabs) = v
                    .get("data")
                    .and_then(|d| d.get("tab_item"))
                    .and_then(|v| v.as_array())
                {
                    for tab in tabs {
                        let tt = tab.get("tab_type").and_then(|v| v.as_i64()).unwrap_or(-1);
                        let title = tab.get("title").and_then(|v| v.as_str()).unwrap_or("");
                        let s = serde_json::to_string(tab).unwrap_or_default();
                        println!(
                            "  tab: type={} title={} video_data_occ={}",
                            tt,
                            title,
                            s.matches("\"video_data\"").count()
                        );
                    }
                }
            }
            Err(e) => println!(
                "homepage tab_type={tab_type} ct2 ERR in {:?}: {}",
                t.elapsed(),
                e.message()
            ),
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_homepage_gender_tab() {
    // 直接点性别 tab（男生 tab_type=1/tab_index=1，女生 tab_type=0/
    // tab_index=2）：性别条带本身就是首屏选择器，选了之后上游
    // 可能回该性别的全量条带（含看剧 8 / 视频 16）。
    let dir = TempDir::new("fanqie-home-gender");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    for (tab_type, tab_index) in [("1", "1"), ("0", "2")] {
        let t = Instant::now();
        match feed(
            &srv.ctx,
            &pairs(&[
                ("tab_type", tab_type),
                ("tab_index", tab_index),
                ("offset", "0"),
            ]),
        )
        .await
        {
            Ok(v) => {
                let raw = serde_json::to_string(&v).unwrap_or_default();
                std::fs::write(format!("/tmp/fanqie_home_gender_tab{tab_type}.json"), &raw).ok();
                println!(
                    "homepage tab_type={tab_type} ok in {:?}: len={}",
                    t.elapsed(),
                    raw.len()
                );
                if let Some(tabs) = v
                    .get("data")
                    .and_then(|d| d.get("tab_item"))
                    .and_then(|v| v.as_array())
                {
                    for (i, tab) in tabs.iter().enumerate() {
                        let tt = tab.get("tab_type").and_then(|v| v.as_i64()).unwrap_or(-1);
                        let title = tab.get("title").and_then(|v| v.as_str()).unwrap_or("");
                        let cells = tab
                            .get("cell_data")
                            .and_then(|v| v.as_array())
                            .map(|a| a.len())
                            .unwrap_or(0);
                        let s = serde_json::to_string(tab).unwrap_or_default();
                        println!(
                            "  [{i}] type={tt} title={title} cells={cells} video_data_occ={}",
                            s.matches("\"video_data\"").count()
                        );
                    }
                }
                println!(
                    "  data.tab_index={}",
                    v.get("data")
                        .and_then(|d| d.get("tab_index"))
                        .map(|x| x.to_string())
                        .unwrap_or_default()
                );
            }
            Err(e) => println!(
                "homepage tab_type={tab_type} ERR in {:?}: {}",
                t.elapsed(),
                e.message()
            ),
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_homepage_tab2_strip() {
    // 推荐 tab（tab_type=2, tab_index=0）：看上游回不回 11 项全条带
    //（推荐/小说/经典/知识/听书/看剧/视频/短篇/漫画/新书/商城），
    //以及看剧(8)/视频(16)在条带里的下标——tab_index 错位可能是
    // tab8/tab16 只回性别条带的原因。
    let dir = TempDir::new("fanqie-home-tab2");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    let t = Instant::now();
    let value = feed(
        &srv.ctx,
        &pairs(&[("tab_type", "2"), ("tab_index", "0"), ("offset", "0")]),
    )
    .await
    .expect("homepage tab_type=2 must succeed");
    let raw = serde_json::to_string(&value).unwrap_or_default();
    std::fs::write("/tmp/fanqie_home_tab2.json", &raw).ok();
    println!("homepage tab2 ok in {:?}: len={}", t.elapsed(), raw.len());
    if let Some(tabs) = value
        .get("data")
        .and_then(|d| d.get("tab_item"))
        .and_then(|v| v.as_array())
    {
        for (i, tab) in tabs.iter().enumerate() {
            let tt = tab.get("tab_type").and_then(|v| v.as_i64()).unwrap_or(-1);
            let title = tab.get("title").and_then(|v| v.as_str()).unwrap_or("");
            let cells = tab
                .get("cell_data")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            println!("  [{i}] type={tt} title={title} cells={cells}");
        }
    }
    println!(
        "  data.tab_index={}",
        value
            .get("data")
            .and_then(|d| d.get("tab_index"))
            .map(|v| v.to_string())
            .unwrap_or_default()
    );
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_homepage_tab16_video() {
    // 书城「视频」tab（tab_type=16）：看它的 tab_item 里有没有 tab_type=16
    // 这一项、cell_data 里有没有 video_data；有就拿它的 cell_id_str 走
    // series_feed(tab_type=16) 看能不能拉出视频流。
    let dir = TempDir::new("fanqie-home-tab16");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv
        .handler("homepage_recommend")
        .expect("route homepage_recommend");
    let t = Instant::now();
    let value = feed(
        &srv.ctx,
        &pairs(&[("tab_type", "16"), ("tab_index", "7"), ("offset", "0")]),
    )
    .await
    .expect("homepage tab_type=16 must succeed");
    let raw = serde_json::to_string(&value).unwrap_or_default();
    std::fs::write("/tmp/fanqie_home_tab16.json", &raw).ok();
    println!("homepage tab16 ok in {:?}: len={}", t.elapsed(), raw.len());
    if let Some(tabs) = value
        .get("data")
        .and_then(|d| d.get("tab_item"))
        .and_then(|v| v.as_array())
    {
        for tab in tabs {
            let tt = tab.get("tab_type").and_then(|v| v.as_i64()).unwrap_or(-1);
            let title = tab.get("title").and_then(|v| v.as_str()).unwrap_or("");
            let cells = tab
                .get("cell_data")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            let s = serde_json::to_string(tab).unwrap_or_default();
            println!(
                "  tab: type={} title={} cells={} video_data_occ={} video_id_occ={} series_cover_occ={}",
                tt,
                title,
                cells,
                s.matches("\"video_data\"").count(),
                s.matches("\"video_id\"").count(),
                s.matches("series_cover").count()
            );
            if tt == 16 {
                std::fs::write("/tmp/fanqie_home_tab16_only.json", &s).ok();
            }
        }
    }
    // 取 tab_type=16 这一项的第一个 cell_id_str，走 series_feed。
    let mut cell = String::new();
    if let Some(tabs) = value
        .get("data")
        .and_then(|d| d.get("tab_item"))
        .and_then(|v| v.as_array())
    {
        for tab in tabs {
            if tab.get("tab_type").and_then(|v| v.as_i64()) != Some(16) {
                continue;
            }
            if let Some(cells) = tab.get("cell_data").and_then(|v| v.as_array()) {
                for c in cells {
                    if let Some(s) = c.get("cell_id_str").and_then(|v| v.as_str()) {
                        if !s.is_empty() {
                            cell = s.to_string();
                            println!(
                                "  tab16 cell: id_str={} show_type={} name={}",
                                cell,
                                c.get("show_type")
                                    .map(|v| v.to_string())
                                    .unwrap_or_default(),
                                c.get("cell_name").and_then(|v| v.as_str()).unwrap_or("")
                            );
                            break;
                        }
                    }
                }
            }
            break;
        }
    }
    if cell.is_empty() {
        println!("NO tab_type=16 cell found");
        return;
    }
    let sf = srv.handler("series_feed").expect("route series_feed");
    let t2 = Instant::now();
    match sf(
        &srv.ctx,
        &pairs(&[
            ("cell_id", &cell),
            ("tab_type", "16"),
            ("client_template", "2"),
            ("client_req_type", "2"),
            ("offset", "0"),
            ("unlimited_selector_change_type", "2"),
        ]),
    )
    .await
    {
        Ok(v) => {
            let s = serde_json::to_string(&v).unwrap_or_default();
            std::fs::write("/tmp/fanqie_series_feed_tab16.json", &s).ok();
            println!(
                "series_feed tab16 ok in {:?}: len={}",
                t2.elapsed(),
                s.len()
            );
            for k in [
                "video_id",
                "series_id",
                "series_cover",
                "thumb_url",
                "series_title",
                "video_data",
            ] {
                println!(
                    "  {} occurrences: {}",
                    k,
                    s.matches(&format!("\"{k}\"")).count()
                );
            }
            let data = v.get("data");
            println!(
                "  has_more={} next_offset={}",
                data.and_then(|d| d.get("has_more"))
                    .map(|x| x.to_string())
                    .unwrap_or_default(),
                data.and_then(|d| d.get("next_offset"))
                    .map(|x| x.to_string())
                    .unwrap_or_default()
            );
        }
        Err(e) => println!(
            "series_feed tab16 ERR in {:?}: {}",
            t2.elapsed(),
            e.message()
        ),
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_search_video_tab() {
    // 搜索「短剧」tab（tab_type=11）：看阅读搜索回不回视频条目
    //（video_id / series_id / series_cover），能否当短剧流的兜底来源。
    let dir = TempDir::new("fanqie-search-video");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let search = srv.handler("search").expect("route search");
    for tab in ["11", "1"] {
        let t = Instant::now();
        match search(
            &srv.ctx,
            &pairs(&[
                ("query", "重生"),
                ("offset", "0"),
                ("count", "10"),
                ("tab_type", tab),
            ]),
        )
        .await
        {
            Ok(v) => {
                let s = serde_json::to_string(&v).unwrap_or_default();
                std::fs::write(format!("/tmp/fanqie_search_tab{tab}.json"), &s).ok();
                println!(
                    "search tab_type={tab} ok in {:?}: len={}",
                    t.elapsed(),
                    s.len()
                );
                for k in [
                    "video_id",
                    "series_id",
                    "series_cover",
                    "thumb_url",
                    "series_title",
                    "book_id",
                    "title",
                ] {
                    println!(
                        "  {} occurrences: {}",
                        k,
                        s.matches(&format!("\"{k}\"")).count()
                    );
                }
                println!("  head: {}", &s[..s.len().min(300)]);
            }
            Err(e) => println!(
                "search tab_type={tab} ERR in {:?}: {}",
                t.elapsed(),
                e.message()
            ),
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_danmaku_first() {
    // 用搜索拿到的 video_id + series_id 测弹幕。
    let txt =
        std::fs::read_to_string("/tmp/fanqie_vid.txt").expect("run live_search_video_id first");
    let mut lines = txt.lines();
    let vid = lines.next().unwrap_or("").to_string();
    let sid = lines.next().unwrap_or("").to_string();
    assert!(
        !vid.is_empty() && !sid.is_empty(),
        "no vid in /tmp/fanqie_vid.txt"
    );
    println!("danmaku target: video_id={} series_id={}", vid, sid);

    let dir = TempDir::new("fanqie-danmaku-first");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let dm = srv
        .handler("playlet_danmaku")
        .expect("route playlet_danmaku");
    let t = Instant::now();
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
            std::fs::write("/tmp/fanqie_danmaku_first.json", &s).ok();
            println!("danmaku ok in {:?}: len={}", t.elapsed(), s.len());
            // 弹幕条数：数 data 里的评论/弹幕节点
            for k in ["comment_list", "danmaku_list", "comments", "data"] {
                println!(
                    "  {} occurrences: {}",
                    k,
                    s.matches(&format!("\"{k}\"")).count()
                );
            }
            println!("  head: {}", &s[..s.len().min(600)]);
        }
        Err(e) => {
            println!("danmaku ERR in {:?}: {}", t.elapsed(), e.message());
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_series_feed_tab8() {
    // 第一段回的第一个 cell_id_str（Dart 侧 _firstStringField 递归取到的
    // 就是这个值）+ 第一段的 session_id。
    let dir = TempDir::new("fanqie-series-feed");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let feed = srv.handler("series_feed").expect("route series_feed");
    let t = Instant::now();
    let res = feed(
        &srv.ctx,
        &pairs(&[
            ("cell_id", "7156181637888212999"),
            ("tab_type", "8"),
            ("client_template", "2"),
            ("client_req_type", "2"),
            ("offset", "0"),
            ("unlimited_selector_change_type", "2"),
            ("session_id", "20261107210733AE8ED3B0EA92C6A27A9E"),
        ]),
    )
    .await;
    let value = match res {
        Ok(v) => v,
        Err(e) => {
            println!("series_feed ERR in {:?}: {}", t.elapsed(), e.message());
            // 失败可能是出口抖动，重试一次
            let t2 = Instant::now();
            match feed(
                &srv.ctx,
                &pairs(&[
                    ("cell_id", "7156181637888212999"),
                    ("tab_type", "8"),
                    ("client_template", "2"),
                    ("client_req_type", "2"),
                    ("offset", "0"),
                    ("unlimited_selector_change_type", "2"),
                    ("session_id", "20261107210733AE8ED3B0EA92C6A27A9E"),
                ]),
            )
            .await
            {
                Ok(v) => {
                    println!("series_feed retry ok in {:?}", t2.elapsed());
                    v
                }
                Err(e2) => {
                    println!(
                        "series_feed retry ERR in {:?}: {}",
                        t2.elapsed(),
                        e2.message()
                    );
                    panic!("series_feed failed twice");
                }
            }
        }
    };
    let raw = serde_json::to_string(&value).unwrap_or_default();
    std::fs::write("/tmp/fanqie_series_feed.json", &raw).ok();
    println!(
        "series_feed tab8 ok in {:?}: len={}",
        t.elapsed(),
        raw.len()
    );
    for k in [
        "series_cover",
        "thumb_url",
        "video_data",
        "video_detail",
        "video_id",
        "series_id",
        "series_title",
    ] {
        println!(
            "  {} occurrences: {}",
            k,
            raw.matches(&format!("\"{k}\"")).count()
        );
    }
    // 前 3 条视频：video_id / series_id / 封面
    let mut shown = 0;
    if let Some(data) = value.get("data") {
        let s = serde_json::to_string(data).unwrap_or_default();
        let _ = s;
    }
    fn walk(v: &serde_json::Value, out: &mut Vec<(String, String, String)>) {
        if out.len() >= 3 {
            return;
        }
        match v {
            serde_json::Value::Object(m) => {
                let vid = m
                    .get("video_id")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let sid = match m.get("series_id") {
                    Some(serde_json::Value::String(s)) => s.clone(),
                    Some(serde_json::Value::Number(n)) => n.to_string(),
                    _ => String::new(),
                };
                let cover = m
                    .get("video_detail")
                    .and_then(|d| d.get("series_cover"))
                    .or_else(|| m.get("series_cover"))
                    .or_else(|| m.get("thumb_url"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                if !vid.is_empty() && out.iter().all(|(a, _, _)| *a != vid) {
                    out.push((vid, sid, cover));
                }
                for (_, val) in m {
                    walk(val, out);
                    if out.len() >= 3 {
                        return;
                    }
                }
            }
            serde_json::Value::Array(a) => {
                for val in a {
                    walk(val, out);
                    if out.len() >= 3 {
                        return;
                    }
                }
            }
            _ => {}
        }
    }
    let mut samples = Vec::new();
    walk(&value, &mut samples);
    for (vid, sid, cover) in &samples {
        println!(
            "  sample: video_id={} series_id={} cover={}",
            vid, sid, cover
        );
    }
    println!("samples shown: {}", samples.len());
}
