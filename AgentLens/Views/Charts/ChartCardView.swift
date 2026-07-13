import SwiftUI
import OpenBurnBarCore

// MARK: - Chart Card
//
// One gallery card on the uniform glass plate. Header (symbol · label ·
// headline stat + optional delta), the chart body, and a whisper of "why it
// matters". All data arrives prepared in `ChartsSnapshot`; the card performs
// zero aggregation. Colour follows the ChartInk rule — cool silver by
// default, ember only for the burn/spend hero series, brand hues only in the
// provider mix, greens/ambers only on directional deltas.

extension ChartKind {
    /// The series ink for this chart's primary line/area (see ChartInk).
    var seriesInk: Color {
        switch self {
        case .burnOverTime, .burnForecast: return ChartInk.signature
        default: return ChartInk.neutral
        }
    }
}

struct ChartCardView: View {
    let config: ChartCardConfig
    let snapshot: ChartsSnapshot
    let onHide: () -> Void
    let onToggleSpan: () -> Void

    private var kind: ChartKind { config.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 156)
            Text(kind.whyItMatters)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chartGlassCard()
        .contextMenu {
            Button(config.span == 2 ? "Make Half Width" : "Make Full Width", action: onToggleSpan)
            Button("Hide Chart", action: onHide)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title). \(headlineValue)\(headlineDelta.map { ", \($0.text)" } ?? ""). \(kind.whyItMatters)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(kind.title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 8)
            if let delta = headlineDelta {
                deltaBadge(delta)
            }
            Text(headlineValue)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    private func deltaBadge(_ delta: DeltaBadge) -> some View {
        let color = delta.good ? ChartInk.down : ChartInk.up
        return Text(delta.text)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private struct DeltaBadge {
        let text: String
        /// Spend fell → good (green); spend rose → caution (amber).
        let good: Bool
    }

    // MARK: Headline

    private var headlineValue: String {
        switch kind {
        case .burnOverTime:
            return snapshot.totalCost.formatAsCost()
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
            return snapshot.thisWeekDaily.reduce(0, +).formatAsCost()
        case .costPerSessionDistribution:
            return snapshot.medianSessionCost.map { "median " + $0.formatAsCost() } ?? "—"
        case .sessionOutliers:
            return snapshot.outlierSessions.first.map { $0.cost.formatAsCost() } ?? "—"
        case .projectFocus:
            return focusLabel(snapshot.projectEntropy)
        case .burnForecast:
            return snapshot.forecast.map { $0.projectedMonthEndSpend.formatAsCost() + " by EOM" } ?? "—"
        case .provenanceQuality:
            return percentText(snapshot.exactShare) + " exact"
        case .modelConcentration:
            return snapshot.modelConcentrationIndex.formatted(.number.precision(.fractionLength(2)))
        case .remoteVsLocal:
            return snapshot.remoteCost.formatAsCost() + " remote"
        }
    }

    private var headlineDelta: DeltaBadge? {
        switch kind {
        case .burnOverTime:
            guard let trend = snapshot.burnTrendPercent else { return nil }
            return DeltaBadge(text: signed(trend), good: trend <= 0)
        case .weekOverWeekDelta:
            guard let percent = snapshot.weekOverWeekPercent else { return nil }
            return DeltaBadge(text: signed(percent), good: percent <= 0)
        default:
            return nil
        }
    }

    private func signed(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isKindEmpty {
            ChartCardEmptyContent()
        } else {
            switch kind {
            case .burnOverTime:
                ChartKitLine(values: snapshot.burnSeries.map(\.value), accent: kind.seriesInk)
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
                    rows: snapshot.modelCosts.prefix(5).enumerated().map { index, model in
                        .init(id: model.label, label: shortModelName(model.label), detail: nil,
                              value: model.value, color: neutralRank(index))
                    }
                )
            case .cacheROI:
                ChartKitLine(values: snapshot.cacheHitRateSeries.map(\.value), accent: ChartInk.neutral, yMax: 1)
            case .reasoningShare:
                ChartKitLine(values: snapshot.reasoningShareSeries.map(\.value), accent: ChartInk.neutral)
            case .hourOfDayHeatmap:
                // The heat map earns its ember: it is literally a map of when
                // you burn, so warmth = intensity is meaningful here.
                ChartKitHeatmap(matrix: snapshot.hourWeekdayCost, accent: ChartInk.signature)
            case .weekOverWeekDelta:
                ChartKitPairedBars(
                    primary: snapshot.thisWeekDaily,
                    secondary: snapshot.lastWeekDaily,
                    primaryAccent: ChartInk.neutral,
                    secondaryAccent: DesignSystem.Colors.textMuted
                )
            case .costPerSessionDistribution:
                ChartKitBars(values: snapshot.sessionCostBins.map { Double($0.count) }, accent: ChartInk.neutral)
            case .sessionOutliers:
                ChartKitRankedBars(
                    rows: snapshot.outlierSessions.map {
                        // Provider brand hue is meaningful here — it tells you
                        // which agent ran the expensive session at a glance.
                        .init(id: $0.sessionId,
                              label: $0.projectName.isEmpty ? "Unassigned" : $0.projectName,
                              detail: shortModelName($0.model),
                              value: $0.cost,
                              color: DesignSystem.Colors.primary(for: $0.provider).opacity(0.85))
                    }
                )
            case .projectFocus:
                ChartKitStackedBars(
                    series: snapshot.projectSeries.enumerated().map { index, series in
                        .init(id: series.projectName, values: series.dailyCosts,
                              color: ChartInk.neutralRamp[index % ChartInk.neutralRamp.count])
                    }
                )
            case .burnForecast:
                if let forecast = snapshot.forecast {
                    ChartKitLine(
                        values: forecast.dailyCosts + forecast.projectedDaily,
                        accent: kind.seriesInk,
                        projectionStartIndex: max(0, forecast.dailyCosts.count - 1)
                    )
                }
            case .provenanceQuality:
                ChartKitRankedBars(
                    rows: snapshot.provenanceShares.map {
                        .init(id: $0.label, label: $0.label, detail: nil, value: $0.value,
                              color: ($0.label.hasPrefix("Exact") || $0.label.hasPrefix("Derived"))
                                  ? ChartInk.down.opacity(0.85)
                                  : ChartInk.up.opacity(0.7))
                    }
                )
            case .modelConcentration:
                ChartKitDonut(
                    segments: snapshot.modelCosts.enumerated().map { index, model in
                        .init(id: model.label, label: shortModelName(model.label), value: model.value,
                              color: ChartInk.signature.opacity(max(0.3, 0.9 - Double(index) * 0.13)))
                    },
                    centerText: snapshot.modelConcentrationIndex.formatted(.number.precision(.fractionLength(2)))
                )
            case .remoteVsLocal:
                ChartKitDonut(
                    segments: [
                        .init(id: "local", label: "This device", value: snapshot.localCost,
                              color: ChartInk.neutral.opacity(0.85)),
                        .init(id: "remote", label: "Remote devices", value: snapshot.remoteCost,
                              color: ChartInk.signature)
                    ],
                    centerText: nil
                )
            }
        }
    }

    /// Whether this kind has nothing meaningful to draw for the window.
    private var isKindEmpty: Bool {
        switch kind {
        case .burnOverTime: return !snapshot.burnSeries.contains { $0.value > 0 }
        case .providerMix: return snapshot.providerShares.isEmpty
        case .modelMix: return snapshot.modelCosts.isEmpty
        case .cacheROI: return snapshot.cacheReadTokens == 0
        case .reasoningShare: return !snapshot.reasoningShareSeries.contains { $0.value > 0 }
        case .hourOfDayHeatmap: return snapshot.peakHour == nil
        case .weekOverWeekDelta:
            return !(snapshot.thisWeekDaily + snapshot.lastWeekDaily).contains { $0 > 0 }
        case .costPerSessionDistribution: return snapshot.sessionCostBins.isEmpty
        case .sessionOutliers: return snapshot.outlierSessions.isEmpty
        case .projectFocus: return snapshot.projectSeries.isEmpty
        case .burnForecast: return snapshot.forecast == nil
        case .provenanceQuality: return snapshot.provenanceShares.isEmpty
        case .modelConcentration: return snapshot.modelCosts.isEmpty
        case .remoteVsLocal: return snapshot.totalCost <= 0
        }
    }

    // MARK: Formatting helpers

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// A rank-descending shade of the neutral ink for ranked bars.
    private func neutralRank(_ index: Int) -> Color {
        DesignSystem.Colors.textPrimary.opacity(max(0.4, 0.92 - Double(index) * 0.14))
    }

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
        let trimmed = raw.split(separator: "/").last.map(String.init) ?? raw
        if let range = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }
}

// MARK: - Empty content

private struct ChartCardEmptyContent: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            Text("Nothing in this window yet")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        )
    }
}
