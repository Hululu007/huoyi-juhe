//! 阅读核心小说 14 + 听书 6 站分类核对测试。
//!
//! 2026-11-07 用户令「所有听书和小说都要有分类」后逐个核对：每站
//! `reading_categories` 必须回非空分类表（静态表照站导航写死，
//! 动态站红果除外，见下）。改分类表后跑这条即知哪站空了。
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test reading_categories -- --nocapture --test-threads=1
//! ```
//!
//! 红果（hongguo）分类是书城 tab=5 扫描卡片现取的，离线跑必失败，
//! 故单独放 `#[ignore]` 的真站测试里，只在联调时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test reading_categories -- --ignored --nocapture --test-threads=1 hongguo
//! ```
//!
//! 注意串行跑：并行时站方会重置部分连接，不是代码问题。

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

/// （站 id，类型，期望分类数，必含的一个分类名）。
const EXPECTED: &[(&str, &str, usize, &str)] = &[
    // 小说 14
    ("1000novel", "novel", 7, "都市生活"),
    ("69story", "novel", 5, "都市生活"),
    ("aabook", "novel", 18, "玄幻"),
    ("buliang", "novel", 20, "都市激情"),
    ("canovel", "novel", 9, "都市小品"),
    ("cheniyo", "novel", 5, "校园之恋"),
    ("cjg", "novel", 11, "都市"),
    ("h528", "novel", 12, "都市生活"),
    ("hwg4", "novel", 11, "都市"),
    ("jywx2", "novel", 11, "都市"),
    ("lbwen", "novel", 11, "都市"),
    ("ssxxs", "novel", 11, "都市激情"),
    ("ylxs", "novel", 4, "最新作品"),
    ("yinse", "novel", 19, "人妻熟女"),
    // 听书 6（红果除外，见 live_hongguo_categories）
    ("tingyou", "audio", 5, "热门"),
    ("hsvoice31", "audio", 4, "榜单"),
    ("hysxs", "audio", 2, "音声剧场"),
    ("ximalaya", "audio", 10, "有声书"),
    ("shuyinfm", "audio", 51, "言情"),
];

#[tokio::test]
async fn static_reading_categories_are_nonempty() {
    let dir = TempDir::new("reading-categories");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_categories").expect("route");
    for (site_id, kind, expected_len, must_contain) in EXPECTED {
        let value = handler(&srv.ctx, &pairs(&[("site_id", site_id)]))
            .await
            .unwrap_or_else(|e| panic!("{site_id} ({kind}) categories must succeed: {e}"));
        let cats = value["categories"]
            .as_array()
            .unwrap_or_else(|| panic!("{site_id} categories must be an array"));
        println!(
            "{site_id} ({kind}): {} categories: {}",
            cats.len(),
            cats.iter()
                .map(|c| c["name"].as_str().unwrap_or("?").to_string())
                .collect::<Vec<_>>()
                .join(" / ")
        );
        assert_eq!(
            cats.len(),
            *expected_len,
            "{site_id} category count changed (was {expected_len})"
        );
        assert!(
            cats.iter()
                .any(|c| c["name"].as_str() == Some(must_contain)),
            "{site_id} must contain category {must_contain}"
        );
        for c in cats {
            assert!(
                !c["id"].as_str().unwrap_or("").is_empty(),
                "{site_id} category id must not be empty"
            );
            assert!(
                !c["name"].as_str().unwrap_or("").is_empty(),
                "{site_id} category name must not be empty"
            );
        }
    }
}

#[tokio::test]
#[ignore = "hits the live hongguo bookmall api"]
async fn live_hongguo_categories() {
    let dir = TempDir::new("reading-categories-hongguo");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let handler = srv.handler("reading_categories").expect("route");
    let value = handler(&srv.ctx, &pairs(&[("site_id", "hongguo")]))
        .await
        .expect("live hongguo categories must succeed");
    let cats = value["categories"].as_array().expect("categories");
    println!(
        "hongguo (audio): {} categories: {}",
        cats.len(),
        cats.iter()
            .map(|c| c["name"].as_str().unwrap_or("?").to_string())
            .collect::<Vec<_>>()
            .join(" / ")
    );
    assert!(
        cats.iter()
            .any(|c| c["id"] == "audio" && c["name"] == "全部"),
        "hongguo first category must be 全部 (id audio)"
    );
    assert!(
        cats.len() >= 2,
        "hongguo must have real scan categories beyond 全部, got {}",
        cats.len()
    );
}
