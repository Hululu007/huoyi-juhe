//! Offline checks for the playback ladder pieces that do not need the
//! network: the anonymous door body shape and the video_tab GET signature.

use super::*;

fn gunzip_json(body: &[u8]) -> Value {
    let plain = crate::crypto::gunzip(body).expect("playback body must gunzip");
    serde_json::from_slice(&plain).expect("playback body must be JSON")
}

#[test]
fn anonymous_body_adds_video_id_and_content_type_to_the_v5_body() {
    let anon = gunzip_json(&anonymous_playback_body("vid-9").expect("anon body"));
    assert_eq!(anon["video_id"], "vid-9");
    assert_eq!(anon["content_type"], 1);
    assert_eq!(anon["mixed_video_id_map"]["1004"][0], "vid-9");
    assert_eq!(anon["dr_scene"], "player");

    let plain = gunzip_json(&v5_playback_body("vid-9").expect("v5 body"));
    assert!(plain.get("video_id").is_none());
    assert!(plain.get("content_type").is_none());
    assert_eq!(plain["mixed_video_id_map"]["1004"][0], "vid-9");
}

#[test]
fn video_tab_get_signs_with_the_full_envelope_and_no_body_headers() {
    let identity = crate::sign::v5::V5Identity {
        device_id: "dev-1",
        install_id: "iid-2",
        cdid: "cdid-3",
    };
    let signed =
        crate::sign::v5::sign_playback_v5_get(VIDEO_TAB_BASE, &[("video_id", "vid-9")], &identity)
            .expect("GET playback signature");
    let query = signed.url.split_once('?').expect("GET query").1;
    assert!(query.contains("video_id=vid-9"));
    assert!(crate::sign::v5::playback_envelope_is_full(query));
    assert!(signed.headers.iter().all(|(name, _)| !matches!(
        name.as_str(),
        "Content-Type" | "Content-Encoding" | "x-ss-stub"
    )));
}

#[test]
fn ladder_routes_put_the_anonymous_door_first() {
    let tags: Vec<&str> = crate::upstream::playback_routes::routes()
        .iter()
        .map(|route| route.tag())
        .collect();
    assert_eq!(tags, vec!["anon", "v5", "model-a", "model-c", "tab-b"]);
}
