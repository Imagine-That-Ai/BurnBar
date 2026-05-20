import SwiftUI

// MARK: - Mission Burn Forecast Strip
//
// Pre-dispatch sanity panel. Three mono digit blocks (tokens / cost / ETA) with
// a low–high range. Tints amber when projected cost exceeds $1.

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
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(runtimeAccent)
                Text("FORECAST")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Spacer()
                Text("via \(runtimeName)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(runtimeAccent)
            }

            HStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                forecastCell(
                    label: "TOKENS",
                    value: MissionConsoleFormatting.tokenRange(forecast.tokensLow, forecast.tokensHigh),
                    tint: UnifiedDesignSystem.Colors.textPrimary
                )
                Divider().frame(height: 36).overlay(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7))
                forecastCell(
                    label: "COST",
                    value: MissionConsoleFormatting.costRange(forecast.costLowUSD, forecast.costHighUSD),
                    tint: forecast.costHighUSD > 1.0 ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.textPrimary
                )
                Divider().frame(height: 36).overlay(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7))
                forecastCell(
                    label: "ETA",
                    value: MissionConsoleFormatting.durationRange(forecast.etaLow, forecast.etaHigh),
                    tint: UnifiedDesignSystem.Colors.textPrimary
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.4))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func forecastCell(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(UnifiedDesignSystem.Animation.gentle, value: value)
        }
    }
}

// MARK: - Dispatch Button
//
// The hero CTA. Fills with the chosen runtime's provider color. On press it
// scales subtly. While dispatching it shows an inline progress spinner; the
// "lift-off" transition is owned by the parent (the active tile slides in).

public struct MissionDispatchButton: View {
    public let runtimeAccent: Color
    public let runtimeName: String
    public let isEnabled: Bool
    public let isDispatching: Bool
    public let action: () -> Void

    @State private var pressed = false

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
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .rotationEffect(.degrees(-45))
                }

                Text(isDispatching ? "Dispatching…" : "Dispatch")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .kerning(0.2)

                Spacer(minLength: UnifiedDesignSystem.Spacing.sm)

                if !isDispatching {
                    HStack(spacing: 4) {
                        Text("via")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .opacity(0.7)
                        Text(runtimeName.uppercased())
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                    }
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(Color.white.opacity(0.2))
                    }
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            .padding(.vertical, UnifiedDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [runtimeAccent, runtimeAccent.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            }
            .shadow(color: runtimeAccent.opacity(0.42), radius: pressed ? 6 : 18, y: pressed ? 2 : 8)
            .scaleEffect(pressed ? 0.985 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.45)
            .animation(UnifiedDesignSystem.Animation.hover, value: pressed)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isDispatching)
        .onHover { hovering in
            // Picked up by hover on macOS; ignored on iOS.
            pressed = hovering
        }
        .accessibilityLabel(isDispatching ? "Dispatching mission via \(runtimeName)" : "Dispatch mission via \(runtimeName)")
    }
}
