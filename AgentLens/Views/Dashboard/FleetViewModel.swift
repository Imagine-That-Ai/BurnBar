import BurnBarCore
import Foundation
import Observation
import SwiftUI

// MARK: - Confidence Presentation

/// Documented confidence level → label/color mapping for the fleet dashboard
/// (VAL-DASH-024). Every level is textually labeled — never color-only — and
/// the mapping is deterministic and fixed-DTO testable.
enum FleetConfidencePresentation {
    /// Canonical textual label for a confidence level.
    static func label(for confidence: BurnBarFleetConfidence) -> String {
        switch confidence {
        case .exactProcess:
            return "Exact process"
        case .activeSessionFile:
            return "Session file"
        case .logHeartbeat:
            return "Log heartbeat"
        case .estimated:
            return "Estimated"
        case .unsupported:
            return "No live signal"
        }
    }

    /// Short badge label (fits chips and cards).
    static func shortLabel(for confidence: BurnBarFleetConfidence) -> String {
        switch confidence {
        case .exactProcess:
            return "Exact"
        case .activeSessionFile:
            return "Session"
        case .logHeartbeat:
            return "Heartbeat"
        case .estimated:
            return "Estimated"
        case .unsupported:
            return "Unsupported"
        }
    }

    /// Provenance copy for a card's accessibility label: the confidence label
    /// plus the first non-secret signal kind when one exists (VAL-DASH-027).
    static func provenance(for agent: BurnBarFleetAgent) -> String {
        let confidenceLabel = label(for: agent.confidence)
        guard let signalKind = agent.signals.first?.kind, !signalKind.isEmpty else {
            return confidenceLabel
        }
        return "\(confidenceLabel) · \(signalKind)"
    }
}

// MARK: - Fleet View Model

/// View model for the fleet dashboard (M3). Owns the `FleetService` lifecycle
/// for the view (start on appear, stop on disappear, restart on reopen) and
/// exposes typed, deterministic presentation state derived from the snapshot.
///
/// The view model never fabricates data: every row, count, and label derives
/// from the daemon snapshot (or the typed degraded state).
@MainActor
@Observable
final class FleetViewModel {
    /// The service backing this view model. Exactly one poller exists while
    /// the view is visible (VAL-DASH-015/018).
    let service: FleetService

    /// Whether the view is currently visible (drives the poller lifecycle).
    private(set) var isVisible = false

    init(service: FleetService) {
        self.service = service
    }

    /// The typed load state (loading/ready/empty/daemonDown).
    var loadState: FleetLoadState { service.loadState }

    /// The latest snapshot, if any.
    var snapshot: BurnBarFleetSnapshot? { service.loadState.snapshot }

    /// Whether the current snapshot is stale per the documented
    /// `2 * cadenceSeconds` threshold (VAL-DASH-006/009).
    var isStale: Bool { service.isStale }

    /// Snapshot age in seconds (for the stale-age display).
    var snapshotAgeSeconds: TimeInterval? { service.snapshotAgeSeconds }

    /// The snapshot cadence (seconds).
    var cadenceSeconds: Int { service.cadenceSeconds }

    /// Total running count from the snapshot.
    var runningCount: Int { snapshot?.runningCount ?? 0 }

    /// Per-provider running counts, ordered by the declared roster order.
    /// Agents with count 0 are included so the view can render explicit
    /// zero-count chips (documented rule: zero-count chips render "0").
    var countsByProvider: [(agentID: BurnBarFleetAgentID, count: Int)] {
        guard let snapshot else { return [] }
        return BurnBarFleetAgentID.declaredRoster.map { id in
            (id, snapshot.countsByAgent[id.wireValue] ?? 0)
        }
    }

    /// Agent rows in the snapshot, in payload order.
    var agents: [BurnBarFleetAgent] {
        snapshot?.agents ?? []
    }

    /// Per-repo groups from the snapshot (payload order).
    var repoGroups: [BurnBarFleetRepoGroup] {
        snapshot?.repos ?? []
    }

    /// Machine status from the snapshot.
    var machine: BurnBarMachineStatus? {
        snapshot?.machine
    }

    /// Probe health entries (payload order).
    var probeHealth: [BurnBarFleetProbeHealth] {
        snapshot?.probeHealth ?? []
    }

    /// The provider theme color for a fleet agent id (via the app's
    /// `AgentProvider` mapping — VAL-CROSS-003).
    func providerColor(for agentID: BurnBarFleetAgentID) -> SwiftUI.Color {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return DesignSystem.Colors.textMuted
        }
        return DesignSystem.Colors.primary(for: provider)
    }

    /// The provider display name for a fleet agent id.
    func providerName(for agentID: BurnBarFleetAgentID) -> String {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return agentID.wireValue
        }
        return provider.displayName
    }

    // MARK: - Lifecycle

    /// Called when the fleet view appears: starts the single poller.
    func viewAppeared() {
        isVisible = true
        service.start()
    }

    /// Called when the fleet view disappears (navigate away, window close):
    /// stops the only poller. Documented hidden-window behavior is "paused":
    /// the reopened view restarts the poller and receives its first refresh
    /// within one cadence interval plus the documented scheduling tolerance
    /// (VAL-DASH-018).
    func viewDisappeared() {
        isVisible = false
        service.stop()
    }
}
