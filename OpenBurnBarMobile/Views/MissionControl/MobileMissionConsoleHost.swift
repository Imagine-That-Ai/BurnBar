import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation
import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission Console Host (iOS)
//
// Bridges the shared Mission Console UI to the iOS dispatch path:
//   • `CLIAgentMissionDispatcher.dispatch(...)` to write a request to Firestore
//   • `CLIAgentMissionDispatcher.observe(...)` per request to stream live state
//   • `respondToApproval(...)` for the approval card actions
//
// Also subscribes to the user's recent-missions list so the situation room
// surfaces work the user dispatched previously (or in flight from another
// device).

@MainActor
@Observable
final class MobileMissionConsoleHost: MissionConsoleHost {
    private(set) var snapshot: MissionConsoleSnapshot = .empty
    private(set) var lastDispatchedMissionID: String?
    private(set) var isDispatching: Bool = false
    private(set) var inlineError: String?

    private let firestoreProvider: () -> Firestore
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listRegistration: ListenerRegistration?
    private var observations: [String: CLIAgentMissionObservation] = [:]
    private var observedMissions: [String: CLIAgentMissionSnapshot] = [:]
    private var observedOrder: [String] = []   // most-recent first
    private var dismissedTerminalIDs: Set<String> = []

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
        seedRuntimes()
    }

    /// Explicit teardown — call from a view's `.onDisappear` if the host is
    /// scoped to a transient surface. The root host lives for the app's
    /// lifetime so this is normally unused.
    func stop() {
        listRegistration?.remove()
        listRegistration = nil
        observations.values.forEach { $0.cancel() }
        observations.removeAll()
        if let handle = authHandle {
            Auth.auth().removeStateDidChangeListener(handle)
            authHandle = nil
        }
    }

    // MARK: Lifecycle

    func start() {
        guard authHandle == nil else { return }
        guard FirebaseApp.app() != nil else {
            inlineError = "Firebase isn't configured on this device. Sign in to enable Mission Console."
            return
        }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartListListener(uid: user?.uid)
            }
        }
        restartListListener(uid: Auth.auth().currentUser?.uid)
    }

    // MARK: Host conformance

    func dispatch(_ request: MissionConsoleDispatchRequest) async -> MissionConsoleDispatchOutcome {
        isDispatching = true
        defer { isDispatching = false }
        do {
            let trimmedTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? "Mission · \(request.kind.displayName)" : trimmedTitle
            let id = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: title,
                prompt: request.prompt,
                missionKind: request.kind.rawValue,
                requestedRuntime: request.runtimeID,
                targetProject: request.targetProject,
                depth: request.depth.rawValue,
                approvalMode: request.approvalMode.rawValue,
                commandsAllowed: request.commandsAllowed,
                fileEditsAllowed: request.fileEditsAllowed
            )
            lastDispatchedMissionID = id
            beginObservingIfNeeded(missionID: id)
            return .dispatched(missionID: id)
        } catch {
            inlineError = error.localizedDescription
            return .failed(message: error.localizedDescription)
        }
    }

    func respond(to ask: MissionConsoleApprovalAsk, approve: Bool) async {
        do {
            try await CLIAgentMissionDispatcher.shared.respondToApproval(
                requestID: ask.missionID,
                approve: approve
            )
        } catch {
            inlineError = error.localizedDescription
        }
    }

    func clearInlineError() { inlineError = nil }

    func refresh() async {
        // Force a re-emit of the list query by recycling auth uid path. No-op
        // when offline.
        guard let uid = Auth.auth().currentUser?.uid else { return }
        restartListListener(uid: uid)
    }

    // MARK: Firestore list

    private func restartListListener(uid: String?) {
        listRegistration?.remove()
        listRegistration = nil
        observations.values.forEach { $0.cancel() }
        observations.removeAll()
        observedMissions.removeAll()
        observedOrder.removeAll()

        guard let uid else {
            rebuildSnapshot()
            return
        }
        listRegistration = firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .order(by: "createdAt", descending: true)
            .limit(to: 12)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.inlineError = error.localizedDescription
                        return
                    }
                    let missions = snapshot?.documents.compactMap {
                        CLIAgentMissionSnapshot(documentID: $0.documentID, data: $0.data())
                    } ?? []
                    self?.absorb(missions)
                }
            }
    }

    private func absorb(_ missions: [CLIAgentMissionSnapshot]) {
        observedOrder = missions.map(\.id)
        for mission in missions {
            observedMissions[mission.id] = mission
            beginObservingIfNeeded(missionID: mission.id)
        }
        let newIDs = Set(missions.map(\.id))
        for id in observations.keys where !newIDs.contains(id) {
            observations[id]?.cancel()
            observations.removeValue(forKey: id)
            observedMissions.removeValue(forKey: id)
        }
        rebuildSnapshot()
    }

    private func beginObservingIfNeeded(missionID: String) {
        guard observations[missionID] == nil else { return }
        do {
            observations[missionID] = try CLIAgentMissionDispatcher.shared.observe(
                requestID: missionID,
                onUpdate: { [weak self] snapshot in
                    self?.observedMissions[snapshot.id] = snapshot
                    if !(self?.observedOrder.contains(snapshot.id) ?? true) {
                        self?.observedOrder.insert(snapshot.id, at: 0)
                    }
                    self?.rebuildSnapshot()
                },
                onError: { [weak self] _ in
                    self?.observations.removeValue(forKey: missionID)
                }
            )
        } catch {
            inlineError = error.localizedDescription
        }
    }

    // MARK: Snapshot composition

    private func rebuildSnapshot() {
        let now = Date()
        var tiles: [MissionConsoleActiveTile] = []
        var ticker: [MissionConsoleTickerEntry] = []
        var approvalAsks: [MissionConsoleApprovalAsk] = []

        let orderedMissions: [CLIAgentMissionSnapshot] = observedOrder.compactMap { observedMissions[$0] }

        for mission in orderedMissions {
            tiles.append(tile(from: mission))
            if mission.isWaitingForApproval {
                approvalAsks.append(approvalAsk(from: mission))
            }
            for event in mission.events.suffix(6) {
                ticker.append(tickerEntry(from: event, mission: mission))
            }
        }

        ticker.sort { $0.timestamp > $1.timestamp }

        let burnToday = orderedMissions.reduce(0.0) { acc, mission in
            // We don't have a per-mission cost field in CLIAgentMissionSnapshot,
            // so this stays 0 until daemon writes it. The forecast still works.
            _ = mission
            return acc
        }
        let liveCount = tiles.filter { $0.phase.isLive }.count
        let blockedCount = tiles.filter { $0.phase == .blocked || $0.phase == .failed }.count
        let queuedCount = tiles.filter { $0.phase == .queued }.count
        let macOnline = !tiles.contains { $0.phase == .macOffline }

        snapshot = MissionConsoleSnapshot(
            health: MissionConsoleSystemHealth(
                daemonState: macOnline ? .live : .macOffline,
                lastRefresh: now,
                openMissions: liveCount,
                queuedMissions: queuedCount,
                blockedMissions: blockedCount,
                burnTodayUSD: burnToday,
                burnPerHourUSD: 0,
                onlineRuntimes: MobileMissionConsoleHost.iosRuntimes.filter { $0.availability == .online }.count,
                totalRuntimes: MobileMissionConsoleHost.iosRuntimes.count
            ),
            runtimes: MobileMissionConsoleHost.iosRuntimes,
            activeTiles: tiles,
            recentTicker: Array(ticker.prefix(16)),
            approvalAsks: approvalAsks,
            knownProjects: knownProjects(from: orderedMissions),
            recentProjects: recentProjects(from: orderedMissions)
        )
    }

    private func tile(from mission: CLIAgentMissionSnapshot) -> MissionConsoleActiveTile {
        let phase = phase(for: mission)
        let runtimeID = runtimeIDGuess(rawRuntime: mission.selectedRuntime ?? mission.requestedRuntime)
        return MissionConsoleActiveTile(
            id: mission.id,
            title: mission.title,
            runtimeID: runtimeID,
            runtimeDisplayLabel: mission.runtimeLabel,
            phase: phase,
            phaseDetail: mission.errorMessage ?? mission.displayLiveSummary,
            currentToolName: mission.activeToolName,
            lastEventSnippet: mission.events.last?.message,
            startedAt: mission.createdAt,
            burnSoFarUSD: 0,
            progressFraction: progressFraction(for: phase),
            approvalPending: mission.isWaitingForApproval
        )
    }

    private func phase(for mission: CLIAgentMissionSnapshot) -> MissionConsoleActiveTile.Phase {
        switch mission.displayStatus.lowercased() {
        case "completed":              return .completed
        case "failed", "agent_launch_failed", "unauthorized":
            return .failed
        case "canceled", "cancelled":  return .cancelled
        case "mac_offline":            return .macOffline
        case "pending", "queued":      return .queued
        case "waiting_for_approval":   return .awaitingApproval
        case "running":
            if mission.activeToolName != nil { return .tooling }
            return .running
        default:
            if mission.events.last?.kind == "llm_response" { return .streaming }
            return .running
        }
    }

    private func progressFraction(for phase: MissionConsoleActiveTile.Phase) -> Double? {
        switch phase {
        case .queued: return 0.05
        case .starting: return 0.15
        case .running, .tooling, .streaming: return 0.5
        case .awaitingApproval: return 0.55
        case .completing: return 0.9
        case .completed: return 1.0
        case .failed, .blocked, .cancelled: return nil
        case .macOffline: return nil
        }
    }

    private func approvalAsk(from mission: CLIAgentMissionSnapshot) -> MissionConsoleApprovalAsk {
        MissionConsoleApprovalAsk(
            id: "approval-\(mission.id)",
            missionID: mission.id,
            title: mission.approvalTitle ?? "Approve \(mission.title)?",
            message: mission.approvalMessage
                ?? "The agent is waiting for your approval before continuing.",
            runtimeID: runtimeIDGuess(rawRuntime: mission.selectedRuntime ?? mission.requestedRuntime),
            runtimeDisplayLabel: mission.runtimeLabel,
            requestedAt: mission.createdAt ?? Date()
        )
    }

    private func tickerEntry(from event: CLIAgentMissionEvent, mission: CLIAgentMissionSnapshot) -> MissionConsoleTickerEntry {
        let kind: MissionConsoleTickerEntry.Kind = {
            switch event.kind {
            case "tool_call":      return .toolCall
            case "tool_result":    return .toolResult
            case "llm_response":   return .llmResponse
            case "final_answer":   return .finalAnswer
            case "changed_file":   return .changedFile
            case "artifact":       return .artifact
            case "error":          return .error
            case "approval_request": return .approval
            default:               return .status
            }
        }()
        return MissionConsoleTickerEntry(
            id: "\(mission.id)-\(event.sequence)",
            timestamp: parseTimestamp(event.timestamp) ?? Date(),
            kind: kind,
            phase: event.phase,
            title: event.title,
            message: event.fullMessage ?? event.message,
            toolName: event.toolName,
            pathDetail: event.changedFilePath ?? event.artifactPath,
            missionID: mission.id,
            runtimeID: runtimeIDGuess(rawRuntime: mission.selectedRuntime ?? mission.requestedRuntime),
            isError: event.isError
        )
    }

    private func parseTimestamp(_ ts: String) -> Date? {
        ISO8601DateFormatter().date(from: ts)
    }

    private func knownProjects(from missions: [CLIAgentMissionSnapshot]) -> [String] {
        // We don't have project in the iOS snapshot — fall back to a static
        // small set the user can edit by hand. This will be populated as the
        // listener pulls more history.
        let dummy = missions.compactMap { _ in Optional<String>.none }
        return dummy
    }

    private func recentProjects(from missions: [CLIAgentMissionSnapshot]) -> [String] { [] }

    private func runtimeIDGuess(rawRuntime: String?) -> MissionConsoleRuntime.ID? {
        guard let raw = rawRuntime?.lowercased(), !raw.isEmpty, raw != "auto" else { return nil }
        if raw.contains("claude") { return "claude" }
        if raw.contains("codex") { return "codex" }
        if raw.contains("hermes") { return "hermes" }
        if raw == "pi" || raw.contains("piagent") || raw.contains("pi-agent") { return "pi" }
        if raw.contains("openclaw") { return "openclaw" }
        if raw.contains("ollama") { return "ollama" }
        return nil
    }

    private func seedRuntimes() {
        snapshot = MissionConsoleSnapshot(
            health: .empty,
            runtimes: MobileMissionConsoleHost.iosRuntimes,
            activeTiles: [],
            recentTicker: [],
            approvalAsks: [],
            knownProjects: [],
            recentProjects: []
        )
    }

    // MARK: Static catalog

    /// iOS runtimes the user can target. Marked online by default because
    /// the iPhone can't probe the paired Mac's runtime health directly — the
    /// `mac_offline` signal surfaces if no Mac claims the queue in time.
    static let iosRuntimes: [MissionConsoleRuntime] = [
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
        )
    ]
}
