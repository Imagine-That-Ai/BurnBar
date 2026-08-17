import OpenBurnBarKernel
import Foundation

/// Claude Code probe: `~/.claude/sessions/<pid>.json`, one file per live
/// session, removed on exit.
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §1):
/// - **Running:** any session file with a live pid AND `updatedAt` fresh
///   (< 120 s). Confidence `exactProcess`; process block carries the live pid.
/// - **Dead pid:** the pid is not alive (or fails the pid-reuse guard) →
///   non-running with confidence below `exactProcess` (`activeSessionFile`
///   when the file is fresh, `logHeartbeat` when stale) — never `running`.
/// - **Stale:** live pid but `updatedAt` beyond the 120 s window →
///   `stale` with `logHeartbeat` confidence.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (`pid`, `updatedAt`) → typed `unknown`/`stale` row with a `degraded`
///   health reason — never fabricated `running`.
/// - **Multi-session:** every live-pid or fresh session is a thread (cap 50).
///   The agent row rolls up from the best thread. Dead+stale files are
///   not emitted. `signals[]` still reflects every session file read.
/// - **Repo attribution:** `cwd` from the live session file.
public struct BurnBarFleetClaudeCodeProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Freshness window override (defaults to the pinned 120 s constant).
    public let freshnessSeconds: TimeInterval
    /// Per-probe timeout for signal-file reads (VAL-FLEET-019 seam).
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .claudeCode,
        rootPath: String,
        freshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.claudeCodeFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.freshnessSeconds = freshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let sessionsDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let sessionsPath = sessionsDirectory.path

        if let rootIssue = BurnBarFleetProbeSupport.rootAccessResult(
            agentID: agentID,
            rootPath: rootPath,
            now: now
        ) {
            return rootIssue
        }

        guard FileManager.default.fileExists(atPath: sessionsPath) else {
            return BurnBarFleetProbeSupport.noEvidenceResult(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                note: "No sessions directory present."
            )
        }

        let sessionFiles: [String]
        do {
            sessionFiles = try FileManager.default.contentsOfDirectory(
                atPath: sessionsPath
            ).filter { $0.hasSuffix(".json") }.sorted()
        } catch {
            let reason = "Failed to list session files: \(error.localizedDescription)"
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                note: reason,
                healthState: .failed(reason: reason)
            )
        }

        guard !sessionFiles.isEmpty else {
            return BurnBarFleetProbeSupport.noEvidenceResult(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                note: "No session files present."
            )
        }

        let parsed = Self.parseSessions(sessionFiles, in: sessionsDirectory, timeoutSeconds: readTimeoutSeconds)
        let signals = parsed.map { session in
            BurnBarFleetSignalSource(
                kind: "session-registry",
                path: session.filePath,
                detail: session.malformedReason ?? Self.signalDetail(for: session)
            )
        }
        let malformedCount = parsed.filter { $0.malformedReason != nil }.count
        let degradedReason = Self.degradedReason(parsed: parsed, malformedCount: malformedCount)

        // One live session drives the row: the freshest live-pid session wins.
        let liveSessions = parsed.filter { session in
            guard let pid = session.pid, session.malformedReason == nil else { return false }
            return BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: session.startedAt)
        }
        let live = liveSessions.max { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }

        let classified: BurnBarFleetProbeResult
        if let live, let updatedAt = live.updatedAt, let livePid = live.pid {
            if now.timeIntervalSince(updatedAt) <= freshnessSeconds {
                // Running: live pid + fresh updatedAt. Malformed sibling files
                // degrade the health state but never the row's liveness.
                let healthState: BurnBarFleetProbeHealthState = degradedReason.map { .degraded(reason: $0) } ?? .ok
                classified = BurnBarFleetProbeSupport.result(
                    agentID: agentID,
                    rootPath: rootPath,
                    now: now,
                    status: .running,
                    confidence: .exactProcess,
                    projectName: live.cwd,
                    lastActivityAt: updatedAt,
                    process: BurnBarFleetProcessInfo(pid: livePid),
                    signals: signals,
                    healthState: healthState
                )
            } else {
                // Live pid but stale updatedAt: freshness downgrade. A malformed
                // sibling file still surfaces as a typed degraded health reason —
                // malformed-signal isolation requires the degradation to be
                // visible even when another session drives the row.
                classified = BurnBarFleetProbeSupport.result(
                    agentID: agentID,
                    rootPath: rootPath,
                    now: now,
                    status: .stale,
                    confidence: .logHeartbeat,
                    projectName: live.cwd,
                    lastActivityAt: updatedAt,
                    signals: signals,
                    note: "Session pid is live but updatedAt is beyond the freshness window.",
                    healthState: degradedReason.map { .degraded(reason: $0) } ?? .ok
                )
            }
        } else {
            classified = Self.classifyNoLiveSession(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                parsed: parsed,
                signals: signals,
                degradedReason: degradedReason,
                freshnessSeconds: freshnessSeconds
            )
        }
        return Self.withThreads(
            classified,
            parsed: parsed,
            now: now,
            freshnessSeconds: freshnessSeconds
        )
    }

    /// Builds the degraded-health reason from malformed session files. The
    /// first malformed file's reason is surfaced verbatim (so a timeout or
    /// unreadable failure is visible, not hidden behind a count); when
    /// several files are malformed the count is appended.
    private static func degradedReason(parsed: [ParsedSession], malformedCount: Int) -> String? {
        guard malformedCount > 0 else { return nil }
        let firstReason = parsed.first { $0.malformedReason != nil }?.malformedReason ?? "malformed"
        if malformedCount == 1 {
            return "Session file malformed: \(firstReason)"
        }
        return "\(malformedCount) session file(s) malformed; first: \(firstReason)"
    }

    /// Classifies the row when no session has a live pid: dead-pid freshness
    /// step-down, malformed-only unknown, or stale.
    private static func classifyNoLiveSession(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        parsed: [ParsedSession],
        signals: [BurnBarFleetSignalSource],
        degradedReason: String?,
        freshnessSeconds: TimeInterval
    ) -> BurnBarFleetProbeResult {
        let freshest = parsed
            .compactMap { $0.updatedAt }
            .max()

        if let freshest, now.timeIntervalSince(freshest) <= freshnessSeconds {
            // Dead pid but the file is fresh: confidence ladder step-down.
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: freshest,
                signals: signals,
                note: "Session file present but its pid is not alive; confidence downgraded.",
                healthState: degradedReason.map { .degraded(reason: $0) } ?? .ok
            )
        }

        if let degradedReason {
            // Valid JSON with a missing/mistyped required key: typed unknown,
            // never fabricated running.
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                signals: signals,
                note: "Session file(s) present but malformed; status unknown.",
                healthState: .degraded(reason: degradedReason)
            )
        }

        // Files exist but everything is stale or dead.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .stale,
            confidence: .logHeartbeat,
            signals: signals,
            note: "Session file(s) present but stale.",
            healthState: .ok
        )
    }

    /// Parses every session file. Malformed files degrade typed and are
    /// isolated: a malformed file never fabricates liveness and never affects
    /// the outcome of well-formed siblings. Reads are bounded by the
    /// per-probe timeout (VAL-FLEET-019).
    private static func parseSessions(
        _ fileNames: [String],
        in directory: URL,
        timeoutSeconds: TimeInterval
    ) -> [ParsedSession] {
        var parsed: [ParsedSession] = []
        for fileName in fileNames {
            let filePath = directory.appendingPathComponent(fileName).path
            switch parseSessionFile(at: filePath, timeoutSeconds: timeoutSeconds) {
            case .success(let session):
                parsed.append(session)
            case .failure(let reason):
                parsed.append(
                    ParsedSession(
                        filePath: filePath,
                        sessionID: nil,
                        pid: nil,
                        updatedAt: nil,
                        cwd: nil,
                        startedAt: nil,
                        malformedReason: reason
                    )
                )
            }
        }
        return parsed
    }

    // MARK: - Parsing

    private struct ParsedSession {
        let filePath: String
        let sessionID: String?
        let pid: Int?
        let updatedAt: Date?
        let cwd: String?
        let startedAt: Date?
        let malformedReason: String?
    }

    private enum ParseOutcome {
        case success(ParsedSession)
        case failure(String)
    }

    private static func parseSessionFile(at path: String, timeoutSeconds: TimeInterval) -> ParseOutcome {
        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return .failure("Session file is not a JSON object.")
            }
            object = dictionary
        } catch {
            return .failure(BurnBarFleetProbeJSON.readFailureReason(error))
        }

        // Required keys: pid and updatedAt. Missing or mistyped → malformed.
        // The pid must be in the positive macOS pid_t range (strict helper);
        // a PRESENT-but-invalid startedAt is malformed — it is never silently
        // converted to nil and treated like an absent record (which would
        // skip the pid-reuse guard and let a live pid pass).
        guard let pid = BurnBarFleetProbeJSON.pidValue(object["pid"]) else {
            let reason = BurnBarFleetProbeJSON.pidRejectionReason(object["pid"])
                ?? "Session file is missing a numeric pid."
            return .failure(reason)
        }
        guard let updatedAt = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(object["updatedAt"]) else {
            return .failure("Session file is missing a numeric updatedAt.")
        }

        let startedAtOutcome = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(object["startedAt"])
        guard case .invalid(let reason) = startedAtOutcome else {
            let startedAt: Date?
            if case .valid(let date) = startedAtOutcome {
                startedAt = date
            } else {
                startedAt = nil
            }
            let sessionID = BurnBarFleetProbeJSON.stringValue(object["sessionId"])
                ?? BurnBarFleetProbeJSON.stringValue(object["session_id"])
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return .success(
                ParsedSession(
                    filePath: path,
                    sessionID: sessionID,
                    pid: pid,
                    updatedAt: updatedAt,
                    cwd: BurnBarFleetProbeJSON.stringValue(object["cwd"]),
                    startedAt: startedAt,
                    malformedReason: nil
                )
            )
        }
        return .failure("Session file startedAt is malformed: \(reason)")
    }

    private static func signalDetail(for session: ParsedSession) -> String? {
        guard let pid = session.pid else { return nil }
        return "pid \(pid)"
    }

    private static func withThreads(
        _ result: BurnBarFleetProbeResult,
        parsed: [ParsedSession],
        now: Date,
        freshnessSeconds: TimeInterval
    ) -> BurnBarFleetProbeResult {
        var threads: [BurnBarFleetThread] = []
        for session in parsed where session.malformedReason == nil {
            guard let pid = session.pid else { continue }
            let live = BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: session.startedAt)
            let member = BurnBarFleetProbeSupport.isThreadMember(
                liveProcess: live,
                lastActivity: session.updatedAt,
                now: now,
                freshnessSeconds: freshnessSeconds
            )
            guard member else { continue }
            guard let threadID = threadID(for: session) else { continue }
            let status: BurnBarFleetAgentStatus
            let confidence: BurnBarFleetConfidence
            let process: BurnBarFleetProcessInfo?
            let note: String?
            if live, let updatedAt = session.updatedAt, now.timeIntervalSince(updatedAt) <= freshnessSeconds {
                status = .running
                confidence = .exactProcess
                process = BurnBarFleetProcessInfo(pid: pid)
                note = nil
            } else if live {
                status = .stale
                confidence = .logHeartbeat
                process = nil
                note = "Session pid is live but updatedAt is beyond the freshness window."
            } else {
                status = .stale
                confidence = .activeSessionFile
                process = nil
                note = "Session file present but its pid is not alive; confidence downgraded."
            }
            threads.append(
                BurnBarFleetThread(
                    id: threadID,
                    agentID: result.agent.id,
                    status: status,
                    confidence: confidence,
                    projectName: session.cwd,
                    lastActivityAt: session.updatedAt,
                    process: process,
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "session-registry",
                            path: session.filePath,
                            detail: signalDetail(for: session)
                        )
                    ],
                    note: note
                )
            )
        }
        return BurnBarFleetProbeSupport.attaching(threads: threads, to: result)
    }

    private static func threadID(for session: ParsedSession) -> String? {
        if let sessionID = session.sessionID,
           let sanitized = BurnBarFleetProbeSupport.sanitizedSessionRef(sessionID) {
            return sanitized
        }
        let stem = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        return BurnBarFleetProbeSupport.sanitizedSessionRef(stem)
    }
}
