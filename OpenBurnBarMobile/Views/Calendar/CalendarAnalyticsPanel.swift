import Charts
import SwiftUI
import OpenBurnBarCore

// MARK: - Calendar Analytics Panel
//
// The selection-driven card gallery. Renders the visible cards from
// `CalendarPageLayout` in order, packed into rows by span (S/M/L → 1/2/3
// columns on a 3-column regular-width grid, clamped to the 2-column compact
// grid). Card chrome (hide, resize) lives in each card's header menu;
// reordering lives in the edit sheet hosted by `CalendarView`. Every card
// reads pre-aggregated data from `CalendarSelectionSnapshot` — no card does
// math of its own.

struct CalendarAnalyticsPanel: View {
    let layout: CalendarPageLayout
    let snapshot: CalendarSelectionSnapshot
    var accent: Color = MobileTheme.ember
    let onSetSpan: (CalendarCardKind, Int) -> Void
    let onHide: (CalendarCardKind) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var panelWidth: CGFloat = 0

    private var columns: Int { horizontalSizeClass == .regular ? 3 : 2 }

    var body: some View {
        let rows = CalendarPageLayout.packedRows(configs: layout.visibleConfigs, columns: columns)
        let spacing = MobileTheme.Spacing.md
        VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { config in
                        cardView(for: config)
                            .frame(width: cardWidth(for: config, spacing: spacing), alignment: .topLeading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { panelWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in panelWidth = width }
            }
        )
    }

    private func cardWidth(for config: CalendarCardConfig, spacing: CGFloat) -> CGFloat? {
        guard panelWidth > 0 else { return nil }
        let span = min(columns, max(1, config.span))
        guard span < columns else { return panelWidth }
        let unit = (panelWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return unit * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    // MARK: - Card chrome

    @ViewBuilder
    private func cardView(for config: CalendarCardConfig) -> some View {
        AuroraGlassCard(
            variant: .standard,
            cornerRadius: AuroraDesign.Shape.standardCorner,
            padding: MobileTheme.Spacing.md
        ) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                cardHeader(for: config)
                cardContent(for: config.kind)
                Text(config.kind.whyItMatters)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("calendar.card.\(config.kind.rawValue)")
    }

    private func cardHeader(for config: CalendarCardConfig) -> some View {
        HStack(spacing: 6) {
            Image(systemName: config.kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
            Text(config.kind.title.uppercased())
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                Section("Card size") {
                    ForEach([(1, "Small"), (2, "Medium"), (3, "Large")], id: \.0) { span, label in
                        Button {
                            onSetSpan(config.kind, span)
                        } label: {
                            Label(label, systemImage: config.span == span ? "checkmark" : "")
                        }
                    }
                }
                Button(role: .destructive) {
                    onHide(config.kind)
                } label: {
                    Label("Hide Card", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Card options")
        }
    }

    // MARK: - Card content

    @ViewBuilder
    private func cardContent(for kind: CalendarCardKind) -> some View {
        switch kind {
        case .kpis:             kpisContent
        case .burnOverSelection: burnOverSelectionContent
        case .providerMix:      providerMixContent
        case .modelMix:         modelMixContent
        case .hourOfDayHeatmap: hourOfDayHeatmapContent
        case .projectFocus:     projectFocusContent
        case .cacheROI:         cacheROIContent
        case .reasoningShare:   reasoningShareContent
        }
    }

    // MARK: Key Numbers

    private var kpisContent: some View {
        let tiles: [(String, String)] = [
            ("Cost", snapshot.totalCost.formatAsCost()),
            ("Tokens", snapshot.totalTokens.formatAsTokenVolume()),
            ("Sessions", "\(snapshot.sessionCount)"),
            ("Active Days", "\(snapshot.activeDays)/\(max(snapshot.selectedDays.count, 1))"),
            ("Avg Cost/Day", snapshot.averageCostPerDay.formatAsCost())
        ]
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 86), spacing: MobileTheme.Spacing.sm)],
            spacing: MobileTheme.Spacing.sm
        ) {
            ForEach(tiles, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text(value)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(colorScheme == .dark ? 0.10 : 0.06))
                )
            }
        }
    }

    // MARK: Burn Over Selection

    private var burnOverSelectionContent: some View {
        Chart(snapshot.dailyBurn) { bucket in
            BarMark(
                x: .value("Day", bucket.day, unit: .day),
                y: .value("Cost", bucket.cost)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [accent, MobileTheme.amber.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(2.5)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, snapshot.dailyBurn.count / 4))) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.12))
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(cost.formatAsCostCompact())
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                    }
                }
            }
        }
        .frame(height: 132)
        .accessibilityLabel("Per-day cost across the selection, total \(snapshot.totalCost.formatAsCost())")
    }

    // MARK: Provider Mix

    private var providerMixContent: some View {
        let shares = Array(snapshot.providerShares.prefix(5))
        let total = max(snapshot.totalCost, 0.000_001)
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Chart(shares, id: \.provider) { share in
                SectorMark(
                    angle: .value("Cost", share.cost),
                    innerRadius: .ratio(0.68),
                    angularInset: 1.5
                )
                .foregroundStyle(MobileTheme.Colors.primary(for: share.provider))
                .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .frame(height: 120)

            VStack(spacing: 6) {
                ForEach(shares, id: \.provider) { share in
                    HStack(spacing: 8) {
                        ProviderAvatar(provider: share.provider, mode: .plain, size: 14)
                        Text(share.provider.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int((share.cost / total * 100).rounded()))%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(share.cost.formatAsCost())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Model Mix

    private var modelMixContent: some View {
        let peak = snapshot.topModels.map(\.cost).max() ?? 0
        return VStack(spacing: 8) {
            ForEach(snapshot.topModels, id: \.model) { model in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        ProviderAvatar(provider: model.provider, mode: .plain, size: 14)
                        Text(model.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(model.cost.formatAsCost())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(MobileTheme.Colors.textMuted.opacity(0.12))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            MobileTheme.Colors.primary(for: model.provider),
                                            MobileTheme.Colors.accent(for: model.provider)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: peak > 0 ? geo.size.width * CGFloat(model.cost / peak) : 0)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    // MARK: Hour-of-Day Heatmap

    private var hourOfDayHeatmapContent: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let flatPeak = snapshot.hourWeekdayCost.flatMap { $0 }.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 3) {
                    Text(symbols[weekday].uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .frame(width: 14, alignment: .leading)
                    HStack(spacing: 1.5) {
                        ForEach(0..<24, id: \.self) { hour in
                            hourCell(weekday: weekday, hour: hour, peak: flatPeak)
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 14)
                HStack {
                    ForEach(Array(["12a", "6a", "12p", "6p", "12a"].enumerated()), id: \.offset) { index, label in
                        Text(label)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : (index == 4 ? .trailing : .center))
                    }
                }
            }
        }
    }

    private func hourCell(weekday: Int, hour: Int, peak: Double) -> some View {
        let value = snapshot.hourWeekdayCost[weekday][hour]
        let intensity = peak > 0 ? (value / peak).squareRoot() : 0
        let isPeak = snapshot.peakWeekdayIndex == weekday && snapshot.peakHour == hour && value > 0
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
                value > 0
                    ? accent.opacity(0.12 + 0.68 * intensity)
                    : MobileTheme.Colors.textMuted.opacity(0.10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(isPeak ? MobileTheme.amber : Color.clear, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .accessibilityLabel("\(Calendar.current.veryShortWeekdaySymbols[weekday]) \(hour):00, \(value.formatAsCost())")
    }

    // MARK: Project Focus

    private var projectFocusContent: some View {
        let peak = snapshot.projectShares.map(\.cost).max() ?? 0
        return Group {
            if snapshot.projectShares.isEmpty {
                Text("No named projects in this selection.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.projectShares, id: \.name) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(accent)
                                Text(project.name)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(project.cost.formatAsCost())
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(MobileTheme.Colors.textMuted.opacity(0.12))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [accent, MobileTheme.amber],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: peak > 0 ? geo.size.width * CGFloat(project.cost / peak) : 0)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: Cache Savings

    private var cacheROIContent: some View {
        metricTileRow(tiles: [
            ("Cache Hit Rate", percent(snapshot.cacheHitRate)),
            ("Cache Reads", snapshot.cacheReadTokens.formatAsTokenVolume()),
            ("Saved (est.)", snapshot.cacheSavingsEstimate.formatAsCost())
        ])
    }

    // MARK: Reasoning Share

    private var reasoningShareContent: some View {
        metricTileRow(tiles: [
            ("Reasoning Share", percent(snapshot.reasoningShare)),
            ("Reasoning Tokens", snapshot.reasoningTokens.formatAsTokenVolume())
        ])
    }

    // MARK: Shared bits

    private func metricTileRow(tiles: [(String, String)]) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            ForEach(tiles, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(value)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(colorScheme == .dark ? 0.10 : 0.06))
                )
            }
        }
    }

    private func percent(_ value: Double) -> String {
        guard value > 0 else { return "0%" }
        return value < 0.005 ? "<1%" : String(format: "%.0f%%", (value * 100).rounded())
    }
}
