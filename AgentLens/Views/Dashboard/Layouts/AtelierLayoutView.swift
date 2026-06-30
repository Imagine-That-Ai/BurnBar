import OpenBurnBarCore
import SwiftUI

// MARK: - Atelier Layout (the keeper · default)
//
// The default dashboard concept: a full-bleed, kernel-forward hero. The shared
// kernel + provider-swarm backdrop (`DashboardBackdrop`, rendered behind the
// whole window) is the canvas; this layer floats a provider rail, an editorial
// headline, and three glass stat cards over it — no opaque plate, so the live
// substrate shows through.
//
// "Curated + complete": a collapsed `ConceptMoreDrawer` keeps the information-
// dense lanes (narrative, provider / model / activity) one click away so no
// data is lost relative to the Classic overview.

extension DashboardView {
    var atelierLayout: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    conceptUpdateBanner
                    if wide {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                            atelierProviderRail
                                .frame(width: 300)
                            atelierHero
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: max(geo.size.height * 0.6, 360), alignment: .topLeading)
                    } else {
                        atelierHero
                        atelierProviderRail
                            .frame(height: 320)
                    }
                    atelierMoreDrawer
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { overviewAppeared = true }
    }

    private var atelierProviderRail: some View {
        ProviderListPanel(
            summaries: dashboardProviderSummaries,
            title: "Providers",
            logoSize: 40,
            onSelect: { conceptOpenProvider($0, lane: "atelier_provider") }
        )
        .frame(maxHeight: .infinity)
    }

    private var atelierHero: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                SwarmFormingChip()
                Text("WebGL kernel")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DesignSystem.Colors.ember.opacity(0.14)))
            }

            Spacer(minLength: DesignSystem.Spacing.xl)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("A living substrate,\ntuned to your spend.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Provider logos emerge from the kernel and dissolve back into it. Every layout is its own ecosystem — pick a concept, tune the glass.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: 460, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .shadow(color: .black.opacity(0.25), radius: 28, y: 4)

            AtelierSpendCurve(
                usages: dashboardUsageWindow.usages,
                range: dashboardDateRange
            )

            HStack(spacing: DesignSystem.Spacing.lg) {
                ConceptStatTile(
                    label: "Burn · Today",
                    value: totalCostForTimeRange.formatAsCost(),
                    accent: DesignSystem.Colors.whimsy,
                    prominence: .hero
                )
                ConceptStatTile(
                    label: "Tokens",
                    value: totalTokensForTimeRange.formatted(),
                    accent: DesignSystem.Colors.ember,
                    prominence: .hero
                )
                ConceptStatTile(
                    label: "Sessions",
                    value: dashboardUsageWindow.sessionCount.formatted(),
                    accent: DesignSystem.Colors.amber,
                    prominence: .hero
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var atelierMoreDrawer: some View {
        conceptMoreDrawer
    }
}
