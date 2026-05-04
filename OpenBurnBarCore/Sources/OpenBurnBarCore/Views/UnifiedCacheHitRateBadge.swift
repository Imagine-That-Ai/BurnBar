import SwiftUI

// NOTE: CacheEfficiency lives in AgentLens/Models/AgentProvider.swift for the macOS target.
// The OpenBurnBarCore version below is the canonical cross-platform definition.
// Once AgentLens migrates its types to OpenBurnBarCore, the local duplicate can be removed.

// MARK: - Cache Efficiency (cross-platform canonical)
public struct CacheEfficiency: Hashable, Sendable {
    public let inputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public var promptBasis: Int { max(0, inputTokens) + max(0, cacheCreationTokens) + max(0, cacheReadTokens) }
    public var hasSignal: Bool { promptBasis > 0 }

    public var hitRate: Double? {
        let basis = promptBasis
        guard basis > 0 else { return nil }
        return Double(max(0, cacheReadTokens)) / Double(basis)
    }

    public var formattedHitRate: String {
        hitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    public static let zero = CacheEfficiency(inputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)

    public init(inputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) {
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

// MARK: - Badge

/// Cross-platform cache hit rate badge with tiered coloring.
public struct UnifiedCacheHitRateBadge: View {
    public let efficiency: CacheEfficiency

    public init(efficiency: CacheEfficiency) {
        self.efficiency = efficiency
    }

    private var tier: CacheHitRateTier {
        CacheHitRateTier(efficiency)
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tier.iconName)
                .font(.system(size: 9, weight: .semibold))
            Text(efficiency.formattedHitRate)
                .font(UnifiedDesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tier.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tier.color.opacity(0.10))
        .overlay(
            Capsule()
                .stroke(tier.color.opacity(0.18), lineWidth: 1)
        )
        .clipShape(Capsule())
        .accessibilityLabel("Cache hit rate \(efficiency.formattedHitRate)")
    }
}

// MARK: - Tier

public struct CacheHitRateTier {
    public let color: Color
    public let iconName: String

    public init(_ efficiency: CacheEfficiency) {
        guard let rate = efficiency.hitRate else {
            self.color = UnifiedDesignSystem.Colors.textMuted
            self.iconName = "minus.circle"
            return
        }
        switch rate {
        case 0.30...:
            self.color = UnifiedDesignSystem.Colors.success
            self.iconName = "bolt.fill"
        case 0.10..<0.30:
            self.color = UnifiedDesignSystem.Colors.amber
            self.iconName = "bolt"
        default:
            self.color = UnifiedDesignSystem.Colors.textMuted
            self.iconName = "bolt.slash"
        }
    }
}
