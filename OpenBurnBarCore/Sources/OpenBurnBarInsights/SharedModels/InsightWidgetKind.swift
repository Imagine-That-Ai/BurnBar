import Foundation

/// The complete registry of widget kinds the Insights tab can render.
///
/// Adding a new widget kind is a 5-step process documented in
/// `docs/INSIGHTS_ARCHITECTURE.md`:
///   1. Add a case here.
///   2. Add a matching `InsightWidgetSpec` case + spec struct.
///   3. Add a matching `InsightDataBinding` case (or reuse an existing one).
///   4. Teach `InsightExecutor` how to evaluate the binding.
///   5. Add a renderer view to `OpenBurnBarCore/Views/Insights/` and fan
///      out the new case in `InsightWidgetRenderer`.
///
/// Because the renderer fans out via exhaustive `switch`, the Swift
/// compiler enforces that every step gets done — there's no way to add a
/// case here without the build pointing at every missing place.
public enum InsightWidgetKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case kpiTile
    case timeSeriesLine
    case timeSeriesArea
    case streamGraph
    case barRanking
    case donut
    case treemap
    case heatmap
    case scatter
    case sankey
    case radar
    case cohort
    case funnel
    case quotaPulse
    case forecast
    case anomalyTable
    case narrative
    case recommendation
    case useCaseCluster
    case agentFocusMatrix
    case modelFocusMatrix
    case drilldownList
    case mermaid
    case ascii
    case composed
    case error

    public var id: String { rawValue }

    /// User-facing label for the "Add widget" menu and the inspector picker.
    public var displayName: String {
        switch self {
        case .kpiTile: return "KPI Tile"
        case .timeSeriesLine: return "Trend (Line)"
        case .timeSeriesArea: return "Trend (Area)"
        case .streamGraph: return "Stream Graph"
        case .barRanking: return "Top-N Ranking"
        case .donut: return "Donut"
        case .treemap: return "Treemap"
        case .heatmap: return "Heatmap"
        case .scatter: return "Scatter"
        case .sankey: return "Sankey Flow"
        case .radar: return "Radar"
        case .cohort: return "Cohort Retention"
        case .funnel: return "Funnel"
        case .quotaPulse: return "Quota Pulse"
        case .forecast: return "Forecast"
        case .anomalyTable: return "Anomaly Table"
        case .narrative: return "Narrative"
        case .recommendation: return "Recommendation"
        case .useCaseCluster: return "Use-Case Cluster"
        case .agentFocusMatrix: return "Agent Focus Matrix"
        case .modelFocusMatrix: return "Model Focus Matrix"
        case .drilldownList: return "Drilldown List"
        case .mermaid: return "Diagram"
        case .ascii: return "ASCII Card"
        case .composed: return "Composed"
        case .error: return "Error"
        }
    }

    /// SF Symbol shown in the Add menu and the widget header chip.
    public var symbolName: String {
        switch self {
        case .kpiTile: return "number.square.fill"
        case .timeSeriesLine: return "chart.xyaxis.line"
        case .timeSeriesArea: return "chart.line.uptrend.xyaxis"
        case .streamGraph: return "waveform.path.ecg"
        case .barRanking: return "list.number"
        case .donut: return "chart.pie.fill"
        case .treemap: return "square.grid.3x3.fill"
        case .heatmap: return "rectangle.grid.3x2.fill"
        case .scatter: return "circle.grid.3x3.fill"
        case .sankey: return "arrow.triangle.branch"
        case .radar: return "circle.grid.cross.fill"
        case .cohort: return "rectangle.grid.2x2.fill"
        case .funnel: return "arrow.down.right.and.arrow.up.left"
        case .quotaPulse: return "gauge.with.dots.needle.67percent"
        case .forecast: return "chart.line.uptrend.xyaxis.circle.fill"
        case .anomalyTable: return "exclamationmark.triangle.fill"
        case .narrative: return "text.quote"
        case .recommendation: return "lightbulb.fill"
        case .useCaseCluster: return "tag.circle.fill"
        case .agentFocusMatrix: return "person.crop.square.filled.and.at.rectangle"
        case .modelFocusMatrix: return "cpu.fill"
        case .drilldownList: return "list.bullet.rectangle"
        case .mermaid: return "flowchart.fill"
        case .ascii: return "terminal.fill"
        case .composed: return "rectangle.stack.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    /// Default placement: how many columns and rows the widget claims when
    /// freshly added on a 12-column macOS canvas. Mobile projections
    /// preserve the intent.
    public var defaultSpan: (columns: Int, rows: Int) {
        switch self {
        case .kpiTile: return (3, 2)
        case .timeSeriesLine: return (8, 3)
        case .timeSeriesArea: return (8, 3)
        case .streamGraph: return (12, 3)
        case .barRanking: return (4, 4)
        case .donut: return (4, 3)
        case .treemap: return (6, 4)
        case .heatmap: return (6, 3)
        case .scatter: return (6, 4)
        case .sankey: return (12, 4)
        case .radar: return (6, 4)
        case .cohort: return (8, 4)
        case .funnel: return (4, 4)
        case .quotaPulse: return (6, 3)
        case .forecast: return (8, 3)
        case .anomalyTable: return (6, 4)
        case .narrative: return (8, 3)
        case .recommendation: return (8, 3)
        case .useCaseCluster: return (8, 4)
        case .agentFocusMatrix: return (6, 4)
        case .modelFocusMatrix: return (6, 4)
        case .drilldownList: return (6, 4)
        case .mermaid: return (8, 4)
        case .ascii: return (6, 3)
        case .composed: return (8, 6)
        case .error: return (4, 2)
        }
    }

    /// Whether this widget kind expects to be authored by the LLM. Local
    /// widgets show "(local)" in the model picker for the widget; LLM
    /// widgets prompt for a model on insert.
    public var isLLMAuthored: Bool {
        switch self {
        case .narrative,
             .recommendation,
             .useCaseCluster,
             .agentFocusMatrix,
             .modelFocusMatrix,
             .mermaid,
             .ascii:
            return true
        default:
            return false
        }
    }
}
