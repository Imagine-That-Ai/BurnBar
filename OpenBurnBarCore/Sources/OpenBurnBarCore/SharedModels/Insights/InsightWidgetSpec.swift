import Foundation

/// Compile-time-exhaustive sum of every widget's authoring spec.
///
/// The spec captures *intent* — what the widget should show and how —
/// independent of what data is actually plotted. The pair `(spec,
/// dataBinding)` is everything a widget needs to render: the binding
/// produces numbers, the spec governs labels, formatting, sort order, and
/// chrome preferences.
public enum InsightWidgetSpec: Codable, Hashable, Sendable {
    case kpiTile(KPITileSpec)
    case timeSeries(TimeSeriesSpec)
    case ranking(RankingSpec)
    case distribution(DistributionSpec)
    case heatmap(HeatmapSpec)
    case scatter(ScatterSpec)
    case sankey(SankeySpec)
    case radar(RadarSpec)
    case cohort(CohortSpec)
    case funnel(FunnelSpec)
    case quotaPulse(QuotaPulseSpec)
    case forecast(ForecastSpec)
    case anomalyTable(AnomalyTableSpec)
    case narrative(NarrativeSpec)
    case recommendation(RecommendationSpec)
    case useCaseCluster(UseCaseClusterSpec)
    case agentFocusMatrix(FocusMatrixSpec)
    case modelFocusMatrix(FocusMatrixSpec)
    case drilldownList(DrilldownSpec)
    case mermaid(MermaidSpec)
    case ascii(ASCIISpec)
    case composed(ComposedSpec)
    case error(ErrorSpec)

    /// Map back to the matching widget kind. The compiler ensures this
    /// stays in sync.
    public var kind: InsightWidgetKind {
        switch self {
        case .kpiTile: return .kpiTile
        case .timeSeries(let s): return s.style == .area ? .timeSeriesArea : (s.style == .stream ? .streamGraph : .timeSeriesLine)
        case .ranking: return .barRanking
        case .distribution: return .donut
        case .heatmap: return .heatmap
        case .scatter: return .scatter
        case .sankey: return .sankey
        case .radar: return .radar
        case .cohort: return .cohort
        case .funnel: return .funnel
        case .quotaPulse: return .quotaPulse
        case .forecast: return .forecast
        case .anomalyTable: return .anomalyTable
        case .narrative: return .narrative
        case .recommendation: return .recommendation
        case .useCaseCluster: return .useCaseCluster
        case .agentFocusMatrix: return .agentFocusMatrix
        case .modelFocusMatrix: return .modelFocusMatrix
        case .drilldownList: return .drilldownList
        case .mermaid: return .mermaid
        case .ascii: return .ascii
        case .composed: return .composed
        case .error: return .error
        }
    }

    // MARK: - Per-variant specs

    public struct KPITileSpec: Codable, Hashable, Sendable {
        public var metricLabel: String
        public var compareWindow: CompareWindow
        public var emphasizeDelta: Bool
        public init(metricLabel: String, compareWindow: CompareWindow = .previousPeriod, emphasizeDelta: Bool = true) {
            self.metricLabel = metricLabel
            self.compareWindow = compareWindow
            self.emphasizeDelta = emphasizeDelta
        }
        public enum CompareWindow: String, Codable, Hashable, Sendable, CaseIterable {
            case none, previousPeriod, weekOverWeek, monthOverMonth, yearOverYear
        }
    }

    public struct TimeSeriesSpec: Codable, Hashable, Sendable {
        public var style: Style
        public var smoothing: Smoothing
        public var showAnnotations: Bool
        public init(style: Style = .line, smoothing: Smoothing = .none, showAnnotations: Bool = true) {
            self.style = style; self.smoothing = smoothing; self.showAnnotations = showAnnotations
        }
        public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
            case line, area, stackedArea, stream, bar, stackedBar
        }
        public enum Smoothing: String, Codable, Hashable, Sendable, CaseIterable {
            case none, monotone, rolling7
        }
    }

    public struct RankingSpec: Codable, Hashable, Sendable {
        public var orientation: Orientation
        public var showValues: Bool
        public init(orientation: Orientation = .horizontal, showValues: Bool = true) {
            self.orientation = orientation; self.showValues = showValues
        }
        public enum Orientation: String, Codable, Hashable, Sendable, CaseIterable {
            case horizontal, vertical
        }
    }

    public struct DistributionSpec: Codable, Hashable, Sendable {
        public var style: Style
        public var showLegend: Bool
        public init(style: Style = .donut, showLegend: Bool = true) {
            self.style = style; self.showLegend = showLegend
        }
        public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
            case donut, pie, treemap
        }
    }

    public struct HeatmapSpec: Codable, Hashable, Sendable {
        public var palette: Palette
        public init(palette: Palette = .ember) { self.palette = palette }
        public enum Palette: String, Codable, Hashable, Sendable, CaseIterable {
            case ember, mercury, whimsy, mono
        }
    }

    public struct ScatterSpec: Codable, Hashable, Sendable {
        public var logX: Bool
        public var logY: Bool
        public var bubble: Bool
        public init(logX: Bool = false, logY: Bool = false, bubble: Bool = false) {
            self.logX = logX; self.logY = logY; self.bubble = bubble
        }
    }

    public struct SankeySpec: Codable, Hashable, Sendable {
        public init() {}
    }

    public struct RadarSpec: Codable, Hashable, Sendable {
        public var fill: Bool
        public init(fill: Bool = true) { self.fill = fill }
    }

    public struct CohortSpec: Codable, Hashable, Sendable {
        public init() {}
    }

    public struct FunnelSpec: Codable, Hashable, Sendable {
        public init() {}
    }

    public struct QuotaPulseSpec: Codable, Hashable, Sendable {
        public var compact: Bool
        public init(compact: Bool = false) { self.compact = compact }
    }

    public struct ForecastSpec: Codable, Hashable, Sendable {
        public var showBands: Bool
        public init(showBands: Bool = true) { self.showBands = showBands }
    }

    public struct AnomalyTableSpec: Codable, Hashable, Sendable {
        public var minScore: Double
        public init(minScore: Double = 2.0) { self.minScore = minScore }
    }

    public struct NarrativeSpec: Codable, Hashable, Sendable {
        public var emphasize: Emphasis
        public init(emphasize: Emphasis = .balanced) { self.emphasize = emphasize }
        public enum Emphasis: String, Codable, Hashable, Sendable, CaseIterable {
            case headlineOnly, balanced, deepDive
        }
    }

    public struct RecommendationSpec: Codable, Hashable, Sendable {
        public var category: Category
        public init(category: Category = .efficiency) { self.category = category }
        public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
            case efficiency, quality, cost, quota, risk, learning
        }
    }

    public struct UseCaseClusterSpec: Codable, Hashable, Sendable {
        public var maxClusters: Int
        public init(maxClusters: Int = 12) { self.maxClusters = max(2, min(36, maxClusters)) }
    }

    public struct FocusMatrixSpec: Codable, Hashable, Sendable {
        public var palette: HeatmapSpec.Palette
        public init(palette: HeatmapSpec.Palette = .whimsy) { self.palette = palette }
    }

    public struct DrilldownSpec: Codable, Hashable, Sendable {
        public var groupBy: InsightDataBinding.Dimension?
        public init(groupBy: InsightDataBinding.Dimension? = nil) { self.groupBy = groupBy }
    }

    public struct MermaidSpec: Codable, Hashable, Sendable {
        public init() {}
    }

    public struct ASCIISpec: Codable, Hashable, Sendable {
        public init() {}
    }

    public struct ComposedSpec: Codable, Hashable, Sendable {
        public var children: [InsightWidgetSpec]
        public init(children: [InsightWidgetSpec]) { self.children = children }
    }

    public struct ErrorSpec: Codable, Hashable, Sendable {
        public var message: String
        public init(message: String) { self.message = message }
    }
}
