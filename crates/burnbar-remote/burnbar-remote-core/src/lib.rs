use std::collections::{BTreeSet, VecDeque};
use std::fmt;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum RemoteCoreError {
    #[error("bounded queue capacity must be greater than zero")]
    EmptyQueueCapacity,
    #[error("invalid dimensions {width}x{height}")]
    InvalidDimensions { width: u32, height: u32 },
    #[error("payload length {actual} exceeds configured limit {limit}")]
    PayloadTooLarge { actual: usize, limit: usize },
}

macro_rules! string_id {
    ($name:ident) => {
        #[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        pub struct $name(pub String);

        impl $name {
            pub fn new(value: impl Into<String>) -> Self {
                Self(value.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
    };
}

string_id!(AccountId);
string_id!(WorkspaceId);
string_id!(DeviceId);
string_id!(EndpointId);
string_id!(SessionId);
string_id!(GrantId);
string_id!(DisplayId);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct TimestampMicros(pub u64);

impl TimestampMicros {
    pub const ZERO: Self = Self(0);

    pub fn saturating_add_duration(self, duration: Duration) -> Self {
        let micros = duration.as_micros().min(u64::MAX as u128) as u64;
        Self(self.0.saturating_add(micros))
    }

    pub fn saturating_duration_since(self, earlier: Self) -> Duration {
        Duration::from_micros(self.0.saturating_sub(earlier.0))
    }
}

#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
pub struct FrameId(pub u64);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct SequenceNumber(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dimensions {
    pub width: u32,
    pub height: u32,
}

impl Dimensions {
    pub fn new(width: u32, height: u32) -> Result<Self, RemoteCoreError> {
        if width == 0 || height == 0 {
            return Err(RemoteCoreError::InvalidDimensions { width, height });
        }
        Ok(Self { width, height })
    }

    pub fn pixels(self) -> u64 {
        self.width as u64 * self.height as u64
    }

    pub fn scaled_by(self, numerator: u32, denominator: u32) -> Self {
        let denominator = denominator.max(1);
        let width = ((self.width as u64 * numerator as u64) / denominator as u64).max(1) as u32;
        let height = ((self.height as u64 * numerator as u64) / denominator as u64).max(1) as u32;
        Self { width, height }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Codec {
    Av1,
    H265,
    H264,
    Vp9,
    Raw,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ColorSpace {
    Srgb,
    DisplayP3,
    Rec709,
    Rec2020,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FrameDependency {
    Key,
    Delta,
    IntraRefresh,
    CursorOnly,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrameMetadata {
    pub frame_id: FrameId,
    pub display_id: DisplayId,
    pub sequence: SequenceNumber,
    pub dimensions: Dimensions,
    pub capture_started_at: TimestampMicros,
    pub captured_at: TimestampMicros,
    pub encode_started_at: TimestampMicros,
    pub encoded_at: TimestampMicros,
    pub codec: Codec,
    pub dependency: FrameDependency,
    pub color_space: ColorSpace,
    pub dirty_regions: Vec<Rect>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeliverySemantics {
    ReliableOrdered,
    ReliableUnordered,
    UnreliableDatagram,
    LatestStateWins,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Permission {
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

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PermissionSet {
    inner: BTreeSet<Permission>,
}

impl PermissionSet {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn contains(&self, permission: Permission) -> bool {
        self.inner.contains(&permission)
    }

    pub fn is_superset(&self, required: &PermissionSet) -> bool {
        required.inner.is_subset(&self.inner)
    }

    pub fn insert(&mut self, permission: Permission) {
        self.inner.insert(permission);
    }

    pub fn iter(&self) -> impl Iterator<Item = Permission> + '_ {
        self.inner.iter().copied()
    }
}

impl FromIterator<Permission> for PermissionSet {
    fn from_iter<T: IntoIterator<Item = Permission>>(iter: T) -> Self {
        Self {
            inner: iter.into_iter().collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionMode {
    ViewOnly,
    Control,
    AgentObserve,
    AgentAssist,
}

impl SessionMode {
    pub fn required_permissions(self) -> PermissionSet {
        match self {
            Self::ViewOnly | Self::AgentObserve => {
                PermissionSet::from_iter([Permission::ViewScreen])
            }
            Self::Control | Self::AgentAssist => {
                PermissionSet::from_iter([Permission::ViewScreen, Permission::InjectInput])
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionDescriptor {
    pub session_id: SessionId,
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub host_device_id: DeviceId,
    pub client_device_id: DeviceId,
    pub mode: SessionMode,
    pub permissions: PermissionSet,
    pub issued_at: TimestampMicros,
    pub expires_at: TimestampMicros,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    Back,
    Forward,
    Other(u16),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum KeyState {
    Down,
    Up,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum InputEvent {
    RelativeMouse {
        dx: f64,
        dy: f64,
        sequence: SequenceNumber,
    },
    AbsoluteMouse {
        display_id: DisplayId,
        x: f64,
        y: f64,
        sequence: SequenceNumber,
    },
    MouseButton {
        button: MouseButton,
        state: KeyState,
        sequence: SequenceNumber,
    },
    KeyboardScanCode {
        scan_code: u32,
        state: KeyState,
        modifiers: u32,
        sequence: SequenceNumber,
    },
    Text {
        text: String,
        sequence: SequenceNumber,
    },
    Clipboard {
        mime_type: String,
        byte_len: u64,
        sequence: SequenceNumber,
    },
}

impl InputEvent {
    pub fn required_permissions(&self) -> PermissionSet {
        match self {
            Self::Clipboard { .. } => PermissionSet::from_iter([Permission::ClipboardWrite]),
            _ => PermissionSet::from_iter([Permission::InjectInput]),
        }
    }

    pub fn sequence(&self) -> SequenceNumber {
        match self {
            Self::RelativeMouse { sequence, .. }
            | Self::AbsoluteMouse { sequence, .. }
            | Self::MouseButton { sequence, .. }
            | Self::KeyboardScanCode { sequence, .. }
            | Self::Text { sequence, .. }
            | Self::Clipboard { sequence, .. } => *sequence,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueuePushOutcome<T> {
    Enqueued,
    DroppedOldest(T),
    Rejected(T),
}

#[derive(Clone, Debug)]
pub struct BoundedQueue<T> {
    capacity: usize,
    items: VecDeque<T>,
}

impl<T> BoundedQueue<T> {
    pub fn with_capacity(capacity: usize) -> Result<Self, RemoteCoreError> {
        if capacity == 0 {
            return Err(RemoteCoreError::EmptyQueueCapacity);
        }
        Ok(Self {
            capacity,
            items: VecDeque::with_capacity(capacity),
        })
    }

    pub fn push_drop_oldest(&mut self, item: T) -> QueuePushOutcome<T> {
        if self.items.len() == self.capacity {
            let dropped = self.items.pop_front().expect("len checked");
            self.items.push_back(item);
            QueuePushOutcome::DroppedOldest(dropped)
        } else {
            self.items.push_back(item);
            QueuePushOutcome::Enqueued
        }
    }

    pub fn push_reject_new(&mut self, item: T) -> QueuePushOutcome<T> {
        if self.items.len() == self.capacity {
            QueuePushOutcome::Rejected(item)
        } else {
            self.items.push_back(item);
            QueuePushOutcome::Enqueued
        }
    }

    pub fn pop_front(&mut self) -> Option<T> {
        self.items.pop_front()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_queue_drops_oldest_media() {
        let mut queue = BoundedQueue::with_capacity(2).unwrap();
        assert_eq!(queue.push_drop_oldest(1), QueuePushOutcome::Enqueued);
        assert_eq!(queue.push_drop_oldest(2), QueuePushOutcome::Enqueued);
        assert_eq!(
            queue.push_drop_oldest(3),
            QueuePushOutcome::DroppedOldest(1)
        );
        assert_eq!(queue.pop_front(), Some(2));
        assert_eq!(queue.pop_front(), Some(3));
    }

    #[test]
    fn control_mode_requires_input_permission() {
        let granted = PermissionSet::from_iter([Permission::ViewScreen]);
        assert!(!granted.is_superset(&SessionMode::Control.required_permissions()));
    }
}
