import SwiftUI
import OpenBurnBarKernel

// MARK: - Mission Burn Forecast Strip
//
// Pre-dispatch sanity panel: three columns (tokens / cost / ETA) with the
// low–high range from the forecast computer. Tints the cost when the high end
// exceeds $1.

public struct MissionBurnForecastStrip: View {
    public let forecast: MissionConsoleForecast
    public let runtimeName: String
    public let runtimeAccent: Color

    public init(
        forecast: MissionConsoleForecast,
        runtimeName: String,
        runtimeAccent: Color
    ) {
        self.forecast = forecast
        self.runtimeName = runtimeName
        self.runtimeAccent = runtimeAccent
    }

    public var body: some View {
        MissionConsoleCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack(spacing: 6) {
                    Text("Estimate")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    Spacer(minLength: 0)
                    Text("via \(runtimeName)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(runtimeAccent)
                        .lineLimit(1)
                }

                HStack(spacing: 0) {
                    forecastCell(
                        label: "Tokens",
                        value: MissionConsoleFormatting.tokenRange(forecast.tokensLow, forecast.tokensHigh),
                        tint: UnifiedDesignSystem.Colors.textPrimary
                    )
                    forecastDivider
                    forecastCell(
                        label: "Cost",
                        value: MissionConsoleFormatting.costRange(forecast.costLowUSD, forecast.costHighUSD),
                        tint: forecast.costHighUSD > 1.0 ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.textPrimary
                    )
                    forecastDivider
                    forecastCell(
                        label: "Time",
                        value: MissionConsoleFormatting.durationRange(forecast.etaLow, forecast.etaHigh),
                        tint: UnifiedDesignSystem.Colors.textPrimary
                    )
                }
            }
            .padding(UnifiedDesignSystem.Spacing.md)
        }
    }

    private var forecastDivider: some View {
        Rectangle()
            .fill(MissionChrome.hairlineColor)
            .frame(width: MissionChrome.hairline, height: 32)
    }

    private func forecastCell(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .animation(UnifiedDesignSystem.Animation.gentle, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
    }
}

// MARK: - Dispatch Button
//
// The primary CTA. Full-width rounded rect in the accent gradient. While
// dispatching it swaps the label for a spinner.

public struct MissionDispatchButton: View {
    public let runtimeAccent: Color
    public let runtimeName: String
    public let isEnabled: Bool
    public let isDispatching: Bool
    public let action: () -> Void

    public init(
        runtimeAccent: Color,
        runtimeName: String,
        isEnabled: Bool,
        isDispatching: Bool,
        action: @escaping () -> Void
    ) {
        self.runtimeAccent = runtimeAccent
        self.runtimeName = runtimeName
        self.isEnabled = isEnabled
        self.isDispatching = isDispatching
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                if isDispatching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                    Text("Dispatching…")
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Dispatch via \(runtimeName)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [runtimeAccent, runtimeAccent.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(isEnabled || isDispatching ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isDispatching)
        .accessibilityLabel(isDispatching ? "Dispatching mission via \(runtimeName)" : "Dispatch mission via \(runtimeName)")
    }
}
