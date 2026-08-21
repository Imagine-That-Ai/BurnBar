import OpenBurnBarCore
import SwiftUI

// MARK: - Canvas (storage id `atelier`) · the default
//
// For the ambient glancer — the person who keeps the window open on a second
// display and wants to feel the shape of their spend without reading it.
//
// Thesis: the kernel *is* the content. Everything else is annotation floating on
// it. This is the only layout where the live WebGL substrate is the subject
// rather than the wallpaper, which is why it is the default: it is the layout
// that shows you what the app is.
//
// Primary axis: none — a single field with type laid over it. Dominant element:
// the backdrop itself. Density: the lowest of the eight, by a wide margin.
//
// Enforced rule: **at most one plate on screen.** The headline, the numbers, and
// the curve draw directly on the backdrop using `\.backdropInk` — the adaptive
// family the readability sampler keeps above 4.5:1 against whatever the kernel
// is currently painting — so nothing needs a slab to be readable. The single
// permitted plate is the collapsed details drawer, because a *closed* drawer is
// chrome and an open one has left ambient mode anyway.
//
// If a `DashboardSection` ever appears above that drawer, this layout has become
// Focus and the kernel has gone back to being wallpaper.

extension DashboardView {
    var atelierLayout: some View {
        conceptCanvas(
            maxWidth: 1_040,
            spacing: DesignSystem.Spacing.xxl,
            gutter: DesignSystem.Spacing.xxl
        ) {
            conceptUpdateBanner
            canvasHeadline
            canvasCurve
            canvasNumbers
            conceptMoreDrawer
        }
    }

    // MARK: Headline

    private var canvasHeadline: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                SwarmFormingChip()
                Text(dataStore.moodLabel.uppercased())
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.3)
                    .foregroundStyle(dataStore.moodColor)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(dataStore.moodColor.opacity(0.14)))
            }

            Text(canvasHeadlineText)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(dashboardSectionInk.primary)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.22), radius: 24, y: 3)

            Text(canvasSubheadText)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(dashboardSectionInk.secondary)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DesignSystem.Spacing.xl)
    }

    /// Editorial, but never fictional: the line changes with the data so an idle
    /// machine does not get told it is busy.
    private var canvasHeadlineText: String {
        guard dashboardUsageWindow.sessionCount > 0 else {
            return "A living substrate,\nwaiting for its first session."
        }
        guard let leader = topProviderSummary else {
            return "A living substrate,\ntuned to your spend."
        }
        return "\(leader.provider.displayName) is\nsetting the weather."
    }

    private var canvasSubheadText: String {
        guard dashboardUsageWindow.sessionCount > 0 else {
            return "Provider logos will emerge from the kernel as sessions land. Nothing has been recorded in this window yet."
        }
        let sessions = dashboardUsageWindow.sessionCount.formatted()
        return "\(totalCostForTimeRange.formatAsCost()) across \(sessions) sessions and \(activeProviderCount) provider\(activeProviderCount == 1 ? "" : "s") this \(selectedTimeRange.displayName.lowercased()). Provider logos emerge from the kernel and dissolve back into it."
    }

    // MARK: Curve

    /// Plateless by design — `AtelierSpendCurve` was written for exactly this
    /// spot and floats on the substrate instead of boxing it.
    private var canvasCurve: some View {
        AtelierSpendCurve(
            usages: dashboardUsageWindow.usages,
            usagesRevision: dataStore.usagesVersion,
            range: dashboardDateRange
        )
    }

    // MARK: Numbers

    /// Three numbers, inline, no plates, separated by hairlines rather than by
    /// card edges. The whole point is that they read as a caption to the kernel.
    private var canvasNumbers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(canvasFacts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 {
                        Rectangle()
                            .fill(dashboardSectionInk.hairline)
                            .frame(width: 0.5, height: 48)
                            .padding(.horizontal, DesignSystem.Spacing.xl)
                            .accessibilityHidden(true)
                    }
                    DashboardSectionValue(
                        label: fact.label,
                        value: fact.value,
                        accent: fact.accent,
                        size: 30
                    )
                }
            }
            DashboardMetricLadder(facts: canvasFacts, rowPadding: DesignSystem.Spacing.sm)
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 3)
    }

    /// Burn, tokens, sessions. Three, not six — six is Bento.
    private var canvasFacts: [(label: String, value: String, accent: Color)] {
        Array(conceptWindowFacts.prefix(3))
    }
}
