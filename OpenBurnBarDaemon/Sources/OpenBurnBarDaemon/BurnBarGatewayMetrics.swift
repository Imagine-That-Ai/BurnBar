import Foundation
import OpenBurnBarCore

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
