//! `dory-proto` — the one wire protocol, shared by `doryd`/helpers (host) and `dory-agent` (guest).
//!
//! - [`frame`]: length-delimited framing (LE u32 prefix, 16 MiB max, timeout ≠ corruption).
//! - [`mux`]: request/response multiplexing over the single control connection — a single writer
//!   task plus an id-keyed response router, so concurrent callers never interleave bytes (the fix
//!   for the legacy one-connection-per-call `malformedFrame` wedge).
//! - [`half_close`]: the asymmetric per-direction `SHUT_WR` splice that keeps `docker` attach/exec
//!   from truncating.
//! - [`handshake`]: the versioned `Hello` exchange (a skew is a clean refusal, not a wedge).
//! - [`channels`]: the vsock port catalog (control 1024 / usbip 1025 / docker 1026).
//! - [`preamble`]: the per-connection forward preamble `dory-hv` prefixes so doryd stays
//!   protocol-free.

pub mod channels;
pub mod frame;
pub mod half_close;
pub mod handshake;
pub mod mux;
pub mod preamble;
