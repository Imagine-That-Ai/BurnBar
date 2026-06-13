use std::env;
use std::error::Error;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use burnbar_remote_core::{
    AccountId, DeviceId, Permission, PermissionSet, SequenceNumber, SessionMode, TimestampMicros,
    WorkspaceId,
};
use burnbar_remote_network::{
    ClientSessionRequestContext, HostSessionAuthorizationContext, IrohTransportConfig,
    IrohTransportManager, IrohTransportSecurity, RelayConfig, RemoteEndpointAddress,
};
use burnbar_remote_protocol::{HeartbeatMessage, MessageKind, ReliableFramePrefix, StreamClass};
use burnbar_remote_security::{
    AuthorizedDeviceRecord, DeviceTrustState, Ed25519SessionGrantSigner, InMemorySessionAuthorizer,
    InMemoryTrustedSignerStore, TrustedSignerRecord,
};
use bytes::Bytes;

fn control_payload_len(len: usize) -> Result<u32, Box<dyn Error + Send + Sync>> {
    u32::try_from(len)
        .map_err(|_| format!("control payload too large: {len} > {}", u32::MAX).into())
}

fn u64_saturating_from_u128(value: u128) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error + Send + Sync>> {
    if env::var("BURNBAR_REMOTE_LIVE_RELAY").ok().as_deref() != Some("1") {
        println!(
            "burnbar_remote_iroh_smoke status=skipped reason=BURNBAR_REMOTE_LIVE_RELAY_not_set"
        );
        return Ok(());
    }

    let relay = match env::var("BURNBAR_REMOTE_RELAY_URL") {
        Ok(url) if !url.is_empty() => RelayConfig::Custom(url),
        _ => RelayConfig::Default,
    };
    let mut config = IrohTransportConfig {
        relay,
        keep_alive_interval: Duration::from_millis(250),
        max_idle_timeout: Duration::from_secs(20),
        relay_only: env::var("BURNBAR_REMOTE_FORCE_RELAY").ok().as_deref() == Some("1"),
        ..IrohTransportConfig::default()
    };
    if env::var("BURNBAR_REMOTE_DIRECT_ONLY").ok().as_deref() == Some("1") {
        config.relay = RelayConfig::Disabled;
    }

    let signer = Arc::new(Ed25519SessionGrantSigner::new(
        "smoke-host-signer",
        [11u8; 32],
    ));
    let verifier = Arc::new(InMemoryTrustedSignerStore::default());
    verifier.upsert_signer(TrustedSignerRecord {
        signer_key_id: signer.signer_key_id().to_string(),
        public_key: signer.public_key(),
        account_id: AccountId::new("smoke-account"),
        workspace_id: WorkspaceId::new("smoke-workspace"),
        revoked: false,
    })?;
    let server_auth = Arc::new(InMemorySessionAuthorizer::default());
    let client_auth = Arc::new(InMemorySessionAuthorizer::default());
    let server = Arc::new(
        IrohTransportManager::bind(
            config.clone(),
            security(server_auth.clone(), signer.clone(), verifier.clone()),
        )
        .await?,
    );
    let client = Arc::new(
        IrohTransportManager::bind(config, security(client_auth, signer, verifier)).await?,
    );
    server_auth.upsert_device(AuthorizedDeviceRecord {
        device_id: DeviceId::new("smoke-client-device"),
        endpoint_id: client.identity().endpoint_id,
        account_id: AccountId::new("smoke-account"),
        workspace_id: WorkspaceId::new("smoke-workspace"),
        trust_state: DeviceTrustState::Trusted,
        allowed_modes: vec![SessionMode::ViewOnly, SessionMode::Control],
        permissions: PermissionSet::from_iter([Permission::ViewScreen, Permission::InjectInput]),
        local_consent_required: true,
        max_session_ttl_micros: 30_000_000,
    })?;

    let remote = remote_address(&server)?;
    let (server_conn, client_conn) = tokio::time::timeout(Duration::from_secs(20), async {
        tokio::join!(
            server.accept_next(HostSessionAuthorizationContext {
                host_device_id: DeviceId::new("smoke-host-device"),
                local_consent_granted: true,
                now: TimestampMicros(1),
            }),
            client.connect(
                remote,
                ClientSessionRequestContext {
                    account_id: AccountId::new("smoke-account"),
                    workspace_id: WorkspaceId::new("smoke-workspace"),
                    client_device_id: DeviceId::new("smoke-client-device"),
                    requested_mode: SessionMode::Control,
                    now: TimestampMicros(1),
                },
            )
        )
    })
    .await?;
    let server_conn = server_conn?;
    let client_conn = client_conn?;

    let (server_channel, client_channel) = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(
            server_conn.accept_stream(),
            client_conn.open_stream(StreamClass::Telemetry)
        )
    })
    .await?;
    let mut server_channel = server_channel?;
    let mut client_channel = client_channel?;

    let echo = tokio::spawn(async move {
        while let Some((prefix, payload)) = server_channel.recv_frame().await? {
            server_channel.send_frame(prefix, &payload).await?;
        }
        Ok::<(), burnbar_remote_network::TransportError>(())
    });

    let mut samples = Vec::with_capacity(20);
    let mut scratch = Vec::with_capacity(128);
    for sequence in 1..=20 {
        let heartbeat = HeartbeatMessage {
            sequence: SequenceNumber(sequence),
            sent_at: TimestampMicros(sequence),
        };
        burnbar_remote_protocol::encode_control(&heartbeat, &mut scratch)?;
        let prefix = ReliableFramePrefix {
            payload_len: control_payload_len(scratch.len())?,
            kind: MessageKind::Heartbeat,
            flags: 0,
        };
        let started = Instant::now();
        client_channel.send_frame(prefix, &scratch).await?;
        let (echo_prefix, _) = client_channel.recv_frame().await?.ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "heartbeat echo stream closed",
            )
        })?;
        if echo_prefix.kind != MessageKind::Heartbeat {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "heartbeat echo returned unexpected frame kind",
            )
            .into());
        }
        samples.push(u64_saturating_from_u128(started.elapsed().as_micros()));
    }
    client_channel.finish().await?;
    echo.await??;

    client_conn.try_send_media_datagram(Bytes::from_static(b"smoke-media"))?;
    let datagram =
        tokio::time::timeout(Duration::from_secs(5), server_conn.recv_datagram()).await??;
    if datagram.as_ref() != b"smoke-media" {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "media datagram echo proof received unexpected payload",
        )
        .into());
    }

    samples.sort_unstable();
    let paths = client_conn.path_snapshot();
    let selected_path = paths
        .iter()
        .find(|path| path.selected)
        .or_else(|| paths.first());
    println!(
        "burnbar_remote_iroh_smoke status=passed samples={} p50_us={} p95_us={} p99_us={} selected_path={:?}",
        samples.len(),
        percentile(&samples, 50),
        percentile(&samples, 95),
        percentile(&samples, 99),
        selected_path.map(|path| path.kind)
    );
    Ok(())
}

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

fn remote_address(
    manager: &IrohTransportManager,
) -> Result<RemoteEndpointAddress, Box<dyn Error + Send + Sync>> {
    let identity = manager.identity();
    let force_relay = env::var("BURNBAR_REMOTE_FORCE_RELAY").ok().as_deref() == Some("1");
    let direct_addresses = if force_relay {
        Vec::new()
    } else {
        identity
            .direct_addresses
            .iter()
            .filter_map(|addr| addr.parse().ok())
            .collect::<Vec<SocketAddr>>()
    };
    let relay_url = identity.relay_urls.first().cloned();
    if direct_addresses.is_empty() && relay_url.is_none() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AddrNotAvailable,
            "endpoint advertised neither direct addresses nor relay urls",
        )
        .into());
    }
    Ok(RemoteEndpointAddress {
        endpoint_id: identity.endpoint_id,
        relay_url,
        direct_addresses,
    })
}

fn percentile(samples: &[u64], percentile: usize) -> u64 {
    if samples.is_empty() {
        return 0;
    }
    let index = ((samples.len() - 1) * percentile) / 100;
    samples[index]
}
