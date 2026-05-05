import SwiftUI

/// Cross-platform quota signal view — the battery-bar visualization.
/// Used identically on macOS and iOS.
public struct UnifiedQuotaSignalView: View {
    public let bucket: ProviderQuotaBucket
    public let provider: AgentProvider
    public var compact: Bool = false

    public init(bucket: ProviderQuotaBucket, provider: AgentProvider, compact: Bool = false) {
        self.bucket = bucket
        self.provider = provider
        self.compact = compact
    }

    @Environment(\.colorScheme) private var colorScheme

    private var theme: UnifiedProviderTheme { UnifiedProviderTheme.theme(for: provider) }
    private var remainingFraction: Double {
        guard bucket.limit > 0 else { return 0 }
        return max(0, bucket.remaining) / bucket.limit
    }
    private var signalStatus: QuotaSignalStatus {
        QuotaSignalStatus.resolve(fraction: remainingFraction, theme: theme)
    }

    private var fillColor: Color {
        switch remainingFraction {
        case 0.75...:   return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.72)
        case 0.25..<0.50: return UnifiedDesignSystem.Colors.amber
        default:        return UnifiedDesignSystem.Colors.warning
        }
    }

    private var fillGradient: LinearGradient {
        switch remainingFraction {
        case 0.75...:
            return LinearGradient(colors: [theme.primaryColor, theme.accentColor], startPoint: .leading, endPoint: .trailing)
        case 0.50..<0.75:
            return LinearGradient(colors: [theme.primaryColor.opacity(0.72), theme.accentColor.opacity(0.56)], startPoint: .leading, endPoint: .trailing)
        case 0.25..<0.50:
            return LinearGradient(colors: [theme.primaryColor.opacity(0.48), UnifiedDesignSystem.Colors.amber], startPoint: .leading, endPoint: .trailing)
        default:
            return LinearGradient(colors: [UnifiedDesignSystem.Colors.amber, UnifiedDesignSystem.Colors.warning], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var batteryHeight: CGFloat { compact ? 28 : 36 }
    private var batteryRadius: CGFloat { compact ? 6 : 8 }
    private var terminalWidth: CGFloat { compact ? 4 : 5 }
    private var terminalHeight: CGFloat { batteryHeight * 0.38 }
    private var cornerRadius: CGFloat { compact ? 14 : 16 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.surface.opacity(0.96),
                            UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.92),
                            theme.primaryColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                // Identity row: the bucket's actual name + the time window it
                // represents. Without this, multiple gauges look identical in
                // the per-account sheet — the only label was a status word.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bucketDisplayName)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    if let windowLabel {
                        Text(windowLabel)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.7))
                            )
                            .overlay(
                                Capsule().stroke(theme.primaryColor.opacity(0.18), lineWidth: 0.5)
                            )
                    }
                    Spacer(minLength: 0)
                    if compact {
                        Text(remainingPercentText)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(fillColor)
                    }
                }

                // Status row — the qualitative state.
                HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(signalStatus.label.uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(signalStatus.tint.opacity(0.86))

                    if compact {
                        Spacer()
                        Text(remainingText)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(fillColor)
                    }
                }

                if !compact {
                    Text(signalStatus.detail)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary.opacity(0.82))
                }

                // Battery bar
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                            .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                                    .stroke(fillColor.opacity(0.22), lineWidth: 1.5)
                            )

                        GeometryReader { geo in
                            let fillWidth = max(geo.size.width * remainingFraction, batteryRadius * 2)
                            RoundedRectangle(cornerRadius: batteryRadius - 1.5, style: .continuous)
                                .fill(fillGradient)
                                .frame(width: remainingFraction > 0.02 ? fillWidth : 0)
                                .padding(2)
                                .shadow(color: fillColor.opacity(0.35), radius: 6, y: 0)
                        }
                    }
                    .frame(height: batteryHeight)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fillColor.opacity(0.32))
                        .frame(width: terminalWidth, height: terminalHeight)
                        .padding(.leading, 2)
                }

                if !compact {
                    HStack {
                        Text(remainingText + " remaining")
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(fillColor)

                        Spacer()

                        Text(usageText)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                }
            }
            .padding(compact ? 10 : 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.primaryColor.opacity(compact ? 0.14 : 0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) quota: \(remainingText) remaining")
    }

    private var remainingText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: bucket.remaining)) ?? "\(Int(bucket.remaining))"
    }

    private var usageText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let used = formatter.string(from: NSNumber(value: bucket.used)) ?? "\(Int(bucket.used))"
        let limit = formatter.string(from: NSNumber(value: bucket.limit)) ?? "\(Int(bucket.limit))"
        return "\(used) / \(limit)"
    }

    private var remainingPercentText: String {
        guard bucket.limit > 0 else { return "—" }
        let pct = remainingFraction * 100
        if pct < 1 {
            return String(format: "%.1f%%", pct)
        }
        return "\(Int(pct.rounded()))%"
    }

    /// Friendly bucket name. Falls back to a humanized form of the raw key.
    private var bucketDisplayName: String {
        let raw = bucket.name.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "Quota" }
        // If the name already contains a space (e.g. "Sonnet 5h"), use it directly.
        if raw.contains(" ") { return raw }
        // Otherwise lightly humanize (`hourly_tokens` → "Hourly Tokens").
        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return cleaned
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Short pill label for the bucket's time window. Matches the macOS
    /// strip's "5h / 24h / 7d / 30d / All" vocabulary so the two surfaces
    /// read consistently.
    private var windowLabel: String? {
        let raw = (bucket.window ?? "").lowercased()
        switch raw {
        case "rollinghours", "rolling_hours", "hourly", "5h": return "5h"
        case "daily", "24h": return "24h"
        case "weekly", "rollingdays", "rolling_days", "7d": return "7d"
        case "monthly", "30d": return "30d"
        case "lifetime", "alltime", "all_time": return "All"
        case "": return nil
        default:
            // Already short like "12h" or "3d" — uppercase trailing unit.
            if raw.count <= 4 { return raw.uppercased() }
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

// MARK: - Signal Status

public struct QuotaSignalStatus {
    public let label: String
    public let detail: String
    public let tint: Color

    public static func resolve(fraction: Double, theme: UnifiedProviderTheme) -> QuotaSignalStatus {
        switch fraction {
        case ..<0.10:
            return QuotaSignalStatus(label: "Near Edge", detail: "Close to the active cap.", tint: UnifiedDesignSystem.Colors.warning)
        case ..<0.25:
            return QuotaSignalStatus(label: "Narrowing", detail: "Reserve is thinning.", tint: UnifiedDesignSystem.Colors.amber)
        case ..<0.50:
            return QuotaSignalStatus(label: "Comfortable", detail: "Healthy reserve remains.", tint: theme.accentColor)
        default:
            return QuotaSignalStatus(label: "Wide Open", detail: "Plenty of headroom in this window.", tint: theme.primaryColor)
        }
    }
}
