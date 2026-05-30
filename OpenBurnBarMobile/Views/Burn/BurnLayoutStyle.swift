import SwiftUI

// MARK: - Burn Layout Style
//
// The set of visualizations a user can pick from in the Burn tab. `.cards`
// is the original default layout (provider ring strip + accordion cards +
// daily chart). The other four are alternate at-a-glance reads of the same
// quota / burn data. The selection is persisted per-device via @AppStorage
// (see `BurnView`).

enum BurnLayoutStyle: String, CaseIterable, Identifiable {
    case cards
    case constellation
    case grid
    case leaderboard
    case timeline

    var id: String { rawValue }

    /// Short segment label shown in the view switcher.
    var label: String {
        switch self {
        case .cards:         return "Cards"
        case .constellation: return "Orbit"
        case .grid:          return "Grid"
        case .leaderboard:   return "Ranked"
        case .timeline:      return "Trends"
        }
    }

    /// SF Symbol for the segment.
    var systemImage: String {
        switch self {
        case .cards:         return "rectangle.stack.fill"
        case .constellation: return "circle.grid.cross.fill"
        case .grid:          return "square.grid.2x2.fill"
        case .leaderboard:   return "chart.bar.fill"
        case .timeline:      return "chart.xyaxis.line"
        }
    }

    /// VoiceOver description for the segment.
    var accessibilityLabel: String {
        switch self {
        case .cards:         return "Cards view"
        case .constellation: return "Orbit view"
        case .grid:          return "Grid view"
        case .leaderboard:   return "Ranked spend view"
        case .timeline:      return "Spend trends view"
        }
    }

    /// Maps a persisted raw value back to a style, defaulting to `.cards` for
    /// unknown / legacy values.
    static func resolve(_ raw: String) -> BurnLayoutStyle {
        BurnLayoutStyle(rawValue: raw) ?? .cards
    }
}
