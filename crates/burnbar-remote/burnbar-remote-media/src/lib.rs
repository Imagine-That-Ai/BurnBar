use std::collections::HashMap;
use std::ffi::c_void;
use std::time::Duration;

use async_trait::async_trait;
use burnbar_remote_core::{
    Codec, Dimensions, DisplayId, FrameDependency, FrameId, FrameMetadata, Rect, TimestampMicros,
};
use burnbar_remote_observability::{NetworkTelemetry, PathKind, ReceiverReport};
use burnbar_remote_protocol::{
    decode_media_datagram, encode_media_datagram, DatagramClass, MediaDatagramHeader,
    MEDIA_DATAGRAM_HEADER_LEN,
};
use bytes::{Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum MediaError {
    #[error("capture failed: {0}")]
    Capture(String),
    #[error("encode failed: {0}")]
    Encode(String),
    #[error("decode failed: {0}")]
    Decode(String),
    #[error("render failed: {0}")]
    Render(String),
    #[error("input injection failed: {0}")]
    Input(String),
    #[error("packetization failed: {0}")]
    Packetize(String),
    #[error("depacketization failed: {0}")]
    Depacketize(String),
    #[error("unsupported platform path: {0}")]
    Unsupported(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CopyClass {
    TrueZeroCopy,
    GpuToGpuZeroCopy,
    SingleCopyFallback,
    CpuFallback,
    Unsupported,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct GpuFrameDescriptor {
    pub display_id: DisplayId,
    pub dimensions: Dimensions,
    pub pixel_format: String,
    pub color_space: String,
    pub copy_class: CopyClass,
    pub captured_at: TimestampMicros,
    pub dirty_regions: Vec<Rect>,
}

#[derive(Clone, Copy, Debug)]
pub struct CpuPlane<'a> {
    pub bytes: &'a [u8],
    pub stride: usize,
}

#[derive(Clone, Copy, Debug)]
#[non_exhaustive]
pub enum PlatformFrameHandle<'a> {
    MacOs {
        io_surface_id: Option<u32>,
        cv_pixel_buffer: Option<*mut c_void>,
    },
    WindowsD3D {
        texture: *mut c_void,
        adapter_luid: u64,
    },
    LinuxDmaBuf {
        fds: &'a [i32],
        modifiers: &'a [u64],
    },
    Cpu {
        planes: &'a [CpuPlane<'a>],
    },
    Unsupported,
}

/// Borrowed view over a captured or decoded frame.
///
/// Ownership stays with the platform implementation; callers may inspect the
/// descriptor and borrow a platform handle for the duration of the call only.
/// Implementations must be `Send + Sync` because capture, encode, decode, and
/// render stages can run on separate runtime workers. Hot-path callers should
/// not allocate when retrieving the descriptor or handle.
pub trait GpuFrame: Send + Sync {
    fn descriptor(&self) -> &GpuFrameDescriptor;
    fn platform_handle(&self) -> PlatformFrameHandle<'_>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CaptureDeadline {
    pub latest_presentable_at: TimestampMicros,
}

#[async_trait]
/// Platform capture boundary.
///
/// `next_frame` transfers one owned frame wrapper to the caller while keeping
/// GPU resource lifetime hidden inside `Self::Frame`. Implementations should
/// block only until the next capture deadline and should drop stale frames
/// rather than queueing unbounded history.
pub trait ZeroCopyCapture: Send {
    type Frame: GpuFrame + 'static;

    async fn next_frame(
        &mut self,
        deadline: CaptureDeadline,
    ) -> Result<CapturedFrame<Self::Frame>, MediaError>;
}

#[derive(Clone, Debug)]
pub struct CapturedFrame<F: GpuFrame> {
    pub metadata: FrameMetadata,
    pub frame: F,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateControlMode {
    Cbr,
    CappedVbr,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncoderSettings {
    pub codec: Codec,
    pub dimensions: Dimensions,
    pub target_bitrate_bps: u32,
    pub target_fps: u16,
    pub qp_min: u8,
    pub qp_max: u8,
    pub rate_control: RateControlMode,
    pub low_latency: bool,
    pub allow_b_frames: bool,
    pub gop_frames: u16,
    pub intra_refresh: bool,
    pub dirty_regions: Vec<Rect>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncodedFrame {
    pub metadata: FrameMetadata,
    pub codec: Codec,
    pub dependency: FrameDependency,
    pub bytes: Bytes,
}

#[async_trait]
/// Hardware encoder boundary.
///
/// Encoders own their codec session and accept borrowed GPU frames. `encode`
/// may allocate the encoded byte buffer, but steady-state implementations must
/// keep driver queues bounded and drop before encode when the deadline is gone.
pub trait HardwareEncoder: Send {
    async fn reconfigure(&mut self, settings: EncoderSettings) -> Result<(), MediaError>;
    async fn encode<F: GpuFrame + Sync>(
        &mut self,
        frame: &CapturedFrame<F>,
    ) -> Result<EncodedFrame, MediaError>;
    async fn request_keyframe(&mut self) -> Result<(), MediaError>;
}

/// Media packetizer boundary.
///
/// The packetizer consumes an `EncodedFrame`, writes datagrams into caller-owned
/// scratch storage, and must not retain frame payloads after returning. The
/// caller controls the output vector to avoid hidden hot-path allocations.
pub trait Packetizer: Send {
    fn packetize(
        &mut self,
        frame: EncodedFrame,
        max_datagram_payload: usize,
        output: &mut Vec<Bytes>,
    ) -> Result<(), MediaError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DatagramPacketizer {
    stream_id: u16,
}

impl DatagramPacketizer {
    pub fn new(stream_id: u16) -> Self {
        Self { stream_id }
    }
}

impl Packetizer for DatagramPacketizer {
    fn packetize(
        &mut self,
        frame: EncodedFrame,
        max_datagram_payload: usize,
        output: &mut Vec<Bytes>,
    ) -> Result<(), MediaError> {
        if max_datagram_payload <= MEDIA_DATAGRAM_HEADER_LEN {
            return Err(MediaError::Packetize(format!(
                "datagram payload {max_datagram_payload} cannot fit {MEDIA_DATAGRAM_HEADER_LEN}-byte header"
            )));
        }

        let chunk_len = max_datagram_payload - MEDIA_DATAGRAM_HEADER_LEN;
        let packet_count_usize = frame.bytes.len().div_ceil(chunk_len);
        if packet_count_usize > u16::MAX as usize {
            return Err(MediaError::Packetize(format!(
                "frame requires {packet_count_usize} packets, exceeds u16 packet_count"
            )));
        }
        let packet_count = u16::try_from(packet_count_usize).map_err(|_| {
            MediaError::Packetize("packet count exceeds u16 packet_count".to_string())
        })?;

        output.clear();
        output.reserve(packet_count_usize);
        let flags = match frame.dependency {
            FrameDependency::Key => 0b0000_0001,
            FrameDependency::IntraRefresh => 0b0000_0010,
            FrameDependency::CursorOnly => 0b0000_0100,
            FrameDependency::Delta => 0,
        };
        for (idx, chunk) in frame.bytes.chunks(chunk_len).enumerate() {
            let packet_index = u16::try_from(idx).map_err(|_| {
                MediaError::Packetize("packet index exceeds u16 packet_index".to_string())
            })?;
            let header = MediaDatagramHeader {
                class: DatagramClass::Video,
                flags,
                stream_id: self.stream_id,
                frame_id: frame.metadata.frame_id,
                packet_index,
                packet_count,
                capture_timestamp: frame.metadata.captured_at,
                payload_len: 0,
            };
            let encoded = encode_media_datagram(header, chunk)
                .map_err(|err| MediaError::Packetize(err.to_string()))?;
            output.push(encoded.bytes);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReassembledFrame {
    pub frame_id: FrameId,
    pub stream_id: u16,
    pub capture_timestamp: TimestampMicros,
    pub dependency: FrameDependency,
    pub bytes: Bytes,
}

#[derive(Clone, Debug)]
struct PartialFrame {
    stream_id: u16,
    capture_timestamp: TimestampMicros,
    dependency: FrameDependency,
    accepted_at: TimestampMicros,
    received_count: usize,
    packets: Vec<Option<Bytes>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct PartialFrameKey {
    stream_id: u16,
    frame_id: FrameId,
}

#[derive(Clone, Debug)]
pub struct DatagramDepacketizer {
    max_incomplete_frames: usize,
    max_frame_age: Duration,
    partials: HashMap<PartialFrameKey, PartialFrame>,
}

impl DatagramDepacketizer {
    pub fn new(max_incomplete_frames: usize, max_frame_age: Duration) -> Self {
        Self {
            max_incomplete_frames: max_incomplete_frames.max(1),
            max_frame_age,
            partials: HashMap::new(),
        }
    }

    pub fn push(
        &mut self,
        datagram: Bytes,
        received_at: TimestampMicros,
    ) -> Result<Option<ReassembledFrame>, MediaError> {
        self.discard_stale(received_at);
        let (header, payload) = decode_media_datagram(datagram)
            .map_err(|err| MediaError::Depacketize(err.to_string()))?;
        if header.class != DatagramClass::Video {
            return Ok(None);
        }
        if header.packet_count == 0 || header.packet_index >= header.packet_count {
            return Err(MediaError::Depacketize(format!(
                "invalid packet index {} of {}",
                header.packet_index, header.packet_count
            )));
        }

        let dependency = frame_dependency_from_flags(header.flags);
        let key = PartialFrameKey {
            stream_id: header.stream_id,
            frame_id: header.frame_id,
        };
        if self.partials.len() >= self.max_incomplete_frames && !self.partials.contains_key(&key) {
            self.drop_oldest_partial();
        }

        let partial = self.partials.entry(key).or_insert_with(|| PartialFrame {
            stream_id: header.stream_id,
            capture_timestamp: header.capture_timestamp,
            dependency,
            accepted_at: received_at,
            received_count: 0,
            packets: vec![None; header.packet_count as usize],
        });

        if partial.packets.len() != header.packet_count as usize
            || partial.capture_timestamp != header.capture_timestamp
            || partial.dependency != dependency
        {
            self.partials.remove(&key);
            return Err(MediaError::Depacketize(format!(
                "conflicting packet metadata for stream {} frame {}",
                header.stream_id, header.frame_id.0
            )));
        }

        let slot = &mut partial.packets[header.packet_index as usize];
        if slot.is_none() {
            *slot = Some(payload);
            partial.received_count += 1;
        }
        if partial.received_count != partial.packets.len() {
            return Ok(None);
        }

        let partial = self.partials.remove(&key).ok_or_else(|| {
            MediaError::Depacketize(format!(
                "missing partial for stream {} frame {}",
                header.stream_id, header.frame_id.0
            ))
        })?;
        let total_len: usize = partial
            .packets
            .iter()
            .map(|packet| packet.as_ref().map(Bytes::len).unwrap_or_default())
            .sum();
        let mut joined = BytesMut::with_capacity(total_len);
        for packet in partial.packets {
            joined.extend_from_slice(
                packet
                    .ok_or_else(|| MediaError::Depacketize("missing packet".into()))?
                    .as_ref(),
            );
        }
        Ok(Some(ReassembledFrame {
            frame_id: key.frame_id,
            stream_id: partial.stream_id,
            capture_timestamp: partial.capture_timestamp,
            dependency: partial.dependency,
            bytes: joined.freeze(),
        }))
    }

    pub fn incomplete_count(&self) -> usize {
        self.partials.len()
    }

    pub fn discard_stale(&mut self, now: TimestampMicros) -> usize {
        let before = self.partials.len();
        let max_age = self.max_frame_age;
        self.partials
            .retain(|_, partial| now.saturating_duration_since(partial.accepted_at) <= max_age);
        before - self.partials.len()
    }

    fn drop_oldest_partial(&mut self) {
        if let Some(oldest) = self
            .partials
            .iter()
            .min_by_key(|(_, partial)| partial.accepted_at)
            .map(|(key, _)| *key)
        {
            self.partials.remove(&oldest);
        }
    }
}

fn frame_dependency_from_flags(flags: u8) -> FrameDependency {
    if flags & 0b0000_0001 != 0 {
        FrameDependency::Key
    } else if flags & 0b0000_0010 != 0 {
        FrameDependency::IntraRefresh
    } else if flags & 0b0000_0100 != 0 {
        FrameDependency::CursorOnly
    } else {
        FrameDependency::Delta
    }
}

#[async_trait]
/// Hardware decoder boundary.
///
/// Decoders own platform decode sessions and return a boxed GPU frame because
/// decoded handle types differ by OS/vendor. Implementations must bound decode
/// queues and prefer dropping stale delta frames over delaying input/control.
pub trait HardwareDecoder: Send {
    async fn configure(&mut self, codec: Codec, dimensions: Dimensions) -> Result<(), MediaError>;
    async fn decode(&mut self, frame: EncodedFrame) -> Result<Box<dyn GpuFrame>, MediaError>;
}

#[async_trait]
/// Renderer boundary.
///
/// Renderers borrow decoded frames for one present operation. Platform
/// implementations own swapchain/wgpu/Metal/DX/Vulkan state and must not block
/// the control path while waiting for cosmetic frame timing.
pub trait Renderer: Send {
    async fn render(
        &mut self,
        frame: &dyn GpuFrame,
        target_present_at: TimestampMicros,
    ) -> Result<(), MediaError>;
}

#[async_trait]
/// OS input-injection boundary.
///
/// The host owns authorization before this trait is called. Implementations are
/// expected to re-check OS permission state, suppress input when focus/session
/// state is invalid, and make `emergency_stop` best-effort nonblocking.
pub trait InputInjector: Send + Sync {
    async fn inject(&self, event: burnbar_remote_core::InputEvent) -> Result<(), MediaError>;
    async fn emergency_stop(&self) -> Result<(), MediaError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum UpscaleMode {
    Off,
    Spatial,
    Temporal,
    FrameInterpolation,
    TextPreserving,
    LowPower,
    RelayBandwidthSaving,
}

pub trait Upscaler: Send {
    fn mode(&self) -> UpscaleMode;
    fn output_dimensions(&self, input: Dimensions) -> Dimensions;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LatencyClass {
    UltraLow,
    Interactive,
    Balanced,
    Quality,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodecCapability {
    pub codec: Codec,
    pub hardware_encode: bool,
    pub hardware_decode: bool,
    pub max_dimensions: Dimensions,
    pub max_fps: u16,
    pub latency_class: LatencyClass,
    pub low_power: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaCapabilitySet {
    pub codecs: Vec<CodecCapability>,
    pub supports_dirty_regions: bool,
    pub supports_roi: bool,
    pub supports_intra_refresh: bool,
    pub supports_gpu_handle_import: bool,
    pub copy_class: CopyClass,
}

impl MediaCapabilitySet {
    pub fn choose_codec(
        &self,
        preference: QualityPreference,
        target: Dimensions,
        target_fps: u16,
    ) -> Option<Codec> {
        self.codecs
            .iter()
            .filter(|capability| capability_supports_target(capability, target, target_fps))
            .min_by_key(|capability| {
                (
                    codec_rank(capability.codec, preference),
                    latency_rank(capability.latency_class, preference),
                    !capability.low_power,
                )
            })
            .map(|capability| capability.codec)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QualityPreference {
    Quality,
    Balanced,
    Responsiveness,
    BandwidthSaver,
}

fn codec_rank(codec: Codec, preference: QualityPreference) -> u8 {
    match preference {
        QualityPreference::Quality | QualityPreference::BandwidthSaver => match codec {
            Codec::Av1 => 0,
            Codec::H265 => 1,
            Codec::H264 => 2,
            Codec::Vp9 => 3,
            Codec::Raw => 4,
        },
        QualityPreference::Balanced => match codec {
            Codec::Av1 => 0,
            Codec::H265 => 1,
            Codec::H264 => 2,
            Codec::Vp9 => 3,
            Codec::Raw => 4,
        },
        QualityPreference::Responsiveness => match codec {
            Codec::H264 => 0,
            Codec::H265 => 1,
            Codec::Av1 => 2,
            Codec::Vp9 => 3,
            Codec::Raw => 4,
        },
    }
}

fn capability_supports_target(
    capability: &CodecCapability,
    target: Dimensions,
    target_fps: u16,
) -> bool {
    capability.hardware_encode
        && capability.hardware_decode
        && capability.max_dimensions.width >= target.width
        && capability.max_dimensions.height >= target.height
        && capability.max_fps >= target_fps
}

fn latency_rank(latency_class: LatencyClass, preference: QualityPreference) -> u8 {
    match preference {
        QualityPreference::Responsiveness => match latency_class {
            LatencyClass::UltraLow => 0,
            LatencyClass::Interactive => 1,
            LatencyClass::Balanced => 2,
            LatencyClass::Quality => 3,
        },
        QualityPreference::BandwidthSaver => match latency_class {
            LatencyClass::UltraLow | LatencyClass::Interactive => 0,
            LatencyClass::Balanced => 1,
            LatencyClass::Quality => 2,
        },
        QualityPreference::Balanced => match latency_class {
            LatencyClass::Interactive => 0,
            LatencyClass::UltraLow | LatencyClass::Balanced => 1,
            LatencyClass::Quality => 2,
        },
        QualityPreference::Quality => match latency_class {
            LatencyClass::Quality => 0,
            LatencyClass::Balanced => 1,
            LatencyClass::Interactive => 2,
            LatencyClass::UltraLow => 3,
        },
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameDropPolicy {
    DropBeforeEncode,
    DropBeforePacketize,
    CursorOnlyUntilDamage,
    PreserveUntilKeyframe,
}

#[derive(Clone, Debug)]
pub struct ControllerInput {
    pub network: NetworkTelemetry,
    pub receiver_report: Option<ReceiverReport>,
    pub decode_time: Duration,
    pub render_time: Duration,
    pub received_frame_age: Duration,
    pub active_control: bool,
    pub preference: QualityPreference,
    pub current_dimensions: Dimensions,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ControllerOutput {
    pub target_bitrate_bps: u32,
    pub target_dimensions: Dimensions,
    pub target_fps: u16,
    pub qp_min: u8,
    pub qp_max: u8,
    pub fec_overhead_ppm: u32,
    pub request_keyframe: bool,
    pub allow_frame_drop: bool,
    pub cursor_only_until_next_damage: bool,
}

#[derive(Clone, Debug)]
pub struct AdaptiveQualityController {
    output: ControllerOutput,
    stable_samples: u32,
    degraded_samples: u32,
}

impl AdaptiveQualityController {
    pub fn new(initial_dimensions: Dimensions, preference: QualityPreference) -> Self {
        let bitrate = match preference {
            QualityPreference::Quality => 45_000_000,
            QualityPreference::Balanced => 24_000_000,
            QualityPreference::Responsiveness => 14_000_000,
            QualityPreference::BandwidthSaver => 6_000_000,
        };
        Self {
            output: ControllerOutput {
                target_bitrate_bps: bitrate,
                target_dimensions: initial_dimensions,
                target_fps: 60,
                qp_min: 18,
                qp_max: 38,
                fec_overhead_ppm: 0,
                request_keyframe: true,
                allow_frame_drop: true,
                cursor_only_until_next_damage: false,
            },
            stable_samples: 0,
            degraded_samples: 0,
        }
    }

    pub fn update(&mut self, input: ControllerInput) -> ControllerOutput {
        let loss_ppm = input.network.packet_loss_ppm.unwrap_or_default();
        let rtt_micros = input.network.rtt_micros.unwrap_or_default();
        let relay = input.network.relay || input.network.path_kind == PathKind::Relay;
        let queue_bad = input.network.send_queue_bytes > 256 * 1024
            || input.network.datagram_send_buffer_space < 2_048
            || input.network.dropped_media_datagrams > 0;
        let stale_frames = input.received_frame_age > Duration::from_millis(80);
        let slow_client = input.decode_time + input.render_time > Duration::from_millis(24);
        let network_bad = loss_ppm > 20_000 || rtt_micros > 120_000 || queue_bad || stale_frames;

        let relay_cap = match input.preference {
            QualityPreference::Quality => 18_000_000,
            QualityPreference::Balanced => 10_000_000,
            QualityPreference::Responsiveness => 6_000_000,
            QualityPreference::BandwidthSaver => 3_000_000,
        };
        let direct_cap = match input.preference {
            QualityPreference::Quality => 90_000_000,
            QualityPreference::Balanced => 45_000_000,
            QualityPreference::Responsiveness => 24_000_000,
            QualityPreference::BandwidthSaver => 10_000_000,
        };
        let cap = if relay { relay_cap } else { direct_cap };

        if network_bad || slow_client {
            self.fast_downshift(input.preference, input.current_dimensions, relay);
            self.degraded_samples = self.degraded_samples.saturating_add(1);
            self.stable_samples = 0;
        } else {
            self.stable_samples = self.stable_samples.saturating_add(1);
            self.degraded_samples = 0;
            if self.stable_samples >= 30 {
                self.slow_recover(cap, input.current_dimensions);
                self.stable_samples = 0;
            }
        }

        if input.active_control {
            self.output.target_bitrate_bps =
                self.output.target_bitrate_bps.min(cap / 2).max(1_500_000);
            self.output.target_fps = self.output.target_fps.max(45);
            self.output.qp_max = self.output.qp_max.max(42);
        }

        self.output.target_bitrate_bps = self.output.target_bitrate_bps.min(cap);
        if relay {
            self.output.fec_overhead_ppm = if loss_ppm > 5_000 { 60_000 } else { 20_000 };
        } else {
            self.output.fec_overhead_ppm = if loss_ppm > 10_000 { 40_000 } else { 0 };
        }
        self.output.request_keyframe = self.degraded_samples == 1
            || input
                .receiver_report
                .as_ref()
                .is_some_and(|r| r.keyframe_requests > 0);
        self.output.clone()
    }

    fn fast_downshift(
        &mut self,
        preference: QualityPreference,
        current_dimensions: Dimensions,
        relay: bool,
    ) {
        self.output.target_bitrate_bps = self.output.target_bitrate_bps.saturating_mul(65) / 100;
        self.output.target_fps = match preference {
            QualityPreference::Quality | QualityPreference::Balanced => {
                self.output.target_fps.min(45)
            }
            QualityPreference::Responsiveness => self.output.target_fps.min(60),
            QualityPreference::BandwidthSaver => self.output.target_fps.min(30),
        };
        let floor = if relay || preference == QualityPreference::BandwidthSaver {
            Dimensions {
                width: 960,
                height: 540,
            }
        } else {
            Dimensions {
                width: 1280,
                height: 720,
            }
        };
        let down = current_dimensions.scaled_by(85, 100);
        self.output.target_dimensions = Dimensions {
            width: down.width.max(floor.width).min(current_dimensions.width),
            height: down.height.max(floor.height).min(current_dimensions.height),
        };
        self.output.qp_min = self.output.qp_min.saturating_add(2).min(28);
        self.output.qp_max = self.output.qp_max.saturating_add(4).min(48);
        self.output.allow_frame_drop = true;
    }

    fn slow_recover(&mut self, cap: u32, current_dimensions: Dimensions) {
        let recovered_bitrate = u64::from(self.output.target_bitrate_bps).saturating_mul(108) / 100;
        self.output.target_bitrate_bps =
            u32::try_from(recovered_bitrate.min(u64::from(cap))).unwrap_or(cap);
        self.output.target_dimensions = Dimensions {
            width: (self.output.target_dimensions.width + 160).min(current_dimensions.width),
            height: (self.output.target_dimensions.height + 90).min(current_dimensions.height),
        };
        self.output.qp_min = self.output.qp_min.saturating_sub(1).max(16);
        self.output.qp_max = self.output.qp_max.saturating_sub(1).max(34);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use burnbar_remote_core::{ColorSpace, SequenceNumber};
    use burnbar_remote_observability::NetworkTelemetry;

    fn must<T, E: std::fmt::Display>(result: Result<T, E>, context: &str) -> T {
        match result {
            Ok(value) => value,
            Err(error) => panic!("{context}: {error}"),
        }
    }

    fn must_some<T>(option: Option<T>, context: &str) -> T {
        match option {
            Some(value) => value,
            None => panic!("{context}"),
        }
    }

    fn dims(width: u32, height: u32) -> Dimensions {
        must(Dimensions::new(width, height), "dimensions should be valid")
    }

    fn frame_metadata(frame_id: u64) -> FrameMetadata {
        FrameMetadata {
            frame_id: FrameId(frame_id),
            display_id: DisplayId::new("main"),
            sequence: SequenceNumber(frame_id),
            dimensions: dims(1920, 1080),
            capture_started_at: TimestampMicros(10),
            captured_at: TimestampMicros(20),
            encode_started_at: TimestampMicros(30),
            encoded_at: TimestampMicros(40),
            codec: Codec::Av1,
            dependency: FrameDependency::Key,
            color_space: ColorSpace::Srgb,
            dirty_regions: vec![],
        }
    }

    #[test]
    fn relay_path_caps_bitrate() {
        let dims = dims(3840, 2160);
        let mut controller = AdaptiveQualityController::new(dims, QualityPreference::Balanced);
        let mut telemetry = NetworkTelemetry::direct_good();
        telemetry.relay = true;
        telemetry.path_kind = PathKind::Relay;
        let output = controller.update(ControllerInput {
            network: telemetry,
            receiver_report: None,
            decode_time: Duration::from_millis(4),
            render_time: Duration::from_millis(4),
            received_frame_age: Duration::from_millis(10),
            active_control: false,
            preference: QualityPreference::Balanced,
            current_dimensions: dims,
        });
        assert!(output.target_bitrate_bps <= 10_000_000);
    }

    #[test]
    fn packet_loss_fast_downshifts() {
        let dims = dims(1920, 1080);
        let mut controller = AdaptiveQualityController::new(dims, QualityPreference::Balanced);
        let mut telemetry = NetworkTelemetry::direct_good();
        telemetry.packet_loss_ppm = Some(30_000);
        let output = controller.update(ControllerInput {
            network: telemetry,
            receiver_report: None,
            decode_time: Duration::from_millis(4),
            render_time: Duration::from_millis(4),
            received_frame_age: Duration::from_millis(10),
            active_control: false,
            preference: QualityPreference::Balanced,
            current_dimensions: dims,
        });
        assert!(output.target_bitrate_bps < 24_000_000);
        assert!(output.allow_frame_drop);
    }

    #[test]
    fn packetizer_chunks_and_depacketizer_reassembles() {
        let frame = EncodedFrame {
            metadata: frame_metadata(7),
            codec: Codec::Av1,
            dependency: FrameDependency::Key,
            bytes: Bytes::from(vec![42u8; 4_096]),
        };
        let mut packetizer = DatagramPacketizer::new(3);
        let mut packets = Vec::new();
        must(
            packetizer.packetize(frame, 1_200, &mut packets),
            "frame should packetize",
        );
        assert!(packets.len() > 1);
        assert!(packets.iter().all(|packet| packet.len() <= 1_200));

        let mut depacketizer = DatagramDepacketizer::new(8, Duration::from_millis(100));
        let mut out = None;
        for packet in packets {
            out = must(
                depacketizer.push(packet, TimestampMicros(50)),
                "packet should depacketize",
            );
        }
        let out = must_some(out, "packets should complete a frame");
        assert_eq!(out.frame_id, FrameId(7));
        assert_eq!(out.stream_id, 3);
        assert_eq!(out.dependency, FrameDependency::Key);
        assert_eq!(out.bytes.len(), 4_096);
    }

    #[test]
    fn depacketizer_discards_stale_partial_frames() {
        let frame = EncodedFrame {
            metadata: frame_metadata(8),
            codec: Codec::Av1,
            dependency: FrameDependency::Delta,
            bytes: Bytes::from(vec![7u8; 2_048]),
        };
        let mut packetizer = DatagramPacketizer::new(1);
        let mut packets = Vec::new();
        must(
            packetizer.packetize(frame, 1_200, &mut packets),
            "frame should packetize",
        );

        let mut depacketizer = DatagramDepacketizer::new(8, Duration::from_millis(10));
        assert!(must(
            depacketizer.push(packets.remove(0), TimestampMicros(1_000)),
            "packet should depacketize",
        )
        .is_none());
        assert_eq!(depacketizer.incomplete_count(), 1);
        assert_eq!(depacketizer.discard_stale(TimestampMicros(20_000)), 1);
        assert_eq!(depacketizer.incomplete_count(), 0);
    }

    #[test]
    fn depacketizer_completes_frame_when_capacity_is_full_with_same_frame() {
        let frame = EncodedFrame {
            metadata: frame_metadata(9),
            codec: Codec::Av1,
            dependency: FrameDependency::Delta,
            bytes: Bytes::from(vec![9u8; 2_048]),
        };
        let mut packetizer = DatagramPacketizer::new(1);
        let mut packets = Vec::new();
        must(
            packetizer.packetize(frame, 1_200, &mut packets),
            "frame should packetize",
        );

        let mut depacketizer = DatagramDepacketizer::new(1, Duration::from_millis(100));
        assert!(must(
            depacketizer.push(packets.remove(0), TimestampMicros(1_000)),
            "packet should depacketize",
        )
        .is_none());
        assert_eq!(depacketizer.incomplete_count(), 1);

        let out = must_some(
            must(
                depacketizer.push(packets.remove(0), TimestampMicros(1_100)),
                "packet should depacketize",
            ),
            "second packet should complete the existing partial",
        );
        assert_eq!(out.frame_id, FrameId(9));
        assert_eq!(out.stream_id, 1);
        assert_eq!(out.bytes.len(), 2_048);
        assert_eq!(depacketizer.incomplete_count(), 0);
    }

    #[test]
    fn depacketizer_allows_same_frame_id_on_different_streams() {
        let frame_a = EncodedFrame {
            metadata: frame_metadata(10),
            codec: Codec::Av1,
            dependency: FrameDependency::Delta,
            bytes: Bytes::from(vec![1u8; 2_048]),
        };
        let frame_b = EncodedFrame {
            metadata: frame_metadata(10),
            codec: Codec::Av1,
            dependency: FrameDependency::Key,
            bytes: Bytes::from(vec![2u8; 2_048]),
        };
        let mut packetizer_a = DatagramPacketizer::new(1);
        let mut packetizer_b = DatagramPacketizer::new(2);
        let mut packets_a = Vec::new();
        let mut packets_b = Vec::new();
        must(
            packetizer_a.packetize(frame_a, 1_200, &mut packets_a),
            "stream 1 frame should packetize",
        );
        must(
            packetizer_b.packetize(frame_b, 1_200, &mut packets_b),
            "stream 2 frame should packetize",
        );

        let mut depacketizer = DatagramDepacketizer::new(8, Duration::from_millis(100));
        assert!(must(
            depacketizer.push(packets_a.remove(0), TimestampMicros(1_000)),
            "stream 1 first packet should depacketize",
        )
        .is_none());
        assert!(must(
            depacketizer.push(packets_b.remove(0), TimestampMicros(1_010)),
            "stream 2 first packet should depacketize",
        )
        .is_none());

        let out_a = must_some(
            must(
                depacketizer.push(packets_a.remove(0), TimestampMicros(1_020)),
                "stream 1 second packet should depacketize",
            ),
            "stream 1 frame should complete independently",
        );
        let out_b = must_some(
            must(
                depacketizer.push(packets_b.remove(0), TimestampMicros(1_030)),
                "stream 2 second packet should depacketize",
            ),
            "stream 2 frame should complete independently",
        );

        assert_eq!(out_a.frame_id, FrameId(10));
        assert_eq!(out_a.stream_id, 1);
        assert!(out_a.bytes.iter().all(|byte| *byte == 1));
        assert_eq!(out_b.frame_id, FrameId(10));
        assert_eq!(out_b.stream_id, 2);
        assert_eq!(out_b.dependency, FrameDependency::Key);
        assert!(out_b.bytes.iter().all(|byte| *byte == 2));
    }

    #[test]
    fn codec_policy_prefers_responsiveness_over_av1_when_requested() {
        let dims = dims(1920, 1080);
        let caps = MediaCapabilitySet {
            codecs: vec![
                CodecCapability {
                    codec: Codec::Av1,
                    hardware_encode: true,
                    hardware_decode: true,
                    max_dimensions: dims,
                    max_fps: 60,
                    latency_class: LatencyClass::Balanced,
                    low_power: false,
                },
                CodecCapability {
                    codec: Codec::H264,
                    hardware_encode: true,
                    hardware_decode: true,
                    max_dimensions: dims,
                    max_fps: 120,
                    latency_class: LatencyClass::UltraLow,
                    low_power: true,
                },
            ],
            supports_dirty_regions: true,
            supports_roi: true,
            supports_intra_refresh: true,
            supports_gpu_handle_import: true,
            copy_class: CopyClass::GpuToGpuZeroCopy,
        };
        assert_eq!(
            caps.choose_codec(QualityPreference::Responsiveness, dims, 60),
            Some(Codec::H264)
        );
        assert_eq!(
            caps.choose_codec(QualityPreference::BandwidthSaver, dims, 60),
            Some(Codec::Av1)
        );
    }

    #[test]
    fn codec_policy_never_returns_codec_that_misses_target_shape() {
        let full_hd = dims(1920, 1080);
        let uhd = dims(3840, 2160);
        let caps = MediaCapabilitySet {
            codecs: vec![
                CodecCapability {
                    codec: Codec::Av1,
                    hardware_encode: true,
                    hardware_decode: true,
                    max_dimensions: full_hd,
                    max_fps: 60,
                    latency_class: LatencyClass::Balanced,
                    low_power: false,
                },
                CodecCapability {
                    codec: Codec::H264,
                    hardware_encode: true,
                    hardware_decode: true,
                    max_dimensions: uhd,
                    max_fps: 120,
                    latency_class: LatencyClass::UltraLow,
                    low_power: true,
                },
            ],
            supports_dirty_regions: true,
            supports_roi: true,
            supports_intra_refresh: true,
            supports_gpu_handle_import: true,
            copy_class: CopyClass::GpuToGpuZeroCopy,
        };

        assert_eq!(
            caps.choose_codec(QualityPreference::BandwidthSaver, uhd, 120),
            Some(Codec::H264)
        );
        assert_eq!(
            caps.choose_codec(QualityPreference::BandwidthSaver, uhd, 144),
            None
        );
    }

    #[test]
    fn stable_samples_recover_slowly() {
        let dims = dims(1920, 1080);
        let mut controller = AdaptiveQualityController::new(dims, QualityPreference::Balanced);
        let mut bad = NetworkTelemetry::direct_good();
        bad.packet_loss_ppm = Some(40_000);
        let degraded = controller.update(ControllerInput {
            network: bad,
            receiver_report: None,
            decode_time: Duration::from_millis(4),
            render_time: Duration::from_millis(4),
            received_frame_age: Duration::from_millis(10),
            active_control: false,
            preference: QualityPreference::Balanced,
            current_dimensions: dims,
        });
        for _ in 0..29 {
            controller.update(ControllerInput {
                network: NetworkTelemetry::direct_good(),
                receiver_report: None,
                decode_time: Duration::from_millis(4),
                render_time: Duration::from_millis(4),
                received_frame_age: Duration::from_millis(10),
                active_control: false,
                preference: QualityPreference::Balanced,
                current_dimensions: dims,
            });
        }
        let recovered = controller.update(ControllerInput {
            network: NetworkTelemetry::direct_good(),
            receiver_report: None,
            decode_time: Duration::from_millis(4),
            render_time: Duration::from_millis(4),
            received_frame_age: Duration::from_millis(10),
            active_control: false,
            preference: QualityPreference::Balanced,
            current_dimensions: dims,
        });
        assert!(recovered.target_bitrate_bps > degraded.target_bitrate_bps);
        assert!(recovered.target_bitrate_bps < 24_000_000);
    }
}
