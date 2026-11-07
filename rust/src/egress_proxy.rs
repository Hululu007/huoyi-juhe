//! Egress proxy configuration for outbound HTTP.
//!
//! The drama/reading clients are plain reqwest clients. reqwest's
//! `system-proxy` feature only reads proxy settings from environment
//! variables on Linux/Android, and the app process has none, so on a phone
//! reqwest connects directly and gets blocked for most third-party sites.
//! Dart reads the Android system proxy and hands its URL to the core via
//! the FRB `set_egress_proxy` function; every shared client below is built
//! through `apply_to_builder` and rebuilt whenever the proxy changes.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;

/// Current egress proxy URL; `None` means direct connection.
static PROXY_URL: RwLock<Option<String>> = RwLock::new(None);

/// Bumped on every `set_egress_proxy` call (including clearing). Shared
/// clients cache the generation they were built with and rebuild on mismatch.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Generation of the proxy config the caller should build against.
pub fn generation() -> u64 {
    GENERATION.load(Ordering::SeqCst)
}

/// Set the egress proxy. Accepts `http://`, `https://`, `socks5://` and
/// `socks5h://` URLs. An empty or whitespace-only string clears the proxy
/// (back to direct). Anything else is rejected with a reason.
pub fn set_egress_proxy(url: &str) -> Result<(), String> {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        let mut guard = PROXY_URL
            .write()
            .map_err(|_| "egress proxy lock poisoned".to_string())?;
        *guard = None;
        GENERATION.fetch_add(1, Ordering::SeqCst);
        return Ok(());
    }
    let parsed =
        url::Url::parse(trimmed).map_err(|e| format!("invalid proxy URL {trimmed:?}: {e}"))?;
    match parsed.scheme() {
        "http" | "https" | "socks5" | "socks5h" => {}
        other => {
            return Err(format!(
                "unsupported proxy scheme {other:?}: use http://, https://, socks5:// or socks5h://"
            ));
        }
    }
    // The url crate is lenient about an empty authority (`http:///path`
    // parses); a proxy without an authority part is never usable, so check
    // the raw text too.
    let authority = trimmed
        .splitn(2, "://")
        .nth(1)
        .unwrap_or("")
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("");
    if authority.is_empty() || parsed.host_str().map(|h| h.is_empty()).unwrap_or(true) {
        return Err(format!("proxy URL {trimmed:?} has no host"));
    }
    let mut guard = PROXY_URL
        .write()
        .map_err(|_| "egress proxy lock poisoned".to_string())?;
    *guard = Some(trimmed.to_string());
    GENERATION.fetch_add(1, Ordering::SeqCst);
    Ok(())
}

/// Current egress proxy URL, or `None` for direct connection.
pub fn get_egress_proxy() -> Option<String> {
    PROXY_URL.read().ok().and_then(|guard| guard.clone())
}

/// Attach the configured proxy (if any) to a client builder. A proxy URL
/// that fails `Proxy::all` (should not happen after `set_egress_proxy`
/// validation) falls back to a direct builder instead of failing the build.
pub fn apply_to_builder(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    match get_egress_proxy() {
        Some(url) => match reqwest::Proxy::all(&url) {
            Ok(proxy) => builder.proxy(proxy),
            Err(_) => builder,
        },
        None => builder,
    }
}

/// A lazily built shared client that rebuilds when the proxy changes.
///
/// `client()` helpers used to cache their client in a `OnceLock` built once
/// and never again, so a proxy set after first use would never take effect.
/// A slot remembers the proxy generation it was built with; `get_or_build`
/// rebuilds on mismatch. The built client is leaked (`Box::leak`) so the
/// existing `&'static Client` call sites keep working; rebuilds only happen
/// when the proxy setting changes, so at most a few clients are ever leaked.
pub struct ClientSlot {
    state: RwLock<(u64, Option<&'static reqwest::Client>)>,
}

impl ClientSlot {
    pub const fn new() -> Self {
        Self {
            state: RwLock::new((0, None)),
        }
    }

    pub fn get_or_build(
        &self,
        build: impl FnOnce() -> Option<reqwest::Client>,
    ) -> Option<&'static reqwest::Client> {
        let gen = generation();
        {
            let guard = self.state.read().ok()?;
            if guard.0 == gen {
                if let Some(client) = guard.1 {
                    return Some(client);
                }
            }
        }
        let mut guard = self.state.write().ok()?;
        if guard.0 == gen {
            if let Some(client) = guard.1 {
                return Some(client);
            }
        }
        let built = build().map(|c| &*Box::leak(Box::new(c)));
        *guard = (gen, built);
        built
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Mutex;

    // The proxy config is process-global; serialize the tests that mutate it.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    // The crate builds reqwest with `rustls-no-provider`; a test process
    // never installs one, so install the ring provider before building any
    // client here (the drama client does the same on its own path).
    fn ensure_crypto_provider() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }

    #[test]
    fn accepts_http_https_and_socks5() {
        let _guard = lock();
        for url in [
            "http://127.0.0.1:8080",
            "https://proxy.example.com:3128",
            "socks5://127.0.0.1:1080",
            "socks5h://user:pass@127.0.0.1:1080",
            "http://proxy.example.com:8080",
        ] {
            assert!(set_egress_proxy(url).is_ok(), "{url} should be accepted");
            assert_eq!(get_egress_proxy().as_deref(), Some(url));
        }
        let _ = set_egress_proxy("");
    }

    #[test]
    fn rejects_invalid_urls() {
        let _guard = lock();
        for url in [
            "ftp://proxy.example.com:21",
            "not a url",
            "proxy.example.com:8080",
            "http://",
            "http:///path-only",
            "gopher://127.0.0.1:70",
        ] {
            assert!(set_egress_proxy(url).is_err(), "{url} should be rejected");
        }
        let _ = set_egress_proxy("");
    }

    #[test]
    fn empty_and_whitespace_clear_the_proxy() {
        let _guard = lock();
        assert!(set_egress_proxy("http://127.0.0.1:8080").is_ok());
        assert_eq!(get_egress_proxy().as_deref(), Some("http://127.0.0.1:8080"));
        assert!(set_egress_proxy("").is_ok());
        assert_eq!(get_egress_proxy(), None);
        assert!(set_egress_proxy("http://127.0.0.1:8080").is_ok());
        assert!(set_egress_proxy("   \t ").is_ok());
        assert_eq!(get_egress_proxy(), None);
    }

    #[test]
    fn set_then_get_roundtrip_and_generation_bumps() {
        let _guard = lock();
        let before = generation();
        assert!(set_egress_proxy("http://127.0.0.1:9090").is_ok());
        assert_eq!(get_egress_proxy().as_deref(), Some("http://127.0.0.1:9090"));
        assert!(generation() > before);
        let _ = set_egress_proxy("");
        assert_eq!(get_egress_proxy(), None);
    }

    #[test]
    fn slot_rebuilds_when_proxy_changes() {
        let _guard = lock();
        ensure_crypto_provider();
        let _ = set_egress_proxy("");
        let builds = AtomicUsize::new(0);
        let slot = ClientSlot::new();
        let first = slot.get_or_build(|| {
            builds.fetch_add(1, Ordering::SeqCst);
            reqwest::Client::builder().build().ok()
        });
        assert!(first.is_some());
        // Same generation: the cached client is returned, no rebuild.
        let second = slot.get_or_build(|| {
            builds.fetch_add(1, Ordering::SeqCst);
            reqwest::Client::builder().build().ok()
        });
        assert_eq!(builds.load(Ordering::SeqCst), 1);
        assert!(std::ptr::eq(first.unwrap(), second.unwrap()));
        // Proxy change bumps the generation: next access rebuilds.
        assert!(set_egress_proxy("http://127.0.0.1:8080").is_ok());
        let third = slot.get_or_build(|| {
            builds.fetch_add(1, Ordering::SeqCst);
            apply_to_builder(reqwest::Client::builder()).build().ok()
        });
        assert_eq!(builds.load(Ordering::SeqCst), 2);
        assert!(third.is_some());
        assert!(!std::ptr::eq(first.unwrap(), third.unwrap()));
        // Clearing the proxy rebuilds once more.
        assert!(set_egress_proxy("").is_ok());
        let fourth = slot.get_or_build(|| {
            builds.fetch_add(1, Ordering::SeqCst);
            reqwest::Client::builder().build().ok()
        });
        assert_eq!(builds.load(Ordering::SeqCst), 3);
        assert!(!std::ptr::eq(third.unwrap(), fourth.unwrap()));
    }

    #[test]
    fn apply_to_builder_builds_with_and_without_proxy() {
        let _guard = lock();
        ensure_crypto_provider();
        let _ = set_egress_proxy("");
        assert!(apply_to_builder(reqwest::Client::builder()).build().is_ok());
        assert!(set_egress_proxy("socks5://127.0.0.1:1080").is_ok());
        assert!(apply_to_builder(reqwest::Client::builder()).build().is_ok());
        let _ = set_egress_proxy("");
    }

    /// Live check of the proxy path, using the same `apply_to_builder`
    /// code the drama client uses. Only runs where the environment already
    /// provides a proxy (this VM does via HTTP_PROXY); elsewhere it skips.
    /// Proves a proxied client really reaches a site that direct
    /// connections cannot (mjv011.com returns 000 direct from this VM).
    #[test]
    fn live_fetch_via_env_proxy_when_present() {
        let _guard = lock();
        ensure_crypto_provider();
        let Some(proxy) = std::env::var("HTTPS_PROXY")
            .or_else(|_| std::env::var("HTTP_PROXY"))
            .ok()
            .filter(|p| !p.trim().is_empty())
        else {
            return;
        };
        assert!(set_egress_proxy(&proxy).is_ok());
        let client = apply_to_builder(
            reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)),
        )
        .build()
        .expect("client builds with proxy");
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime");
        let status = rt
            .block_on(async { client.get("https://mjv011.com").send().await })
            .expect("request through configured proxy succeeds")
            .status();
        assert!(status.is_success(), "mjv011 via proxy: {status}");
        let _ = set_egress_proxy("");
    }
}
