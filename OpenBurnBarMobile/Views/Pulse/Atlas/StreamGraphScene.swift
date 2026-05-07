import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Stream Graph Scene
//
// Provider-stacked stream graph with brand tinting, plus a translucent
// total ribbon that traces the daily window. Powers the "Spend" tab of
// Trend Atlas. Designed to look intentionally beautiful even at preview
// size — the eye should land on this and want to expand it.

struct StreamGraphScene: View {
    let digest: TrendDataDigest
    let displayMode: UsageDisplayMode

    @State private var selectedDate: Date?

    private var stackedSeries: [(provider: String, color: Color, points: [(Date, Double)])] {
        // Sort providers by overall share so the largest sits at the bottom of
        // the stack (this is what makes a stream graph readable).
        let providers = digest.providers
            .filter { $0.tokens > 0 }
            .sorted { $0.sharePct > $1.sharePct }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return providers.map { p -> (String, Color, [(Date, Double)]) in
            let series: [(Date, Double)] = digest.daily.compactMap { day in
                guard let date = formatter.date(from: day.date) else { return nil }
                let value = day.perProvider[p.providerKey] ?? 0
                return (date, value)
            }
            let agent = AgentProvider.fromPersistedToken(p.providerKey)
            let color = agent.map(MobileTheme.Colors.primary(for:)) ?? MobileTheme.amber
            return (p.provider, color, series)
        }
    }

    private var hasData: Bool {
        digest.daily.contains(where: { $0.total > 0 }) || !stackedSeries.flatMap(\.points).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            if hasData {
                chart
                    .frame(height: 180)
                    .padding(.top, 4)
                    .overlay(alignment: .topLeading) { totalRibbon }
                HourOfDayHeatStrip(buckets: digest.hourly)
                    .frame(height: 36)
            } else {
                AuroraLoadingShimmer(height: 180, cornerRadius: 16)
                AuroraLoadingShimmer(height: 36, cornerRadius: 8)
            }
        }
    }

    // MARK: - Stream chart

    private var chart: some View {
        Chart {
            ForEach(Array(stackedSeries.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.0) { point in
                    AreaMark(
                        x: .value("Date", point.0, unit: .day),
                        y: .value("Cost", point.1),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Provider", series.provider))
                    .interpolationMethod(.catmullRom)
                }
            }
            // Today rule
            if let lastDate = stackedSeries.flatMap({ $0.points }).map(\.0).max() {
                RuleMark(x: .value("Today", lastDate, unit: .day))
                    .foregroundStyle(MobileTheme.amber.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let selectedDate {
                RuleMark(x: .value("Selected", selectedDate, unit: .day))
                    .foregroundStyle(MobileTheme.ember.opacity(0.85))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        VStack(spacing: 2) {
                            Text(selectedDate, format: .dateTime.month().day())
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                            Text(formatTotal(for: selectedDate))
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial)
                        )
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: stackedSeries.map(\.provider),
            range: stackedSeries.map(\.color)
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                AxisValueLabel(format: .dateTime.month().day())
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .chartYAxis(.hidden)
        .chartXSelection(value: $selectedDate)
        .chartLegend(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Total ribbon (translucent overlay tracing the sum)

    private var totalRibbon: some View {
        // Subtle highlight across the topmost ridge — purely decorative, gives
        // the stack a glassy "amber sheen" the eye reads first.
        LinearGradient(
            colors: [
                MobileTheme.ember.opacity(0.35),
                MobileTheme.amber.opacity(0.18),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 16)
        .blendMode(.plusLighter)
        .padding(.top, 4)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }

    private func formatTotal(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        let key = f.string(from: date)
        guard let day = digest.daily.first(where: { $0.date == key }) else { return "—" }
        switch displayMode {
        case .currency: return day.total.formatAsCost()
        case .tokens:   return Int(day.total).formatAsTokenVolume()
        }
    }
}
