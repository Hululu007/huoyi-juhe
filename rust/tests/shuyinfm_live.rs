//! 书音FM 真站冒烟测试。
//!
//! 默认不跑（`#[ignore]`），只在联调时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test shuyinfm_live -- --ignored --nocapture --test-threads=1
//! ```
//!
//! 注意串行跑：并行时站方会重置部分连接（search POST 与章节页曾
//! 因此报过请求错，串行即通），不是代码问题。
//!
//! 离线单测只能证明「解析与样本 HTML 一致」；这条链路验证的是另一半：
//! 官网是否真的按文档结构返回数据。2026-11-05 实测基线：分类 51 项；
//! 言情第 1 页 24 条（首条《花颜策》）；专辑 /album/1-126558.html
//! 370 集（首集“花颜策 001 我算哪门子的贤良淑德”）；搜“花颜策”2 条。
//! play 目前预期干净报错（服务端 HTML 里没有 #jp-Lines，见模块头）。

mod common;

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
#[ignore = "hits the live shuyinfm site"]
async fn live_categories() {
    let dir = TempDir::new("shuyinfm-live-cats");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_categories").expect("route");
    let value = handler(&srv.ctx, &pairs(&[("site_id", "shuyinfm")]))
        .await
        .expect("live categories must succeed");
    let cats = value["categories"].as_array().expect("categories");
    println!("categories: {}", cats.len());
    assert_eq!(cats.len(), 51, "category table must have 51 entries");
    assert!(
        cats.iter()
            .any(|c| c["id"] == "1" && c["name"] == "言情"),
        "言情 (id 1) must be present"
    );
}

#[tokio::test]
#[ignore = "hits the live shuyinfm site"]
async fn live_catalog_page1() {
    let dir = TempDir::new("shuyinfm-live-catalog");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_catalog").expect("route");
    let value = handler(
        &srv.ctx,
        &pairs(&[
            ("site_id", "shuyinfm"),
            ("category_id", "1"),
            ("page", "1"),
        ]),
    )
    .await
    .expect("live catalog must succeed");
    let items = value["items"].as_array().expect("items");
    println!("catalog page 1: {} items, has_more={}", items.len(), value["has_more"]);
    for item in items.iter().take(3) {
        println!(
            "  - {} | {} | {}",
            item["id"], item["title"], item["remark"]
        );
    }
    assert_eq!(items.len(), 24, "page 1 must have 24 items");
    assert_eq!(value["has_more"], true, "page 1 must have more");
    for item in items {
        assert!(!item["id"].as_str().unwrap_or("").is_empty());
        assert!(!item["title"].as_str().unwrap_or("").is_empty());
        assert!(!item["cover"].as_str().unwrap_or("").is_empty());
        assert!(item["id"].as_str().unwrap_or("").starts_with("/album/"));
    }
}

#[tokio::test]
#[ignore = "hits the live shuyinfm site"]
async fn live_detail() {
    let dir = TempDir::new("shuyinfm-live-detail");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_detail").expect("route");
    let value = handler(
        &srv.ctx,
        &pairs(&[("site_id", "shuyinfm"), ("id", "/album/1-126558.html")]),
    )
    .await
    .expect("live detail must succeed");
    println!(
        "detail: title={} cover={} teller={} episodes={}",
        value["title"],
        value["cover"],
        value["extra"]["teller"],
        value["episodes"].as_array().map(|e| e.len()).unwrap_or(0)
    );
    assert_eq!(value["title"], "花颜策");
    assert!(!value["cover"].as_str().unwrap_or("").is_empty());
    assert!(!value["synopsis"].as_str().unwrap_or("").is_empty());
    assert!(!value["extra"]["teller"].as_str().unwrap_or("").is_empty());
    let episodes = value["episodes"].as_array().expect("episodes");
    assert!(
        episodes.len() >= 300,
        "花颜策 must have hundreds of chapters, got {}",
        episodes.len()
    );
    let first = &episodes[0];
    assert_eq!(first["video_id"], "/audio/1-126558-0.html");
    assert_eq!(first["title"], "花颜策 001 我算哪门子的贤良淑德");
}

#[tokio::test]
#[ignore = "hits the live shuyinfm site"]
async fn live_search() {
    let dir = TempDir::new("shuyinfm-live-search");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_search").expect("route");
    let value = handler(
        &srv.ctx,
        &pairs(&[("site_id", "shuyinfm"), ("query", "花颜策")]),
    )
    .await
    .expect("live search must succeed");
    let items = value["items"].as_array().expect("items");
    println!("search 花颜策: {} items", items.len());
    for item in items.iter() {
        println!("  - {} | {}", item["id"], item["title"]);
    }
    assert!(!items.is_empty(), "search must return at least one item");
    assert!(
        items.iter().any(|i| i["title"] == "花颜策"),
        "search must find 花颜策"
    );
}

#[tokio::test]
#[ignore = "hits the live shuyinfm site"]
async fn live_play_fails_cleanly() {
    let dir = TempDir::new("shuyinfm-live-play");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_play").expect("route");
    // 当前已知状态：服务端 HTML 里没有 #jp-Lines，play 应干净报错，
    // 而不是崩溃或返回假地址。站方改版渲染线路列表后，此测试要改
    // 成断言拿到音频直链。
    let err = handler(
        &srv.ctx,
        &pairs(&[
            ("site_id", "shuyinfm"),
            ("episode_id", "/audio/1-126558-0.html"),
        ]),
    )
    .await
    .expect_err("live play is expected to fail cleanly for now");
    let msg = err.to_string();
    println!("play error (expected): {msg}");
    assert!(
        msg.contains("暂无可用的播放线路"),
        "play must fail with the known no-lines error, got: {msg}"
    );
}
