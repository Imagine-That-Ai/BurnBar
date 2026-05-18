import Foundation

/// Session-level metadata recorded alongside every Mercury media transfer
/// or call. Pure plaintext — no payload bytes ever flow through this
/// envelope. Used by the audit logger (`iroh_audit_events`) and by the
/// daily rollup Cloud Function to bucket telemetry without ingesting
/// payload content.
public struct MediaSessionMetadata: Sendable, Codable, Equatable {
    public enum EndReason: String, Sendable, Codable, Equatable {
        case completedSuccess
        case completedUserCancel
        case completedPeerCancel
        case timeout
        case error
        case entitlementRevoked
        case budgetSoftCap
        case budgetHardCap
        case thermalCritical
    }

    public var sessionID: String
    public var feature: MediaStreamClass.Feature
    public var streamClass: MediaStreamClass
    public var startedAt: Date
    public var endedAt: Date?
    public var endReason: EndReason?
    public var peerDeviceID: String?
    public var byteCountInbound: Int64
    public var byteCountOutbound: Int64
    public var freezeCount: Int
    public var p95RoundTripMillis: Int?
    public var p95BitsPerSecond: Int?

    public init(
        sessionID: String,
        feature: MediaStreamClass.Feature,
        streamClass: MediaStreamClass,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        endReason: EndReason? = nil,
        peerDeviceID: String? = nil,
        byteCountInbound: Int64 = 0,
        byteCountOutbound: Int64 = 0,
        freezeCount: Int = 0,
        p95RoundTripMillis: Int? = nil,
        p95BitsPerSecond: Int? = nil
    ) {
        self.sessionID = sessionID
        self.feature = feature
        self.streamClass = streamClass
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.peerDeviceID = peerDeviceID
        self.byteCountInbound = byteCountInbound
        self.byteCountOutbound = byteCountOutbound
        self.freezeCount = freezeCount
        self.p95RoundTripMillis = p95RoundTripMillis
        self.p95BitsPerSecond = p95BitsPerSecond
    }
}

/// Bucket helper used by analytics events so payload counts never ride the
/// wire alongside their bucket name. Mirrors the `durationBucket` and
/// `sizeBucket` enums in the plan's § H.1 telemetry table.
public enum MediaTelemetryBucket {
    public static func sessionDuration(_ duration: TimeInterval) -> String {
        switch duration {
        case ..<30: return "lt_30s"
        case ..<120: return "30s_2m"
        case ..<600: return "2m_10m"
        case ..<1800: return "10m_30m"
        case ..<3600: return "30m_60m"
        default: return "gte_60m"
        }
    }

    public static func transferSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000.0
        switch mb {
        case ..<1: return "lt_1mb"
        case ..<10: return "1_10mb"
        case ..<100: return "10_100mb"
        case ..<1_000: return "100mb_1gb"
        default: return "gte_1gb"
        }
    }

    public static func roundTrip(_ millis: Int) -> String {
        switch millis {
        case ..<50: return "lt_50ms"
        case ..<150: return "50_150ms"
        case ..<400: return "150_400ms"
        default: return "gte_400ms"
        }
    }

    public static func freezeCount(_ count: Int) -> String {
        switch count {
        case 0: return "0"
        case 1...3: return "1_3"
        case 4...10: return "4_10"
        default: return "gt_10"
        }
    }
}
