import Foundation
import OpenBurnBarCore
import OSLog

// MARK: - Telemetry Feature

/// Privacy-preserving feature identifiers. No PII, no conversation content, no API keys.
public enum TelemetryFeature: String, Sendable {
    case searchRetrieval
    case cloudSync
    case conversationSummary
    case daemonHealthCheck
    case settingsChange
    case providerQuotaRefresh
}

// MARK: - Telemetry Outcome

public enum TelemetryOutcome: String, Sendable {
    case success
    case failure
    case degraded
    case cancelled
}

/// A sink that mirrors each recorded feature event downstream (e.g. to the
/// consent-gated Amplitude wrapper). Registered once at app launch.
public typealias TelemetryForwardHandler = @Sendable (TelemetryFeature, TelemetryOutcome, Int?) -> Void

// MARK: - Telemetry Event

private struct TelemetryEvent: Sendable {
    let feature: TelemetryFeature
    let outcome: TelemetryOutcome
    let durationMs: Int?
    let timestamp: Date
}

// MARK: - Telemetry Service

/// Lightweight, privacy-preserving feature usage telemetry.
///
/// - No PII, conversation content, or API keys are ever recorded.
/// - Durations are bucketed to 100ms to reduce fingerprinting surface.
/// - Events are buffered in-memory and flushed to os_log.
///
/// Future: batch upload to a privacy-respecting telemetry endpoint.
/// Thread-safe telemetry service using NSLock for event-buffer protection.
/// May be called from any thread/actor context.
public final class TelemetryService: Sendable {
    public static let shared = TelemetryService()

    private let events = Locked<[TelemetryEvent]>([])
    private let maxBufferSize = 100
    private let logger = Logger(subsystem: "com.openburnbar.telemetry", category: "events")
    private let forwarder = Locked<TelemetryForwardHandler?>(nil)

    /// Register a downstream sink for recorded feature events. The app wires this
    /// at launch to fan telemetry out to the consent-gated Amplitude wrapper.
    /// Passing `nil` detaches the sink.
    public func setForwarder(_ handler: TelemetryForwardHandler?) {
        forwarder.withLock { $0 = handler }
    }

    public func record(
        feature: TelemetryFeature,
        outcome: TelemetryOutcome,
        durationMs: Int? = nil
    ) {
        let bucketedDuration = durationMs.map { ($0 / 100) * 100 }
        let event = TelemetryEvent(
            feature: feature,
            outcome: outcome,
            durationMs: bucketedDuration,
            timestamp: Date()
        )
        let shouldFlush = events.withLock { events -> Bool in
            events.append(event)
            return events.count >= maxBufferSize
        }
        // Fan out to the consent-gated Amplitude wrapper, if wired. The handler
        // itself drops everything unless analytics consent has been granted.
        if let handler = forwarder.withLock({ $0 }) {
            handler(feature, outcome, bucketedDuration)
        }
        if shouldFlush {
            flush()
        }
    }

    public func flush() {
        let pending = events.withLock { events -> [TelemetryEvent] in
            let pending = events
            events.removeAll()
            return pending
        }
        for event in pending {
            if let duration = event.durationMs {
                logger.info("feature=\(event.feature.rawValue) outcome=\(event.outcome.rawValue) duration_ms=\(duration)")
            } else {
                logger.info("feature=\(event.feature.rawValue) outcome=\(event.outcome.rawValue)")
            }
        }
    }
}
