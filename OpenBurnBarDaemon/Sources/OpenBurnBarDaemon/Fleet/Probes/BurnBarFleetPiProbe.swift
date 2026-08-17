import OpenBurnBarKernel
import Foundation

/// Pi probe: `~/.pi/agent/sessions/<project-dir>/*.jsonl` transcript mtimes.
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §7):
/// - **Running:** newest transcript mtime fresh (< 300 s). Confidence is
///   `logHeartbeat` — no pid/state file exists for Pi, so `exactProcess` is
///   never claimed (VAL-FLEET-006).
/// - **Idle:** nothing fresh.
/// - **Stale:** newest transcript mtime beyond the 300 s window.
/// - **Repo attribution:** `--`-encoded project dir name decode (split only
///   on `--` boundaries; single hyphens inside one path component are
///   preserved).
/// - **Config files** (`models.json`, `settings.json`, `trust.json`) are
///   never a live signal; only the declared `sessions/` tree is scanned.
public struct BurnBarFleetPiProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// Transcript mtime freshness window (defaults to the pinned 300 s constant).
    public let transcriptFreshnessSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .pi,
        rootPath: String,
        transcriptFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.piTranscriptFreshnessSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.transcriptFreshnessSeconds = transcriptFreshnessSeconds
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

        let sessionsDirectory = rootURL.appendingPathComponent("agent/sessions", isDirectory: true)
        let transcripts = Self.readTranscripts(in: sessionsDirectory)

        var signals: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []
        var freshest: Date?
        var freshestProject: String?

        for transcript in transcripts {
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "log-mtime",
                    path: transcript.path,
                    detail: transcript.mtime.map { "mtime \(Int(now.timeIntervalSince($0)))s ago" } ?? "mtime unavailable"
                )
            )
            if let reason = transcript.malformedReason {
                healthReasons.append(reason)
            }
            if let mtime = transcript.mtime, freshest.map({ mtime > $0 }) ?? true {
                freshest = mtime
                freshestProject = transcript.projectName
            }
        }

        let healthState: BurnBarFleetProbeHealthState = healthReasons.isEmpty
            ? .ok
            : .degraded(reason: healthReasons.joined(separator: " "))

        return Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            transcriptFreshnessSeconds: transcriptFreshnessSeconds,
            freshest: freshest,
            freshestProject: freshestProject,
            signals: signals,
            healthState: healthState
        )
    }

    /// Classifies the row from the newest transcript mtime.
    private static func classify(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        transcriptFreshnessSeconds: TimeInterval,
        freshest: Date?,
        freshestProject: String?,
        signals: [BurnBarFleetSignalSource],
        healthState: BurnBarFleetProbeHealthState
    ) -> BurnBarFleetProbeResult {
        if let freshest, now.timeIntervalSince(freshest) <= transcriptFreshnessSeconds {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .logHeartbeat,
                projectName: freshestProject,
                lastActivityAt: freshest,
                signals: signals,
                note: "Transcript mtime heuristic; no pid registry exists for Pi.",
                healthState: healthState
            )
        }

        if let freshest {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .logHeartbeat,
                projectName: freshestProject,
                lastActivityAt: freshest,
                signals: signals,
                note: "Newest transcript mtime is beyond the freshness window.",
                healthState: healthState
            )
        }

        // Root present but no transcripts at all.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .idle,
            confidence: .logHeartbeat,
            signals: signals,
            note: "Roots present, no transcript files.",
            healthState: healthState
        )
    }

    // MARK: - Transcripts

    private struct Transcript {
        let path: String
        let mtime: Date?
        let projectName: String?
        let malformedReason: String?
    }

    /// Lists every `*.jsonl` transcript under `agent/sessions/`, one level
    /// deep (project dirs). Only the declared sessions tree is scanned.
    private static func readTranscripts(in sessionsDirectory: URL) -> [Transcript] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }

        let projectDirs: [String]
        do {
            projectDirs = try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)
        } catch {
            return [
                Transcript(
                    path: sessionsDirectory.path,
                    mtime: nil,
                    projectName: nil,
                    malformedReason: "Failed to list sessions: \(error.localizedDescription)"
                )
            ]
        }

        var transcripts: [Transcript] = []
        for projectName in projectDirs.sorted() {
            let projectURL = sessionsDirectory.appendingPathComponent(projectName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let files: [String]
            do {
                files = try FileManager.default.contentsOfDirectory(atPath: projectURL.path)
            } catch {
                transcripts.append(
                    Transcript(
                        path: projectURL.path,
                        mtime: nil,
                        projectName: Self.decodeProjectName(projectName),
                        malformedReason: "Failed to list project directory: \(error.localizedDescription)"
                    )
                )
                continue
            }

            for fileName in files.sorted() {
                guard fileName.hasSuffix(".jsonl") else { continue }
                let itemPath = projectURL.appendingPathComponent(fileName).path
                let mtime = (try? FileManager.default.attributesOfItem(atPath: itemPath))?[.modificationDate] as? Date
                transcripts.append(
                    Transcript(
                        path: itemPath,
                        mtime: mtime,
                        projectName: Self.decodeProjectName(projectName),
                        malformedReason: nil
                    )
                )
            }
        }
        return transcripts
    }

    /// Decodes a `--`-encoded Pi project dir (`--Users-albertonunez--Developer--AgentLens`
    /// → `/Users/albertonunez/Developer/AgentLens`). Split only on `--`
    /// boundaries; single hyphens inside one path component are preserved.
    /// Slugs that do not start with `--` are returned as-is.
    public static func decodeProjectName(_ slug: String) -> String? {
        guard slug.hasPrefix("--") else { return slug }
        let components = slug.components(separatedBy: "--").filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }
}
