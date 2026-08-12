import BurnBarCore
import Foundation

/// Cursor probe (partial confidence): `~/.cursor/agent-cli-state.json`
/// (`workerIdsByDisplayName`) + `~/.cursor/ai-tracking/` mtime.
///
/// Rules (docs/fleet/BURNBAR_FLEET_SIGNALS.md §8):
/// - **Running:** worker ids present AND `ai-tracking/` mtime fresh
///   (< 300 s). Confidence is `activeSessionFile` (partial) — there are no
///   pids, so `exactProcess` is never claimed (VAL-CONTRACT-017).
/// - **Idle/stale:** absent worker ids, or tracking mtime outside the
///   documented window, is `idle`/`stale` with honest partial confidence.
/// - **Malformed shape:** valid JSON with a missing/mistyped
///   `workerIdsByDisplayName`, or a worker-id VALUE that is null, a
///   non-string, or an empty string → typed `unknown`/`stale` row with a
///   `degraded` health reason — never fabricated `running`. A malformed
///   value with otherwise-fresh tracking never yields
///   `running`/`activeSessionFile` with healthy probeHealth.
/// - **Repo attribution:** the first worker-id display name (`<project> @
///   <host>`), split at ` @ `, yields the project name.
public struct BurnBarFleetCursorProbe: BurnBarFleetProbe {
    public let agentID: BurnBarFleetAgentID
    public let rootPath: String
    /// `ai-tracking/` mtime freshness window (defaults to the pinned 300 s constant).
    public let trackingFreshnessSeconds: TimeInterval
    /// Per-probe timeout for signal-file reads (VAL-FLEET-019 seam).
    public let readTimeoutSeconds: TimeInterval

    public init(
        agentID: BurnBarFleetAgentID = .cursor,
        rootPath: String,
        trackingFreshnessSeconds: TimeInterval = BurnBarFleetProbeConstants.cursorTrackingFreshnessSeconds,
        readTimeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds
    ) {
        self.agentID = agentID
        self.rootPath = rootPath
        self.trackingFreshnessSeconds = trackingFreshnessSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func probe(now: Date) async -> BurnBarFleetProbeResult {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: rootPath) else {
            return BurnBarFleetProbeSupport.missingRootResult(agentID: agentID, rootPath: rootPath, now: now)
        }

        let statePath = rootURL.appendingPathComponent("agent-cli-state.json").path
        let trackingPath = rootURL.appendingPathComponent("ai-tracking", isDirectory: true).path

        let state = Self.readState(at: statePath, timeoutSeconds: readTimeoutSeconds)
        let trackingMtime = Self.readTrackingMtime(at: trackingPath)

        var signals: [BurnBarFleetSignalSource] = []
        var healthReasons: [String] = []

        if let state {
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "session-registry",
                    path: state.path,
                    detail: state.malformedReason ?? Self.stateDetail(state)
                )
            )
            if let reason = state.malformedReason {
                healthReasons.append(reason)
            }
        }

        if let trackingMtime {
            signals.append(
                BurnBarFleetSignalSource(
                    kind: "log-mtime",
                    path: trackingPath,
                    detail: "mtime \(Int(now.timeIntervalSince(trackingMtime)))s ago"
                )
            )
        }

        let healthState: BurnBarFleetProbeHealthState = healthReasons.isEmpty
            ? .ok
            : .degraded(reason: healthReasons.joined(separator: " "))

        return Self.classify(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            trackingFreshnessSeconds: trackingFreshnessSeconds,
            state: state,
            trackingMtime: trackingMtime,
            signals: signals,
            healthState: healthState
        )
    }

    /// Classifies the row. Running requires worker ids present AND a fresh
    /// `ai-tracking/` mtime; partial confidence never becomes exactProcess.
    private static func classify(
        agentID: BurnBarFleetAgentID,
        rootPath: String,
        now: Date,
        trackingFreshnessSeconds: TimeInterval,
        state: StateSignal?,
        trackingMtime: Date?,
        signals: [BurnBarFleetSignalSource],
        healthState: BurnBarFleetProbeHealthState
    ) -> BurnBarFleetProbeResult {
        let hasWorkerIDs = state?.workerIDs.isEmpty == false
        let trackingFresh = trackingMtime.map { now.timeIntervalSince($0) <= trackingFreshnessSeconds } ?? false

        if hasWorkerIDs, trackingFresh {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .running,
                confidence: .activeSessionFile,
                projectName: state?.firstProjectName,
                lastActivityAt: trackingMtime,
                signals: signals,
                note: "Worker ids present with fresh ai-tracking mtime; no pids, partial confidence.",
                healthState: healthState
            )
        }

        if hasWorkerIDs {
            // Worker ids present but tracking stale: no active work claimed.
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .stale,
                confidence: .activeSessionFile,
                projectName: state?.firstProjectName,
                lastActivityAt: trackingMtime,
                signals: signals,
                note: "Worker ids present but ai-tracking mtime is beyond the freshness window.",
                healthState: healthState
            )
        }

        if let state, state.malformedReason != nil {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .unknown,
                confidence: .unsupported,
                signals: signals,
                note: "agent-cli-state.json malformed; status unknown.",
                healthState: healthState
            )
        }

        if let trackingMtime {
            return BurnBarFleetProbeSupport.result(
                agentID: agentID,
                rootPath: rootPath,
                now: now,
                status: .idle,
                confidence: .activeSessionFile,
                lastActivityAt: trackingMtime,
                signals: signals,
                note: "No worker ids present.",
                healthState: healthState
            )
        }

        // Root present but no signal files at all.
        return BurnBarFleetProbeSupport.result(
            agentID: agentID,
            rootPath: rootPath,
            now: now,
            status: .idle,
            confidence: .activeSessionFile,
            signals: signals,
            note: "Roots present, no signal files.",
            healthState: healthState
        )
    }

    // MARK: - Parsing

    private struct StateSignal {
        let path: String
        let workerIDs: [String]
        let firstProjectName: String?
        let malformedReason: String?
    }

    private static func readState(at path: String, timeoutSeconds: TimeInterval) -> StateSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                return StateSignal(
                    path: path,
                    workerIDs: [],
                    firstProjectName: nil,
                    malformedReason: "agent-cli-state.json is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return StateSignal(
                path: path,
                workerIDs: [],
                firstProjectName: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let rawWorkerIDs = object["workerIdsByDisplayName"] as? [String: Any] else {
            return StateSignal(
                path: path,
                workerIDs: [],
                firstProjectName: nil,
                malformedReason: "agent-cli-state.json is missing the workerIdsByDisplayName object."
            )
        }

        // Every worker-id VALUE must be a non-empty string. A null,
        // non-string, or empty value is a malformed primary signal: it
        // degrades typed and never yields running/activeSessionFile with
        // healthy probeHealth (VAL-FLEET-024).
        var workerIDs: [String] = []
        for (displayName, value) in rawWorkerIDs {
            guard let workerID = BurnBarFleetProbeJSON.stringValue(value), !workerID.isEmpty else {
                return StateSignal(
                    path: path,
                    workerIDs: [],
                    firstProjectName: nil,
                    malformedReason: "workerIdsByDisplayName contains a null, non-string, or empty worker id."
                )
            }
            workerIDs.append(displayName)
        }
        workerIDs.sort()

        let firstProjectName = workerIDs.first.map { Self.projectName(fromDisplayName: $0) } ?? nil
        return StateSignal(
            path: path,
            workerIDs: workerIDs,
            firstProjectName: firstProjectName,
            malformedReason: nil
        )
    }

    /// `<project> @ <host>` → `<project>`; display names without ` @ ` are
    /// returned as-is.
    public static func projectName(fromDisplayName displayName: String) -> String? {
        let components = displayName.components(separatedBy: " @ ")
        guard let first = components.first, !first.isEmpty else { return nil }
        return first
    }

    private static func readTrackingMtime(at path: String) -> Date? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func stateDetail(_ state: StateSignal) -> String? {
        "\(state.workerIDs.count) worker id(s)"
    }
}
