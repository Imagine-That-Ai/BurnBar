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
/// - **Idle (installed-but-inactive):** roots present with no active work —
///   an empty-but-present task ledger or background registry, only fresh
///   terminal invocations, or dead background entries. A present root with no
///   signal files at all is also idle, evidenced by the declared root itself.
/// - **Stale:** last timestamped signal beyond the 300 s window.
/// - **Status vocabulary:** invocation `status` must be one of the documented
///   non-terminal (`running`, `queued`, `pending`, `in_progress`, `active`,
///   `working`) or terminal (`completed`, `failed`, `cancelled`) strings.
///   Any other string (e.g. `"bogus"`) is malformed — it never counts as
///   non-terminal and never yields `running`.
/// - **Malformed shape:** valid JSON with a missing/mistyped required key
///   (invocation `status`/`updatedAt`, registry `pid`) or an unknown status
///   string degrades only its own path — the alternate paths still drive the
///   row, and a malformed ledger never fabricates `running`.
/// - **Pid-reuse guard:** a background entry's recorded `startTime` is
///   compared against the current process start time before `kill -0`
///   liveness (same standard as the claude-code probe); a reused pid is
///   treated as dead.
/// - **Artifacts exclusion:** the probe touches only the declared signal
///   files and the `sessions/`/`missions/` subdirectories. It NEVER reads,
///   lists, or traverses `<root>/artifacts/` (system-reserved).
/// - **Repo attribution:** for overlapping live evidence, invocation `cwd`
///   wins over background-entry `cwd`, which wins over session/mission slug
///   decode (`-Users-albertonunez-…` → `/Users/albertonunez/…`). Timestamps
///   break ties within one source only.
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

        if let rootIssue = BurnBarFleetProbeSupport.rootAccessResult(
            agentID: agentID,
            rootPath: rootPath,
            now: now
        ) {
            return rootIssue
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

        let evidence = Self.collectEvidence(
            rootPath: rootPath,
            ledger: ledger,
            background: background,
            sessionDirs: sessionDirs,
            missionDirs: missionDirs,
            now: now,
            freshnessSeconds: freshnessSeconds
        )

        return Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            freshnessSeconds: freshnessSeconds,
            evidence: evidence
        )
    }

    /// Collects every evidence source into one set: the declared root itself
    /// (root-presence, so a determined row always carries at least one
    /// evidence path — VAL-FLEET-016), the task ledger, the background
    /// registry, and the session/mission directory mtimes. Malformed sources
    /// degrade typed and never fabricate liveness.
    private static func collectEvidence(
        rootPath: String,
        ledger: Ledger?,
        background: BackgroundRegistry?,
        sessionDirs: [DirectoryFreshness],
        missionDirs: [DirectoryFreshness],
        now: Date,
        freshnessSeconds: TimeInterval
    ) -> EvidenceSet {
        var signals: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []
        var liveEvidence: [Evidence] = []
        var staleEvidence: [Evidence] = []
        var hasAnySignalFile = false

        // Root-presence evidence: the declared root itself is a signal source
        // for the installed-but-inactive state, so a determined (non-unknown)
        // row always carries at least one evidence path (VAL-FLEET-016).
        signals.append(
            BurnBarFleetSignalSource(
                kind: "root-presence",
                path: rootPath,
                detail: "Declared root present."
            )
        )

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

        return EvidenceSet(
            signals: signals,
            healthState: healthState,
            healthReasons: healthReasons,
            liveEvidence: liveEvidence,
            staleEvidence: staleEvidence,
            hasAnySignalFile: hasAnySignalFile
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
                        source: .invocation,
                        projectName: invocation.cwd,
                        lastActivityAt: invocation.updatedAt,
                        detail: "non-terminal invocation"
                    )
                )
            } else if invocation.malformedReason == nil, let updatedAt = invocation.updatedAt {
                staleEvidence.append(
                    Evidence(
                        source: .invocation,
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
                        source: .background,
                        projectName: entry.cwd,
                        lastActivityAt: entry.startTime,
                        detail: "live background process"
                    )
                )
            } else if entry.malformedReason == nil, let startTime = entry.startTime {
                staleEvidence.append(
                    Evidence(
                        source: .background,
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
                        source: kind == "session-directory" ? .session : .mission,
                        projectName: projectName,
                        lastActivityAt: directory.mtime,
                        detail: "fresh \(kind)"
                    )
                )
            } else {
                staleEvidence.append(
                    Evidence(
                        source: kind == "session-directory" ? .session : .mission,
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
        if let strongest = evidence.preferredLiveEvidence {
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
            // terminal invocations, an empty-but-present registry, or dead
            // background entries) is idle — the documented installed-but-
            // inactive state, never stale. Everything beyond the window is
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
            if freshest == nil {
                // Signal files exist but carry no timestamped evidence at
                // all: an empty-but-present registry is the documented
                // installed-but-inactive state (idle), not stale.
                return BurnBarFleetProbeSupport.result(
                    agentID: agentID,
                    rootPath: rootPath,
                    now: now,
                    status: .idle,
                    confidence: .activeSessionFile,
                    signals: evidence.signals,
                    note: "Signal files present but no timestamped evidence; installed but inactive.",
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

        // Root present but no signal files at all: installed-but-inactive.
        // The declared root itself is the evidence path (VAL-FLEET-016).
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .idle,
            confidence: .activeSessionFile,
            signals: evidence.signals,
            note: "Roots present, no signal files; installed but inactive.",
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

        var preferredLiveEvidence: Evidence? {
            let attributed = liveEvidence
                .filter { $0.projectName?.isEmpty == false }
                .min { lhs, rhs in
                    if lhs.source.priority != rhs.source.priority {
                        return lhs.source.priority < rhs.source.priority
                    }
                    return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
                }
            return attributed ?? liveEvidence.max {
                ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
            }
        }
    }

    private enum EvidenceSource {
        case invocation
        case background
        case session
        case mission

        var priority: Int {
            switch self {
            case .invocation:
                return 0
            case .background:
                return 1
            case .session, .mission:
                return 2
            }
        }
    }

    private struct Evidence {
        let source: EvidenceSource
        let projectName: String?
        let lastActivityAt: Date?
        let detail: String
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
