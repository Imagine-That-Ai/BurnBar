import OpenBurnBarKernel
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Freshness constants pinned in `docs/fleet/BURNBAR_FLEET_SIGNALS.md`.
/// Probes read these constants; validators reference the same values.
public enum BurnBarFleetProbeConstants {
    /// claude-code session `updatedAt` freshness window (120 s).
    public static let claudeCodeFreshnessSeconds: TimeInterval = 120
    /// hermes gateway heartbeat freshness window (120 s).
    public static let hermesHeartbeatFreshnessSeconds: TimeInterval = 120
    /// grok-bot supervisor `at` / recent-log freshness window (120 s).
    public static let grokBotSupervisorFreshnessSeconds: TimeInterval = 120
    /// factory-droid invocation / session-dir freshness window (300 s).
    public static let factoryDroidFreshnessSeconds: TimeInterval = 300
    /// codex thread-writer-lock mtime freshness window (300 s).
    public static let codexLockFreshnessSeconds: TimeInterval = 300
    /// pi newest-transcript mtime freshness window (300 s).
    public static let piTranscriptFreshnessSeconds: TimeInterval = 300
    /// cursor `ai-tracking/` mtime freshness window (300 s).
    public static let cursorTrackingFreshnessSeconds: TimeInterval = 300
    /// grok-cli registry-file freshness window (300 s). Used for the
    /// pid-dead-but-file-fresh confidence step-down: a registry file whose
    /// mtime is inside this window is "fresh".
    public static let grokCLIFileFreshnessSeconds: TimeInterval = 300
    /// Per-probe timeout seam (VAL-FLEET-019): every signal-file content read
    /// is bounded by this interval via a non-blocking open + poll. A blocking
    /// path (FIFO) or a read that exceeds the bound degrades the affected
    /// probe typed (`degraded(reason: ... timed out ...)`) and the tick
    /// continues on cadence — a hung signal path never stalls the snapshot.
    public static let perProbeTimeoutSeconds: TimeInterval = 2.0
    /// Hermes applies the same two-second budget to its complete sequence of
    /// signal reads, rather than granting two seconds to each file.
    public static let hermesProbeBudgetSeconds: TimeInterval = 2.0
}

/// Read-only process liveness checks. The mission never signals, kills, or
/// renicies processes: probes use `kill -0`-style existence checks only.
public enum BurnBarFleetProcessLiveness: Sendable {
    /// `kill -0` existence check. The positive pid_t range guard runs BEFORE
    /// the `pid_t(pid)` conversion: on macOS pid_t is Int32 and the checked
    /// conversion traps on out-of-range Int values, so zero, negative, and
    /// values beyond Int32.max are rejected here as a second line of defense
    /// behind the probes' strict `pidValue` decoding.
    public static func isAlive(pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    /// Process start time (seconds since 1970) via `proc_pidinfo`, or nil
    /// when the process is not queryable. Same pid_t range guard as
    /// `isAlive` — an out-of-range pid is never converted.
    public static func processStartTime(pid: Int) -> TimeInterval? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Int8.self, capacity: size) { rebound in
                proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, rebound, Int32(size))
            }
        }
        guard result == Int32(size) else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000.0
        #else
        return nil
        #endif
    }

    /// Pid-reuse guard (documented in BURNBAR_FLEET_SIGNALS.md): the pid is
    /// alive AND, when the signal file records a start time, the current
    /// process started at or before the recorded start. A process
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
    /// Maps a bounded-read failure to a probe-health reason string. The
    /// timeout case is the documented VAL-FLEET-019 degradation; other
    /// failures are reported as unreadable.
    public static func readFailureReason(_ error: Error) -> String {
        if let readError = error as? BurnBarFleetProbeReadError {
            switch readError {
            case .timedOut:
                return "Signal file read timed out (per-probe timeout)."
            case .unreadable(let code):
                return "Signal file is not readable (errno \(code))."
            }
        }
        return "Signal file is not valid JSON."
    }

    /// Epoch-milliseconds number → Date (nil when absent, null, mistyped,
    /// boolean, or fractional). The documented encoding is INTEGRAL
    /// epoch-milliseconds; booleans and fractional values are malformed and
    /// degrade typed — they never become a live-looking timestamp.
    public static func dateFromEpochMilliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        guard !isBoolean(number) else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds.rounded() == milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000.0)
    }

    /// Tri-state epoch-milliseconds timestamp: `.absent` when the field is
    /// missing/null, `.invalid(reason)` when it is PRESENT but malformed
    /// (boolean, fractional, non-numeric), `.valid(Date)` otherwise.
    ///
    /// The absent-vs-invalid distinction is a hard probe rule: an ABSENT
    /// process-start record keeps the documented fallback behavior (the
    /// pid-reuse guard is skipped and `kill -0` decides), while a
    /// PRESENT-but-invalid record is malformed and must degrade the entry
    /// typed — it is never silently converted to nil and treated like an
    /// absent record (probe-hardening-repair-a follow-up, reviewer issue 1).
    public static func dateFromEpochMillisecondsTriState(_ value: Any?) -> TimestampOutcome {
        guard let number = value as? NSNumber else {
            if value == nil || value is NSNull {
                return .absent
            }
            return .invalid(reason: "startTime is not a number.")
        }
        guard !isBoolean(number) else {
            return .invalid(reason: "startTime is a boolean, not a numeric timestamp.")
        }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds.rounded() == milliseconds else {
            return .invalid(
                reason: "startTime is fractional or non-finite, not an integral epoch-milliseconds timestamp."
            )
        }
        return .valid(Date(timeIntervalSince1970: milliseconds / 1000.0))
    }

    /// Tri-state process-start timestamp from a signal file's `start_time`
    /// field, with the same absent-vs-invalid distinction as
    /// `dateFromEpochMillisecondsTriState`. The documented encoding is
    /// epoch-seconds (e.g. `1750000000`), but the real hermes `gateway.pid`
    /// writes epoch-milliseconds (e.g. `178653683051`): values >= 1e11 are
    /// treated as integral epoch-milliseconds, smaller values as epoch-seconds
    /// (fractional allowed, matching the real heartbeat's `1786536834.708521`).
    /// Booleans, non-finite values, and fractional epoch-milliseconds are
    /// malformed and return `.invalid` — they never become a live-looking
    /// start time. Records mapping to before 2000 are implausible for any
    /// current process (the real gateway.pid's ms-in-seconds bug yields
    /// 1975) and are treated as `.absent` so a corrupt record can neither
    /// resurrect a dead pid nor falsely kill a live one.
    public static func dateFromStartTimeTriState(_ value: Any?) -> TimestampOutcome {
        guard let number = value as? NSNumber else {
            if value == nil || value is NSNull {
                return .absent
            }
            return .invalid(reason: "start_time is not a number.")
        }
        guard !isBoolean(number) else {
            return .invalid(reason: "start_time is a boolean, not a numeric timestamp.")
        }
        let double = number.doubleValue
        guard double.isFinite else {
            return .invalid(reason: "start_time is non-finite.")
        }
        let date: Date
        if double >= 100_000_000_000 {
            guard double.rounded() == double else {
                return .invalid(reason: "start_time is fractional epoch-milliseconds; integral only.")
            }
            date = Date(timeIntervalSince1970: double / 1000.0)
        } else {
            date = Date(timeIntervalSince1970: double)
        }
        guard date.timeIntervalSince1970 >= 946_684_800 else { return .absent }
        return .valid(date)
    }

    /// Tri-state outcome for a signal-file timestamp field: absent (field
    /// missing/null), invalid (field present but malformed, with a reason
    /// naming the malformed value), or valid.
    public enum TimestampOutcome: Equatable, Sendable {
        case absent
        case invalid(reason: String)
        case valid(Date)
    }

    /// Integer value (nil when absent, null, mistyped, boolean, fractional,
    /// or out of Int64 range). Strict by design: a malformed
    /// pid/inflightCount/active_agents must degrade typed — it is never
    /// coerced via `intValue` into a live-looking integer.
    public static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded() == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max) else { return nil }
        return Int(number.int64Value)
    }

    /// Strict pid decoding for JSON pid fields: a valid pid is an integral
    /// number in the positive macOS pid_t range (1...Int32.max). Zero,
    /// negative, and values beyond Int32.max are REJECTED before any
    /// pid_t/liveness conversion — on macOS pid_t is Int32 and the checked
    /// `pid_t(pid)` conversion traps on out-of-range Int values
    /// (probe-hardening-repair-a follow-up, reviewer issue 2). The strict
    /// helper is the single home for the range guard: every probe converts
    /// JSON numbers to pid_t only through this function.
    public static func pidValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded() == double,
              double >= 1,
              double <= Double(Int32.max) else { return nil }
        return Int(number.int64Value)
    }

    /// Human-readable reason for a rejected pid value, for probeHealth
    /// reasons that must name the malformed value. Returns nil when the
    /// value is a valid pid.
    public static func pidRejectionReason(_ value: Any?) -> String? {
        if pidValue(value) != nil { return nil }
        if let number = value as? NSNumber, !isBoolean(number) {
            let double = number.doubleValue
            if double.isFinite, double.rounded() == double {
                if double < 1 {
                    if double >= Double(Int64.min) {
                        return "pid \(Int64(double)) is not a positive pid."
                    }
                    return "pid is not a positive pid."
                }
                if double > Double(Int32.max) {
                    // Double(Int64.max) rounds to 2^63, which Int64 cannot
                    // hold — convert only values strictly below it.
                    if double < Double(Int64.max) {
                        return "pid \(Int64(double)) exceeds the macOS pid_t range (Int32.max)."
                    }
                    return "pid exceeds the macOS pid_t range (Int32.max)."
                }
            }
            return "pid is not an integral number."
        }
        return "pid is not a numeric value."
    }

    /// JSON `true`/`false` bridge to `NSNumber`; never a valid integer or
    /// timestamp signal value.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
        #endif
    }

    /// String value (nil when absent, null, or mistyped).
    public static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
    }
}

/// Typed bounded-read failures (per-probe timeout seam).
public enum BurnBarFleetProbeReadError: Error, Equatable, Sendable {
    /// The file could not be opened for reading.
    case unreadable(Int32)
    /// The file did not become readable within the per-probe timeout.
    case timedOut
}

/// Shared probe result builders so every probe reports the same typed shapes
/// for missing roots, absent evidence, and ordinary rows.
public enum BurnBarFleetProbeSupport {
    /// Checks a declared root before a probe touches any child path. Missing
    /// and unreadable roots both return a typed result; a readable root
    /// returns nil so the owning probe can inspect its known signals.
    public static func rootAccessResult(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date
    ) -> BurnBarFleetProbeResult? {
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return missingRootResult(agentID: agentID, rootPath: rootPath, now: now)
        }
        guard rootPermissionDeniedReason(at: rootPath) == nil else {
            return permissionDeniedRootResult(agentID: agentID, rootPath: rootPath, now: now)
        }
        return nil
    }

    /// Returns a typed access failure for a declared root that exists but
    /// cannot be read/traversed. Probes check this before looking for signal
    /// files so an unreadable root is never mistaken for an installed-but-
    /// inactive root. The permission-bit check also makes the hermetic
    /// `chmod 000` fixture deterministic when a validator happens to run as
    /// uid 0, whose `access(2)` call would otherwise bypass the mode bits.
    public static func rootPermissionDeniedReason(at rootPath: String) -> String? {
        var fileStatus = stat()
        guard lstat(rootPath, &fileStatus) == 0 else {
            return errno == EACCES
                ? "Declared root permission denied: \(rootPath)"
                : nil
        }

        guard (fileStatus.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let permissionBits = fileStatus.st_mode & 0o777
        guard permissionBits != 0,
              access(rootPath, R_OK | X_OK) == 0 else {
            return "Declared root permission denied: \(rootPath)"
        }
        return nil
    }

    /// Typed result for a present but unreadable declared root. Permission
    /// failures are probe-local and intentionally do not expose file content.
    public static func permissionDeniedRootResult(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date
    ) -> BurnBarFleetProbeResult {
        let reason = rootPermissionDeniedReason(at: rootPath)
            ?? "Declared root permission denied: \(rootPath)"
        return result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .unknown,
            confidence: .unsupported,
            note: reason,
            healthState: .degraded(reason: reason)
        )
    }

    /// Merges a typed reason into an existing health state: an `ok` state
    /// becomes `degraded(reason:)`; a degraded/failed state keeps its kind
    /// and appends the new reason. Used when a branch adds its own typed
    /// evidence reason (e.g. a stale/absent supervisor or heartbeat) on top
    /// of any malformed-signal reasons already collected.
    public static func degradedHealth(
        _ health: BurnBarFleetProbeHealthState,
        reason: String
    ) -> BurnBarFleetProbeHealthState {
        switch health {
        case .ok:
            return .degraded(reason: reason)
        case .degraded(let existing):
            return .degraded(reason: existing + " " + reason)
        case .failed(let existing):
            return .failed(reason: existing + " " + reason)
        }
    }

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

    /// Membership for the bounded thread crawl: live PID (when we have one)
    /// or last activity inside the freshness window. Historical dead+stale
    /// files are not emitted.
    public static func isThreadMember(
        liveProcess: Bool,
        lastActivity: Date?,
        now: Date,
        freshnessSeconds: TimeInterval
    ) -> Bool {
        if liveProcess { return true }
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) <= freshnessSeconds
    }

    /// Sorts running first, then last activity, and caps at
    /// `BurnBarFleetThreadLimits.maxPerAgent`.
    public static func boundThreads(_ threads: [BurnBarFleetThread]) -> [BurnBarFleetThread] {
        let sorted = threads.sorted { lhs, rhs in
            if lhs.status.rollupRank != rhs.status.rollupRank {
                return lhs.status.rollupRank > rhs.status.rollupRank
            }
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
        return Array(sorted.prefix(BurnBarFleetThreadLimits.maxPerAgent))
    }

    /// Attaches a bounded thread list to a classified probe result. When
    /// threads are present the agent row is rolled up from the best thread
    /// (running > idle > stale > unknown) so the ten-row honesty contract
    /// still holds. Truncation is a typed probeHealth reason.
    public static func attaching(
        threads: [BurnBarFleetThread],
        to result: BurnBarFleetProbeResult
    ) -> BurnBarFleetProbeResult {
        let bounded = boundThreads(threads)
        let dropped = max(0, threads.count - bounded.count)
        var health = result.health
        if dropped > 0 {
            health = BurnBarFleetProbeHealth(
                agent: health.agent,
                state: degradedHealth(
                    health.state,
                    reason: "Thread list truncated to \(BurnBarFleetThreadLimits.maxPerAgent); dropped \(dropped) older thread(s)."
                ),
                rootPath: health.rootPath,
                checkedAt: health.checkedAt
            )
        }
        guard let best = bounded.first else {
            return BurnBarFleetProbeResult(agent: result.agent, health: health, threads: [])
        }
        let lastActivity = bounded.compactMap(\.lastActivityAt).max() ?? best.lastActivityAt
        let agent = BurnBarFleetAgent(
            id: result.agent.id,
            displayName: result.agent.displayName,
            status: best.status,
            confidence: best.confidence,
            currentTask: best.currentTask ?? result.agent.currentTask,
            projectName: best.projectName ?? result.agent.projectName,
            model: best.model ?? result.agent.model,
            lastActivityAt: lastActivity,
            process: best.process,
            signals: result.agent.signals,
            note: result.agent.note
        )
        return BurnBarFleetProbeResult(agent: agent, health: health, threads: bounded)
    }

    /// Stable filesystem-safe sessionRef. Rejects empty, `.`, `..`, and
    /// path separators so inbox paths cannot escape the agent directory.
    public static func sanitizedSessionRef(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return nil }
        return trimmed
    }
}
