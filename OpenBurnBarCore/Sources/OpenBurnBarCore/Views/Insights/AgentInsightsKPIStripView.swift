import SwiftUI

/// Four KPI tiles, identical order on every platform: Spend · Tokens ·
/// Sessions · Anomaly. `compact` lays them out in a 2×2 grid; `roomy`
/// uses a single 4-wide row.
public struct AgentInsightsKPIStripView: View {
    public let strip: AgentInsightsKPIStrip
    public let presentation: AgentInsightsView.Presentation

    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false
    @AppStorage("useKernelBackdrop") private var useKernelBackdrop: Bool = false

    private var usesLiveBackground: Bool {
        useWebsiteBackground || useKernelBackdrop
    }

    public init(strip: AgentInsightsKPIStrip, presentation: AgentInsightsView.Presentation) {
        self.strip = strip
        self.presentation = presentation
    }

    public var body: some View {
        let columns: [GridItem] = presentation == .roomy
            ? Array(repeating: GridItem(.flexible(), spacing: UnifiedDesignSystem.Spacing.md), count: 4)
            : Array(repeating: GridItem(.flexible(), spacing: UnifiedDesignSystem.Spacing.md), count: 2)

        LazyVGrid(columns: columns, spacing: UnifiedDesignSystem.Spacing.md) {
            ForEach(strip.ordered) { kpi in
                AgentInsightsKPITile(kpi: kpi, live: usesLiveBackground)
            }
        }
    }
}

private struct AgentInsightsKPITile: View {
    let kpi: AgentInsightsKPIStrip.KPI
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: kpi.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Text(kpi.label.uppercased())
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
                trendBadge
            }
            Text(kpi.valueText)
                .font(UnifiedDesignSystem.Typography.monoLarge)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let trendText = kpi.trendText {
                Text(trendText)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(trendColor)
                    .lineLimit(1)
            } else {
                // Reserve trend line height so tiles align across the grid.
                Text(" ")
                    .font(UnifiedDesignSystem.Typography.tiny)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface(
            cornerRadius: UnifiedDesignSystem.Radius.md,
            live: live,
            stroke: UnifiedDesignSystem.Colors.borderSubtle,
            lineWidth: 0.5
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kpi.label): \(kpi.valueText). \(kpi.trendText ?? "")")
    }

    @ViewBuilder
    private var trendBadge: some View {
        switch kpi.trendDirection {
        case .up:
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.Colors.success)
        case .down:
            Image(systemName: "arrow.down.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
        case .flat:
            EmptyView()
        }
    }

    private var trendColor: Color {
        switch kpi.trendDirection {
        case .up: return UnifiedDesignSystem.Colors.success
        case .down: return UnifiedDesignSystem.Colors.warning
        case .flat: return UnifiedDesignSystem.Colors.textMuted
        }
    }
}
