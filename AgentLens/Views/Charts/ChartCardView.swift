import SwiftUI
import OpenBurnBarCore

// MARK: - Chart Card
//
// One liquid-glass gallery card: header (accent chip · title · headline
// stat), the chart body, and a "why it matters" footer. All data arrives
// prepared inside `ChartsSnapshot`; the card performs zero aggregation.
// Accent color comes from the active `ChartsAppearance` (palette mood + any
// per-card override), so the whole page re-voices from one picker.

struct ChartCardView: View {
    let config: ChartCardConfig
    let snapshot: ChartsSnapshot
    let appearance: ChartsAppearance
    let onHide: () -> Void
    let onToggleSpan: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var kind: ChartKind { config.kind }
    private var accent: Color { appearance.accent(for: kind) }
    private var metric: ChartsPrimaryMetric { appearance.primaryMetric }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: appearance.density.chartHeight)
            Text(kind.whyItMatters)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(2)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Same recipe as DashboardLiveCostCurve: real glass with a faint
            // accent wash. The wash tints the light, it never paints a slab.
            let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
            if #available(macOS 26, *) {
                shape
                    .fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
                    .liquidGlassEffect(.regular, in: shape)
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                    shape.fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(accent.opacity(isHovered ? 0.45 : 0.22), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .shadow(
            color: accent.opacity(isHovered && !reduceMotion ? 0.22 : 0),
            radius: 14,
            y: 6
        )
        .scaleEffect(isHovered && !reduceMotion ? 1.008 : 1)
        .animation(reduceMotion ? nil : DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(config.span > 1 ? "Make Narrow" : "Make Full Width", action: onToggleSpan)
            Button("Hide Chart", action: onHide)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title). \(headline). \(kind.whyItMatters)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.14))
                )
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: Headline stat

    private var headline: String {
        switch kind {
        case .burnOverTime:
            let total = metric == .cost ? snapshot.totalCost : Double(snapshot.totalTokens)
            let trendValue = metric == .cost ? snapshot.burnTrendPercent : snapshot.tokenTrendPercent
            let trend = trendValue.map {
                " · " + $0.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%"
            } ?? ""
            return metric.format(total) + trend
        case .providerMix:
            guard let top = snapshot.providerShares.first, snapshot.totalCost > 0 else { return "—" }
            return "\(top.provider.displayName) \(Int((top.cost / snapshot.totalCost * 100).rounded()))%"
        case .modelMix:
            return snapshot.modelCosts.first.map { shortModelName($0.label) } ?? "—"
        case .cacheROI:
            return "≈\(snapshot.cacheSavingsEstimate.formatAsCost()) saved"
        case .reasoningShare:
            return percentText(snapshot.reasoningShare)
        case .hourOfDayHeatmap:
            guard let weekday = snapshot.peakWeekdayIndex, let hour = snapshot.peakHour else { return "—" }
            return "Peak \(Self.weekdayNames[weekday]) \(hourText(hour))"
        case .weekOverWeekDelta:
            let percent = metric == .cost ? snapshot.weekOverWeekPercent : snapshot.weekOverWeekTokenPercent
            guard let percent else { return "—" }
            return percent.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%"
        case .costPerSessionDistribution:
            return snapshot.medianSessionCost.map { "median " + $0.formatAsCost() } ?? "—"
        case .sessionOutliers:
            return snapshot.outlierSessions.first.map { $0.cost.formatAsCost() } ?? "—"
        case .projectFocus:
            return focusLabel(snapshot.projectEntropy)
        case .burnForecast:
            let forecast = metric == .cost ? snapshot.forecast : snapshot.tokenForecast
            return forecast.map { metric.format($0.projectedMonthEndSpend) + " by EOM" } ?? "—"
        case .provenanceQuality:
            return percentText(snapshot.exactShare) + " exact"
        case .modelConcentration:
            return snapshot.modelConcentrationIndex.formatted(.number.precision(.fractionLength(2)))
        case .remoteVsLocal:
            return snapshot.remoteCost.formatAsCost() + " remote"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isKindEmpty {
            ChartCardEmptyContent(accent: accent)
        } else {
            switch kind {
            case .burnOverTime:
                let series = metric == .cost ? snapshot.burnSeries : snapshot.burnTokenSeries
                ChartKitLine(
                    values: series.map(\.value),
                    accent: accent,
                    valueFormatter: { metric.format($0) },
                    pointLabels: bucketLabels(series)
                )
            case .providerMix:
                ChartKitDonut(
                    segments: snapshot.providerShares.map {
                        .init(
                            id: $0.provider.rawValue,
                            label: $0.provider.displayName,
                            value: $0.cost,
                            color: DesignSystem.Colors.primary(for: $0.provider)
                        )
                    },
                    centerText: snapshot.providerShares.first.flatMap { top in
                        snapshot.totalCost > 0
                        ? "\(Int((top.cost / snapshot.totalCost * 100).rounded()))%"
                        : nil
                    }
                )
            case .modelMix:
                ChartKitRankedBars(
                    rows: snapshot.modelCosts.prefix(5).map {
                        .init(id: $0.label, label: shortModelName($0.label), detail: nil,
                              value: $0.value, color: accent)
                    }
                )
            case .cacheROI:
                ChartKitLine(
                    values: snapshot.cacheHitRateSeries.map(\.value),
                    accent: accent,
                    yMax: 1,
                    valueFormatter: { percentText($0) },
                    pointLabels: bucketLabels(snapshot.cacheHitRateSeries)
                )
            case .reasoningShare:
                ChartKitLine(
                    values: snapshot.reasoningShareSeries.map(\.value),
                    accent: accent,
                    valueFormatter: { percentText($0) },
                    pointLabels: bucketLabels(snapshot.reasoningShareSeries)
                )
            case .hourOfDayHeatmap:
                ChartKitHeatmap(matrix: snapshot.hourWeekdayCost, accent: accent)
            case .weekOverWeekDelta:
                let thisWeek = metric == .cost ? snapshot.thisWeekDaily : snapshot.thisWeekTokenDaily
                let lastWeek = metric == .cost ? snapshot.lastWeekDaily : snapshot.lastWeekTokenDaily
                ChartKitPairedBars(
                    primary: thisWeek, secondary: lastWeek,
                    primaryAccent: accent,
                    groupLabels: rollingDayLabels(count: max(thisWeek.count, lastWeek.count)),
                    valueFormatter: { metric.format($0) }
                )
            case .costPerSessionDistribution:
                ChartKitBars(
                    values: snapshot.sessionCostBins.map { Double($0.count) },
                    accent: accent,
                    barLabels: snapshot.sessionCostBins.map {
                        "\($0.lower.formatAsCost())–\($0.upper.formatAsCost())"
                    },
                    valueFormatter: { "\(Int($0)) sessions" }
                )
            case .sessionOutliers:
                ChartKitRankedBars(
                    rows: snapshot.outlierSessions.map {
                        .init(id: $0.sessionId,
                              label: $0.projectName.isEmpty ? "Unassigned" : $0.projectName,
                              detail: shortModelName($0.model),
                              value: $0.cost,
                              color: DesignSystem.Colors.primary(for: $0.provider))
                    }
                )
            case .projectFocus:
                ChartKitStackedBars(
                    series: snapshot.projectSeries.enumerated().map { index, series in
                        .init(id: series.projectName, values: series.dailyCosts,
                              color: Self.projectPalette[index % Self.projectPalette.count])
                    }
                )
            case .burnForecast:
                let forecast = metric == .cost ? snapshot.forecast : snapshot.tokenForecast
                if let forecast {
                    ChartKitLine(
                        values: forecast.dailyCosts + forecast.projectedDaily,
                        accent: accent,
                        projectionStartIndex: max(0, forecast.dailyCosts.count - 1),
                        valueFormatter: { metric.format($0) },
                        pointLabels: forecastLabels(forecast)
                    )
                }
            case .provenanceQuality:
                ChartKitRankedBars(
                    rows: snapshot.provenanceShares.map {
                        .init(id: $0.label, label: $0.label, detail: nil, value: $0.value,
                              color: $0.label.hasPrefix("Exact") || $0.label.hasPrefix("Derived")
                                  ? DesignSystem.Colors.success
                                  : DesignSystem.Colors.amber)
                    }
                )
            case .modelConcentration:
                ChartKitDonut(
                    segments: snapshot.modelCosts.map {
                        .init(id: $0.label, label: shortModelName($0.label), value: $0.value,
                              color: accent)
                    },
                    centerText: snapshot.modelConcentrationIndex.formatted(.number.precision(.fractionLength(2)))
                )
            case .remoteVsLocal:
                ChartKitDonut(
                    segments: [
                        .init(id: "local", label: "This device", value: snapshot.localCost,
                              color: appearance.paletteMood.color(for: .mix)),
                        .init(id: "remote", label: "Remote devices", value: snapshot.remoteCost,
                              color: appearance.paletteMood.color(for: .rhythm))
                    ],
                    centerText: nil
                )
            }
        }
    }

    /// Whether this kind has nothing meaningful to draw for the window.
    private var isKindEmpty: Bool {
        switch kind {
        case .burnOverTime:
            let series = metric == .cost ? snapshot.burnSeries : snapshot.burnTokenSeries
            return !series.contains { $0.value > 0 }
        case .providerMix: return snapshot.providerShares.isEmpty
        case .modelMix: return snapshot.modelCosts.isEmpty
        case .cacheROI: return snapshot.cacheReadTokens == 0
        case .reasoningShare: return !snapshot.reasoningShareSeries.contains { $0.value > 0 }
        case .hourOfDayHeatmap: return snapshot.peakHour == nil
        case .weekOverWeekDelta:
            let combined = metric == .cost
                ? snapshot.thisWeekDaily + snapshot.lastWeekDaily
                : snapshot.thisWeekTokenDaily + snapshot.lastWeekTokenDaily
            return !combined.contains { $0 > 0 }
        case .costPerSessionDistribution: return snapshot.sessionCostBins.isEmpty
        case .sessionOutliers: return snapshot.outlierSessions.isEmpty
        case .projectFocus: return snapshot.projectSeries.isEmpty
        case .burnForecast:
            return (metric == .cost ? snapshot.forecast : snapshot.tokenForecast) == nil
        case .provenanceQuality: return snapshot.provenanceShares.isEmpty
        case .modelConcentration: return snapshot.modelCosts.isEmpty
        case .remoteVsLocal: return snapshot.totalCost <= 0
        }
    }

    // MARK: Label helpers

    /// Bucket captions for line-chart tooltips: hours for the Today window,
    /// short dates otherwise.
    private func bucketLabels(_ series: [ChartBucketing.DateBucket]) -> [String] {
        series.map { bucket in
            snapshot.timeRange == .today
                ? Self.hourFormatter.string(from: bucket.start)
                : Self.dayFormatter.string(from: bucket.start)
        }
    }

    private func forecastLabels(_ forecast: ChartsSnapshot.Forecast) -> [String] {
        var labels = forecast.dayStarts.map { Self.dayFormatter.string(from: $0) }
        // Projected days continue past the observation window.
        if let last = forecast.dayStarts.last {
            for offset in 1...max(0, forecast.projectedDaily.count) {
                let date = Calendar.current.date(byAdding: .day, value: offset, to: last) ?? last
                labels.append(Self.dayFormatter.string(from: date) + " (proj.)")
            }
        }
        return labels
    }

    /// Rolling-window captions for the week-vs-week pairs: index count-1 is
    /// always today.
    private func rollingDayLabels(count: Int) -> [String] {
        (0..<count).map { index in
            let daysAgo = count - 1 - index
            switch daysAgo {
            case 0: return "Today"
            case 1: return "Yesterday"
            default: return "\(daysAgo)d ago"
            }
        }
    }

    // MARK: Formatting helpers

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        return formatter
    }()

    private static let projectPalette: [Color] = [
        DesignSystem.Colors.ember,
        DesignSystem.Colors.whimsy,
        DesignSystem.Colors.amber,
        DesignSystem.Colors.blaze,
        DesignSystem.Colors.success
    ]

    private func percentText(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(fraction < 0.1 ? 1 : 0))) + "%"
    }

    private func hourText(_ hour: Int) -> String {
        switch hour {
        case 0: return "12am"
        case 12: return "12pm"
        case ..<12: return "\(hour)am"
        default: return "\(hour - 12)pm"
        }
    }

    private func focusLabel(_ entropy: Double) -> String {
        switch entropy {
        case ..<0.35: return "Locked in"
        case ..<0.7: return "Balanced"
        default: return "Spread wide"
        }
    }

    private func shortModelName(_ raw: String) -> String {
        // Model ids read like "claude-opus-4-8" or "gpt-5.6-sol"; strip
        // vendor date suffixes for card labels.
        let trimmed = raw.split(separator: "/").last.map(String.init) ?? raw
        if let range = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }
}

// MARK: - Empty content

private struct ChartCardEmptyContent: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent.opacity(0.5))
            Text("Nothing in this window yet")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(accent.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        )
    }
}
