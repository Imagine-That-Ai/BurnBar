import SwiftUI

struct ProviderQuotaBucketRow: View {
    let bucket: ProviderQuotaBucket
    let provider: AgentProvider

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var signalStatus: QuotaSignalStatus {
        QuotaSignalStatus.resolve(bucket: bucket, theme: theme)
    }
    private var windowBadgeText: String? {
        switch bucket.windowKind {
        case .rollingHours: return "Rolling hours"
        case .rollingDays: return "Rolling days"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .lifetime: return "Lifetime"
        case .custom: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(bucket.label)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        QuotaMicroBadge(text: signalStatus.label, tint: signalStatus.tint)

                        if let windowBadgeText {
                            QuotaMicroBadge(text: windowBadgeText, tint: theme.primaryColor)
                        }
                    }

                    Text(bucket.usageText)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                QuotaFigureTile(bucket: bucket, provider: provider)
            }

            QuotaSignalView(bucket: bucket, provider: provider)
                .frame(height: 104)

            HStack(spacing: DesignSystem.Spacing.sm) {
                if let pair = bucket.resetsAtDisplay {
                    // Combined "in 2h 14m · May 8, 3:35 AM" — the relative
                    // half answers "when do I get my budget back" at a
                    // glance, the absolute half pins it for far-future
                    // weekly windows where the relative read alone
                    // ("in 6 days") loses precision.
                    QuotaMicroBadge(
                        text: "Resets \(pair.relative) · \(pair.absolute)",
                        tint: DesignSystem.Colors.textMuted
                    )
                }

                PaceBadge(pace: bucket.idealPace())

                if bucket.isEstimated {
                    QuotaMicroBadge(text: "Estimated", tint: DesignSystem.Colors.warning)
                }

                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.48))

                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryColor.opacity(0.10),
                                theme.accentColor.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.12), lineWidth: 1)
        )
    }
}

struct QuotaFigureTile: View {
    let bucket: ProviderQuotaBucket
    let provider: AgentProvider

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var descriptor: String {
        switch bucket.unit {
        case .percent:
            return "window left"
        case .requests:
            return "requests left"
        case .tokens:
            return "tokens left"
        case .sessions:
            return "sessions left"
        case .lines:
            return "lines left"
        case .files:
            return "files left"
        case .count:
            return "remaining"
        case .currency:
            return "remaining"
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(descriptor.uppercased())
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(bucket.remainingText)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.gradient)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(bucket.usageText)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.16), lineWidth: 1)
        )
    }
}

struct QuotaStatusCallout: View {
    let provider: AgentProvider
    let title: String
    let message: String
    let isActive: Bool
    let isWarning: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var tint: Color { isWarning ? DesignSystem.Colors.warning : theme.primaryColor }
    private var iconName: String { isWarning ? "exclamationmark.triangle.fill" : "sparkles" }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 42, height: 42)

                if isActive {
                    AnimatedMiningPickView()
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            QuotaSignalPlaceholder(provider: provider, isActive: isActive, compact: true)
                .frame(width: 138, height: 76)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(tint.opacity(isWarning ? 0.24 : 0.14), lineWidth: 1)
        )
    }
}

struct ProviderQuotaIdentityOrb: View {
    let provider: AgentProvider
    let isActive: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.22),
                            theme.accentColor.opacity(0.12),
                            DesignSystem.Colors.surfaceElevated.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(theme.accentColor.opacity(isActive ? 0.22 : 0.12))
                .frame(width: 18, height: 18)
                .blur(radius: isActive ? 10 : 6)
                .offset(x: 10, y: -10)

            Circle()
                .stroke(theme.primaryColor.opacity(isActive ? 0.36 : 0.18), lineWidth: 1)

            ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
        }
        .frame(width: 42, height: 42)
        .shadow(color: theme.primaryColor.opacity(isActive ? 0.20 : 0.08), radius: isActive ? 18 : 8, y: 5)
        .overlay(alignment: .bottomTrailing) {
            if isActive {
                Circle()
                    .fill(DesignSystem.Colors.amber)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(DesignSystem.Colors.surface, lineWidth: 1.5)
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.gentle, value: isActive)
    }
}

struct ProviderQuotaActivityBadge: View {
    let provider: AgentProvider
    var compact = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        HStack(spacing: compact ? 6 : DesignSystem.Spacing.sm) {
            AnimatedMiningPickView()
                .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                .clipShape(.circle)

            if !compact {
                Text("At work")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(theme.gradient)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.16),
                            theme.accentColor.opacity(0.10)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(theme.primaryColor.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) quota refresh in progress")
    }
}

struct QuotaSignalStatus {
    let label: String
    let detail: String
    let tint: Color

    static func resolve(bucket: ProviderQuotaBucket, theme: ProviderTheme) -> QuotaSignalStatus {
        let pressure = min(max(bucket.progressFraction, 0), 1)

        switch pressure {
        case ..<0.20:
            return QuotaSignalStatus(
                label: "Wide Open",
                detail: "Plenty of headroom in this window.",
                tint: theme.primaryColor
            )
        case ..<0.46:
            return QuotaSignalStatus(
                label: "Comfortable",
                detail: "Healthy reserve remains.",
                tint: theme.accentColor
            )
        case ..<0.74:
            return QuotaSignalStatus(
                label: "Narrowing",
                detail: "Reserve is thinning.",
                tint: DesignSystem.Colors.amber
            )
        default:
            return QuotaSignalStatus(
                label: "Near Edge",
                detail: "Close to the active cap.",
                tint: DesignSystem.Colors.warning
            )
        }
    }
}

struct QuotaSignalView: View {
    let bucket: ProviderQuotaBucket
    let provider: AgentProvider
    var compact = false

    @Environment(\.colorScheme) private var colorScheme

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var remainingFraction: Double {
        if let remainingPercent = bucket.remainingPercent {
            return min(max(remainingPercent / 100, 0), 1)
        }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }
    private var signalStatus: QuotaSignalStatus {
        QuotaSignalStatus.resolve(bucket: bucket, theme: theme)
    }

    private var fillColor: Color {
        switch remainingFraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.72)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    private var fillGradient: LinearGradient {
        switch remainingFraction {
        case 0.75...:
            return LinearGradient(
                colors: [theme.primaryColor, theme.accentColor],
                startPoint: .leading,
                endPoint: .trailing
            )
        case 0.50..<0.75:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.72), theme.accentColor.opacity(0.56)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case 0.25..<0.50:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.48), DesignSystem.Colors.amber],
                startPoint: .leading,
                endPoint: .trailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.warning],
                startPoint: .leading,
                endPoint: .trailing
            )
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.surface.opacity(0.96),
                            DesignSystem.Colors.surfaceElevated.opacity(0.92),
                            theme.primaryColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text(signalStatus.label.uppercased())
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(signalStatus.tint.opacity(0.86))

                    if compact {
                        Spacer()
                        Text(bucket.remainingText)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(fillColor)
                    }
                }

                if !compact {
                    Text(signalStatus.detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.82))
                }

                // Battery bar
                HStack(spacing: 0) {
                    // Battery body
                    ZStack(alignment: .leading) {
                        // Track (empty shell)
                        RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                            .fill(negativeSpaceColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                                    .stroke(fillColor.opacity(0.22), lineWidth: 1.5)
                            )

                        // Fill bar
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

                    // Terminal nub
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fillColor.opacity(0.32))
                        .frame(width: terminalWidth, height: terminalHeight)
                        .padding(.leading, 2)
                }

                if !compact {
                    HStack {
                        Text(bucket.remainingText + " remaining")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(fillColor)

                        Spacer()

                        Text(bucket.usageText)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            .padding(compact ? 10 : 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.primaryColor.opacity(compact ? 0.14 : 0.18), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) quota: \(bucket.remainingText) remaining")
    }
}

struct QuotaSignalPlaceholder: View {
    let provider: AgentProvider
    let isActive: Bool
    var compact = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var cornerRadius: CGFloat { compact ? 14 : 16 }
    private var batteryHeight: CGFloat { compact ? 28 : 36 }
    private var batteryRadius: CGFloat { compact ? 6 : 8 }
    private var terminalWidth: CGFloat { compact ? 4 : 5 }
    private var terminalHeight: CGFloat { batteryHeight * 0.38 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.surface.opacity(0.95),
                            DesignSystem.Colors.surfaceElevated.opacity(0.90),
                            theme.primaryColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text(isActive ? "REFRESHING" : "NO SIGNAL YET")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                if !compact {
                    Text(isActive ? "Provider at work" : "Waiting for quota data")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                // Empty battery shell
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                                .stroke(
                                    theme.primaryColor.opacity(isActive ? 0.22 : 0.12),
                                    style: StrokeStyle(lineWidth: 1.5, dash: isActive ? [4, 4] : [])
                                )
                        )
                        .frame(height: batteryHeight)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.primaryColor.opacity(0.14))
                        .frame(width: terminalWidth, height: terminalHeight)
                        .padding(.leading, 2)
                }
            }
            .padding(compact ? 10 : 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.14), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}
