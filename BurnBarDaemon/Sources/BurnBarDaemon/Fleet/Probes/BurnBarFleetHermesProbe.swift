import BurnBarCore
import Foundation

/// Hermes probe: `~/.hermes/gateway.pid` + `state/gateway.heartbeat` +
/// `gateway_state.json` + `processes.json`.
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §4):
/// - **Running:** gateway heartbeat fresh (< 120 s) AND (`active_agents > 0`
///   OR `processes.json` non-empty). Confidence `exactProcess`; the process
///   block carries the gateway pid.
/// - **Idle:** gateway alive (live pid + fresh heartbeat) with
///   `active_agents == 0` and empty `processes.json` (VAL-FLEET-005).
/// - **Stale heartbeat:** a live pid with `active_agents > 0` but a heartbeat
///   beyond the 120 s window is NON-running with a typed stale/unknown
///   confidence and a typed health reason — stale evidence never yields
///   `running` (VAL-FLEET-023).
/// - **Missing heartbeat:** the documented missing-signal state — non-running
///   with a typed health reason.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (`pid`, heartbeat `updated_at`, `active_agents`) → typed `unknown`/`stale`
///   row with a `degraded` health reason — never fabricated `running`.
/// - **Repo attribution:** `processes.json` entries when present; else nil.
public struct BurnBarFleetHermesProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Heartbeat freshness window (defaults to the pinned 120 s constant).
    public let heartbeatFreshnessSeconds: TimeInterval
    /// Per-probe timeout for signal-file reads (VAL-FLEET-019 seam).
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .hermes,
        rootPath: String,
        heartbeatFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.hermesHeartbeatFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.heartbeatFreshnessSeconds = heartbeatFreshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: rootPath) else {
            return BurnBarFleetProbeSupport.missingRootResult(agentID: agentID, rootPath: rootPath, now: now)
        }

        let gatewayPidPath = rootURL.appendingPathComponent("gateway.pid").path
        let heartbeatPath = rootURL.appendingPathComponent("state/gateway.heartbeat").path
        let gatewayStatePath = rootURL.appendingPathComponent("gateway_state.json").path
        let processesPath = rootURL.appendingPathComponent("processes.json").path

        let gatewayPid = Self.readGatewayPid(at: gatewayPidPath, timeoutSeconds: readTimeoutSeconds)
        let heartbeat = Self.readHeartbeat(at: heartbeatPath, timeoutSeconds: readTimeoutSeconds)
        let gatewayState = Self.readGatewayState(at: gatewayStatePath, timeoutSeconds: readTimeoutSeconds)
        let processes = Self.readProcesses(at: processesPath, timeoutSeconds: readTimeoutSeconds)

        var sources: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []

        if let gatewayPid {
            sources.append(
                BurnBarFleetSignalSource(
                    kind: "process-list",
                    path: gatewayPid.path,
                    detail: gatewayPid.malformedReason ?? Self.pidDetail(gatewayPid)
                )
            )
            if let reason = gatewayPid.malformedReason {
                healthReasons.append(reason)
            }
        }

        if let heartbeat {
            sources.append(
                BurnBarFleetSignalSource(
                    kind: "heartbeat-file",
                    path: heartbeat.path,
                    detail: heartbeat.malformedReason ?? Self.heartbeatDetail(heartbeat, now: now)
                )
            )
            if let reason = heartbeat.malformedReason {
                healthReasons.append(reason)
            }
        }

        if let gatewayState {
            sources.append(
                BurnBarFleetSignalSource(
                    kind: "heartbeat-file",
                    path: gatewayState.path,
                    detail: gatewayState.malformedReason ?? Self.stateDetail(gatewayState)
                )
            )
            if let reason = gatewayState.malformedReason {
                healthReasons.append(reason)
            }
        }

        if let processes {
            sources.append(
                BurnBarFleetSignalSource(
                    kind: "process-list",
                    path: processes.path,
                    detail: processes.malformedReason ?? "\(processes.entries.count) entry(ies)"
                )
            )
            if let reason = processes.malformedReason {
                healthReasons.append(reason)
            }
        }

        let healthState: BurnBarFleetProbeHealthState = healthReasons.isEmpty
            ? .ok
            : .degraded(reason: healthReasons.joined(separator: " "))

        let signals = Signals(
            gatewayPid: gatewayPid,
            heartbeat: heartbeat,
            gatewayState: gatewayState,
            processes: processes,
            sources: sources,
            healthState: healthState
        )
        return Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            heartbeatFreshnessSeconds: heartbeatFreshnessSeconds,
            signals: signals
        )
    }

    /// Classifies the row. Running requires a live gateway pid, a FRESH
    /// heartbeat, and active work (`active_agents > 0` or non-empty
    /// `processes.json`). Stale or missing heartbeat evidence never yields
    /// running (VAL-FLEET-023).
    private static func classify(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        heartbeatFreshnessSeconds: TimeInterval,
        signals: Signals
    ) -> BurnBarFleetProbeResult {
        let gatewayPid = signals.gatewayPid
        let heartbeat = signals.heartbeat
        let gatewayState = signals.gatewayState
        let processes = signals.processes
        let pid = gatewayPid?.pid
        let pidAlive = pid.map { BurnBarFleetProcessLiveness.isAlive(pid: $0) } ?? false
        let heartbeatFresh = heartbeat?.isFresh(now: now, freshnessSeconds: heartbeatFreshnessSeconds) ?? false
        let activeAgents = gatewayState?.activeAgents
        let hasActiveWork = (activeAgents ?? 0) > 0 || (processes?.entries.isEmpty == false)

        // Running: live pid + fresh heartbeat + active work.
        if pidAlive, heartbeatFresh, hasActiveWork, let pid {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .exactProcess,
                projectName: processes?.entries.first?.cwd,
                lastActivityAt: heartbeat?.updatedAt,
                process: BurnBarFleetProcessInfo(pid: pid),
                signals: signals.sources,
                healthState: signals.healthState
            )
        }

        // Idle: live pid + fresh heartbeat, zero active agents.
        if pidAlive, heartbeatFresh, let pid {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .idle,
                confidence: .exactProcess,
                lastActivityAt: heartbeat?.updatedAt,
                process: BurnBarFleetProcessInfo(pid: pid),
                signals: signals.sources,
                note: "Gateway alive with zero active agents; idle, not running.",
                healthState: signals.healthState
            )
        }

        // Stale heartbeat: live pid + active work but the heartbeat is beyond
        // the freshness window — never running from stale evidence.
        if pidAlive, let pid {
            let reason = "Gateway heartbeat is stale or missing; active work is not claimed."
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: heartbeat?.updatedAt,
                signals: signals.sources,
                note: reason,
                healthState: signals.healthState
            )
        }

        // Malformed gateway pid signal: typed unknown, never fabricated
        // running (checked before the dead-pid branch so a malformed primary
        // signal never masquerades as a merely-dead gateway).
        if let gatewayPid, gatewayPid.malformedReason != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                signals: signals.sources,
                note: "Gateway pid signal malformed; status unknown.",
                healthState: signals.healthState
            )
        }

        // Gateway pid dead or absent: never running.
        if gatewayPid != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: heartbeat?.updatedAt,
                signals: signals.sources,
                note: "Gateway pid is not alive; confidence downgraded.",
                healthState: signals.healthState
            )
        }

        // No gateway pid signal at all.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .unknown,
            confidence: .unsupported,
            signals: signals.sources,
            note: "Gateway pid signal absent.",
            healthState: signals.healthState
        )
    }

    // MARK: - Parsing

    /// Bundles the parsed signal files plus the derived evidence trail and
    /// health state for one probe run.
    private struct Signals {
        let gatewayPid: GatewayPidSignal?
        let heartbeat: HeartbeatSignal?
        let gatewayState: GatewayStateSignal?
        let processes: ProcessesSignal?
        let sources: [BurnBarFleetSignalSource]
        let healthState: BurnBarFleetProbeHealthState
    }

    private struct GatewayPidSignal {
        let path: String
        let pid: Int?
        let malformedReason: String?
    }

    private struct HeartbeatSignal {
        let path: String
        let pid: Int?
        let updatedAt: Date?
        let malformedReason: String?

        func isFresh(now: Date, freshnessSeconds: TimeInterval) -> Bool {
            guard let updatedAt else { return false }
            return now.timeIntervalSince(updatedAt) <= freshnessSeconds
        }
    }

    private struct GatewayStateSignal {
        let path: String
        let activeAgents: Int?
        let malformedReason: String?
    }

    private struct ProcessesSignal {
        let path: String
        let entries: [ProcessEntry]
        let malformedReason: String?
    }

    private struct ProcessEntry {
        let cwd: String?
    }

    private static func readGatewayPid(at path: String, timeoutSeconds: TimeInterval) -> GatewayPidSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return GatewayPidSignal(
                    path: path,
                    pid: nil,
                    malformedReason: "gateway.pid is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return GatewayPidSignal(
                path: path,
                pid: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let pid = BurnBarFleetProbeJSON.integerValue(object["pid"]) else {
            return GatewayPidSignal(
                path: path,
                pid: nil,
                malformedReason: "gateway.pid is missing a numeric pid."
            )
        }
        return GatewayPidSignal(path: path, pid: pid, malformedReason: nil)
    }

    private static func readHeartbeat(at path: String, timeoutSeconds: TimeInterval) -> HeartbeatSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return HeartbeatSignal(
                    path: path,
                    pid: nil,
                    updatedAt: nil,
                    malformedReason: "gateway.heartbeat is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return HeartbeatSignal(
                path: path,
                pid: nil,
                updatedAt: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let pid = BurnBarFleetProbeJSON.integerValue(object["pid"]) else {
            return HeartbeatSignal(
                path: path,
                pid: nil,
                updatedAt: nil,
                malformedReason: "gateway.heartbeat is missing a numeric pid."
            )
        }

        let updatedAt: Date?
        if let raw = object["updated_at"] as? String {
            updatedAt = ISO8601DateFormatter().date(from: raw)
        } else {
            updatedAt = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(object["updated_at"])
        }
        guard updatedAt != nil else {
            return HeartbeatSignal(
                path: path,
                pid: pid,
                updatedAt: nil,
                malformedReason: "gateway.heartbeat is missing a parseable updated_at."
            )
        }

        return HeartbeatSignal(path: path, pid: pid, updatedAt: updatedAt, malformedReason: nil)
    }

    private static func readGatewayState(at path: String, timeoutSeconds: TimeInterval) -> GatewayStateSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return GatewayStateSignal(
                    path: path,
                    activeAgents: nil,
                    malformedReason: "gateway_state.json is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return GatewayStateSignal(
                path: path,
                activeAgents: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let activeAgents = BurnBarFleetProbeJSON.integerValue(object["active_agents"]) else {
            return GatewayStateSignal(
                path: path,
                activeAgents: nil,
                malformedReason: "gateway_state.json is missing a numeric active_agents."
            )
        }
        return GatewayStateSignal(path: path, activeAgents: activeAgents, malformedReason: nil)
    }

    private static func readProcesses(at path: String, timeoutSeconds: TimeInterval) -> ProcessesSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let array = raw as? [Any] else {
                return ProcessesSignal(
                    path: path,
                    entries: [],
                    malformedReason: "processes.json is not a JSON array."
                )
            }
            object = array
        } catch {
            return ProcessesSignal(
                path: path,
                entries: [],
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        var entries: [ProcessEntry] = []
        for item in object {
            if let dictionary = item as? [String: Any] {
                entries.append(ProcessEntry(cwd: BurnBarFleetProbeJSON.stringValue(dictionary["cwd"])))
            }
        }
        return ProcessesSignal(path: path, entries: entries, malformedReason: nil)
    }

    private static func pidDetail(_ signal: GatewayPidSignal) -> String? {
        guard let pid = signal.pid else { return nil }
        return "pid \(pid)"
    }

    private static func heartbeatDetail(_ signal: HeartbeatSignal, now: Date) -> String? {
        guard let pid = signal.pid else { return nil }
        if let updatedAt = signal.updatedAt {
            let age = Int(now.timeIntervalSince(updatedAt))
            return "pid \(pid), \(age)s ago"
        }
        return "pid \(pid)"
    }

    private static func stateDetail(_ signal: GatewayStateSignal) -> String? {
        guard let activeAgents = signal.activeAgents else { return nil }
        return "active_agents \(activeAgents)"
    }
}
