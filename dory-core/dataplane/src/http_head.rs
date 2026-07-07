//! Minimal, bounded HTTP/1.1 request-head parsing — just enough to classify a docker request and
//! strip the `/vX.YZ` API-version prefix. The body is never buffered here: streaming/hijacked
//! endpoints hand the raw connection to the splice as soon as the head is known.

/// The maximum head we will buffer before giving up (a docker request head is tiny).
pub const MAX_HEAD_BYTES: usize = 64 * 1024;

const TERMINATOR: &[u8] = b"\r\n\r\n";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestHead {
    pub method: String,
    /// Path with the `/vX.YZ` version prefix and query string removed (e.g. `/containers/json`).
    pub path: String,
    /// The original request target, version prefix and query intact.
    pub raw_target: String,
    /// The request asks to upgrade the connection (exec/attach hijack).
    pub is_upgrade: bool,
}

/// Find the end of the head (`\r\n\r\n`) in `buf`, if present, returning the index just past it.
pub fn head_end(buf: &[u8]) -> Option<usize> {
    buf.windows(TERMINATOR.len())
        .position(|w| w == TERMINATOR)
        .map(|i| i + TERMINATOR.len())
}

/// Parse the request head from `buf` (which must contain a full `\r\n\r\n`).
pub fn parse_head(buf: &[u8]) -> Option<RequestHead> {
    let end = head_end(buf)?;
    let text = std::str::from_utf8(&buf[..end]).ok()?;
    let mut lines = text.split("\r\n");

    let request_line = lines.next()?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_ascii_uppercase();
    let raw_target = parts.next()?.to_string();

    let path_only = raw_target.split('?').next().unwrap_or(&raw_target);
    let path = strip_version_prefix(path_only).to_string();

    let mut is_upgrade = false;
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim().to_ascii_lowercase();
            let value = value.trim().to_ascii_lowercase();
            if (name == "upgrade" && !value.is_empty())
                || (name == "connection" && value.contains("upgrade"))
            {
                is_upgrade = true;
            }
        }
    }

    Some(RequestHead {
        method,
        path,
        raw_target,
        is_upgrade,
    })
}

/// `/v1.47/containers/json` -> `/containers/json`. Leaves paths without a version prefix untouched.
fn strip_version_prefix(path: &str) -> &str {
    if let Some(rest) = path.strip_prefix("/v") {
        if let Some(slash) = rest.find('/') {
            let version = &rest[..slash];
            if !version.is_empty() && version.chars().all(|c| c.is_ascii_digit() || c == '.') {
                return &rest[slash..];
            }
        }
    }
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head(bytes: &str) -> RequestHead {
        parse_head(bytes.as_bytes()).expect("parse")
    }

    #[test]
    fn strips_version_prefix_and_query() {
        let h = head("GET /v1.47/containers/json?all=1 HTTP/1.1\r\nHost: d\r\n\r\n");
        assert_eq!(h.method, "GET");
        assert_eq!(h.path, "/containers/json");
        assert_eq!(h.raw_target, "/v1.47/containers/json?all=1");
        assert!(!h.is_upgrade);
    }

    #[test]
    fn keeps_unversioned_path() {
        assert_eq!(
            head("POST /containers/create HTTP/1.1\r\n\r\n").path,
            "/containers/create"
        );
    }

    #[test]
    fn detects_upgrade() {
        let h = head(
            "POST /containers/abc/attach HTTP/1.1\r\nUpgrade: tcp\r\nConnection: Upgrade\r\n\r\n",
        );
        assert!(h.is_upgrade);
    }

    #[test]
    fn incomplete_head_is_none() {
        assert!(parse_head(b"GET /v1.47/conta").is_none());
        assert!(head_end(b"GET / HTTP/1.1\r\nHost: d\r\n").is_none());
    }
}
