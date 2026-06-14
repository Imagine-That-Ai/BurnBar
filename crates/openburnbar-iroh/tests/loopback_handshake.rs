//! Live loopback handshake test for the SHIPPING iroh transport.
//!
//! Stands up two in-process iroh endpoints with relays DISABLED (hermetic — no
//! internet, no n0 relay), performs the real ALPN handshake over loopback
//! direct addresses, and round-trips a length-prefixed frame using the crate's
//! own wire constants (`OPENBURNBAR_ALPN`, `OPENBURNBAR_MAX_FRAME_BYTES`) and
//! the same big-endian-u32 length-prefix framing `IrohStream` ships.
//!
//! This is the first merge-blocking validation of the transport the iOS,
//! Android, and macOS apps depend on: it fails on ALPN drift, a length-prefix
//! change, or any handshake regression.
//!
//! Per the crate convention (zero unwrap/expect; CI denies clippy::expect_used
//! and the Rust-panic debt budget), failures surface through contextual panics
//! via the `must` / `present` helpers below rather than expect/unwrap calls.

use std::time::Duration;

use iroh::{endpoint::presets, Endpoint, EndpointAddr, RelayMode, SecretKey, TransportAddr};
use openburnbar_iroh::{OPENBURNBAR_ALPN, OPENBURNBAR_MAX_FRAME_BYTES};
use tokio::io::AsyncWriteExt;

/// Unwrap a `Result` in test code with a contextual panic (no `.expect`).
#[track_caller]
fn must<T, E: std::fmt::Debug>(result: Result<T, E>, what: &str) -> T {
    match result {
        Ok(value) => value,
        Err(error) => panic!("{what}: {error:?}"),
    }
}

/// Unwrap an `Option` in test code with a contextual panic (no `.unwrap`).
#[track_caller]
fn present<T>(value: Option<T>, what: &str) -> T {
    match value {
        Some(value) => value,
        None => panic!("{what}"),
    }
}

async fn bind_loopback_endpoint() -> Endpoint {
    // RelayMode::Disabled keeps the test hermetic: connectivity is via loopback
    // direct addresses only, so `endpoint.online()` (which needs a relay) is
    // never required.
    let bound = Endpoint::builder(presets::N0)
        .secret_key(SecretKey::generate())
        .alpns(vec![OPENBURNBAR_ALPN.to_vec()])
        .relay_mode(RelayMode::Disabled)
        .bind()
        .await;
    must(bound, "bind loopback iroh endpoint")
}

// Mirrors IrohStream::send_frame: big-endian u32 length prefix + payload,
// bounded by OPENBURNBAR_MAX_FRAME_BYTES. Kept in lockstep with the shipping
// framing so a change to the wire format breaks this test.
async fn write_frame(send: &mut iroh::endpoint::SendStream, frame: &[u8]) {
    assert!(
        frame.len() <= OPENBURNBAR_MAX_FRAME_BYTES,
        "test frame exceeds the wire cap"
    );
    let length = must(u32::try_from(frame.len()), "frame length fits u32");
    must(
        send.write_all(&length.to_be_bytes()).await,
        "write length prefix",
    );
    must(send.write_all(frame).await, "write frame payload");
    must(send.flush().await, "flush frame");
}

// Mirrors IrohStream::recv_frame.
async fn read_frame(recv: &mut iroh::endpoint::RecvStream) -> Vec<u8> {
    let mut len_buf = [0u8; 4];
    must(recv.read_exact(&mut len_buf).await, "read length prefix");
    let length = u32::from_be_bytes(len_buf) as usize;
    assert!(
        length <= OPENBURNBAR_MAX_FRAME_BYTES,
        "received frame exceeds the wire cap"
    );
    let mut payload = vec![0u8; length];
    must(recv.read_exact(&mut payload).await, "read frame payload");
    payload
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn loopback_alpn_handshake_round_trips_a_length_prefixed_frame() {
    // Guard the wire constant itself: the apps hand-mirror this ALPN.
    assert_eq!(
        OPENBURNBAR_ALPN, b"openburnbar/1",
        "OPENBURNBAR_ALPN wire constant changed"
    );

    let server = bind_loopback_endpoint().await;
    let client = bind_loopback_endpoint().await;

    let server_id = server.id();
    let client_id = client.id();

    // Loopback direct addresses are available immediately after bind (no relay).
    let direct: Vec<std::net::SocketAddr> = server.addr().ip_addrs().copied().collect();
    assert!(
        !direct.is_empty(),
        "loopback endpoint exposed no direct addresses"
    );

    let remote = EndpointAddr::new(server_id).with_addrs(direct.into_iter().map(TransportAddr::Ip));

    // Server: accept one connection + bi-stream, echo the framed message back.
    let server_task = tokio::spawn(async move {
        let incoming = present(
            server.accept().await,
            "server receives an inbound connection",
        );
        let conn = must(incoming.await, "server completes the ALPN handshake");
        let remote_id = conn.remote_id();
        let (mut send, mut recv) = must(conn.accept_bi().await, "server accepts a bi-stream");
        let frame = read_frame(&mut recv).await;
        write_frame(&mut send, &frame).await;
        let _ = send.finish();
        // Hold the connection open until the client has read the echo.
        tokio::time::sleep(Duration::from_millis(50)).await;
        remote_id
    });

    // Client: dial the server over loopback using the shipping ALPN.
    let conn = must(
        must(
            tokio::time::timeout(
                Duration::from_secs(10),
                client.connect(remote, OPENBURNBAR_ALPN),
            )
            .await,
            "client connect did not time out",
        ),
        "client connects over loopback",
    );
    assert_eq!(
        conn.remote_id(),
        server_id,
        "client connected to the wrong endpoint"
    );

    let (mut send, mut recv) = must(conn.open_bi().await, "client opens a bi-stream");
    let payload = b"hermes/iroh loopback handshake".to_vec();
    write_frame(&mut send, &payload).await;
    let _ = send.finish();

    let echoed = read_frame(&mut recv).await;
    assert_eq!(echoed, payload, "framed payload did not round-trip intact");

    let server_saw = must(
        must(
            tokio::time::timeout(Duration::from_secs(5), server_task).await,
            "server task completes",
        ),
        "server task did not panic",
    );
    assert_eq!(
        server_saw, client_id,
        "server observed the wrong remote endpoint id"
    );
}
