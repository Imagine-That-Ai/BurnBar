import Foundation

/// Binary media frame envelope used by the per-GOP video / per-packet audio
/// stream classes (Phases 3, 4, 5). Layout, fixed at 16 bytes:
///
/// ```
/// |  0 .. 0  | frame type    (u8)
/// |  1 .. 1  | flags         (u8)         bit 0: keyframe; bit 1: end-of-GOP
/// |  2 .. 5  | gop id        (u32 BE)
/// |  6 .. 9  | frame index   (u32 BE)
/// | 10 .. 17 | presentation timestamp ms  (u64 BE)
/// | 18 .. ...| encoded payload (NAL units, Opus frame, etc.)
/// ```
///
/// Phase 1 does not exercise this envelope — file blobs ride iroh-blobs
/// directly without a Mercury frame header. The codec lives in Phase 1
/// because Phase 3+ pipelines pre-allocate it during their startup path,
/// and shipping the substrate here lets the test target lock down the
/// header layout before the first decoder is written.
public struct MediaFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Codable, Equatable {
        case videoNAL = 0x01
        case audioOpus = 0x02
        case bweFeedback = 0x10
        case sessionControl = 0x20
    }

    public struct Flags: OptionSet, Sendable, Codable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// First frame of a new GOP — the receiver can re-anchor its
        /// decoder here after dropping a stalled stream.
        public static let keyframe = Flags(rawValue: 1 << 0)

        /// Last frame of the current GOP. Receivers use this to know when
        /// they can safely abandon a stalled in-flight GOP and request a
        /// fresh keyframe without losing in-progress decode state.
        public static let endOfGroup = Flags(rawValue: 1 << 1)

        /// Marks an audio frame produced while the local mic is muted —
        /// kept on the wire for sample-clock alignment but the receiver
        /// renders silence.
        public static let muted = Flags(rawValue: 1 << 2)

        /// Phase 8 — Computer Use Agent Watch: this frame carries 4 extra
        /// bytes (i16 cursorX + i16 cursorY, big-endian, in display
        /// pixels) appended immediately after the fixed header and before
        /// the payload. Receivers that do not set this bit ignore the 4
        /// trailing bytes — codec stays backward-compatible.
        ///
        /// The plan's draft labels this bit `0x04`, but `0x04` is already
        /// taken by `.muted`. The wire bit is `0x08`. This is captured in
        /// `docs/HERMES_COMPUTER_USE.md` and the Phase 8 decision-log
        /// entry in `DESIGN.md`.
        public static let hasCursorMetadata = Flags(rawValue: 1 << 3)
    }

    public var kind: Kind
    public var flags: Flags
    public var gopID: UInt32
    public var frameIndex: UInt32
    public var presentationTimestampMillis: UInt64
    /// Cursor coordinates in display pixels at the moment the frame was
    /// captured. Encoded inline on the wire as two big-endian i16 values
    /// immediately after the 18-byte header when `flags.hasCursorMetadata`
    /// is set. `nil` everywhere else.
    public var cursor: CursorMetadata?
    public var payload: Data

    public init(
        kind: Kind,
        flags: Flags = [],
        gopID: UInt32 = 0,
        frameIndex: UInt32 = 0,
        presentationTimestampMillis: UInt64 = 0,
        cursor: CursorMetadata? = nil,
        payload: Data = Data()
    ) {
        self.kind = kind
        self.flags = flags
        self.gopID = gopID
        self.frameIndex = frameIndex
        self.presentationTimestampMillis = presentationTimestampMillis
        self.cursor = cursor
        self.payload = payload
    }
}

extension MediaFrame {
    /// Cursor coordinates in display pixels. Carried on
    /// `control.surface.frame` frames so the phone overlay can render the
    /// agent's cursor without an out-of-band sync channel (Decision 4).
    public struct CursorMetadata: Sendable, Codable, Equatable {
        public var x: Int16
        public var y: Int16

        public init(x: Int16, y: Int16) {
            self.x = x
            self.y = y
        }
    }
}

extension MediaFrame {
    /// Fixed header size in bytes. Pinned in `MediaPacketCodec` and exposed
    /// here so test code never has to rederive the wire layout.
    public static let headerByteCount = 18

    /// Number of trailing bytes appended after the fixed header when
    /// `flags.hasCursorMetadata` is set. Two big-endian i16 values.
    public static let cursorMetadataByteCount = 4
}
