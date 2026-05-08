import SwiftUI
import OpenBurnBarCore

// MARK: - Velocity Forecast Card
//
// Renders the projected end-of-day burn alongside a "day progress" gauge.
// Updates on a 60s timer so the projection nudges throughout the day.

struct VelocityForecastCard: View {
    let todayTotals: RollupTotals?
    let trailingTotals: RollupTotals?
    let displayMode: UsageDisplayMode

    @State private var nowTick: Date = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var forecast: VelocityForecast? {
        guard let todayTotals else { return nil }
        return VelocityForecaster.forecast(
            todayCost: todayTotals.costUsd,
            todayTokens: todayTotals.tokens,
            sevenDayCost: trailingTotals?.costUsd ?? 0,
            sevenDayTokens: trailingTotals?.tokens ?? 0,
            now: nowTick
        )
    }

    var body: some View {
        AuroraGlassCard(variant: paceVariant, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection(
                    "End-of-day forecast",
                    subtitle: forecast?.pace.label ?? "Awaiting data",
                    accent: paceColor
                )

                HStack(spacing: MobileTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROJECTED")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .tracking(2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(projectedText)
                            .font(AuroraDesign.Typography.monoDisplay)
                            .foregroundStyle(MobileTheme.primaryGradient)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let forecast {
                            Label(forecast.pace.label, systemImage: forecast.pace.icon)
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(paceColor)
                        }
                    }
                    Spacer()
                    progressGauge
                        .frame(width: 88, height: 88)
                }
            }
        }
        .onReceive(timer) { _ in nowTick = Date() }
    }

    // MARK: - Derived

    private var projectedText: String {
        guard let forecast else { return "—" }
        switch displayMode {
        case .currency: return forecast.projectedCost.formatAsCost()
        case .tokens:   return forecast.projectedTokens.formatAsTokenVolume()
        }
    }

    private var paceVariant: AuroraGlassVariant {
        switch forecast?.pace {
        case .ahead: return .urgent
        case .below: return .success
        default:     return .standard
        }
    }

    private var paceColor: Color {
        switch forecast?.pace {
        case .ahead: return MobileTheme.warning
        case .below: return MobileTheme.success
        case .onTrack, .none: return MobileTheme.amber
        }
    }

    // MARK: - Gauge

    private var progressGauge: some View {
        let progress = CGFloat(forecast?.dayProgress ?? 0)
        return ZStack {
            Circle()
                .stroke(MobileTheme.Colors.border.opacity(0.3), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(
                    AngularGradient(
                        colors: [MobileTheme.amber, MobileTheme.ember, MobileTheme.amber],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: MobileTheme.amber.opacity(0.55), radius: 12)
            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("of day")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }
}
