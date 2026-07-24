import OpenBurnBarCore
import SwiftUI

// MARK: - Cockpit Layout (concept 3 · mission control)
//
// The dense operator view: a spend-share provider rail, a four-tile KPI row
// (Burn / Tokens / Sessions / Cache Hit), a routing swarm stage, and a bottom
// band pairing the live cost curve with The Wand's verdicts.

extension DashboardView {
    var cockpitLayout: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 940
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    conceptUpdateBanner
                    if wide {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            cockpitProviderRail
                                .frame(width: 290)
                            cockpitMain
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        cockpitKPIRow
                        cockpitStage.frame(height: 240)
                        cockpitProviderRail.frame(height: 300)
                    }
                    cockpitBottomBand
                    conceptDetailsDrawer(includesLiveCurve: false, includesCastle: false)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: DashboardLayoutMetrics.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { overviewAppeared = true }
    }

    private var cockpitProviderRail: some View {
        ProviderListPanel(
            summaries: dashboardProviderSummaries,
            title: "Providers",
            subtitle: "Spend Share",
            showsSpendShare: true,
            onSelect: { conceptOpenProvider($0, lane: "cockpit_provider") }
        )
        .frame(maxHeight: .infinity)
    }

    private var cockpitMain: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            cockpitKPIRow
            cockpitStage
                .frame(minHeight: 220)
                .frame(maxHeight: .infinity)
        }
        .frame(minHeight: 360)
    }

    private var cockpitKPIRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ConceptStatTile(
                label: selectedTimeRange.burnTileLabel,
                value: totalCostForTimeRange.formatAsCost(),
                accent: DesignSystem.Colors.whimsy
            )
            ConceptStatTile(
                label: "Tokens",
                value: totalTokensForTimeRange.formatted(),
                accent: DesignSystem.Colors.ember
            )
            ConceptStatTile(
                label: "Sessions",
                value: dashboardUsageWindow.sessionCount.formatted(),
                accent: DesignSystem.Colors.amber
            )
            ConceptStatTile(
                label: "Cache Hit",
                value: dashboardUsageWindow.cacheEfficiency.formattedHitRate,
                accent: CacheHitRateTier(dashboardUsageWindow.cacheEfficiency).color
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cockpitStage: some View {
        SwarmRevealWindow {
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    SwarmFormingChip(label: "forming · boids")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("PROVIDERS")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(activeProviderCount.formatted())
                            .font(DesignSystem.Typography.monoLarge)
                            .foregroundStyle(DesignSystem.Colors.ember)
                    }
                }
                Spacer()
                Text("REAL-TIME ROUTING · \(activeProviderCount) PROVIDER\(activeProviderCount == 1 ? "" : "S")")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.3)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    private var cockpitBottomBand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                conceptCurveCard
                    .frame(maxWidth: .infinity)
                CastleGreatHallContainer()
                    .frame(maxWidth: .infinity)
            }
            VStack(spacing: DesignSystem.Spacing.md) {
                conceptCurveCard.frame(height: 160)
                CastleGreatHallContainer()
            }
        }
    }
}
