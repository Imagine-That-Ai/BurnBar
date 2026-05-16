import Foundation

/// Canonical identifier for a media stream class on the iroh transport.
///
/// Stream classes are negotiated **in band** via the first frame on each
/// new bi-stream rather than through a separate ALPN. The full table lives
/// in `docs/HERMES_MEDIA_TRANSPORT.md`. Carried as a string newtype rather
/// than a closed enum so receivers route an unknown class to a no-op
/// handler instead of failing to decode — older peers that have not yet
/// shipped support for a newer phase's class never crash on a frame they
/// don't understand.
public struct MediaStreamClass: RawRepresentable, Hashable, Sendable, Codable, Equatable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension MediaStreamClass {
    // Phase 1 — file transfer.

    /// Sender → receiver advertisement frame on the existing Hermes chat
    /// control stream. Carries `MediaAttachmentManifest` + base32 ticket.
    public static let blobAdvertise = MediaStreamClass("media.blob.advertise")

    /// Dedicated bi-stream the receiver dials back to the sender to fetch
    /// the actual blob bytes via iroh-blobs.
    public static let blobFetch = MediaStreamClass("media.blob.fetch")

    /// Logical class name for "any blob-related traffic" — used for
    /// telemetry bucketing and capability gates.
    public static let blob = MediaStreamClass("media.blob")

    // Phase 3 — screen share (Mac → iOS).

    public static let screenVideo = MediaStreamClass("media.screen.video")

    // Phase 4 — bidirectional audio (datagrams, but the class id labels
    // datagram batches in audit telemetry).

    public static let audioOut = MediaStreamClass("media.audio.out")
    public static let audioIn = MediaStreamClass("media.audio.in")

    // Phase 5 — bidirectional video.

    public static let videoOut = MediaStreamClass("media.video.out")
    public static let videoIn = MediaStreamClass("media.video.in")

    // Phase 3+ — RTCP-style sender reports, BWE feedback, mute, terminate.

    public static let control = MediaStreamClass("media.control")

    /// Static negotiation frame sent first on any new media-class
    /// bi-stream after `request.start`-style handshake. Always carried as
    /// a JSON envelope alongside `streamClass`.
    public static let classify = MediaStreamClass("media.classify")
}

extension MediaStreamClass {
    /// Top-level capability bucket the receiver should consult. Maps each
    /// class onto one of the three Mercury features so quota gates can
    /// charge the right counter without knowing about every wire-class.
    public enum Feature: String, Sendable, Codable, Equatable {
        case fileTransfer
        case screenShare
        case videoCall
    }

    public var feature: Feature? {
        switch rawValue {
        case Self.blobAdvertise.rawValue,
             Self.blobFetch.rawValue,
             Self.blob.rawValue:
            return .fileTransfer
        case Self.screenVideo.rawValue:
            return .screenShare
        case Self.videoOut.rawValue,
             Self.videoIn.rawValue,
             Self.audioOut.rawValue,
             Self.audioIn.rawValue:
            return .videoCall
        case Self.control.rawValue,
             Self.classify.rawValue:
            return nil
        default:
            return nil
        }
    }

    /// Whether this class is rolled out as of the given phase number.
    /// Receivers can use this to refuse a too-new stream from a pre-rollout
    /// peer instead of wasting compute on an unsupported pipeline.
    public func isAvailable(asOfPhase phase: Int) -> Bool {
        switch rawValue {
        case Self.blobAdvertise.rawValue,
             Self.blobFetch.rawValue,
             Self.blob.rawValue:
            return phase >= 1
        case Self.screenVideo.rawValue,
             Self.control.rawValue,
             Self.classify.rawValue:
            return phase >= 3
        case Self.audioOut.rawValue,
             Self.audioIn.rawValue:
            return phase >= 4
        case Self.videoOut.rawValue,
             Self.videoIn.rawValue:
            return phase >= 5
        default:
            return false
        }
    }
}
