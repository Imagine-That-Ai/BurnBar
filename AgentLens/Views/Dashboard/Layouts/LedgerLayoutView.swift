import OpenBurnBarUI
import SwiftUI

// MARK: - Ledger (storage id `classic`)
//
// For the sequential reader — the person who reads a dashboard the way they read
// a bank statement: from the top, in order, all the way down.
//
// Thesis: one ordered column of numbered sections, dense tabular rows, and no
// hero. Order carries the meaning. Section 01 is the window, 02 is the shape of
// it over time, 03 is where it went by provider, 04 by model, 05 the sessions
// that produced it, 06 the narrative. Read it once and you have read everything.
//
// Primary axis: vertical, single column, strictly ordered. Dominant element:
// none — the *sequence* is the structure. Density: high; second only to Cockpit.
//
// Enforced rule: **no hero.** Nothing in this file renders type larger than
// `Typography.headline`. Every number is a monospaced value in a
// `DashboardSectionMetric` or a `DashboardRankedRow`, sitting in the same column
// as the number above it, because a column of aligned figures is the entire
// point of a ledger. The moment a 60pt figure appears here the layout is Focus.

extension DashboardView {
    /// Rendered by `overviewView`, which keeps the scroll-geometry probe, the
    /// easter-egg overlay, and the first-view analytics that every route needs.
    /// This is the content, not the scaffold.
    @ViewBuilder
    var ledgerContent: some View {
        ledgerSection(
            "01",
            "Window",
            accent: DesignSystem.Colors.whimsy,
            accessory: selectedTimeRange.displayName
        ) {
            VStack(spacing: 0) {
                DashboardMetricLadder(facts: conceptWindowFacts)
                DashboardSectionRule()
                DashboardSectionMetric(
                    label: "Sessions on this machine",
                    value: dataStore.totalUsageSessionCount.formatted(),
                    caption: dataStore.lastRefresh.map {
                        "last refresh \($0.formatted(date: .omitted, time: .shortened))"
                    }
                )
                .padding(.vertical, 7)
            }
        }

        ledgerSection("02", "Cost over time", accent: DesignSystem.Colors.ember, density: .flush) {
            liveCostCurveBand
                .frame(height: 180)
        }

        ledgerSection(
            "03",
            "By provider",
            accent: DesignSystem.Colors.ember,
            accessory: "\(dashboardProviderSummaries.count) active"
        ) {
            DashboardRankedTable(
                items: conceptProviderRows,
                emptyMessage: "No provider activity in this window.",
                onSelect: { item in
                    guard let provider = item.provider else { return }
                    conceptOpenProvider(provider, lane: "ledger_provider")
                }
            )
        }

        ledgerSection(
            "04",
            "By model",
            accent: DesignSystem.Colors.blaze,
            accessory: "\(dashboardModelSummaries.count) seen"
        ) {
            DashboardRankedTable(
                items: conceptModelRows,
                emptyMessage: "No model activity in this window."
            )
        }

        ledgerSection("05", "Sessions", accent: DesignSystem.Colors.amber, density: .flush) {
            activityLane
        }

        ledgerSection("06", "Notes", accent: DesignSystem.Colors.success, density: .flush) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                NarrativeCardView(dataStore: dataStore)
                CastleGreatHallContainer()
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
        }
    }

    /// A numbered ledger section. The number is the navigation — it is why this
    /// layout does not need a hero to tell you where to start.
    private func ledgerSection<Content: View>(
        _ number: String,
        _ title: String,
        accent: Color,
        density: DashboardSectionDensity = .compact,
        accessory: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DashboardSection(
            "\(number) · \(title)",
            accent: accent,
            density: density,
            emphasis: .standard,
            accessory: {
                if let accessory {
                    Text(accessory.uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .tracking(1.1)
                        .foregroundStyle(dashboardSectionInk.subtle)
                }
            },
            content: content
        )
    }
}
