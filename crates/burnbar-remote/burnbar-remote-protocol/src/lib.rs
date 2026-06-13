use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use burnbar_remote_core::{
    AccountId, DeviceId, EndpointId, FrameId, SequenceNumber, SessionId, SessionMode,
    TimestampMicros, WorkspaceId,
};

pub const REMOTE_ALPN: &[u8] = b"openburnbar/remote/1";
pub const WIRE_VERSION: u16 = 1;
pub const MAX_CONTROL_FRAME_BYTES: usize = 64 * 1024;
pub const RELIABLE_PREFIX_LEN: usize = 8;
pub const MEDIA_DATAGRAM_HEADER_LEN: usize = 32;

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("unknown stream class {0}")]
    UnknownStreamClass(u8),
    #[error("unknown message kind {0}")]
    UnknownMessageKind(u16),
    #[error("unknown datagram class {0}")]
    UnknownDatagramClass(u8),
    #[error("payload length {actual} exceeds maximum {max}")]
    PayloadTooLarge { actual: usize, max: usize },
    #[error("buffer is too short: expected at least {expected}, got {actual}")]
    BufferTooShort { expected: usize, actual: usize },
    #[error("buffer has trailing bytes: expected exactly {expected}, got {actual}")]
    TrailingBytes { expected: usize, actual: usize },
    #[error("postcard serialization failed: {0}")]
    Serialization(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum StreamClass {
    Control = 1,
    Telemetry = 2,
    ReliableMedia = 3,
    Clipboard = 4,
}

impl TryFrom<u8> for StreamClass {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Control),
            2 => Ok(Self::Telemetry),
            3 => Ok(Self::ReliableMedia),
            4 => Ok(Self::Clipboard),
            other => Err(ProtocolError::UnknownStreamClass(other)),
        }
    }
}

impl From<StreamClass> for u8 {
    fn from(value: StreamClass) -> Self {
        value as u8
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u16)]
pub enum MessageKind {
    Hello = 1,
    SessionGrant = 2,
    Input = 3,
    PermissionChange = 4,
    DisplayTopology = 5,
    Heartbeat = 6,
    ReceiverReport = 7,
    KeyframeRequest = 8,
    GracefulShutdown = 9,
    ErrorReport = 10,
    SessionRequest = 11,
    SessionDenied = 12,
}

impl TryFrom<u16> for MessageKind {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, <Self as TryFrom<u16>>::Error> {
        match value {
            1 => Ok(Self::Hello),
            2 => Ok(Self::SessionGrant),
            3 => Ok(Self::Input),
            4 => Ok(Self::PermissionChange),
            5 => Ok(Self::DisplayTopology),
            6 => Ok(Self::Heartbeat),
            7 => Ok(Self::ReceiverReport),
            8 => Ok(Self::KeyframeRequest),
            9 => Ok(Self::GracefulShutdown),
            10 => Ok(Self::ErrorReport),
            11 => Ok(Self::SessionRequest),
            12 => Ok(Self::SessionDenied),
            other => Err(ProtocolError::UnknownMessageKind(other)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReliableFramePrefix {
    pub payload_len: u32,
    pub kind: MessageKind,
    pub flags: u16,
}

impl ReliableFramePrefix {
    pub fn encode(self) -> [u8; RELIABLE_PREFIX_LEN] {
        let mut out = [0u8; RELIABLE_PREFIX_LEN];
        out[0..4].copy_from_slice(&self.payload_len.to_be_bytes());
        out[4..6].copy_from_slice(&(self.kind as u16).to_be_bytes());
        out[6..8].copy_from_slice(&self.flags.to_be_bytes());
        out
    }

    pub fn decode(bytes: [u8; RELIABLE_PREFIX_LEN]) -> Result<Self, ProtocolError> {
        let payload_len = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        let kind = MessageKind::try_from(u16::from_be_bytes([bytes[4], bytes[5]]))?;
        let flags = u16::from_be_bytes([bytes[6], bytes[7]]);
        Ok(Self {
            payload_len,
            kind,
            flags,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum DatagramClass {
    Video = 1,
    Audio = 2,
    ReceiverReport = 3,
    CursorState = 4,
}

impl TryFrom<u8> for DatagramClass {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Video),
            2 => Ok(Self::Audio),
            3 => Ok(Self::ReceiverReport),
            4 => Ok(Self::CursorState),
            other => Err(ProtocolError::UnknownDatagramClass(other)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaDatagramHeader {
    pub class: DatagramClass,
    pub flags: u8,
    pub stream_id: u16,
    pub frame_id: FrameId,
    pub packet_index: u16,
    pub packet_count: u16,
    pub capture_timestamp: TimestampMicros,
    pub payload_len: u16,
}

impl MediaDatagramHeader {
    pub fn encode(self) -> [u8; MEDIA_DATAGRAM_HEADER_LEN] {
        let mut out = [0u8; MEDIA_DATAGRAM_HEADER_LEN];
        out[0] = self.class as u8;
        out[1] = self.flags;
        out[2..4].copy_from_slice(&self.stream_id.to_be_bytes());
        out[4..12].copy_from_slice(&self.frame_id.0.to_be_bytes());
        out[12..14].copy_from_slice(&self.packet_index.to_be_bytes());
        out[14..16].copy_from_slice(&self.packet_count.to_be_bytes());
        out[16..24].copy_from_slice(&self.capture_timestamp.0.to_be_bytes());
        out[24..26].copy_from_slice(&self.payload_len.to_be_bytes());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ProtocolError> {
        if bytes.len() < MEDIA_DATAGRAM_HEADER_LEN {
            return Err(ProtocolError::BufferTooShort {
                expected: MEDIA_DATAGRAM_HEADER_LEN,
                actual: bytes.len(),
            });
        }
        Ok(Self {
            class: DatagramClass::try_from(bytes[0])?,
            flags: bytes[1],
            stream_id: u16::from_be_bytes([bytes[2], bytes[3]]),
            frame_id: FrameId(u64::from_be_bytes([
                bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
            ])),
            packet_index: u16::from_be_bytes([bytes[12], bytes[13]]),
            packet_count: u16::from_be_bytes([bytes[14], bytes[15]]),
            capture_timestamp: TimestampMicros(u64::from_be_bytes([
                bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22],
                bytes[23],
            ])),
            payload_len: u16::from_be_bytes([bytes[24], bytes[25]]),
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncodedDatagram {
    pub header: MediaDatagramHeader,
    pub bytes: Bytes,
}

pub fn encode_media_datagram(
    header: MediaDatagramHeader,
    payload: &[u8],
) -> Result<EncodedDatagram, ProtocolError> {
    let payload_len = u16::try_from(payload.len()).map_err(|_| ProtocolError::PayloadTooLarge {
        actual: payload.len(),
        max: u16::MAX as usize,
    })?;
    let mut header = header;
    header.payload_len = payload_len;
    let mut out = BytesMut::with_capacity(MEDIA_DATAGRAM_HEADER_LEN + payload.len());
    out.put_slice(&header.encode());
    out.put_slice(payload);
    Ok(EncodedDatagram {
        header,
        bytes: out.freeze(),
    })
}

pub fn decode_media_datagram(bytes: Bytes) -> Result<(MediaDatagramHeader, Bytes), ProtocolError> {
    let header = MediaDatagramHeader::decode(&bytes)?;
    let expected = MEDIA_DATAGRAM_HEADER_LEN + header.payload_len as usize;
    if bytes.len() < expected {
        return Err(ProtocolError::BufferTooShort {
            expected,
            actual: bytes.len(),
        });
    }
    if bytes.len() != expected {
        return Err(ProtocolError::TrailingBytes {
            expected,
            actual: bytes.len(),
        });
    }
    let payload = bytes.slice(MEDIA_DATAGRAM_HEADER_LEN..expected);
    Ok((header, payload))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct HelloMessage {
    pub version: u16,
    pub session_id: SessionId,
    pub endpoint_id: String,
    pub supported_codecs: Vec<String>,
    pub features: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionRequestMessage {
    pub version: u16,
    pub client_endpoint_id: EndpointId,
    pub client_device_id: DeviceId,
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub requested_mode: SessionMode,
    pub nonce: [u8; 16],
    pub requested_at: TimestampMicros,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionDeniedMessage {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct HeartbeatMessage {
    pub sequence: SequenceNumber,
    pub sent_at: TimestampMicros,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReceiverReportMessage {
    pub highest_contiguous_frame: FrameId,
    pub last_rendered_frame: FrameId,
    pub received_at: TimestampMicros,
    pub decoded_at: TimestampMicros,
    pub rendered_at: TimestampMicros,
    pub lost_packets: u32,
    pub decode_time_micros: u32,
    pub render_time_micros: u32,
}

pub fn encode_control<T: Serialize>(value: &T, scratch: &mut Vec<u8>) -> Result<(), ProtocolError> {
    let writer = std::mem::take(scratch);
    let writer = postcard::to_extend(value, writer)
        .map_err(|err| ProtocolError::Serialization(err.to_string()))?;
    *scratch = writer;
    if scratch.len() > MAX_CONTROL_FRAME_BYTES {
        return Err(ProtocolError::PayloadTooLarge {
            actual: scratch.len(),
            max: MAX_CONTROL_FRAME_BYTES,
        });
    }
    Ok(())
}

pub fn decode_control<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T, ProtocolError> {
    postcard::from_bytes(bytes).map_err(|err| ProtocolError::Serialization(err.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reliable_prefix_round_trips() {
        let prefix = ReliableFramePrefix {
            payload_len: 42,
            kind: MessageKind::Input,
            flags: 7,
        };
        let decoded = match ReliableFramePrefix::decode(prefix.encode()) {
            Ok(decoded) => decoded,
            Err(error) => panic!("reliable prefix should decode: {error}"),
        };
        assert_eq!(decoded, prefix);
    }

    #[test]
    fn media_datagram_header_is_fixed_layout() {
        let header = MediaDatagramHeader {
            class: DatagramClass::Video,
            flags: 3,
            stream_id: 9,
            frame_id: FrameId(77),
            packet_index: 2,
            packet_count: 4,
            capture_timestamp: TimestampMicros(123),
            payload_len: 0,
        };
        let encoded = match encode_media_datagram(header, b"abc") {
            Ok(encoded) => encoded,
            Err(error) => panic!("media datagram should encode: {error}"),
        };
        let (decoded, payload) = match decode_media_datagram(encoded.bytes) {
            Ok(decoded) => decoded,
            Err(error) => panic!("media datagram should decode: {error}"),
        };
        assert_eq!(decoded.payload_len, 3);
        assert_eq!(payload.as_ref(), b"abc");
    }

    #[test]
    fn media_datagram_rejects_trailing_bytes() {
        let header = MediaDatagramHeader {
            class: DatagramClass::Video,
            flags: 0,
            stream_id: 1,
            frame_id: FrameId(1),
            packet_index: 0,
            packet_count: 1,
            capture_timestamp: TimestampMicros(1),
            payload_len: 0,
        };
        let mut bytes = match encode_media_datagram(header, b"abc") {
            Ok(encoded) => encoded.bytes.to_vec(),
            Err(error) => panic!("media datagram should encode: {error}"),
        };
        bytes.push(0);
        assert!(matches!(
            decode_media_datagram(Bytes::from(bytes)),
            Err(ProtocolError::TrailingBytes { .. })
        ));
    }

    #[test]
    fn media_datagram_rejects_unknown_class_and_short_header() {
        assert!(matches!(
            decode_media_datagram(Bytes::from_static(b"short")),
            Err(ProtocolError::BufferTooShort { .. })
        ));
        let mut bytes = [0u8; MEDIA_DATAGRAM_HEADER_LEN];
        bytes[0] = 99;
        assert!(matches!(
            decode_media_datagram(Bytes::copy_from_slice(&bytes)),
            Err(ProtocolError::UnknownDatagramClass(99))
        ));
    }

    #[test]
    fn session_request_round_trips_with_version_and_nonce() {
        let request = SessionRequestMessage {
            version: WIRE_VERSION,
            client_endpoint_id: EndpointId::new("endpoint"),
            client_device_id: DeviceId::new("device"),
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            requested_mode: SessionMode::Control,
            nonce: [7u8; 16],
            requested_at: TimestampMicros(42),
        };
        let mut scratch = Vec::new();
        if let Err(error) = encode_control(&request, &mut scratch) {
            panic!("session request should encode: {error}");
        }
        let decoded = match decode_control::<SessionRequestMessage>(&scratch) {
            Ok(decoded) => decoded,
            Err(error) => panic!("session request should decode: {error}"),
        };
        assert_eq!(decoded, request);
    }
}
