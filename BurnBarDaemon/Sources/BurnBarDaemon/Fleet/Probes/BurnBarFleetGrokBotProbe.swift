import BurnBarCore
import Foundation

/// Grok Bot probe: `~/.grokbot/local-exec-daemon.json` +
/// `local-exec-supervisor.json` (+ `local-exec-daemon.log`).
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §5):
/// - **Running:** daemon pid live AND `inflightCount > 0`. The documented
///   alternate (supervisor `at` fresh (< 120 s) with recent log activity) is
///   NOT claimed: the supervisor file is refreshed ~minutely by the same
///   daemon, so a fresh supervisor signal alone cannot distinguish active
///   work from a merely alive daemon. Claiming it would risk reporting
///   `running` from stale evidence (VAL-FLEET-023).
/// - **Pid-reuse guard:** every pid-bearing liveness check (daemon pid,
///   supervisor pid) applies the process-start identity check
///   (`isLiveProcess`) before `kill -0` — a reused pid whose current process
///   started after the recorded `startedAt`/`at` is treated as dead and can
///   never resurrect `running`/`exactProcess` (VAL-HARD-007).
/// - **Idle:** daemon/supervisor alive with `inflightCount == 0` — the common
///   case; the daemon existing is NOT running (VAL-FLEET-004).
/// - **Stale/absent supervisor signal:** never yields `running` from stale
///   evidence. A live daemon with a stale or absent supervisor signal stays
///   `idle`/`unknown` (VAL-FLEET-023) AND surfaces a typed `degraded`
///   probeHealth reason — the missing/stale corroboration is never silently
///   healthy.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (`pid`, `inflightCount`) → typed `unknown`/`stale` row with a
///   `degraded` health reason — never fabricated `running`.
/// - **Secrets:** `local-exec-daemon-connection.json` is NEVER read (it
///   bears tokens); only the two declared signal files are parsed.
/// - **Repo attribution:** connection/workspace hints are not present in the
///   declared signal files; projectName stays nil.
public struct BurnBarFleetGrokBotProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Supervisor-signal freshness window (defaults to the pinned 120 s
    /// constant). Used only to classify the supervisor signal's own state.
    public let supervisorFreshnessSeconds: TimeInterval
    /// Per-probe timeout for signal-file reads (VAL-FLEET-019 seam).
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .grokBot,
        rootPath: String,
        supervisorFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.grokBotSupervisorFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.supervisorFreshnessSeconds = supervisorFreshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: rootPath) else {
            return BurnBarFleetProbeSupport.missingRootResult(agentID: agentID, rootPath: rootPath, now: now)
        }

        let daemonPath = rootURL.appendingPathComponent("local-exec-daemon.json").path
        let supervisorPath = rootURL.appendingPathComponent("local-exec-supervisor.json").path

        let daemon = Self.readDaemon(at: daemonPath, timeoutSeconds: readTimeoutSeconds)
        let supervisor = Self.readSupervisor(at: supervisorPath, timeoutSeconds: readTimeoutSeconds)

        var signals: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []

        if let daemon {
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "heartbeat-file",
                    path: daemon.path,
                    detail: daemon.malformedReason ?? Self.daemonDetail(daemon)
                )
            )
            if let reason = daemon.malformedReason {
                healthReasons.append(reason)
            }
        }

        if let supervisor {
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "heartbeat-file",
                    path: supervisor.path,
                    detail: supervisor.malformedReason ?? Self.supervisorDetail(supervisor, now: now)
                )
            )
            if let reason = supervisor.malformedReason {
                healthReasons.append(reason)
            }
        }

        let healthState: BurnBarFleetProbeHealthState = healthReasons.isEmpty
            ? .ok
            : .degraded(reason: healthReasons.joined(separator: " "))

        return Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            supervisorFreshnessSeconds: supervisorFreshnessSeconds,
            daemon: daemon,
            supervisor: supervisor,
            signals: signals,
            healthState: healthState
        )
    }

    /// Classifies the row. Running requires a live daemon pid (verified with
    /// the process-start identity check — a reused pid is never live) AND
    /// `inflightCount > 0`; a stale/absent supervisor signal never yields
    /// running from stale evidence.
    private static func classify(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        supervisorFreshnessSeconds: TimeInterval,
        daemon: DaemonSignal?,
        supervisor: SupervisorSignal?,
        signals: [BurnBarFleetSignalSource],
        healthState: BurnBarFleetProbeHealthState
    ) -> BurnBarFleetProbeResult {
        // Running: live daemon pid (pid-reuse guarded) + inflightCount > 0.
        if let daemon, daemon.malformedReason == nil,
           let pid = daemon.pid, let inflight = daemon.inflightCount,
           BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: daemon.startedAt), inflight > 0 {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .exactProcess,
                lastActivityAt: daemon.startedAt,
                process: BurnBarFleetProcessInfo(pid: pid),
                signals: signals,
                healthState: healthState
            )
        }

        // Idle: daemon alive (pid-reuse guarded) with inflight 0 (the common
        // case). A stale or absent supervisor signal does not change the
        // status — the daemon is genuinely idle — but it MUST surface as a
        // typed degraded probeHealth reason (VAL-FLEET-023): an idle row with
        // healthy probeHealth while the supervisor corroboration is
        // stale/absent silently hides the missing evidence.
        if let daemon, daemon.malformedReason == nil,
           let pid = daemon.pid, let inflight = daemon.inflightCount,
           BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: daemon.startedAt), inflight == 0 {
            var branchHealth = healthState
            if let supervisor, supervisor.malformedReason == nil {
                let supervisorLive = supervisor.pid.map {
                    BurnBarFleetProcessLiveness.isLiveProcess(pid: $0, fileStartedAt: supervisor.at)
                } ?? false
                let supervisorFresh = supervisor.at.map {
                    now.timeIntervalSince($0) <= supervisorFreshnessSeconds
                } ?? false
                if !supervisorLive || !supervisorFresh {
                    branchHealth = BurnBarFleetProbeSupport.degradedHealth(
                        branchHealth,
                        reason: "Supervisor signal is stale or its pid is not alive; daemon idle with inflightCount 0."
                    )
                }
            } else if supervisor == nil {
                branchHealth = BurnBarFleetProbeSupport.degradedHealth(
                    branchHealth,
                    reason: "Supervisor signal absent; daemon idle with inflightCount 0."
                )
            }
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .idle,
                confidence: .exactProcess,
                lastActivityAt: daemon.startedAt,
                process: BurnBarFleetProcessInfo(pid: pid),
                signals: signals,
                note: "Daemon alive with inflightCount 0; idle, not running.",
                healthState: branchHealth
            )
        }

        // Daemon pid dead (or fails the pid-reuse guard): never running.
        if let daemon, daemon.malformedReason == nil, let pid = daemon.pid {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: daemon.startedAt,
                signals: signals,
                note: "Daemon pid \(pid) is not alive; confidence downgraded.",
                healthState: healthState
            )
        }

        // Malformed daemon signal: typed unknown, never fabricated running.
        if let daemon, daemon.malformedReason != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                signals: signals,
                note: "Daemon signal malformed; status unknown.",
                healthState: healthState
            )
        }

        // No daemon signal file at all. A supervisor signal alone is not a
        // liveness claim for the daemon: report unknown with the supervisor
        // evidence listed.
        if let supervisor, supervisor.malformedReason == nil {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                signals: signals,
                note: "Daemon signal file absent; supervisor signal alone is not a liveness claim.",
                healthState: healthState
            )
        }

        // Root present but no signal files at all.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .unknown,
            confidence: .unsupported,
            signals: signals,
            note: "Roots present, no signal files.",
            healthState: healthState
        )
    }

    // MARK: - Parsing

    private struct DaemonSignal {
        let path: String
        let pid: Int?
        let startedAt: Date?
        let inflightCount: Int?
        let malformedReason: String?
    }

    private struct SupervisorSignal {
        let path: String
        let pid: Int?
        let at: Date?
        let malformedReason: String?
    }

    private static func readDaemon(at path: String, timeoutSeconds: TimeInterval) -> DaemonSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return DaemonSignal(
                    path: path,
                    pid: nil,
                    startedAt: nil,
                    inflightCount: nil,
                    malformedReason: "local-exec-daemon.json is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return DaemonSignal(
                path: path,
                pid: nil,
                startedAt: nil,
                inflightCount: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        // Required keys: pid and inflightCount. Missing or mistyped → malformed.
        // The pid must be in the positive macOS pid_t range (strict helper);
        // a PRESENT-but-invalid startedAt is malformed — it is never silently
        // converted to nil and treated like an absent record (which would
        // skip the pid-reuse guard and let a live pid pass).
        guard let pid = BurnBarFleetProbeJSON.pidValue(object["pid"]) else {
            let reason = BurnBarFleetProbeJSON.pidRejectionReason(object["pid"])
                ?? "local-exec-daemon.json is missing a numeric pid."
            return DaemonSignal(
                path: path,
                pid: nil,
                startedAt: nil,
                inflightCount: nil,
                malformedReason: "local-exec-daemon.json pid is malformed: \(reason)"
            )
        }
        guard let inflightCount = BurnBarFleetProbeJSON.integerValue(object["inflightCount"]) else {
            return DaemonSignal(
                path: path,
                pid: pid,
                startedAt: nil,
                inflightCount: nil,
                malformedReason: "local-exec-daemon.json is missing a numeric inflightCount."
            )
        }

        let startedAtOutcome = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(object["startedAt"])
        guard case .invalid(let reason) = startedAtOutcome else {
            let startedAt: Date?
            if case .valid(let date) = startedAtOutcome {
                startedAt = date
            } else {
                startedAt = nil
            }
            return DaemonSignal(
                path: path,
                pid: pid,
                startedAt: startedAt,
                inflightCount: inflightCount,
                malformedReason: nil
            )
        }
        return DaemonSignal(
            path: path,
            pid: nil,
            startedAt: nil,
            inflightCount: nil,
            malformedReason: "local-exec-daemon.json startedAt is malformed: \(reason)"
        )
    }

    private static func readSupervisor(at path: String, timeoutSeconds: TimeInterval) -> SupervisorSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return SupervisorSignal(
                    path: path,
                    pid: nil,
                    at: nil,
                    malformedReason: "local-exec-supervisor.json is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return SupervisorSignal(
                path: path,
                pid: nil,
                at: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let pid = BurnBarFleetProbeJSON.pidValue(object["pid"]) else {
            let reason = BurnBarFleetProbeJSON.pidRejectionReason(object["pid"])
                ?? "local-exec-supervisor.json is missing a numeric pid."
            return SupervisorSignal(
                path: path,
                pid: nil,
                at: nil,
                malformedReason: "local-exec-supervisor.json pid is malformed: \(reason)"
            )
        }

        let atOutcome = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(object["at"])
        guard case .invalid(let reason) = atOutcome else {
            let at: Date?
            if case .valid(let date) = atOutcome {
                at = date
            } else {
                at = nil
            }
            return SupervisorSignal(path: path, pid: pid, at: at, malformedReason: nil)
        }
        return SupervisorSignal(
            path: path,
            pid: nil,
            at: nil,
            malformedReason: "local-exec-supervisor.json at is malformed: \(reason)"
        )
    }

    private static func daemonDetail(_ daemon: DaemonSignal) -> String? {
        guard let pid = daemon.pid, let inflight = daemon.inflightCount else { return nil }
        return "pid \(pid), inflightCount \(inflight)"
    }

    private static func supervisorDetail(_ supervisor: SupervisorSignal, now: Date) -> String? {
        guard let pid = supervisor.pid else { return nil }
        if let at = supervisor.at {
            let age = Int(now.timeIntervalSince(at))
            return "pid \(pid), at \(age)s ago"
        }
        return "pid \(pid)"
    }
}
