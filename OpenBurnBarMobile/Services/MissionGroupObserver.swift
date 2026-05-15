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
@Observable
final class MissionGroupObserver {
    private(set) var group: MissionGroupDocument?
    private(set) var childSnapshots: [String: CLIAgentMissionSnapshot] = [:]
    private(set) var inlineError: String?

    private var groupObservation: CLIAgentMissionObservation?
    private var childObservations: [String: CLIAgentMissionObservation] = [:]

    func start(groupID: String) {
        stop()
        do {
            groupObservation = try CLIAgentMissionDispatcher.shared.observeMissionGroup(
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

    /// Aggregate burn across all children (best-effort; nil children
    /// contribute 0).
    var aggregateBurnUSD: Double {
        childSnapshots.values.reduce(0.0) { acc, snap in
            acc + 0.0 // CLI mission snapshots don't carry burn directly today;
                      // Phase B will compute via events. Stub.
        }
    }

    private func ensureChildObservations(for group: MissionGroupDocument) {
        for child in group.childMissionIDs where childObservations[child] == nil {
            if let obs = try? CLIAgentMissionDispatcher.shared.observe(
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
        switch action {
        case .pickOne(let id):
            try? await CLIAgentMissionDispatcher.shared.mergeMissionGroup(
                groupID: group.id,
                winnerMissionID: id,
                synthesisSummary: nil
            )
        case .keepAll:
            try? await CLIAgentMissionDispatcher.shared.mergeMissionGroup(
                groupID: group.id,
                winnerMissionID: nil,
                synthesisSummary: nil
            )
        case .synthesize:
            // Phase B+: this would kick off a second-stage synthesizer
            // mission. For now we just record the user's intent.
            try? await CLIAgentMissionDispatcher.shared.mergeMissionGroup(
                groupID: group.id,
                winnerMissionID: nil,
                synthesisSummary: "Synthesizing across \(group.runtimeTokens.joined(separator: ", "))…"
            )
        }
    }
}
