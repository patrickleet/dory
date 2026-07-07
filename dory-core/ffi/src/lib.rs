//! `dory-ffi` — seam 2: the UniFFI staticlib the Swift `doryd`/`dory-vmm` link.
//!
//! The iron rule: this boundary carries **configuration, file descriptors, and stats — never
//! data-plane bytes**. Swift hands the Rust engine an fd and a compiled config; from then on bytes
//! flow socket-to-socket entirely inside Rust ([`dory_proto::half_close`]), zero per-packet
//! crossings. Every exported entry is panic-safe (UniFFI wraps calls so a Rust panic surfaces as a
//! Swift error rather than unwinding across the boundary — UB).
//!
//! This slice exposes the small control surface that is ready: the protocol version and the
//! create-body rewrite. The `serve(listen_fd, config) -> Handle` entry that hands Rust the captive
//! docker socket fd lands with the VMM integration.

uniffi::setup_scaffolding!();

/// The wire protocol version doryd and the agent must agree on.
#[uniffi::export]
pub fn proto_version() -> u32 {
    dory_proto::handshake::PROTO_VERSION
}

/// Result of a create-body rewrite. `ok == false` carries a human-readable `error` (e.g. a GPU
/// request on an engine without GPU) and an empty `body`.
#[derive(uniffi::Record)]
pub struct RewriteResult {
    pub ok: bool,
    pub body: Vec<u8>,
    pub error: String,
}

/// Apply the shared-VM container-create rewrites to a JSON body. Control-plane only: this is a small
/// config message, not a data-plane stream.
#[uniffi::export]
pub fn rewrite_create_body(body: Vec<u8>, gpu_supported: bool) -> RewriteResult {
    match dory_dataplane::rewrite_create_body(&body, &dory_dataplane::RewriteOpts { gpu_supported })
    {
        Ok(out) => RewriteResult {
            ok: true,
            body: out,
            error: String::new(),
        },
        Err(e) => RewriteResult {
            ok: false,
            body: Vec::new(),
            error: e.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proto_version_matches_proto_crate() {
        assert_eq!(proto_version(), dory_proto::handshake::PROTO_VERSION);
    }

    #[test]
    fn rewrite_reports_gpu_error_across_the_boundary_shape() {
        let body = br#"{"HostConfig":{"DeviceRequests":[{"Capabilities":[["gpu"]]}]}}"#.to_vec();
        let r = rewrite_create_body(body, false);
        assert!(!r.ok);
        assert!(r.error.contains("GPU"));
    }

    #[test]
    fn rewrite_adds_extra_hosts() {
        let r = rewrite_create_body(br#"{"Image":"alpine"}"#.to_vec(), true);
        assert!(r.ok);
        let v: serde_json::Value = serde_json::from_slice(&r.body).unwrap();
        assert!(v["HostConfig"]["ExtraHosts"].as_array().unwrap().len() >= 2);
    }
}
