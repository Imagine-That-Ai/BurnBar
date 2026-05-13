import SwiftUI
import Charts

public struct InsightKPITileView: View {
    public let data: InsightWidgetData.KPI

    public init(data: InsightWidgetData.KPI) { self.data = data }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.xs) {
                Text(InsightFormatting.format(data.value, as: data.valueFormat))
                    .font(UnifiedDesignSystem.Typography.display)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                if let delta = data.delta {
                    deltaPill(delta: delta)
                }
            }
            if let ctx = data.contextLabel, !ctx.isEmpty {
                Text(ctx)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            if !data.sparkline.isEmpty {
                sparkline
            }
        }
    }

    @ViewBuilder
    private func deltaPill(delta: Double) -> some View {
        let positive = delta >= 0
        let color: Color = positive
            ? UnifiedDesignSystem.Colors.success
            : UnifiedDesignSystem.Colors.error
        HStack(spacing: 2) {
            Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(InsightFormatting.formatDelta(delta, asPercent: data.deltaIsPercent))
                .font(UnifiedDesignSystem.Typography.caption)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }

    private var sparkline: some View {
        let points = data.sparkline.enumerated().map { (Double($0), $1) }
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("x", point.0), y: .value("y", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                AreaMark(x: .value("x", point.0), y: .value("y", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [
                            UnifiedDesignSystem.Colors.ember.opacity(0.25),
                            UnifiedDesignSystem.Colors.ember.opacity(0)
                        ], startPoint: .top, endPoint: .bottom)
                    )
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 36)
    }
}
