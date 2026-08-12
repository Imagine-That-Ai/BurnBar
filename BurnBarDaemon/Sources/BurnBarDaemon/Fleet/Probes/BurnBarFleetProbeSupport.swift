import BurnBarCore
import Darwin
import Foundation

/// Freshness constants pinned in `docs/fleet/BURNBAR_FLEET_SIGNALS.md`.
/// Probes read these constants; validators reference the same values.
public enum BurnBarFleetProbeConstants {
    /// claude-code session `updatedAt` freshness window (120 s).
    public static let claudeCodeFreshnessSeconds: TimeInterval = 120
    /// factory-droid invocation / session-dir freshness window (300 s).
    public static let factoryDroidFreshnessSeconds: TimeInterval = 300
    /// grok-cli registry-file freshness window (300 s). Used for the
    /// pid-dead-but-file-fresh confidence step-down: a registry file whose
    /// mtime is inside this window is "fresh".
    public static let grokCLIFileFreshnessSeconds: TimeInterval = 300
}

/// Read-only process liveness checks. The mission never signals, kills, or
/// renicies processes: probes use `kill -0`-style existence checks only.
public enum BurnBarFleetProcessLiveness: Sendable {
    /// `kill -0` existence check.
    public static func isAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    /// Process start time (seconds since 1970) via `proc_pidinfo`, or nil
    /// when the process is not queryable.
    public static func processStartTime(pid: Int) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Int8.self, capacity: size) { rebound in
                proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, rebound, Int32(size))
            }
        }
        guard result == Int32(size) else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000.0
    }

    /// Pid-reuse guard (documented in BURNBAR_FLEET_SIGNALS.md): the pid is
    /// alive AND, when the signal file records a process start time, the
    /// current process started at or before the recorded start. A process
    /// that started after the file's record is a reused pid and is treated
    /// as dead. A missing or unqueryable record skips the guard (kill -0
    /// decides). The small tolerance absorbs clock granularity between the
    /// kernel and the writing process.
    public static func isLiveProcess(pid: Int, fileStartedAt: Date?) -> Bool {
        guard isAlive(pid: pid) else { return false }
        guard let fileStartedAt else { return true }
        guard let processStart = processStartTime(pid: pid) else { return true }
        return processStart <= fileStartedAt.timeIntervalSince1970 + 5.0
    }
}

/// Small JSON helpers for probe signal parsing. Probes parse only declared
/// signal files; malformed shapes degrade typed (never fabricated liveness).
public enum BurnBarFleetProbeJSON {
    /// Reads and parses a JSON document at `path`. Throws when the file is
    /// unreadable or the content is not valid JSON.
    public static func readJSON(at path: String) throws -> Any {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Epoch-milliseconds number → Date (nil when absent, null, or mistyped).
    public static func dateFromEpochMilliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000.0)
    }

    /// Integer value (nil when absent, null, or mistyped).
    public static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    /// String value (nil when absent, null, or mistyped).
    public static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
    }
}

/// Shared probe result builders so every probe reports the same typed shapes
/// for missing roots, absent evidence, and ordinary rows.
public enum BurnBarFleetProbeSupport {
    /// Typed result for a missing declared root: `unknown`/`unsupported` row
    /// with `failed` health naming the root path.
    public static func missingRootResult(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date
    ) -> BurnBarFleetProbeResult {
        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: .unknown,
            confidence: .unsupported,
            note: "Declared root missing."
        )
        let health = BurnBarFleetProbeHealth(
            agent: agentID,
            state: .failed(reason: "Declared root missing: \(rootPath)"),
            rootPath: rootPath,
            checkedAt: now
        )
        return BurnBarFleetProbeResult(agent: agent, health: health)
    }

    /// Typed result for a present root with no signal evidence: an
    /// `unknown`/`unsupported` row with `ok` health.
    public static func noEvidenceResult(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        note: String
    ) -> BurnBarFleetProbeResult {
        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: .unknown,
            confidence: .unsupported,
            note: note
        )
        let health = BurnBarFleetProbeHealth(agent: agentID, state: .ok, rootPath: rootPath, checkedAt: now)
        return BurnBarFleetProbeResult(agent: agent, health: health)
    }

    /// Builds a probe result from explicit row fields plus a health state.
    public static func result(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        status: BurnBarFleetAgentStatus,
        confidence: BurnBarFleetConfidence,
        projectName: String? = nil,
        lastActivityAt: Date? = nil,
        process: BurnBarFleetProcessInfo? = nil,
        signals: [BurnBarFleetSignalSource] = [],
        note: String? = nil,
        healthState: BurnBarFleetProbeHealthState
    ) -> BurnBarFleetProbeResult {
        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: status,
            confidence: confidence,
            projectName: projectName,
            lastActivityAt: lastActivityAt,
            process: process,
            signals: signals,
            note: note
        )
        let health = BurnBarFleetProbeHealth(agent: agentID, state: healthState, rootPath: rootPath, checkedAt: now)
        return BurnBarFleetProbeResult(agent: agent, health: health)
    }
}
