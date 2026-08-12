import BurnBarCore
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
/// - **Multi-session:** one live session drives the row; dead/stale sessions
///   never mask a live one. `signals[]` reflects every session file read.
/// - **Repo attribution:** `cwd` from the live session file.
public struct BurnBarFleetClaudeCodeProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Freshness window override (defaults to the pinned 120 s constant).
    public let freshnessSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .claudeCode,
        rootPath: String,
        freshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.claudeCodeFreshnessSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.freshnessSeconds = freshnessSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let sessionsDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let sessionsPath = sessionsDirectory.path

        guard FileManager.default.fileExists(atPath: rootPath) else {
            return BurnBarFleetProbeSupport.missingRootResult(agentID: agentID, rootPath: rootPath, now: now)
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

        let parsed = Self.parseSessions(sessionFiles, in: sessionsDirectory)
        let signals = parsed.map { session in
            BurnBarFleetSignalSource(
                kind: "session-registry",
                path: session.filePath,
                detail: session.malformedReason ?? Self.signalDetail(for: session)
            )
        }
        let malformedCount = parsed.filter { $0.malformedReason != nil }.count

        // One live session drives the row: the freshest live-pid session wins.
        let liveSessions = parsed.filter { session in
            guard let pid = session.pid, session.malformedReason == nil else { return false }
            return BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: session.startedAt)
        }
        let live = liveSessions.max { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }

        if let live, let updatedAt = live.updatedAt, let livePid = live.pid {
            if now.timeIntervalSince(updatedAt) <= freshnessSeconds {
                // Running: live pid + fresh updatedAt. Malformed sibling files
                // degrade the health state but never the row's liveness.
                let healthState: BurnBarFleetProbeHealthState = malformedCount > 0
                    ? .degraded(reason: "\(malformedCount) session file(s) malformed.")
                    : .ok
                return BurnBarFleetProbeSupport.result(
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
            }
            // Live pid but stale updatedAt: freshness downgrade.
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .logHeartbeat,
                projectName: live.cwd,
                lastActivityAt: updatedAt,
                signals: signals,
                note: "Session pid is live but updatedAt is beyond the freshness window.",
                healthState: .ok
            )
        }

        return Self.classifyNoLiveSession(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            parsed: parsed,
            signals: signals,
            malformedCount: malformedCount,
            freshnessSeconds: freshnessSeconds
        )
    }

    /// Classifies the row when no session has a live pid: dead-pid freshness
    /// step-down, malformed-only unknown, or stale.
    private static func classifyNoLiveSession(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        parsed: [ParsedSession],
        signals: [BurnBarFleetSignalSource],
        malformedCount: Int,
        freshnessSeconds: TimeInterval
    ) -> BurnBarFleetProbeResult {
        let freshest = parsed
            .compactMap { $0.updatedAt }
            .max()
        let hasMalformed = malformedCount > 0

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
                healthState: hasMalformed ? .degraded(reason: "\(malformedCount) session file(s) malformed.") : .ok
            )
        }

        if hasMalformed {
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
                healthState: .degraded(reason: "\(malformedCount) session file(s) malformed.")
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
    /// the outcome of well-formed siblings.
    private static func parseSessions(_ fileNames: [String], in directory: URL) -> [ParsedSession] {
        var parsed: [ParsedSession] = []
        for fileName in fileNames {
            let filePath = directory.appendingPathComponent(fileName).path
            switch parseSessionFile(at: filePath) {
            case .success(let session):
                parsed.append(session)
            case .failure(let reason):
                parsed.append(
                    ParsedSession(
                        filePath: filePath,
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

    private static func parseSessionFile(at path: String) -> ParseOutcome {
        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSON(at: path)
            guard let dictionary = raw as? [String: Any] else {
                return .failure("Session file is not a JSON object.")
            }
            object = dictionary
        } catch {
            return .failure("Session file is not valid JSON.")
        }

        // Required keys: pid and updatedAt. Missing or mistyped → malformed.
        guard let pid = BurnBarFleetProbeJSON.integerValue(object["pid"]) else {
            return .failure("Session file is missing a numeric pid.")
        }
        guard let updatedAt = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(object["updatedAt"]) else {
            return .failure("Session file is missing a numeric updatedAt.")
        }

        return .success(
            ParsedSession(
                filePath: path,
                pid: pid,
                updatedAt: updatedAt,
                cwd: BurnBarFleetProbeJSON.stringValue(object["cwd"]),
                startedAt: BurnBarFleetProbeJSON.dateFromEpochMilliseconds(object["startedAt"]),
                malformedReason: nil
            )
        )
    }

    private static func signalDetail(for session: ParsedSession) -> String? {
        guard let pid = session.pid else { return nil }
        return "pid \(pid)"
    }
}
