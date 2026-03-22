import SwiftUI
import Charts

struct DailyTrendChart: View {
    let usages: [TokenUsage]
    let theme: ProviderTheme
    let days: Int
    
    init(usages: [TokenUsage], theme: ProviderTheme, days: Int = 30) {
        self.usages = usages
        self.theme = theme
        self.days = days
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daily Trend")
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(theme.textColor)
                
                Spacer()
                
                Text("Last \(days) days")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            
            Chart(dailyData, id: \.date) { day in
                LineMark(
                    x: .value("Date", day.date),
                    y: .value("Cost", day.cost)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [theme.primaryColor, theme.accentColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                
                AreaMark(
                    x: .value("Date", day.date),
                    y: .value("Cost", day.cost)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.3),
                            theme.primaryColor.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                PointMark(
                    x: .value("Date", day.date),
                    y: .value("Cost", day.cost)
                )
                .foregroundStyle(theme.primaryColor)
                .symbolSize(20)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(theme.textColor.opacity(0.1))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(formatDate(date))
                                .font(ThemeManager.Typography.monoCaption)
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(theme.textColor.opacity(0.1))
                    AxisValueLabel {
                        if let cost = value.as(Double.self) {
                            Text(formatCost(cost))
                                .font(ThemeManager.Typography.monoCaption)
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...(dailyData.map(\.cost).max() ?? 1) * 1.1)
            .frame(height: 200)
            
            // Summary Stats
            HStack(spacing: 24) {
                StatPill(
                    label: "Avg/Day",
                    value: formatCost(averageDailyCost),
                    color: theme.primaryColor
                )
                
                StatPill(
                    label: "Peak",
                    value: formatCost(peakDailyCost),
                    color: theme.accentColor
                )
                
                StatPill(
                    label: "Total",
                    value: formatCost(totalCost),
                    color: theme.chartColors[2]
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.lg)
                .fill(theme.secondaryBackgroundColor)
        )
    }
    
    // MARK: - Computed Properties
    
    private var dailyData: [(date: Date, cost: Double)] {
        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        
        var dailyCosts: [Date: Double] = [:]
        
        // Initialize all days with 0
        for offset in 0..<days {
            if let date = calendar.date(byAdding: .day, value: -offset, to: now) {
                let dayStart = calendar.startOfDay(for: date)
                dailyCosts[dayStart] = 0
            }
        }
        
        // Fill in actual costs
        let filteredUsages = usages.filter { $0.startTime >= startDate }
        for usage in filteredUsages {
            let dayStart = calendar.startOfDay(for: usage.startTime)
            dailyCosts[dayStart, default: 0] += usage.cost
        }
        
        return dailyCosts
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }
    
    private var averageDailyCost: Double {
        guard !dailyData.isEmpty else { return 0 }
        return dailyData.reduce(0) { $0 + $1.cost } / Double(dailyData.count)
    }
    
    private var peakDailyCost: Double {
        dailyData.map(\.cost).max() ?? 0
    }
    
    private var totalCost: Double {
        dailyData.reduce(0) { $0 + $1.cost }
    }
    
    // MARK: - Helpers
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
    
    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1.0 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(ThemeManager.Typography.monoCaption)
                .foregroundStyle(color)
            
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
        )
    }
}

#Preview {
    DailyTrendChart(
        usages: (0..<30).map { i in
            TokenUsage(
                provider: .factory,
                sessionId: "session-\(i)",
                projectName: "Test",
                model: "claude",
                inputTokens: Int.random(in: 1000...50000),
                outputTokens: Int.random(in: 500...20000),
                startTime: Calendar.current.date(byAdding: .day, value: -i, to: Date()) ?? Date(),
                endTime: Date()
            )
        },
        theme: .theme(for: .factory),
        days: 30
    )
    .frame(width: 500)
    .padding()
}
