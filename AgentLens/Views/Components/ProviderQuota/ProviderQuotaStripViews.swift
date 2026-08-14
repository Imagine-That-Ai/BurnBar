import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Shared bar styling

/// Fill, track, and threshold logic shared by the popover's primary bar and
/// the dual-window strip, so every quota surface agrees on color steps.
enum QuotaBarFill {
    static func fraction(for bucket: ProviderQuotaBucket) -> Double {
        if let remainingPercent = bucket.remainingPercent {
            return min(max(remainingPercent / 100, 0), 1)
        }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }

    static func color(for fraction: Double, theme: ProviderTheme) -> Color {
        switch fraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.72)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    /// Bar gradient. Pass the ambient `ColorScheme` via `adjustingFor` so
    /// extreme-luminance brand colors (Warp's near-white, xAI's near-black)
    /// stay visible against the track in the appearance where they'd
    /// otherwise wash out.
    static func gradient(for fraction: Double, theme: ProviderTheme, adjustingFor scheme: ColorScheme? = nil) -> LinearGradient {
        let primary = scheme.map { quotaLegibleProviderColor(theme.primaryColor, in: $0) } ?? theme.primaryColor
        let accent = scheme.map { quotaLegibleProviderColor(theme.accentColor, in: $0) } ?? theme.accentColor
        switch fraction {
        case 0.75...:
            return LinearGradient(
                colors: [primary, accent],
                startPoint: .leading, endPoint: .trailing
            )
        case 0.50..<0.75:
            return LinearGradient(
                colors: [primary.opacity(0.72), accent.opacity(0.56)],
                startPoint: .leading, endPoint: .trailing
            )
        case 0.25..<0.50:
            return LinearGradient(
                colors: [primary.opacity(0.48), DesignSystem.Colors.amber],
                startPoint: .leading, endPoint: .trailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.warning],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    /// Bar track: dark inset well in dark mode, soft gray in light mode.
    static func trackColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.74) : Color.black.opacity(0.18)
    }
}

// MARK: - Popover copy

/// Text formatting for the popover's collapsed quota rows. Kept as pure
/// static functions so the exact strings are unit-testable.
enum QuotaPopoverCopy {
    /// Headline remaining copy — "75% left", "$400.00 left", "350.8M left",
    /// or "Unavailable" when the bucket carries no signal.
    static func remainingLeftText(for bucket: ProviderQuotaBucket?) -> String {
        guard let bucket else { return "—" }
        if let remainingPercent = bucket.remainingPercent {
            let clamped = min(max(remainingPercent, 0), 100)
            return "\(Int(clamped.rounded()))% left"
        }
        let text = bucket.remainingText
        return text == "Unavailable" ? text : "\(text) left"
    }

    /// Short window tag matching the dual strip's vocabulary ("5h", "7d").
    static func windowLabel(for bucket: ProviderQuotaBucket) -> String {
        switch bucket.windowKind {
        case .rollingHours: return "5h"
        case .daily: return "24h"
        case .weekly, .rollingDays: return "7d"
        case .monthly: return "30d"
        case .lifetime: return "All"
        case .custom: return ""
        }
    }

    /// Muted reset line under the bar — "7d · resets in 4d 22h". Nil when the
    /// bucket has no known reset moment so the row drops the line entirely.
    static func resetsText(for bucket: ProviderQuotaBucket?) -> String? {
        guard let bucket, let pair = bucket.resetsAtDisplay else { return nil }
        let window = windowLabel(for: bucket)
        return window.isEmpty ? "resets \(pair.relative)" : "\(window) · resets \(pair.relative)"
    }
}

/// Provider brand colors are fixed hexes — a few (Warp's near-white, xAI's
/// near-black) vanish against one appearance. Nudge those toward the
/// contrasting ink so the "% left" headline stays legible in both modes.
func quotaLegibleProviderColor(_ color: Color, in scheme: ColorScheme) -> Color {
    #if canImport(AppKit)
    guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return color }
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    switch scheme {
    case .light where luminance > 0.55:
        return Color(rgb.blended(withFraction: 0.38, of: .black) ?? rgb)
    case .dark where luminance < 0.22:
        return Color(rgb.blended(withFraction: 0.50, of: .white) ?? rgb)
    default:
        return color
    }
    #else
    return color
    #endif
}

// MARK: - Dual Window Strip

/// Compact inline component that always shows two quota windows as horizontal bar
/// strips within a single surface. Labels adapt to whatever time windows are available.
struct QuotaDualWindowStrip: View {
    let hourlyBucket: ProviderQuotaBucket?
    let weeklyBucket: ProviderQuotaBucket?
    let fallbackBucket: ProviderQuotaBucket?
    let provider: AgentProvider
    let isActive: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var negativeSpaceColor: Color {
        QuotaBarFill.trackColor(for: colorScheme)
    }

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
        let fraction = QuotaBarFill.fraction(for: bucket)
        let fill = QuotaBarFill.color(for: fraction, theme: theme)
        let gradient = QuotaBarFill.gradient(for: fraction, theme: theme, adjustingFor: colorScheme)

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
                        .fill(negativeSpaceColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(fill.opacity(0.18), lineWidth: 1)
                        )

                    // Fill
                    if fraction > 0 {
                        let fillWidth = geo.size.width * fraction
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(gradient)
                            .frame(width: fillWidth)
                            .shadow(color: fill.opacity(0.3), radius: 4, y: 0)
                            .animation(DesignSystem.Animation.gentle, value: fraction)
                    }

                    // Pace tick — where the fill edge SHOULD be if usage
                    // is to last the full window.
                    PaceTickOverlay(pace: bucket.idealPace(), tint: theme.primaryColor)
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
                .fill(negativeSpaceColor)
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

    private func windowTooltipText(for bucket: ProviderQuotaBucket, label: String) -> String {
        let resetText: String
        if let display = bucket.resetsAtDisplay {
            resetText = "Resets \(display.relative) · \(display.absolute)"
        } else {
            resetText = "Reset time unavailable"
        }
        return "\(label): \(bucket.remainingText) remaining\n\(resetText)"
    }
}

// MARK: - Primary Bar (popover collapsed row)

/// The popover's glanceable quota readout: provider name + "% left" headline,
/// a single gradient bar for the most-constrained window, and a muted reset
/// line. Tapping the row expands the dual-window strip for full detail.
struct QuotaPrimaryBar: View {
    let bucket: ProviderQuotaBucket?
    let provider: AgentProvider
    let isActive: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var fraction: Double { bucket.map { QuotaBarFill.fraction(for: $0) } ?? 0 }
    private var fillColor: Color { QuotaBarFill.color(for: fraction, theme: theme) }

    /// Headline tint: the provider's brand color while the reserve is healthy
    /// (nudged legible per appearance), state colors once it thins. Missing
    /// buckets stay muted — absence of data must not read as exhaustion.
    private var headlineColor: Color {
        guard bucket != nil else { return DesignSystem.Colors.textMuted }
        switch fraction {
        case 0.50...: return quotaLegibleProviderColor(theme.primaryColor, in: colorScheme)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(QuotaPopoverCopy.remainingLeftText(for: bucket))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(DesignSystem.Animation.gentle, value: bucket?.remainingPercent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(QuotaBarFill.trackColor(for: colorScheme))

                    if fraction > 0 {
                        Capsule(style: .continuous)
                            .fill(QuotaBarFill.gradient(for: fraction, theme: theme, adjustingFor: colorScheme))
                            .frame(width: geo.size.width * fraction)
                            .shadow(color: fillColor.opacity(0.30), radius: 3, y: 0)
                            .animation(DesignSystem.Animation.gentle, value: fraction)
                    }

                    PaceTickOverlay(pace: bucket?.idealPace(), tint: quotaLegibleProviderColor(theme.primaryColor, in: colorScheme))
                }
            }
            .frame(height: 6)

            if let resets = QuotaPopoverCopy.resetsText(for: bucket) {
                Text(resets)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .popoverTooltip(tooltipText)
    }

    private var tooltipText: String {
        guard let bucket else { return "\(provider.displayName): No quota signal yet" }
        let window = QuotaPopoverCopy.windowLabel(for: bucket)
        let label = window.isEmpty ? provider.displayName : "\(provider.displayName) · \(window)"
        if let pair = bucket.resetsAtDisplay {
            return "\(label): \(bucket.remainingText) remaining\nResets \(pair.relative) · \(pair.absolute)"
        }
        return "\(label): \(bucket.remainingText) remaining"
    }
}

struct QuotaMicroBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .truncationMode(.middle)
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
        case .high: return DesignSystem.Colors.success
        case .medium: return DesignSystem.Colors.warning
        case .low, .stale: return DesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        Text(source.label)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 5)
            .background(foreground.opacity(0.08))
            .overlay(
                Capsule()
                    .stroke(foreground.opacity(0.14), lineWidth: 1)
            )
            .clipShape(.capsule)
    }
}
