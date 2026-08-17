import OpenBurnBarKernel
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
    /// Whole-probe budget for the serial signal-file reads (VAL-FLEET-019
    /// seam). The same monotonic deadline is passed through every reader.
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .hermes,
        rootPath: String,
        heartbeatFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.hermesHeartbeatFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.hermesProbeBudgetSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.heartbeatFreshnessSeconds = heartbeatFreshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        if let rootIssue = BurnBarFleetProbeSupport.rootAccessResult(
            agentID: agentID,
            rootPath: rootPath,
            now: now
        ) {
            return rootIssue
        }

        let rawSignals = Self.readSignals(
            rootURL: rootURL,
            timeoutSeconds: readTimeoutSeconds
        )
        let gatewayPid = rawSignals.gatewayPid
        let heartbeat = rawSignals.heartbeat
        let gatewayState = rawSignals.gatewayState
        let processes = rawSignals.processes

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

    private struct ClassificationContext {
        let agentID: BurnBarFleetAgentID
        let rootPath: String
        let now: Date
        let gatewayPid: GatewayPidSignal?
        let heartbeat: HeartbeatSignal?
        let gatewayState: GatewayStateSignal?
        let processes: ProcessesSignal?
        let signals: Signals
        let pid: Int?
        let pidAlive: Bool
        let heartbeatFresh: Bool
        let heartbeatMatchesGateway: Bool
        let hasActiveWork: Bool
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
        let pid = signals.gatewayPid?.pid
        let context = ClassificationContext(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            gatewayPid: signals.gatewayPid,
            heartbeat: signals.heartbeat,
            gatewayState: signals.gatewayState,
            processes: signals.processes,
            signals: signals,
            pid: pid,
            pidAlive: pid.map {
                Self.isLiveGatewayPid(
                    $0,
                    gatewayPid: signals.gatewayPid,
                    heartbeat: signals.heartbeat
                )
            } ?? false,
            heartbeatFresh: signals.heartbeat?.isFresh(
                now: now,
                freshnessSeconds: heartbeatFreshnessSeconds
            ) ?? false,
            heartbeatMatchesGateway: Self.heartbeatMatchesGateway(
                heartbeat: signals.heartbeat,
                gatewayPid: pid
            ),
            hasActiveWork: (signals.gatewayState?.activeAgents ?? 0) > 0
                || (signals.processes?.entries.isEmpty == false)
        )
        if let freshResult = Self.classifyFreshHeartbeat(context) {
            return freshResult
        }
        return Self.classifyNonFreshHeartbeat(context)
    }

    private static func classifyFreshHeartbeat(
        _ context: ClassificationContext
    ) -> BurnBarFleetProbeResult? {
        let heartbeat = context.heartbeat
        let signals = context.signals

        // A fresh heartbeat without gateway_state cannot distinguish idle
        // from active work when processes.json is empty. A non-empty
        // processes.json is itself the documented active-work signal, so
        // preserve that evidence and classify the gateway as running while
        // surfacing the missing primary signal as typed health.
        if context.gatewayState == nil,
           context.pidAlive,
           context.heartbeatFresh,
           context.heartbeatMatchesGateway {
            let reason = "gateway_state.json is absent; active_agents is unavailable."
            let healthState = BurnBarFleetProbeSupport.degradedHealth(
                signals.healthState,
                reason: reason
            )
            if context.hasActiveWork, let pid = context.pid {
                return BurnBarFleetProbeSupport.result(
                    agentID: context.agentID,
                    rootPath: context.rootPath,
                    now: context.now,
                    status: .running,
                    confidence: .exactProcess,
                    projectName: context.processes?.entries.first?.cwd,
                    lastActivityAt: heartbeat?.updatedAt,
                    process: BurnBarFleetProcessInfo(pid: pid),
                    signals: signals.sources,
                    note: reason,
                    healthState: healthState
                )
            }
            return BurnBarFleetProbeSupport.result(
                agentID: context.agentID,
                rootPath: context.rootPath,
                now: context.now,
                status: .unknown,
                confidence: .activeSessionFile,
                lastActivityAt: heartbeat?.updatedAt,
                signals: signals.sources,
                note: reason,
                healthState: healthState
            )
        }

        // A malformed active_agents count cannot be defaulted to zero.
        if let gatewayState = context.gatewayState,
           gatewayState.malformedReason != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: context.agentID,
                rootPath: context.rootPath,
                now: context.now,
                status: .unknown,
                confidence: .unsupported,
                lastActivityAt: heartbeat?.updatedAt,
                signals: signals.sources,
                note: "Gateway state signal malformed; status unknown.",
                healthState: signals.healthState
            )
        }

        guard context.pidAlive,
              context.heartbeatFresh,
              context.heartbeatMatchesGateway,
              let pid = context.pid else {
            return nil
        }

        let healthState = secondarySignalHealth(signals.healthState, processes: context.processes)
        if context.hasActiveWork {
            return BurnBarFleetProbeSupport.result(
                agentID: context.agentID,
                rootPath: context.rootPath,
                now: context.now,
                status: .running,
                confidence: .exactProcess,
                projectName: context.processes?.entries.first?.cwd,
                lastActivityAt: heartbeat?.updatedAt,
                process: BurnBarFleetProcessInfo(pid: pid),
                signals: signals.sources,
                note: secondarySignalNote(processes: context.processes),
                healthState: healthState
            )
        }

        let note = [
            "Gateway alive with zero active agents; idle, not running.",
            secondarySignalNote(processes: context.processes)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return BurnBarFleetProbeSupport.result(
            agentID: context.agentID,
            rootPath: context.rootPath,
            now: context.now,
            status: .idle,
            confidence: .exactProcess,
            lastActivityAt: heartbeat?.updatedAt,
            process: BurnBarFleetProcessInfo(pid: pid),
            signals: signals.sources,
            note: note,
            healthState: healthState
        )
    }

    private static func classifyNonFreshHeartbeat(
        _ context: ClassificationContext
    ) -> BurnBarFleetProbeResult {
        // A live pid without a fresh, matching heartbeat never claims work.
        if context.pidAlive {
            return staleHeartbeatResult(
                agentID: context.agentID,
                rootPath: context.rootPath,
                now: context.now,
                heartbeatMatchesGateway: context.heartbeatMatchesGateway,
                signals: context.signals
            )
        }

        // A malformed gateway pid is distinct from a merely dead pid.
        if let gatewayPid = context.gatewayPid,
           gatewayPid.malformedReason != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: context.agentID,
                rootPath: context.rootPath,
                now: context.now,
                status: .unknown,
                confidence: .unsupported,
                signals: context.signals.sources,
                note: "Gateway pid signal malformed; status unknown.",
                healthState: context.signals.healthState
            )
        }

        if context.gatewayPid != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: context.agentID,
                rootPath: context.rootPath,
                now: context.now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: context.heartbeat?.updatedAt,
                signals: context.signals.sources,
                note: "Gateway pid is not alive; confidence downgraded.",
                healthState: context.signals.healthState
            )
        }

        return BurnBarFleetProbeSupport.result(
            agentID: context.agentID,
            rootPath: context.rootPath,
            now: context.now,
            status: .unknown,
            confidence: .unsupported,
            signals: context.signals.sources,
            note: "Gateway pid signal absent.",
            healthState: context.signals.healthState
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

    /// Missing `processes.json` does not invalidate a fresh heartbeat or the
    /// typed `active_agents` count, but it removes repo attribution and the
    /// secondary corroboration. Surface that loss through both typed health
    /// and a non-secret note instead of presenting a fully corroborated row.
    private static func secondarySignalHealth(
        _ health: BurnBarFleetProbeHealthState,
        processes: ProcessesSignal?
    ) -> BurnBarFleetProbeHealthState {
        guard processes == nil else { return health }
        return BurnBarFleetProbeSupport.degradedHealth(
            health,
            reason: "processes.json is absent; repo attribution is unavailable."
        )
    }

    private static func secondarySignalNote(processes: ProcessesSignal?) -> String? {
        guard processes == nil else { return nil }
        return "processes.json is absent; repo attribution is unavailable."
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
