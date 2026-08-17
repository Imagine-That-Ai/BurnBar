import OpenBurnBarKernel
import Foundation

/// Grok CLI probe: `~/.grok/active_sessions.json` (+ `active_sessions.lock`).
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §6):
/// - **Running:** an entry with a live pid → `running` + `exactProcess`.
/// - **Pid dead but file fresh:** non-running with confidence exactly
///   `activeSessionFile` — never `running`, never `exactProcess`, never
///   collapsed to `unsupported`.
/// - **Empty/absent file:** `idle`/`unknown`.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (`pid`, `session_id`, `cwd`) → typed `unknown`/`stale` row with a
///   `degraded` health reason — never fabricated `running`.
/// - **Multi-session:** one live entry drives the row; dead entries never
///   mask a live one. `signals[]` reflects every entry read.
/// - **Repo attribution:** `cwd` from the live entry.
public struct BurnBarFleetGrokCLIProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Registry-file freshness window (defaults to the pinned 300 s constant).
    public let fileFreshnessSeconds: TimeInterval
    /// Per-probe timeout for signal-file reads (VAL-FLEET-019 seam).
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .grokCLI,
        rootPath: String,
        fileFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.grokCLIFileFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.fileFreshnessSeconds = fileFreshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let registryPath = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("active_sessions.json")
            .path

        if let rootIssue = BurnBarFleetProbeSupport.rootAccessResult(
            agentID: agentID,
            rootPath: rootPath,
            now: now
        ) {
            return rootIssue
        }

        guard FileManager.default.fileExists(atPath: registryPath) else {
            // Idle rule: file absent → idle/unknown (never running).
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .idle,
                confidence: .activeSessionFile,
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "session-registry",
                        path: registryPath,
                        detail: "Registry file absent."
                    )
                ],
                note: "Registry file absent.",
                healthState: .ok
            )
        }

        let fileMtime: Date?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: registryPath)
            fileMtime = attributes[.modificationDate] as? Date
        } catch {
            fileMtime = nil
        }

        let entries: [ParsedEntry]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: registryPath, timeoutSeconds: readTimeoutSeconds)
            guard let array = raw as? [[String: Any]] else {
                let reason = "active_sessions.json is not a JSON array."
                return degradedResult(
                    now: now,
                    registryPath: registryPath,
                    fileMtime: fileMtime,
                    reason: reason
                )
            }
            entries = array.map { Self.parseEntry($0, at: registryPath) }
        } catch {
            let reason = BurnBarFleetProbeJSON.readFailureReason(error)
            return degradedResult(
                now: now,
                registryPath: registryPath,
                fileMtime: fileMtime,
                reason: reason
            )
        }

        let signals = entries.map { entry in
            BurnBarFleetSignalSource(
                kind: "session-registry",
                path: entry.filePath,
                detail: entry.malformedReason ?? Self.signalDetail(for: entry)
            )
        }

        // One live entry drives the row.
        let liveEntries = entries.filter { entry in
            guard let pid = entry.pid, entry.malformedReason == nil else { return false }
            return BurnBarFleetProcessLiveness.isAlive(pid: pid)
        }
        let live = liveEntries.max { lhs, rhs in
            (lhs.openedAt ?? .distantPast) < (rhs.openedAt ?? .distantPast)
        }

        if let live, let pid = live.pid {
            // Malformed sibling entries degrade the health state but never
            // the row's liveness.
            let healthState: BurnBarFleetProbeHealthState = Self.degradedReason(entries: entries)
                .map { .degraded(reason: $0) } ?? .ok
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .exactProcess,
                projectName: live.cwd,
                lastActivityAt: live.openedAt,
                process: BurnBarFleetProcessInfo(pid: pid),
                signals: signals,
                healthState: healthState
            )
        }

        return Self.classifyNoLiveEntry(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            entries: entries,
            signals: signals,
            fileMtime: fileMtime,
            fileFreshnessSeconds: fileFreshnessSeconds
        )
    }

    /// Classifies the row when no entry has a live pid: empty → idle,
    /// fresh-file → activeSessionFile step-down, malformed-only → unknown,
    /// stale file → stale.
    private static func classifyNoLiveEntry(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        entries: [ParsedEntry],
        signals: [BurnBarFleetSignalSource],
        fileMtime: Date?,
        fileFreshnessSeconds: TimeInterval
    ) -> BurnBarFleetProbeResult {
        let hasMalformed = entries.contains { $0.malformedReason != nil }
        let malformedCount = entries.filter { $0.malformedReason != nil }.count

        if entries.isEmpty {
            // Empty registry: idle (never running).
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .idle,
                confidence: .activeSessionFile,
                signals: signals,
                note: "Registry file present but empty.",
                healthState: .ok
            )
        }

        if let fileMtime, now.timeIntervalSince(fileMtime) <= fileFreshnessSeconds {
            // Pid dead but the file is fresh: confidence ladder step-down to
            // activeSessionFile — never running, never exactProcess.
            let healthState: BurnBarFleetProbeHealthState = Self.degradedReason(entries: entries)
                .map { .degraded(reason: $0) } ?? .ok
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: fileMtime,
                signals: signals,
                note: "Registry file is fresh but no entry has a live pid; confidence downgraded.",
                healthState: healthState
            )
        }

        if hasMalformed {
            let reason = Self.degradedReason(entries: entries) ?? "\(malformedCount) entry(ies) malformed."
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                signals: signals,
                note: "Registry entries malformed; status unknown.",
                healthState: .degraded(reason: reason)
            )
        }

        // Entries exist but the file is stale and no pid is live.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .stale,
            confidence: .activeSessionFile,
            signals: signals,
            note: "Registry file present but stale.",
            healthState: .ok
        )
    }

    // MARK: - Parsing

    /// Builds the degraded-health reason from malformed registry entries.
    /// The first malformed entry's reason is surfaced verbatim (so the
    /// offending pid is visible, not hidden behind a count); when several
    /// entries are malformed the count is appended.
    private static func degradedReason(entries: [ParsedEntry]) -> String? {
        let malformed = entries.filter { $0.malformedReason != nil }
        guard !malformed.isEmpty else { return nil }
        let firstReason = malformed.first?.malformedReason ?? "malformed"
        if malformed.count == 1 {
            return "Entry malformed: \(firstReason)"
        }
        return "\(malformed.count) entries malformed; first: \(firstReason)"
    }

    private struct ParsedEntry {
        let filePath: String
        let pid: Int?
        let cwd: String?
        let openedAt: Date?
        let malformedReason: String?
    }

    private static func parseEntry(_ object: [String: Any], at path: String) -> ParsedEntry {
        // Required keys: pid, session_id, cwd. Missing or mistyped → malformed.
        // The pid must be in the positive macOS pid_t range (strict helper).
        guard let pid = BurnBarFleetProbeJSON.pidValue(object["pid"]) else {
            let reason = BurnBarFleetProbeJSON.pidRejectionReason(object["pid"])
                ?? "Entry is missing a numeric pid."
            return ParsedEntry(
                filePath: path,
                pid: nil,
                cwd: nil,
                openedAt: nil,
                malformedReason: reason
            )
        }
        guard BurnBarFleetProbeJSON.stringValue(object["session_id"]) != nil else {
            return ParsedEntry(
                filePath: path,
                pid: nil,
                cwd: nil,
                openedAt: nil,
                malformedReason: "Entry is missing a session_id."
            )
        }
        guard let cwd = BurnBarFleetProbeJSON.stringValue(object["cwd"]) else {
            return ParsedEntry(
                filePath: path,
                pid: nil,
                cwd: nil,
                openedAt: nil,
                malformedReason: "Entry is missing a cwd."
            )
        }

        let openedAt: Date?
        if let raw = object["opened_at"] as? String {
            openedAt = ISO8601DateFormatter().date(from: raw)
        } else {
            openedAt = nil
        }

        return ParsedEntry(filePath: path, pid: pid, cwd: cwd, openedAt: openedAt, malformedReason: nil)
    }

    private func degradedResult(
        now: Date,
        registryPath: String,
        fileMtime: Date?,
        reason: String
    ) -> BurnBarFleetProbeResult {
        let signal = BurnBarFleetSignalSource(kind: "session-registry", path: registryPath, detail: reason)
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .unknown,
            confidence: .unsupported,
            lastActivityAt: fileMtime,
            signals: [signal],
            note: reason,
            healthState: .degraded(reason: reason)
        )
    }

    private static func signalDetail(for entry: ParsedEntry) -> String? {
        guard let pid = entry.pid else { return nil }
        return "pid \(pid)"
    }
}
