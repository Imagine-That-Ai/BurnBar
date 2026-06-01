use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use burnbar_remote_core::{
    AccountId, DeviceId, EndpointId as CoreEndpointId, SequenceNumber, SessionMode,
    TimestampMicros, WorkspaceId,
};
use burnbar_remote_observability::{NetworkTelemetry, PathKind, PathState};
use burnbar_remote_protocol::{
    decode_control, encode_control, HeartbeatMessage, MessageKind, ReliableFramePrefix,
    SessionDeniedMessage, SessionRequestMessage, StreamClass, RELIABLE_PREFIX_LEN, REMOTE_ALPN,
    WIRE_VERSION,
};
use burnbar_remote_security::{
    PeerAuthorizationRequest, SessionAuthorizer, SessionGrant, SessionGrantSigner,
    SessionGrantVerifier, SignedSessionGrant,
};
use bytes::Bytes;
use iroh::endpoint::{presets, Connection, QuicTransportConfig, RecvStream, SendStream, VarInt};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl, SecretKey, TransportAddr,
};
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TrySendError;
use tokio_stream::StreamExt;
use tracing::{debug, info, warn};

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("endpoint failed: {0}")]
    Endpoint(String),
    #[error("connect failed: {0}")]
    Connect(String),
    #[error("accept failed: {0}")]
    Accept(String),
    #[error("stream failed: {0}")]
    Stream(String),
    #[error("datagrams are unsupported by peer")]
    DatagramUnsupported,
    #[error("datagram too large: {actual} > {max}")]
    DatagramTooLarge { actual: usize, max: usize },
    #[error("media datagram dropped because send buffer has {available} bytes for {needed} bytes")]
    DatagramCongested { available: usize, needed: usize },
    #[error("authorization failed: {0}")]
    Authorization(#[from] burnbar_remote_security::AuthorizationError),
    #[error("session denied by remote host: {code}: {message}")]
    SessionDenied { code: String, message: String },
    #[error("protocol failed: {0}")]
    Protocol(#[from] burnbar_remote_protocol::ProtocolError),
}

#[derive(Clone, Debug)]
pub enum RelayConfig {
    Default,
    Disabled,
    Custom(String),
}

impl RelayConfig {
    fn into_iroh(self) -> Result<RelayMode, TransportError> {
        match self {
            Self::Default => Ok(RelayMode::Default),
            Self::Disabled => Ok(RelayMode::Disabled),
            Self::Custom(url) => {
                let url: RelayUrl = url
                    .parse()
                    .map_err(|err| TransportError::Endpoint(format!("invalid relay url: {err}")))?;
                Ok(RelayMode::Custom(RelayMap::from(url)))
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct IrohTransportConfig {
    pub secret_key: Option<[u8; 32]>,
    pub alpn: Vec<u8>,
    pub relay: RelayConfig,
    pub keep_alive_interval: Duration,
    pub max_idle_timeout: Duration,
    pub max_control_frame_bytes: usize,
    pub max_concurrent_bi_streams: u32,
    pub max_concurrent_uni_streams: u32,
}

impl Default for IrohTransportConfig {
    fn default() -> Self {
        Self {
            secret_key: None,
            alpn: REMOTE_ALPN.to_vec(),
            relay: RelayConfig::Default,
            keep_alive_interval: Duration::from_secs(1),
            max_idle_timeout: Duration::from_secs(60),
            max_control_frame_bytes: 64 * 1024,
            max_concurrent_bi_streams: 16,
            max_concurrent_uni_streams: 8,
        }
    }
}

#[derive(Clone, Debug)]
pub struct LocalEndpointIdentity {
    pub endpoint_id: CoreEndpointId,
    pub relay_urls: Vec<String>,
    pub direct_addresses: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct RemoteEndpointAddress {
    pub endpoint_id: CoreEndpointId,
    pub relay_url: Option<String>,
    pub direct_addresses: Vec<SocketAddr>,
}

#[derive(Clone, Debug)]
pub struct ClientSessionRequestContext {
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub client_device_id: DeviceId,
    pub requested_mode: SessionMode,
    pub now: TimestampMicros,
}

#[derive(Clone, Debug)]
pub struct HostSessionAuthorizationContext {
    pub host_device_id: DeviceId,
    pub local_consent_granted: bool,
    pub now: TimestampMicros,
}

#[derive(Clone)]
pub struct IrohTransportSecurity {
    pub authorizer: Arc<dyn SessionAuthorizer>,
    pub grant_signer: Arc<dyn SessionGrantSigner>,
    pub grant_verifier: Arc<dyn SessionGrantVerifier>,
}

pub struct IrohTransportManager {
    endpoint: Endpoint,
    security: IrohTransportSecurity,
    config: IrohTransportConfig,
}

impl IrohTransportManager {
    pub async fn bind(
        config: IrohTransportConfig,
        security: IrohTransportSecurity,
    ) -> Result<Self, TransportError> {
        let mut builder = Endpoint::builder(presets::N0)
            .alpns(vec![config.alpn.clone()])
            .relay_mode(config.relay.clone().into_iroh()?);
        if let Some(secret) = config.secret_key {
            builder = builder.secret_key(SecretKey::from_bytes(&secret));
        }
        let idle = config
            .max_idle_timeout
            .try_into()
            .map_err(|err| TransportError::Endpoint(format!("invalid idle timeout: {err}")))?;
        let transport_config = QuicTransportConfig::builder()
            .keep_alive_interval(config.keep_alive_interval)
            .max_idle_timeout(Some(idle))
            .max_concurrent_bidi_streams(VarInt::from_u32(config.max_concurrent_bi_streams))
            .max_concurrent_uni_streams(VarInt::from_u32(config.max_concurrent_uni_streams))
            .build();
        let endpoint = builder
            .transport_config(transport_config)
            .bind()
            .await
            .map_err(|err| TransportError::Endpoint(err.to_string()))?;
        endpoint.online().await;
        info!(endpoint_id = %endpoint.id(), "burnbar remote iroh endpoint online");
        Ok(Self {
            endpoint,
            security,
            config,
        })
    }

    pub fn identity(&self) -> LocalEndpointIdentity {
        let addr = self.endpoint.addr();
        LocalEndpointIdentity {
            endpoint_id: CoreEndpointId::new(self.endpoint.id().to_string()),
            relay_urls: addr.relay_urls().map(ToString::to_string).collect(),
            direct_addresses: addr.ip_addrs().map(ToString::to_string).collect(),
        }
    }

    pub async fn connect(
        &self,
        remote: RemoteEndpointAddress,
        request: ClientSessionRequestContext,
    ) -> Result<AuthorizedConnection, TransportError> {
        let addr = endpoint_addr(remote)?;
        let conn = self
            .endpoint
            .connect(addr, &self.config.alpn)
            .await
            .map_err(|err| TransportError::Connect(err.to_string()))?;
        self.client_session_handshake(conn, request).await
    }

    pub async fn accept_next(
        &self,
        request: HostSessionAuthorizationContext,
    ) -> Result<AuthorizedConnection, TransportError> {
        let incoming = self
            .endpoint
            .accept()
            .await
            .ok_or_else(|| TransportError::Accept("endpoint closed".into()))?;
        let conn = incoming
            .await
            .map_err(|err| TransportError::Accept(err.to_string()))?;
        self.host_session_handshake(conn, request).await
    }

    pub async fn shutdown(self) {
        self.endpoint.close().await;
    }

    async fn client_session_handshake(
        &self,
        conn: Connection,
        request: ClientSessionRequestContext,
    ) -> Result<AuthorizedConnection, TransportError> {
        let remote_id = conn.remote_id().to_string();
        let mut channel =
            open_reliable_channel(&conn, StreamClass::Control, self.config.max_control_frame_bytes)
                .await?;
        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce)
            .map_err(|err| TransportError::Connect(format!("nonce generation failed: {err}")))?;
        let request_message = SessionRequestMessage {
            version: WIRE_VERSION,
            client_endpoint_id: CoreEndpointId::new(self.endpoint.id().to_string()),
            client_device_id: request.client_device_id,
            account_id: request.account_id,
            workspace_id: request.workspace_id,
            requested_mode: request.requested_mode,
            nonce,
            requested_at: request.now,
        };
        let mut scratch = Vec::with_capacity(256);
        encode_control(&request_message, &mut scratch)?;
        channel
            .send_frame(
                ReliableFramePrefix {
                    payload_len: scratch.len() as u32,
                    kind: MessageKind::SessionRequest,
                    flags: 0,
                },
                &scratch,
            )
            .await?;
        let (prefix, payload) = channel
            .recv_frame()
            .await?
            .ok_or_else(|| TransportError::Accept("session handshake closed".into()))?;
        match prefix.kind {
            MessageKind::SessionGrant => {
                let signed: SignedSessionGrant = decode_control(&payload)?;
                self.security.grant_verifier.verify_session_grant(&signed)?;
                Ok(AuthorizedConnection {
                    conn,
                    grant: signed.grant,
                    remote_endpoint_id: CoreEndpointId::new(remote_id),
                    max_control_frame_bytes: self.config.max_control_frame_bytes,
                })
            }
            MessageKind::SessionDenied | MessageKind::ErrorReport => {
                let denied: SessionDeniedMessage = decode_control(&payload)?;
                Err(TransportError::SessionDenied {
                    code: denied.code,
                    message: denied.message,
                })
            }
            other => Err(TransportError::Stream(format!(
                "unexpected session handshake response: {other:?}"
            ))),
        }
    }

    async fn host_session_handshake(
        &self,
        conn: Connection,
        request: HostSessionAuthorizationContext,
    ) -> Result<AuthorizedConnection, TransportError> {
        let remote_id = conn.remote_id().to_string();
        let mut channel =
            accept_reliable_channel(&conn, self.config.max_control_frame_bytes).await?;
        if channel.class != StreamClass::Control {
            return Err(TransportError::Stream(format!(
                "session handshake used {:?} stream",
                channel.class
            )));
        }
        let (prefix, payload) = channel
            .recv_frame()
            .await?
            .ok_or_else(|| TransportError::Accept("session request stream closed".into()))?;
        if prefix.kind != MessageKind::SessionRequest {
            return Err(TransportError::Stream(format!(
                "expected session request, got {:?}",
                prefix.kind
            )));
        }
        let session_request: SessionRequestMessage = decode_control(&payload)?;
        if session_request.version != WIRE_VERSION {
            self.send_session_denied(
                &mut channel,
                "unsupported_version",
                "unsupported remote protocol version",
            )
            .await?;
            return Err(TransportError::Protocol(
                burnbar_remote_protocol::ProtocolError::Serialization(format!(
                    "unsupported protocol version {}",
                    session_request.version
                )),
            ));
        }
        if session_request.client_endpoint_id.as_str() != remote_id {
            self.send_session_denied(
                &mut channel,
                "endpoint_mismatch",
                "session request endpoint does not match Iroh peer identity",
            )
            .await?;
            return Err(TransportError::Authorization(
                burnbar_remote_security::AuthorizationError::BindingMismatch,
            ));
        }
        let grant = match self
            .security
            .authorizer
            .authorize_peer(PeerAuthorizationRequest {
                remote_endpoint_id: CoreEndpointId::new(remote_id.clone()),
                requested_device_id: session_request.client_device_id,
                requested_account_id: session_request.account_id,
                requested_workspace_id: session_request.workspace_id,
                host_device_id: request.host_device_id,
                requested_mode: session_request.requested_mode,
                local_consent_granted: request.local_consent_granted,
                now: request.now,
            })
            .await
        {
            Ok(grant) => grant,
            Err(err) => {
                self.send_session_denied(&mut channel, "authorization_failed", &err.to_string())
                    .await?;
                return Err(err.into());
            }
        };
        let signed = self.security.grant_signer.sign_session_grant(grant)?;
        let mut scratch = Vec::with_capacity(512);
        encode_control(&signed, &mut scratch)?;
        channel
            .send_frame(
                ReliableFramePrefix {
                    payload_len: scratch.len() as u32,
                    kind: MessageKind::SessionGrant,
                    flags: 0,
                },
                &scratch,
            )
            .await?;
        Ok(AuthorizedConnection {
            conn,
            grant: signed.grant,
            remote_endpoint_id: CoreEndpointId::new(remote_id),
            max_control_frame_bytes: self.config.max_control_frame_bytes,
        })
    }

    async fn send_session_denied(
        &self,
        channel: &mut ReliableChannel,
        code: &str,
        message: &str,
    ) -> Result<(), TransportError> {
        let denied = SessionDeniedMessage {
            code: code.to_string(),
            message: message.to_string(),
        };
        let mut scratch = Vec::with_capacity(128);
        encode_control(&denied, &mut scratch)?;
        channel
            .send_frame(
                ReliableFramePrefix {
                    payload_len: scratch.len() as u32,
                    kind: MessageKind::SessionDenied,
                    flags: 0,
                },
                &scratch,
            )
            .await
    }
}

pub struct AuthorizedConnection {
    conn: Connection,
    grant: SessionGrant,
    remote_endpoint_id: CoreEndpointId,
    max_control_frame_bytes: usize,
}

impl AuthorizedConnection {
    pub fn grant(&self) -> &SessionGrant {
        &self.grant
    }

    pub fn remote_endpoint_id(&self) -> &CoreEndpointId {
        &self.remote_endpoint_id
    }

    pub async fn open_stream(&self, class: StreamClass) -> Result<ReliableChannel, TransportError> {
        open_reliable_channel(&self.conn, class, self.max_control_frame_bytes).await
    }

    pub async fn accept_stream(&self) -> Result<ReliableChannel, TransportError> {
        accept_reliable_channel(&self.conn, self.max_control_frame_bytes).await
    }

    pub fn try_send_media_datagram(&self, bytes: Bytes) -> Result<(), TransportError> {
        let max = self
            .conn
            .max_datagram_size()
            .ok_or(TransportError::DatagramUnsupported)?;
        if bytes.len() > max {
            return Err(TransportError::DatagramTooLarge {
                actual: bytes.len(),
                max,
            });
        }
        let available = self.conn.datagram_send_buffer_space();
        if available < bytes.len() {
            return Err(TransportError::DatagramCongested {
                available,
                needed: bytes.len(),
            });
        }
        self.conn
            .send_datagram(bytes)
            .map_err(|err| TransportError::Stream(err.to_string()))
    }

    pub async fn recv_datagram(&self) -> Result<Bytes, TransportError> {
        self.conn
            .read_datagram()
            .await
            .map_err(|err| TransportError::Stream(err.to_string()))
    }

    pub fn path_snapshot(&self) -> Vec<PathState> {
        let paths = self.conn.paths();
        paths
            .iter()
            .map(|path| PathState {
                kind: if path.is_relay() {
                    PathKind::Relay
                } else if path.is_ip() {
                    PathKind::Direct
                } else {
                    PathKind::Unknown
                },
                selected: path.is_selected(),
                remote_addr: path.remote_addr().to_string(),
            })
            .collect()
    }

    pub fn network_telemetry(&self, dropped_media_datagrams: u64) -> NetworkTelemetry {
        let paths = self.conn.paths();
        let selected = paths.iter().find(|path| path.is_selected());
        let (path_kind, rtt_micros, relay) = if let Some(path) = selected {
            let kind = if path.is_relay() {
                PathKind::Relay
            } else if path.is_ip() {
                PathKind::Direct
            } else {
                PathKind::Unknown
            };
            (
                kind,
                Some(path.rtt().as_micros().min(u64::MAX as u128) as u64),
                kind == PathKind::Relay,
            )
        } else {
            (PathKind::Unknown, None, false)
        };
        NetworkTelemetry {
            path_kind,
            rtt_micros,
            jitter_micros: None,
            packet_loss_ppm: None,
            send_queue_bytes: 0,
            datagram_send_buffer_space: self
                .conn
                .datagram_send_buffer_space()
                .min(u32::MAX as usize) as u32,
            dropped_media_datagrams,
            relay,
        }
    }

    pub fn spawn_path_event_forwarder(
        &self,
        capacity: usize,
    ) -> mpsc::Receiver<TransportPathEvent> {
        let capacity = capacity.max(1);
        let (tx, rx) = mpsc::channel(capacity);
        let mut events = self.conn.path_events();
        tokio::spawn(async move {
            while let Some(event) = events.next().await {
                let mapped = match event {
                    iroh::endpoint::PathEvent::Opened { id, remote_addr } => {
                        TransportPathEvent::Opened {
                            path_id: id.to_string(),
                            remote_addr: remote_addr.to_string(),
                            kind: classify_addr(&remote_addr),
                        }
                    }
                    iroh::endpoint::PathEvent::Closed {
                        id,
                        remote_addr,
                        last_stats,
                    } => TransportPathEvent::Closed {
                        path_id: id.to_string(),
                        remote_addr: remote_addr.to_string(),
                        kind: classify_addr(&remote_addr),
                        rtt_micros: last_stats.rtt.as_micros().min(u64::MAX as u128) as u64,
                    },
                    iroh::endpoint::PathEvent::Selected { id, remote_addr } => {
                        TransportPathEvent::Selected {
                            path_id: id.to_string(),
                            remote_addr: remote_addr.to_string(),
                            kind: classify_addr(&remote_addr),
                        }
                    }
                    iroh::endpoint::PathEvent::Lagged { missed } => {
                        TransportPathEvent::Lagged { missed }
                    }
                    _ => TransportPathEvent::Unknown,
                };
                match tx.try_send(mapped) {
                    Ok(()) => {}
                    Err(TrySendError::Closed(_)) => break,
                    Err(TrySendError::Full(_)) => {}
                }
            }
            debug!("path event forwarder stopped");
        });
        rx
    }

    pub fn close(&self, reason: &'static [u8]) {
        self.conn.close(0u32.into(), reason);
    }
}

async fn open_reliable_channel(
    conn: &Connection,
    class: StreamClass,
    max_frame_bytes: usize,
) -> Result<ReliableChannel, TransportError> {
    let (mut send, recv) = conn
        .open_bi()
        .await
        .map_err(|err| TransportError::Stream(err.to_string()))?;
    send.write_all(&[u8::from(class)])
        .await
        .map_err(|err| TransportError::Stream(err.to_string()))?;
    send.flush()
        .await
        .map_err(|err| TransportError::Stream(err.to_string()))?;
    Ok(ReliableChannel {
        class,
        send,
        recv,
        max_frame_bytes,
    })
}

async fn accept_reliable_channel(
    conn: &Connection,
    max_frame_bytes: usize,
) -> Result<ReliableChannel, TransportError> {
    let (send, mut recv) = conn
        .accept_bi()
        .await
        .map_err(|err| TransportError::Stream(err.to_string()))?;
    let mut class = [0u8; 1];
    recv.read_exact(&mut class)
        .await
        .map_err(|err| TransportError::Stream(err.to_string()))?;
    Ok(ReliableChannel {
        class: StreamClass::try_from(class[0])?,
        send,
        recv,
        max_frame_bytes,
    })
}

pub struct ReliableChannel {
    pub class: StreamClass,
    send: SendStream,
    recv: RecvStream,
    max_frame_bytes: usize,
}

impl ReliableChannel {
    pub async fn send_frame(
        &mut self,
        prefix: ReliableFramePrefix,
        payload: &[u8],
    ) -> Result<(), TransportError> {
        if payload.len() > self.max_frame_bytes {
            return Err(TransportError::Stream(format!(
                "frame too large: {} > {}",
                payload.len(),
                self.max_frame_bytes
            )));
        }
        if payload.len() != prefix.payload_len as usize {
            return Err(TransportError::Stream(
                "prefix length does not match payload".into(),
            ));
        }
        self.send
            .write_all(&prefix.encode())
            .await
            .map_err(|err| TransportError::Stream(err.to_string()))?;
        self.send
            .write_all(payload)
            .await
            .map_err(|err| TransportError::Stream(err.to_string()))?;
        self.send
            .flush()
            .await
            .map_err(|err| TransportError::Stream(err.to_string()))
    }

    pub async fn recv_frame(
        &mut self,
    ) -> Result<Option<(ReliableFramePrefix, Bytes)>, TransportError> {
        let mut prefix_bytes = [0u8; RELIABLE_PREFIX_LEN];
        match self.recv.read_exact(&mut prefix_bytes).await {
            Ok(_) => {}
            Err(iroh::endpoint::ReadExactError::FinishedEarly(0)) => return Ok(None),
            Err(err) => return Err(TransportError::Stream(err.to_string())),
        }
        let prefix = ReliableFramePrefix::decode(prefix_bytes)?;
        if prefix.payload_len as usize > self.max_frame_bytes {
            return Err(TransportError::Stream(format!(
                "frame too large: {} > {}",
                prefix.payload_len, self.max_frame_bytes
            )));
        }
        let mut payload = vec![0u8; prefix.payload_len as usize];
        self.recv
            .read_exact(&mut payload)
            .await
            .map_err(|err| TransportError::Stream(err.to_string()))?;
        Ok(Some((prefix, Bytes::from(payload))))
    }

    pub async fn send_heartbeat(
        &mut self,
        heartbeat: HeartbeatMessage,
        scratch: &mut Vec<u8>,
    ) -> Result<(), TransportError> {
        encode_control(&heartbeat, scratch)?;
        let prefix = ReliableFramePrefix {
            payload_len: scratch.len() as u32,
            kind: MessageKind::Heartbeat,
            flags: 0,
        };
        self.send_frame(prefix, scratch.as_slice()).await
    }

    pub async fn finish(mut self) -> Result<(), TransportError> {
        self.send
            .finish()
            .map_err(|err| TransportError::Stream(err.to_string()))?;
        self.send
            .stopped()
            .await
            .map_err(|err| TransportError::Stream(err.to_string()))?;
        Ok(())
    }
}

pub struct HeartbeatDriver {
    next_sequence: u64,
    scratch: Vec<u8>,
}

impl HeartbeatDriver {
    pub fn new() -> Self {
        Self {
            next_sequence: 1,
            scratch: Vec::with_capacity(128),
        }
    }

    pub async fn send_now(
        &mut self,
        channel: &mut ReliableChannel,
        now: TimestampMicros,
    ) -> Result<(), TransportError> {
        let heartbeat = HeartbeatMessage {
            sequence: SequenceNumber(self.next_sequence),
            sent_at: now,
        };
        self.next_sequence = self.next_sequence.saturating_add(1);
        channel.send_heartbeat(heartbeat, &mut self.scratch).await
    }
}

impl Default for HeartbeatDriver {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransportPathEvent {
    Opened {
        path_id: String,
        remote_addr: String,
        kind: PathKind,
    },
    Selected {
        path_id: String,
        remote_addr: String,
        kind: PathKind,
    },
    Closed {
        path_id: String,
        remote_addr: String,
        kind: PathKind,
        rtt_micros: u64,
    },
    Lagged {
        missed: u64,
    },
    Unknown,
}

fn endpoint_addr(remote: RemoteEndpointAddress) -> Result<EndpointAddr, TransportError> {
    let endpoint_id: EndpointId = remote
        .endpoint_id
        .as_str()
        .parse()
        .map_err(|_| TransportError::Connect("invalid remote endpoint id".into()))?;
    let mut addr = EndpointAddr::new(endpoint_id);
    if let Some(relay_url) = remote.relay_url {
        let relay_url: RelayUrl = relay_url
            .parse()
            .map_err(|err| TransportError::Connect(format!("invalid relay url: {err}")))?;
        addr = addr.with_relay_url(relay_url);
    }
    if !remote.direct_addresses.is_empty() {
        addr = addr.with_addrs(remote.direct_addresses.into_iter().map(TransportAddr::Ip));
    }
    Ok(addr)
}

fn classify_addr(addr: &TransportAddr) -> PathKind {
    if addr.is_relay() {
        PathKind::Relay
    } else if addr.is_ip() {
        PathKind::Direct
    } else {
        warn!(?addr, "unknown iroh path transport kind");
        PathKind::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use burnbar_remote_core::{Permission, PermissionSet};
    use burnbar_remote_protocol::decode_control;
    use burnbar_remote_security::{
        AuthorizedDeviceRecord, DeviceTrustState, Ed25519SessionGrantSigner,
        InMemorySessionAuthorizer, InMemoryTrustedSignerStore, TrustedSignerRecord,
    };

    fn security(
        authorizer: Arc<InMemorySessionAuthorizer>,
        signer: Arc<Ed25519SessionGrantSigner>,
        verifier: Arc<InMemoryTrustedSignerStore>,
    ) -> IrohTransportSecurity {
        IrohTransportSecurity {
            authorizer,
            grant_signer: signer,
            grant_verifier: verifier,
        }
    }

    fn config() -> IrohTransportConfig {
        IrohTransportConfig {
            relay: RelayConfig::Disabled,
            keep_alive_interval: Duration::from_millis(250),
            max_idle_timeout: Duration::from_secs(10),
            ..IrohTransportConfig::default()
        }
    }

    fn remote_address(identity: &LocalEndpointIdentity) -> RemoteEndpointAddress {
        let direct_addresses = identity
            .direct_addresses
            .iter()
            .filter_map(|addr| addr.parse().ok())
            .collect::<Vec<SocketAddr>>();
        assert!(
            !direct_addresses.is_empty(),
            "loopback endpoint must advertise at least one direct address"
        );
        RemoteEndpointAddress {
            endpoint_id: identity.endpoint_id.clone(),
            relay_url: None,
            direct_addresses,
        }
    }

    async fn loopback_managers() -> (
        Arc<IrohTransportManager>,
        Arc<IrohTransportManager>,
        Arc<InMemorySessionAuthorizer>,
    ) {
        let signer = Arc::new(Ed25519SessionGrantSigner::new("host-signer", [7u8; 32]));
        let verifier = Arc::new(InMemoryTrustedSignerStore::default());
        verifier
            .upsert_signer(TrustedSignerRecord {
                signer_key_id: signer.signer_key_id().to_string(),
                public_key: signer.public_key(),
                account_id: AccountId::new("account"),
                workspace_id: WorkspaceId::new("workspace"),
                revoked: false,
            })
            .unwrap();
        let server_auth = Arc::new(InMemorySessionAuthorizer::default());
        let client_auth = Arc::new(InMemorySessionAuthorizer::default());
        let server = Arc::new(
            IrohTransportManager::bind(
                config(),
                security(server_auth.clone(), signer.clone(), verifier.clone()),
            )
            .await
            .unwrap(),
        );
        let client = Arc::new(
            IrohTransportManager::bind(config(), security(client_auth, signer, verifier))
                .await
                .unwrap(),
        );
        server_auth
            .upsert_device(AuthorizedDeviceRecord {
                device_id: DeviceId::new("client-device"),
                endpoint_id: client.identity().endpoint_id,
                account_id: AccountId::new("account"),
                workspace_id: WorkspaceId::new("workspace"),
                trust_state: DeviceTrustState::Trusted,
                allowed_modes: vec![SessionMode::ViewOnly, SessionMode::Control],
                permissions: PermissionSet::from_iter([
                    Permission::ViewScreen,
                    Permission::InjectInput,
                ]),
                local_consent_required: true,
                max_session_ttl_micros: 5_000_000,
            })
            .unwrap();
        (server, client, server_auth)
    }

    #[tokio::test]
    async fn iroh_loopback_authorizes_streams_datagrams_and_paths() {
        let (server, client, _server_auth) = loopback_managers().await;
        let remote = remote_address(&server.identity());
        let accept = server.accept_next(HostSessionAuthorizationContext {
            host_device_id: DeviceId::new("host-device"),
            local_consent_granted: true,
            now: TimestampMicros(1),
        });
        let connect = client.connect(
            remote,
            ClientSessionRequestContext {
                account_id: AccountId::new("account"),
                workspace_id: WorkspaceId::new("workspace"),
                client_device_id: DeviceId::new("client-device"),
                requested_mode: SessionMode::Control,
                now: TimestampMicros(1),
            },
        );
        let (server_conn, client_conn) = tokio::join!(accept, connect);
        let server_conn = server_conn.unwrap();
        let client_conn = client_conn.unwrap();
        assert_eq!(
            client_conn.grant().descriptor.client_device_id,
            DeviceId::new("client-device")
        );

        let (server_channel, client_channel) = tokio::join!(
            server_conn.accept_stream(),
            client_conn.open_stream(StreamClass::Telemetry)
        );
        let mut server_channel = server_channel.unwrap();
        let mut client_channel = client_channel.unwrap();
        HeartbeatDriver::new()
            .send_now(&mut client_channel, TimestampMicros(2))
            .await
            .unwrap();
        let (prefix, payload) = server_channel.recv_frame().await.unwrap().unwrap();
        assert_eq!(prefix.kind, MessageKind::Heartbeat);
        let heartbeat: HeartbeatMessage = decode_control(&payload).unwrap();
        assert_eq!(heartbeat.sequence, SequenceNumber(1));

        client_conn
            .try_send_media_datagram(Bytes::from_static(b"video"))
            .unwrap();
        assert_eq!(
            server_conn.recv_datagram().await.unwrap().as_ref(),
            b"video"
        );
        assert!(!client_conn.path_snapshot().is_empty());
        assert!(client_conn.network_telemetry(0).datagram_send_buffer_space > 0);
    }

    #[tokio::test]
    async fn iroh_loopback_denies_unknown_peer_before_authorized_connection() {
        let signer = Arc::new(Ed25519SessionGrantSigner::new("host-signer", [7u8; 32]));
        let verifier = Arc::new(InMemoryTrustedSignerStore::default());
        verifier
            .upsert_signer(TrustedSignerRecord {
                signer_key_id: signer.signer_key_id().to_string(),
                public_key: signer.public_key(),
                account_id: AccountId::new("account"),
                workspace_id: WorkspaceId::new("workspace"),
                revoked: false,
            })
            .unwrap();
        let server_auth = Arc::new(InMemorySessionAuthorizer::default());
        let client_auth = Arc::new(InMemorySessionAuthorizer::default());
        let server = IrohTransportManager::bind(
            config(),
            security(server_auth, signer.clone(), verifier.clone()),
        )
        .await
        .unwrap();
        let client = IrohTransportManager::bind(config(), security(client_auth, signer, verifier))
            .await
            .unwrap();
        let remote = remote_address(&server.identity());
        let accept = server.accept_next(HostSessionAuthorizationContext {
            host_device_id: DeviceId::new("host-device"),
            local_consent_granted: true,
            now: TimestampMicros(1),
        });
        let connect = client.connect(
            remote,
            ClientSessionRequestContext {
                account_id: AccountId::new("account"),
                workspace_id: WorkspaceId::new("workspace"),
                client_device_id: DeviceId::new("client-device"),
                requested_mode: SessionMode::Control,
                now: TimestampMicros(1),
            },
        );
        let (server_result, client_result) = tokio::join!(accept, connect);
        match server_result {
            Err(TransportError::Authorization(
                burnbar_remote_security::AuthorizationError::UnknownPeer,
            )) => {}
            Err(err) => panic!("unexpected server error: {err}"),
            Ok(_) => panic!("server unexpectedly authorized unknown peer"),
        }
        match client_result {
            Err(TransportError::SessionDenied { .. }) => {}
            Err(err) => panic!("unexpected client error: {err}"),
            Ok(_) => panic!("client unexpectedly received a grant"),
        }
    }
}
