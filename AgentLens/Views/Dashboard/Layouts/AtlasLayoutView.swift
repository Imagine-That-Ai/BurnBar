import OpenBurnBarCore
import SwiftUI

// MARK: - Atlas (storage id `atlas`)
//
// For the comparative thinker — the person who does not want a total, they want
// to know which of two things is winning and whether that changed.
//
// Thesis: two ranked ladders side by side, providers against models, every row
// carrying its share of the window *and* a signed delta. Nothing here is a
// single figure in isolation; every number is presented next to the number it
// should be judged against.
//
// Primary axis: horizontal — the comparison is left-versus-right.
// Dominant element: the paired ladders. Density: high, but wide rather than tall.
//
// Enforced rule: **every row carries a comparison.** A share bar, a delta chip,
// or both. A row here with a bare number has failed the layout's only job, and
// belongs in Ledger.
//
// About the delta: it is the window's own second half against its first half, not
// this period against the last one. That is a deliberate trade. A previous-period
// comparison needs a second window query and silently lies at range boundaries
// (yesterday vs "today so far" is not a fair fight); an in-window split is
// computed from rows already loaded, is always a like-for-like duration, and is
// labelled as what it is everywhere it appears.

extension DashboardView {
    var atlasLayout: some View {
        conceptCanvas(spacing: DesignSystem.Spacing.md) {
            conceptUpdateBanner
            atlasSplitHeader
            atlasLadders
            atlasShapeBand
            conceptDetailsDrawer(includesLiveCurve: false)
        }
    }

    // MARK: Header — the window against itself

    private var atlasSplitHeader: some View {
        DashboardSection(
            "Second half vs first half",
            title: selectedTimeRange.displayName,
            accent: DesignSystem.Colors.whimsy,
            density: .compact,
            emphasis: .featured,
            accessory: {
                DashboardDeltaChip(delta: atlasWindowDelta)
            },
            content: {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                        atlasHalfCells
                    }
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        atlasHalfCells
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var atlasHalfCells: some View {
        DashboardSectionValue(
            label: "First half",
            value: atlasHalves.first.formatAsCost(),
            accent: dashboardSectionInk.secondary,
            size: 26
        )
        DashboardSectionValue(
            label: "Second half",
            value: atlasHalves.second.formatAsCost(),
            accent: DesignSystem.Colors.whimsy,
            size: 26
        )
        DashboardSectionValue(
            label: "Whole window",
            value: totalCostForTimeRange.formatAsCost(),
            accent: DesignSystem.Colors.ember,
            size: 26
        )
    }

    // MARK: The paired ladders

    private var atlasLadders: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                atlasProviderLadder.frame(maxWidth: .infinity)
                atlasModelLadder.frame(maxWidth: .infinity)
            }
            VStack(spacing: DesignSystem.Spacing.md) {
                atlasProviderLadder
                atlasModelLadder
            }
        }
    }

    private var atlasProviderLadder: some View {
        DashboardSection(
            "Providers",
            accent: DesignSystem.Colors.ember,
            density: .compact,
            accessory: { atlasDeltaLegend },
            content: {
                DashboardRankedTable(
                    items: atlasProviderRows,
                    emptyMessage: "No provider activity in this window.",
                    onSelect: { item in
                        guard let provider = item.provider else { return }
                        conceptOpenProvider(provider, lane: "atlas_provider")
                    }
                )
            }
        )
    }

    private var atlasModelLadder: some View {
        DashboardSection(
            "Models",
            accent: DesignSystem.Colors.blaze,
            density: .compact,
            accessory: { atlasDeltaLegend },
            content: {
                DashboardRankedTable(
                    items: atlasModelRows,
                    limit: 10,
                    emptyMessage: "No model activity in this window."
                )
            }
        )
    }

    /// Says what the chips mean, once per ladder. A delta without a stated basis
    /// is decoration.
    private var atlasDeltaLegend: some View {
        Text("Δ 2ND HALF")
            .font(DesignSystem.Typography.tiny)
            .tracking(1.1)
            .foregroundStyle(dashboardSectionInk.subtle)
    }

    // MARK: Shape

    /// The stacked provider ribbon, which is the one view in the app that already
    /// answers "who grew and who shrank" visually rather than numerically.
    private var atlasShapeBand: some View {
        DashboardSection(
            "Shape of the window",
            accent: DesignSystem.Colors.amber,
            density: .flush
        ) {
            AtelierSpendCurve(
                usages: dashboardUsageWindow.usages,
                usagesRevision: dataStore.usagesVersion,
                range: dashboardDateRange,
                title: "PROVIDER BURN OVER TIME",
                height: 200
            )
            .padding(.horizontal, DesignSystem.Spacing.md)
        }
    }

    // MARK: Comparison model

    /// The window split at its own midpoint.
    ///
    /// The midpoint comes from the selected range when there is one, and from the
    /// data's own extent for All Time, so the split is never off the end of the
    /// rows it is dividing.
    private var atlasMidpoint: Date? {
        if let range = dashboardDateRange, range.lowerBound < range.upperBound {
            return range.lowerBound.addingTimeInterval(
                range.upperBound.timeIntervalSince(range.lowerBound) / 2
            )
        }
        let stamps = dashboardUsageWindow.usages.map { max($0.startTime, $0.endTime) }
        guard let low = stamps.min(), let high = stamps.max(), low < high else { return nil }
        return low.addingTimeInterval(high.timeIntervalSince(low) / 2)
    }

    private var atlasHalves: (first: Double, second: Double) {
        guard let midpoint = atlasMidpoint else { return (0, totalCostForTimeRange) }
        var first = 0.0
        var second = 0.0
        for usage in dashboardUsageWindow.usages {
            let stamp = max(usage.startTime, usage.endTime)
            if stamp < midpoint {
                first += max(0, usage.cost)
            } else {
                second += max(0, usage.cost)
            }
        }
        return (first, second)
    }

    private var atlasWindowDelta: Double {
        atlasDelta(first: atlasHalves.first, second: atlasHalves.second)
    }

    /// Fractional change from `first` to `second`.
    ///
    /// A zero baseline has no defined percentage change, so anything appearing
    /// only in the second half reports flat rather than an invented `+∞`. The
    /// share bar next to it already shows that the row is new.
    private func atlasDelta(first: Double, second: Double) -> Double {
        guard first > 1e-9 else { return 0 }
        return (second - first) / first
    }

    /// Per-key half-window costs, keyed the same way the ranked rows are, so a
    /// row and its delta can never come from different groupings.
    private func atlasHalfCosts(
        key: (TokenUsage) -> String?
    ) -> [String: (first: Double, second: Double)] {
        guard let midpoint = atlasMidpoint else { return [:] }
        var result: [String: (first: Double, second: Double)] = [:]
        for usage in dashboardUsageWindow.usages {
            guard let id = key(usage) else { continue }
            let cost = max(0, usage.cost)
            let stamp = max(usage.startTime, usage.endTime)
            var bucket = result[id] ?? (first: 0, second: 0)
            if stamp < midpoint {
                bucket.first += cost
            } else {
                bucket.second += cost
            }
            result[id] = bucket
        }
        return result
    }

    private var atlasProviderRows: [DashboardRankedItem] {
        let halves = atlasHalfCosts { "provider-\($0.provider.rawValue)" }
        return conceptProviderRows.map { row in
            var updated = row
            if let bucket = halves[row.id] {
                updated.delta = atlasDelta(first: bucket.first, second: bucket.second)
            }
            return updated
        }
    }

    private var atlasModelRows: [DashboardRankedItem] {
        let halves = atlasHalfCosts { "model-\($0.model)" }
        return conceptModelRows.map { row in
            var updated = row
            if let bucket = halves[row.id] {
                updated.delta = atlasDelta(first: bucket.first, second: bucket.second)
            }
            return updated
        }
    }
}
