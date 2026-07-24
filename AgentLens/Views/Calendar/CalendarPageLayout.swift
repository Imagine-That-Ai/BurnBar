import Foundation

// MARK: - Calendar Card Kind
//
// The registry of every analytics card the Calendar surface can render for
// the current day selection. Mirrors `ChartKind`: each kind carries its own
// editorial metadata, and adding a card = add a case here, prepare its data
// in `CalendarSelectionSnapshot`, and give it a renderer arm in
// `CalendarAnalyticsPanel`.

enum CalendarCardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case kpis
    case burnOverSelection
    case providerMix
    case modelMix
    case hourOfDayHeatmap
    case projectFocus
    case cacheROI
    case reasoningShare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kpis: return "Key Numbers"
        case .burnOverSelection: return "Burn Over Selection"
        case .providerMix: return "Provider Mix"
        case .modelMix: return "Model Mix"
        case .hourOfDayHeatmap: return "When You Burn"
        case .projectFocus: return "Project Focus"
        case .cacheROI: return "Cache Savings"
        case .reasoningShare: return "Reasoning Share"
        }
    }

    /// One-line "why it matters" — rendered as the card's footer microcopy.
    var whyItMatters: String {
        switch self {
        case .kpis:
            return "The selection at a glance — spend, volume, sessions, cadence."
        case .burnOverSelection:
            return "Day-by-day spend across the selected days."
        case .providerMix:
            return "Where the money actually goes across providers."
        case .modelMix:
            return "Which models earn their keep — and which quietly dominate."
        case .hourOfDayHeatmap:
            return "Your true working rhythm inside the selection."
        case .projectFocus:
            return "Which projects the selected days actually funded."
        case .cacheROI:
            return "Prompt caching pays rent. This is the receipt."
        case .reasoningShare:
            return "Extended thinking is a hidden line item. Watch its share."
        }
    }

    var systemImage: String {
        switch self {
        case .kpis: return "number.square"
        case .burnOverSelection: return "chart.bar"
        case .providerMix: return "chart.pie"
        case .modelMix: return "cube.transparent"
        case .hourOfDayHeatmap: return "clock.badge"
        case .projectFocus: return "scope"
        case .cacheROI: return "archivebox"
        case .reasoningShare: return "brain"
        }
    }

    /// Grid span in columns (the analytics grid is 3 columns wide; 3 = full
    /// width). Surfaced in the UI as S/M/L sizes.
    var defaultSpan: Int {
        switch self {
        case .kpis, .burnOverSelection, .hourOfDayHeatmap:
            return 3
        default:
            return 1
        }
    }

    var defaultVisible: Bool { true }
}

// MARK: - Card configuration & page layout

/// One card's persisted state: which card, whether shown, and how wide.
struct CalendarCardConfig: Codable, Equatable, Identifiable, Sendable {
    var kind: CalendarCardKind
    var isVisible: Bool
    var span: Int

    var id: String { kind.rawValue }

    init(kind: CalendarCardKind, isVisible: Bool? = nil, span: Int? = nil) {
        self.kind = kind
        self.isVisible = isVisible ?? kind.defaultVisible
        self.span = min(3, max(1, span ?? kind.defaultSpan))
    }
}

/// The full panel layout: an ordered list of card configs, persisted as JSON
/// under `CalendarPageLayout.storageKey`. Same forward-compatible contract as
/// `ChartsPageLayout` — unknown kinds are dropped, missing kinds are appended
/// with defaults, so upgrades never clobber the user's arrangement.
struct CalendarPageLayout: Equatable, Sendable {
    static let storageKey = "calendarPageLayout.v1"

    private(set) var configs: [CalendarCardConfig]

    static var `default`: CalendarPageLayout {
        CalendarPageLayout(configs: CalendarCardKind.allCases.map { CalendarCardConfig(kind: $0) })
    }

    init(configs: [CalendarCardConfig]) {
        self.configs = Self.reconciled(configs)
    }

    /// Cards the grid actually renders, in order.
    var visibleConfigs: [CalendarCardConfig] {
        configs.filter(\.isVisible)
    }

    var hiddenConfigs: [CalendarCardConfig] {
        configs.filter { !$0.isVisible }
    }

    // MARK: Mutations

    /// Moves `kind` so it occupies the position currently held by `target`
    /// (drag-to-reorder lands on a specific card, not an abstract index).
    mutating func move(_ kind: CalendarCardKind, toPositionOf target: CalendarCardKind) {
        guard kind != target,
              let from = configs.firstIndex(where: { $0.kind == kind }),
              let to = configs.firstIndex(where: { $0.kind == target }) else { return }
        let config = configs.remove(at: from)
        configs.insert(config, at: to)
    }

    mutating func setVisible(_ kind: CalendarCardKind, _ visible: Bool) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        configs[index].isVisible = visible
    }

    mutating func setSpan(_ kind: CalendarCardKind, _ span: Int) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        configs[index].span = min(3, max(1, span))
    }

    mutating func reset() {
        self = .default
    }

    // MARK: Persistence

    /// JSON round-trip tolerant of unknown kinds. See type comment.
    static func decode(from data: Data) -> CalendarPageLayout {
        struct RawConfig: Codable {
            let kind: String
            let isVisible: Bool?
            let span: Int?
        }
        guard let raw = try? JSONDecoder().decode([RawConfig].self, from: data) else {
            return .default
        }
        let known = raw.compactMap { entry -> CalendarCardConfig? in
            guard let kind = CalendarCardKind(rawValue: entry.kind) else { return nil }
            return CalendarCardConfig(kind: kind, isVisible: entry.isVisible, span: entry.span)
        }
        return CalendarPageLayout(configs: known)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(configs)
    }

    /// Deduplicates and appends any kinds missing from `configs` so every
    /// registered card always has exactly one slot.
    private static func reconciled(_ configs: [CalendarCardConfig]) -> [CalendarCardConfig] {
        var seen = Set<CalendarCardKind>()
        var result: [CalendarCardConfig] = []
        for config in configs where !seen.contains(config.kind) {
            seen.insert(config.kind)
            result.append(config)
        }
        for kind in CalendarCardKind.allCases where !seen.contains(kind) {
            result.append(CalendarCardConfig(kind: kind))
        }
        return result
    }
}
