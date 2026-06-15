import Charts
import SwiftUI
import OpenBurnBarCore

// MARK: - Fusion Impact Screen
//
// The standing "Fusion impact" surface for The Elder Wand: a durable,
// period-scoped read of how much fusion has cost versus normal requests, what
// each model contributed, how many runs ran, and how much of the fusion-search
// allowance is left.
//
// Where the end-of-session receipt modal answers "what did *this* run cost?",
// this screen answers "what is fusion costing me over time, and is it worth
// it?". It reads the canonical `token_usage` table through `FusionImpactLedger`
// (rows tagged `parentRequestID LIKE 'elderwand-%'` are fusion), and partitions
// them with the same `FusionSpendAggregator.partition(_:)` the modal uses, so
// the two surfaces can never disagree.
//
// The period quota ring is fed by an injected `ProviderQuotaBucket?` sourced
// from `users/{uid}/quota_snapshots/openburnbar_elder_wand_fusion`. Its limit is
// already `min(monthlyCap, included + purchased)`, so this screen NEVER
// re-derives it from a tier — it renders the bucket verbatim and self-hides the
// ring when no quota signal is present.

struct FusionImpactView: View {
    private let dataStore: DataStore
    private let fusionQuotaBucket: ProviderQuotaBucket?

    @State private var model: FusionImpactModel

    /// - Parameters:
    ///   - dataStore: the canonical store; the screen reads `token_usage`
    ///     through its `dbQueue` via `FusionImpactLedger`.
    ///   - fusionQuotaBucket: the fusion-search allowance for the ring, sourced
    ///     from the `openburnbar_elder_wand_fusion` quota snapshot. Pass `nil`
    ///     when no quota signal is available — the ring self-hides.
    init(dataStore: DataStore, fusionQuotaBucket: ProviderQuotaBucket? = nil) {
        self.dataStore = dataStore
        self.fusionQuotaBucket = fusionQuotaBucket
        _model = State(initialValue: FusionImpactModel(dataStore: dataStore))
    }

    var body: some View {
        SettingsDetailContainer(
            title: "Fusion Impact",
            subtitle: "What The Elder Wand spent — fusion runs versus your normal requests over the period.",
            searchRoute: .fusionImpact
        ) {
            FusionPeriodPicker(selection: $model.period)
                .id(SettingsAnchor.fusionImpactPeriod)

            switch model.phase {
            case .loading:
                FusionImpactLoadingCard()
            case .failed:
                FusionImpactErrorCard { Task { await model.reload() } }
            case .loaded(let totals):
                FusionImpactContent(
                    totals: totals,
                    period: model.period,
                    fusionQuotaBucket: fusionQuotaBucket
                )
            }
        }
        .task(id: model.period) {
            await model.reload()
        }
    }
}

// MARK: - Period

/// The two windows the impact screen supports. `Identifiable` so the picker's
/// `ForEach` has stable identity without leaning on `.indices`.
enum FusionImpactPeriod: String, CaseIterable, Identifiable, Hashable {
    case thisMonth
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth: return "This Month"
        case .last30Days: return "Last 30 Days"
        }
    }

    /// `[start, end]` for the window, evaluated against `reference`.
    func window(reference: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        switch self {
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: reference)?.start
                ?? calendar.startOfDay(for: reference)
            return start...reference
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: reference)
                ?? reference.addingTimeInterval(-30 * 24 * 60 * 60)
            return start...reference
        }
    }
}

// MARK: - View Model

/// View-owned loader: holds the selected period and the partitioned totals, and
/// runs the SQL read off the main actor through `FusionImpactLedger`.
@Observable
@MainActor
final class FusionImpactModel {
    enum Phase {
        case loading
        case loaded(FusionVsNormalTotals)
        case failed
    }

    var period: FusionImpactPeriod = .thisMonth
    private(set) var phase: Phase = .loading

    private let ledger: FusionImpactLedger

    init(dataStore: DataStore) {
        // `dbQueue` is `nonisolated` on the store; the ledger is an actor that
        // does all DB I/O off the main thread, so the view never blocks.
        self.ledger = FusionImpactLedger(dbQueue: dataStore.dbQueue)
    }

    func reload() async {
        let window = period.window()
        do {
            let totals = try await ledger.totals(from: window.lowerBound, to: window.upperBound)
            phase = .loaded(totals)
        } catch {
            phase = .failed
        }
    }
}

// MARK: - Period Picker

private struct FusionPeriodPicker: View {
    @Binding var selection: FusionImpactPeriod

    var body: some View {
        Picker("Period", selection: $selection) {
            ForEach(FusionImpactPeriod.allCases) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Reporting period")
    }
}

// MARK: - Loaded content

private struct FusionImpactContent: View {
    let totals: FusionVsNormalTotals
    let period: FusionImpactPeriod
    let fusionQuotaBucket: ProviderQuotaBucket?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            FusionHeadlineCard(totals: totals, period: period)

            FusionComparisonChartCard(totals: totals)

            FusionRunStatsCard(totals: totals)

            if !totals.fusionCostByModel.isEmpty {
                FusionModelContributionCard(totals: totals)
            }

            if let bucket = fusionQuotaBucket {
                FusionQuotaMeterCard(bucket: bucket)
            }
        }
        .animation(DesignSystem.Animation.gentle, value: totals)
    }
}

// MARK: - Headline

private struct FusionHeadlineCard: View {
    let totals: FusionVsNormalTotals
    let period: FusionImpactPeriod

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Fusion spend · \(period.title)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Text(CurrencyFormatting.usd(totals.fusionCost))
                    .font(DesignSystem.Typography.monoLarge)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .contentTransition(.numericText())

                Text("\(Self.percent(totals.fusionShareFraction)) of your \(CurrencyFormatting.usd(totals.totalCost)) total spend this period.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fusion spend \(period.title)")
        .accessibilityValue("\(CurrencyFormatting.usd(totals.fusionCost)), \(Self.percent(totals.fusionShareFraction)) of total spend")
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Comparison chart

private struct FusionComparisonChartCard: View {
    let totals: FusionVsNormalTotals

    /// Stable, identifiable rows for the bar chart.
    private struct Bar: Identifiable {
        let id: String
        let category: String
        let cost: Double
    }

    private var bars: [Bar] {
        [
            Bar(id: "fusion", category: "Fusion", cost: totals.fusionCost),
            Bar(id: "normal", category: "Normal", cost: totals.normalCost)
        ]
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Fusion vs Normal")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("How fusion spend compares to everything else.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if #available(macOS 13, *) {
                    chart
                } else {
                    FusionComparisonBarFallback(bars: bars.map { ($0.category, $0.cost) })
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @available(macOS 13, *)
    private var chart: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Category", bar.category),
                y: .value("Cost", bar.cost)
            )
            .foregroundStyle(by: .value("Category", bar.category))
            .cornerRadius(6)
            .annotation(position: .top) {
                Text(CurrencyFormatting.usd(bar.cost))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .chartForegroundStyleScale([
            "Fusion": DesignSystem.Colors.whimsy,
            "Normal": DesignSystem.Colors.textSecondary
        ])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(DesignSystem.Colors.border)
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(CurrencyFormatting.usdCompact(cost))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 180)
        .accessibilityLabel("Fusion versus normal spend comparison")
    }
}

/// Pre-macOS-13 fallback: a labeled proportional bar pair without Swift Charts.
private struct FusionComparisonBarFallback: View {
    let bars: [(category: String, cost: Double)]

    private var maxCost: Double {
        max(bars.map(\.cost).max() ?? 0, 0.0001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(bars, id: \.category) { bar in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(bar.category)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer()
                        Text(CurrencyFormatting.usd(bar.cost))
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(bar.category == "Fusion" ? DesignSystem.Colors.whimsy : DesignSystem.Colors.textSecondary)
                            .frame(width: max(2, geo.size.width * CGFloat(bar.cost / maxCost)))
                    }
                    .frame(height: 10)
                }
            }
        }
        .frame(height: 70)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Run stats

private struct FusionRunStatsCard: View {
    let totals: FusionVsNormalTotals

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                FusionStatTile(
                    label: "Fusion runs",
                    value: "\(totals.fusionRuns)",
                    caption: "panel + judge + final"
                )
                Divider()
                FusionStatTile(
                    label: "Avg / run",
                    value: totals.averageCostPerFusionRun.map(CurrencyFormatting.usd) ?? "—",
                    caption: "across the period"
                )
                Divider()
                FusionStatTile(
                    label: "Cost of certainty",
                    value: Self.multiplierText(totals),
                    caption: "vs a single answer"
                )
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The period-level multiplier: total fusion spend over the implied solo
    /// baseline (one normal answer per fusion run, approximated by the average
    /// normal cost). Omitted when there is no positive baseline.
    private static func multiplierText(_ totals: FusionVsNormalTotals) -> String {
        guard totals.fusionRuns > 0, totals.fusionCost > 0 else { return "—" }
        // Approximate solo baseline = average normal request cost × fusion runs.
        // Falls back to the average fusion-run cost when there is no normal spend
        // to compare against, which yields ×1 — honestly "no comparison".
        let baseline: Double
        if totals.normalCost > 0, totals.normalTokens > 0 {
            let avgNormal = totals.normalCost / Double(max(1, normalRequestEstimate(totals)))
            baseline = avgNormal * Double(totals.fusionRuns)
        } else {
            baseline = totals.fusionCost
        }
        guard baseline > 0 else { return "—" }
        let multiplier = totals.fusionCost / baseline
        return String(format: "×%.1f", multiplier)
    }

    /// Rough request count for the normal partition, used only to derive an
    /// average normal cost. We don't store a per-request count, so we treat the
    /// fusion run count as a proxy for comparable normal requests — keeping the
    /// multiplier a conservative, clearly-approximate signal.
    private static func normalRequestEstimate(_ totals: FusionVsNormalTotals) -> Int {
        max(totals.fusionRuns, 1)
    }
}

private struct FusionStatTile: View {
    let label: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(value)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .contentTransition(.numericText())
            Text(caption)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Per-model contribution

private struct FusionModelContributionCard: View {
    let totals: FusionVsNormalTotals

    /// Stable, identifiable, descending-by-cost contribution rows.
    private struct Contribution: Identifiable {
        let id: String
        let modelID: String
        let cost: Double
        var fraction: Double
    }

    private var contributions: [Contribution] {
        let total = max(totals.fusionCost, 0.0001)
        return totals.fusionCostByModel
            .map { Contribution(id: $0.key, modelID: $0.key, cost: $0.value, fraction: $0.value / total) }
            .sorted { $0.cost > $1.cost }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Where fusion spend went")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Each model's share of fusion cost this period.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(contributions) { contribution in
                    FusionModelRow(
                        modelID: contribution.modelID,
                        cost: contribution.cost,
                        fraction: contribution.fraction
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FusionModelRow: View {
    let modelID: String
    let cost: Double
    let fraction: Double

    private var color: Color { DesignSystem.Colors.colorForModel(modelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(TokenExtractionUtility.displayNameForModel(modelID))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Text(CurrencyFormatting.usd(cost))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.85))
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
            .frame(height: 6)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(DesignSystem.Colors.border.opacity(0.4))
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TokenExtractionUtility.displayNameForModel(modelID))
        .accessibilityValue("\(CurrencyFormatting.usd(cost)), \(Int((fraction * 100).rounded())) percent of fusion spend")
    }
}

// MARK: - Quota meter

private struct FusionQuotaMeterCard: View {
    let bucket: ProviderQuotaBucket

    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 96

    private var usedFraction: Double {
        min(max(bucket.progressFraction, 0), 1)
    }

    var body: some View {
        GlassCard {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
                ring
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fusion searches")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(bucket.usageText)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    if let resets = bucket.resetsAtDisplay {
                        Text("Resets \(resets.relative)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    if bucket.isEstimated {
                        Text("Estimated")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fusion searches allowance")
        .accessibilityValue(bucket.usageText)
    }

    @ViewBuilder
    private var ring: some View {
        if #available(macOS 13, *) {
            sectorRing
        } else {
            strokeRing
        }
    }

    @available(macOS 13, *)
    private var sectorRing: some View {
        Chart {
            SectorMark(
                angle: .value("Used", usedFraction),
                innerRadius: .ratio(0.68),
                angularInset: 1.5
            )
            .foregroundStyle(DesignSystem.Colors.whimsy)
            SectorMark(
                angle: .value("Remaining", max(0, 1 - usedFraction)),
                innerRadius: .ratio(0.68),
                angularInset: 1.5
            )
            .foregroundStyle(DesignSystem.Colors.border.opacity(0.5))
        }
        .chartLegend(.hidden)
        .frame(width: ringSize, height: ringSize)
        .overlay { ringCenterLabel }
        .accessibilityHidden(true)
    }

    private var strokeRing: some View {
        ZStack {
            Circle()
                .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(usedFraction))
                .stroke(DesignSystem.Colors.whimsy, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ringCenterLabel
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityHidden(true)
    }

    private var ringCenterLabel: some View {
        Text(bucket.remainingText)
            .font(DesignSystem.Typography.monoSmall)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
    }
}

// MARK: - Loading / error states

private struct FusionImpactLoadingCard: View {
    var body: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading fusion spend…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FusionImpactErrorCard: View {
    let retry: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Couldn't read fusion spend")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("The usage ledger couldn't be read for this period.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Currency formatting

private enum CurrencyFormatting {
    static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// Compact axis form: "$1.2K", "$340", "$0.40".
    static func usdCompact(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "$%.1fK", value / 1_000)
        }
        if value >= 1 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }
}
