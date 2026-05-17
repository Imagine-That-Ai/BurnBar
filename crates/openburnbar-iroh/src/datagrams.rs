// Mercury Phase 1 audio datagram channel.
//
// Voice over QUIC datagrams (per `plans/2026-05-15-mercury-media-master-plan.md`
// § B.4): Opus packets at 64 kbps mono with 20 ms framing are ~120 bytes,
// well below the iroh-net MTU. Datagrams are loss-tolerant and don't
// re-order — perfect for Opus PLC + a 60 ms jitter buffer in the receiver.
//
// Wire shape: a single `IrohDatagramChannel` wraps one `iroh::endpoint::Connection`
// and exposes `send(bytes)` / `recv(timeout)` to Swift / Kotlin. The
// channel is created either by dialing a peer (`open_datagram_channel`)
// or by accepting one (`accept_datagram_channel`). Both sides MUST agree
// on the datagram ALPN below before exchanging packets.

use std::sync::Arc;
use std::time::Duration;

use iroh::endpoint::Connection;
use iroh::{Endpoint, NodeAddr, NodeId, RelayUrl};
use tokio::sync::Mutex;

use crate::{block_on, IrohEndpointHandle, IrohFfiError};

/// Mercury audio ALPN. We pin a distinct ALPN from the chat / blob ALPNs so
/// the accept side classifies datagram-only connections without any
/// per-frame discriminator.
pub const MERCURY_AUDIO_ALPN: &[u8] = b"openburnbar/mercury/audio/1";

/// A single datagram channel — one `Connection` dedicated to small,
/// unreliable, unordered packets. Audio only for now; future video
/// callers should NOT reuse this object — they get their own QUIC
/// streams per GOP per the master plan.
#[derive(uniffi::Object)]
pub struct IrohDatagramChannel {
    inner: Mutex<Option<DatagramChannelInner>>,
    runtime_handle: tokio::runtime::Handle,
}

struct DatagramChannelInner {
    conn: Connection,
}

#[uniffi::export]
impl IrohDatagramChannel {
    /// Send a single datagram. Length is the in-flight MTU (1200 bytes on
    /// most networks) — anything larger fails with `StreamFailed`. The
    /// sender is responsible for keeping each Opus packet under the MTU.
    pub fn send(self: Arc<Self>, packet: Vec<u8>) -> Result<(), IrohFfiError> {
        let handle = self.runtime_handle.clone();
        handle.block_on(async move {
            let guard = self.inner.lock().await;
            let inner = guard.as_ref().ok_or(IrohFfiError::EndpointNotInitialized)?;
            inner
                .conn
                .send_datagram(packet.into())
                .map_err(IrohFfiError::stream)
        })
    }

    /// Receive one datagram with a bounded wait. Returns `None` if the
    /// peer closed the connection before a packet arrived. `timeout_millis`
    /// is the per-call ceiling — receivers should drive a tight loop at
    /// the Opus framing cadence (20 ms) plus a small safety margin.
    pub fn recv(self: Arc<Self>, timeout_millis: u32) -> Result<Option<Vec<u8>>, IrohFfiError> {
        let handle = self.runtime_handle.clone();
        let timeout = Duration::from_millis(timeout_millis.max(1) as u64);
        handle.block_on(async move {
            let guard = self.inner.lock().await;
            let inner = guard.as_ref().ok_or(IrohFfiError::EndpointNotInitialized)?;
            match tokio::time::timeout(timeout, inner.conn.read_datagram()).await {
                Ok(Ok(bytes)) => Ok(Some(bytes.to_vec())),
                Ok(Err(err)) => match err {
                    iroh::endpoint::ConnectionError::ApplicationClosed(_)
                    | iroh::endpoint::ConnectionError::ConnectionClosed(_)
                    | iroh::endpoint::ConnectionError::LocallyClosed => Ok(None),
                    other => Err(IrohFfiError::stream(other)),
                },
                Err(_elapsed) => Ok(None),
            }
        })
    }

    /// Cleanly close the underlying connection. Idempotent.
    pub fn close_channel(self: Arc<Self>) -> Result<(), IrohFfiError> {
        let handle = self.runtime_handle.clone();
        handle.block_on(async move {
            if let Some(inner) = self.inner.lock().await.take() {
                inner.conn.close(0u32.into(), b"mercury-audio-close");
            }
            Ok(())
        })
    }

    /// Maximum datagram payload size negotiated for this connection.
    /// Returns 0 if datagrams aren't supported (peer disabled them).
    pub fn max_datagram_size(self: Arc<Self>) -> Result<u32, IrohFfiError> {
        let handle = self.runtime_handle.clone();
        handle.block_on(async move {
            let guard = self.inner.lock().await;
            let inner = guard.as_ref().ok_or(IrohFfiError::EndpointNotInitialized)?;
            Ok(inner.conn.max_datagram_size().unwrap_or(0) as u32)
        })
    }
}

#[uniffi::export]
impl IrohEndpointHandle {
    /// Dial a remote NodeId on the Mercury audio ALPN and return a
    /// datagram-only channel. The chat ALPN endpoint must already be
    /// bootstrapped — this method reuses the same iroh `Endpoint` so it
    /// shares discovery + relay state.
    pub fn open_datagram_channel(
        self: Arc<Self>,
        node_id: String,
        relay_url: String,
        direct_addresses: Vec<String>,
        timeout_seconds: u32,
    ) -> Result<Arc<IrohDatagramChannel>, IrohFfiError> {
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

        let target: NodeId = node_id.parse().map_err(|_| IrohFfiError::InvalidNodeId)?;
        let mut node_addr = NodeAddr::new(target);
        let relay = relay_url.trim();
        if !relay.is_empty() {
            let url: RelayUrl = relay.parse().map_err(|err: iroh::RelayUrlParseError| {
                IrohFfiError::ConnectFailed {
                    detail: format!("invalid relay url: {err}"),
                }
            })?;
            node_addr = node_addr.with_relay_url(url);
        }
        let parsed_addresses = direct_addresses
            .into_iter()
            .filter(|addr| !addr.trim().is_empty())
            .map(|addr| {
                addr.parse::<std::net::SocketAddr>()
                    .map_err(|err| IrohFfiError::ConnectFailed {
                        detail: format!("invalid direct address {addr}: {err}"),
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if !parsed_addresses.is_empty() {
            node_addr = node_addr.with_direct_addresses(parsed_addresses);
        }

        let timeout = Duration::from_secs(timeout_seconds.max(1) as u64);
        let conn = connect_audio(endpoint, node_addr, runtime_handle.clone(), timeout)?;
        Ok(Arc::new(IrohDatagramChannel {
            inner: Mutex::new(Some(DatagramChannelInner { conn })),
            runtime_handle,
        }))
    }

    /// Block waiting for an inbound Mercury audio datagram connection.
    /// Mac uses this in a loop on a dedicated accept task; iOS / Android
    /// dial outbound and rarely accept.
    pub fn accept_datagram_channel(
        self: Arc<Self>,
        timeout_seconds: u32,
    ) -> Result<Arc<IrohDatagramChannel>, IrohFfiError> {
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
        let timeout = Duration::from_secs(timeout_seconds.max(1) as u64);
        let conn = accept_audio(endpoint, runtime_handle.clone(), timeout)?;
        Ok(Arc::new(IrohDatagramChannel {
            inner: Mutex::new(Some(DatagramChannelInner { conn })),
            runtime_handle,
        }))
    }
}

fn connect_audio(
    endpoint: Endpoint,
    node_addr: NodeAddr,
    runtime_handle: tokio::runtime::Handle,
    timeout: Duration,
) -> Result<Connection, IrohFfiError> {
    runtime_handle.block_on(async move {
        let conn = tokio::time::timeout(timeout, endpoint.connect(node_addr, MERCURY_AUDIO_ALPN))
            .await
            .map_err(|_| IrohFfiError::ConnectFailed {
                detail: "iroh audio connect timed out".into(),
            })?
            .map_err(IrohFfiError::connect)?;
        Ok(conn)
    })
}

fn accept_audio(
    endpoint: Endpoint,
    runtime_handle: tokio::runtime::Handle,
    timeout: Duration,
) -> Result<Connection, IrohFfiError> {
    runtime_handle.block_on(async move {
        let conn = tokio::time::timeout(timeout, async {
            let incoming = endpoint
                .accept()
                .await
                .ok_or_else(|| IrohFfiError::AcceptFailed {
                    detail: "iroh endpoint closed before accepting".into(),
                })?;
            incoming.await.map_err(IrohFfiError::accept)
        })
        .await
        .map_err(|_| IrohFfiError::AcceptFailed {
            detail: "iroh audio accept timed out".into(),
        })??;
        Ok(conn)
    })
}

/// Exported constant so platform code never has to hardcode the ALPN.
#[uniffi::export]
pub fn mercury_audio_alpn() -> Vec<u8> {
    MERCURY_AUDIO_ALPN.to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mercury_audio_alpn_matches_constant() {
        assert_eq!(mercury_audio_alpn(), MERCURY_AUDIO_ALPN.to_vec());
    }

    #[test]
    fn mercury_audio_alpn_is_distinct_from_chat() {
        assert_ne!(MERCURY_AUDIO_ALPN, crate::OPENBURNBAR_ALPN);
    }
}
