import Foundation

/// Structured analytics events emitted at Mercury media session
/// boundaries. Pure value types so the SwiftPM `OpenBurnBarMedia`
/// target stays free of Firebase deps; the platform-specific Mac + iOS
/// adapters translate these into `Firebase.Analytics.logEvent(...)`
/// calls via a thin `MediaAnalyticsSink` protocol.
///
/// Privacy: every parameter is a bucketed enum or count. Filenames,
/// hashes, peer NodeIds, and frame contents never appear in the event
/// dictionary.
public struct MediaAnalyticsEvent: Sendable, Equatable {
    public enum Name: String, Sendable, Equatable {
        case sessionStarted = "media_session_started"
        case sessionEnded = "media_session_ended"
        case transferCompleted = "media_transfer_completed"
        case transferFailed = "media_transfer_failed"
        case quotaDenied = "media_quota_denied"
        case budgetLevelChanged = "media_budget_level_changed"
        case controlStreamConnected = "media_control_stream_connected"
        case controlStreamLost = "media_control_stream_lost"
    }

    public let name: Name
    public let parameters: [String: AnalyticsValue]

    public init(name: Name, parameters: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.parameters = parameters
    }

    public enum AnalyticsValue: Sendable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        public var anyValue: Any {
            switch self {
            case .string(let v): return v
            case .int(let v): return v
            case .double(let v): return v
            case .bool(let v): return v
            }
        }
    }
}

/// Sink adapter implemented per platform. Mac uses Firebase Analytics
/// via `Analytics.logEvent(_:parameters:)`; iOS uses the same API.
/// Tests inject a recording sink to assert on emitted events without
/// actually firing analytics.
public protocol MediaAnalyticsSink: Sendable {
    func record(_ event: MediaAnalyticsEvent)
}

/// No-op sink used when analytics aren't configured (CI, headless dev,
/// unit tests). Keeps callers from littering nil-checks.
public struct NoOpMediaAnalyticsSink: MediaAnalyticsSink {
    public init() {}
    public func record(_ event: MediaAnalyticsEvent) {}
}

public extension MediaAnalyticsEvent {
    static func sessionStarted(
        feature: MediaStreamClass.Feature,
        streamClass: MediaStreamClass
    ) -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(
            name: .sessionStarted,
            parameters: [
                "feature": .string(feature.rawValue),
                "streamClass": .string(streamClass.rawValue),
            ]
        )
    }

    static func sessionEnded(
        feature: MediaStreamClass.Feature,
        durationSeconds: TimeInterval,
        endReason: MediaSessionMetadata.EndReason,
        freezeCount: Int,
        p95RoundTripMillis: Int?,
        p95BitsPerSecond: Int?
    ) -> MediaAnalyticsEvent {
        var parameters: [String: AnalyticsValue] = [
            "feature": .string(feature.rawValue),
            "endReason": .string(endReason.rawValue),
            "durationBucket": .string(MediaTelemetryBucket.sessionDuration(durationSeconds)),
            "freezeCountBucket": .string(MediaTelemetryBucket.freezeCount(freezeCount)),
        ]
        if let rtt = p95RoundTripMillis {
            parameters["p95RoundTripBucket"] = .string(MediaTelemetryBucket.roundTrip(rtt))
        }
        if let bps = p95BitsPerSecond {
            parameters["p95BitsPerSecondBucket"] = .string(bitrateBucket(bps))
        }
        return MediaAnalyticsEvent(name: .sessionEnded, parameters: parameters)
    }

    static func transferCompleted(
        sizeBytes: Int64,
        durationSeconds: TimeInterval,
        didResume: Bool
    ) -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(
            name: .transferCompleted,
            parameters: [
                "sizeBucket": .string(MediaTelemetryBucket.transferSize(sizeBytes)),
                "durationBucket": .string(MediaTelemetryBucket.sessionDuration(durationSeconds)),
                "didResume": .bool(didResume),
            ]
        )
    }

    static func transferFailed(
        sizeBytes: Int64,
        failureCode: String
    ) -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(
            name: .transferFailed,
            parameters: [
                "sizeBucket": .string(MediaTelemetryBucket.transferSize(sizeBytes)),
                "failureCode": .string(failureCode),
            ]
        )
    }

    static func quotaDenied(
        feature: MediaStreamClass.Feature,
        reason: MediaCapabilityDenialReason
    ) -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(
            name: .quotaDenied,
            parameters: [
                "feature": .string(feature.rawValue),
                "quotaReason": .string(reason.rawValue),
            ]
        )
    }

    static func budgetLevelChanged(
        from: MediaBudgetStatus.Level,
        to: MediaBudgetStatus.Level,
        projectedMonthEndUSD: Double
    ) -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(
            name: .budgetLevelChanged,
            parameters: [
                "fromLevel": .string(from.rawValue),
                "toLevel": .string(to.rawValue),
                "projectedMonthEndUSDBucket": .string(budgetBucket(projectedMonthEndUSD)),
            ]
        )
    }

    static func controlStreamConnected() -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(name: .controlStreamConnected)
    }

    static func controlStreamLost(reason: String) -> MediaAnalyticsEvent {
        MediaAnalyticsEvent(
            name: .controlStreamLost,
            parameters: ["reason": .string(reason)]
        )
    }

    static func bitrateBucket(_ bps: Int) -> String {
        switch bps {
        case ..<300_000: return "lt_300kbps"
        case ..<600_000: return "300_600kbps"
        case ..<1_000_000: return "600kbps_1mbps"
        case ..<2_000_000: return "1_2mbps"
        case ..<4_000_000: return "2_4mbps"
        case ..<8_000_000: return "4_8mbps"
        default: return "gte_8mbps"
        }
    }

    static func budgetBucket(_ usd: Double) -> String {
        switch usd {
        case ..<300: return "lt_300"
        case ..<600: return "300_600"
        case ..<1_000: return "600_1000"
        case ..<1_500: return "1000_1500"
        default: return "gte_1500"
        }
    }
}
