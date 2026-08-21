import OpenBurnBarCore
import SwiftUI

// MARK: - Focus (storage id `aurora`)
//
// For the person who opens the dashboard with exactly one question: *how much?*
//
// Thesis: one number, big enough to read from across the room, and nothing else
// competing with it. Everything the other layouts spread across a page is folded
// into a single supporting section underneath and a collapsed drawer below that.
//
// Primary axis: vertical, single narrow column. Dominant element: the number.
// Density: the lowest of the eight — this layout deliberately wastes space,
// because the whitespace is what makes the answer unambiguous.
//
// Enforced rule: **exactly one number above the fold.** The answer block is the
// only place in this file that renders type above `Typography.headline`, and the
// supporting facts are metric *rows*, never tiles. If a second large number ever
// shows up here, this layout has become Bento and should be deleted.

extension DashboardView {
    var auroraLayout: some View {
        conceptCanvas(
            maxWidth: 720,
            spacing: DesignSystem.Spacing.xl,
            gutter: DesignSystem.Spacing.xxl
        ) {
            conceptUpdateBanner
            focusAnswer
            focusSupport
            conceptDetailsDrawer(includesLiveCurve: false)
        }
    }

    /// The answer. One value, one sentence, one curve for context.
    private var focusAnswer: some View {
        DashboardSection(
            "Burn · \(selectedTimeRange.displayName)",
            accent: DesignSystem.Colors.whimsy,
            emphasis: .featured
        ) {
            VStack(spacing: DesignSystem.Spacing.lg) {
                Text(totalCostForTimeRange.formatAsCost())
                    .font(.system(size: 66, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [DesignSystem.Colors.whimsy, DesignSystem.Colors.ember],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .allowsTightening(true)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: totalCostForTimeRange)
                    .accessibilityLabel("Total burn \(totalCostForTimeRange.formatAsCost())")

                Text(focusSentence)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(dashboardSectionInk.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                liveCostCurveBand
                    .frame(height: 104)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// One sentence, assembled rather than templated, so it stays true when the
    /// window is empty or single-provider.
    private var focusSentence: String {
        guard dashboardUsageWindow.sessionCount > 0 else {
            return "No spend recorded in this window yet."
        }
        let sessions = "\(dashboardUsageWindow.sessionCount.formatted()) session\(dashboardUsageWindow.sessionCount == 1 ? "" : "s")"
        guard let leader = topProviderSummary else { return "Across \(sessions)." }
        let share = totalCostForTimeRange > 0
            ? Int(((leader.totalCost / totalCostForTimeRange) * 100).rounded())
            : 0
        return "Across \(sessions). \(leader.provider.displayName) is \(share)% of it."
    }

    /// Everything else, as rows. Rows and not tiles because a tile is a second
    /// number competing with the answer, which is the one thing this layout
    /// refuses to do.
    private var focusSupport: some View {
        DashboardSection("Supporting", density: .compact, emphasis: .quiet) {
            DashboardMetricLadder(facts: focusSupportFacts)
        }
    }

    /// The window facts minus the headline burn — it is already the answer.
    private var focusSupportFacts: [(label: String, value: String, accent: Color)] {
        Array(conceptWindowFacts.dropFirst())
    }
}
