import SwiftUI
import OpenBurnBarCore

// MARK: - Cache Hit Rate Tier

/// Adaptive color band for a cache hit rate. Lets every surface render the
/// same metric with consistent semantic color so users can compare at a glance.
enum CacheHitRateTier {
    case strong        // ≥ 60%
    case healthy       // 30–60%
    case warming       // 5–30%
    case cold          // > 0–5%
    case noSignal      // no prompt-side data yet

    init(_ efficiency: CacheEfficiency) {
        guard let rate = efficiency.hitRate else {
            self = .noSignal
            return
        }
        switch rate {
        case 0.60...: self = .strong
        case 0.30..<0.60: self = .healthy
        case 0.05..<0.30: self = .warming
        case 0.0..<0.05 where rate > 0: self = .cold
        default: self = .noSignal
        }
    }

    var color: Color {
        switch self {
        case .strong: return DesignSystem.Colors.success
        case .healthy: return DesignSystem.Colors.amber
        case .warming: return DesignSystem.Colors.whimsy
        case .cold: return DesignSystem.Colors.textSecondary
        case .noSignal: return DesignSystem.Colors.textMuted
        }
    }

    var caption: String {
        switch self {
        case .strong: return "Strong reuse"
        case .healthy: return "Healthy reuse"
        case .warming: return "Warming up"
        case .cold: return "Low reuse"
        case .noSignal: return "No cache data"
        }
    }
}

// MARK: - CacheHitRateBadge

/// Compact, opinionated badge for a cache hit rate. Used inside provider/model
/// cards and detail headers. Renders a colored dot, the percentage, and a tiny
/// "cache" suffix so the number is always self-describing.
struct CacheHitRateBadge: View {
    let efficiency: CacheEfficiency
    var size: Size = .compact

    enum Size {
        case compact
        case prominent
    }

    private var tier: CacheHitRateTier { CacheHitRateTier(efficiency) }

    var body: some View {
        let color = tier.color
        HStack(spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: dotSize, height: dotSize)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.25), lineWidth: 1)
                        .scaleEffect(1.6)
                        .opacity(efficiency.hasSignal ? 1 : 0)
                )
            Text(efficiency.formattedHitRate)
                .font(valueFont)
                .foregroundStyle(color)
                .monospacedDigit()
            Text("cache")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)
                .kerning(0.4)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(color.opacity(efficiency.hasSignal ? 0.12 : 0.06))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(efficiency.hasSignal ? 0.30 : 0.18), lineWidth: 0.5)
        )
        .help(helpText)
    }

    private var dotSize: CGFloat {
        switch size {
        case .compact: return 6
        case .prominent: return 7
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact: return 3
        case .prominent: return 4
        }
    }

    private var valueFont: Font {
        switch size {
        case .compact: return DesignSystem.Typography.monoTiny
        case .prominent: return DesignSystem.Typography.monoSmall
        }
    }

    private var helpText: String {
        let read = efficiency.cacheReadTokens.formatAsTokens()
        let basis = efficiency.promptBasis.formatAsTokens()
        if efficiency.hasSignal {
            return "\(tier.caption) — \(read) of \(basis) prompt tokens served from cache."
        }
        return "No prompt cache data in this window yet."
    }
}

// MARK: - Cache Stat Tile

/// Hero-sized tile used in the dashboard overview to surface the window-wide
/// cache hit rate next to spend, tokens, and sessions. Mirrors `StatCard` shape.
struct CacheHitStatCard: View {
    let efficiency: CacheEfficiency

    private var tier: CacheHitRateTier { CacheHitRateTier(efficiency) }

    var body: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                Text("Cache Hit")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Text(efficiency.formattedHitRate)
                    .font(UnifiedDesignSystem.Typography.monoLarge)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tier.color, tier.color.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .contentTransition(.numericText())
                    .animation(UnifiedDesignSystem.Animation.gentle, value: efficiency.hitRate ?? -1)

                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    Circle()
                        .fill(tier.color)
                        .frame(width: 6, height: 6)
                    Text(tier.caption)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(tier.color)
                }

                Text(detail)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var detail: String {
        guard efficiency.hasSignal else {
            return "No prompt cache reads recorded yet for this window."
        }
        let read = efficiency.cacheReadTokens.formatAsTokens()
        let basis = efficiency.promptBasis.formatAsTokens()
        return "\(read) of \(basis) prompt tokens reused from cache."
    }
}
