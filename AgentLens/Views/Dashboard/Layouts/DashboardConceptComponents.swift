import Charts
import OpenBurnBarCore
import SwiftUI

// MARK: - Shared concept building blocks
//
// Helpers reused by every named dashboard layout concept (Aurora, Nebula,
// Constellation, Cockpit, Atelier). Kept as `DashboardView` extension members
// so they can reach the view's data (`dashboardProviderSummaries`, the live
// cost curve, the lanes) without threading state through initializers.

extension DashboardView {

    /// Same non-MAS update prompt Classic renders at the top of Overview. Concept
    /// layouts call this before their hero so update availability is never hidden
    /// behind a collapsed details drawer.
    @ViewBuilder
    var conceptUpdateBanner: some View {
        #if !DISTRIBUTION_MAS
        UpdateBannerCard()
        #endif
    }

    /// The scroll scaffold every named layout sits in.
    ///
    /// Shared deliberately: eight layouts should differ in *composition*, not in
    /// how each one handles scrolling, width clamping, page background, and the
    /// appear hook. Those four were copy-pasted per layout and drifted every
    /// time one of them was touched — three different `maxWidth` clamps and two
    /// different background rules, none of them intentional.
    ///
    /// What a layout still chooses: rail width, column axis, section order,
    /// density, and the gutter, because those are the thesis.
    func conceptCanvas<Content: View>(
        maxWidth: CGFloat = DashboardLayoutMetrics.contentMaxWidth,
        spacing: CGFloat = DesignSystem.Spacing.lg,
        alignment: HorizontalAlignment = .leading,
        gutter: CGFloat = DesignSystem.Spacing.xl,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: alignment, spacing: spacing) {
                content()
            }
            .padding(gutter)
            .frame(maxWidth: maxWidth, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardPageBackground(liveBackdropActive: dashboardLiveBackdropActive)
        .onAppear { overviewAppeared = true }
    }

    /// The ink a layout draws with when it needs a colour *outside* a view body
    /// (string interpolation into a `foregroundStyle`, a chart series, a shape
    /// fill computed in a helper).
    ///
    /// `DashboardSection` and its atoms read `\.backdropInk` from the
    /// environment, which `DashboardView.body` publishes once. Layout code that
    /// runs before that environment is readable resolves the same value here
    /// from the same two inputs, so the two can never disagree.
    var dashboardSectionInk: BackdropInk {
        BackdropInk.resolve(
            liveBackdropActive: dashboardLiveBackdropActive,
            profile: dashboardActiveReadabilityProfile
        )
    }

    /// The window's headline numbers, as data rather than as views.
    ///
    /// Every layout shows some subset of these; holding the tuples in one place
    /// is what keeps "Sessions" meaning the same thing in Ledger, Bento, and
    /// Cockpit instead of three near-identical inline literals.
    var conceptWindowFacts: [(label: String, value: String, accent: Color)] {
        [
            (
                "Burn · \(selectedTimeRange.displayName)",
                totalCostForTimeRange.formatAsCost(),
                DesignSystem.Colors.whimsy
            ),
            ("Tokens", totalTokensForTimeRange.formatted(), DesignSystem.Colors.ember),
            ("Sessions", dashboardUsageWindow.sessionCount.formatted(), DesignSystem.Colors.amber),
            (
                "Cache hit",
                dashboardUsageWindow.cacheEfficiency.formattedHitRate,
                CacheHitRateTier(dashboardUsageWindow.cacheEfficiency).color
            ),
            ("Providers", activeProviderCount.formatted(), DesignSystem.Colors.success),
            ("Models", dashboardModelSummaries.count.formatted(), DesignSystem.Colors.blaze)
        ]
    }

    /// Ranked provider rows with spend share, ready for any layout's table.
    var conceptProviderRows: [DashboardRankedItem] {
        let total = max(dashboardProviderSummaries.reduce(0) { $0 + $1.totalCost }, 0.0001)
        return dashboardProviderSummaries.enumerated().map { index, summary in
            DashboardRankedItem(
                id: "provider-\(summary.provider.rawValue)",
                rank: index + 1,
                title: summary.provider.displayName,
                subtitle: "\(summary.sessionCount.formatted()) sessions · \(summary.totalTokens.formatted()) tokens",
                value: summary.formattedCost,
                share: summary.totalCost / total,
                accent: DesignSystem.Colors.primary(for: summary.provider),
                provider: summary.provider
            )
        }
    }

    /// Ranked model rows with spend share.
    var conceptModelRows: [DashboardRankedItem] {
        let total = max(dashboardModelSummaries.reduce(0) { $0 + $1.totalCost }, 0.0001)
        return dashboardModelSummaries.enumerated().map { index, summary in
            DashboardRankedItem(
                id: "model-\(summary.modelName)",
                rank: index + 1,
                title: summary.displayName,
                subtitle: "\(summary.sessionCount.formatted()) sessions · \(summary.totalTokens.formatted()) tokens",
                value: summary.formattedCost,
                share: summary.totalCost / total,
                accent: summary.providerBreakdown.first
                    .map { DesignSystem.Colors.primary(for: $0.provider) } ?? DesignSystem.Colors.ember,
                provider: summary.providerBreakdown.first?.provider
            )
        }
    }

    /// The collapsed "more details" drawer every concept embeds beneath its
    /// curated hero. It carries every Classic-only section a concept does not
    /// already show directly, so curated layouts never lose Overview information.
    func conceptDetailsDrawer(includesLiveCurve: Bool = true, includesCastle: Bool = true) -> some View {
        ConceptMoreDrawer {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                if includesLiveCurve {
                    conceptCurveCard.frame(height: 170)
                }
                if includesCastle {
                    CastleGreatHallContainer()
                }
                NarrativeCardView(dataStore: dataStore)
                providerLane
                modelLane
                activityLane
            }
        }
    }

    var conceptMoreDrawer: some View {
        conceptDetailsDrawer()
    }

    /// The shared live cost curve wrapped in a glass card. Reached only through
    /// `conceptDetailsDrawer`; the curated layouts render their curves inside
    /// `DashboardSection` plates.
    var conceptCurveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Cumulative Cost")
                    .font(DesignSystem.Typography.tiny)
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                liveCostCurveBand
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DesignSystem.Spacing.lg)
        }
    }

    /// Provider drill-in used by the concept rails.
    func conceptOpenProvider(_ provider: AgentProvider, lane: String) {
        Analytics.shared.track(.dashboardLaneCardOpened, ["lane": .string(lane)])
        withAnimation(DesignSystem.Animation.standard) {
            navigate(to: .provider(provider))
        }
    }
}

// MARK: - Atelier Spend Curve
//
// A stacked "area under curve" of provider burn across the active window, sized
// to fill the open space in the Atelier hero between the editorial headline and
// the three stat tiles. It floats directly on the live kernel backdrop — no
// opaque plate — so the substrate keeps showing through.
//
// Design:
//   * One translucent brand-tinted ribbon per provider (top ~5 by spend), with
//     the remainder folded into a single muted "Other" cap so the chart never
//     gets noisy.
//   * Manual stacking (explicit base/top per bucket) so each ribbon and its
//     crisp top stroke share identical monotone curves and nest seamlessly.
//   * Brand-colour vertical gradient fill (≈0.55 → 0.04 alpha) + a brighter
//     1.4pt top stroke with a soft brand glow for definition.
//   * Minimal chrome: a faint zero baseline, 3 currency y-ticks and 4 sparse
//     date x-ticks in `textMuted`, no boxy border.
//   * Graceful at the edges: a single provider reads as one smooth filled
//     curve; genuinely empty windows fall back to a tasteful dashed baseline
//     with a muted caption.
//
// Hosted in this already-compiled file (the AgentLens target uses explicit
// project membership, not Xcode synchronized folders) rather than a new
// standalone source file.

struct AtelierSpendCurve: View {

    /// Usage rows for the active window (already filtered to `range`).
    let usages: [TokenUsage]
    /// Explicit observation token bumped whenever mined usage is replaced.
    /// This keeps the chart's redraw contract aligned with the toolbar and
    /// ``DashboardLiveCostCurve`` even when the filtered row count is stable.
    var usagesRevision: Int = 0
    /// The selected window. `nil` == "All Time" → derived from the data.
    let range: ClosedRange<Date>?
    var title: String = "PROVIDER BURN OVER TIME"
    var height: CGFloat = 176

    /// Cap on individually-coloured provider ribbons before folding into "Other".
    private let maxProviders = 5

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let model = buildModel()
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header(bands: model.bands, isEmpty: model.isEmpty)
            if model.isEmpty {
                emptyState
            } else {
                chart(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: usagesRevision)
    }

    // MARK: - Header + legend

    private func header(bands: [AtelierSpendBand], isEmpty: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: DesignSystem.Spacing.sm)
            if !isEmpty {
                legend(bands: bands)
            }
        }
    }

    private func legend(bands: [AtelierSpendBand]) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ForEach(bands) { band in
                HStack(spacing: 5) {
                    Circle()
                        .fill(band.color)
                        .frame(width: 7, height: 7)
                    Text(band.label)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Chart

    private func chart(_ model: AtelierSpendModel) -> some View {
        // Two synthetic categories per band — one for the gradient fill, one
        // (suffixed) for the near-solid top stroke — so a single foreground
        // style scale styles both while keeping every ribbon its own series
        // (Charts never connects across distinct series).
        let scaleDomain = model.bands.map(\.id) + model.bands.map { $0.id + strokeSuffix }
        let scaleRange = model.bands.map { areaGradient($0.color) }
            + model.bands.map { strokeGradient($0.color) }

        return Chart {
            RuleMark(y: .value("Zero", 0.0))
                .foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.75))

            ForEach(model.bands) { band in
                ForEach(band.points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Base", point.base),
                        yEnd: .value("Top", point.top)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Series", band.id))
                }
            }

            ForEach(model.bands) { band in
                ForEach(band.points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Top", point.top)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(by: .value("Series", band.id + strokeSuffix))
                    .shadow(color: band.color.opacity(0.28), radius: 4, x: 0, y: 2)
                }
            }
        }
        .chartForegroundStyleScale(domain: scaleDomain, range: scaleRange)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...model.yMax)
        .chartXScale(domain: model.xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.35))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(raw.formatAsCostCompact())
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(
                    format: model.granularity.axisFormat,
                    centered: false,
                    collisionResolution: .greedy(minimumSpacing: 8)
                )
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .frame(height: height)
        .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            Chart {
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 6]))
            }
            .chartYScale(domain: -1.0...1.0)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: height)

            Text("No spend in this range")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(height: height)
    }

    // MARK: - Styling

    private let strokeSuffix = "\u{2063}stroke" // invisible separator → unique series key

    private func areaGradient(_ color: Color) -> LinearGradient {
        let topAlpha = colorScheme == .dark ? 0.60 : 0.50
        let midAlpha = colorScheme == .dark ? 0.26 : 0.20
        return LinearGradient(
            colors: [
                color.opacity(topAlpha),
                color.opacity(midAlpha),
                color.opacity(0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func strokeGradient(_ color: Color) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.95), color.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Model

    /// Buckets `usages` by (time bucket, provider), folds all but the top
    /// `maxProviders` into a muted "Other" cap, and pre-computes the stacked
    /// base/top for every ribbon so the chart never restacks per redraw.
    private func buildModel() -> AtelierSpendModel {
        let calendar = Calendar.current
        let now = Date()

        // 1. Resolve the time domain.
        let domain: ClosedRange<Date>
        if let range, range.lowerBound < range.upperBound {
            domain = range
        } else {
            let lows = usages.map { min($0.startTime, $0.endTime) }
            let highs = usages.map { max($0.startTime, $0.endTime) }
            if let lo = lows.min(), let hi = highs.max() {
                if lo < hi {
                    domain = lo...hi
                } else {
                    // All spend collapses to a single instant (one row, or
                    // zero-duration API/billing rows at the same time). Centre a
                    // small window on it instead of defaulting to the last 30
                    // days — which would drop spend older than 30 days and show
                    // an empty chart while the totals still report it.
                    let pad: TimeInterval = 12 * 60 * 60
                    domain = lo.addingTimeInterval(-pad)...hi.addingTimeInterval(pad)
                }
            } else {
                let lo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
                domain = lo...now
            }
        }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let granularity = AtelierSpendGranularity.choose(span: span)

        // 2. Bucket cost by provider; accumulate provider totals.
        var totals: [AgentProvider: Double] = [:]
        var bucketCosts: [Date: [AgentProvider: Double]] = [:]
        for usage in usages {
            let cost = max(0, usage.cost)
            guard cost > 0 else { continue }
            let lo = min(usage.startTime, usage.endTime)
            let hi = max(usage.startTime, usage.endTime)
            // The window's upstream filter uses intersects(dateRange:), so it
            // legitimately includes sessions that started before the window and
            // ended inside it. Skip only rows fully outside the domain; clamp
            // boundary-crossing rows' attribution into the domain instead of
            // dropping them, so the curve matches the surrounding Atelier totals.
            guard hi >= domain.lowerBound, lo <= domain.upperBound else { continue }
            let eventDate = min(max(lo, domain.lowerBound), domain.upperBound)
            let key = granularity.floor(eventDate, calendar: calendar)
            totals[usage.provider, default: 0] += cost
            bucketCosts[key, default: [:]][usage.provider, default: 0] += cost
        }

        let totalSpend = totals.values.reduce(0, +)
        guard totalSpend > 1e-9 else {
            return AtelierSpendModel(
                bands: [],
                xDomain: domain,
                yMax: 1,
                granularity: granularity,
                isEmpty: true
            )
        }

        // 3. Rank providers; fold the long tail into "Other".
        let ranked = totals.sorted { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value > rhs.value
                : lhs.key.displayName.localizedCaseInsensitiveCompare(rhs.key.displayName) == .orderedAscending
        }
        let mains = Array(ranked.prefix(maxProviders))
        let rest = ranked.dropFirst(maxProviders)
        let otherTotal = rest.reduce(0) { $0 + $1.value }
        let restProviders = Set(rest.map(\.key))

        // 4. Build an even bucket grid with zero "shoulders" so every island of
        //    spend starts and ends on the baseline — a clean area-under-curve.
        var grid = granularity.bucketDates(in: domain, calendar: calendar)
        if grid.isEmpty {
            grid = [granularity.floor(domain.lowerBound, calendar: calendar)]
        }
        if let first = grid.first,
           let pre = calendar.date(byAdding: granularity.component, value: -1, to: first) {
            grid.insert(pre, at: 0)
        }
        if let last = grid.last,
           let post = calendar.date(byAdding: granularity.component, value: 1, to: last) {
            grid.append(post)
        }

        // 5. Band descriptors, bottom → top: biggest provider forms the base,
        //    the muted "Other" cap (if any) rides on top.
        struct Descriptor {
            let id: String
            let label: String
            let color: Color
            let total: Double
            let provider: AgentProvider?
        }
        var descriptors: [Descriptor] = mains.map {
            Descriptor(
                id: $0.key.rawValue,
                label: $0.key.displayName,
                color: DesignSystem.Colors.primary(for: $0.key),
                total: $0.value,
                provider: $0.key
            )
        }
        if otherTotal > 1e-9 {
            descriptors.append(
                Descriptor(
                    id: "__atelier_other__",
                    label: "Other",
                    color: DesignSystem.Colors.textMuted,
                    total: otherTotal,
                    provider: nil
                )
            )
        }

        // 6. Manual stacking — explicit base/top per bucket per band.
        var pointsByBand: [String: [AtelierSpendRibbonPoint]] = [:]
        for descriptor in descriptors { pointsByBand[descriptor.id] = [] }
        var peak: Double = 0
        for date in grid {
            let costsHere = bucketCosts[date] ?? [:]
            var base: Double = 0
            for descriptor in descriptors {
                let value: Double
                if let provider = descriptor.provider {
                    value = costsHere[provider] ?? 0
                } else {
                    value = costsHere.reduce(0) { acc, entry in
                        restProviders.contains(entry.key) ? acc + entry.value : acc
                    }
                }
                let top = base + value
                pointsByBand[descriptor.id]?.append(
                    AtelierSpendRibbonPoint(date: date, base: base, top: top)
                )
                base = top
            }
            peak = max(peak, base)
        }

        let bands = descriptors.map { descriptor in
            AtelierSpendBand(
                id: descriptor.id,
                label: descriptor.label,
                color: descriptor.color,
                total: descriptor.total,
                points: pointsByBand[descriptor.id] ?? []
            )
        }
        let xDomain = (grid.first ?? domain.lowerBound)...(grid.last ?? domain.upperBound)
        return AtelierSpendModel(
            bands: bands,
            xDomain: xDomain,
            yMax: max(peak * 1.12, 1e-6),
            granularity: granularity,
            isEmpty: false
        )
    }
}

// MARK: - Atelier Spend Curve · model types

private struct AtelierSpendModel {
    let bands: [AtelierSpendBand]
    let xDomain: ClosedRange<Date>
    let yMax: Double
    let granularity: AtelierSpendGranularity
    let isEmpty: Bool
}

private struct AtelierSpendBand: Identifiable {
    let id: String
    let label: String
    let color: Color
    let total: Double
    let points: [AtelierSpendRibbonPoint]
}

private struct AtelierSpendRibbonPoint: Identifiable {
    let date: Date
    let base: Double
    let top: Double
    var id: Date { date }
}

/// Bucket granularity ladder — chosen from the window span so the chart always
/// renders a comfortable ~8–30 buckets regardless of range.
private enum AtelierSpendGranularity {
    case hour, day, week, month

    static func choose(span: TimeInterval) -> AtelierSpendGranularity {
        if span <= 36 * 3_600 { return .hour }       // ≤ ~1.5 days → hourly
        if span <= 45 * 86_400 { return .day }       // ≤ ~6 weeks → daily
        if span <= 547 * 86_400 { return .week }     // ≤ ~18 months → weekly
        return .month
    }

    var component: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    func floor(_ date: Date, calendar: Calendar) -> Date {
        switch self {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    func bucketDates(in domain: ClosedRange<Date>, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = floor(domain.lowerBound, calendar: calendar)
        var guardCount = 0
        while cursor <= domain.upperBound, guardCount < 512 {
            result.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return result
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .hour:
            return .dateTime.hour(.defaultDigits(amPM: .abbreviated))
        case .day, .week:
            return .dateTime.month(.abbreviated).day()
        case .month:
            return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }
}
