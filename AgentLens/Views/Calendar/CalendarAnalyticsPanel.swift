import SwiftUI
import UniformTypeIdentifiers

// MARK: - Calendar Analytics Panel
//
// The selection-driven half of the Calendar surface: a three-column flow of
// analytics cards, re-arrangeable by drag & drop, resizable (S/M/L spans),
// and hideable via context menu — the same interaction contract as
// `ChartsReorderableGrid`, generalized to three columns. All data arrives
// prepared inside `CalendarSelectionSnapshot`; cards perform zero
// aggregation.

extension CalendarCardKind {
    var accent: Color {
        switch self {
        case .kpis, .burnOverSelection: return DesignSystem.Colors.ember
        case .providerMix, .modelMix, .projectFocus: return DesignSystem.Colors.whimsy
        case .hourOfDayHeatmap: return DesignSystem.Colors.amber
        case .cacheROI: return DesignSystem.Colors.success
        case .reasoningShare: return DesignSystem.Colors.blaze
        }
    }
}

struct CalendarAnalyticsPanel: View {
    let layout: CalendarPageLayout
    let snapshot: CalendarSelectionSnapshot
    let onMove: (CalendarCardKind, CalendarCardKind) -> Void
    let onHide: (CalendarCardKind) -> Void
    let onSetSpan: (CalendarCardKind, Int) -> Void

    @State private var dropTargetKind: CalendarCardKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = Self.rows(for: layout.visibleConfigs)
        VStack(spacing: DesignSystem.Spacing.md) {
            ForEach(rows, id: \.id) { row in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ForEach(row.configs) { config in
                        card(config)
                    }
                    // Hold any unfilled columns so widths stay stable.
                    if row.configs.map(\.span).reduce(0, +) < 3 {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: layout.configs)
    }

    @ViewBuilder
    private func card(_ config: CalendarCardConfig) -> some View {
        let isTarget = dropTargetKind == config.kind
        CalendarCardView(
            config: config,
            snapshot: snapshot,
            onHide: { onHide(config.kind) },
            onSetSpan: { span in onSetSpan(config.kind, span) }
        )
        .overlay {
            if isTarget {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .stroke(DesignSystem.Colors.ember.opacity(0.8), lineWidth: 2)
            }
        }
        .scaleEffect(isTarget && !reduceMotion ? 1.01 : 1.0)
        .draggable(config.kind.rawValue) {
            HStack(spacing: 6) {
                Image(systemName: config.kind.systemImage)
                Text(config.kind.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(DesignSystem.Colors.surface))
        }
        .dropDestination(for: String.self) { items, _ in
            dropTargetKind = nil
            guard let raw = items.first, let dragged = CalendarCardKind(rawValue: raw),
                  dragged != config.kind else { return false }
            onMove(dragged, config.kind)
            return true
        } isTargeted: { targeted in
            dropTargetKind = targeted ? config.kind : nil
        }
        .accessibilityHint("Drag onto another card to reorder. Use the context menu to hide or resize.")
    }

    // MARK: Row packing

    struct Row: Identifiable {
        let id: String
        let configs: [CalendarCardConfig]
    }

    /// Packs configs greedily into rows up to 3 columns wide: a card joins
    /// the current row while the span sum stays ≤ 3, otherwise it starts a
    /// new row.
    static func rows(for configs: [CalendarCardConfig]) -> [Row] {
        var rows: [Row] = []
        var current: [CalendarCardConfig] = []
        var currentSpan = 0
        for config in configs {
            let span = min(3, max(1, config.span))
            if currentSpan + span > 3, !current.isEmpty {
                rows.append(Row(id: current.map(\.id).joined(separator: "+"), configs: current))
                current = []
                currentSpan = 0
            }
            current.append(config)
            currentSpan += span
        }
        if !current.isEmpty {
            rows.append(Row(id: current.map(\.id).joined(separator: "+"), configs: current))
        }
        return rows
    }
}

// MARK: - Calendar Card

/// One analytics card: header (symbol · title · headline stat), the chart
/// body, and a "why it matters" footer — the same chrome contract as
/// `ChartCardView`, on the shared `chartGlassCard` plate.
struct CalendarCardView: View {
    let config: CalendarCardConfig
    let snapshot: CalendarSelectionSnapshot
    let onHide: () -> Void
    let onSetSpan: (Int) -> Void

    private var kind: CalendarCardKind { config.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: contentHeight)
            Text(kind.whyItMatters)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(2)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chartGlassCard()
        .contextMenu {
            Menu("Size") {
                ForEach([(1, "S"), (2, "M"), (3, "L")], id: \.0) { span, label in
                    Button {
                        onSetSpan(span)
                    } label: {
                        if config.span == span {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            }
            Button("Hide Card", action: onHide)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title). \(headline). \(kind.whyItMatters)")
    }

    /// KPI tiles and the mix tiles size to their content; charts pin to the
    /// shared gallery height.
    private var contentHeight: CGFloat? {
        switch kind {
        case .kpis, .cacheROI, .reasoningShare: return nil
        default: return 150
        }
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
        case .kpis:
            return snapshot.totalCost.formatAsCost()
        case .burnOverSelection:
            let days = snapshot.selectedDays.count
            return snapshot.totalCost.formatAsCost() + " · \(days)d"
        case .providerMix:
            guard let top = snapshot.providerShares.first, snapshot.totalCost > 0 else { return "—" }
            return "\(top.provider.displayName) \(Int((top.cost / snapshot.totalCost * 100).rounded()))%"
        case .modelMix:
            return snapshot.topModels.first?.displayName ?? "—"
        case .hourOfDayHeatmap:
            guard let weekday = snapshot.peakWeekdayIndex, let hour = snapshot.peakHour else { return "—" }
            return "Peak \(Self.weekdayNames[weekday]) \(hourText(hour))"
        case .projectFocus:
            return snapshot.projectShares.first?.name ?? "—"
        case .cacheROI:
            return "≈\(snapshot.cacheSavingsEstimate.formatAsCost()) saved"
        case .reasoningShare:
            return percentText(snapshot.reasoningShare)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isKindEmpty {
            CalendarCardEmptyContent(accent: kind.accent)
        } else {
            switch kind {
            case .kpis:
                kpiTiles
            case .burnOverSelection:
                ChartKitBars(values: snapshot.dailyBurn.map(\.value), accent: kind.accent)
            case .providerMix:
                ChartKitDonut(
                    segments: snapshot.providerShares.map {
                        .init(
                            id: $0.provider.rawValue,
                            label: $0.provider.displayName,
                            value: $0.cost,
                            color: DesignSystem.Colors.primary(for: $0.provider),
                            badge: AnyView(ProviderLogoView(provider: $0.provider, size: 12))
                        )
                    },
                    centerText: snapshot.providerShares.first.flatMap { top in
                        snapshot.totalCost > 0
                            ? "\(Int((top.cost / snapshot.totalCost * 100).rounded()))%"
                            : nil
                    }
                )
            case .modelMix:
                modelMixRows
            case .hourOfDayHeatmap:
                ChartKitHeatmap(matrix: snapshot.hourWeekdayCost, accent: kind.accent)
            case .projectFocus:
                ChartKitRankedBars(
                    rows: snapshot.projectShares.enumerated().map { index, share in
                        .init(
                            id: share.name,
                            label: share.name,
                            detail: nil,
                            value: share.cost,
                            color: ChartInk.neutralRamp[index % ChartInk.neutralRamp.count]
                        )
                    }
                )
            case .cacheROI:
                CalendarMixTile(
                    value: "≈\(snapshot.cacheSavingsEstimate.formatAsCost())",
                    label: "estimated savings",
                    detail: "\(percentText(snapshot.cacheHitRate)) hit rate · "
                        + "\(snapshot.cacheReadTokens.formatAsTokenVolume()) cache-read tokens",
                    accent: kind.accent
                )
            case .reasoningShare:
                CalendarMixTile(
                    value: percentText(snapshot.reasoningShare),
                    label: "of tokens were reasoning",
                    detail: "\(snapshot.reasoningTokens.formatAsTokenVolume()) reasoning tokens",
                    accent: kind.accent
                )
            }
        }
    }

    /// Whether this kind has nothing meaningful to draw for the selection.
    private var isKindEmpty: Bool {
        switch kind {
        case .kpis: return snapshot.isEmpty
        case .burnOverSelection: return !snapshot.dailyBurn.contains { $0.value > 0 }
        case .providerMix: return snapshot.providerShares.isEmpty
        case .modelMix: return snapshot.topModels.isEmpty
        case .hourOfDayHeatmap: return snapshot.peakHour == nil
        case .projectFocus: return snapshot.projectShares.isEmpty
        case .cacheROI: return snapshot.cacheReadTokens == 0
        case .reasoningShare: return snapshot.reasoningTokens == 0
        }
    }

    // MARK: KPI tiles

    private var kpiTiles: some View {
        let tiles: [(label: String, value: String)] = [
            ("Total Cost", snapshot.totalCost.formatAsCost()),
            ("Total Tokens", snapshot.totalTokens.formatAsTokenVolume()),
            ("Sessions", "\(snapshot.sessionCount)"),
            ("Active Days", "\(snapshot.activeDays)"),
            ("Avg Cost/Day", snapshot.averageCostPerDay.formatAsCost())
        ]
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: DesignSystem.Spacing.sm)],
            spacing: DesignSystem.Spacing.sm
        ) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.label.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(tile.value)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(kind.accent.opacity(0.07))
                )
            }
        }
    }

    // MARK: Model mix rows

    /// Ranked model rows with the vendor's brand mark — the ChartKit ranked
    /// bar recipe with `ModelProviderLogoView` in place of a plain label.
    private var modelMixRows: some View {
        let rows = snapshot.topModels
        let peak = max(rows.map(\.cost).max() ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.model) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ModelProviderLogoView(modelKey: row.model, size: 14)
                        Text(row.displayName)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.cost.formatAsCost())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DesignSystem.Colors.surface.opacity(0.6))
                            Capsule()
                                .fill(kind.accent.opacity(0.85))
                                .frame(width: max(3, CGFloat(row.cost / peak) * proxy.size.width))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Formatting helpers

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

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
}

// MARK: - Mix tile

/// The big-number tile used by the cache-ROI and reasoning-share cards.
private struct CalendarMixTile: View {
    let value: String
    let label: String
    let detail: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - Empty content

private struct CalendarCardEmptyContent: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent.opacity(0.5))
            Text("Nothing on these days yet")
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
