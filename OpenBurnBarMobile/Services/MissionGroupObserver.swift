import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Mission Group Observer (Hermes Square §6.4)
//
// Listens to a `MissionGroupDocument` + each child mission's events. Surfaces
// rolled-up state to the UI: which children are done, which are awaiting
// approval, the latest aggregate phase, and the rolled-up burn so far.
//
// Each call to `start(groupID:)` opens N+1 listeners (group doc + each
// child mission). `stop()` removes them all. Concurrency-safe via @MainActor.

@MainActor
protocol MissionGroupDispatching: AnyObject {
    func observeMissionGroup(
        groupID: String,
        onUpdate: @escaping @MainActor (MissionGroupDocument) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation

    func observe(
        requestID: String,
        onUpdate: @escaping @MainActor (CLIAgentMissionSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation

    func fetchMissionSnapshot(requestID: String) async throws -> CLIAgentMissionSnapshot

    func dispatchMissionGroupSynthesis(
        group: MissionGroupDocument,
        childSnapshots: [String: CLIAgentMissionSnapshot]
    ) async throws -> String

    func mergeMissionGroup(
        groupID: String,
        winnerMissionID: String?,
        synthesisSummary: String?
    ) async throws
}

extension CLIAgentMissionDispatcher: MissionGroupDispatching {}

@MainActor
@Observable
final class MissionGroupObserver {
    private(set) var group: MissionGroupDocument?
    private(set) var childSnapshots: [String: CLIAgentMissionSnapshot] = [:]
    private(set) var inlineError: String?

    private let dispatcher: MissionGroupDispatching
    private var groupObservation: CLIAgentMissionObservation?
    private var childObservations: [String: CLIAgentMissionObservation] = [:]
    private var synthesisDispatchInFlightGroupIDs: Set<String> = []
    private var synthesisRequestIDByGroupID: [String: String] = [:]

    init(dispatcher: MissionGroupDispatching = CLIAgentMissionDispatcher.shared) {
        self.dispatcher = dispatcher
    }

    func start(groupID: String) {
        stop()
        do {
            groupObservation = try dispatcher.observeMissionGroup(
                groupID: groupID,
                onUpdate: { [weak self] doc in
                    self?.group = doc
                    self?.ensureChildObservations(for: doc)
                },
                onError: { [weak self] message in
                    self?.inlineError = message
                }
            )
        } catch {
            inlineError = error.localizedDescription
        }
    }

    func stop() {
        groupObservation?.cancel()
        groupObservation = nil
        for (_, obs) in childObservations { obs.cancel() }
        childObservations.removeAll()
        childSnapshots.removeAll()
        synthesisDispatchInFlightGroupIDs.removeAll()
        synthesisRequestIDByGroupID.removeAll()
        group = nil
    }

    /// Roll up child mission statuses into `MissionGroupPhase`. The Mac
    /// listener writes the authoritative phase too, but the phone derives
    /// it locally so the UI is snappy.
    var derivedPhase: MissionGroupPhase {
        guard let group else { return .queued }
        let statuses = group.childMissionIDs.compactMap { childSnapshots[$0]?.status }
        return MissionGroupPhaseReducer.reduce(childStatuses: statuses, current: group.phase)
    }

    /// Live-rolled child snapshot count by phase. Used by the
    /// `MissionFanOutGroupCard` header for "2 of 3 done" affordances
    /// without having to recompute on every render.
    var childPhaseTally: (live: Int, terminal: Int, awaitingApproval: Int) {
        var live = 0
        var terminal = 0
        var awaitingApproval = 0
        for snap in childSnapshots.values {
            if snap.isTerminal { terminal += 1 } else if snap.isWaitingForApproval {
                awaitingApproval += 1
                live += 1
            } else { live += 1 }
        }
        return (live, terminal, awaitingApproval)
    }

    private func ensureChildObservations(for group: MissionGroupDocument) {
        for child in group.childMissionIDs where childObservations[child] == nil {
            if let obs = try? dispatcher.observe(
                requestID: child,
                onUpdate: { [weak self] snap in
                    self?.childSnapshots[child] = snap
                },
                onError: { _ in /* tolerated — observer keeps going */ }
            ) {
                childObservations[child] = obs
            }
        }
    }

    /// Apply a merge choice. Updates the group doc; the next snapshot
    /// publishes back through `onUpdate`.
    func applyMerge(_ action: MissionFanOutGroupCard.MergeAction) async {
        guard let group else { return }
        do {
            switch action {
            case .pickOne(let id):
                try await dispatcher.mergeMissionGroup(
                    groupID: group.id,
                    winnerMissionID: id,
                    synthesisSummary: nil
                )
            case .keepAll:
                try await dispatcher.mergeMissionGroup(
                    groupID: group.id,
                    winnerMissionID: nil,
                    synthesisSummary: nil
                )
            case .synthesize:
                try await applySynthesisMerge(for: group)
            }
            inlineError = nil
        } catch {
            inlineError = error.localizedDescription
        }
    }

    private func applySynthesisMerge(for group: MissionGroupDocument) async throws {
        guard group.phase != .merged else { return }
        guard !synthesisDispatchInFlightGroupIDs.contains(group.id) else { return }
        synthesisDispatchInFlightGroupIDs.insert(group.id)
        defer { synthesisDispatchInFlightGroupIDs.remove(group.id) }

        let synthesisRequestID: String
        if let existingRequestID = synthesisRequestIDByGroupID[group.id] {
            synthesisRequestID = existingRequestID
        } else {
            let completeSnapshots = try await completeChildSnapshots(for: group)
            let requestID = try await dispatcher.dispatchMissionGroupSynthesis(
                group: group,
                childSnapshots: completeSnapshots
            )
            synthesisRequestIDByGroupID[group.id] = requestID
            synthesisRequestID = requestID
        }

        try await dispatcher.mergeMissionGroup(
            groupID: group.id,
            winnerMissionID: synthesisRequestID,
            synthesisSummary: "Queued synthesizer mission \(synthesisRequestID) across \(group.runtimeTokens.joined(separator: ", "))."
        )
    }

    private func completeChildSnapshots(
        for group: MissionGroupDocument
    ) async throws -> [String: CLIAgentMissionSnapshot] {
        var resolved = childSnapshots
        for missionID in group.childMissionIDs where resolved[missionID]?.isTerminal != true {
            resolved[missionID] = try await dispatcher.fetchMissionSnapshot(requestID: missionID)
        }

        let incompleteIDs = group.childMissionIDs.filter { missionID in
            guard let snapshot = resolved[missionID] else { return true }
            return !snapshot.isTerminal
        }
        guard incompleteIDs.isEmpty else {
            throw MissionGroupObserverError.childSnapshotsIncomplete(incompleteIDs)
        }
        childSnapshots = resolved
        return resolved
    }
}

private enum MissionGroupObserverError: LocalizedError {
    case childSnapshotsIncomplete([String])

    var errorDescription: String? {
        switch self {
        case let .childSnapshotsIncomplete(ids):
            return "Waiting for all child mission results before synthesis: \(ids.joined(separator: ", "))."
        }
    }
}
