import Foundation
import OpenBurnBarCore

/// Process-wide RPC counters surfaced on `GET /metrics`.
///
/// Intentionally lock-based (not actor-isolated) so hot RPC paths can increment
/// without awaiting. See `docs/runbooks/slos.md` for SLO probe names.
public enum BurnBarDaemonMetricsCounters {
    private static let lock = NSLock()
    private static var rpcRequestsTotal = 0
    private static var rpcErrorsTotal = 0

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

    public static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "rpc_requests_total": rpcRequestsTotal,
            "rpc_errors_total": rpcErrorsTotal,
        ]
    }

    #if DEBUG
    /// Resets counters for unit tests only.
    public static func _resetForTesting() {
        lock.lock()
        rpcRequestsTotal = 0
        rpcErrorsTotal = 0
        lock.unlock()
    }
    #endif
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

    public init(
        generatedAt: Date = Date(),
        daemonVersion: String = BurnBarDaemonVersion.current,
        protocolVersion: Int = BurnBarProtocolVersion.current,
        uptimeSeconds: Int,
        heartbeat: BurnBarDaemonHeartbeatSnapshot?,
        heartbeatStale: Bool,
        gatewayEnabled: Bool,
        counters: [String: Int] = [:]
    ) {
        self.generatedAt = generatedAt
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.uptimeSeconds = uptimeSeconds
        self.heartbeat = heartbeat
        self.heartbeatStale = heartbeatStale
        self.gatewayEnabled = gatewayEnabled
        self.counters = counters
    }

    public static let processStartDate = Date()

    public static func live(
        gatewayEnabled: Bool
    ) -> BurnBarGatewayMetricsSnapshot {
        let heartbeat = BurnBarDaemonHeartbeat.readSnapshot()
        let heartbeatStale = BurnBarDaemonHeartbeat.isStale(snapshot: heartbeat)
        let uptime = max(0, Int(Date().timeIntervalSince(processStartDate)))
        return BurnBarGatewayMetricsSnapshot(
            uptimeSeconds: uptime,
            heartbeat: heartbeat,
            heartbeatStale: heartbeatStale,
            gatewayEnabled: gatewayEnabled,
            counters: [
                "daemon_heartbeat_present": heartbeat == nil ? 0 : 1,
                "gateway_enabled": gatewayEnabled ? 1 : 0,
                "heartbeat_stale": heartbeatStale ? 1 : 0,
            ].merging(BurnBarDaemonMetricsCounters.snapshot()) { current, _ in current }
        )
    }
}
