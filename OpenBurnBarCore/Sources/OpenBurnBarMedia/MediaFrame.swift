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
    }

    public var kind: Kind
    public var flags: Flags
    public var gopID: UInt32
    public var frameIndex: UInt32
    public var presentationTimestampMillis: UInt64
    public var payload: Data

    public init(
        kind: Kind,
        flags: Flags = [],
        gopID: UInt32 = 0,
        frameIndex: UInt32 = 0,
        presentationTimestampMillis: UInt64 = 0,
        payload: Data = Data()
    ) {
        self.kind = kind
        self.flags = flags
        self.gopID = gopID
        self.frameIndex = frameIndex
        self.presentationTimestampMillis = presentationTimestampMillis
        self.payload = payload
    }
}

extension MediaFrame {
    /// Fixed header size in bytes. Pinned in `MediaPacketCodec` and exposed
    /// here so test code never has to rederive the wire layout.
    public static let headerByteCount = 18
}
