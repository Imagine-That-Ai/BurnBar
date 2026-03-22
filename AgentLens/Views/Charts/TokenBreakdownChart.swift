import SwiftUI
import Charts

struct TokenBreakdownChart: View {
    let usages: [TokenUsage]
    let theme: ProviderTheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token Breakdown")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(theme.textColor)
            
            Chart(tokenData, id: \.label) { item in
                BarMark(
                    x: .value("Type", item.label),
                    y: .value("Tokens", item.value)
                )
                .foregroundStyle(item.color)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(theme.textColor.opacity(0.1))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(theme.textColor.opacity(0.1))
                    AxisValueLabel {
                        if let intValue = value.as(Int.self) {
                            Text(formatTokens(intValue))
                                .font(ThemeManager.Typography.monoCaption)
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                    }
                }
            }
            .frame(height: 200)
            
            // Legend
            HStack(spacing: 16) {
                ForEach(tokenData, id: \.label) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)
                        
                        Text(item.label)
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.lg)
                .fill(theme.secondaryBackgroundColor)
        )
    }
    
    private var tokenData: [(label: String, value: Int, color: Color)] {
        let totalInput = usages.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = usages.reduce(0) { $0 + $1.outputTokens }
        let totalCacheCreation = usages.reduce(0) { $0 + $1.cacheCreationTokens }
        let totalCacheRead = usages.reduce(0) { $0 + $1.cacheReadTokens }
        
        return [
            ("Input", totalInput, theme.chartColors[0]),
            ("Output", totalOutput, theme.chartColors[1]),
            ("Cache Write", totalCacheCreation, theme.chartColors[2]),
            ("Cache Read", totalCacheRead, theme.chartColors[3])
        ]
        .filter { $0.1 > 0 }
    }
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
    }
}

#Preview {
    TokenBreakdownChart(
        usages: [
            TokenUsage(
                provider: .factory,
                sessionId: "test",
                projectName: "Test",
                model: "claude",
                inputTokens: 10000,
                outputTokens: 5000,
                cacheCreationTokens: 2000,
                cacheReadTokens: 8000,
                startTime: Date(),
                endTime: Date()
            )
        ],
        theme: .theme(for: .factory)
    )
    .frame(width: 400)
    .padding()
}
