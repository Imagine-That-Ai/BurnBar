import SwiftUI

// MARK: - Provider Theme

struct ProviderTheme {
    let provider: AgentProvider
    let primaryColor: Color
    let accentColor: Color
    let backgroundColor: Color
    let secondaryBackgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color
    let gradient: LinearGradient
    let chartColors: [Color]
    
    // MARK: - App Brand Colors (User specified)
    
    /// Coral/Rose - Primary accent
    static let coral = Color(hex: "F45B69")
    
    /// Purple/Blue - Secondary
    static let purple = Color(hex: "8080FF")
    
    /// Teal - Accent
    static let teal = Color(hex: "028090")
    
    /// Botanical Cream - Warm cream background
    static let botanicalCream = Color(hex: "FDF6EC")
    
    /// Dark background for terminal aesthetic
    static let darkBackground = Color(hex: "0D1117")
    
    /// Card background dark
    static let darkCard = Color(hex: "161B22")
    
    // MARK: - Provider Themes
    
    static func theme(for provider: AgentProvider) -> ProviderTheme {
        switch provider {
        case .factory:
            return ProviderTheme(
                provider: .factory,
                primaryColor: purple,
                accentColor: coral,
                backgroundColor: darkBackground,
                secondaryBackgroundColor: darkCard,
                textColor: .white,
                secondaryTextColor: Color(hex: "8B949E"),
                gradient: LinearGradient(
                    colors: [purple, Color(hex: "6366F1")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                chartColors: [purple, coral, teal, Color(hex: "A78BFA")]
            )
            
        case .claudeCode:
            return ProviderTheme(
                provider: .claudeCode,
                primaryColor: Color(hex: "CC785C"), // Anthropic terracotta
                accentColor: Color(hex: "D4A574"),
                backgroundColor: botanicalCream,
                secondaryBackgroundColor: Color(hex: "F5EDE0"),
                textColor: Color(hex: "1F1F1F"),
                secondaryTextColor: Color(hex: "6B6B6B"),
                gradient: LinearGradient(
                    colors: [Color(hex: "CC785C"), Color(hex: "D4A574")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                chartColors: [Color(hex: "CC785C"), coral, teal, Color(hex: "E8C4A0")]
            )
            
        case .copilot:
            return ProviderTheme(
                provider: .copilot,
                primaryColor: Color(hex: "23EA3B"), // GitHub neon green
                accentColor: Color(hex: "0969DA"), // GitHub blue
                backgroundColor: Color(hex: "0D1117"),
                secondaryBackgroundColor: Color(hex: "161B22"),
                textColor: .white,
                secondaryTextColor: Color(hex: "8B949E"),
                gradient: LinearGradient(
                    colors: [Color(hex: "23EA3B"), Color(hex: "2EA043")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                chartColors: [Color(hex: "23EA3B"), Color(hex: "0969DA"), coral, purple]
            )
            
        case .aider:
            return ProviderTheme(
                provider: .aider,
                primaryColor: Color(hex: "FF6B35"),
                accentColor: Color(hex: "1E1E1E"),
                backgroundColor: Color(hex: "1A1A2E"),
                secondaryBackgroundColor: Color(hex: "16213E"),
                textColor: .white,
                secondaryTextColor: Color(hex: "A0A0A0"),
                gradient: LinearGradient(
                    colors: [Color(hex: "FF6B35"), Color(hex: "FF8C61")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                chartColors: [Color(hex: "FF6B35"), teal, coral, purple]
            )
            
        case .cursor:
            return ProviderTheme(
                provider: .cursor,
                primaryColor: Color(hex: "AC8C57"), // Cursor gold
                accentColor: Color(hex: "007AFF"),
                backgroundColor: Color(hex: "0A0E27"), // Deep navy
                secondaryBackgroundColor: Color(hex: "111530"),
                textColor: .white,
                secondaryTextColor: Color(hex: "8B949E"),
                gradient: LinearGradient(
                    colors: [Color(hex: "AC8C57"), Color(hex: "D4A574")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                chartColors: [Color(hex: "AC8C57"), Color(hex: "007AFF"), teal, coral]
            )
        }
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
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
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
