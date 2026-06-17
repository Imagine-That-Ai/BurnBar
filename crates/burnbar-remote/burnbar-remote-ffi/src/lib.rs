use std::sync::{Arc, Mutex};
use std::time::Duration;

use burnbar_remote_core::{Dimensions, Permission, SessionMode};
use burnbar_remote_media::{AdaptiveQualityController, ControllerInput, ControllerOutput};
use burnbar_remote_observability::{NetworkTelemetry, PathKind};
use thiserror::Error;

uniffi::setup_scaffolding!();

const REMOTE_PROTOCOL_VERSION: &str = "burnbar-remote/v1";

#[derive(Debug, Error, uniffi::Error)]
pub enum BurnBarRemoteFfiError {
    #[error("invalid dimensions {width}x{height}")]
    InvalidDimensions { width: u32, height: u32 },
    #[error("quality controller lock poisoned")]
    ControllerLockPoisoned,
}

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
}
