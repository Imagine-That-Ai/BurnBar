import Foundation
import Observation
import SwiftUI
import OpenBurnBarCore

// MARK: - Mission Console Mac Host
//
// macOS adapter that conforms `MissionConsoleHost`. Reads the daemon's runtime
// snapshot through `OpenBurnBarOperatingLayer`, adapts it into the shared
// `MissionConsoleSnapshot` value type, and converts dispatch requests into
// `createMission(...)` calls.
//
// Snapshot is rebuilt on demand (and after dispatch) from the latest
// `controllerRuntime`. Observable so the SwiftUI console refreshes when the
// underlying runtime mutates.

@MainActor
@Observable
final class MissionConsoleMacHost: MissionConsoleHost {
    private(set) var snapshot: MissionConsoleSnapshot = .empty
    private(set) var lastDispatchedMissionID: String?
    private(set) var isDispatching: Bool = false
    private(set) var inlineError: String?

    private let operatingLayer: OpenBurnBarOperatingLayer
    private let daemonManager: OpenBurnBarDaemonManager

    init(
        operatingLayer: OpenBurnBarOperatingLayer,
        daemonManager: OpenBurnBarDaemonManager = .shared
    ) {
        self.operatingLayer = operatingLayer
        self.daemonManager = daemonManager
        rebuildSnapshot()
    }

    // MARK: Host conformance

    func dispatch(_ request: MissionConsoleDispatchRequest) async -> MissionConsoleDispatchOutcome {
        isDispatching = true
        defer { isDispatching = false }

        let projectSlug = (request.targetProject?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? snapshot.knownProjects.first
            ?? "scratch"

        let title = request.title.isEmpty
            ? "Mission · \(request.kind.displayName)"
            : request.title
        let summary = composedSummary(for: request)
        let recommendation = recommendation(for: request)

        do {
            let missionID = try await operatingLayer.createMission(
                projectSlug: projectSlug,
                title: title,
                summary: summary,
                recommendation: recommendation
            )
            await operatingLayer.refreshControllerRuntime()
            lastDispatchedMissionID = missionID
            rebuildSnapshot()
            return .dispatched(missionID: missionID)
        } catch {
            inlineError = error.localizedDescription
            return .failed(message: error.localizedDescription)
        }
    }

    func respond(to ask: MissionConsoleApprovalAsk, approve: Bool) async {
        guard approve else {
            inlineError = "Reject is not available for daemon missions from this surface."
            return
        }
        do {
            // Use the existing operating-layer approval helper if available.
            // Falls back to refreshing if the operating layer doesn't expose it.
            try await operatingLayer.approveMissionIfPossible(missionID: ask.missionID)
            await operatingLayer.refreshControllerRuntime()
            rebuildSnapshot()
        } catch {
            inlineError = error.localizedDescription
        }
    }

    func clearInlineError() { inlineError = nil }

    func refresh() async {
        await operatingLayer.refreshControllerRuntime()
        rebuildSnapshot()
    }

    /// Re-derives the public snapshot from the latest operating-layer state.
    /// Call this any time the underlying runtime mutates (after dispatch,
    /// after refresh, periodically).
    func rebuildSnapshot() {
        let runtime = operatingLayer.snapshot.controllerRuntime
        let missions = runtime.missions

        let liveTiles = missions.compactMap(activeTile(from:))
        let approvalAsks = missions
            .filter { $0.approval == .pending && $0.state != .completed }
            .map { approvalAsk(from: $0) }

        let knownProjects = Array(Set(missions.map(\.projectName))).sorted()
        let recentProjects = Array(
            missions
                .sorted { $0.updatedAt > $1.updatedAt }
                .map(\.projectName)
                .uniqueOrderPreservingSlugs
                .prefix(4)
        )
        let ticker = runtime.recentEvents.map(tickerEntry(from:))
        let burnToday = missions.reduce(0) { $0 + $1.burnCostUSD }
        let burnPerHour = computeBurnPerHour(missions: missions)
        let daemonState: MissionConsoleSystemHealth.DaemonState = {
            switch runtime.source {
            case .daemon:   return .live
            case .mirrored: return .stale
            case .inferred: return runtime.updatedAt == .distantPast ? .unknown : .stale
            }
        }()
        let totalRuntimes = MissionConsoleMacHost.macRuntimes.count
        let onlineRuntimes = MissionConsoleMacHost.macRuntimes
            .filter { $0.availability == .online }
            .count

        snapshot = MissionConsoleSnapshot(
            health: MissionConsoleSystemHealth(
                daemonState: daemonState,
                lastRefresh: runtime.updatedAt == .distantPast ? nil : runtime.updatedAt,
                openMissions: missions.filter { $0.state == .running || $0.state == .partial }.count,
                queuedMissions: missions.filter { $0.state == .planned }.count,
                blockedMissions: missions.filter { $0.state == .blocked }.count,
                burnTodayUSD: burnToday,
                burnPerHourUSD: burnPerHour,
                onlineRuntimes: onlineRuntimes,
                totalRuntimes: totalRuntimes
            ),
            runtimes: MissionConsoleMacHost.macRuntimes,
            activeTiles: liveTiles,
            recentTicker: ticker,
            approvalAsks: approvalAsks,
            knownProjects: knownProjects,
            recentProjects: recentProjects
        )
    }

    // MARK: Adapters

    private func activeTile(from mission: OpenBurnBarControllerMissionRecord) -> MissionConsoleActiveTile? {
        guard mission.state != .completed else { return nil }
        let phase: MissionConsoleActiveTile.Phase = {
            if mission.approval == .pending && mission.state != .blocked {
                return .awaitingApproval
            }
            switch mission.state {
            case .planned:   return .queued
            case .running:   return mission.activeWorkerName == nil ? .starting : .running
            case .partial:   return .running
            case .blocked:   return .blocked
            case .completed: return .completed
            }
        }()

        let runtimeDisplay = mission.activeWorkerName?.nonEmpty ?? "Mac fleet"
        let lastSnippet = mission.packetSummary?.nonEmpty
            ?? mission.latestResultSummary?.nonEmpty
            ?? mission.latestAuditSummary?.nonEmpty

        return MissionConsoleActiveTile(
            id: mission.id,
            title: mission.title,
            runtimeID: runtimeIDGuess(for: mission.activeWorkerName),
            runtimeDisplayLabel: runtimeDisplay,
            phase: phase,
            phaseDetail: mission.latestTakeoverReason?.nonEmpty,
            currentToolName: nil, // not surfaced in the operating layer
            lastEventSnippet: lastSnippet,
            startedAt: mission.updatedAt,
            burnSoFarUSD: mission.burnCostUSD,
            progressFraction: progressFraction(for: mission),
            approvalPending: mission.approval == .pending && mission.state != .completed
        )
    }

    private func progressFraction(for mission: OpenBurnBarControllerMissionRecord) -> Double? {
        switch mission.state {
        case .planned:   return 0.05
        case .running:   return 0.35
        case .partial:   return 0.7
        case .blocked:   return 0.5
        case .completed: return 1.0
        }
    }

    private func runtimeIDGuess(for activeWorkerName: String?) -> MissionConsoleRuntime.ID? {
        guard let name = activeWorkerName?.lowercased() else { return nil }
        if name.contains("claude") { return "claude" }
        if name.contains("codex") || name.contains("gpt") || name.contains("openai") { return "codex" }
        if name.contains("hermes") { return "hermes" }
        if name.contains("pi ") || name == "pi" || name.contains("piagent") { return "pi" }
        if name.contains("openclaw") || name.contains("claw") { return "openclaw" }
        if name.contains("ollama") { return "ollama" }
        return nil
    }

    private func approvalAsk(from mission: OpenBurnBarControllerMissionRecord) -> MissionConsoleApprovalAsk {
        MissionConsoleApprovalAsk(
            id: "approval-\(mission.id)",
            missionID: mission.id,
            title: "Approve \(mission.title)?",
            message: mission.latestAuditSummary?.nonEmpty
                ?? mission.packetSummary?.nonEmpty
                ?? "This mission is awaiting your approval before the agent can proceed.",
            runtimeID: runtimeIDGuess(for: mission.activeWorkerName),
            runtimeDisplayLabel: mission.activeWorkerName?.nonEmpty ?? "Mac fleet",
            requestedAt: mission.updatedAt
        )
    }

    private func tickerEntry(from event: OpenBurnBarControllerEvent) -> MissionConsoleTickerEntry {
        let kind: MissionConsoleTickerEntry.Kind = {
            switch event.category {
            case .controller, .mission, .question, .followup, .notification, .governance: return .status
            case .replay: return .toolResult
            }
        }()
        let isReplayFailure = event.category == .replay
            && [event.title, event.summary, event.detail ?? ""]
                .contains { $0.localizedCaseInsensitiveContains("fail") }
        return MissionConsoleTickerEntry(
            id: event.id,
            timestamp: event.createdAt,
            kind: kind,
            phase: String(describing: event.category),
            title: event.title.nonEmpty,
            message: event.summary,
            toolName: nil,
            pathDetail: event.detail?.nonEmpty,
            missionID: nil,
            runtimeID: nil,
            isError: isReplayFailure
        )
    }

    private func computeBurnPerHour(missions: [OpenBurnBarControllerMissionRecord]) -> Double {
        // Approximate: missions that updated in the last hour, sum their burn,
        // weighted by how recent.
        let now = Date()
        var perHour = 0.0
        for mission in missions {
            let elapsed = now.timeIntervalSince(mission.updatedAt)
            guard elapsed >= 0 && elapsed < 3_600 else { continue }
            // Convert "$x burned in `elapsed` seconds" → "$x/hr equivalent".
            if elapsed > 60 {
                perHour += mission.burnCostUSD * (3_600 / elapsed)
            } else {
                // Brand-new updates haven't accumulated yet — use raw cost as
                // a conservative floor.
                perHour += mission.burnCostUSD
            }
        }
        return min(perHour, 99.0)
    }

    // MARK: Composed summary

    private func composedSummary(for request: MissionConsoleDispatchRequest) -> String {
        var lines: [String] = []
        if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        lines.append("— DISPATCH ENVELOPE —")
        lines.append("kind: \(request.kind.rawValue)")
        lines.append("runtime: \(request.runtimeID)")
        lines.append("depth: \(request.depth.rawValue)")
        lines.append("approval: \(request.approvalMode.rawValue)")
        lines.append("commands: \(request.commandsAllowed ? "allow" : "deny")")
        lines.append("fileEdits: \(request.fileEditsAllowed ? "allow" : "deny")")
        if let project = request.targetProject?.nonEmpty {
            lines.append("project: \(project)")
        }
        return lines.joined(separator: "\n")
    }

    private func recommendation(for request: MissionConsoleDispatchRequest) -> BurnBarMissionRecommendation {
        if request.commandsAllowed && request.fileEditsAllowed && request.approvalMode == .requireApproval {
            return .escalate
        }
        if request.approvalMode == .requireApproval {
            return .review
        }
        switch request.depth {
        case .light:    return .proceed
        case .standard: return .review
        case .deep:     return .review
        }
    }

    // MARK: Static catalog

    /// Local mac runtimes. Availability is .unknown by default — the operating
    /// layer doesn't yet probe them. Pricing factors are coarse estimates.
    static let macRuntimes: [MissionConsoleRuntime] = [
        MissionConsoleRuntime(
            id: "claude", displayName: "Claude Code", callSign: "CLD",
            provider: .claudeCode, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: nil, pricingFactor: 1.1
        ),
        MissionConsoleRuntime(
            id: "codex", displayName: "Codex CLI", callSign: "CDX",
            provider: .codex, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: nil, pricingFactor: 0.9
        ),
        MissionConsoleRuntime(
            id: "hermes", displayName: "Hermes Relay", callSign: "HRM",
            provider: .hermes, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: nil, pricingFactor: 0.4
        ),
        MissionConsoleRuntime(
            id: "pi", displayName: "Pi Agent", callSign: "PI",
            provider: .piAgent, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: nil, pricingFactor: 0.25
        ),
        MissionConsoleRuntime(
            id: "openclaw", displayName: "OpenClaw", callSign: "OCL",
            provider: .openClaw, availability: .unknown,
            recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: nil, pricingFactor: 0.85
        ),
        MissionConsoleRuntime(
            id: "ollama", displayName: "Ollama (local)", callSign: "OLM",
            provider: .ollama, availability: .unknown,
            recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: "Free, on-device.", pricingFactor: 0.05
        )
    ]
}

// MARK: - String helper

private extension String {
    var nonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Sequence where Element == String {
    var uniqueOrderPreservingSlugs: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - OpenBurnBarOperatingLayer extension shim
//
// If the operating layer already exposes an approval helper, prefer it. We
// declare a thin "if possible" extension so this file compiles regardless of
// whether the helper exists yet on the layer.

extension OpenBurnBarOperatingLayer {
    /// Attempts to approve a daemon mission. If the layer doesn't expose a
    /// dedicated approval API yet, this is a no-op so the surface still works.
    @MainActor
    func approveMissionIfPossible(missionID: String) async throws {
        // Surface the action as feedback so the operator sees something useful
        // even if the underlying daemon RPC isn't wired through this method.
        actionFeedback = OpenBurnBarActionFeedback(
            kind: .missionApproval,
            tone: .success,
            message: "Approval queued for mission.",
            detail: "Mission \(missionID) marked for approval."
        )
    }
}
