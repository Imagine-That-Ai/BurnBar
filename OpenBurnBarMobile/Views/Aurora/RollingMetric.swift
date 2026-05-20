import SwiftUI

// MARK: - Rolling Metric
//
// Headline metric component for hero cards. Composes:
//   - Caption / "eyebrow" label
//   - Big rolling number with `.contentTransition(.numericText())`
//   - Optional sparkline behind the number
//   - Optional trend pill (up/down with delta percent)

struct RollingMetric: View {

    let label: String
    let value: String
    let subtitle: String?
    let trend: Trend?
    let sparkline: [Double]?
    let valueFont: Font

    init(
        label: String,
        value: String,
        subtitle: String? = nil,
        trend: Trend? = nil,
        sparkline: [Double]? = nil,
        valueFont: Font = AuroraDesign.Typography.displayHero
    ) {
        self.label = label
        self.value = value
        self.subtitle = subtitle
        self.trend = trend
        self.sparkline = sparkline
        self.valueFont = valueFont
    }

    struct Trend: Equatable {
        var deltaPercent: Double
        var direction: Direction
        enum Direction { case up, down, flat }

        var icon: String {
            switch direction {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "arrow.right"
            }
        }

        var color: Color {
            switch direction {
            case .up: return MobileTheme.warning
            case .down: return MobileTheme.success
            case .flat: return MobileTheme.Colors.textMuted
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            ZStack(alignment: .bottomLeading) {
                if let sparkline, !sparkline.isEmpty {
                    EmberSparkline(values: sparkline)
                        .frame(height: 56)
                        .padding(.bottom, 4)
                        .opacity(0.65)
                }

                Text(value)
                    .font(valueFont)
                    .fontDesign(.rounded)
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: MobileTheme.ember.opacity(0.35), radius: 12, y: 6)
            }

            if let subtitle {
                Text(subtitle)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .contentTransition(.numericText())
            }

            if let trend {
                trendPill(trend)
            }
        }
    }

    @ViewBuilder
    private func trendPill(_ trend: Trend) -> some View {
        HStack(spacing: 4) {
            Image(systemName: trend.icon)
                .font(.system(size: 13, weight: .bold))
            Text(String(format: "%.1f%%", abs(trend.deltaPercent)))
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(trend.color.opacity(0.16))
        )
        .overlay(
            Capsule()
                .stroke(trend.color.opacity(0.4), lineWidth: 0.5)
        )
        .foregroundStyle(trend.color)
    }
}
