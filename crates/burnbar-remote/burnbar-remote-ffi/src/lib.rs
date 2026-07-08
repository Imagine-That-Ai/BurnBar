use std::sync::{Arc, Mutex};
use std::time::Duration;

use burnbar_remote_core::{Dimensions, Permission, SessionMode};
use burnbar_remote_media::{AdaptiveQualityController, ControllerInput, ControllerOutput};
use burnbar_remote_observability::{NetworkTelemetry, PathKind};
use thiserror::Error;

uniffi::setup_scaffolding!();

const REMOTE_PROTOCOL_VERSION: &str = "burnbar-remote/v1";

/// Installs the process-wide `tracing` subscriber that gives the remote stack's
/// `tracing::info!/warn!/debug!` a destination.
///
/// Before this existed, no crate, Tauri shell, or FFI host installed a
/// subscriber, so every `tracing` event in `burnbar-remote-*` (e.g. the iroh
/// endpoint-online / unknown-path-kind logs in `burnbar-remote-network`) was
/// silently dropped. A UniFFI host (Swift / Kotlin / **C#**) should call this
/// exactly once at startup; the Tauri Linux shell installs its own equivalent.
///
/// Idempotent and safe to call multiple times or concurrently: it uses
/// `try_init`, so a second call (or a host that already set a global default)
/// is a no-op rather than a panic. Verbosity is controlled by the standard
/// `RUST_LOG` env var (e.g. `RUST_LOG=burnbar_remote=debug`); when unset it
/// defaults to `info`.
///
/// Returns `true` if this call installed the subscriber, `false` if one was
/// already present (so the host can log the outcome without treating it as an
/// error).
#[uniffi::export]
pub fn init_tracing() -> bool {
    use tracing_subscriber::{fmt, EnvFilter};

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).with_target(true).try_init().is_ok()
}

#[derive(Debug, Error, uniffi::Error)]
pub enum BurnBarRemoteFfiError {
    #[error("invalid dimensions {width}x{height}")]
    InvalidDimensions { width: u32, height: u32 },
    #[error("quality controller lock poisoned")]
    ControllerLockPoisoned,
    #[error("wire vector truncated: expected {expected} bytes, found {found}")]
    WireTruncated { expected: u32, found: u32 },
    #[error("unsupported wire version {found} (this build speaks version {expected})")]
    WireVersionMismatch { expected: u8, found: u8 },
}

/// Version byte prefixed to every `RemoteQualityDecision` wire vector. Bumping
/// it is a deliberate, breaking wire change; both the Rust encoder and every
/// foreign decoder (Swift/Kotlin/**C#**) must agree on it byte-for-byte. This is
/// the smallest representative "wire vector" that the Windows C# binding
/// round-trips against the committed golden (FFI-007 / VAL-P0-FFI-007).
pub const REMOTE_WIRE_VERSION: u8 = 1;

/// Fixed on-wire size of an encoded `RemoteQualityDecision` (see
/// `encode_decision_wire` for the exact big-endian field layout).
pub const REMOTE_WIRE_DECISION_LEN: usize = 22;

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RemoteReadiness {
    pub protocol_version: String,
    pub supports_iroh_transport: bool,
    pub supports_adaptive_quality: bool,
    pub supports_permission_gate: bool,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct RemoteDimensions {
    pub width: u32,
    pub height: u32,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteSessionMode {
    ViewOnly,
    Control,
    AgentObserve,
    AgentAssist,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemotePermission {
    ViewScreen,
    HearAudio,
    InjectInput,
    ClipboardRead,
    ClipboardWrite,
    TransferFiles,
    SystemControl,
    ElevateControl,
    AuditExport,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteQualityPreference {
    Quality,
    Balanced,
    Responsiveness,
    BandwidthSaver,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemotePathKind {
    Direct,
    Relay,
    Mixed,
    Unknown,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RemoteNetworkTelemetry {
    pub path_kind: RemotePathKind,
    pub rtt_micros: Option<u64>,
    pub jitter_micros: Option<u64>,
    pub packet_loss_ppm: Option<u32>,
    pub send_queue_bytes: u32,
    pub datagram_send_buffer_space: u32,
    pub dropped_media_datagrams: u64,
    pub relay: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RemoteControllerInput {
    pub network: RemoteNetworkTelemetry,
    pub decode_time_micros: u64,
    pub render_time_micros: u64,
    pub received_frame_age_micros: u64,
    pub active_control: bool,
    pub preference: RemoteQualityPreference,
    pub current_dimensions: RemoteDimensions,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RemoteQualityDecision {
    pub target_bitrate_bps: u32,
    pub target_dimensions: RemoteDimensions,
    pub target_fps: u16,
    pub qp_min: u8,
    pub qp_max: u8,
    pub fec_overhead_ppm: u32,
    pub request_keyframe: bool,
    pub allow_frame_drop: bool,
    pub cursor_only_until_next_damage: bool,
}

#[uniffi::export]
pub fn burnbar_remote_readiness() -> RemoteReadiness {
    RemoteReadiness {
        protocol_version: REMOTE_PROTOCOL_VERSION.to_string(),
        supports_iroh_transport: true,
        supports_adaptive_quality: true,
        supports_permission_gate: true,
    }
}

#[uniffi::export]
pub fn remote_scaled_dimensions(
    dimensions: RemoteDimensions,
    numerator: u32,
    denominator: u32,
) -> Result<RemoteDimensions, BurnBarRemoteFfiError> {
    let dims = dimensions_to_core(dimensions)?;
    Ok(dimensions_from_core(dims.scaled_by(numerator, denominator)))
}

#[uniffi::export]
pub fn remote_mode_requires_permission(
    mode: RemoteSessionMode,
    permission: RemotePermission,
) -> bool {
    mode_to_core(mode)
        .required_permissions()
        .contains(permission_to_core(permission))
}

#[derive(uniffi::Object)]
pub struct BurnBarRemoteQualityController {
    inner: Mutex<AdaptiveQualityController>,
}

#[uniffi::export]
impl BurnBarRemoteQualityController {
    #[uniffi::constructor]
    pub fn new(
        initial_dimensions: RemoteDimensions,
        preference: RemoteQualityPreference,
    ) -> Result<Arc<Self>, BurnBarRemoteFfiError> {
        Ok(Arc::new(Self {
            inner: Mutex::new(AdaptiveQualityController::new(
                dimensions_to_core(initial_dimensions)?,
                preference_to_core(preference),
            )),
        }))
    }

    pub fn update(
        self: Arc<Self>,
        input: RemoteControllerInput,
    ) -> Result<RemoteQualityDecision, BurnBarRemoteFfiError> {
        let mut controller = self
            .inner
            .lock()
            .map_err(|_| BurnBarRemoteFfiError::ControllerLockPoisoned)?;
        Ok(decision_from_core(
            controller.update(controller_input_to_core(input)?),
        ))
    }
}

fn dimensions_to_core(dimensions: RemoteDimensions) -> Result<Dimensions, BurnBarRemoteFfiError> {
    Dimensions::new(dimensions.width, dimensions.height).map_err(|_| {
        BurnBarRemoteFfiError::InvalidDimensions {
            width: dimensions.width,
            height: dimensions.height,
        }
    })
}

fn dimensions_from_core(dimensions: Dimensions) -> RemoteDimensions {
    RemoteDimensions {
        width: dimensions.width,
        height: dimensions.height,
    }
}

fn mode_to_core(mode: RemoteSessionMode) -> SessionMode {
    match mode {
        RemoteSessionMode::ViewOnly => SessionMode::ViewOnly,
        RemoteSessionMode::Control => SessionMode::Control,
        RemoteSessionMode::AgentObserve => SessionMode::AgentObserve,
        RemoteSessionMode::AgentAssist => SessionMode::AgentAssist,
    }
}

fn permission_to_core(permission: RemotePermission) -> Permission {
    match permission {
        RemotePermission::ViewScreen => Permission::ViewScreen,
        RemotePermission::HearAudio => Permission::HearAudio,
        RemotePermission::InjectInput => Permission::InjectInput,
        RemotePermission::ClipboardRead => Permission::ClipboardRead,
        RemotePermission::ClipboardWrite => Permission::ClipboardWrite,
        RemotePermission::TransferFiles => Permission::TransferFiles,
        RemotePermission::SystemControl => Permission::SystemControl,
        RemotePermission::ElevateControl => Permission::ElevateControl,
        RemotePermission::AuditExport => Permission::AuditExport,
    }
}

fn preference_to_core(
    preference: RemoteQualityPreference,
) -> burnbar_remote_media::QualityPreference {
    match preference {
        RemoteQualityPreference::Quality => burnbar_remote_media::QualityPreference::Quality,
        RemoteQualityPreference::Balanced => burnbar_remote_media::QualityPreference::Balanced,
        RemoteQualityPreference::Responsiveness => {
            burnbar_remote_media::QualityPreference::Responsiveness
        }
        RemoteQualityPreference::BandwidthSaver => {
            burnbar_remote_media::QualityPreference::BandwidthSaver
        }
    }
}

fn path_kind_to_core(path_kind: RemotePathKind) -> PathKind {
    match path_kind {
        RemotePathKind::Direct => PathKind::Direct,
        RemotePathKind::Relay => PathKind::Relay,
        RemotePathKind::Mixed => PathKind::Mixed,
        RemotePathKind::Unknown => PathKind::Unknown,
    }
}

fn network_to_core(network: RemoteNetworkTelemetry) -> NetworkTelemetry {
    NetworkTelemetry {
        path_kind: path_kind_to_core(network.path_kind),
        rtt_micros: network.rtt_micros,
        jitter_micros: network.jitter_micros,
        packet_loss_ppm: network.packet_loss_ppm,
        send_queue_bytes: network.send_queue_bytes,
        datagram_send_buffer_space: network.datagram_send_buffer_space,
        dropped_media_datagrams: network.dropped_media_datagrams,
        relay: network.relay,
    }
}

fn controller_input_to_core(
    input: RemoteControllerInput,
) -> Result<ControllerInput, BurnBarRemoteFfiError> {
    Ok(ControllerInput {
        network: network_to_core(input.network),
        receiver_report: None,
        decode_time: Duration::from_micros(input.decode_time_micros),
        render_time: Duration::from_micros(input.render_time_micros),
        received_frame_age: Duration::from_micros(input.received_frame_age_micros),
        active_control: input.active_control,
        preference: preference_to_core(input.preference),
        current_dimensions: dimensions_to_core(input.current_dimensions)?,
    })
}

fn decision_from_core(output: ControllerOutput) -> RemoteQualityDecision {
    RemoteQualityDecision {
        target_bitrate_bps: output.target_bitrate_bps,
        target_dimensions: dimensions_from_core(output.target_dimensions),
        target_fps: output.target_fps,
        qp_min: output.qp_min,
        qp_max: output.qp_max,
        fec_overhead_ppm: output.fec_overhead_ppm,
        request_keyframe: output.request_keyframe,
        allow_frame_drop: output.allow_frame_drop,
        cursor_only_until_next_damage: output.cursor_only_until_next_damage,
    }
}

// ============================================================================
// Representative async + callback + error surface (FFI-007 / VAL-P0-FFI-007)
// ============================================================================
//
// The bridge above is entirely synchronous, infallible-or-`Result` free
// functions plus one `Object`. To prove that the *Windows C# binding path*
// (uniffi-bindgen-cs, decided in
// docs/windows-port/decisions/0001-csharp-binding-path.md) can carry the three
// FFI features that actually matter for the Windows port — asynchronous calls,
// foreign callbacks, and typed errors — we add ONE small interface that
// exercises all three at once and round-trips a byte-identical wire vector.
//
// `encode_quality_decision` is `async` (foreign-future ABI), takes a foreign
// `WireProgressListener` (callback vtable ABI), and returns
// `Result<Vec<u8>, BurnBarRemoteFfiError>` (error ABI). `decode_quality_decision`
// is the inverse and drives the error path. The macOS `dotnet test`
// (crates/burnbar-remote/bindings/csharp) calls both against the natively-built
// `libburnbar_remote.dylib` and asserts the encoded bytes equal the committed
// golden and that decode∘encode is the identity. FFI-008 repeats the identical
// assertions on the `*-pc-windows-msvc` runtime.

/// Foreign-implemented progress sink invoked during `encode_quality_decision`.
///
/// This is a UniFFI *foreign trait* (`with_foreign`): Swift/Kotlin/C# each
/// implement it and hand an instance across the FFI boundary. It exists to
/// exercise the callback ABI end-to-end from the round-trip test — the encoder
/// reports each stage it passes through so the foreign side can assert the
/// callback fired in order.
#[uniffi::export(with_foreign)]
pub trait WireProgressListener: Send + Sync {
    /// Called once per encode stage, in order: `"validate"`, `"encode"`,
    /// `"done"`.
    fn on_stage(&self, stage: String);
}

/// Encode a `RemoteQualityDecision` to its canonical wire vector, reporting
/// progress through `listener`.
///
/// `async` purely to exercise the foreign-future ABI; the body performs no
/// I/O and is fully deterministic, so it needs no async runtime. Returns
/// `WireTruncated`/`WireVersionMismatch` only via the decode inverse; encoding
/// a well-formed record is infallible but is typed `Result` so the C# binding
/// generates the fallible async signature that FFI-008 also needs.
#[uniffi::export]
pub async fn encode_quality_decision(
    decision: RemoteQualityDecision,
    listener: Arc<dyn WireProgressListener>,
) -> Result<Vec<u8>, BurnBarRemoteFfiError> {
    listener.on_stage("validate".to_string());
    listener.on_stage("encode".to_string());
    let bytes = encode_decision_wire(&decision);
    listener.on_stage("done".to_string());
    Ok(bytes)
}

/// Decode a `RemoteQualityDecision` from its canonical wire vector.
///
/// Fails closed with a typed error on a truncated buffer or an unknown version
/// byte — this is the error path the C# round-trip test asserts against.
#[uniffi::export]
pub fn decode_quality_decision(
    bytes: Vec<u8>,
) -> Result<RemoteQualityDecision, BurnBarRemoteFfiError> {
    decode_decision_wire(&bytes)
}

/// Canonical, versioned, fixed-width big-endian encoding of a
/// `RemoteQualityDecision` (`REMOTE_WIRE_DECISION_LEN` = 22 bytes):
///
/// | offset | width | field                                   |
/// |--------|-------|-----------------------------------------|
/// | 0      | 1     | `REMOTE_WIRE_VERSION`                    |
/// | 1      | 4     | `target_bitrate_bps` (u32 BE)           |
/// | 5      | 4     | `target_dimensions.width` (u32 BE)      |
/// | 9      | 4     | `target_dimensions.height` (u32 BE)     |
/// | 13     | 2     | `target_fps` (u16 BE)                   |
/// | 15     | 1     | `qp_min`                                |
/// | 16     | 1     | `qp_max`                                |
/// | 17     | 4     | `fec_overhead_ppm` (u32 BE)             |
/// | 21     | 1     | flags: bit0 keyframe, bit1 frame_drop, bit2 cursor_only |
///
/// Deterministic and endian-explicit so the bytes are identical on every host
/// and every binding — the property the golden vector locks.
fn encode_decision_wire(decision: &RemoteQualityDecision) -> Vec<u8> {
    let mut out = Vec::with_capacity(REMOTE_WIRE_DECISION_LEN);
    out.push(REMOTE_WIRE_VERSION);
    out.extend_from_slice(&decision.target_bitrate_bps.to_be_bytes());
    out.extend_from_slice(&decision.target_dimensions.width.to_be_bytes());
    out.extend_from_slice(&decision.target_dimensions.height.to_be_bytes());
    out.extend_from_slice(&decision.target_fps.to_be_bytes());
    out.push(decision.qp_min);
    out.push(decision.qp_max);
    out.extend_from_slice(&decision.fec_overhead_ppm.to_be_bytes());
    let flags = (decision.request_keyframe as u8)
        | ((decision.allow_frame_drop as u8) << 1)
        | ((decision.cursor_only_until_next_damage as u8) << 2);
    out.push(flags);
    debug_assert_eq!(out.len(), REMOTE_WIRE_DECISION_LEN);
    out
}

fn decode_decision_wire(bytes: &[u8]) -> Result<RemoteQualityDecision, BurnBarRemoteFfiError> {
    if bytes.len() != REMOTE_WIRE_DECISION_LEN {
        return Err(BurnBarRemoteFfiError::WireTruncated {
            expected: u32::try_from(REMOTE_WIRE_DECISION_LEN).unwrap_or(u32::MAX),
            found: u32::try_from(bytes.len()).unwrap_or(u32::MAX),
        });
    }
    if bytes[0] != REMOTE_WIRE_VERSION {
        return Err(BurnBarRemoteFfiError::WireVersionMismatch {
            expected: REMOTE_WIRE_VERSION,
            found: bytes[0],
        });
    }
    // Widths are validated by the length check above; these slices are exact.
    let u32_at =
        |i: usize| u32::from_be_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]);
    let flags = bytes[21];
    Ok(RemoteQualityDecision {
        target_bitrate_bps: u32_at(1),
        target_dimensions: RemoteDimensions {
            width: u32_at(5),
            height: u32_at(9),
        },
        target_fps: u16::from_be_bytes([bytes[13], bytes[14]]),
        qp_min: bytes[15],
        qp_max: bytes[16],
        fec_overhead_ppm: u32_at(17),
        request_keyframe: flags & 0b001 != 0,
        allow_frame_drop: flags & 0b010 != 0,
        cursor_only_until_next_damage: flags & 0b100 != 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dimensions(width: u32, height: u32) -> RemoteDimensions {
        RemoteDimensions { width, height }
    }

    #[test]
    fn readiness_advertises_remote_engine_capabilities() {
        let readiness = burnbar_remote_readiness();
        assert_eq!(readiness.protocol_version, REMOTE_PROTOCOL_VERSION);
        assert!(readiness.supports_iroh_transport);
        assert!(readiness.supports_adaptive_quality);
        assert!(readiness.supports_permission_gate);
    }

    #[test]
    fn control_mode_requires_input_permission() {
        assert!(remote_mode_requires_permission(
            RemoteSessionMode::Control,
            RemotePermission::InjectInput
        ));
        assert!(!remote_mode_requires_permission(
            RemoteSessionMode::ViewOnly,
            RemotePermission::InjectInput
        ));
    }

    #[test]
    fn quality_controller_applies_relay_cap() -> Result<(), BurnBarRemoteFfiError> {
        let controller = BurnBarRemoteQualityController::new(
            dimensions(3840, 2160),
            RemoteQualityPreference::Balanced,
        )?;
        let decision = controller.update(RemoteControllerInput {
            network: RemoteNetworkTelemetry {
                path_kind: RemotePathKind::Relay,
                rtt_micros: Some(12_000),
                jitter_micros: Some(1_000),
                packet_loss_ppm: Some(0),
                send_queue_bytes: 0,
                datagram_send_buffer_space: 64 * 1024,
                dropped_media_datagrams: 0,
                relay: true,
            },
            decode_time_micros: 4_000,
            render_time_micros: 4_000,
            received_frame_age_micros: 10_000,
            active_control: false,
            preference: RemoteQualityPreference::Balanced,
            current_dimensions: dimensions(3840, 2160),
        })?;
        assert!(decision.target_bitrate_bps <= 10_000_000);
        Ok(())
    }

    // ---- Wire-vector round-trip (FFI-007) -------------------------------

    /// The committed golden wire vector. The identical bytes are copied next to
    /// the C# test binary (crates/burnbar-remote/bindings/csharp) so the Rust
    /// encoder and the C# binding assert against one source of truth.
    const GOLDEN_WIRE_V1: &[u8] = include_bytes!("../tests/golden/quality_decision_v1.wire");

    /// The exact `RemoteQualityDecision` the golden vector encodes. Kept in
    /// lock-step with `bindings/csharp/BurnBarRemote.Ffi.Tests/WireRoundTripTests.cs`.
    fn golden_decision() -> RemoteQualityDecision {
        RemoteQualityDecision {
            target_bitrate_bps: 8_000_000,
            target_dimensions: dimensions(2560, 1440),
            target_fps: 60,
            qp_min: 24,
            qp_max: 40,
            fec_overhead_ppm: 50_000,
            request_keyframe: true,
            allow_frame_drop: true,
            cursor_only_until_next_damage: false,
        }
    }

    /// Minimal executor that drives a future to completion on the current
    /// thread with a no-op waker. `encode_quality_decision` never yields, so a
    /// single poll resolves it — this proves the *async* export works without
    /// pulling a runtime into the test.
    fn block_on<F: std::future::Future>(mut fut: F) -> F::Output {
        use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};
        const VTABLE: RawWakerVTable = RawWakerVTable::new(
            |_| RawWaker::new(std::ptr::null(), &VTABLE),
            |_| {},
            |_| {},
            |_| {},
        );
        // SAFETY: the no-op waker ignores its data pointer entirely.
        let waker = unsafe { Waker::from_raw(RawWaker::new(std::ptr::null(), &VTABLE)) };
        let mut cx = Context::from_waker(&waker);
        // SAFETY: `fut` is owned and never moved after being pinned here.
        let mut fut = unsafe { std::pin::Pin::new_unchecked(&mut fut) };
        loop {
            if let Poll::Ready(out) = fut.as_mut().poll(&mut cx) {
                return out;
            }
        }
    }

    fn must_err<T, E>(result: Result<T, E>, context: &str) -> E {
        match result {
            Ok(_) => panic!("{context}: expected an error"),
            Err(error) => error,
        }
    }

    #[derive(Default)]
    struct RecordingListener {
        stages: Mutex<Vec<String>>,
    }

    impl RecordingListener {
        fn recorded(&self) -> Vec<String> {
            self.stages
                .lock()
                .unwrap_or_else(|error| panic!("listener lock poisoned: {error}"))
                .clone()
        }
    }

    impl WireProgressListener for RecordingListener {
        fn on_stage(&self, stage: String) {
            self.stages
                .lock()
                .unwrap_or_else(|error| panic!("listener lock poisoned: {error}"))
                .push(stage);
        }
    }

    #[test]
    fn encode_matches_committed_golden_vector() {
        assert_eq!(encode_decision_wire(&golden_decision()), GOLDEN_WIRE_V1);
    }

    #[test]
    fn decode_of_golden_is_the_original_decision() -> Result<(), BurnBarRemoteFfiError> {
        assert_eq!(
            decode_quality_decision(GOLDEN_WIRE_V1.to_vec())?,
            golden_decision()
        );
        Ok(())
    }

    #[test]
    fn encode_then_decode_is_identity() -> Result<(), BurnBarRemoteFfiError> {
        let decision = golden_decision();
        let listener = Arc::new(RecordingListener::default());
        let encoded = block_on(encode_quality_decision(
            decision.clone(),
            listener.clone() as Arc<dyn WireProgressListener>,
        ))?;
        assert_eq!(
            encoded, GOLDEN_WIRE_V1,
            "async encoder must produce the golden bytes"
        );
        assert_eq!(
            listener.recorded(),
            vec![
                "validate".to_string(),
                "encode".to_string(),
                "done".to_string()
            ],
            "callback must fire once per stage, in order"
        );
        assert_eq!(decode_quality_decision(encoded)?, decision);
        Ok(())
    }

    #[test]
    fn decode_rejects_truncated_buffer() {
        let err = must_err(
            decode_quality_decision(vec![REMOTE_WIRE_VERSION; 4]),
            "short buffer",
        );
        assert!(matches!(
            err,
            BurnBarRemoteFfiError::WireTruncated {
                expected: 22,
                found: 4
            }
        ));
    }

    #[test]
    fn decode_rejects_unknown_version() {
        let mut bytes = GOLDEN_WIRE_V1.to_vec();
        bytes[0] = 99;
        let err = must_err(decode_quality_decision(bytes), "bad version");
        assert!(matches!(
            err,
            BurnBarRemoteFfiError::WireVersionMismatch {
                expected: 1,
                found: 99
            }
        ));
    }
}
