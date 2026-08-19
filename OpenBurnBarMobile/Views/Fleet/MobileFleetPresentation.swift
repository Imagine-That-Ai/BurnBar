import OpenBurnBarKernel
import SwiftUI

// MARK: - Mobile Fleet Presentation
//
// Faithful port of the Mac fleet dashboard's presentation logic
// (`AgentLens/Views/Dashboard/Fleet/FleetViewModel.swift`) with the design
// system swapped: `DesignSystem` colors become `MobileTheme` tokens. The
// LABELS are copied verbatim — the status/confidence vocabulary is the
// dashboard's honesty contract (documented in
// docs/fleet/BURNBAR_FLEET_SIGNALS.md) and the two platforms must not drift.
//
// Everything here is pure and fixed-DTO testable: no fabricated liveness, no
// absent metric formatted as zero, provenance carries the signal KIND only
// (never path/detail, which could bear secret material).

// MARK: - Provider identity

extension AgentProvider {
    /// Maps a fleet roster id onto the usage-surface provider used for
    /// display. Unknown/forward-compatible ids return nil. Mirrors
    /// `AgentLens/Models/AgentProvider+Fleet.swift` exactly (VAL-CROSS-003).
    init?(fleetAgentID: BurnBarFleetAgentID) {
        switch fleetAgentID {
        case .claudeCode: self = .claudeCode
        case .factoryDroid: self = .factory
        case .codex: self = .codex
        case .hermes: self = .hermes
        case .grokBot, .grokCLI: self = .xAI
        case .pi: self = .piAgent
        case .cursor: self = .cursor
        case .kimi: self = .kimi
        case .geminiCLI: self = .geminiCLI
        case .unknown: return nil
        }
    }
}

/// Provider display identity for a fleet agent id — the same name, icon, and
/// theme color the usage surface renders for the same provider.
enum FleetProviderIdentity {
    static func name(for agentID: BurnBarFleetAgentID) -> String {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return agentID.wireValue
        }
        return provider.displayName
    }

    static func iconName(for agentID: BurnBarFleetAgentID) -> String {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return "questionmark.circle"
        }
        return provider.iconName
    }

    static func color(for agentID: BurnBarFleetAgentID) -> Color {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return MobileTheme.Colors.textMuted
        }
        return MobileTheme.Colors.primary(for: provider)
    }
}

// MARK: - Confidence presentation

/// Documented confidence level → label/color mapping (VAL-DASH-024). Every
/// level is textually labeled — never color-only — and the labels match the
/// Mac's `FleetConfidencePresentation` verbatim.
enum FleetConfidencePresentation {
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

    /// The level color, mapped onto the mobile theme tokens that carry the
    /// same semantic role as the Mac's `DesignSystem` colors. All five values
    /// stay pairwise distinct; the textual label remains the primary carrier
    /// of meaning.
    static func color(for confidence: BurnBarFleetConfidence) -> Color {
        switch confidence {
        case .exactProcess:
            return MobileTheme.success
        case .activeSessionFile:
            return MobileTheme.whimsy
        case .logHeartbeat:
            return MobileTheme.warning
        case .estimated:
            return MobileTheme.blaze
        case .unsupported:
            return MobileTheme.Colors.textMuted
        }
    }

    /// Provenance copy: the confidence label plus the first non-secret signal
    /// kind when one exists (VAL-DASH-027). Only the signal KIND is used —
    /// never the path or detail, which could bear secret material.
    static func provenance(for agent: BurnBarFleetAgent) -> String {
        let confidenceLabel = label(for: agent.confidence)
        guard let signalKind = agent.signals.first?.kind, !signalKind.isEmpty else {
            return confidenceLabel
        }
        return "\(confidenceLabel) · \(signalKind)"
    }

    /// Visible per-card provenance text. Unsupported rows state that no live
    /// signal is available.
    static func provenanceLabel(for agent: BurnBarFleetAgent) -> String {
        switch agent.confidence {
        case .unsupported:
            return "No live signal"
        default:
            return provenance(for: agent)
        }
    }
}

// MARK: - Status presentation

/// Documented status → label/color mapping (VAL-DASH-025). `unknown` has its
/// own treatment, distinct from `idle` and from the empty-fleet state. Labels
/// match the Mac's `FleetStatusPresentation` verbatim.
enum FleetStatusPresentation {
    static func label(for status: BurnBarFleetAgentStatus) -> String {
        switch status {
        case .running:
            return "Running"
        case .idle:
            return "Idle"
        case .stale:
            return "Stale"
        case .unknown:
            return "Unknown"
        }
    }

    static func color(for status: BurnBarFleetAgentStatus) -> Color {
        switch status {
        case .running:
            return MobileTheme.success
        case .idle:
            return MobileTheme.Colors.textMuted
        case .stale:
            return MobileTheme.warning
        case .unknown:
            return MobileTheme.Colors.textSecondary
        }
    }
}

// MARK: - Header copy

/// Pinned header readout — the honesty surface. A missing snapshot is never
/// shown as "0 running" (VAL-DASH-028); strings match the Mac's
/// `FleetHeaderCopy` verbatim, with the transport-appropriate mapping from
/// `MobileFleetStore.State` (the Mac maps from `FleetLoadState`).
enum FleetHeaderCopy {
    enum Readout: Equatable {
        case checking
        case unavailable
        case running(Int)
    }

    static func readout(for state: MobileFleetStore.State) -> Readout {
        switch state {
        case .loading:
            return .checking
        case .macOffline:
            return .unavailable
        case .ready(let snapshot):
            return .running(snapshot.runningCount)
        case .empty(let snapshot):
            // `empty(nil)` means the mirror document exists but could not be
            // opened — there is no snapshot, so "0 running" would be invented.
            guard let snapshot else { return .unavailable }
            return .running(snapshot.runningCount)
        }
    }

    static func runningReadout(_ readout: Readout) -> String {
        switch readout {
        case .unavailable:
            return "Unavailable"
        case .checking:
            return "Checking…"
        case .running(let count):
            return "\(count) running"
        }
    }

    static func runningAccessibility(_ readout: Readout) -> String {
        switch readout {
        case .unavailable:
            return "Fleet data unavailable"
        case .checking:
            return "Checking fleet snapshot"
        case .running(let count):
            return "\(count) agents running"
        }
    }
}

// MARK: - Agent ordering

/// Card ordering for the phone's single column. The Mac renders payload order
/// because its grid shows every card at once; a phone list is read top-down,
/// so running rows are promoted. Deliberate, documented mobile divergence —
/// within each partition the daemon's payload order is preserved untouched.
enum FleetAgentOrdering {
    static func runningFirst(_ agents: [BurnBarFleetAgent]) -> [BurnBarFleetAgent] {
        let running = agents.filter { $0.status == .running }
        let rest = agents.filter { $0.status != .running }
        return running + rest
    }
}

// MARK: - Machine rows

/// One machine row (VAL-DASH-011/022/030): label, rendered value, and typed
/// unavailability. Absent optional metrics carry `value == nil` and
/// `isUnavailable == true` — the view renders "—" and the accessibility label
/// states unavailability. Absence is never formatted as 0, NaN, or a
/// current-looking value. Port of the Mac's `FleetMachineRow`.
struct FleetMachineRow: Equatable, Identifiable {
    let label: String
    let value: String?
    let isUnavailable: Bool
    let accessibilityLabel: String

    var id: String { label }

    static func rows(for machine: BurnBarMachineStatus) -> [FleetMachineRow] {
        func metric(_ label: String, _ value: String?) -> FleetMachineRow {
            FleetMachineRow(
                label: label,
                value: value,
                isUnavailable: value == nil,
                accessibilityLabel: value.map { "\(label): \($0)" } ?? "\(label): unavailable"
            )
        }
        var rows: [FleetMachineRow] = [
            metric("CPU", machine.cpuPercent.map { FleetFormatting.formatCPU($0) }),
            metric(
                "Memory",
                machine.memoryUsedBytes.map {
                    FleetFormatting.formatMemory(used: $0, total: machine.memoryTotalBytes)
                }
            ),
            metric("Load", machine.loadAverage.map { FleetFormatting.formatLoadAverage($0) }),
            metric("Disk free", machine.diskFreeBytes.map { FleetFormatting.formatDiskFree($0) })
        ]
        rows.append(sensorRow("Thermal", machine.thermal))
        rows.append(sensorRow("Power", machine.power))
        return rows
    }

    private static func sensorRow(_ label: String, _ state: BurnBarSensorState) -> FleetMachineRow {
        switch state {
        case .available(let value):
            let text = String(format: "%.1f", value)
            return FleetMachineRow(
                label: label,
                value: text,
                isUnavailable: false,
                accessibilityLabel: "\(label): \(text)"
            )
        case .unavailable(let reason):
            let text = "Unavailable (\(reason))"
            return FleetMachineRow(
                label: label,
                value: text,
                isUnavailable: true,
                accessibilityLabel: "\(label): unavailable (\(reason))"
            )
        }
    }
}

// MARK: - Repo groups

/// One per-repo group row (VAL-DASH-010): project name plus member agent ids.
/// The "No repo" bucket holds agents with nil/empty projectName — they are
/// never dropped. Port of the Mac's `FleetRepoGroupRowModel` + the bucket
/// logic from `FleetViewModel.repoGroupRows` (collapse state lives in the
/// view on mobile).
struct FleetRepoGroupRowModel: Equatable, Identifiable {
    static let noRepoBucketName = "No repo"

    let projectName: String
    let agentIDs: [BurnBarFleetAgentID]

    var id: String { projectName }
    var count: Int { agentIDs.count }

    static func rows(for snapshot: BurnBarFleetSnapshot) -> [FleetRepoGroupRowModel] {
        var rows = snapshot.repos.map { group in
            FleetRepoGroupRowModel(projectName: group.projectName, agentIDs: group.agents)
        }
        let ungrouped = snapshot.agents
            .filter { $0.projectName == nil || $0.projectName?.isEmpty == true }
            .map(\.id)
        if !ungrouped.isEmpty {
            rows.append(
                FleetRepoGroupRowModel(projectName: noRepoBucketName, agentIDs: ungrouped)
            )
        }
        return rows
    }
}

// MARK: - Formatting

/// Deterministic metric formatting with documented units — the subset of the
/// Mac's `FleetFormatting` the mobile dashboard renders. Absent values are
/// handled by the rows above (rendered "—"), never formatted as zero or NaN
/// here. Relative times use `MissionConsoleFormatting.relativeTime`, the
/// mobile app's shared idiom.
enum FleetFormatting {
    /// CPU percent with one decimal, e.g. "12.3%".
    static func formatCPU(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Load average: all three values, two decimals, joined with ", ".
    static func formatLoadAverage(_ values: [Double]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: ", ")
    }

    /// Disk free: MB below 1 GB, GB (one decimal) at or above 1 GB.
    static func formatDiskFree(_ bytes: Int) -> String {
        let clamped = max(0, bytes)
        if clamped < 1_000_000_000 {
            return String(format: "%.0f MB", Double(clamped) / 1_000_000)
        }
        return String(format: "%.1f GB", Double(clamped) / 1_000_000_000)
    }

    /// Memory used/total with consistent units: MB below 1 GB total, GB
    /// (one decimal) at or above.
    static func formatMemory(used: Int, total: Int) -> String {
        let usedClamped = max(0, used)
        let totalClamped = max(0, total)
        if totalClamped < 1_000_000_000 {
            return String(format: "%.0f MB / %.0f MB",
                          Double(usedClamped) / 1_000_000,
                          Double(totalClamped) / 1_000_000)
        }
        return String(format: "%.1f GB / %.1f GB",
                      Double(usedClamped) / 1_000_000_000,
                      Double(totalClamped) / 1_000_000_000)
    }
}
