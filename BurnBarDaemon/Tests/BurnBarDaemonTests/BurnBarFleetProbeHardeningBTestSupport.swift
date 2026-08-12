@testable import BurnBarDaemon
import Foundation

// MARK: - Probe-hardening-repair-b fixture helpers
//
// Fixture builders for `BurnBarFleetProbeHardeningBTests`, kept in a
// dedicated file so the test class stays under the lint type-body budget
// (precedent: BurnBarFleetLifecycleFixtures.swift).

/// The real process start time of a live fixture pid (epoch-seconds), used
/// so the pid-reuse guard passes for live fixture pids.
func hardeningBRealStartTime(_ pid: Int32) -> TimeInterval {
    BurnBarFleetProcessLiveness.processStartTime(pid: Int(pid)) ?? Date().timeIntervalSince1970
}

/// Writes a grok-bot daemon signal with the given pid/startedAt/inflight.
func hardeningBWriteGrokBotDaemon(
    root: URL,
    pid: Int,
    startedAtMilliseconds: Int,
    inflightCount: Int
) throws {
    try writeJSONFixture(
        [
            "pid": pid,
            "startedAt": startedAtMilliseconds,
            "inflightCount": inflightCount
        ],
        to: root.appendingPathComponent("local-exec-daemon.json").path
    )
}

/// Writes a grok-bot supervisor signal with the given pid/at.
func hardeningBWriteGrokBotSupervisor(root: URL, pid: Int, atMilliseconds: Int) throws {
    try writeJSONFixture(
        ["pid": pid, "at": atMilliseconds],
        to: root.appendingPathComponent("local-exec-supervisor.json").path
    )
}

/// Writes a hermes gateway.pid signal.
func hardeningBWriteHermesGatewayPid(root: URL, pid: Int, startTime: TimeInterval) throws {
    try writeJSONFixture(
        ["pid": pid, "kind": "hermes-gateway", "start_time": Int(startTime)],
        to: root.appendingPathComponent("gateway.pid").path
    )
}

/// Writes a hermes state/gateway.heartbeat signal.
func hardeningBWriteHermesHeartbeat(
    root: URL,
    pid: Int,
    updatedAt: Date,
    startTime: TimeInterval
) throws {
    try writeJSONFixture(
        [
            "pid": pid,
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
            "monotonic": 0,
            "start_time": startTime
        ],
        to: root.appendingPathComponent("state/gateway.heartbeat").path
    )
}

/// Writes a hermes gateway_state.json signal.
func hardeningBWriteHermesGatewayState(root: URL, activeAgents: Int) throws {
    try writeJSONFixture(
        ["pid": 1, "gateway_state": "running", "active_agents": activeAgents],
        to: root.appendingPathComponent("gateway_state.json").path
    )
}

/// Writes a hermes processes.json signal.
func hardeningBWriteHermesProcesses(root: URL) throws {
    try writeJSONFixture([], to: root.appendingPathComponent("processes.json").path)
}

/// Writes a cursor agent-cli-state.json signal with arbitrary worker-id
/// values (Any so malformed values like NSNull can be planted).
func hardeningBWriteCursorState(root: URL, workerIDs: [String: Any]) throws {
    try writeJSONFixture(
        ["workerIdsByDisplayName": workerIDs],
        to: root.appendingPathComponent("agent-cli-state.json").path
    )
}

/// Writes a cursor ai-tracking/ directory with the given mtime.
func hardeningBWriteCursorTracking(root: URL, mtime: Date) throws {
    let trackingPath = root.appendingPathComponent("ai-tracking", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: trackingPath, withIntermediateDirectories: true)
    try setFileMtime(mtime, at: trackingPath)
}
