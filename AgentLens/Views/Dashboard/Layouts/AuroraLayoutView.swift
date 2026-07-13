import OpenBurnBarCore
import SwiftUI

// MARK: - Aurora Layout (concept 0)
//
// Provider rail on the left, an open hero field on the right: a swarm "reveal"
// stage up top (the global backdrop showing through a framed window) over a
// bottom data band — a big Burn card, the live cost curve, and a stacked
// Tokens / Sessions column. The signature, balanced concept.

extension DashboardView {
    var auroraLayout: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    conceptUpdateBanner
                    if wide {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                            auroraProviderRail
                                .frame(width: 280)
                            auroraHeroColumn
                                .frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: max(geo.size.height * 0.66, 420), alignment: .topLeading)
                    } else {
                        auroraHeroColumn
                        auroraProviderRail
                            .frame(height: 320)
                    }
                    conceptDetailsDrawer(includesLiveCurve: false)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: DashboardLayoutMetrics.contentMaxWidth, alignment: .topLeading) // cov:ignore -- decorative layout geometry is smoke-tested but not line-attributed by ViewInspector
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { overviewAppeared = true }
    }

    private var auroraProviderRail: some View {
        ProviderListPanel(
            summaries: dashboardProviderSummaries,
            title: "LLM Models",
            subtitle: "Command",
            onSelect: { conceptOpenProvider($0, lane: "aurora_provider") }
        )
        .frame(maxHeight: .infinity)
    }

    private var auroraHeroColumn: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            SwarmRevealWindow {
                VStack {
                    HStack {
                        SwarmFormingChip(label: "forming · flow field")
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 180)

            auroraDataBand
        }
    }

    @ViewBuilder
    private var auroraDataBand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                ConceptStatTile(
                    label: "Burn · Today",
                    value: totalCostForTimeRange.formatAsCost(),
                    caption: heroSubheadline,
                    accent: DesignSystem.Colors.whimsy,
                    prominence: .hero
                )
                .frame(width: 240)
                conceptCurveCard
                    .frame(maxWidth: .infinity)
                auroraTokensSessions
                    .frame(width: 168)
            }
            VStack(spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.lg) {
                    ConceptStatTile(
                        label: "Burn · Today",
                        value: totalCostForTimeRange.formatAsCost(),
                        accent: DesignSystem.Colors.whimsy,
                        prominence: .hero
                    )
                    auroraTokensSessions
                }
                conceptCurveCard.frame(height: 150)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var auroraTokensSessions: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
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
        }
    }
}
