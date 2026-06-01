use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use burnbar_remote_core::{FrameId, SequenceNumber, SessionId, TimestampMicros};

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
        let payload_len = u32::from_be_bytes(bytes[0..4].try_into().expect("fixed"));
        let kind =
            MessageKind::try_from(u16::from_be_bytes(bytes[4..6].try_into().expect("fixed")))?;
        let flags = u16::from_be_bytes(bytes[6..8].try_into().expect("fixed"));
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
            stream_id: u16::from_be_bytes(bytes[2..4].try_into().expect("fixed")),
            frame_id: FrameId(u64::from_be_bytes(bytes[4..12].try_into().expect("fixed"))),
            packet_index: u16::from_be_bytes(bytes[12..14].try_into().expect("fixed")),
            packet_count: u16::from_be_bytes(bytes[14..16].try_into().expect("fixed")),
            capture_timestamp: TimestampMicros(u64::from_be_bytes(
                bytes[16..24].try_into().expect("fixed"),
            )),
            payload_len: u16::from_be_bytes(bytes[24..26].try_into().expect("fixed")),
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
    if payload.len() > u16::MAX as usize {
        return Err(ProtocolError::PayloadTooLarge {
            actual: payload.len(),
            max: u16::MAX as usize,
        });
    }
    let mut header = header;
    header.payload_len = payload.len() as u16;
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
        assert_eq!(
            ReliableFramePrefix::decode(prefix.encode()).unwrap(),
            prefix
        );
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
        let encoded = encode_media_datagram(header, b"abc").unwrap();
        let (decoded, payload) = decode_media_datagram(encoded.bytes).unwrap();
        assert_eq!(decoded.payload_len, 3);
        assert_eq!(payload.as_ref(), b"abc");
    }
}
