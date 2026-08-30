import SwiftUI

// MARK: - Home view modes
//
// Each region of the Home surface picks its own presentation, persisted
// independently.
//
// These follow `QuotaViewMode`, not `DashboardLayout`: a plain `String` enum
// read through `@AppStorage`, with no `SettingsManager` round-trip and no
// `NotificationCenter` post. `DashboardLayout` needs that heavier machinery
// only because `DashboardLayout.current` is read from non-SwiftUI colour
// resolvers. Nothing here is.

/// Anything the shared switcher can present.
protocol HomeSwitcherOption: Hashable, CaseIterable, Identifiable {
    var displayName: String { get }
    var symbolName: String { get }
}

extension HomeSwitcherOption where Self: RawRepresentable, RawValue == String {
    var id: String { rawValue }
}

// MARK: - Inbox

enum DashboardHomeInboxMode: String, CaseIterable, HomeSwitcherOption {
    /// The focused route's list + detail. The default.
    case reader
    /// List only, full width. At the narrow width band Home's detail pane is
    /// ~448pt — half-useless for reading, and the wrong shape for clearing
    /// thirty items. Opening a row navigates to the focused inbox.
    case triage
    /// Columns by priority band. The one genuinely new rendering surface.
    case board

    static let storageKey = "dashboard.home.inbox.mode"

    var displayName: String {
        switch self {
        case .reader: return "Reader"
        case .triage: return "Triage"
        case .board:  return "Board"
        }
    }

    var symbolName: String {
        switch self {
        case .reader: return "sidebar.squares.right"
        case .triage: return "list.bullet"
        case .board:  return "rectangle.split.3x1"
        }
    }
}

// MARK: - Quota

enum DashboardHomeQuotaMode: String, CaseIterable, HomeSwitcherOption {
    /// `QuotaPrimaryBar` in the popover's row. ~46pt per provider.
    case bars
    /// `QuotaDualWindowStrip` — the only compact view that shows the 5h *and*
    /// 7d windows, which is usually the actual question. ~60pt.
    case windows
    /// `QuotaArcDial` at 96pt, two per row.
    case dials
    /// `ProviderQuotaChip` — the only mode still legible below ~110pt, and
    /// what the collapsed rail stub uses.
    case chips

    static let storageKey = "dashboard.home.quota.mode"

    var displayName: String {
        switch self {
        case .bars:    return "Bars"
        case .windows: return "Windows"
        case .dials:   return "Dials"
        case .chips:   return "Chips"
        }
    }

    var symbolName: String {
        switch self {
        case .bars:    return "chart.bar.fill"
        case .windows: return "rectangle.split.1x2"
        case .dials:   return "gauge.with.dots.needle.67percent"
        case .chips:   return "capsule"
        }
    }
}

// MARK: - Fleet

enum DashboardHomeFleetMode: String, CaseIterable, HomeSwitcherOption {
    /// Dot · mark · name · evidence phrase · relative time.
    case rows
    /// Dots and marks only. Says the least, so it cannot lie — and it is what
    /// the collapsed rail stub falls back to.
    case strip
    /// A 60-minute lane of observed writes.
    ///
    /// Deliberately unavailable until the filesystem watchers are armed: with
    /// only 60s-cadence parsed rows every tick clusters at "last scan" and
    /// implies a precision we do not have.
    case timeline

    static let storageKey = "dashboard.home.fleet.mode"

    var displayName: String {
        switch self {
        case .rows:     return "Rows"
        case .strip:    return "Strip"
        case .timeline: return "Timeline"
        }
    }

    var symbolName: String {
        switch self {
        case .rows:     return "list.bullet.indent"
        case .strip:    return "circle.grid.3x1.fill"
        case .timeline: return "chart.bar.xaxis"
        }
    }

    /// Modes that can be rendered truthfully right now.
    ///
    /// Follows `OnboardingWizardStep.availableCases`: gate the option out of
    /// the picker rather than shipping it present-and-empty.
    static func availableCases(hasRealTimeCoverage: Bool) -> [DashboardHomeFleetMode] {
        hasRealTimeCoverage ? allCases : allCases.filter { $0 != .timeline }
    }
}

// MARK: - Rail panels

enum DashboardHomeRailPanel: String, CaseIterable, Identifiable {
    case fleet
    case quota

    var id: String { rawValue }

    static let orderStorageKey = "dashboard.home.rail.panelOrder"
    static let stateStorageKey = "dashboard.home.rail.panelState"

    var title: String {
        switch self {
        case .fleet: return "FLEET"
        case .quota: return "QUOTA"
        }
    }

    var symbolName: String {
        switch self {
        case .fleet: return "antenna.radiowaves.left.and.right"
        case .quota: return "gauge.with.dots.needle.67percent"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .fleet: return "Agent fleet"
        case .quota: return "Quota"
        }
    }

    /// Decodes the persisted order, normalized against what actually exists.
    ///
    /// Same decode ∩ available, then append missing IDs shape as
    /// `PopoverTrayLayout` uses for the menu-bar popover. A future panel
    /// appears automatically and a stale key is harmless.
    static func ordered(from raw: String) -> [DashboardHomeRailPanel] {
        let decoded = raw
            .split(separator: ",")
            .compactMap { DashboardHomeRailPanel(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        var result = decoded.filter { allCases.contains($0) }
        for panel in allCases where result.contains(panel) == false {
            result.append(panel)
        }
        return result
    }

    static func encode(_ panels: [DashboardHomeRailPanel]) -> String {
        panels.map(\.rawValue).joined(separator: ",")
    }
}

/// Per-panel persisted state.
struct DashboardHomeRailPanelState: Codable, Equatable {
    var collapsed: Bool = false
    /// Per-panel share of the rail. **Not read yet** — with exactly two panels
    /// the rail is driven by the single `splitFraction`, and `nil` means "share
    /// equally with the other expanded panels". It is persisted now so adding a
    /// third panel does not need a storage migration; delete it if a third
    /// panel never arrives.
    var fraction: Double?

    static func decode(_ raw: String) -> [String: DashboardHomeRailPanelState] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: DashboardHomeRailPanelState].self, from: data)
        else { return [:] }
        return decoded
    }

    static func encode(_ state: [String: DashboardHomeRailPanelState]) -> String {
        guard let data = try? JSONEncoder().encode(state),
              let raw = String(data: data, encoding: .utf8)
        else { return "{}" }
        return raw
    }
}

// MARK: - Rail geometry

/// Every clamp and breakpoint the Home rail obeys.
///
/// Kept as pure statics so the layout rules are unit-testable without mounting
/// a view — `@State` cannot be mutated on an unmounted `DashboardView`, which
/// is why `DashboardViewIntegrationTests` tests logic rather than rendering.
enum DashboardHomeRailMetrics {
    static let defaultWidth: CGFloat = 320
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 460
    /// Width cap while in the medium band. Applied at render only — never
    /// written to storage, so widening the window restores the user's choice.
    static let mediumBandWidthCap: CGFloat = 300

    static let defaultSplitFraction: Double = 0.58
    static let minSplitFraction: Double = 0.25
    static let maxSplitFraction: Double = 0.78

    static let widthStorageKey = "dashboard.home.rail.width"
    static let splitStorageKey = "dashboard.home.rail.splitFraction"
    static let collapsedStorageKey = "dashboard.home.rail.collapsed"

    /// Height of the stub the rail collapses to. Never zero: a collapsed rail
    /// still shows the fleet count and a quota chip.
    static let collapsedStubWidth: CGFloat = 28

    enum Band: Equatable { case narrow, medium, wide }

    /// Dead-band width classification.
    ///
    /// Two hold zones, mirroring `updateOverviewLaneLayout`, because a
    /// `GeometryReader` reports sub-pixel changes when the user parks a divider
    /// near a threshold and a hard cutoff makes the rail flicker.
    /// Enter thresholds, with a hold zone on each side:
    ///
    ///     < 980        narrow
    ///     980…1000     hold  ← dead band
    ///     1000…1160    medium
    ///     1160…1180    hold  ← dead band
    ///     > 1180       wide
    ///
    /// Both zones are load-bearing. The `medium` upper bound must stop short of
    /// the `wide` threshold, or the medium rule swallows the upper dead band and
    /// the rail flickers between medium and wide when a divider is parked near
    /// 1170 — which is precisely the jitter these bands exist to prevent.
    static func band(forWidth width: CGFloat, current: Band) -> Band {
        guard width > 0 else { return current }
        if width < 980 { return .narrow }
        if width > 1180 { return .wide }
        if width > 1000, width <= 1160 { return .medium }
        return current
    }

    static func resolvedWidth(stored: CGFloat, band: Band) -> CGFloat {
        let clamped = min(max(stored, minWidth), maxWidth)
        switch band {
        case .wide:   return clamped
        case .medium: return min(clamped, mediumBandWidthCap)
        case .narrow: return collapsedStubWidth
        }
    }

    static func clampSplit(_ fraction: Double) -> Double {
        min(max(fraction, minSplitFraction), maxSplitFraction)
    }

    /// Whether the rail is actually showing.
    ///
    /// The narrow band forces the stub **without** writing the collapsed key:
    /// an automatic collapse must never be mistaken for the user's intent, the
    /// same separation `resolvedSidebarVisibility` keeps between an override
    /// and a route default.
    static func railIsExpanded(userWantsRail: Bool, band: Band) -> Bool {
        userWantsRail && band != .narrow
    }
}
