// OpenBurnBar iroh transport binding.
//
// This is the Rust core that the OpenBurnBarIroh Swift package wraps via
// UniFFI. The surface area is intentionally tiny — eight functions that move
// us from "no transport" to "open a bidirectional stream of bytes." Anything
// richer (frame parsing, quota, runtime discriminators) lives in Swift in
// `OpenBurnBarCore/IrohRelay/` where it can reuse `HermesRelayCrypto` and
// the existing `HermesRealtimeRelayFrame` Codable model.
//
// Why so small: n0 paused official iroh-ffi releases in Feb 2025
// (https://www.iroh.computer/blog/ffi-updates). Owning the surface in-tree
// lets us pin iroh, drift on our schedule, and keep the binding green for
// macOS arm64 + iOS arm64 + iOS Simulator arm64/x86_64.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use iroh::endpoint::IncomingAddr;
use iroh::{
    endpoint::presets, Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl,
    SecretKey, TransportAddr,
};
use iroh_services::Client as IrohServicesClient;
use tokio::io::AsyncWriteExt;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, Mutex, Semaphore};
use tokio::task::JoinHandle;

#[cfg(target_os = "android")]
mod android_context;
mod blobs;
mod datagrams;

#[allow(unused_imports)]
pub use blobs::{
    iroh_blobs_alpn, iroh_blobs_crate_version, parse_blob_ticket, BlobTicketBytes,
    BlobTransferStats, IrohBlobNode, OPENBURNBAR_MAX_BLOB_BYTES,
};

#[allow(unused_imports)]
pub use datagrams::{mercury_audio_alpn, IrohDatagramChannel, MERCURY_AUDIO_ALPN};

uniffi::setup_scaffolding!();

/// ALPN we negotiate over QUIC. Bumping this string forces a clean upgrade
/// boundary across iOS + Mac, mirroring `IrohRelayProtocol.alpn` in Swift.
pub const OPENBURNBAR_ALPN: &[u8] = b"openburnbar/1";
pub const OPENBURNBAR_MAX_FRAME_BYTES: usize = 512 * 1024;
const OPENBURNBAR_KEEP_ALIVE_INTERVAL: Duration = Duration::from_secs(1);
const OPENBURNBAR_MAX_IDLE_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// Inbound admission controls (T-TRN-06). The Mac host accepts connections
/// from a small, paired set of devices; an unpaired or hostile peer that can
/// reach the relay must not be able to exhaust handshake slots or spin the
/// acceptor with a connect storm. These bounds are deliberately generous for
/// the legitimate one-Mac/few-phones topology while capping the blast radius
/// of a single source.
///
/// Maximum number of inbound QUIC handshakes allowed in flight at once across
/// all sources. Each in-flight handshake holds a permit until the connection
/// either fails or its bi-stream loop ends; a flood of half-open handshakes
/// therefore cannot grow without bound.
const OPENBURNBAR_MAX_CONCURRENT_INBOUND_HANDSHAKES: usize = 64;
/// Sliding-window length for the per-source connection-rate limit.
const OPENBURNBAR_INBOUND_RATE_WINDOW: Duration = Duration::from_secs(10);
/// Maximum new connections a single source (IP for direct dials, NodeId for
/// relayed dials) may start within one `OPENBURNBAR_INBOUND_RATE_WINDOW`.
/// Beyond this the connection is refused early, before the handshake runs.
const OPENBURNBAR_INBOUND_MAX_CONNECTIONS_PER_WINDOW: u32 = 30;
const IROH_SERVICES_API_SECRET_ENV: &str = "IROH_SERVICES_API_SECRET";
const OPENBURNBAR_IROH_SERVICES_ENDPOINT_NAME_ENV: &str = "OPENBURNBAR_IROH_SERVICES_ENDPOINT_NAME";
const OPENBURNBAR_IROH_SERVICES_REQUIRED_ENV: &str = "OPENBURNBAR_IROH_SERVICES_REQUIRED";

pub(crate) fn openburnbar_transport_config(
) -> Result<iroh::endpoint::QuicTransportConfig, IrohFfiError> {
    Ok(iroh::endpoint::QuicTransportConfig::builder()
        .keep_alive_interval(OPENBURNBAR_KEEP_ALIVE_INTERVAL)
        .max_idle_timeout(Some(
            OPENBURNBAR_MAX_IDLE_TIMEOUT
                .try_into()
                .map_err(IrohFfiError::runtime)?,
        ))
        .build())
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum IrohFfiError {
    #[error("invalid iroh secret key")]
    InvalidSecretKey,
    #[error("invalid iroh node id")]
    InvalidNodeId,
    #[error("endpoint not initialized")]
    EndpointNotInitialized,
    #[error("connect failed: {detail}")]
    ConnectFailed { detail: String },
    #[error("stream failed: {detail}")]
    StreamFailed { detail: String },
    #[error("accept failed: {detail}")]
    AcceptFailed { detail: String },
    #[error("shutdown failed: {detail}")]
    ShutdownFailed { detail: String },
    #[error("runtime failed: {detail}")]
    RuntimeFailed { detail: String },
}

impl IrohFfiError {
    fn connect<E: std::fmt::Display>(error: E) -> Self {
        Self::ConnectFailed {
            detail: error.to_string(),
        }
    }
    fn stream<E: std::fmt::Display>(error: E) -> Self {
        Self::StreamFailed {
            detail: error.to_string(),
        }
    }
    fn accept<E: std::fmt::Display>(error: E) -> Self {
        Self::AcceptFailed {
            detail: error.to_string(),
        }
    }
    fn runtime<E: std::fmt::Display>(error: E) -> Self {
        Self::RuntimeFailed {
            detail: error.to_string(),
        }
    }
}

fn assert_openburnbar_frame_length(length: usize) -> Result<(), IrohFfiError> {
    if length > OPENBURNBAR_MAX_FRAME_BYTES {
        return Err(IrohFfiError::StreamFailed {
            detail: format!(
                "frame too large: {length} bytes exceeds {OPENBURNBAR_MAX_FRAME_BYTES} bytes"
            ),
        });
    }
    Ok(())
}

pub(crate) fn u64_saturating_from_u128(value: u128) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

pub(crate) fn u32_saturating_from_usize(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// 32 raw secret-key bytes generated by `IrohSecretKeyMaterial.generate()` on
/// the Swift side (or by `generate_secret_key_material()` for cold-start).
#[derive(uniffi::Record, Clone)]
pub struct IrohSecretKeyMaterial {
    pub raw: Vec<u8>,
}

/// 32 raw public-key bytes plus the base32 NodeId surface form (52 chars).
#[derive(uniffi::Record, Clone)]
pub struct IrohNodeIdentity {
    pub raw_public_key: Vec<u8>,
    pub node_id: String,
    pub relay_url: String,
    pub direct_addresses: Vec<String>,
}

/// Per-call options for inbound connection acceptance. Today only the
/// ALPN is configurable; we hard-pin `OPENBURNBAR_ALPN` from Swift.
#[derive(uniffi::Record, Clone)]
pub struct IrohAcceptOptions {
    pub alpn: Vec<u8>,
}

/// A single bidirectional stream, surfaced as an opaque handle to Swift so we
/// can keep the send/recv halves alive across UniFFI boundaries.
#[derive(uniffi::Object)]
pub struct IrohStream {
    /// Remote peer NodeId (base32 surface form) for inbound peer-binding on the Mac host.
    remote_node_id: String,
    /// Keep the QUIC connection alive while the send/recv halves are held by
    /// separate locks. Do not use one mutex for the whole stream: `recv_frame`
    /// intentionally blocks while waiting for remote data, and phone-control
    /// must still be able to write approval/input frames during that wait.
    conn: Mutex<Option<iroh::endpoint::Connection>>,
    send: Mutex<Option<iroh::endpoint::SendStream>>,
    recv: Mutex<Option<iroh::endpoint::RecvStream>>,
    runtime_handle: tokio::runtime::Handle,
}

#[uniffi::export]
impl IrohStream {
    /// Write a length-prefixed JSON frame onto the stream. Length prefix is
    /// a big-endian u32 — matches `IrohRelayWireFormat.lengthPrefix` in Swift.
    pub fn send_frame(self: Arc<Self>, frame: Vec<u8>) -> Result<(), IrohFfiError> {
        assert_openburnbar_frame_length(frame.len())?;
        let runtime_handle = self.runtime_handle.clone();
        runtime_handle.block_on(async move {
            let mut guard = self.send.lock().await;
            let send = guard.as_mut().ok_or(IrohFfiError::EndpointNotInitialized)?;
            let length = u32::try_from(frame.len()).map_err(|_| IrohFfiError::StreamFailed {
                detail: format!("frame too large for length prefix: {} bytes", frame.len()),
            })?;
            send.write_all(&length.to_be_bytes())
                .await
                .map_err(IrohFfiError::stream)?;
            send.write_all(&frame).await.map_err(IrohFfiError::stream)?;
            send.flush().await.map_err(IrohFfiError::stream)?;
            Ok(())
        })
    }

    /// Read one length-prefixed JSON frame off the stream. Returns `None` on
    /// clean stream close.
    pub fn recv_frame(self: Arc<Self>) -> Result<Option<Vec<u8>>, IrohFfiError> {
        let runtime_handle = self.runtime_handle.clone();
        runtime_handle.block_on(async move {
            let mut guard = self.recv.lock().await;
            let recv = guard.as_mut().ok_or(IrohFfiError::EndpointNotInitialized)?;
            let mut len_buf = [0u8; 4];
            match recv.read_exact(&mut len_buf).await {
                Ok(_) => {}
                Err(iroh::endpoint::ReadExactError::FinishedEarly(0)) => return Ok(None),
                Err(err) => return Err(IrohFfiError::stream(err)),
            }
            let length = u32::from_be_bytes(len_buf) as usize;
            assert_openburnbar_frame_length(length)?;
            let mut payload = vec![0u8; length];
            recv.read_exact(&mut payload)
                .await
                .map_err(IrohFfiError::stream)?;
            Ok(Some(payload))
        })
    }

    /// Base32 NodeId of the remote peer that opened this stream.
    pub fn remote_node_id(self: Arc<Self>) -> String {
        self.remote_node_id.clone()
    }

    /// Close the stream cleanly. Idempotent.
    pub fn close_stream(self: Arc<Self>) -> Result<(), IrohFfiError> {
        let runtime_handle = self.runtime_handle.clone();
        runtime_handle.block_on(async move {
            if let Some(mut send) = self.send.lock().await.take() {
                let _ = send.finish();
                let _ = send.stopped().await;
            }
            let _ = self.recv.lock().await.take();
            let _ = self.conn.lock().await.take();
            Ok(())
        })
    }
}

/// Stable per-source key for inbound rate limiting (T-TRN-06). Direct dials
/// are keyed by source IP (port-stripped so a NAT rebind doesn't reset the
/// budget); relayed dials are keyed by the remote NodeId the relay attests,
/// which is the only stable identity available before the handshake.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub(crate) enum InboundSource {
    Ip(IpAddr),
    Node(String),
}

impl InboundSource {
    fn from_incoming_addr(addr: &IncomingAddr) -> Self {
        match addr {
            IncomingAddr::Ip(socket) => InboundSource::Ip(socket.ip()),
            IncomingAddr::Relay { endpoint_id, .. } => InboundSource::Node(endpoint_id.to_string()),
            IncomingAddr::Custom(custom) => InboundSource::Node(format!("{custom:?}")),
            // `IncomingAddr` is `#[non_exhaustive]`; an unknown transport keys
            // to its debug form so the rate limit still applies (fail closed).
            other => InboundSource::Node(format!("{other:?}")),
        }
    }
}

/// Per-source sliding-window connection-rate limiter plus a global
/// concurrent-handshake cap. Pure logic (the timestamp ring) is split out so
/// the rate decision is unit-testable without a live endpoint; the semaphore
/// enforces the concurrency cap in the async acceptor.
pub(crate) struct InboundAdmission {
    window: Duration,
    max_per_window: u32,
    recent: StdMutex<HashMap<InboundSource, Vec<Instant>>>,
    handshake_slots: Arc<Semaphore>,
    /// When non-empty, only these NodeIds may complete a handshake; every
    /// other peer is rejected early. Empty means "no NodeId restriction" so
    /// the existing Swift-side allowlist stays the source of truth until it
    /// pushes a list down. Stored as base32 NodeId strings to match the
    /// `IrohStream::remote_node_id` surface form.
    allowlist: StdMutex<Option<std::collections::HashSet<String>>>,
}

impl InboundAdmission {
    fn new(window: Duration, max_per_window: u32, max_concurrent_handshakes: usize) -> Self {
        Self {
            window,
            max_per_window,
            recent: StdMutex::new(HashMap::new()),
            handshake_slots: Arc::new(Semaphore::new(max_concurrent_handshakes)),
            allowlist: StdMutex::new(None),
        }
    }

    /// Record one new connection attempt from `source` at `now` and report
    /// whether it stays within budget. Evicts timestamps older than the
    /// window so the map cannot grow without bound for a chatty source.
    pub(crate) fn admit_at(&self, source: &InboundSource, now: Instant) -> bool {
        let mut recent = match self.recent.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        let window = self.window;
        let timestamps = recent.entry(source.clone()).or_default();
        timestamps.retain(|seen| now.duration_since(*seen) < window);
        if timestamps.len() as u32 >= self.max_per_window {
            return false;
        }
        timestamps.push(now);
        true
    }

    fn admit(&self, source: &InboundSource) -> bool {
        self.admit_at(source, Instant::now())
    }

    /// Replace the NodeId allowlist. An empty list clears the restriction.
    fn set_allowlist(&self, node_ids: Vec<String>) {
        let mut guard = match self.allowlist.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        let cleaned: std::collections::HashSet<String> = node_ids
            .into_iter()
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty())
            .collect();
        *guard = if cleaned.is_empty() {
            None
        } else {
            Some(cleaned)
        };
    }

    /// True if `node_id` is permitted. No configured allowlist means permit
    /// all (the Swift allowlist still gates the stream downstream); once a
    /// list is pushed down, only listed NodeIds pass — fail closed.
    pub(crate) fn node_allowed(&self, node_id: &str) -> bool {
        let guard = match self.allowlist.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        match guard.as_ref() {
            None => true,
            Some(set) => set.contains(node_id.trim()),
        }
    }
}

fn spawn_incoming_stream_acceptor(
    endpoint: Endpoint,
    runtime_handle: tokio::runtime::Handle,
    stream_tx: mpsc::Sender<Arc<IrohStream>>,
    admission: Arc<InboundAdmission>,
) -> JoinHandle<()> {
    let outer_runtime_handle = runtime_handle.clone();
    runtime_handle.spawn(async move {
        while let Some(incoming) = endpoint.accept().await {
            // Per-source connection-rate limit (T-TRN-06): refuse the dial
            // before spending a handshake on a source that is hammering us.
            // `refuse()` sends a CONNECTION_REFUSED without running the
            // handshake, so a connect storm costs us a map lookup, not a TLS
            // negotiation or a spawned task.
            let source = InboundSource::from_incoming_addr(&incoming.remote_addr());
            if !admission.admit(&source) {
                incoming.refuse();
                continue;
            }
            // Relayed dials carry the peer NodeId before the handshake; reject
            // a non-allowlisted peer here so it never even completes a
            // handshake. Direct dials are re-checked after `incoming.await`
            // below, where the NodeId first becomes known.
            if let IncomingAddr::Relay { endpoint_id, .. } = incoming.remote_addr() {
                if !admission.node_allowed(&endpoint_id.to_string()) {
                    incoming.refuse();
                    continue;
                }
            }

            // Concurrent inbound-handshake cap (T-TRN-06): bound the number of
            // half-open handshakes in flight. If every slot is busy we drop
            // this dial (`ignore()` lets QUIC retransmit / time out) rather
            // than queueing unbounded work.
            let permit = match Arc::clone(&admission.handshake_slots).try_acquire_owned() {
                Ok(permit) => permit,
                Err(_) => {
                    incoming.ignore();
                    continue;
                }
            };

            let connection_stream_tx = stream_tx.clone();
            let stream_runtime_handle = outer_runtime_handle.clone();
            let connection_admission = Arc::clone(&admission);
            tokio::spawn(async move {
                // Hold the handshake permit for the lifetime of this peer's
                // accept loop so a peer that completes the handshake but never
                // opens a stream still counts against the concurrency cap.
                let _permit = permit;
                let conn = match incoming.await {
                    Ok(conn) => conn,
                    Err(_) => return,
                };
                let remote_node_id = conn.remote_id().to_string();
                // Early allowlist enforcement for direct dials: the NodeId is
                // only knowable post-handshake here, so reject before draining
                // any bi-stream into the queue. Fail closed.
                if !connection_admission.node_allowed(&remote_node_id) {
                    conn.close(0u32.into(), b"peer-not-allowlisted");
                    return;
                }
                while let Ok((send, recv)) = conn.accept_bi().await {
                    let stream = Arc::new(IrohStream {
                        remote_node_id: remote_node_id.clone(),
                        conn: Mutex::new(Some(conn.clone())),
                        send: Mutex::new(Some(send)),
                        recv: Mutex::new(Some(recv)),
                        runtime_handle: stream_runtime_handle.clone(),
                    });
                    if connection_stream_tx.send(stream).await.is_err() {
                        return;
                    }
                }
            });
        }
    })
}

/// Wraps an `iroh::Endpoint` and exposes the eight-function surface the Swift
/// `OpenBurnBarIrohEndpoint` actor calls into.
#[derive(uniffi::Object)]
pub struct IrohEndpointHandle {
    endpoint: Mutex<Option<Endpoint>>,
    runtime: Mutex<Option<Runtime>>,
    runtime_handle: Mutex<Option<tokio::runtime::Handle>>,
    identity: Mutex<Option<IrohNodeIdentity>>,
    services_client: Mutex<Option<IrohServicesClient>>,
    incoming_stream_rx: Mutex<Option<mpsc::Receiver<Arc<IrohStream>>>>,
    incoming_accept_task: Mutex<Option<JoinHandle<()>>>,
    /// Inbound admission controls (T-TRN-06): per-source rate limit,
    /// concurrent-handshake cap, and optional NodeId allowlist. Lives on the
    /// handle (not per-bootstrap) so a `set_inbound_allowlist` call survives a
    /// re-bootstrap and the rate-limit state is shared across the handle.
    inbound_admission: Arc<InboundAdmission>,
}

#[uniffi::export]
impl IrohEndpointHandle {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            endpoint: Mutex::new(None),
            runtime: Mutex::new(None),
            runtime_handle: Mutex::new(None),
            identity: Mutex::new(None),
            services_client: Mutex::new(None),
            incoming_stream_rx: Mutex::new(None),
            incoming_accept_task: Mutex::new(None),
            inbound_admission: Arc::new(InboundAdmission::new(
                OPENBURNBAR_INBOUND_RATE_WINDOW,
                OPENBURNBAR_INBOUND_MAX_CONNECTIONS_PER_WINDOW,
                OPENBURNBAR_MAX_CONCURRENT_INBOUND_HANDSHAKES,
            )),
        })
    }

    /// Spawn the iroh endpoint with the supplied 32-byte secret key. Idempotent
    /// per handle; calling twice replaces the inner endpoint. Returns the
    /// node identity (public key + base32 NodeId).
    ///
    /// Phase 6+: callers can pass a non-empty `relay_url` to pin a specific
    /// hosted relay (e.g., the $200/mo n0 hosted tier provisioned via the
    /// services API and surfaced by `scripts/cutover-n0-hosted-relay.sh`).
    /// Empty string means "use n0's public relay set" (the default in
    /// phases 1-5).
    pub fn bootstrap(
        self: Arc<Self>,
        secret: IrohSecretKeyMaterial,
        relay_url: String,
    ) -> Result<IrohNodeIdentity, IrohFfiError> {
        if secret.raw.len() != 32 {
            return Err(IrohFfiError::InvalidSecretKey);
        }
        let mut key_bytes = [0u8; 32];
        key_bytes.copy_from_slice(&secret.raw);
        let secret_key = SecretKey::from_bytes(&key_bytes);

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("openburnbar-iroh")
            .build()
            .map_err(IrohFfiError::runtime)?;

        let configured_relay_url = relay_url.trim().to_string();
        let relay_mode = if configured_relay_url.is_empty() {
            RelayMode::Default
        } else {
            let url: RelayUrl =
                configured_relay_url
                    .parse()
                    .map_err(
                        |err: iroh::RelayUrlParseError| IrohFfiError::RuntimeFailed {
                            detail: format!("invalid relay url: {err}"),
                        },
                    )?;
            RelayMode::Custom(RelayMap::from(url))
        };
        let transport_config = openburnbar_transport_config()?;

        let endpoint = runtime
            .block_on(async {
                Endpoint::builder(presets::N0)
                    .secret_key(secret_key.clone())
                    .alpns(vec![OPENBURNBAR_ALPN.to_vec()])
                    .relay_mode(relay_mode)
                    .transport_config(transport_config)
                    .bind()
                    .await
            })
            .map_err(IrohFfiError::runtime)?;

        let identity = runtime.block_on(async {
            tokio::time::timeout(Duration::from_secs(10), endpoint.online())
                .await
                .map_err(|_| IrohFfiError::RuntimeFailed {
                    detail: "iroh endpoint did not come online within 10s".into(),
                })?;

            let addr = endpoint.addr();
            let selected_relay_url = addr
                .relay_urls()
                .next()
                .map(ToString::to_string)
                .unwrap_or_default();
            let published_relay_url = if configured_relay_url.is_empty() {
                selected_relay_url
            } else {
                configured_relay_url.clone()
            };

            let direct_addresses = addr.ip_addrs().map(ToString::to_string).collect();

            let node_id = endpoint.id();
            Ok::<_, IrohFfiError>(IrohNodeIdentity {
                raw_public_key: node_id.as_bytes().to_vec(),
                node_id: node_id.to_string(),
                relay_url: published_relay_url,
                direct_addresses,
            })
        })?;
        let services_client =
            runtime.block_on(async { start_iroh_services_if_configured(&endpoint).await })?;

        let runtime_handle = runtime.handle().clone();
        let (incoming_stream_tx, incoming_stream_rx) = mpsc::channel(128);
        let incoming_accept_task = spawn_incoming_stream_acceptor(
            endpoint.clone(),
            runtime_handle.clone(),
            incoming_stream_tx,
            Arc::clone(&self.inbound_admission),
        );
        block_on(async {
            if let Some(previous_accept_task) = self.incoming_accept_task.lock().await.take() {
                previous_accept_task.abort();
            }
            *self.endpoint.lock().await = Some(endpoint);
            *self.runtime_handle.lock().await = Some(runtime_handle);
            *self.runtime.lock().await = Some(runtime);
            *self.identity.lock().await = Some(identity.clone());
            *self.services_client.lock().await = services_client;
            *self.incoming_stream_rx.lock().await = Some(incoming_stream_rx);
            *self.incoming_accept_task.lock().await = Some(incoming_accept_task);
            Ok::<_, IrohFfiError>(())
        })?;

        Ok(identity)
    }

    /// Returns the cached identity if `bootstrap` has been called.
    pub fn identity(self: Arc<Self>) -> Result<IrohNodeIdentity, IrohFfiError> {
        block_on(async move {
            self.identity
                .lock()
                .await
                .clone()
                .ok_or(IrohFfiError::EndpointNotInitialized)
        })
    }

    /// Restrict inbound peers to the supplied base32 NodeIds (T-TRN-06).
    /// Non-allowlisted peers are rejected in the acceptor before any stream
    /// reaches `accept_one`. Passing an empty list clears the restriction and
    /// defers to the Swift-side allowlist. Safe to call before or after
    /// `bootstrap`; the admission state lives on the handle, not the endpoint.
    pub fn set_inbound_allowlist(self: Arc<Self>, node_ids: Vec<String>) {
        self.inbound_admission.set_allowlist(node_ids);
    }

    /// Dial a remote node by NodeId (base32 surface form) and open one
    /// bidirectional stream. The caller is responsible for stream lifetime.
    pub fn connect(
        self: Arc<Self>,
        node_id: String,
        relay_url: String,
        direct_addresses: Vec<String>,
        timeout_seconds: u32,
    ) -> Result<Arc<IrohStream>, IrohFfiError> {
        let (endpoint, runtime_handle) = block_on(async {
            let endpoint = self
                .endpoint
                .lock()
                .await
                .clone()
                .ok_or(IrohFfiError::EndpointNotInitialized)?;
            let runtime_handle = self
                .runtime_handle
                .lock()
                .await
                .clone()
                .ok_or(IrohFfiError::EndpointNotInitialized)?;
            Ok::<_, IrohFfiError>((endpoint, runtime_handle))
        })?;

        let target: EndpointId = node_id.parse().map_err(|_| IrohFfiError::InvalidNodeId)?;
        let relay_url = relay_url.trim();
        let relay_url = if relay_url.is_empty() {
            None
        } else {
            Some(relay_url.parse().map_err(|err: iroh::RelayUrlParseError| {
                IrohFfiError::ConnectFailed {
                    detail: format!("invalid relay url: {err}"),
                }
            })?)
        };
        let direct_addresses = direct_addresses
            .into_iter()
            .filter(|addr| !addr.trim().is_empty())
            .map(|addr| {
                addr.parse::<SocketAddr>()
                    .map_err(|err| IrohFfiError::ConnectFailed {
                        detail: format!("invalid direct address {addr}: {err}"),
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut node_addr = EndpointAddr::new(target);
        if let Some(relay_url) = relay_url {
            node_addr = node_addr.with_relay_url(relay_url);
        }
        if !direct_addresses.is_empty() {
            node_addr = node_addr.with_addrs(direct_addresses.into_iter().map(TransportAddr::Ip));
        }
        let timeout = Duration::from_secs(timeout_seconds.max(1) as u64);

        let stream_runtime_handle = runtime_handle.clone();
        runtime_handle.block_on(async move {
            let (conn, send, recv, remote_node_id) = tokio::time::timeout(timeout, async move {
                let conn = endpoint
                    .connect(node_addr, OPENBURNBAR_ALPN)
                    .await
                    .map_err(IrohFfiError::connect)?;
                let remote_node_id = conn.remote_id().to_string();
                let (send, recv) = conn.open_bi().await.map_err(IrohFfiError::stream)?;
                Ok::<_, IrohFfiError>((conn, send, recv, remote_node_id))
            })
            .await
            .map_err(|_| IrohFfiError::ConnectFailed {
                detail: "iroh connect timed out".into(),
            })??;
            Ok(Arc::new(IrohStream {
                remote_node_id,
                conn: Mutex::new(Some(conn)),
                send: Mutex::new(Some(send)),
                recv: Mutex::new(Some(recv)),
                runtime_handle: stream_runtime_handle,
            }))
        })
    }

    /// Block waiting for one inbound bidirectional stream.
    ///
    /// The endpoint owns a background acceptor that accepts each peer
    /// connection once and then drains every bidirectional stream opened on
    /// that connection into this queue. This matters because iroh may reuse an
    /// existing QUIC connection for later Mercury streams; waiting on
    /// `endpoint.accept()` for every stream would miss those reused streams and
    /// make clients connect/disconnect in a loop.
    pub fn accept_one(
        self: Arc<Self>,
        timeout_seconds: u32,
    ) -> Result<Arc<IrohStream>, IrohFfiError> {
        let runtime_handle = block_on(async {
            let runtime_handle = self
                .runtime_handle
                .lock()
                .await
                .clone()
                .ok_or(IrohFfiError::EndpointNotInitialized)?;
            if self.incoming_stream_rx.lock().await.is_none() {
                return Err(IrohFfiError::EndpointNotInitialized);
            }
            Ok::<_, IrohFfiError>(runtime_handle)
        })?;
        let timeout = Duration::from_secs(timeout_seconds.max(1) as u64);
        runtime_handle.block_on(async move {
            let mut receiver_guard = self.incoming_stream_rx.lock().await;
            let receiver = receiver_guard
                .as_mut()
                .ok_or(IrohFfiError::EndpointNotInitialized)?;
            tokio::time::timeout(timeout, receiver.recv())
                .await
                .map_err(|_| IrohFfiError::AcceptFailed {
                    detail: "iroh accept timed out".into(),
                })?
                .ok_or_else(|| IrohFfiError::AcceptFailed {
                    detail: "iroh endpoint closed before accepting".into(),
                })
        })
    }

    /// Cleanly close the endpoint. After shutdown the handle is unusable.
    pub fn shutdown(self: Arc<Self>) -> Result<(), IrohFfiError> {
        let endpoint_opt = block_on(async {
            if let Some(accept_task) = self.incoming_accept_task.lock().await.take() {
                accept_task.abort();
            }
            let _ = self.incoming_stream_rx.lock().await.take();
            let endpoint = self.endpoint.lock().await.take();
            let runtime = self.runtime.lock().await.take();
            let _ = self.runtime_handle.lock().await.take();
            let _ = self.services_client.lock().await.take();
            *self.identity.lock().await = None;
            Ok::<_, IrohFfiError>((endpoint, runtime))
        })?;

        if let (Some(endpoint), Some(runtime)) = endpoint_opt {
            runtime.block_on(async move {
                endpoint.close().await;
            });
            // Drop the runtime explicitly so any spawned tasks are shut down
            // before this function returns. Swift never reuses the handle
            // after shutdown.
            drop(runtime);
        }
        Ok(())
    }
}

#[uniffi::export]
pub fn generate_secret_key_material() -> IrohSecretKeyMaterial {
    let secret = SecretKey::generate();
    IrohSecretKeyMaterial {
        raw: secret.to_bytes().to_vec(),
    }
}

#[uniffi::export]
pub fn openburnbar_alpn() -> Vec<u8> {
    OPENBURNBAR_ALPN.to_vec()
}

#[uniffi::export]
pub fn openburnbar_iroh_protocol_version() -> u32 {
    1
}

async fn start_iroh_services_if_configured(
    endpoint: &Endpoint,
) -> Result<Option<IrohServicesClient>, IrohFfiError> {
    let secret = match std::env::var(IROH_SERVICES_API_SECRET_ENV) {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return Ok(None),
    };
    let required = std::env::var(OPENBURNBAR_IROH_SERVICES_REQUIRED_ENV)
        .map(|value| truthy_env_value(&value))
        .unwrap_or(false);
    let endpoint_name = std::env::var(OPENBURNBAR_IROH_SERVICES_ENDPOINT_NAME_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default_iroh_services_endpoint_name(endpoint.id()));

    let build_client = || {
        IrohServicesClient::builder(endpoint)
            .api_secret_from_str(secret.trim())
            .and_then(|builder| builder.name(endpoint_name.clone()))
    };
    let builder = match build_client() {
        Ok(builder) => builder,
        Err(err) if required => return Err(IrohFfiError::runtime(err)),
        Err(err) => {
            eprintln!("openburnbar-iroh: Iroh Services disabled after configuration error: {err}");
            return Ok(None);
        }
    };
    let client = match tokio::time::timeout(Duration::from_secs(15), builder.build()).await {
        Ok(Ok(client)) => client,
        Ok(Err(err)) if required => return Err(IrohFfiError::runtime(err)),
        Err(_) if required => {
            return Err(IrohFfiError::RuntimeFailed {
                detail: "iroh services client build timed out".into(),
            });
        }
        Ok(Err(err)) => {
            eprintln!(
                "openburnbar-iroh: Iroh Services client failed to start; endpoint remains available without native metrics: {err}"
            );
            return Ok(None);
        }
        Err(_) => {
            eprintln!(
                "openburnbar-iroh: Iroh Services client start timed out; endpoint remains available without native metrics"
            );
            return Ok(None);
        }
    };
    Ok(Some(client))
}

fn truthy_env_value(value: &str) -> bool {
    let normalized = value.trim();
    normalized == "1" || normalized.eq_ignore_ascii_case("true")
}

fn default_iroh_services_endpoint_name(endpoint_id: EndpointId) -> String {
    let id = endpoint_id.to_string();
    let short = id.get(..12).unwrap_or(&id);
    format!("openburnbar-{short}")
}

pub(crate) fn block_on<F, T>(future: F) -> T
where
    F: std::future::Future<Output = T>,
{
    // Caller-side block_on runs on the iroh-owned multi-thread runtime when
    // available; otherwise we use a transient single-thread runtime for
    // construction-time work (which never holds the endpoint mutex).
    let handle = tokio::runtime::Handle::try_current();
    match handle {
        Ok(handle) => handle.block_on(future),
        Err(_) => match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime.block_on(future),
            Err(error) => panic!("tokio runtime build failed: {error}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iroh_services_required_env_accepts_only_explicit_truthy_values() {
        assert!(truthy_env_value("1"));
        assert!(truthy_env_value("true"));
        assert!(truthy_env_value(" TRUE "));

        assert!(!truthy_env_value(""));
        assert!(!truthy_env_value("0"));
        assert!(!truthy_env_value("false"));
        assert!(!truthy_env_value("yes"));
    }

    #[test]
    fn default_iroh_services_endpoint_name_is_stable_and_human_scannable() {
        let endpoint_id = EndpointId::from(SecretKey::generate().public());
        let id = endpoint_id.to_string();
        let name = default_iroh_services_endpoint_name(endpoint_id);

        assert!(name.starts_with("openburnbar-"));
        assert_eq!(name, format!("openburnbar-{}", &id[..12]));
        assert!(name.len() <= "openburnbar-".len() + 12);
    }

    #[test]
    fn frame_length_guard_allows_boundary_frame() {
        assert_eq!(OPENBURNBAR_MAX_FRAME_BYTES, 512 * 1024);
        assert!(assert_openburnbar_frame_length(OPENBURNBAR_MAX_FRAME_BYTES).is_ok());
    }

    #[test]
    fn frame_length_guard_rejects_before_allocation() {
        let err = match assert_openburnbar_frame_length(OPENBURNBAR_MAX_FRAME_BYTES + 1) {
            Ok(()) => panic!("oversized frame must be rejected"),
            Err(error) => error,
        };
        match err {
            IrohFfiError::StreamFailed { detail } => {
                assert!(detail.contains("frame too large"));
                assert!(detail.contains(&(OPENBURNBAR_MAX_FRAME_BYTES + 1).to_string()));
                assert!(detail.contains(&OPENBURNBAR_MAX_FRAME_BYTES.to_string()));
            }
            other => panic!("expected StreamFailed, got {other:?}"),
        }
    }

    fn ip_source(last_octet: u8) -> InboundSource {
        InboundSource::Ip(IpAddr::from([10, 0, 0, last_octet]))
    }

    #[test]
    fn inbound_rate_limit_refuses_a_single_source_connect_storm() {
        let admission = InboundAdmission::new(Duration::from_secs(10), 3, 64);
        let source = ip_source(7);
        let now = Instant::now();

        // The first `max_per_window` attempts inside the window are admitted.
        assert!(admission.admit_at(&source, now));
        assert!(admission.admit_at(&source, now));
        assert!(admission.admit_at(&source, now));
        // The next attempt in the same window is refused.
        assert!(!admission.admit_at(&source, now));
        assert!(!admission.admit_at(&source, now + Duration::from_secs(1)));
    }

    #[test]
    fn inbound_rate_limit_is_per_source_and_recovers_after_window() {
        let admission = InboundAdmission::new(Duration::from_secs(10), 2, 64);
        let attacker = ip_source(1);
        let paired = ip_source(2);
        let now = Instant::now();

        assert!(admission.admit_at(&attacker, now));
        assert!(admission.admit_at(&attacker, now));
        assert!(!admission.admit_at(&attacker, now));
        // A different source has its own independent budget.
        assert!(admission.admit_at(&paired, now));
        assert!(admission.admit_at(&paired, now));
        // Once the window has fully elapsed, the attacker's budget refills.
        let later = now + Duration::from_secs(11);
        assert!(admission.admit_at(&attacker, later));
    }

    #[test]
    fn inbound_rate_limit_keys_relay_dials_by_node_id() {
        let admission = InboundAdmission::new(Duration::from_secs(10), 1, 64);
        let node_a = InboundSource::Node("node-a".into());
        let node_b = InboundSource::Node("node-b".into());
        let now = Instant::now();

        assert!(admission.admit_at(&node_a, now));
        assert!(!admission.admit_at(&node_a, now));
        // A distinct relayed NodeId is not penalized by node-a's storm.
        assert!(admission.admit_at(&node_b, now));
    }

    #[test]
    fn concurrent_handshake_cap_blocks_when_slots_are_exhausted() {
        let admission = InboundAdmission::new(Duration::from_secs(10), 1000, 2);
        // Two permits available, then exhausted.
        let p1 = admission.handshake_slots.try_acquire().unwrap();
        let p2 = admission.handshake_slots.try_acquire().unwrap();
        assert!(admission.handshake_slots.try_acquire().is_err());
        // Releasing one permit frees a slot for the next handshake.
        drop(p1);
        assert!(admission.handshake_slots.try_acquire().is_ok());
        drop(p2);
    }

    #[test]
    fn allowlist_empty_permits_all_then_restricts_once_set() {
        let admission = InboundAdmission::new(Duration::from_secs(10), 1000, 64);
        // No list configured → permit all (Swift allowlist still gates downstream).
        assert!(admission.node_allowed("any-peer"));

        admission.set_allowlist(vec!["  paired-peer  ".into(), String::new()]);
        // Trimmed, non-empty entries are honored; whitespace-only entries dropped.
        assert!(admission.node_allowed("paired-peer"));
        assert!(admission.node_allowed("  paired-peer "));
        // A peer not on the list is rejected early — fail closed.
        assert!(!admission.node_allowed("hostile-peer"));

        // Clearing the list restores permit-all.
        admission.set_allowlist(vec![]);
        assert!(admission.node_allowed("hostile-peer"));
    }
}
