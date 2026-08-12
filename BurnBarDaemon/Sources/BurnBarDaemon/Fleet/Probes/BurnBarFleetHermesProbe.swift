import BurnBarCore
import Foundation

/// Hermes probe: `~/.hermes/gateway.pid` + `state/gateway.heartbeat` +
/// `gateway_state.json` + `processes.json`.
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §4):
/// - **Running:** gateway pid live (pid-reuse guarded) AND heartbeat fresh
///   (< 120 s) AND (`active_agents > 0` OR `processes.json` non-empty).
///   Confidence `exactProcess`; the process block carries the gateway pid.
/// - **Pid-reuse guard:** the gateway pid is verified with the process-start
///   identity check before `kill -0`. The heartbeat's recorded `start_time`
///   is the authoritative identity (the real heartbeat writes accurate
///   epoch-seconds while `gateway.pid`'s `start_time` is a known-buggy
///   epoch-milliseconds value); when the heartbeat carries no usable
///   `start_time`, `gateway.pid`'s own record is used. A reused pid whose
///   current process started after the recorded start is treated as dead and
///   can never resurrect `running`/`exactProcess` (VAL-HARD-007).
/// - **Heartbeat identity:** the heartbeat's pid must match the gateway pid
///   (or be absent). A fresh heartbeat written by a DIFFERENT live process
///   is not evidence for the gateway — it degrades typed, never running.
/// - **Idle:** gateway alive (live pid + fresh heartbeat) with
///   `active_agents == 0` and empty `processes.json` (VAL-FLEET-005).
/// - **Stale heartbeat:** a live pid with `active_agents > 0` but a heartbeat
///   beyond the 120 s window is NON-running with a typed stale/unknown
///   confidence AND a typed `degraded` probeHealth reason — stale evidence
///   never yields `running` and never looks healthy (VAL-FLEET-023).
/// - **Missing heartbeat:** the documented missing-signal state — non-running
///   with a typed `degraded` probeHealth reason.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (`pid`, heartbeat `updated_at`, `active_agents`) → typed `unknown`/`stale`
///   row with a `degraded` health reason — never fabricated `running`. A
///   missing `active_agents` key is malformed-shape: it is NEVER defaulted
///   to zero (which would fabricate an idle/exactProcess row).
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

    /// Classifies the row. Running requires a live gateway pid (pid-reuse
    /// guarded), a FRESH heartbeat whose pid matches the gateway, and active
    /// work (`active_agents > 0` or non-empty `processes.json`). Stale or
    /// missing heartbeat evidence never yields running (VAL-FLEET-023).
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
        let pidAlive = pid.map { Self.isLiveGatewayPid($0, gatewayPid: gatewayPid, heartbeat: heartbeat) } ?? false
        let heartbeatFresh = heartbeat?.isFresh(now: now, freshnessSeconds: heartbeatFreshnessSeconds) ?? false
        let heartbeatMatchesGateway = Self.heartbeatMatchesGateway(heartbeat: heartbeat, gatewayPid: pid)
        let activeAgents = gatewayState?.activeAgents
        let hasActiveWork = (activeAgents ?? 0) > 0 || (processes?.entries.isEmpty == false)

        // Malformed gateway_state.json (missing/mistyped active_agents):
        // the active-work count is unknown, so the row is typed unknown —
        // NEVER defaulted to zero, which would fabricate an idle/exactProcess
        // row from a malformed primary signal (VAL-FLEET-024).
        if let gatewayState, gatewayState.malformedReason != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                lastActivityAt: heartbeat?.updatedAt,
                signals: signals.sources,
                note: "Gateway state signal malformed; status unknown.",
                healthState: signals.healthState
            )
        }

        // Running: live pid + fresh heartbeat + active work.
        if pidAlive, heartbeatFresh, heartbeatMatchesGateway, hasActiveWork, let pid {
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
        if pidAlive, heartbeatFresh, heartbeatMatchesGateway, let pid {
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

        // Stale or missing heartbeat with a live pid: never running from
        // stale evidence, and the missing/stale heartbeat MUST surface as a
        // typed degraded probeHealth reason — an active-work row with healthy
        // probeHealth while the heartbeat is stale/absent silently hides the
        // missing corroboration (VAL-FLEET-023). A heartbeat written by a
        // DIFFERENT live process is not evidence for the gateway either and
        // degrades the same way.
        if pidAlive {
            return Self.staleHeartbeatResult(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                heartbeatMatchesGateway: heartbeatMatchesGateway,
                signals: signals
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

    /// The gateway pid is live only when the process-start identity check
    /// passes. The heartbeat's recorded `start_time` is the authoritative
    /// identity record (the real heartbeat writes accurate epoch-seconds);
    /// when the heartbeat carries no usable record, `gateway.pid`'s own
    /// `start_time` is used. A reused pid whose current process started after
    /// the recorded start is treated as dead (VAL-HARD-007).
    private static func isLiveGatewayPid(
        _ pid: Int,
        gatewayPid: GatewayPidSignal?,
        heartbeat: HeartbeatSignal?
    ) -> Bool {
        if let heartbeatStart = heartbeat?.startTime {
            return BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: heartbeatStart)
        }
        return BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: gatewayPid?.startTime)
    }

    /// The heartbeat is evidence for the gateway only when its pid matches
    /// the gateway pid. A heartbeat with no pid field cannot be associated
    /// and is treated as matching (the pid-reuse guard still applies via the
    /// gateway pid's own record).
    private static func heartbeatMatchesGateway(heartbeat: HeartbeatSignal?, gatewayPid: Int?) -> Bool {
        guard let heartbeatPid = heartbeat?.pid else { return true }
        return heartbeatPid == gatewayPid
    }

    /// Stale/missing-heartbeat result for a live gateway pid: non-running
    /// with a typed degraded probeHealth reason naming the missing
    /// corroboration (VAL-FLEET-023).
    private static func staleHeartbeatResult(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        heartbeatMatchesGateway: Bool,
        signals: Signals
    ) -> BurnBarFleetProbeResult {
        let reason: String
        if signals.heartbeat != nil, !heartbeatMatchesGateway {
            reason = "Gateway heartbeat pid does not match the gateway pid; active work is not claimed."
        } else {
            reason = "Gateway heartbeat is stale or missing; active work is not claimed."
        }
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .stale,
            confidence: .activeSessionFile,
            lastActivityAt: signals.heartbeat?.updatedAt,
            signals: signals.sources,
            note: reason,
            healthState: BurnBarFleetProbeSupport.degradedHealth(signals.healthState, reason: reason)
        )
    }
}
