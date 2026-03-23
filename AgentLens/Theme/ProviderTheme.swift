import SwiftUI

/// Provider-specific theme tokens backed by the DesignSystem palette.
/// All providers use a unified dark glass aesthetic for visual consistency.
struct ProviderTheme {
    let provider: AgentProvider
    let primaryColor: Color
    let accentColor: Color
    let textColor: Color
    let secondaryTextColor: Color
    let chartColors: [Color]
    let gradient: LinearGradient

    // MARK: - Unified Dark Glass Surfaces (all providers share)

    static let background = DesignSystem.Colors.background
    static let surface = DesignSystem.Colors.surface
    static let surfaceElevated = DesignSystem.Colors.surfaceElevated
    static let border = DesignSystem.Colors.border

    var secondaryBackgroundColor: Color { Self.surface }
    var backgroundColor: Color { Self.background }

    // MARK: - Provider Themes

    static func theme(for provider: AgentProvider) -> ProviderTheme {
        let primary = DesignSystem.Colors.primary(for: provider)
        let accent = DesignSystem.Colors.accent(for: provider)
        let chartPalette = DesignSystem.Colors.chartPalette(for: provider)

        return ProviderTheme(
            provider: provider,
            primaryColor: primary,
            accentColor: accent,
            textColor: DesignSystem.Colors.textPrimary,
            secondaryTextColor: DesignSystem.Colors.textSecondary,
            chartColors: chartPalette,
            gradient: LinearGradient(
                colors: [primary, accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Model Themes

    static func theme(forModel modelName: String) -> ProviderTheme {
        let primary = DesignSystem.Colors.colorForModel(modelName)
        let accent = primary.opacity(0.7)
        let chartColors = [primary, primary.opacity(0.7), primary.opacity(0.5), primary.opacity(0.3)]

        return ProviderTheme(
            provider: .claudeCode, // placeholder — views use primaryColor, not provider
            primaryColor: primary,
            accentColor: accent,
            textColor: DesignSystem.Colors.textPrimary,
            secondaryTextColor: DesignSystem.Colors.textSecondary,
            chartColors: chartColors,
            gradient: LinearGradient(
                colors: [primary, accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Theme Environment Key

private struct ProviderThemeKey: EnvironmentKey {
    static let defaultValue: ProviderTheme = .theme(for: .factory)
}

extension EnvironmentValues {
    var providerTheme: ProviderTheme {
        get { self[ProviderThemeKey.self] }
        set { self[ProviderThemeKey.self] = newValue }
    }
}

extension View {
    func providerTheme(_ theme: ProviderTheme) -> some View {
        environment(\.providerTheme, theme)
    }
}
