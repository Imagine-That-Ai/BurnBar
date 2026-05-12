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
        if bucketUnit == .unlimited { return 1 }
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
    private var negativeSpaceColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.74) : Color.black.opacity(0.18)
    }

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
                    if compact, let pair = bucket.resetsAtDisplay {
                        // Glance-level reset hint sits next to the window
                        // pill so the compact card still answers "when does
                        // this refill" without growing a new row.
                        Text(pair.relative)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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
                            .fill(negativeSpaceColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                                    .stroke(fillColor.opacity(0.22), lineWidth: 1.5)
                            )

                        GeometryReader { geo in
                            let fillWidth = max(geo.size.width - 4, 0) * remainingFraction
                            RoundedRectangle(cornerRadius: batteryRadius - 1.5, style: .continuous)
                                .fill(fillGradient)
                                .frame(width: remainingFraction > 0 ? fillWidth : 0)
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

                // Reset row: lifts `bucket.resetsAt` into a dedicated line in
                // the details sheet so 5h and weekly windows tell the user
                // when they refill, not just how full they are. Compact mode
                // squeezes only the relative half into the identity row's
                // window pill area (see above).
                if !compact, let pair = bucket.resetsAtDisplay {
                    HStack(spacing: 4) {
                        Text("Resets")
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        Text(pair.relative)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary.opacity(0.86))
                        Text("·")
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        Text(pair.absolute)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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

    /// What kind of value this bucket carries — drives label formatting.
    /// Falls back to `.count` so existing buckets without a `meta["unit"]`
    /// keep their previous decimal rendering.
    private enum BucketUnitKind {
        case currency
        case percent
        case tokens
        case unlimited
        case count

        init(metaValue: String?) {
            switch (metaValue ?? "").lowercased() {
            case "currency", "usd", "dollars", "$": self = .currency
            case "percent", "%": self = .percent
            case "tokens", "tok": self = .tokens
            case "unlimited": self = .unlimited
            default: self = .count
            }
        }
    }

    private var bucketUnit: BucketUnitKind {
        BucketUnitKind(metaValue: bucket.meta?["unit"])
    }

    private var remainingText: String {
        if bucketUnit == .unlimited { return "Unlimited" }
        return formatValue(bucket.remaining)
    }

    private var usageText: String {
        if bucketUnit == .unlimited { return "No fixed cap" }
        let used = formatValue(bucket.used)
        let limit = formatValue(bucket.limit)
        return "\(used) / \(limit)"
    }

    private func formatValue(_ value: Double) -> String {
        switch bucketUnit {
        case .currency:
            // USD with two decimals — handles "$0.39", "$3.61", "$1,250.00".
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencySymbol = "$"
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
        case .percent:
            let clamped = min(max(value, 0), 100)
            return "\(Int(clamped.rounded()))%"
        case .tokens:
            if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
            if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
            if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
            return "\(Int(value.rounded()))"
        case .unlimited:
            return "Unlimited"
        case .count:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        }
    }

    private var remainingPercentText: String {
        if bucketUnit == .unlimited { return "∞" }
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
