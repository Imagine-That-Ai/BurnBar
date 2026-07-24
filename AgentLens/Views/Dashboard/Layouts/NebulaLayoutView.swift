import OpenBurnBarCore
import SwiftUI

// MARK: - Nebula Layout (concept 1 · bento)
//
// A bento grid: provider rail on the left; on the right a top row pairing a
// tall Burn card with a swarm reveal stage, and a bottom row of Tokens,
// Sessions, and the live cost curve. Denser than Aurora, still card-forward.

extension DashboardView {
    var nebulaLayout: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    conceptUpdateBanner
                    if wide {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                            nebulaProviderRail
                                .frame(width: 250)
                            nebulaBento
                                .frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: max(geo.size.height * 0.66, 420), alignment: .topLeading)
                    } else {
                        nebulaStacked
                        nebulaProviderRail
                            .frame(height: 320)
                    }
                    conceptDetailsDrawer(includesLiveCurve: false)
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

    private var nebulaProviderRail: some View {
        ProviderListPanel(
            summaries: dashboardProviderSummaries,
            title: "Providers",
            onSelect: { conceptOpenProvider($0, lane: "nebula_provider") }
        )
        .frame(maxHeight: .infinity)
    }

    private var nebulaBento: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                nebulaBurnCard
                    .frame(width: 280)
                SwarmRevealWindow {
                    VStack(alignment: .leading) {
                        HStack {
                            SwarmFormingChip(label: "forming · pso")
                            Spacer()
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PROVIDER FORMATIONS")
                                .font(DesignSystem.Typography.tiny)
                                .tracking(1.3)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                            Text("Living substrate")
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.ember)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .frame(minHeight: 220)

            HStack(spacing: DesignSystem.Spacing.lg) {
                ConceptStatTile(
                    label: "Tokens",
                    value: totalTokensForTimeRange.formatted(),
                    accent: DesignSystem.Colors.ember
                )
                .frame(width: 168)
                ConceptStatTile(
                    label: "Sessions",
                    value: dashboardUsageWindow.sessionCount.formatted(),
                    accent: DesignSystem.Colors.amber
                )
                .frame(width: 168)
                conceptCurveCard
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 150)
        }
    }

    private var nebulaBurnCard: some View {
        ConceptStatTile(
            label: "Burn · \(selectedTimeRange.displayName)",
            value: totalCostForTimeRange.formatAsCost(),
            caption: heroSubheadline,
            accent: DesignSystem.Colors.whimsy,
            prominence: .hero
        )
    }

    private var nebulaStacked: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.lg) {
                nebulaBurnCard
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
            conceptCurveCard.frame(height: 150)
        }
    }
}
