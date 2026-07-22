import Foundation

// MARK: - Chart Kind
//
// The registry of every chart the Charts page can render. Each kind carries
// its own editorial metadata (title, "why it matters" microcopy, symbol) so
// the page reads like a curated gallery rather than a grid of anonymous
// plots. Adding a chart = add a case here, prepare its data in
// `ChartsSnapshot`, and give it a renderer arm in `ChartCardView`.

enum ChartKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case burnOverTime
    case providerMix
    case modelMix
    case cacheROI
    case reasoningShare
    case hourOfDayHeatmap
    case weekOverWeekDelta
    case costPerSessionDistribution
    case sessionOutliers
    case projectFocus
    case burnForecast
    case provenanceQuality
    // Registered but hidden by default — surfaced via "Edit charts" or an
    // AI-suggested chart chip.
    case modelConcentration
    case remoteVsLocal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .burnOverTime: return "Burn Over Time"
        case .providerMix: return "Provider Mix"
        case .modelMix: return "Model Mix"
        case .cacheROI: return "Cache Savings"
        case .reasoningShare: return "Reasoning Share"
        case .hourOfDayHeatmap: return "When You Burn"
        case .weekOverWeekDelta: return "Week vs Week"
        case .costPerSessionDistribution: return "Session Cost Spread"
        case .sessionOutliers: return "Heavyweight Sessions"
        case .projectFocus: return "Project Focus"
        case .burnForecast: return "Burn Forecast"
        case .provenanceQuality: return "Data Confidence"
        case .modelConcentration: return "Model Concentration"
        case .remoteVsLocal: return "Remote vs Local"
        }
    }

    /// One-line "why it matters" — rendered as the card's footer microcopy.
    var whyItMatters: String {
        switch self {
        case .burnOverTime:
            return "The shape of your spend — spikes, plateaus, and quiet hours."
        case .providerMix:
            return "Where the money actually goes across providers."
        case .modelMix:
            return "Which models earn their keep — and which quietly dominate."
        case .cacheROI:
            return "Prompt caching pays rent. This is the receipt."
        case .reasoningShare:
            return "Extended thinking is a hidden line item. Watch its share."
        case .hourOfDayHeatmap:
            return "Your true working rhythm, drawn by every request you've made."
        case .weekOverWeekDelta:
            return "Momentum check: is this week heavier or lighter than last?"
        case .costPerSessionDistribution:
            return "Most sessions are cheap. The tail is where budgets die."
        case .sessionOutliers:
            return "The five sessions that cost the most — worth a second look."
        case .projectFocus:
            return "Spread thin or locked in? Spend entropy across projects."
        case .burnForecast:
            return "If the last two weeks continue, this is where the month lands."
        case .provenanceQuality:
            return "How much of this data is exact versus estimated."
        case .modelConcentration:
            return "A Herfindahl index for your model portfolio."
        case .remoteVsLocal:
            return "Spend that originated on other devices versus this one."
        }
    }

    var systemImage: String {
        switch self {
        case .burnOverTime: return "chart.line.uptrend.xyaxis"
        case .providerMix: return "chart.pie"
        case .modelMix: return "cube.transparent"
        case .cacheROI: return "archivebox"
        case .reasoningShare: return "brain"
        case .hourOfDayHeatmap: return "clock.badge"
        case .weekOverWeekDelta: return "arrow.left.arrow.right"
        case .costPerSessionDistribution: return "chart.bar"
        case .sessionOutliers: return "flame"
        case .projectFocus: return "scope"
        case .burnForecast: return "chart.line.uptrend.xyaxis.circle"
        case .provenanceQuality: return "checkmark.seal"
        case .modelConcentration: return "circle.hexagongrid"
        case .remoteVsLocal: return "laptopcomputer.and.iphone"
        }
    }

    /// Grid span in columns (the grid is 2 columns wide; 2 = full width).
    var defaultSpan: Int {
        switch self {
        case .burnOverTime, .hourOfDayHeatmap, .burnForecast, .projectFocus:
            return 2
        default:
            return 1
        }
    }

    var defaultVisible: Bool {
        switch self {
        case .modelConcentration, .remoteVsLocal: return false
        default: return true
        }
    }
}

// MARK: - Card configuration & page layout

/// One card's persisted state: which chart, whether shown, and how wide.
struct ChartCardConfig: Codable, Equatable, Identifiable, Sendable {
    var kind: ChartKind
    var isVisible: Bool
    var span: Int

    var id: String { kind.rawValue }

    init(kind: ChartKind, isVisible: Bool? = nil, span: Int? = nil) {
        self.kind = kind
        self.isVisible = isVisible ?? kind.defaultVisible
        self.span = min(2, max(1, span ?? kind.defaultSpan))
    }
}

/// The full page layout: an ordered list of card configs, persisted as JSON
/// under `ChartsPageLayout.storageKey`. Decoding is forward-compatible —
/// unknown kinds (from a newer build) are dropped, and kinds missing from the
/// stored payload (added since the layout was saved) are appended with their
/// defaults, so upgrades surface new charts without clobbering the user's
/// arrangement.
struct ChartsPageLayout: Equatable, Sendable {
    static let storageKey = "chartsPageLayout.v1"

    private(set) var configs: [ChartCardConfig]

    static var `default`: ChartsPageLayout {
        ChartsPageLayout(configs: ChartKind.allCases.map { ChartCardConfig(kind: $0) })
    }

    init(configs: [ChartCardConfig]) {
        self.configs = Self.reconciled(configs)
    }

    /// Cards the grid actually renders, in order.
    var visibleConfigs: [ChartCardConfig] {
        configs.filter(\.isVisible)
    }

    var hiddenConfigs: [ChartCardConfig] {
        configs.filter { !$0.isVisible }
    }

    // MARK: Mutations

    /// Moves `kind` so it occupies the position currently held by `target`
    /// (drag-to-reorder lands on a specific card, not an abstract index).
    mutating func move(_ kind: ChartKind, toPositionOf target: ChartKind) {
        guard kind != target,
              let from = configs.firstIndex(where: { $0.kind == kind }),
              let to = configs.firstIndex(where: { $0.kind == target }) else { return }
        let config = configs.remove(at: from)
        configs.insert(config, at: to)
    }

    mutating func setVisible(_ kind: ChartKind, _ visible: Bool) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        configs[index].isVisible = visible
    }

    mutating func setSpan(_ kind: ChartKind, _ span: Int) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        configs[index].span = min(2, max(1, span))
    }

    mutating func reset() {
        self = .default
    }

    // MARK: Persistence

    /// JSON round-trip tolerant of unknown kinds. See type comment.
    static func decode(from data: Data) -> ChartsPageLayout {
        struct RawConfig: Codable {
            let kind: String
            let isVisible: Bool?
            let span: Int?
        }
        guard let raw = try? JSONDecoder().decode([RawConfig].self, from: data) else {
            return .default
        }
        let known = raw.compactMap { entry -> ChartCardConfig? in
            guard let kind = ChartKind(rawValue: entry.kind) else { return nil }
            return ChartCardConfig(kind: kind, isVisible: entry.isVisible, span: entry.span)
        }
        return ChartsPageLayout(configs: known)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(configs)
    }

    /// Deduplicates and appends any kinds missing from `configs` so every
    /// registered chart always has exactly one slot.
    private static func reconciled(_ configs: [ChartCardConfig]) -> [ChartCardConfig] {
        var seen = Set<ChartKind>()
        var result: [ChartCardConfig] = []
        for config in configs where !seen.contains(config.kind) {
            seen.insert(config.kind)
            result.append(config)
        }
        for kind in ChartKind.allCases where !seen.contains(kind) {
            result.append(ChartCardConfig(kind: kind))
        }
        return result
    }
}
