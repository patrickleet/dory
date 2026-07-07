//! Route a docker request to one of three dispositions. Everything is passthrough now that the
//! backend is a real `dockerd`; the exceptions are the streaming/hijack endpoints (which must not be
//! buffered — buffering `build`/`pull` reintroduces the `/wait`-before-`/start` deadlock) and
//! container create (which needs the compatibility rewrites).

use crate::http_head::RequestHead;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disposition {
    /// Relay bytes verbatim to dockerd and back.
    Passthrough,
    /// Hand the raw connection to the half-close splice (attach/exec/build/pull, or any Upgrade).
    Hijack,
    /// Rewrite the create body for shared-VM compatibility, then relay.
    CreateRewrite,
}

pub fn classify(head: &RequestHead) -> Disposition {
    if head.is_upgrade {
        return Disposition::Hijack;
    }
    let (m, p) = (head.method.as_str(), head.path.as_str());
    if m == "POST" && p == "/containers/create" {
        return Disposition::CreateRewrite;
    }
    if p.ends_with("/attach") || p.ends_with("/attach/ws") {
        return Disposition::Hijack;
    }
    if p.starts_with("/exec/") && p.ends_with("/start") {
        return Disposition::Hijack;
    }
    if m == "POST" && (p == "/build" || p == "/images/create" || p == "/images/load") {
        return Disposition::Hijack;
    }
    Disposition::Passthrough
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http_head::parse_head;

    fn disp(req: &str) -> Disposition {
        classify(&parse_head(req.as_bytes()).unwrap())
    }

    #[test]
    fn create_is_rewritten() {
        assert_eq!(
            disp("POST /v1.47/containers/create HTTP/1.1\r\n\r\n"),
            Disposition::CreateRewrite
        );
        assert_eq!(
            disp("POST /containers/create HTTP/1.1\r\n\r\n"),
            Disposition::CreateRewrite
        );
    }

    #[test]
    fn list_and_inspect_pass_through() {
        assert_eq!(
            disp("GET /v1.47/containers/json HTTP/1.1\r\n\r\n"),
            Disposition::Passthrough
        );
        assert_eq!(
            disp("GET /containers/abc/json HTTP/1.1\r\n\r\n"),
            Disposition::Passthrough
        );
    }

    #[test]
    fn streaming_and_hijack_endpoints() {
        assert_eq!(
            disp("POST /containers/abc/attach HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
        assert_eq!(
            disp("POST /exec/xyz/start HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
        assert_eq!(
            disp("POST /v1.47/build HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
        assert_eq!(
            disp("POST /images/create?fromImage=alpine HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
    }

    #[test]
    fn upgrade_always_hijacks() {
        let d = disp("GET /events HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n");
        assert_eq!(d, Disposition::Hijack);
    }
}
