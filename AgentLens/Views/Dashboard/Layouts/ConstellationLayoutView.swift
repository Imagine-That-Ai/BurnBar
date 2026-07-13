import OpenBurnBarCore
import SwiftUI

// MARK: - Constellation Layout (concept 2 · command)
//
// A centered command column over a full-bleed swarm: a search / Hermes bar at
// the top, the live substrate filling the middle (one logo resolving at a
// time), three stat pills, and a wrap of provider chips. Minimal and calm.

extension DashboardView {
    var constellationLayout: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.xl) {
                    conceptUpdateBanner

                    constellationSearchBar
                        .frame(maxWidth: 620)

                    SwarmRevealWindow {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                SwarmFormingChip(label: "forming · vicsek · one model at a time")
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(geo.size.height * 0.34, 220))

                    constellationStatPills

                    constellationProviderChips
                        .frame(maxWidth: 720)

                    conceptMoreDrawer
                        .frame(maxWidth: 900)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: DashboardLayoutMetrics.contentMaxWidth, alignment: .top) // cov:ignore -- decorative layout geometry is smoke-tested but not line-attributed by ViewInspector
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { overviewAppeared = true }
    }

    private var constellationSearchBar: some View {
        Button {
            withAnimation(DesignSystem.Animation.standard) { chatPanelOpen = true }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("Ask Hermes, or search \(dataStore.totalUsageSessionCount.formatted()) sessions…")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Text("⌘K")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.12)))
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chat or search sessions")
    }

    private var constellationStatPills: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            ConceptStatTile(
                label: "Burn",
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
        }
        .frame(maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var constellationProviderChips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSystem.Spacing.sm)],
            spacing: DesignSystem.Spacing.sm
        ) {
            ForEach(dashboardProviderSummaries) { summary in
                Button {
                    conceptOpenProvider(summary.provider, lane: "constellation_provider")
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        ProviderLogoView(provider: summary.provider, size: 22, useFallbackColor: true)
                        Text(summary.provider.displayName)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
