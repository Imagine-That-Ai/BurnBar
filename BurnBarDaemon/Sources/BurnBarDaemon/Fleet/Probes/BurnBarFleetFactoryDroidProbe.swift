import BurnBarCore
import Foundation

/// Factory Droid probe: task ledger + background-process registry + session
/// directory mtimes. Confidence is `activeSessionFile` by design — there is
/// no pid registry for Factory Droid, so `exactProcess` is never claimed.
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §2):
/// - **Running:** a non-terminal invocation with `updatedAt` fresh (< 300 s),
///   OR a live background-process entry, OR a session/mission directory
///   mtime fresh (< 300 s).
/// - **Idle:** roots present, nothing fresh (or only fresh terminal
///   invocations — no active work).
/// - **Stale:** last signal beyond the 300 s window.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (invocation `status`/`updatedAt`, registry `pid`) degrades only its own
///   path — the alternate paths still drive the row, and a malformed ledger
///   never fabricates `running`.
/// - **Artifacts exclusion:** the probe touches only the declared signal
///   files and the `sessions/`/`missions/` subdirectories. It NEVER reads,
///   lists, or traverses `<root>/artifacts/` (system-reserved).
/// - **Repo attribution:** invocation `cwd`, else background-entry `cwd`,
///   else session-dir slug decode (`-Users-albertonunez-…` →
///   `/Users/albertonunez/…`).
public struct BurnBarFleetFactoryDroidProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Freshness window override (defaults to the pinned 300 s constant).
    public let freshnessSeconds: TimeInterval
    /// Per-probe timeout for signal-file reads (VAL-FLEET-019 seam).
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .factoryDroid,
        rootPath: String,
        freshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.factoryDroidFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.freshnessSeconds = freshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: rootPath) else {
            return BurnBarFleetProbeSupport.missingRootResult(agentID: agentID, rootPath: rootPath, now: now)
        }

        // 1. Task ledger.
        let ledger = Self.readLedger(
            at: rootURL.appendingPathComponent("task-invocations.json").path,
            timeoutSeconds: readTimeoutSeconds
        )

        // 2. Background-process registry.
        let background = Self.readBackgroundProcesses(
            at: rootURL.appendingPathComponent("background-processes.json").path,
            timeoutSeconds: readTimeoutSeconds
        )

        // 3. Session + mission directory mtimes. Only the declared
        // subdirectories are listed; artifacts/ is never touched.
        let sessionDirs = Self.readDirectoryFreshness(
            at: rootURL.appendingPathComponent("sessions", isDirectory: true).path
        )
        let missionDirs = Self.readDirectoryFreshness(
            at: rootURL.appendingPathComponent("missions", isDirectory: true).path
        )

        var signals: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []
        var liveEvidence: [Evidence] = []
        var staleEvidence: [Evidence] = []
        var hasAnySignalFile = false

        if let ledger {
            hasAnySignalFile = true
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "task-ledger",
                    path: ledger.path,
                    detail: ledger.malformedReason ?? "\(ledger.invocations.count) invocation(s)"
                )
            )
            if let reason = ledger.malformedReason {
                healthReasons.append(reason)
            }
            Self.collectInvocationEvidence(
                ledger.invocations,
                now: now,
                freshnessSeconds: freshnessSeconds,
                liveEvidence: &liveEvidence,
                staleEvidence: &staleEvidence
            )
        }

        if let background {
            hasAnySignalFile = true
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "process-list",
                    path: background.path,
                    detail: background.malformedReason ?? "\(background.entries.count) entry(ies)"
                )
            )
            if let reason = background.malformedReason {
                healthReasons.append(reason)
            }
            Self.collectBackgroundEvidence(
                background.entries,
                liveEvidence: &liveEvidence,
                staleEvidence: &staleEvidence
            )
        }

        Self.collectDirectoryEvidence(
            sessionDirs,
            kind: "session-directory",
            now: now,
            freshnessSeconds: freshnessSeconds,
            signals: &signals,
            liveEvidence: &liveEvidence,
            staleEvidence: &staleEvidence,
            hasAnySignalFile: &hasAnySignalFile
        )
        Self.collectDirectoryEvidence(
            missionDirs,
            kind: "mission-directory",
            now: now,
            freshnessSeconds: freshnessSeconds,
            signals: &signals,
            liveEvidence: &liveEvidence,
            staleEvidence: &staleEvidence,
            hasAnySignalFile: &hasAnySignalFile
        )

        let healthState: BurnBarFleetProbeHealthState = healthReasons.isEmpty
            ? .ok
            : .degraded(reason: healthReasons.joined(separator: " "))

        let evidence = EvidenceSet(
            signals: signals,
            healthState: healthState,
            healthReasons: healthReasons,
            liveEvidence: liveEvidence,
            staleEvidence: staleEvidence,
            hasAnySignalFile: hasAnySignalFile
        )

        return Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            freshnessSeconds: freshnessSeconds,
            evidence: evidence
        )
    }

    /// Collects invocation evidence: live non-terminal fresh invocations are
    /// live evidence; well-formed non-live invocations are stale evidence.
    private static func collectInvocationEvidence(
        _ invocations: [Invocation],
        now: Date,
        freshnessSeconds: TimeInterval,
        liveEvidence: inout [Evidence],
        staleEvidence: inout [Evidence]
    ) {
        for invocation in invocations {
            if invocation.isLive(now: now, freshnessSeconds: freshnessSeconds) {
                liveEvidence.append(
                    Evidence(
                        projectName: invocation.cwd,
                        lastActivityAt: invocation.updatedAt,
                        detail: "non-terminal invocation"
                    )
                )
            } else if invocation.malformedReason == nil, let updatedAt = invocation.updatedAt {
                staleEvidence.append(
                    Evidence(
                        projectName: invocation.cwd,
                        lastActivityAt: updatedAt,
                        detail: "invocation"
                    )
                )
            }
        }
    }

    /// Collects background-process evidence: live pids are live evidence;
    /// well-formed non-live entries are stale evidence.
    private static func collectBackgroundEvidence(
        _ entries: [BackgroundEntry],
        liveEvidence: inout [Evidence],
        staleEvidence: inout [Evidence]
    ) {
        for entry in entries {
            if entry.isLive {
                liveEvidence.append(
                    Evidence(
                        projectName: entry.cwd,
                        lastActivityAt: entry.startTime,
                        detail: "live background process"
                    )
                )
            } else if entry.malformedReason == nil, let startTime = entry.startTime {
                staleEvidence.append(
                    Evidence(
                        projectName: entry.cwd,
                        lastActivityAt: startTime,
                        detail: "background process"
                    )
                )
            }
        }
    }

    /// Collects directory-mtime evidence (sessions or missions). Only the
    /// declared subdirectories are listed; artifacts/ is never touched.
    private static func collectDirectoryEvidence(
        _ directories: [DirectoryFreshness],
        kind: String,
        now: Date,
        freshnessSeconds: TimeInterval,
        signals: inout [BurnBarFleetSignalSource],
        liveEvidence: inout [Evidence],
        staleEvidence: inout [Evidence],
        hasAnySignalFile: inout Bool
    ) {
        for directory in directories {
            hasAnySignalFile = true
            let projectName = kind == "session-directory" ? Self.slugDecode(directory.name) : nil
            signals.append(
                BurnBarFleetSignalSource(
                    kind: kind,
                    path: directory.path,
                    detail: projectName.map { "mtime \($0)" } ?? "mtime"
                )
            )
            if directory.isFresh(now: now, freshnessSeconds: freshnessSeconds) {
                liveEvidence.append(
                    Evidence(
                        projectName: projectName,
                        lastActivityAt: directory.mtime,
                        detail: "fresh \(kind)"
                    )
                )
            } else {
                staleEvidence.append(
                    Evidence(
                        projectName: projectName,
                        lastActivityAt: directory.mtime,
                        detail: kind
                    )
                )
            }
        }
    }

    /// Classifies the row from the collected evidence: one live signal drives
    /// running; fresh-but-no-active-work is idle; all-stale is stale;
    /// malformed-only is typed unknown — never fabricated running.
    private static func classify(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        freshnessSeconds: TimeInterval,
        evidence: EvidenceSet
    ) -> BurnBarFleetProbeResult {
        // One live signal drives the row.
        if let strongest = evidence.liveEvidence.max(by: {
            ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
        }) {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .activeSessionFile,
                projectName: strongest.projectName,
                lastActivityAt: strongest.lastActivityAt,
                signals: evidence.signals,
                healthState: evidence.healthState
            )
        }

        if evidence.hasAnySignalFile {
            // Evidence files exist. Fresh-but-no-active-work (e.g. only fresh
            // terminal invocations) is idle; everything beyond the window is
            // stale. When every signal is malformed and no usable evidence
            // remains, the row is typed unknown — never fabricated running.
            let freshest = evidence.staleEvidence.compactMap { $0.lastActivityAt }.max()
            if let freshest, now.timeIntervalSince(freshest) <= freshnessSeconds {
                return BurnBarFleetProbeSupport.result(
                    agentID: agentID,
                    rootPath: rootPath,
                    now: now,
                    status: .idle,
                    confidence: .activeSessionFile,
                    lastActivityAt: freshest,
                    signals: evidence.signals,
                    note: "Signal files present but no active work.",
                    healthState: evidence.healthState
                )
            }
            if freshest == nil, !evidence.healthReasons.isEmpty {
                return BurnBarFleetProbeSupport.result(
                    agentID: agentID,
                    rootPath: rootPath,
                    now: now,
                    status: .unknown,
                    confidence: .unsupported,
                    signals: evidence.signals,
                    note: "Signal files present but malformed; status unknown.",
                    healthState: evidence.healthState
                )
            }
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                lastActivityAt: freshest,
                signals: evidence.signals,
                note: "Last signal is beyond the freshness window.",
                healthState: evidence.healthState
            )
        }

        // Root present but no signal files at all.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .idle,
            confidence: .unsupported,
            signals: evidence.signals,
            note: "Roots present, no signal files.",
            healthState: evidence.healthState
        )
    }

    // MARK: - Evidence

    /// Collected evidence for one probe run, passed to the classifier.
    private struct EvidenceSet {
        let signals: [BurnBarFleetSignalSource]
        let healthState: BurnBarFleetProbeHealthState
        let healthReasons: [String]
        let liveEvidence: [Evidence]
        let staleEvidence: [Evidence]
        let hasAnySignalFile: Bool
    }

    private struct Evidence {
        let projectName: String?
        let lastActivityAt: Date?
        let detail: String
    }

    // MARK: - Task ledger

    private struct Ledger {
        let path: String
        let invocations: [Invocation]
        let malformedReason: String?
    }

    private struct Invocation {
        let cwd: String?
        let updatedAt: Date?
        let status: String?
        let malformedReason: String?

        /// A non-terminal invocation with a fresh `updatedAt` is live
        /// evidence. Terminal statuses are exactly the documented set;
        /// anything else (including unknown strings) is non-terminal.
        var isNonTerminal: Bool {
            guard let status else { return false }
            return !["completed", "failed", "cancelled"].contains(status)
        }

        func isLive(now: Date, freshnessSeconds: TimeInterval) -> Bool {
            guard malformedReason == nil, isNonTerminal, let updatedAt else { return false }
            return now.timeIntervalSince(updatedAt) <= freshnessSeconds
        }
    }

    private static func readLedger(at path: String, timeoutSeconds: TimeInterval) -> Ledger? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                let reason = "task-invocations.json is not a JSON object."
                return Ledger(path: path, invocations: [], malformedReason: reason)
            }
            object = dictionary
        } catch {
            let reason = BurnBarFleetProbeJSON.readFailureReason(error)
            return Ledger(path: path, invocations: [], malformedReason: reason)
        }

        guard let rawInvocations = object["invocations"] as? [[String: Any]] else {
            let reason = "task-invocations.json is missing the invocations array."
            return Ledger(path: path, invocations: [], malformedReason: reason)
        }

        var invocations: [Invocation] = []
        var malformedCount = 0
        for raw in rawInvocations {
            let status = BurnBarFleetProbeJSON.stringValue(raw["status"])
            let updatedAt = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(raw["updatedAt"])
            let cwd = BurnBarFleetProbeJSON.stringValue(raw["cwd"])
            if status == nil || updatedAt == nil {
                malformedCount += 1
                invocations.append(
                    Invocation(
                        cwd: cwd,
                        updatedAt: updatedAt,
                        status: status,
                        malformedReason: "Invocation is missing a string status or numeric updatedAt."
                    )
                )
            } else {
                invocations.append(
                    Invocation(cwd: cwd, updatedAt: updatedAt, status: status, malformedReason: nil)
                )
            }
        }

        let reason = malformedCount > 0 ? "\(malformedCount) invocation(s) malformed." : nil
        return Ledger(path: path, invocations: invocations, malformedReason: reason)
    }

    // MARK: - Background processes

    private struct BackgroundRegistry {
        let path: String
        let entries: [BackgroundEntry]
        let malformedReason: String?
    }

    private struct BackgroundEntry {
        let pid: Int?
        let cwd: String?
        let startTime: Date?
        let malformedReason: String?

        var isLive: Bool {
            guard malformedReason == nil, let pid else { return false }
            return BurnBarFleetProcessLiveness.isAlive(pid: pid)
        }
    }

    private static func readBackgroundProcesses(at path: String, timeoutSeconds: TimeInterval) -> BackgroundRegistry? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                let reason = "background-processes.json is not a JSON object."
                return BackgroundRegistry(path: path, entries: [], malformedReason: reason)
            }
            object = dictionary
        } catch {
            let reason = BurnBarFleetProbeJSON.readFailureReason(error)
            return BackgroundRegistry(path: path, entries: [], malformedReason: reason)
        }

        guard let rawEntries = object["processes"] as? [[String: Any]] else {
            let reason = "background-processes.json is missing the processes array."
            return BackgroundRegistry(path: path, entries: [], malformedReason: reason)
        }

        var entries: [BackgroundEntry] = []
        var malformedCount = 0
        for raw in rawEntries {
            let pid = BurnBarFleetProbeJSON.integerValue(raw["pid"])
            let cwd = BurnBarFleetProbeJSON.stringValue(raw["cwd"])
            let startTime = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(raw["startTime"])
            if pid == nil {
                malformedCount += 1
                let reason = "Entry is missing a numeric pid."
                entries.append(
                    BackgroundEntry(pid: nil, cwd: cwd, startTime: startTime, malformedReason: reason)
                )
            } else {
                entries.append(BackgroundEntry(pid: pid, cwd: cwd, startTime: startTime, malformedReason: nil))
            }
        }

        let reason = malformedCount > 0 ? "\(malformedCount) background entry(ies) malformed." : nil
        return BackgroundRegistry(path: path, entries: entries, malformedReason: reason)
    }

    // MARK: - Session / mission directories

    private struct DirectoryFreshness {
        let path: String
        let name: String
        let mtime: Date?

        func isFresh(now: Date, freshnessSeconds: TimeInterval) -> Bool {
            guard let mtime else { return false }
            return now.timeIntervalSince(mtime) <= freshnessSeconds
        }
    }

    private static func readDirectoryFreshness(at path: String) -> [DirectoryFreshness] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return []
        }

        var result: [DirectoryFreshness] = []
        for name in contents {
            let itemPath = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: itemPath))?[.modificationDate] as? Date
            result.append(DirectoryFreshness(path: itemPath, name: name, mtime: mtime))
        }
        return result
    }

    /// Decodes a factory session-dir slug (`-Users-albertonunez-Developer-AgentLens`
    /// → `/Users/albertonunez/Developer/AgentLens`). Slugs that do not start
    /// with `-` are returned as-is.
    public static func slugDecode(_ slug: String) -> String? {
        guard slug.hasPrefix("-") else { return slug }
        let components = slug.dropFirst().split(separator: "-").map(String.init)
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }
}
