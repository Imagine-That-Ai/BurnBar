import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Dual Window Strip

/// Compact inline component that always shows two quota windows as horizontal bar
/// strips within a single surface. Labels adapt to whatever time windows are available.
struct QuotaDualWindowStrip: View {
    let hourlyBucket: ProviderQuotaBucket?
    let weeklyBucket: ProviderQuotaBucket?
    let fallbackBucket: ProviderQuotaBucket?
    let provider: AgentProvider
    let isActive: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    /// The "short" slot prefers the hourly bucket; falls back to a daily fallback.
    private var shortSlotBucket: ProviderQuotaBucket? {
        if let hourlyBucket { return hourlyBucket }
        if let fallback = fallbackBucket, fallback.windowKind == .daily { return fallback }
        return nil
    }

    /// The "long" slot prefers the weekly bucket; falls back to the primary bucket.
    private var longSlotBucket: ProviderQuotaBucket? {
        if let weeklyBucket { return weeklyBucket }
        return fallbackBucket
    }

    private func rowConfig(for bucket: ProviderQuotaBucket, defaultLabel: String, defaultIcon: String) -> (label: String, icon: String) {
        switch bucket.windowKind {
        case .rollingHours: return ("5h", "clock.fill")
        case .daily:        return ("24h", "clock")
        case .weekly:       return ("7d", "calendar")
        case .rollingDays:  return ("7d", "calendar")
        case .monthly:      return ("30d", "calendar")
        case .lifetime:     return ("All", "infinity")
        case .custom:       return (defaultLabel, defaultIcon)
        }
    }

    var body: some View {
        dualLayout
    }

    // MARK: - Dual Layout

    private var dualLayout: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Short window row (5h / 24h)
            if let bucket = shortSlotBucket {
                let config = rowConfig(for: bucket, defaultLabel: "5h", defaultIcon: "clock.fill")
                windowBar(bucket: bucket, label: config.label, icon: config.icon)
            } else {
                windowBarPlaceholder(label: "5h", icon: "clock.fill")
            }

            // Long window row (7d / 30d)
            if let bucket = longSlotBucket {
                let config = rowConfig(for: bucket, defaultLabel: "7d", defaultIcon: "calendar")
                windowBar(bucket: bucket, label: config.label, icon: config.icon)
            } else {
                windowBarPlaceholder(label: "7d", icon: "calendar")
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.14), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    // MARK: - Window Bar

    @ViewBuilder
    private func windowBar(bucket: ProviderQuotaBucket, label: String, icon: String) -> some View {
        let fraction = remainingFraction(for: bucket)
        let fill = fillColor(for: fraction)
        let gradient = fillGradient(for: fraction)

        HStack(spacing: DesignSystem.Spacing.sm) {
            // Window label
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(fill)
                    .frame(width: 12)
                Text(label)
                    .font(DesignSystem.Typography.monoTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(width: 34, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(fill.opacity(0.18), lineWidth: 1)
                        )

                    // Fill
                    if fraction > 0.02 {
                        let fillWidth = max(geo.size.width * fraction, 6)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(gradient)
                            .frame(width: fillWidth)
                            .shadow(color: fill.opacity(0.3), radius: 4, y: 0)
                    }
                }
            }
            .frame(height: 10)

            // Remaining text
            Text(bucket.remainingText)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(fill)
                .lineLimit(1)
                .frame(width: 36, alignment: .trailing)
        }
        .popoverTooltip(windowTooltipText(for: bucket, label: label))
    }

    @ViewBuilder
    private func windowBarPlaceholder(label: String, icon: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 12)
                Text(label)
                    .font(DesignSystem.Typography.monoTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(width: 34, alignment: .leading)

            // Empty track
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(
                            theme.primaryColor.opacity(isActive ? 0.18 : 0.08),
                            style: StrokeStyle(lineWidth: 1, dash: isActive ? [3, 3] : [])
                        )
                )
                .frame(height: 10)

            Text("—")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 36, alignment: .trailing)
        }
        .popoverTooltip("\(label): No quota signal yet\nReset time unavailable")
    }

    // MARK: - Color Helpers

    private func remainingFraction(for bucket: ProviderQuotaBucket) -> Double {
        if let remainingPercent = bucket.remainingPercent {
            return min(max(remainingPercent / 100, 0), 1)
        }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }

    private func fillColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.72)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    private func fillGradient(for fraction: Double) -> LinearGradient {
        switch fraction {
        case 0.75...:
            return LinearGradient(
                colors: [theme.primaryColor, theme.accentColor],
                startPoint: .leading, endPoint: .trailing
            )
        case 0.50..<0.75:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.72), theme.accentColor.opacity(0.56)],
                startPoint: .leading, endPoint: .trailing
            )
        case 0.25..<0.50:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.48), DesignSystem.Colors.amber],
                startPoint: .leading, endPoint: .trailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.warning],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    private func windowTooltipText(for bucket: ProviderQuotaBucket, label: String) -> String {
        let resetText: String
        if let resetsAt = bucket.resetsAt {
            resetText = "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
        } else {
            resetText = "Reset time unavailable"
        }
        return "\(label): \(bucket.remainingText) remaining\n\(resetText)"
    }
}

struct QuotaMicroBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 5)
            .background(tint.opacity(0.08))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            )
            .clipShape(.capsule)
    }
}

struct QuotaSourceBadge: View {
    let source: ProviderQuotaSourceKind
    let confidence: ProviderQuotaConfidence

    private var foreground: Color {
        switch confidence {
        case .exact: return DesignSystem.Colors.success
        case .estimated: return DesignSystem.Colors.warning
        case .unavailable: return DesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        Text(source.label)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(foreground.opacity(0.08))
            .overlay(
                Capsule()
                    .stroke(foreground.opacity(0.14), lineWidth: 1)
            )
            .clipShape(.capsule)
    }
}
