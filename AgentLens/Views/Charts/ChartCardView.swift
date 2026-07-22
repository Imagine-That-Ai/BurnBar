import SwiftUI
import OpenBurnBarCore

// MARK: - Chart Card
//
// One liquid-glass gallery card: header (symbol · title · headline stat),
// the chart body, and a "why it matters" footer. All data arrives prepared
// inside `ChartsSnapshot`; the card performs zero aggregation.

extension ChartKind {
    var accent: Color {
        switch self {
        case .burnOverTime, .burnForecast: return DesignSystem.Colors.ember
        case .providerMix, .modelMix, .modelConcentration: return DesignSystem.Colors.whimsy
        case .cacheROI, .provenanceQuality: return DesignSystem.Colors.success
        case .reasoningShare: return DesignSystem.Colors.blaze
        case .hourOfDayHeatmap, .weekOverWeekDelta: return DesignSystem.Colors.amber
        case .costPerSessionDistribution, .sessionOutliers: return DesignSystem.Colors.ember
        case .projectFocus, .remoteVsLocal: return DesignSystem.Colors.whimsy
        }
    }
}

struct ChartCardView: View {
    let config: ChartCardConfig
    let snapshot: ChartsSnapshot
    let onHide: () -> Void
    let onToggleSpan: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var kind: ChartKind { config.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 150)
            Text(kind.whyItMatters)
                .font(.system(size: 10, design: .rounded))
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
                    .fill(kind.accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
                    .liquidGlassEffect(.regular, in: shape)
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                    shape.fill(kind.accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(kind.accent.opacity(0.22), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .contextMenu {
            Button(config.span == 2 ? "Make Half Width" : "Make Full Width", action: onToggleSpan)
            Button("Hide Chart", action: onHide)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title). \(headline). \(kind.whyItMatters)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.accent)
            Text(kind.title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 8)
            Text(headline)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Headline stat

    private var headline: String {
        switch kind {
        case .burnOverTime:
            let trend = snapshot.burnTrendPercent.map {
                " · " + $0.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%"
            } ?? ""
            return snapshot.totalCost.formatAsCost() + trend
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
            guard let percent = snapshot.weekOverWeekPercent else { return "—" }
            return percent.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%"
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

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isKindEmpty {
            ChartCardEmptyContent(accent: kind.accent)
        } else {
            switch kind {
            case .burnOverTime:
                ChartKitLine(values: snapshot.burnSeries.map(\.value), accent: kind.accent)
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
                              value: $0.value, color: kind.accent)
                    }
                )
            case .cacheROI:
                ChartKitLine(values: snapshot.cacheHitRateSeries.map(\.value), accent: kind.accent, yMax: 1)
            case .reasoningShare:
                ChartKitLine(values: snapshot.reasoningShareSeries.map(\.value), accent: kind.accent)
            case .hourOfDayHeatmap:
                ChartKitHeatmap(matrix: snapshot.hourWeekdayCost, accent: kind.accent)
            case .weekOverWeekDelta:
                ChartKitPairedBars(primary: snapshot.thisWeekDaily, secondary: snapshot.lastWeekDaily,
                                   primaryAccent: kind.accent)
            case .costPerSessionDistribution:
                ChartKitBars(values: snapshot.sessionCostBins.map { Double($0.count) }, accent: kind.accent)
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
                if let forecast = snapshot.forecast {
                    ChartKitLine(
                        values: forecast.dailyCosts + forecast.projectedDaily,
                        accent: kind.accent,
                        projectionStartIndex: max(0, forecast.dailyCosts.count - 1)
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
                              color: kind.accent)
                    },
                    centerText: snapshot.modelConcentrationIndex.formatted(.number.precision(.fractionLength(2)))
                )
            case .remoteVsLocal:
                ChartKitDonut(
                    segments: [
                        .init(id: "local", label: "This device", value: snapshot.localCost,
                              color: DesignSystem.Colors.whimsy),
                        .init(id: "remote", label: "Remote devices", value: snapshot.remoteCost,
                              color: DesignSystem.Colors.amber)
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
