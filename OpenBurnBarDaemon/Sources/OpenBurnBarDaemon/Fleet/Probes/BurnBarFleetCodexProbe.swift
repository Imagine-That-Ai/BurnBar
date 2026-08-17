import OpenBurnBarKernel
import Foundation

/// Codex probe: `~/.codex/thread-writer-locks/*.lock` mtimes (+
/// `state_5.sqlite-wal` / `.codex-global-state.json` mtimes as corroboration).
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §3):
/// - **Running:** any lock-file mtime fresh (< 300 s). Confidence is
///   `logHeartbeat` — there is NO pid registry for Codex (the
///   `active_sessions.json` file belongs to Grok CLI), and locks may survive
///   crashes, so `exactProcess` is never claimed (VAL-FLEET-006).
/// - **Idle:** nothing fresh.
/// - **Stale:** last fresh lock mtime beyond the 300 s window.
/// - **Repo attribution:** session_index/rollout `cwd` fields when cheap to
///   read; else null. The probe reads only the declared lock directory and
///   the two corroboration file mtimes — it never crawls `sessions/`.
public struct BurnBarFleetCodexProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Lock-file mtime freshness window (defaults to the pinned 300 s constant).
    public let lockFreshnessSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .codex,
        rootPath: String,
        lockFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.codexLockFreshnessSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.lockFreshnessSeconds = lockFreshnessSeconds
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

        let locksDirectory = rootURL.appendingPathComponent("thread-writer-locks", isDirectory: true)
        let locks = Self.readLockFiles(in: locksDirectory)

        var signals: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []
        var freshestLock: Date?

        for lock in locks {
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "lock-file",
                    path: lock.path,
                    detail: lock.mtime.map { "mtime \(Int(now.timeIntervalSince($0)))s ago" } ?? "mtime unavailable"
                )
            )
            if let reason = lock.malformedReason {
                healthReasons.append(reason)
            }
            if let mtime = lock.mtime {
                freshestLock = max(freshestLock ?? mtime, mtime)
            }
        }

        // Corroboration mtimes (secondary signals; never drive the row alone).
        let corroborationPaths = [
            rootURL.appendingPathComponent("state_5.sqlite-wal").path,
            rootURL.appendingPathComponent(".codex-global-state.json").path
        ]
        var corroborationMtimes: [Date] = []
        for path in corroborationPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "log-mtime",
                    path: path,
                    detail: mtime.map { "mtime \(Int(now.timeIntervalSince($0)))s ago" } ?? "mtime unavailable"
                )
            )
            if let mtime {
                corroborationMtimes.append(mtime)
            }
        }

        let healthState: BurnBarFleetProbeHealthState = healthReasons.isEmpty
            ? .ok
            : .degraded(reason: healthReasons.joined(separator: " "))

        let classified = Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            lockFreshnessSeconds: lockFreshnessSeconds,
            freshestLock: freshestLock,
            corroborationMtimes: corroborationMtimes,
            signals: signals,
            healthState: healthState
        )
        let threads: [BurnBarFleetThread] = locks.compactMap { lock in
            guard lock.malformedReason == nil else { return nil }
            let member = BurnBarFleetProbeSupport.isThreadMember(
                liveProcess: false,
                lastActivity: lock.mtime,
                now: now,
                freshnessSeconds: lockFreshnessSeconds
            )
            guard member else { return nil }
            let stem = URL(fileURLWithPath: lock.path).deletingPathExtension().lastPathComponent
            guard let threadID = BurnBarFleetProbeSupport.sanitizedSessionRef(stem) else { return nil }
            let fresh = lock.mtime.map { now.timeIntervalSince($0) <= lockFreshnessSeconds } ?? false
            return BurnBarFleetThread(
                id: threadID,
                agentID: agentID,
                status: fresh ? .running : .stale,
                confidence: .logHeartbeat,
                lastActivityAt: lock.mtime,
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "lock-file",
                        path: lock.path,
                        detail: lock.mtime.map { "mtime \(Int(now.timeIntervalSince($0)))s ago" }
                    )
                ],
                note: "Lock-file mtime heuristic; no pid registry exists for Codex."
            )
        }
        return BurnBarFleetProbeSupport.attaching(threads: threads, to: classified)
    }

    /// Classifies the row from lock mtimes. A fresh lock drives `running`
    /// with `logHeartbeat` confidence; nothing fresh is idle; everything
    /// beyond the window is stale.
    private static func classify(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        lockFreshnessSeconds: TimeInterval,
        freshestLock: Date?,
        corroborationMtimes: [Date],
        signals: [BurnBarFleetSignalSource],
        healthState: BurnBarFleetProbeHealthState
    ) -> BurnBarFleetProbeResult {
        if let freshestLock, now.timeIntervalSince(freshestLock) <= lockFreshnessSeconds {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .logHeartbeat,
                lastActivityAt: freshestLock,
                signals: signals,
                note: "Lock-file mtime heuristic; no pid registry exists for Codex.",
                healthState: healthState
            )
        }

        let freshestCorroboration = corroborationMtimes.max()
        let freshest = max(freshestLock ?? .distantPast, freshestCorroboration ?? .distantPast)

        if freshest > .distantPast {
            if now.timeIntervalSince(freshest) <= lockFreshnessSeconds {
                // Corroboration mtime fresh but no fresh lock: no active
                // thread-writer work is claimed.
                return BurnBarFleetProbeSupport.result(
                    agentID: agentID,
                    rootPath: rootPath,
                    now: now,
                    status: .idle,
                    confidence: .logHeartbeat,
                    lastActivityAt: freshest,
                    signals: signals,
                    note: "Corroboration files fresh but no fresh thread-writer lock.",
                    healthState: healthState
                )
            }
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .logHeartbeat,
                lastActivityAt: freshest,
                signals: signals,
                note: "Last lock mtime is beyond the freshness window.",
                healthState: healthState
            )
        }

        // Root present but no lock files at all.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .idle,
            confidence: .logHeartbeat,
            signals: signals,
            note: "Roots present, no lock files.",
            healthState: healthState
        )
    }

    // MARK: - Lock files

    private struct LockFile {
        let path: String
        let mtime: Date?
        let malformedReason: String?
    }

    private static func readLockFiles(in directory: URL) -> [LockFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return [
                LockFile(
                    path: directory.path,
                    mtime: nil,
                    malformedReason: "Failed to list thread-writer-locks: \(error.localizedDescription)"
                )
            ]
        }

        var locks: [LockFile] = []
        for name in contents.sorted() {
            guard name.hasSuffix(".lock") else { continue }
            let itemPath = directory.appendingPathComponent(name).path
            let mtime = (try? FileManager.default.attributesOfItem(atPath: itemPath))?[.modificationDate] as? Date
            locks.append(LockFile(path: itemPath, mtime: mtime, malformedReason: nil))
        }
        return locks
    }
}
