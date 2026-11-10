//! Runtime configuration (mirrors config.json).

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AntiCrawler {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub redirect_url: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Admin {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub update_server_url: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub algorithm_type: String,
    #[serde(default)]
    pub zwsm: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub anti_crawler: AntiCrawler,
    #[serde(default)]
    pub admin: Admin,
}

impl Config {
    pub fn load(path: &str) -> Result<Self, String> {
        let data = std::fs::read(path).map_err(|e| format!("read config {path}: {e}"))?;
        let mut c: Config =
            serde_json::from_slice(&data).map_err(|e| format!("parse config {path}: {e}"))?;
        if c.port == 0 {
            c.port = 18921;
        }
        Ok(c)
    }
}

/// Loopback port the rest of the core should advertise.
///
/// The adapter may end up on an ephemeral port when the configured one is
/// still held by a stale process of a previous install (overlay install
/// does not always kill the old process first). The actually-bound port
/// wins; otherwise the configured port, defaulting to 18921 when the
/// config says 0.
pub fn effective_port(configured: u16, bound: u16) -> u16 {
    if bound != 0 {
        bound
    } else if configured != 0 {
        configured
    } else {
        18921
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective_port_prefers_the_bound_port() {
        assert_eq!(effective_port(18921, 54321), 54321);
    }

    #[test]
    fn effective_port_falls_back_to_the_configured_port() {
        assert_eq!(effective_port(18921, 0), 18921);
    }

    #[test]
    fn effective_port_defaults_when_nothing_is_set() {
        assert_eq!(effective_port(0, 0), 18921);
    }
}
