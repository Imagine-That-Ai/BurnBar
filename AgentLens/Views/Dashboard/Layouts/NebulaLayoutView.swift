import OpenBurnBarCore
import SwiftUI

// MARK: - Bento (storage id `nebula`)
//
// For the spatial scanner — the person who does not read a dashboard so much as
// *look* at it, lands wherever their eye lands, and builds the picture from
// whichever tile they noticed first.
//
// Thesis: a flat field of equal-weight tiles with no reading order. There is no
// hero, no left rail, no "start here". Every tile is the same size, carries the
// same visual weight, and is independently meaningful, so any entry point is a
// valid entry point.
//
// Primary axis: none — it is a grid, and that is the point. Density: medium and
// uniform. Dominant element: deliberately absent.
//
// Enforced rule: **no dominant tile.** Every tile in this file is
// `bentoTileHeight` tall and `emphasis: .standard`. Nothing spans two columns,
// nothing is `.featured`, and no tile renders type larger than
// `bentoValueSize`. The moment one tile gets bigger the layout is Focus with
// extra steps.

extension DashboardView {
    /// Uniform for every tile. A single constant rather than a per-tile frame is
    /// what actually enforces "no dominant tile" — you cannot make one bigger
    /// without changing all of them.
    private var bentoTileHeight: CGFloat { 128 }
    private var bentoValueSize: CGFloat { 26 }

    var nebulaLayout: some View {
        conceptCanvas(spacing: DesignSystem.Spacing.lg) {
            conceptUpdateBanner
            bentoGrid
            conceptDetailsDrawer(includesLiveCurve: false)
        }
    }

    private var bentoGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 210, maximum: 320),
                    spacing: DesignSystem.Spacing.md,
                    alignment: .top
                )
            ],
            alignment: .leading,
            spacing: DesignSystem.Spacing.md
        ) {
            ForEach(Array(conceptWindowFacts.enumerated()), id: \.offset) { _, fact in
                bentoTile(fact.label, accent: fact.accent) {
                    Text(fact.value)
                        .font(.system(size: bentoValueSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(fact.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .contentTransition(.numericText())
                        .animation(DesignSystem.Animation.gentle, value: fact.value)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }

            bentoTile("Top provider", accent: DesignSystem.Colors.ember) {
                bentoLeaderBody(conceptProviderRows.first, empty: "No provider spend yet")
            }

            bentoTile("Top model", accent: DesignSystem.Colors.blaze) {
                bentoLeaderBody(conceptModelRows.first, empty: "No model spend yet")
            }

            bentoTile("Cumulative", accent: DesignSystem.Colors.whimsy) {
                liveCostCurveBand
                    .frame(maxHeight: .infinity)
            }

            bentoTile("Substrate", accent: DesignSystem.Colors.amber) {
                SwarmRevealWindow {
                    VStack {
                        Spacer()
                        HStack {
                            SwarmFormingChip(label: "forming")
                            Spacer()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// One tile. The only knob a caller gets is the eyebrow, the accent, and the
    /// body — never the size.
    private func bentoTile<Content: View>(
        _ eyebrow: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DashboardSection(eyebrow, accent: accent, density: .compact, emphasis: .standard) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: bentoTileHeight)
    }

    @ViewBuilder
    private func bentoLeaderBody(_ item: DashboardRankedItem?, empty: String) -> some View {
        if let item {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if let provider = item.provider {
                        ProviderLogoView(provider: provider, size: 22, useFallbackColor: true)
                    }
                    Text(item.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(dashboardSectionInk.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.value)
                    .font(.system(size: bentoValueSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(item.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("\(Int((item.share * 100).rounded()))% of window spend")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(dashboardSectionInk.subtle)
                    .lineLimit(1)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(empty)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(dashboardSectionInk.subtle)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
