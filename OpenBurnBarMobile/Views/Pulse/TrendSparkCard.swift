import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Trend Spark Card
//
// Pulse moment that shows the daily-points chart from the selected window.
// Has bar / area / line modes (segmented inline) and brushable selection
// when iOS 17+ chart selection is available.

struct TrendSparkCard: View {
    let dailyPoints: [RollupDailyPoint]
    let displayMode: UsageDisplayMode

    @State private var mode: ChartMode = .area
    @State private var selectedDate: Date?

    enum ChartMode: String, Hashable, CaseIterable, Identifiable {
        case area, bars, line
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .area: return "chart.xyaxis.line"
            case .bars: return "chart.bar.fill"
            case .line: return "chart.line.uptrend.xyaxis"
            }
        }
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection("Trend", subtitle: subtitleText, accent: MobileTheme.amber) {
                    modeSelector
                }

                if dailyPoints.isEmpty {
                    placeholder
                } else {
                    chart
                        .frame(height: 200)
                }
            }
        }
    }

    private var subtitleText: String {
        switch displayMode {
        case .currency: return "Daily spend across your fleet"
        case .tokens:   return "Daily token volume across your fleet"
        }
    }

    // MARK: - Selector

    private var modeSelector: some View {
        HStack(spacing: 4) {
            ForEach(ChartMode.allCases) { m in
                Button {
                    withAnimation(AuroraDesign.Motion.auroraSnap) { mode = m }
                    HapticBus.chipChange()
                } label: {
                    Image(systemName: m.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(mode == m ? .white : MobileTheme.Colors.textMuted)
                        .background(
                            Capsule().fill(mode == m ? AnyShapeStyle(MobileTheme.primaryGradient) : AnyShapeStyle(.clear))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.label) chart")
            }
        }
        .padding(2)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(0.6)))
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        Chart {
            ForEach(dailyPoints) { point in
                switch mode {
                case .area:
                    AreaMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                MobileTheme.ember.opacity(0.42),
                                MobileTheme.amber.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)
                case .bars:
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Value", point.value)
                    )
                    .cornerRadius(3)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [MobileTheme.amber, MobileTheme.ember],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                case .line:
                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(MobileTheme.amber)
                    .symbolSize(20)
                }
            }

            if Calendar.current.startOfDay(for: Date()) <= Calendar.current.startOfDay(for: dailyPoints.last?.date ?? Date()) {
                RuleMark(x: .value("Today", Calendar.current.startOfDay(for: Date()), unit: .day))
                    .foregroundStyle(MobileTheme.amber.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .annotation(position: .top) {
                        Text("Today")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.amber)
                    }
            }

            if let selectedDate, let value = valueForDate(selectedDate) {
                RuleMark(x: .value("Selected", selectedDate, unit: .day))
                    .foregroundStyle(MobileTheme.ember.opacity(0.8))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        VStack(spacing: 2) {
                            Text(selectedDate, format: .dateTime.month().day())
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                            Text(formatValue(value))
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.ultraThinMaterial)
                        )
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, dailyPoints.count / 5))) { _ in
                AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.25))
                AxisValueLabel(format: .dateTime.month().day())
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                AxisValueLabel().foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityChartDescriptor(self)
    }

    private var placeholder: some View {
        AuroraLoadingShimmer(height: 200, cornerRadius: 16)
    }

    private func valueForDate(_ date: Date) -> Double? {
        dailyPoints.first {
            Calendar.current.isDate($0.date, inSameDayAs: date)
        }?.value
    }

    private func formatValue(_ value: Double) -> String {
        switch displayMode {
        case .currency: return value.formatAsCost()
        case .tokens:   return Int(value).formatAsTokenVolume()
        }
    }
}

// MARK: - Accessibility

@MainActor
extension TrendSparkCard: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Date",
            range: 0...Double(Swift.max(dailyPoints.count, 1) - 1),
            gridlinePositions: []
        ) { value in
            guard !dailyPoints.isEmpty else { return "No data" }
            let index = Swift.max(0, Swift.min(dailyPoints.count - 1, Int(value)))
            return DateFormatter.localizedString(from: dailyPoints[index].date, dateStyle: .short, timeStyle: .none)
        }
        let yAxisMaximum = dailyPoints.map(\.value).max() ?? 1
        let yAxis = AXNumericDataAxisDescriptor(
            title: displayMode == .currency ? "Cost (USD)" : "Tokens",
            range: 0...yAxisMaximum,
            gridlinePositions: []
        ) { value in "\(value)" }

        let series = AXDataSeriesDescriptor(
            name: "Daily total",
            isContinuous: true,
            dataPoints: dailyPoints.enumerated().map { index, point in
                AXDataPoint(x: Double(index), y: point.value)
            }
        )

        return AXChartDescriptor(
            title: "Daily trend",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
