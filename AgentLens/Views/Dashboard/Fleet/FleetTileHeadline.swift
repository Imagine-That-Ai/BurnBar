import OpenBurnBarKernel
import SwiftUI

/// Control Deck Fleet tile headline. The tile and tests share this mapping so
/// a missing snapshot can never render as "0 agents running".
enum FleetTileHeadline: Equatable {
    case watching
    case preparing
    case running(Int)
    case daemonDown

    static func resolved(fromSnapshot snapshot: BurnBarFleetSnapshot) -> FleetTileHeadline {
        .running(snapshot.agents.filter { $0.status == .running }.count)
    }

    static func resolved(fromError error: Error) -> FleetTileHeadline {
        if let error = error as? BurnBarFleetClientError, case .notReady = error {
            return .preparing
        }
        return .daemonDown
    }

    var label: String {
        switch self {
        case .watching:
            return "Watching…"
        case .preparing:
            return "Preparing first snapshot"
        case .running(let count):
            return count == 1 ? "1 agent running" : "\(count) agents running"
        case .daemonDown:
            return "Daemon not serving fleet yet"
        }
    }

    var tileState: ControlTileState {
        switch self {
        case .watching, .preparing:
            return .unavailable("Checking fleet…")
        case .running:
            return .on
        case .daemonDown:
            return .unavailable("Daemon not serving fleet")
        }
    }

    var chipLabel: String {
        switch self {
        case .watching, .preparing:
            return "Checking"
        case .running:
            return "Live watch"
        case .daemonDown:
            return "Unavailable"
        }
    }

    var chipTint: Color {
        switch self {
        case .running:
            return ControlKind.fleet.accent
        case .watching, .preparing:
            return DesignSystem.Colors.textSecondary
        case .daemonDown:
            return DesignSystem.Colors.warning
        }
    }
}

/// Pinned Fleet header copy. Color is secondary; these strings are the
/// honesty surface (never "0 running" before a snapshot exists).
enum FleetHeaderCopy {
    static func runningReadout(_ readout: FleetViewModel.HeaderRunningReadout) -> String {
        switch readout {
        case .unavailable:
            return "Unavailable"
        case .checking:
            return "Checking…"
        case .running(let count):
            return "\(count) running"
        }
    }

    static func runningAccessibility(_ readout: FleetViewModel.HeaderRunningReadout) -> String {
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
