//! 影视区：我方自有短剧站点的核心实现。
//!
//! 上游源码里没有影视区（它原来只有一个官方短剧站），所以这里是全新
//! 增加的模块，不改上游原有的任何端点、路由与数据。首批只进修复好能
//! 播的站：芽果、剧果、黄豆、野果、牛果；坏站（发果已死、花果手机
//! 问题未解、伍果要网页引擎）不进核心，仍留在 Dart 侧。
//!
//! 路由（全部走 query，不占路径段，与书旗一致）：
//! - `/api/v1/drama/categories?site_id=...`
//! - `/api/v1/drama/catalog?site_id=...&category_id=...&page=...`
//! - `/api/v1/drama/detail?site_id=...&id=...`
//! - `/api/v1/drama/search?site_id=...&query=...`
//! - `/api/v1/drama/play?site_id=...&video_id=...`
//!
//! 返回的 JSON 字段与 Dart 的 DramaSite* 模型一一对应（id/title/cover/
//! remark、episodes 的 video_id/title/series_id），Dart 侧只做直译，不
//! 再做字段归一。

mod abjav;
mod ai2026;
mod ai4k;
mod aidj;
mod aiduanju;
mod aimove;
mod airav;
mod aisxpc;
mod aiye;
mod aoxx69;
mod asextv;
#[path = "123av.rs"]
mod av123;
mod av18av;
mod av18avmcg;
mod av321;
mod av591;
mod av6k;
mod av91;
mod avbigplat;
mod avcnn;
mod avhwa;
mod avjoy;
mod avtoday;
mod avyanjiuyuan;
mod badyi;
mod caoliu;
mod chengren91;
mod chinax;
mod cporn;
mod crdj;
mod cucumber;
mod dage;
mod danai;
mod dayday;
mod ddys;
mod dingjiaseku;
mod dj69;
mod dj91;
mod djwo;
mod dsav;
mod dsd;
mod duanjuone;
mod fq;
mod fuchou;
mod getav;
mod go2av;
mod goodav;
mod gqck;
mod guzhuang;
mod haijiao;
mod haijiao4k;
mod hanime;
mod hbook;
mod hddj;
mod hduanju;
mod heitaoduanju;
mod henhenlu;
mod herexxx;
mod hgai;
mod hgaidj;
mod hgdj;
mod hgdj58;
mod hgdjv;
mod hgkpz;
mod hgtvim;
mod hjapp;
mod hjw;
mod hl365;
mod hohoj;
mod hongluo;
mod hongxing;
mod hongyan;
mod hsck;
mod huai;
mod huangduanju;
mod huangguazy;
mod huangguo;
mod huangguotv;
mod jable;
mod jack20;
mod japanwhores;
mod jav;
mod jav188;
mod jav777;
mod javdino;
mod javfun;
mod javgg;
mod javguru;
mod javhd;
mod javhdtube;
mod javher;
mod javmap;
mod javmit;
mod javplay;
mod javrate;
mod javsiri;
mod javtiful;
mod javtsunami;
mod javwine;
mod javzw;
mod jin18;
mod jiuse;
mod jiuseduanju;
#[path = "99jj.rs"]
mod jj99;
mod jm;
mod jptt;
mod juyin;
mod kissjav;
mod klxq;
mod km2;
mod koreanporn;
mod kuaihuo;
mod lissav;
mod lissavcn;
mod luoliai;
mod lxs;
mod madao;
mod madou;
mod md;
mod mianfeiai;
mod mirror;
mod missav;
mod missavoff;
mod missavt;
mod mjv011;
mod mmtv7;
mod mose365;
mod muzi;
mod mythav;
mod naihenda;
mod netflav;
mod nvdi;
mod okxxx;
mod pachub;
mod pandatv;
mod pb;
mod pigav;
mod pj5ti;
mod porna91;
mod porncgw;
mod pornhub;
mod ptt01;
mod px8x;
#[path = "17rip.rs"]
mod rip17;
mod roshy;
mod rou;
mod rouav;
mod rouvideo;
mod rscg91;
mod senzuri;
mod sex8;
mod sexkbj;
mod shaofu;
mod shunvqu;
mod shunvwang;
mod sihu;
mod sihucdn;
mod sporn;
mod ssis;
mod swagr;
mod taiav;
mod tanhua91;
mod taose;
mod thdh;
mod theporny;
mod tiktvod;
mod tinyav;
mod tokyomotion;
mod topjav;
mod toptv;
mod tudou;
mod txfans;
mod utube;
mod uudj;
#[path = "69vj.rs"]
mod vj69;
mod vjav;
mod wnzs;
mod wohs;
mod wukong;
mod wuyetv;
mod x51;
mod xanimu;
mod xhamster;
mod xhy11;
mod xianxia;
mod xingkongfuli;
mod xj;
mod xj2;
mod xjh5;
mod xlook;
mod xojav;
mod xszav;
mod xvideo;
mod xx01;
mod xx9;
mod yaguo;
mod yiren;
mod yunmeng;
mod ywmm;
mod zggjav;
mod zwdj;
mod zwwm;

use std::sync::OnceLock;
use std::time::Duration;

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

/// 影视区上游请求超时：与 Dart 侧 ApiClient 的默认超时一致。
const DRAMA_TIMEOUT_SECS: u64 = 20;

static DRAMA_CLIENT: OnceLock<Option<reqwest::Client>> = OnceLock::new();

/// 影视区共用的明文 HTTP 客户端（第三方站，无番茄设备签名，与 video.rs
/// 的 streaming_client 同款做法：懒建，建不出来时调用方如实报错）。
pub(crate) fn client() -> ApiResult<&'static reqwest::Client> {
    DRAMA_CLIENT
        .get_or_init(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
            reqwest::Client::builder()
                .timeout(Duration::from_secs(DRAMA_TIMEOUT_SECS))
                .build()
                .ok()
        })
        .as_ref()
        .ok_or_else(|| ApiError::Internal("drama client unavailable".into()))
}

/// 把 query 参数拼到 URL 上：reqwest 未开 `query` 特性，`RequestBuilder::query`
/// 不可用（cfg 掉了），这里用 url 的 form 编码手动拼，与 requests 的
/// params= 同款编码（空格成 `+`，中文成 %XX）。
pub(crate) fn with_query(url: &str, params: &[(&str, &str)]) -> String {
    if params.is_empty() {
        return url.to_string();
    }
    let mut out = String::with_capacity(url.len() + 64);
    out.push_str(url);
    out.push(if url.contains('?') { '&' } else { '?' });
    for (i, (k, v)) in params.iter().enumerate() {
        if i > 0 {
            out.push('&');
        }
        out.push_str(&url::form_urlencoded::byte_serialize(k.as_bytes()).collect::<String>());
        out.push('=');
        out.push_str(&url::form_urlencoded::byte_serialize(v.as_bytes()).collect::<String>());
    }
    out
}

pub fn register(s: &mut Server) {
    s.add_route("drama_categories", handle_categories);
    s.add_route("drama_catalog", handle_catalog);
    s.add_route("drama_detail", handle_detail);
    s.add_route("drama_search", handle_search);
    s.add_route("drama_play", handle_play);
}

/// JSON 对象取值：非对象一律视作缺失（与 Dart 的 _asMap 一致）。
pub(crate) fn obj_of(v: &Value) -> Option<&Map<String, Value>> {
    v.as_object()
}

/// JSON 对象里按 key 取值：非对象或无此 key 返回 None。
pub(crate) fn get<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object().and_then(|m| m.get(key))
}

/// JSON 数组取值：非数组返回 None。
pub(crate) fn arr_of(v: &Value) -> Option<&Vec<Value>> {
    v.as_array()
}

/// 标量转字符串：字符串去空白，数字/布尔按原样，null 与复合值为空
/// （与 Dart 的 _stringOf 对标量字段的行为一致）。
pub(crate) fn str_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// 按 key 顺序取第一个非空字符串（与 Dart 的 _firstString 一致）。
pub(crate) fn text_of(v: &Value, keys: &[&str]) -> String {
    let Some(m) = v.as_object() else {
        return String::new();
    };
    for key in keys {
        if let Some(value) = m.get(*key) {
            let s = str_of(value);
            if !s.is_empty() {
                return s;
            }
        }
    }
    String::new()
}

/// 按 key 顺序取第一个整数：JSON 数字直接取整，字符串解析，皆无则 0
/// （与 Dart 的 _firstInt 一致）。
pub(crate) fn int_of(v: &Value, keys: &[&str]) -> i64 {
    let Some(m) = v.as_object() else {
        return 0;
    };
    for key in keys {
        if let Some(value) = m.get(*key) {
            match value {
                Value::Number(n) => {
                    if let Some(i) = n.as_i64() {
                        return i;
                    }
                    if let Some(u) = n.as_u64() {
                        return u as i64;
                    }
                    if let Some(f) = n.as_f64() {
                        return f as i64;
                    }
                }
                Value::String(s) => {
                    if let Ok(i) = s.trim().parse::<i64>() {
                        return i;
                    }
                }
                _ => {}
            }
        }
    }
    0
}

/// 分类卡片：与 Dart 的 DramaSiteCategory(id, name) 对应。
pub(crate) fn category_json(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

/// 视频卡片：与 Dart 的 DramaSiteItem(id, title, cover, remark) 对应。
pub(crate) fn item_json(id: &str, title: &str, cover: &str, remark: &str) -> Value {
    json!({"id": id, "title": title, "cover": cover, "remark": remark})
}

/// 分集：与 Dart 的 DramaSiteEpisode(video_id, title, series_id) 对应。
pub(crate) fn episode_json(video_id: &str, title: &str, series_id: &str) -> Value {
    json!({"video_id": video_id, "title": title, "series_id": series_id})
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
            "yaguo" => yaguo::categories().await,
            "123av" => av123::categories().await,
            "17rip" => rip17::categories().await,
            "321av" => av321::categories().await,
            "591av" => av591::categories().await,
            "69vj" => vj69::categories().await,
            "99jj" => jj99::categories().await,
            "abjav" => abjav::categories().await,
            "ai2026" => ai2026::categories().await,
            "ai4k" => ai4k::categories().await,
            "aidj" => aidj::categories().await,
            "aiduanju" => aiduanju::categories().await,
            "aimove" => aimove::categories().await,
            "airav" => airav::categories().await,
            "aisxpc" => aisxpc::categories().await,
            "aiye" => aiye::categories().await,
            "aoxx69" => aoxx69::categories().await,
            "asextv" => asextv::categories().await,
            "av18av" => av18av::categories().await,
            "av18avmcg" => av18avmcg::categories().await,
            "av6k" => av6k::categories().await,
            "av91" => av91::categories().await,
            "avbigplat" => avbigplat::categories().await,
            "avcnn" => avcnn::categories().await,
            "avhwa" => avhwa::categories().await,
            "avjoy" => avjoy::categories().await,
            "avtoday" => avtoday::categories().await,
            "avyanjiuyuan" => avyanjiuyuan::categories().await,
            "badyi" => badyi::categories().await,
            "caoliu" => caoliu::categories().await,
            "chengren91" => chengren91::categories().await,
            "chinax" => chinax::categories().await,
            "cporn" => cporn::categories().await,
            "crdj" => crdj::categories().await,
            "cucumber" => cucumber::categories().await,
            "dage" => dage::categories().await,
            "danai" => danai::categories().await,
            "dayday" => dayday::categories().await,
            "ddys" => ddys::categories().await,
            "dingjiaseku" => dingjiaseku::categories().await,
            "dj69" => dj69::categories().await,
            "dj91" => dj91::categories().await,
            "djwo" => djwo::categories().await,
            "dsav" => dsav::categories().await,
            "dsd" => dsd::categories().await,
            "duanjuone" => duanjuone::categories().await,
            "fq" => fq::categories().await,
            "fuchou" => fuchou::categories().await,
            "getav" => getav::categories().await,
            "go2av" => go2av::categories().await,
            "goodav" => goodav::categories().await,
            "gqck" => gqck::categories().await,
            "guzhuang" => guzhuang::categories().await,
            "haijiao" => haijiao::categories().await,
            "haijiao4k" => haijiao4k::categories().await,
            "hanime" => hanime::categories().await,
            "hbook" => hbook::categories().await,
            "hddj" => hddj::categories().await,
            "hduanju" => hduanju::categories().await,
            "heitaoduanju" => heitaoduanju::categories().await,
            "henhenlu" => henhenlu::categories().await,
            "herexxx" => herexxx::categories().await,
            "hgai" => hgai::categories().await,
            "hgaidj" => hgaidj::categories().await,
            "hgdj" => hgdj::categories().await,
            "hgdj58" => hgdj58::categories().await,
            "hgdjv" => hgdjv::categories().await,
            "hgkpz" => hgkpz::categories().await,
            "hgtvim" => hgtvim::categories().await,
            "hjapp" => hjapp::categories().await,
            "hjw" => hjw::categories().await,
            "hl365" => hl365::categories().await,
            "hohoj" => hohoj::categories().await,
            "hongxing" => hongxing::categories().await,
            "hongyan" => hongyan::categories().await,
            "hongluo" => hongluo::categories().await,
            "hsck" => hsck::categories().await,
            "huai" => huai::categories().await,
            "huangduanju" => huangduanju::categories().await,
            "huangguazy" => huangguazy::categories().await,
            "huangguo" => huangguo::categories().await,
            "huangguotv" => huangguotv::categories().await,
            "jable" => jable::categories().await,
            "jack20" => jack20::categories().await,
            "japanwhores" => japanwhores::categories().await,
            "jav" => jav::categories().await,
            "jav188" => jav188::categories().await,
            "jav777" => jav777::categories().await,
            "javdino" => javdino::categories().await,
            "javfun" => javfun::categories().await,
            "javgg" => javgg::categories().await,
            "javguru" => javguru::categories().await,
            "javhd" => javhd::categories().await,
            "javhdtube" => javhdtube::categories().await,
            "javher" => javher::categories().await,
            "javmap" => javmap::categories().await,
            "javmit" => javmit::categories().await,
            "javplay" => javplay::categories().await,
            "javrate" => javrate::categories().await,
            "javsiri" => javsiri::categories().await,
            "javtiful" => javtiful::categories().await,
            "javtsunami" => javtsunami::categories().await,
            "javwine" => javwine::categories().await,
            "javzw" => javzw::categories().await,
            "jin18" => jin18::categories().await,
            "jiuse" => jiuse::categories().await,
            "jiuseduanju" => jiuseduanju::categories().await,
            "jm" => jm::categories().await,
            "jptt" => jptt::categories().await,
            "juyin" => juyin::categories().await,
            "kissjav" => kissjav::categories().await,
            "klxq" => klxq::categories().await,
            "km2" => km2::categories().await,
            "koreanporn" => koreanporn::categories().await,
            "kuaihuo" => kuaihuo::categories().await,
            "lissav" => lissav::categories().await,
            "lissavcn" => lissavcn::categories().await,
            "luoliai" => luoliai::categories().await,
            "lxs" => lxs::categories().await,
            "madao" => madao::categories().await,
            "madou" => madou::categories().await,
            "md" => md::categories().await,
            "mianfeiai" => mianfeiai::categories().await,
            "mirror" => mirror::categories().await,
            "missav" => missav::categories().await,
            "missavoff" => missavoff::categories().await,
            "missavt" => missavt::categories().await,
            "mjv011" => mjv011::categories().await,
            "mmtv7" => mmtv7::categories().await,
            "mose365" => mose365::categories().await,
            "muzi" => muzi::categories().await,
            "mythav" => mythav::categories().await,
            "naihenda" => naihenda::categories().await,
            "netflav" => netflav::categories().await,
            "nvdi" => nvdi::categories().await,
            "okxxx" => okxxx::categories().await,
            "pachub" => pachub::categories().await,
            "pandatv" => pandatv::categories().await,
            "pb" => pb::categories().await,
            "pigav" => pigav::categories().await,
            "pj5ti" => pj5ti::categories().await,
            "porna91" => porna91::categories().await,
            "porncgw" => porncgw::categories().await,
            "pornhub" => pornhub::categories().await,
            "ptt01" => ptt01::categories().await,
            "px8x" => px8x::categories().await,
            "roshy" => roshy::categories().await,
            "rou" => rou::categories().await,
            "rouav" => rouav::categories().await,
            "rouvideo" => rouvideo::categories().await,
            "rscg91" => rscg91::categories().await,
            "senzuri" => senzuri::categories().await,
            "sex8" => sex8::categories().await,
            "sexkbj" => sexkbj::categories().await,
            "shaofu" => shaofu::categories().await,
            "shunvqu" => shunvqu::categories().await,
            "shunvwang" => shunvwang::categories().await,
            "sihu" => sihu::categories().await,
            "sihucdn" => sihucdn::categories().await,
            "sporn" => sporn::categories().await,
            "ssis" => ssis::categories().await,
            "swagr" => swagr::categories().await,
            "taiav" => taiav::categories().await,
            "tanhua91" => tanhua91::categories().await,
            "taose" => taose::categories().await,
            "thdh" => thdh::categories().await,
            "theporny" => theporny::categories().await,
            "tiktvod" => tiktvod::categories().await,
            "tinyav" => tinyav::categories().await,
            "tokyomotion" => tokyomotion::categories().await,
            "topjav" => topjav::categories().await,
            "toptv" => toptv::categories().await,
            "tudou" => tudou::categories().await,
            "txfans" => txfans::categories().await,
            "utube" => utube::categories().await,
            "uudj" => uudj::categories().await,
            "vjav" => vjav::categories().await,
            "wnzs" => wnzs::categories().await,
            "wohs" => wohs::categories().await,
            "wukong" => wukong::categories().await,
            "wuyetv" => wuyetv::categories().await,
            "x51" => x51::categories().await,
            "xanimu" => xanimu::categories().await,
            "xhamster" => xhamster::categories().await,
            "xhy11" => xhy11::categories().await,
            "xianxia" => xianxia::categories().await,
            "xingkongfuli" => xingkongfuli::categories().await,
            "xj" => xj::categories().await,
            "xj2" => xj2::categories().await,
            "xjh5" => xjh5::categories().await,
            "xlook" => xlook::categories().await,
            "xojav" => xojav::categories().await,
            "xszav" => xszav::categories().await,
            "xvideo" => xvideo::categories().await,
            "xx01" => xx01::categories().await,
            "xx9" => xx9::categories().await,
            "yiren" => yiren::categories().await,
            "yunmeng" => yunmeng::categories().await,
            "ywmm" => ywmm::categories().await,
            "zggjav" => zggjav::categories().await,
            "zwdj" => zwdj::categories().await,
            "zwwm" => zwwm::categories().await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}

fn handle_catalog<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let category_id = params.get_str("category_id");
    let page = page_of(params);
    Box::pin(async move {
        match site?.as_str() {
            "yaguo" => yaguo::catalog(&category_id, page).await,
            "123av" => av123::catalog(&category_id, page).await,
            "17rip" => rip17::catalog(&category_id, page).await,
            "321av" => av321::catalog(&category_id, page).await,
            "591av" => av591::catalog(&category_id, page).await,
            "69vj" => vj69::catalog(&category_id, page).await,
            "99jj" => jj99::catalog(&category_id, page).await,
            "abjav" => abjav::catalog(&category_id, page).await,
            "ai2026" => ai2026::catalog(&category_id, page).await,
            "ai4k" => ai4k::catalog(&category_id, page).await,
            "aidj" => aidj::catalog(&category_id, page).await,
            "aiduanju" => aiduanju::catalog(&category_id, page).await,
            "aimove" => aimove::catalog(&category_id, page).await,
            "airav" => airav::catalog(&category_id, page).await,
            "aisxpc" => aisxpc::catalog(&category_id, page).await,
            "aiye" => aiye::catalog(&category_id, page).await,
            "aoxx69" => aoxx69::catalog(&category_id, page).await,
            "asextv" => asextv::catalog(&category_id, page).await,
            "av18av" => av18av::catalog(&category_id, page).await,
            "av18avmcg" => av18avmcg::catalog(&category_id, page).await,
            "av6k" => av6k::catalog(&category_id, page).await,
            "av91" => av91::catalog(&category_id, page).await,
            "avbigplat" => avbigplat::catalog(&category_id, page).await,
            "avcnn" => avcnn::catalog(&category_id, page).await,
            "avhwa" => avhwa::catalog(&category_id, page).await,
            "avjoy" => avjoy::catalog(&category_id, page).await,
            "avtoday" => avtoday::catalog(&category_id, page).await,
            "avyanjiuyuan" => avyanjiuyuan::catalog(&category_id, page).await,
            "badyi" => badyi::catalog(&category_id, page).await,
            "caoliu" => caoliu::catalog(&category_id, page).await,
            "chengren91" => chengren91::catalog(&category_id, page).await,
            "chinax" => chinax::catalog(&category_id, page).await,
            "cporn" => cporn::catalog(&category_id, page).await,
            "crdj" => crdj::catalog(&category_id, page).await,
            "cucumber" => cucumber::catalog(&category_id, page).await,
            "dage" => dage::catalog(&category_id, page).await,
            "danai" => danai::catalog(&category_id, page).await,
            "dayday" => dayday::catalog(&category_id, page).await,
            "ddys" => ddys::catalog(&category_id, page).await,
            "dingjiaseku" => dingjiaseku::catalog(&category_id, page).await,
            "dj69" => dj69::catalog(&category_id, page).await,
            "dj91" => dj91::catalog(&category_id, page).await,
            "djwo" => djwo::catalog(&category_id, page).await,
            "dsav" => dsav::catalog(&category_id, page).await,
            "dsd" => dsd::catalog(&category_id, page).await,
            "duanjuone" => duanjuone::catalog(&category_id, page).await,
            "fq" => fq::catalog(&category_id, page).await,
            "fuchou" => fuchou::catalog(&category_id, page).await,
            "getav" => getav::catalog(&category_id, page).await,
            "go2av" => go2av::catalog(&category_id, page).await,
            "goodav" => goodav::catalog(&category_id, page).await,
            "gqck" => gqck::catalog(&category_id, page).await,
            "guzhuang" => guzhuang::catalog(&category_id, page).await,
            "haijiao" => haijiao::catalog(&category_id, page).await,
            "haijiao4k" => haijiao4k::catalog(&category_id, page).await,
            "hanime" => hanime::catalog(&category_id, page).await,
            "hbook" => hbook::catalog(&category_id, page).await,
            "hddj" => hddj::catalog(&category_id, page).await,
            "hduanju" => hduanju::catalog(&category_id, page).await,
            "heitaoduanju" => heitaoduanju::catalog(&category_id, page).await,
            "henhenlu" => henhenlu::catalog(&category_id, page).await,
            "herexxx" => herexxx::catalog(&category_id, page).await,
            "hgai" => hgai::catalog(&category_id, page).await,
            "hgaidj" => hgaidj::catalog(&category_id, page).await,
            "hgdj" => hgdj::catalog(&category_id, page).await,
            "hgdj58" => hgdj58::catalog(&category_id, page).await,
            "hgdjv" => hgdjv::catalog(&category_id, page).await,
            "hgkpz" => hgkpz::catalog(&category_id, page).await,
            "hgtvim" => hgtvim::catalog(&category_id, page).await,
            "hjapp" => hjapp::catalog(&category_id, page).await,
            "hjw" => hjw::catalog(&category_id, page).await,
            "hl365" => hl365::catalog(&category_id, page).await,
            "hohoj" => hohoj::catalog(&category_id, page).await,
            "hongxing" => hongxing::catalog(&category_id, page).await,
            "hongyan" => hongyan::catalog(&category_id, page).await,
            "hongluo" => hongluo::catalog(&category_id, page).await,
            "hsck" => hsck::catalog(&category_id, page).await,
            "huai" => huai::catalog(&category_id, page).await,
            "huangduanju" => huangduanju::catalog(&category_id, page).await,
            "huangguazy" => huangguazy::catalog(&category_id, page).await,
            "huangguo" => huangguo::catalog(&category_id, page).await,
            "huangguotv" => huangguotv::catalog(&category_id, page).await,
            "jable" => jable::catalog(&category_id, page).await,
            "jack20" => jack20::catalog(&category_id, page).await,
            "japanwhores" => japanwhores::catalog(&category_id, page).await,
            "jav" => jav::catalog(&category_id, page).await,
            "jav188" => jav188::catalog(&category_id, page).await,
            "jav777" => jav777::catalog(&category_id, page).await,
            "javdino" => javdino::catalog(&category_id, page).await,
            "javfun" => javfun::catalog(&category_id, page).await,
            "javgg" => javgg::catalog(&category_id, page).await,
            "javguru" => javguru::catalog(&category_id, page).await,
            "javhd" => javhd::catalog(&category_id, page).await,
            "javhdtube" => javhdtube::catalog(&category_id, page).await,
            "javher" => javher::catalog(&category_id, page).await,
            "javmap" => javmap::catalog(&category_id, page).await,
            "javmit" => javmit::catalog(&category_id, page).await,
            "javplay" => javplay::catalog(&category_id, page).await,
            "javrate" => javrate::catalog(&category_id, page).await,
            "javsiri" => javsiri::catalog(&category_id, page).await,
            "javtiful" => javtiful::catalog(&category_id, page).await,
            "javtsunami" => javtsunami::catalog(&category_id, page).await,
            "javwine" => javwine::catalog(&category_id, page).await,
            "javzw" => javzw::catalog(&category_id, page).await,
            "jin18" => jin18::catalog(&category_id, page).await,
            "jiuse" => jiuse::catalog(&category_id, page).await,
            "jiuseduanju" => jiuseduanju::catalog(&category_id, page).await,
            "jm" => jm::catalog(&category_id, page).await,
            "jptt" => jptt::catalog(&category_id, page).await,
            "juyin" => juyin::catalog(&category_id, page).await,
            "kissjav" => kissjav::catalog(&category_id, page).await,
            "klxq" => klxq::catalog(&category_id, page).await,
            "km2" => km2::catalog(&category_id, page).await,
            "koreanporn" => koreanporn::catalog(&category_id, page).await,
            "kuaihuo" => kuaihuo::catalog(&category_id, page).await,
            "lissav" => lissav::catalog(&category_id, page).await,
            "lissavcn" => lissavcn::catalog(&category_id, page).await,
            "luoliai" => luoliai::catalog(&category_id, page).await,
            "lxs" => lxs::catalog(&category_id, page).await,
            "madao" => madao::catalog(&category_id, page).await,
            "madou" => madou::catalog(&category_id, page).await,
            "md" => md::catalog(&category_id, page).await,
            "mianfeiai" => mianfeiai::catalog(&category_id, page).await,
            "mirror" => mirror::catalog(&category_id, page).await,
            "missav" => missav::catalog(&category_id, page).await,
            "missavoff" => missavoff::catalog(&category_id, page).await,
            "missavt" => missavt::catalog(&category_id, page).await,
            "mjv011" => mjv011::catalog(&category_id, page).await,
            "mmtv7" => mmtv7::catalog(&category_id, page).await,
            "mose365" => mose365::catalog(&category_id, page).await,
            "muzi" => muzi::catalog(&category_id, page).await,
            "mythav" => mythav::catalog(&category_id, page).await,
            "naihenda" => naihenda::catalog(&category_id, page).await,
            "netflav" => netflav::catalog(&category_id, page).await,
            "nvdi" => nvdi::catalog(&category_id, page).await,
            "okxxx" => okxxx::catalog(&category_id, page).await,
            "pachub" => pachub::catalog(&category_id, page).await,
            "pandatv" => pandatv::catalog(&category_id, page).await,
            "pb" => pb::catalog(&category_id, page).await,
            "pigav" => pigav::catalog(&category_id, page).await,
            "pj5ti" => pj5ti::catalog(&category_id, page).await,
            "porna91" => porna91::catalog(&category_id, page).await,
            "porncgw" => porncgw::catalog(&category_id, page).await,
            "pornhub" => pornhub::catalog(&category_id, page).await,
            "ptt01" => ptt01::catalog(&category_id, page).await,
            "px8x" => px8x::catalog(&category_id, page).await,
            "roshy" => roshy::catalog(&category_id, page).await,
            "rou" => rou::catalog(&category_id, page).await,
            "rouav" => rouav::catalog(&category_id, page).await,
            "rouvideo" => rouvideo::catalog(&category_id, page).await,
            "rscg91" => rscg91::catalog(&category_id, page).await,
            "senzuri" => senzuri::catalog(&category_id, page).await,
            "sex8" => sex8::catalog(&category_id, page).await,
            "sexkbj" => sexkbj::catalog(&category_id, page).await,
            "shaofu" => shaofu::catalog(&category_id, page).await,
            "shunvqu" => shunvqu::catalog(&category_id, page).await,
            "shunvwang" => shunvwang::catalog(&category_id, page).await,
            "sihu" => sihu::catalog(&category_id, page).await,
            "sihucdn" => sihucdn::catalog(&category_id, page).await,
            "sporn" => sporn::catalog(&category_id, page).await,
            "ssis" => ssis::catalog(&category_id, page).await,
            "swagr" => swagr::catalog(&category_id, page).await,
            "taiav" => taiav::catalog(&category_id, page).await,
            "tanhua91" => tanhua91::catalog(&category_id, page).await,
            "taose" => taose::catalog(&category_id, page).await,
            "thdh" => thdh::catalog(&category_id, page).await,
            "theporny" => theporny::catalog(&category_id, page).await,
            "tiktvod" => tiktvod::catalog(&category_id, page).await,
            "tinyav" => tinyav::catalog(&category_id, page).await,
            "tokyomotion" => tokyomotion::catalog(&category_id, page).await,
            "topjav" => topjav::catalog(&category_id, page).await,
            "toptv" => toptv::catalog(&category_id, page).await,
            "tudou" => tudou::catalog(&category_id, page).await,
            "txfans" => txfans::catalog(&category_id, page).await,
            "utube" => utube::catalog(&category_id, page).await,
            "uudj" => uudj::catalog(&category_id, page).await,
            "vjav" => vjav::catalog(&category_id, page).await,
            "wnzs" => wnzs::catalog(&category_id, page).await,
            "wohs" => wohs::catalog(&category_id, page).await,
            "wukong" => wukong::catalog(&category_id, page).await,
            "wuyetv" => wuyetv::catalog(&category_id, page).await,
            "x51" => x51::catalog(&category_id, page).await,
            "xanimu" => xanimu::catalog(&category_id, page).await,
            "xhamster" => xhamster::catalog(&category_id, page).await,
            "xhy11" => xhy11::catalog(&category_id, page).await,
            "xianxia" => xianxia::catalog(&category_id, page).await,
            "xingkongfuli" => xingkongfuli::catalog(&category_id, page).await,
            "xj" => xj::catalog(&category_id, page).await,
            "xj2" => xj2::catalog(&category_id, page).await,
            "xjh5" => xjh5::catalog(&category_id, page).await,
            "xlook" => xlook::catalog(&category_id, page).await,
            "xojav" => xojav::catalog(&category_id, page).await,
            "xszav" => xszav::catalog(&category_id, page).await,
            "xvideo" => xvideo::catalog(&category_id, page).await,
            "xx01" => xx01::catalog(&category_id, page).await,
            "xx9" => xx9::catalog(&category_id, page).await,
            "yiren" => yiren::catalog(&category_id, page).await,
            "yunmeng" => yunmeng::catalog(&category_id, page).await,
            "ywmm" => ywmm::catalog(&category_id, page).await,
            "zggjav" => zggjav::catalog(&category_id, page).await,
            "zwdj" => zwdj::catalog(&category_id, page).await,
            "zwwm" => zwwm::catalog(&category_id, page).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
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
            "yaguo" => yaguo::detail(&id).await,
            "123av" => av123::detail(&id).await,
            "17rip" => rip17::detail(&id).await,
            "321av" => av321::detail(&id).await,
            "591av" => av591::detail(&id).await,
            "69vj" => vj69::detail(&id).await,
            "99jj" => jj99::detail(&id).await,
            "abjav" => abjav::detail(&id).await,
            "ai2026" => ai2026::detail(&id).await,
            "ai4k" => ai4k::detail(&id).await,
            "aidj" => aidj::detail(&id).await,
            "aiduanju" => aiduanju::detail(&id).await,
            "aimove" => aimove::detail(&id).await,
            "airav" => airav::detail(&id).await,
            "aisxpc" => aisxpc::detail(&id).await,
            "aiye" => aiye::detail(&id).await,
            "aoxx69" => aoxx69::detail(&id).await,
            "asextv" => asextv::detail(&id).await,
            "av18av" => av18av::detail(&id).await,
            "av18avmcg" => av18avmcg::detail(&id).await,
            "av6k" => av6k::detail(&id).await,
            "av91" => av91::detail(&id).await,
            "avbigplat" => avbigplat::detail(&id).await,
            "avcnn" => avcnn::detail(&id).await,
            "avhwa" => avhwa::detail(&id).await,
            "avjoy" => avjoy::detail(&id).await,
            "avtoday" => avtoday::detail(&id).await,
            "avyanjiuyuan" => avyanjiuyuan::detail(&id).await,
            "badyi" => badyi::detail(&id).await,
            "caoliu" => caoliu::detail(&id).await,
            "chengren91" => chengren91::detail(&id).await,
            "chinax" => chinax::detail(&id).await,
            "cporn" => cporn::detail(&id).await,
            "crdj" => crdj::detail(&id).await,
            "cucumber" => cucumber::detail(&id).await,
            "dage" => dage::detail(&id).await,
            "danai" => danai::detail(&id).await,
            "dayday" => dayday::detail(&id).await,
            "ddys" => ddys::detail(&id).await,
            "dingjiaseku" => dingjiaseku::detail(&id).await,
            "dj69" => dj69::detail(&id).await,
            "dj91" => dj91::detail(&id).await,
            "djwo" => djwo::detail(&id).await,
            "dsav" => dsav::detail(&id).await,
            "dsd" => dsd::detail(&id).await,
            "duanjuone" => duanjuone::detail(&id).await,
            "fq" => fq::detail(&id).await,
            "fuchou" => fuchou::detail(&id).await,
            "getav" => getav::detail(&id).await,
            "go2av" => go2av::detail(&id).await,
            "goodav" => goodav::detail(&id).await,
            "gqck" => gqck::detail(&id).await,
            "guzhuang" => guzhuang::detail(&id).await,
            "haijiao" => haijiao::detail(&id).await,
            "haijiao4k" => haijiao4k::detail(&id).await,
            "hanime" => hanime::detail(&id).await,
            "hbook" => hbook::detail(&id).await,
            "hddj" => hddj::detail(&id).await,
            "hduanju" => hduanju::detail(&id).await,
            "heitaoduanju" => heitaoduanju::detail(&id).await,
            "henhenlu" => henhenlu::detail(&id).await,
            "herexxx" => herexxx::detail(&id).await,
            "hgai" => hgai::detail(&id).await,
            "hgaidj" => hgaidj::detail(&id).await,
            "hgdj" => hgdj::detail(&id).await,
            "hgdj58" => hgdj58::detail(&id).await,
            "hgdjv" => hgdjv::detail(&id).await,
            "hgkpz" => hgkpz::detail(&id).await,
            "hgtvim" => hgtvim::detail(&id).await,
            "hjapp" => hjapp::detail(&id).await,
            "hjw" => hjw::detail(&id).await,
            "hl365" => hl365::detail(&id).await,
            "hohoj" => hohoj::detail(&id).await,
            "hongxing" => hongxing::detail(&id).await,
            "hongyan" => hongyan::detail(&id).await,
            "hongluo" => hongluo::detail(&id).await,
            "hsck" => hsck::detail(&id).await,
            "huai" => huai::detail(&id).await,
            "huangduanju" => huangduanju::detail(&id).await,
            "huangguazy" => huangguazy::detail(&id).await,
            "huangguo" => huangguo::detail(&id).await,
            "huangguotv" => huangguotv::detail(&id).await,
            "jable" => jable::detail(&id).await,
            "jack20" => jack20::detail(&id).await,
            "japanwhores" => japanwhores::detail(&id).await,
            "jav" => jav::detail(&id).await,
            "jav188" => jav188::detail(&id).await,
            "jav777" => jav777::detail(&id).await,
            "javdino" => javdino::detail(&id).await,
            "javfun" => javfun::detail(&id).await,
            "javgg" => javgg::detail(&id).await,
            "javguru" => javguru::detail(&id).await,
            "javhd" => javhd::detail(&id).await,
            "javhdtube" => javhdtube::detail(&id).await,
            "javher" => javher::detail(&id).await,
            "javmap" => javmap::detail(&id).await,
            "javmit" => javmit::detail(&id).await,
            "javplay" => javplay::detail(&id).await,
            "javrate" => javrate::detail(&id).await,
            "javsiri" => javsiri::detail(&id).await,
            "javtiful" => javtiful::detail(&id).await,
            "javtsunami" => javtsunami::detail(&id).await,
            "javwine" => javwine::detail(&id).await,
            "javzw" => javzw::detail(&id).await,
            "jin18" => jin18::detail(&id).await,
            "jiuse" => jiuse::detail(&id).await,
            "jiuseduanju" => jiuseduanju::detail(&id).await,
            "jm" => jm::detail(&id).await,
            "jptt" => jptt::detail(&id).await,
            "juyin" => juyin::detail(&id).await,
            "kissjav" => kissjav::detail(&id).await,
            "klxq" => klxq::detail(&id).await,
            "km2" => km2::detail(&id).await,
            "koreanporn" => koreanporn::detail(&id).await,
            "kuaihuo" => kuaihuo::detail(&id).await,
            "lissav" => lissav::detail(&id).await,
            "lissavcn" => lissavcn::detail(&id).await,
            "luoliai" => luoliai::detail(&id).await,
            "lxs" => lxs::detail(&id).await,
            "madao" => madao::detail(&id).await,
            "madou" => madou::detail(&id).await,
            "md" => md::detail(&id).await,
            "mianfeiai" => mianfeiai::detail(&id).await,
            "mirror" => mirror::detail(&id).await,
            "missav" => missav::detail(&id).await,
            "missavoff" => missavoff::detail(&id).await,
            "missavt" => missavt::detail(&id).await,
            "mjv011" => mjv011::detail(&id).await,
            "mmtv7" => mmtv7::detail(&id).await,
            "mose365" => mose365::detail(&id).await,
            "muzi" => muzi::detail(&id).await,
            "mythav" => mythav::detail(&id).await,
            "naihenda" => naihenda::detail(&id).await,
            "netflav" => netflav::detail(&id).await,
            "nvdi" => nvdi::detail(&id).await,
            "okxxx" => okxxx::detail(&id).await,
            "pachub" => pachub::detail(&id).await,
            "pandatv" => pandatv::detail(&id).await,
            "pb" => pb::detail(&id).await,
            "pigav" => pigav::detail(&id).await,
            "pj5ti" => pj5ti::detail(&id).await,
            "porna91" => porna91::detail(&id).await,
            "porncgw" => porncgw::detail(&id).await,
            "pornhub" => pornhub::detail(&id).await,
            "ptt01" => ptt01::detail(&id).await,
            "px8x" => px8x::detail(&id).await,
            "roshy" => roshy::detail(&id).await,
            "rou" => rou::detail(&id).await,
            "rouav" => rouav::detail(&id).await,
            "rouvideo" => rouvideo::detail(&id).await,
            "rscg91" => rscg91::detail(&id).await,
            "senzuri" => senzuri::detail(&id).await,
            "sex8" => sex8::detail(&id).await,
            "sexkbj" => sexkbj::detail(&id).await,
            "shaofu" => shaofu::detail(&id).await,
            "shunvqu" => shunvqu::detail(&id).await,
            "shunvwang" => shunvwang::detail(&id).await,
            "sihu" => sihu::detail(&id).await,
            "sihucdn" => sihucdn::detail(&id).await,
            "sporn" => sporn::detail(&id).await,
            "ssis" => ssis::detail(&id).await,
            "swagr" => swagr::detail(&id).await,
            "taiav" => taiav::detail(&id).await,
            "tanhua91" => tanhua91::detail(&id).await,
            "taose" => taose::detail(&id).await,
            "thdh" => thdh::detail(&id).await,
            "theporny" => theporny::detail(&id).await,
            "tiktvod" => tiktvod::detail(&id).await,
            "tinyav" => tinyav::detail(&id).await,
            "tokyomotion" => tokyomotion::detail(&id).await,
            "topjav" => topjav::detail(&id).await,
            "toptv" => toptv::detail(&id).await,
            "tudou" => tudou::detail(&id).await,
            "txfans" => txfans::detail(&id).await,
            "utube" => utube::detail(&id).await,
            "uudj" => uudj::detail(&id).await,
            "vjav" => vjav::detail(&id).await,
            "wnzs" => wnzs::detail(&id).await,
            "wohs" => wohs::detail(&id).await,
            "wukong" => wukong::detail(&id).await,
            "wuyetv" => wuyetv::detail(&id).await,
            "x51" => x51::detail(&id).await,
            "xanimu" => xanimu::detail(&id).await,
            "xhamster" => xhamster::detail(&id).await,
            "xhy11" => xhy11::detail(&id).await,
            "xianxia" => xianxia::detail(&id).await,
            "xingkongfuli" => xingkongfuli::detail(&id).await,
            "xj" => xj::detail(&id).await,
            "xj2" => xj2::detail(&id).await,
            "xjh5" => xjh5::detail(&id).await,
            "xlook" => xlook::detail(&id).await,
            "xojav" => xojav::detail(&id).await,
            "xszav" => xszav::detail(&id).await,
            "xvideo" => xvideo::detail(&id).await,
            "xx01" => xx01::detail(&id).await,
            "xx9" => xx9::detail(&id).await,
            "yiren" => yiren::detail(&id).await,
            "yunmeng" => yunmeng::detail(&id).await,
            "ywmm" => ywmm::detail(&id).await,
            "zggjav" => zggjav::detail(&id).await,
            "zwdj" => zwdj::detail(&id).await,
            "zwwm" => zwwm::detail(&id).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
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
            "yaguo" => yaguo::search(&query).await,
            "123av" => av123::search(&query).await,
            "17rip" => rip17::search(&query).await,
            "321av" => av321::search(&query).await,
            "591av" => av591::search(&query).await,
            "69vj" => vj69::search(&query).await,
            "99jj" => jj99::search(&query).await,
            "abjav" => abjav::search(&query).await,
            "ai2026" => ai2026::search(&query).await,
            "ai4k" => ai4k::search(&query).await,
            "aidj" => aidj::search(&query).await,
            "aiduanju" => aiduanju::search(&query).await,
            "aimove" => aimove::search(&query).await,
            "airav" => airav::search(&query).await,
            "aisxpc" => aisxpc::search(&query).await,
            "aiye" => aiye::search(&query).await,
            "aoxx69" => aoxx69::search(&query).await,
            "asextv" => asextv::search(&query).await,
            "av18av" => av18av::search(&query).await,
            "av18avmcg" => av18avmcg::search(&query).await,
            "av6k" => av6k::search(&query).await,
            "av91" => av91::search(&query).await,
            "avbigplat" => avbigplat::search(&query).await,
            "avcnn" => avcnn::search(&query).await,
            "avhwa" => avhwa::search(&query).await,
            "avjoy" => avjoy::search(&query).await,
            "avtoday" => avtoday::search(&query).await,
            "avyanjiuyuan" => avyanjiuyuan::search(&query).await,
            "badyi" => badyi::search(&query).await,
            "caoliu" => caoliu::search(&query).await,
            "chengren91" => chengren91::search(&query).await,
            "chinax" => chinax::search(&query).await,
            "cporn" => cporn::search(&query).await,
            "crdj" => crdj::search(&query).await,
            "cucumber" => cucumber::search(&query).await,
            "dage" => dage::search(&query).await,
            "danai" => danai::search(&query).await,
            "dayday" => dayday::search(&query).await,
            "ddys" => ddys::search(&query).await,
            "dingjiaseku" => dingjiaseku::search(&query).await,
            "dj69" => dj69::search(&query).await,
            "dj91" => dj91::search(&query).await,
            "djwo" => djwo::search(&query).await,
            "dsav" => dsav::search(&query).await,
            "dsd" => dsd::search(&query).await,
            "duanjuone" => duanjuone::search(&query).await,
            "fq" => fq::search(&query).await,
            "fuchou" => fuchou::search(&query).await,
            "getav" => getav::search(&query).await,
            "go2av" => go2av::search(&query).await,
            "goodav" => goodav::search(&query).await,
            "gqck" => gqck::search(&query).await,
            "guzhuang" => guzhuang::search(&query).await,
            "haijiao" => haijiao::search(&query).await,
            "haijiao4k" => haijiao4k::search(&query).await,
            "hanime" => hanime::search(&query).await,
            "hbook" => hbook::search(&query).await,
            "hddj" => hddj::search(&query).await,
            "hduanju" => hduanju::search(&query).await,
            "heitaoduanju" => heitaoduanju::search(&query).await,
            "henhenlu" => henhenlu::search(&query).await,
            "herexxx" => herexxx::search(&query).await,
            "hgai" => hgai::search(&query).await,
            "hgaidj" => hgaidj::search(&query).await,
            "hgdj" => hgdj::search(&query).await,
            "hgdj58" => hgdj58::search(&query).await,
            "hgdjv" => hgdjv::search(&query).await,
            "hgkpz" => hgkpz::search(&query).await,
            "hgtvim" => hgtvim::search(&query).await,
            "hjapp" => hjapp::search(&query).await,
            "hjw" => hjw::search(&query).await,
            "hl365" => hl365::search(&query).await,
            "hohoj" => hohoj::search(&query).await,
            "hongxing" => hongxing::search(&query).await,
            "hongyan" => hongyan::search(&query).await,
            "hongluo" => hongluo::search(&query).await,
            "hsck" => hsck::search(&query).await,
            "huai" => huai::search(&query).await,
            "huangduanju" => huangduanju::search(&query).await,
            "huangguazy" => huangguazy::search(&query).await,
            "huangguo" => huangguo::search(&query).await,
            "huangguotv" => huangguotv::search(&query).await,
            "jable" => jable::search(&query).await,
            "jack20" => jack20::search(&query).await,
            "japanwhores" => japanwhores::search(&query).await,
            "jav" => jav::search(&query).await,
            "jav188" => jav188::search(&query).await,
            "jav777" => jav777::search(&query).await,
            "javdino" => javdino::search(&query).await,
            "javfun" => javfun::search(&query).await,
            "javgg" => javgg::search(&query).await,
            "javguru" => javguru::search(&query).await,
            "javhd" => javhd::search(&query).await,
            "javhdtube" => javhdtube::search(&query).await,
            "javher" => javher::search(&query).await,
            "javmap" => javmap::search(&query).await,
            "javmit" => javmit::search(&query).await,
            "javplay" => javplay::search(&query).await,
            "javrate" => javrate::search(&query).await,
            "javsiri" => javsiri::search(&query).await,
            "javtiful" => javtiful::search(&query).await,
            "javtsunami" => javtsunami::search(&query).await,
            "javwine" => javwine::search(&query).await,
            "javzw" => javzw::search(&query).await,
            "jin18" => jin18::search(&query).await,
            "jiuse" => jiuse::search(&query).await,
            "jiuseduanju" => jiuseduanju::search(&query).await,
            "jm" => jm::search(&query).await,
            "jptt" => jptt::search(&query).await,
            "juyin" => juyin::search(&query).await,
            "kissjav" => kissjav::search(&query).await,
            "klxq" => klxq::search(&query).await,
            "km2" => km2::search(&query).await,
            "koreanporn" => koreanporn::search(&query).await,
            "kuaihuo" => kuaihuo::search(&query).await,
            "lissav" => lissav::search(&query).await,
            "lissavcn" => lissavcn::search(&query).await,
            "luoliai" => luoliai::search(&query).await,
            "lxs" => lxs::search(&query).await,
            "madao" => madao::search(&query).await,
            "madou" => madou::search(&query).await,
            "md" => md::search(&query).await,
            "mianfeiai" => mianfeiai::search(&query).await,
            "mirror" => mirror::search(&query).await,
            "missav" => missav::search(&query).await,
            "missavoff" => missavoff::search(&query).await,
            "missavt" => missavt::search(&query).await,
            "mjv011" => mjv011::search(&query).await,
            "mmtv7" => mmtv7::search(&query).await,
            "mose365" => mose365::search(&query).await,
            "muzi" => muzi::search(&query).await,
            "mythav" => mythav::search(&query).await,
            "naihenda" => naihenda::search(&query).await,
            "netflav" => netflav::search(&query).await,
            "nvdi" => nvdi::search(&query).await,
            "okxxx" => okxxx::search(&query).await,
            "pachub" => pachub::search(&query).await,
            "pandatv" => pandatv::search(&query).await,
            "pb" => pb::search(&query).await,
            "pigav" => pigav::search(&query).await,
            "pj5ti" => pj5ti::search(&query).await,
            "porna91" => porna91::search(&query).await,
            "porncgw" => porncgw::search(&query).await,
            "pornhub" => pornhub::search(&query).await,
            "ptt01" => ptt01::search(&query).await,
            "px8x" => px8x::search(&query).await,
            "roshy" => roshy::search(&query).await,
            "rou" => rou::search(&query).await,
            "rouav" => rouav::search(&query).await,
            "rouvideo" => rouvideo::search(&query).await,
            "rscg91" => rscg91::search(&query).await,
            "senzuri" => senzuri::search(&query).await,
            "sex8" => sex8::search(&query).await,
            "sexkbj" => sexkbj::search(&query).await,
            "shaofu" => shaofu::search(&query).await,
            "shunvqu" => shunvqu::search(&query).await,
            "shunvwang" => shunvwang::search(&query).await,
            "sihu" => sihu::search(&query).await,
            "sihucdn" => sihucdn::search(&query).await,
            "sporn" => sporn::search(&query).await,
            "ssis" => ssis::search(&query).await,
            "swagr" => swagr::search(&query).await,
            "taiav" => taiav::search(&query).await,
            "tanhua91" => tanhua91::search(&query).await,
            "taose" => taose::search(&query).await,
            "thdh" => thdh::search(&query).await,
            "theporny" => theporny::search(&query).await,
            "tiktvod" => tiktvod::search(&query).await,
            "tinyav" => tinyav::search(&query).await,
            "tokyomotion" => tokyomotion::search(&query).await,
            "topjav" => topjav::search(&query).await,
            "toptv" => toptv::search(&query).await,
            "tudou" => tudou::search(&query).await,
            "txfans" => txfans::search(&query).await,
            "utube" => utube::search(&query).await,
            "uudj" => uudj::search(&query).await,
            "vjav" => vjav::search(&query).await,
            "wnzs" => wnzs::search(&query).await,
            "wohs" => wohs::search(&query).await,
            "wukong" => wukong::search(&query).await,
            "wuyetv" => wuyetv::search(&query).await,
            "x51" => x51::search(&query).await,
            "xanimu" => xanimu::search(&query).await,
            "xhamster" => xhamster::search(&query).await,
            "xhy11" => xhy11::search(&query).await,
            "xianxia" => xianxia::search(&query).await,
            "xingkongfuli" => xingkongfuli::search(&query).await,
            "xj" => xj::search(&query).await,
            "xj2" => xj2::search(&query).await,
            "xjh5" => xjh5::search(&query).await,
            "xlook" => xlook::search(&query).await,
            "xojav" => xojav::search(&query).await,
            "xszav" => xszav::search(&query).await,
            "xvideo" => xvideo::search(&query).await,
            "xx01" => xx01::search(&query).await,
            "xx9" => xx9::search(&query).await,
            "yiren" => yiren::search(&query).await,
            "yunmeng" => yunmeng::search(&query).await,
            "ywmm" => ywmm::search(&query).await,
            "zggjav" => zggjav::search(&query).await,
            "zwdj" => zwdj::search(&query).await,
            "zwwm" => zwwm::search(&query).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}

fn handle_play<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    let site = site_id(params);
    let video_id = params.get_str("video_id");
    Box::pin(async move {
        if video_id.is_empty() {
            return Err(ApiError::BadRequest("missing video_id parameter".into()));
        }
        match site?.as_str() {
            "yaguo" => yaguo::play(&video_id).await,
            "123av" => av123::play(&video_id).await,
            "17rip" => rip17::play(&video_id).await,
            "321av" => av321::play(&video_id).await,
            "591av" => av591::play(&video_id).await,
            "69vj" => vj69::play(&video_id).await,
            "99jj" => jj99::play(&video_id).await,
            "abjav" => abjav::play(&video_id).await,
            "ai2026" => ai2026::play(&video_id).await,
            "ai4k" => ai4k::play(&video_id).await,
            "aidj" => aidj::play(&video_id).await,
            "aiduanju" => aiduanju::play(&video_id).await,
            "aimove" => aimove::play(&video_id).await,
            "airav" => airav::play(&video_id).await,
            "aisxpc" => aisxpc::play(&video_id).await,
            "aiye" => aiye::play(&video_id).await,
            "aoxx69" => aoxx69::play(&video_id).await,
            "asextv" => asextv::play(&video_id).await,
            "av18av" => av18av::play(&video_id).await,
            "av18avmcg" => av18avmcg::play(&video_id).await,
            "av6k" => av6k::play(&video_id).await,
            "av91" => av91::play(&video_id).await,
            "avbigplat" => avbigplat::play(&video_id).await,
            "avcnn" => avcnn::play(&video_id).await,
            "avhwa" => avhwa::play(&video_id).await,
            "avjoy" => avjoy::play(&video_id).await,
            "avtoday" => avtoday::play(&video_id).await,
            "avyanjiuyuan" => avyanjiuyuan::play(&video_id).await,
            "badyi" => badyi::play(&video_id).await,
            "caoliu" => caoliu::play(&video_id).await,
            "chengren91" => chengren91::play(&video_id).await,
            "chinax" => chinax::play(&video_id).await,
            "cporn" => cporn::play(&video_id).await,
            "crdj" => crdj::play(&video_id).await,
            "cucumber" => cucumber::play(&video_id).await,
            "dage" => dage::play(&video_id).await,
            "danai" => danai::play(&video_id).await,
            "dayday" => dayday::play(&video_id).await,
            "ddys" => ddys::play(&video_id).await,
            "dingjiaseku" => dingjiaseku::play(&video_id).await,
            "dj69" => dj69::play(&video_id).await,
            "dj91" => dj91::play(&video_id).await,
            "djwo" => djwo::play(&video_id).await,
            "dsav" => dsav::play(&video_id).await,
            "dsd" => dsd::play(&video_id).await,
            "duanjuone" => duanjuone::play(&video_id).await,
            "fq" => fq::play(&video_id).await,
            "fuchou" => fuchou::play(&video_id).await,
            "getav" => getav::play(&video_id).await,
            "go2av" => go2av::play(&video_id).await,
            "goodav" => goodav::play(&video_id).await,
            "gqck" => gqck::play(&video_id).await,
            "guzhuang" => guzhuang::play(&video_id).await,
            "haijiao" => haijiao::play(&video_id).await,
            "haijiao4k" => haijiao4k::play(&video_id).await,
            "hanime" => hanime::play(&video_id).await,
            "hbook" => hbook::play(&video_id).await,
            "hddj" => hddj::play(&video_id).await,
            "hduanju" => hduanju::play(&video_id).await,
            "heitaoduanju" => heitaoduanju::play(&video_id).await,
            "henhenlu" => henhenlu::play(&video_id).await,
            "herexxx" => herexxx::play(&video_id).await,
            "hgai" => hgai::play(&video_id).await,
            "hgaidj" => hgaidj::play(&video_id).await,
            "hgdj" => hgdj::play(&video_id).await,
            "hgdj58" => hgdj58::play(&video_id).await,
            "hgdjv" => hgdjv::play(&video_id).await,
            "hgkpz" => hgkpz::play(&video_id).await,
            "hgtvim" => hgtvim::play(&video_id).await,
            "hjapp" => hjapp::play(&video_id).await,
            "hjw" => hjw::play(&video_id).await,
            "hl365" => hl365::play(&video_id).await,
            "hohoj" => hohoj::play(&video_id).await,
            "hongxing" => hongxing::play(&video_id).await,
            "hongyan" => hongyan::play(&video_id).await,
            "hongluo" => hongluo::play(&video_id).await,
            "hsck" => hsck::play(&video_id).await,
            "huai" => huai::play(&video_id).await,
            "huangduanju" => huangduanju::play(&video_id).await,
            "huangguazy" => huangguazy::play(&video_id).await,
            "huangguo" => huangguo::play(&video_id).await,
            "huangguotv" => huangguotv::play(&video_id).await,
            "jable" => jable::play(&video_id).await,
            "jack20" => jack20::play(&video_id).await,
            "japanwhores" => japanwhores::play(&video_id).await,
            "jav" => jav::play(&video_id).await,
            "jav188" => jav188::play(&video_id).await,
            "jav777" => jav777::play(&video_id).await,
            "javdino" => javdino::play(&video_id).await,
            "javfun" => javfun::play(&video_id).await,
            "javgg" => javgg::play(&video_id).await,
            "javguru" => javguru::play(&video_id).await,
            "javhd" => javhd::play(&video_id).await,
            "javhdtube" => javhdtube::play(&video_id).await,
            "javher" => javher::play(&video_id).await,
            "javmap" => javmap::play(&video_id).await,
            "javmit" => javmit::play(&video_id).await,
            "javplay" => javplay::play(&video_id).await,
            "javrate" => javrate::play(&video_id).await,
            "javsiri" => javsiri::play(&video_id).await,
            "javtiful" => javtiful::play(&video_id).await,
            "javtsunami" => javtsunami::play(&video_id).await,
            "javwine" => javwine::play(&video_id).await,
            "javzw" => javzw::play(&video_id).await,
            "jin18" => jin18::play(&video_id).await,
            "jiuse" => jiuse::play(&video_id).await,
            "jiuseduanju" => jiuseduanju::play(&video_id).await,
            "jm" => jm::play(&video_id).await,
            "jptt" => jptt::play(&video_id).await,
            "juyin" => juyin::play(&video_id).await,
            "kissjav" => kissjav::play(&video_id).await,
            "klxq" => klxq::play(&video_id).await,
            "km2" => km2::play(&video_id).await,
            "koreanporn" => koreanporn::play(&video_id).await,
            "kuaihuo" => kuaihuo::play(&video_id).await,
            "lissav" => lissav::play(&video_id).await,
            "lissavcn" => lissavcn::play(&video_id).await,
            "luoliai" => luoliai::play(&video_id).await,
            "lxs" => lxs::play(&video_id).await,
            "madao" => madao::play(&video_id).await,
            "madou" => madou::play(&video_id).await,
            "md" => md::play(&video_id).await,
            "mianfeiai" => mianfeiai::play(&video_id).await,
            "mirror" => mirror::play(&video_id).await,
            "missav" => missav::play(&video_id).await,
            "missavoff" => missavoff::play(&video_id).await,
            "missavt" => missavt::play(&video_id).await,
            "mjv011" => mjv011::play(&video_id).await,
            "mmtv7" => mmtv7::play(&video_id).await,
            "mose365" => mose365::play(&video_id).await,
            "muzi" => muzi::play(&video_id).await,
            "mythav" => mythav::play(&video_id).await,
            "naihenda" => naihenda::play(&video_id).await,
            "netflav" => netflav::play(&video_id).await,
            "nvdi" => nvdi::play(&video_id).await,
            "okxxx" => okxxx::play(&video_id).await,
            "pachub" => pachub::play(&video_id).await,
            "pandatv" => pandatv::play(&video_id).await,
            "pb" => pb::play(&video_id).await,
            "pigav" => pigav::play(&video_id).await,
            "pj5ti" => pj5ti::play(&video_id).await,
            "porna91" => porna91::play(&video_id).await,
            "porncgw" => porncgw::play(&video_id).await,
            "pornhub" => pornhub::play(&video_id).await,
            "ptt01" => ptt01::play(&video_id).await,
            "px8x" => px8x::play(&video_id).await,
            "roshy" => roshy::play(&video_id).await,
            "rou" => rou::play(&video_id).await,
            "rouav" => rouav::play(&video_id).await,
            "rouvideo" => rouvideo::play(&video_id).await,
            "rscg91" => rscg91::play(&video_id).await,
            "senzuri" => senzuri::play(&video_id).await,
            "sex8" => sex8::play(&video_id).await,
            "sexkbj" => sexkbj::play(&video_id).await,
            "shaofu" => shaofu::play(&video_id).await,
            "shunvqu" => shunvqu::play(&video_id).await,
            "shunvwang" => shunvwang::play(&video_id).await,
            "sihu" => sihu::play(&video_id).await,
            "sihucdn" => sihucdn::play(&video_id).await,
            "sporn" => sporn::play(&video_id).await,
            "ssis" => ssis::play(&video_id).await,
            "swagr" => swagr::play(&video_id).await,
            "taiav" => taiav::play(&video_id).await,
            "tanhua91" => tanhua91::play(&video_id).await,
            "taose" => taose::play(&video_id).await,
            "thdh" => thdh::play(&video_id).await,
            "theporny" => theporny::play(&video_id).await,
            "tiktvod" => tiktvod::play(&video_id).await,
            "tinyav" => tinyav::play(&video_id).await,
            "tokyomotion" => tokyomotion::play(&video_id).await,
            "topjav" => topjav::play(&video_id).await,
            "toptv" => toptv::play(&video_id).await,
            "tudou" => tudou::play(&video_id).await,
            "txfans" => txfans::play(&video_id).await,
            "utube" => utube::play(&video_id).await,
            "uudj" => uudj::play(&video_id).await,
            "vjav" => vjav::play(&video_id).await,
            "wnzs" => wnzs::play(&video_id).await,
            "wohs" => wohs::play(&video_id).await,
            "wukong" => wukong::play(&video_id).await,
            "wuyetv" => wuyetv::play(&video_id).await,
            "x51" => x51::play(&video_id).await,
            "xanimu" => xanimu::play(&video_id).await,
            "xhamster" => xhamster::play(&video_id).await,
            "xhy11" => xhy11::play(&video_id).await,
            "xianxia" => xianxia::play(&video_id).await,
            "xingkongfuli" => xingkongfuli::play(&video_id).await,
            "xj" => xj::play(&video_id).await,
            "xj2" => xj2::play(&video_id).await,
            "xjh5" => xjh5::play(&video_id).await,
            "xlook" => xlook::play(&video_id).await,
            "xojav" => xojav::play(&video_id).await,
            "xszav" => xszav::play(&video_id).await,
            "xvideo" => xvideo::play(&video_id).await,
            "xx01" => xx01::play(&video_id).await,
            "xx9" => xx9::play(&video_id).await,
            "yiren" => yiren::play(&video_id).await,
            "yunmeng" => yunmeng::play(&video_id).await,
            "ywmm" => ywmm::play(&video_id).await,
            "zggjav" => zggjav::play(&video_id).await,
            "zwdj" => zwdj::play(&video_id).await,
            "zwwm" => zwwm::play(&video_id).await,
            other => Err(ApiError::BadRequest(format!("unknown drama site: {other}"))),
        }
    })
}
