import SwiftUI

/// Cross-platform provider theme backed by unified design tokens.
public struct UnifiedProviderTheme {
    public let provider: AgentProvider
    public let primaryColor: Color
    public let accentColor: Color
    public let textColor: Color
    public let secondaryTextColor: Color
    public let chartColors: [Color]
    public let gradient: LinearGradient

    public var backgroundColor: Color { UnifiedDesignSystem.Colors.background }
    public var surfaceColor: Color { UnifiedDesignSystem.Colors.surface }
    public var surfaceElevatedColor: Color { UnifiedDesignSystem.Colors.surfaceElevated }
    public var borderColor: Color { UnifiedDesignSystem.Colors.border }

    public static func theme(for provider: AgentProvider) -> UnifiedProviderTheme {
        let primary = UnifiedDesignSystem.Colors.primary(for: provider)
        let accent = UnifiedDesignSystem.Colors.accent(for: provider)
        let chartPalette = UnifiedDesignSystem.Colors.chartPalette(for: provider)

        return UnifiedProviderTheme(
            provider: provider,
            primaryColor: primary,
            accentColor: accent,
            textColor: UnifiedDesignSystem.Colors.textPrimary,
            secondaryTextColor: UnifiedDesignSystem.Colors.textSecondary,
            chartColors: chartPalette,
            gradient: LinearGradient(
                colors: [primary, accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    public static func theme(forModel modelName: String) -> UnifiedProviderTheme {
        let primary = UnifiedDesignSystem.Colors.colorForModel(modelName)
        let accent = primary.opacity(0.7)
        let chartColors = [primary, primary.opacity(0.7), primary.opacity(0.5), primary.opacity(0.3)]

        return UnifiedProviderTheme(
            provider: .claudeCode,
            primaryColor: primary,
            accentColor: accent,
            textColor: UnifiedDesignSystem.Colors.textPrimary,
            secondaryTextColor: UnifiedDesignSystem.Colors.textSecondary,
            chartColors: chartColors,
            gradient: LinearGradient(
                colors: [primary, accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
