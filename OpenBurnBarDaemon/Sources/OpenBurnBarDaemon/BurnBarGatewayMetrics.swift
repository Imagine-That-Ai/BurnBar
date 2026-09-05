import Foundation
import OpenBurnBarEngine

/// Process-wide RPC counters surfaced on `GET /metrics`.
///
/// Intentionally lock-based (not actor-isolated) so hot RPC paths can increment
/// without awaiting. See `docs/runbooks/slos.md` for SLO probe names.
public enum BurnBarDaemonMetricsCounters {
    private static let lock = NSLock()
    // guarded by `lock`
    private nonisolated(unsafe) static var rpcRequestsTotal = 0
    // guarded by `lock`
    private nonisolated(unsafe) static var rpcErrorsTotal = 0
    // guarded by `lock`
    private nonisolated(unsafe) static var rpcLatencyMsSamples: [Int] = []
    private static let maxLatencySamples = 256

    /// Tri-state listener bind health: `nil` when the gateway has not attempted
    /// to bind, `true` once the socket is ready, `false` when the bind failed
    /// (e.g. the port is already in use). Surfaced on `GET /metrics` so a
    /// "gateway port bound but not serving" condition is visible, not silent.
    ///
    /// `nonisolated(unsafe)`: guarded by `lock`.
    private nonisolated(unsafe) static var gatewayListenerBound: Bool?
    // guarded by `lock`
    private nonisolated(unsafe) static var gatewayListenerErrorMessage: String?
    // guarded by `lock`
    private nonisolated(unsafe) static var memorySyncMetrics: BurnBarMemorySyncMetrics?

    /// Records that the gateway TCP listener reached the `.ready` state.
    public static func recordGatewayListenerReady() {
        lock.lock()
        gatewayListenerBound = true
        gatewayListenerErrorMessage = nil
        lock.unlock()
    }

    /// Records that the gateway TCP listener failed to bind, with a
    /// human-readable reason (e.g. address-in-use) for operator surfacing.
    public static func recordGatewayListenerFailure(_ message: String) {
        lock.lock()
        gatewayListenerBound = false
        gatewayListenerErrorMessage = message
        lock.unlock()
    }

    /// The most recent gateway listener bind failure message, if the listener
    /// is currently in a failed state. `nil` when unknown or healthy.
    public static func gatewayListenerError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return gatewayListenerBound == false ? gatewayListenerErrorMessage : nil
    }

    /// `1` when the listener is bound, `0` when it failed to bind. Omitted from
    /// the counters map (returns `nil`) until the gateway attempts to bind.
    public static func gatewayListenerBoundCounter() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let gatewayListenerBound else { return nil }
        return gatewayListenerBound ? 1 : 0
    }

    /// Records current memory sync observability metrics.
    public static func recordMemorySyncMetrics(_ metrics: BurnBarMemorySyncMetrics) {
        lock.lock()
        memorySyncMetrics = metrics
        lock.unlock()
    }

    /// Returns current memory sync observability metrics, if recorded.
    public static func currentMemorySyncMetrics() -> BurnBarMemorySyncMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return memorySyncMetrics
    }

    public static func recordRPCRequest() {
        lock.lock()
        rpcRequestsTotal &+= 1
        lock.unlock()
    }

    public static func recordRPCError() {
        lock.lock()
        rpcErrorsTotal &+= 1
        lock.unlock()
    }

    /// Records one RPC round-trip latency sample for p95 SLO probes.
    public static func recordRPCLatency(milliseconds: Int) {
        let clamped = max(0, milliseconds)
        lock.lock()
        rpcLatencyMsSamples.append(clamped)
        if rpcLatencyMsSamples.count > maxLatencySamples {
            rpcLatencyMsSamples.removeFirst(rpcLatencyMsSamples.count - maxLatencySamples)
        }
        lock.unlock()
    }

    public static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var counters = [
            "rpc_requests_total": rpcRequestsTotal,
            "rpc_errors_total": rpcErrorsTotal
        ]
        if let p95 = percentile(rpcLatencyMsSamples, p: 0.95) {
            counters["rpc_latency_ms_p95"] = p95
        }
        return counters
    }

    private static func percentile(_ values: [Int], p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Double(sorted.count - 1) * p
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = index - Double(lower)
        let value = Double(sorted[lower]) * (1 - fraction) + Double(sorted[upper]) * fraction
        return Int(value.rounded())
    }

    #if DEBUG
    /// Resets counters for unit tests only.
    public static func _resetForTesting() {
        lock.lock()
        rpcRequestsTotal = 0
        rpcErrorsTotal = 0
        rpcLatencyMsSamples = []
        gatewayListenerBound = nil
        gatewayListenerErrorMessage = nil
        memorySyncMetrics = nil
        lock.unlock()
    }
    #endif
}

// MARK: - Memory Sync Observability Metrics (E19 / P24)

/// Process-wide memory sync counters and watermark observability.
public struct BurnBarMemorySyncMetrics: Codable, Sendable, Equatable {
    public let lastPullTimestamp: String?
    public let appliedCount: Int
    public let rejectedCount: Int
    public let parkedCount: Int
    public let skippedCount: Int
    public let engineWatermarkAgeSeconds: TimeInterval?
    public let transportWatermarkAgeSeconds: TimeInterval?
    public let alertThresholdSeconds: TimeInterval
    public let isAlertTripped: Bool
    public let skippedFloorNote: String

    public init(
        lastPullTimestamp: String? = nil,
        appliedCount: Int = 0,
        rejectedCount: Int = 0,
        parkedCount: Int = 0,
        skippedCount: Int = 0,
        engineWatermarkAgeSeconds: TimeInterval? = nil,
        transportWatermarkAgeSeconds: TimeInterval? = nil,
        alertThresholdSeconds: TimeInterval = BurnBarMemoryDeviceSyncMarker.maxAge
    ) {
        self.lastPullTimestamp = lastPullTimestamp
        self.appliedCount = appliedCount
        self.rejectedCount = rejectedCount
        self.parkedCount = parkedCount
        self.skippedCount = skippedCount
        self.engineWatermarkAgeSeconds = engineWatermarkAgeSeconds
        self.transportWatermarkAgeSeconds = transportWatermarkAgeSeconds
        self.alertThresholdSeconds = alertThresholdSeconds
        self.isAlertTripped = (engineWatermarkAgeSeconds.map { $0 > alertThresholdSeconds } ?? false) ||
                              (transportWatermarkAgeSeconds.map { $0 > alertThresholdSeconds } ?? false)
        self.skippedFloorNote = "Pre-PR-1 chat memories in users/{uid}/memory_facts carry no engine projectID and are skipped on every pull; a permanent non-zero skipped is expected, not a fault."
    }
}

/// Loopback metrics snapshot for the HTTP gateway `GET /metrics` stub.
///
/// **Counter contract** (stable names for SLO probes — see `docs/runbooks/slos.md`):
/// - `gateway_enabled` — `1` when the gateway is configured on; `0` when disabled.
/// - `daemon_heartbeat_present` — `1` when the on-disk heartbeat file decodes; else `0`.
/// - `heartbeat_stale` — `1` when heartbeat age exceeds `BurnBarDaemonHeartbeat.defaultStaleThreshold` (20s).
///
/// Counters are intentionally minimal in Phase 5; expand as `metrics.jsonl` lands.
public struct BurnBarGatewayMetricsSnapshot: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let daemonVersion: String
    public let protocolVersion: Int
    public let uptimeSeconds: Int
    public let heartbeat: BurnBarDaemonHeartbeatSnapshot?
    public let heartbeatStale: Bool
    public let gatewayEnabled: Bool
    public let counters: [String: Int]
    /// Human-readable reason the gateway TCP listener is not bound (e.g. the
    /// port is already in use). `nil` when the listener is healthy or has not
    /// attempted to bind. Lets operators see "8317 down but socket up" instead
    /// of a silent failure.
    public let gatewayListenerError: String?
    /// Process-wide memory sync observability metrics, if recorded.
    public let memorySync: BurnBarMemorySyncMetrics?

    public init(
        generatedAt: Date = Date(),
        daemonVersion: String = BurnBarDaemonVersion.current,
        protocolVersion: Int = BurnBarProtocolVersion.current,
        uptimeSeconds: Int,
        heartbeat: BurnBarDaemonHeartbeatSnapshot?,
        heartbeatStale: Bool,
        gatewayEnabled: Bool,
        counters: [String: Int] = [:],
        gatewayListenerError: String? = nil,
        memorySync: BurnBarMemorySyncMetrics? = nil
    ) {
        self.generatedAt = generatedAt
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.uptimeSeconds = uptimeSeconds
        self.heartbeat = heartbeat
        self.heartbeatStale = heartbeatStale
        self.gatewayEnabled = gatewayEnabled
        self.counters = counters
        self.gatewayListenerError = gatewayListenerError
        self.memorySync = memorySync
    }

    public static let processStartDate = Date()

    public static func live(
        gatewayEnabled: Bool
    ) -> BurnBarGatewayMetricsSnapshot {
        let heartbeat = BurnBarDaemonHeartbeat.readSnapshot()
        let heartbeatStale = BurnBarDaemonHeartbeat.isStale(snapshot: heartbeat)
        let uptime = max(0, Int(Date().timeIntervalSince(processStartDate)))
        let syncMetrics = BurnBarDaemonMetricsCounters.currentMemorySyncMetrics()
        var counters = [
            "daemon_heartbeat_present": heartbeat == nil ? 0 : 1,
            "gateway_enabled": gatewayEnabled ? 1 : 0,
            "heartbeat_stale": heartbeatStale ? 1 : 0
        ].merging(BurnBarDaemonMetricsCounters.snapshot()) { current, _ in current }
        if let listenerBound = BurnBarDaemonMetricsCounters.gatewayListenerBoundCounter() {
            counters["gateway_listener_bound"] = listenerBound
        }
        if let sync = syncMetrics {
            counters["memory_sync_applied_total"] = sync.appliedCount
            counters["memory_sync_rejected_total"] = sync.rejectedCount
            counters["memory_sync_parked_total"] = sync.parkedCount
            counters["memory_sync_skipped_total"] = sync.skippedCount
            counters["memory_sync_alert_tripped"] = sync.isAlertTripped ? 1 : 0
        }
        return BurnBarGatewayMetricsSnapshot(
            uptimeSeconds: uptime,
            heartbeat: heartbeat,
            heartbeatStale: heartbeatStale,
            gatewayEnabled: gatewayEnabled,
            counters: counters,
            gatewayListenerError: BurnBarDaemonMetricsCounters.gatewayListenerError(),
            memorySync: syncMetrics
        )
    }
}
