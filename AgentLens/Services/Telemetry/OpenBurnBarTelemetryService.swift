import Foundation
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
public final class TelemetryService: @unchecked Sendable {
    public static let shared = TelemetryService()

    private var events: [TelemetryEvent] = []
    private let maxBufferSize = 100
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.openburnbar.telemetry", category: "events")

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
        lock.lock()
        events.append(event)
        let shouldFlush = events.count >= maxBufferSize
        lock.unlock()
        if shouldFlush {
            flush()
        }
    }

    public func flush() {
        lock.lock()
        let pending = events
        events.removeAll()
        lock.unlock()
        for event in pending {
            if let duration = event.durationMs {
                logger.info("feature=\(event.feature.rawValue) outcome=\(event.outcome.rawValue) duration_ms=\(duration)")
            } else {
                logger.info("feature=\(event.feature.rawValue) outcome=\(event.outcome.rawValue)")
            }
        }
    }
}
