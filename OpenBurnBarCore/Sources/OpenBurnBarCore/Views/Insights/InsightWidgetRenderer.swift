import SwiftUI

/// Top-level dispatcher that renders any `InsightWidget` into the chrome
/// wrapper + the correct per-kind body view.
///
/// Adding a new widget kind requires a matching case here — the compiler
/// enforces completeness because the inner switch is exhaustive over
/// `InsightWidgetData`.
public struct InsightWidgetRenderer: View {

    public let widget: InsightWidget
    public let isSelected: Bool
    public let onConfigure: (() -> Void)?
    public let onCitationTapped: ((InsightCitation) -> Void)?

    public init(widget: InsightWidget,
                isSelected: Bool = false,
                onConfigure: (() -> Void)? = nil,
                onCitationTapped: ((InsightCitation) -> Void)? = nil) {
        self.widget = widget
        self.isSelected = isSelected
        self.onConfigure = onConfigure
        self.onCitationTapped = onCitationTapped
    }

    public var body: some View {
        InsightWidgetChrome(widget: widget, isSelected: isSelected, onConfigure: onConfigure) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let data = widget.data {
            switch data {
            case .kpi(let kpi):                 InsightKPITileView(data: kpi)
            case .timeSeries(let ts):           InsightTimeSeriesView(data: ts, spec: widget.spec)
            case .ranking(let r):               InsightRankingView(data: r)
            case .distribution(let d):          InsightDistributionView(data: d, spec: widget.spec)
            case .heatmap(let h):               InsightHeatmapView(data: h)
            case .scatter(let s):               InsightScatterView(data: s)
            case .sankey(let s):                InsightSankeyView(data: s)
            case .radar(let r):                 InsightRadarView(data: r)
            case .cohort(let c):                InsightCohortView(data: c)
            case .funnel(let f):                InsightFunnelView(data: f)
            case .quota(let q):                 InsightQuotaPulseView(data: q)
            case .forecast(let f):              InsightForecastView(data: f)
            case .anomaly(let a):               InsightAnomalyTableView(data: a, onCitationTapped: onCitationTapped)
            case .narrative(let n):             InsightNarrativeView(data: n, onCitationTapped: onCitationTapped)
            case .recommendation(let r):        InsightRecommendationView(data: r, onCitationTapped: onCitationTapped)
            case .useCaseCluster(let c):        InsightUseCaseClusterView(data: c)
            case .focusMatrix(let fm):          InsightFocusMatrixView(data: fm)
            case .drilldown(let d):             InsightDrilldownListView(data: d, onCitationTapped: onCitationTapped)
            case .mermaid(let source):          InsightMermaidPlaceholderView(source: source)
            case .ascii(let card):              InsightASCIIView(data: card)
            case .composed(let children):
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        InsightChildBodyView(data: child)
                    }
                }
            case .empty(let reason):
                InsightEmptyBodyView(message: reason)
            case .error(let message):
                InsightErrorBodyView(message: message)
            }
        } else {
            InsightSkeletonBodyView()
        }
    }
}

/// Used for composed children — same dispatch but without the chrome.
struct InsightChildBodyView: View {
    let data: InsightWidgetData
    var body: some View {
        switch data {
        case .kpi(let kpi):                 InsightKPITileView(data: kpi)
        case .timeSeries(let ts):           InsightTimeSeriesView(data: ts, spec: .timeSeries(.init(style: .line)))
        case .ranking(let r):               InsightRankingView(data: r)
        case .distribution(let d):          InsightDistributionView(data: d, spec: .distribution(.init(style: .donut)))
        case .heatmap(let h):               InsightHeatmapView(data: h)
        case .scatter(let s):               InsightScatterView(data: s)
        case .sankey(let s):                InsightSankeyView(data: s)
        case .radar(let r):                 InsightRadarView(data: r)
        case .cohort(let c):                InsightCohortView(data: c)
        case .funnel(let f):                InsightFunnelView(data: f)
        case .quota(let q):                 InsightQuotaPulseView(data: q)
        case .forecast(let f):              InsightForecastView(data: f)
        case .anomaly(let a):               InsightAnomalyTableView(data: a, onCitationTapped: nil)
        case .narrative(let n):             InsightNarrativeView(data: n, onCitationTapped: nil)
        case .recommendation(let r):        InsightRecommendationView(data: r, onCitationTapped: nil)
        case .useCaseCluster(let c):        InsightUseCaseClusterView(data: c)
        case .focusMatrix(let fm):          InsightFocusMatrixView(data: fm)
        case .drilldown(let d):             InsightDrilldownListView(data: d, onCitationTapped: nil)
        case .mermaid(let source):          InsightMermaidPlaceholderView(source: source)
        case .ascii(let card):              InsightASCIIView(data: card)
        case .composed(let children):
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    InsightChildBodyView(data: child)
                }
            }
        case .empty(let reason):
            InsightEmptyBodyView(message: reason)
        case .error(let message):
            InsightErrorBodyView(message: message)
        }
    }
}

struct InsightSkeletonBodyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6).fill(UnifiedDesignSystem.Colors.borderSubtle).frame(height: 14)
            RoundedRectangle(cornerRadius: 6).fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.8)).frame(height: 14)
            RoundedRectangle(cornerRadius: 6).fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6)).frame(height: 14)
        }
        .opacity(0.6)
    }
}

struct InsightEmptyBodyView: View {
    let message: String
    var body: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(message)
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

struct InsightErrorBodyView: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
            Text(message)
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
        }
    }
}

struct InsightMermaidPlaceholderView: View {
    let source: String
    var body: some View {
        // Real Mermaid rendering lives in the shell layer (WKWebView). In
        // Core we surface the source as a compact monospaced preview so
        // the renderer is platform-agnostic and unit-testable.
        ScrollView {
            Text(source)
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
        .frame(maxHeight: 240)
    }
}
