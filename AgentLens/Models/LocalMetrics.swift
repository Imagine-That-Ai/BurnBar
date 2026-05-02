import Foundation

// MARK: - Local Metrics Snapshot

/// A point-in-time aggregate of local operational health.
/// Computed from `retrieval_health` records and lightweight in-memory counters.
struct LocalMetricsSnapshot: Sendable, Equatable {
    let windowStart: Date
    let windowEnd: Date

    // Search latencies (milliseconds)
    let searchP50Ms: Double?
    let searchP95Ms: Double?
    let searchP99Ms: Double?
    let lexicalP50Ms: Double?
    let semanticP50Ms: Double?

    // Success / fallback rates (0.0–1.0)
    let rerankSuccessRate: Double?
    let semanticFallbackRate: Double?

    // Parser / sync throughput
    let parserEventsPerMinute: Double?
    let syncSuccessRate: Double?

    // Projection health
    let projectionJobsPerMinute: Double?
    let projectionFailureRate: Double?

    var isEmpty: Bool {
        searchP50Ms == nil
            && lexicalP50Ms == nil
            && rerankSuccessRate == nil
            && parserEventsPerMinute == nil
    }
}

// MARK: - Local Metrics Subsystem

enum LocalMetricsSubsystem: String, Sendable {
    case search
    case parser
    case sync
    case projection
}

// MARK: - Lightweight Counter

/// A thread-safe, lossy counter for high-frequency events.
/// Uses an atomic via `OSAllocatedUnfairLock` on macOS 15+, falls back to `NSLock`.
actor LocalMetricsCounter {
    private var counts: [String: Int] = [:]
    private var lastReset: Date = Date()

    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }

    func add(_ key: String, delta: Int) {
        counts[key, default: 0] += delta
    }

    func snapshot(since: Date) -> [String: Int] {
        guard since < lastReset else { return counts }
        // Counters were reset after the requested window; return current partial count.
        return counts
    }

    func reset() {
        counts.removeAll()
        lastReset = Date()
    }
}
