//! 第 20 轮任务二：阅读区 31 站现网解析探针（live probe）。
//!
//! 直接跑真实 Rust 解析器：每站 categories → 首分类 catalog(1) →
//! 首条 detail（+ 各类一个通用词 search），只打印计数与首条标题，
//! 不 assert 站方活着——站方挂了/改版/上 VIP 墙时测试本身不标红，
//! 结果看打印输出，由人按输出定修法。
//!
//! 只在显式触发时跑（#[ignore]），串行（站方会重置并行连接）：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test reading_live_probe -- --ignored --nocapture --test-threads=1
//! ```

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

/// （站 id，类型，通用搜索词）。
const SITES: &[(&str, &str, &str)] = &[
    // 小说 14
    ("1000novel", "novel", "重生"),
    ("69story", "novel", "重生"),
    ("aabook", "novel", "重生"),
    ("buliang", "novel", "人妻"),
    ("canovel", "novel", "重生"),
    ("cheniyo", "novel", "校园"),
    ("cjg", "novel", "人妻"),
    ("h528", "novel", "重生"),
    ("hwg4", "novel", "重生"),
    ("jywx2", "novel", "重生"),
    ("lbwen", "novel", "人妻"),
    ("ssxxs", "novel", "人妻"),
    ("ylxs", "novel", "重生"),
    ("yinse", "novel", "人妻"),
    // 漫画 11
    ("55comics", "comic", "斗罗"),
    ("csmanhua", "comic", "斗罗"),
    ("dongmanla", "comic", "斗罗"),
    ("ho5ho", "comic", "斗罗"),
    ("kmh001", "comic", "斗罗"),
    ("kuaikan", "comic", "斗罗"),
    ("kxmanhua", "comic", "斗罗"),
    ("mhbl", "comic", "斗罗"),
    ("modu18", "comic", "斗罗"),
    ("nnhanman", "comic", "斗罗"),
    ("tencent", "comic", "斗罗"),
    // 听书 6
    ("tingyou", "audio", "言情"),
    ("hsvoice31", "audio", "言情"),
    ("hysxs", "audio", "言情"),
    ("ximalaya", "audio", "言情"),
    ("hongguo", "audio", "言情"),
    ("shuyinfm", "audio", "言情"),
];

#[tokio::test]
#[ignore]
async fn live_probe_catalog_detail_search() {
    let dir = TempDir::new("reading-live-probe");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let cats = srv.handler("reading_categories").expect("route");
    let catalog = srv.handler("reading_catalog").expect("route");
    let detail = srv.handler("reading_detail").expect("route");
    let search = srv.handler("reading_search").expect("route");
    for (site_id, kind, query) in SITES {
        let t0 = std::time::Instant::now();
        let cat_value = match cats(
            &srv.ctx,
            &pairs(&[("site_id", site_id)]),
        )
        .await
        {
            Ok(v) => v,
            Err(e) => {
                println!("{site_id} ({kind}): CATEGORIES ERR {e} [{:?}]", t0.elapsed());
                continue;
            }
        };
        let cat_list = cat_value["categories"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let first_cat = cat_list
            .first()
            .and_then(|c| c["id"].as_str().map(str::to_string))
            .unwrap_or_default();
        let cat_out = match catalog(
            &srv.ctx,
            &pairs(&[
                ("site_id", site_id),
                ("category_id", &first_cat),
                ("page", "1"),
            ]),
        )
        .await
        {
            Ok(v) => v,
            Err(e) => {
                println!(
                    "{site_id} ({kind}): cats={} first={first_cat} CATALOG ERR {e} [{:?}]",
                    cat_list.len(),
                    t0.elapsed()
                );
                continue;
            }
        };
        let items = cat_out["items"].as_array().cloned().unwrap_or_default();
        let first_title = items
            .first()
            .and_then(|i| i["title"].as_str().map(str::to_string))
            .unwrap_or_default();
        let first_id = items
            .first()
            .and_then(|i| i["id"].as_str().map(str::to_string))
            .unwrap_or_default();
        let mut detail_out = String::new();
        if !first_id.is_empty() {
            match detail(
                &srv.ctx,
                &pairs(&[("site_id", site_id), ("id", &first_id)]),
            )
            .await
            {
                Ok(v) => {
                    let eps = v["episodes"].as_array().map(|a| a.len()).unwrap_or(0);
                    let title = v["title"].as_str().unwrap_or("");
                    detail_out = format!("detail title={title:?} eps={eps}");
                }
                Err(e) => detail_out = format!("DETAIL ERR {e}"),
            }
        }
        let search_n = match search(
            &srv.ctx,
            &pairs(&[("site_id", site_id), ("query", query)]),
        )
        .await
        {
            Ok(v) => v["items"]
                .as_array()
                .map(|a| a.len())
                .unwrap_or(0)
                .to_string(),
            Err(e) => format!("ERR {e}"),
        };
        println!(
            "{site_id} ({kind}): cats={} first={first_cat} catalog={} first={first_title:?} | {detail_out} | search[{query}]={search_n} [{:?}]",
            cat_list.len(),
            items.len(),
            t0.elapsed()
        );
    }
}

/// 复核首轮异常：目录 0 / 目录报错的三站重跑首分类 + 第二分类；
/// 搜索 0 的十站改用目录首条标题的前两个字再搜一次，区分“词无结果”
/// 与“搜索本身坏了”。只跑下面这张表里的站：
///
/// ```text
/// cargo test --manifest-path rust/Cargo.toml --test reading_live_probe -- --ignored --nocapture --test-threads=1 live_reprobe_anomalies
/// ```
#[tokio::test]
#[ignore]
async fn live_reprobe_anomalies() {
    let dir = TempDir::new("reading-live-reprobe");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let cats = srv.handler("reading_categories").expect("route");
    let catalog = srv.handler("reading_catalog").expect("route");
    let search = srv.handler("reading_search").expect("route");
    // （站 id，是否重跑目录，是否用标题词重搜）。
    const TARGETS: &[(&str, bool, bool)] = &[
        ("ssxxs", true, false),
        ("yinse", true, false),
        ("ximalaya", true, false),
        ("shuyinfm", true, false),
        ("69story", false, true),
        ("cheniyo", false, true),
        ("ho5ho", false, true),
        ("kmh001", false, true),
        ("modu18", false, true),
        ("nnhanman", false, true),
        ("tingyou", false, true),
        ("hsvoice31", false, true),
        ("hysxs", false, true),
        ("hongguo", false, true),
    ];
    for &(site_id, recat, research) in TARGETS {
        let t0 = std::time::Instant::now();
        let cat_value = match cats(&srv.ctx, &pairs(&[("site_id", site_id)])).await {
            Ok(v) => v,
            Err(e) => {
                println!("{site_id}: CATEGORIES ERR {e} [{:?}]", t0.elapsed());
                continue;
            }
        };
        let cat_list = cat_value["categories"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let mut out = format!("{site_id}: cats={}", cat_list.len());
        for (ci, cat) in cat_list.iter().take(2).enumerate() {
            if !recat && ci > 0 {
                break;
            }
            let cid = cat["id"].as_str().unwrap_or("");
            match catalog(
                &srv.ctx,
                &pairs(&[
                    ("site_id", site_id),
                    ("category_id", cid),
                    ("page", "1"),
                ]),
            )
            .await
            {
                Ok(v) => {
                    let items = v["items"].as_array().cloned().unwrap_or_default();
                    let first_title = items
                        .first()
                        .and_then(|i| i["title"].as_str().map(str::to_string))
                        .unwrap_or_default();
                    out += &format!(
                        " | cat[{cid}]={} first={first_title:?}",
                        items.len()
                    );
                    if research {
                        let kw: String = first_title.chars().take(2).collect();
                        if !kw.is_empty() {
                            match search(
                                &srv.ctx,
                                &pairs(&[("site_id", site_id), ("query", &kw)]),
                            )
                            .await
                            {
                                Ok(v) => {
                                    let n = v["items"]
                                        .as_array()
                                        .map(|a| a.len())
                                        .unwrap_or(0);
                                    out += &format!(" | search[{kw}]={n}");
                                }
                                Err(e) => out += &format!(" | search[{kw}] ERR {e}"),
                            }
                        }
                    }
                }
                Err(e) => out += &format!(" | cat[{cid}] ERR {e}"),
            }
        }
        println!("{out} [{:?}]", t0.elapsed());
    }
}
