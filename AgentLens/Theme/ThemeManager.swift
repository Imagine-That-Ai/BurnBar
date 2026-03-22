import SwiftUI
import Combine

@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()
    
    // MARK: - App Color Palette (User's Brand)
    
    struct AppColors {
        static let coral = Color(hex: "F45B69")
        static let purple = Color(hex: "8080FF")
        static let teal = Color(hex: "028090")
        static let botanicalCream = Color(hex: "FDF6EC")
        static let darkBackground = Color(hex: "0D1117")
        static let cardBackground = Color(hex: "161B22")
        static let border = Color(hex: "30363D")
        static let textPrimary = Color.white
        static let textSecondary = Color(hex: "8B949E")
        static let textMuted = Color(hex: "6E7681")
    }
    
    // MARK: - App Gradients
    
    struct AppGradients {
        static let primary = LinearGradient(
            colors: [AppColors.coral, AppColors.purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        static let accent = LinearGradient(
            colors: [AppColors.teal, AppColors.purple],
            startPoint: .leading,
            endPoint: .trailing
        )
        
        static let cardGlow = LinearGradient(
            colors: [
                AppColors.coral.opacity(0.15),
                AppColors.purple.opacity(0.15),
                AppColors.teal.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        static let menuBarGlow = RadialGradient(
            colors: [
                AppColors.coral.opacity(0.3),
                AppColors.purple.opacity(0.2),
                .clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: 50
        )
    }
    
    // MARK: - Typography
    
    struct Typography {
        static let display = Font.system(size: 32, weight: .bold, design: .rounded)
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 14, weight: .regular, design: .rounded)
        static let caption = Font.system(size: 12, weight: .medium, design: .rounded)
        static let monoDisplay = Font.system(size: 28, weight: .bold, design: .monospaced)
        static let monoBody = Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoCaption = Font.system(size: 11, weight: .medium, design: .monospaced)
    }
    
    // MARK: - Spacing
    
    struct Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
    
    // MARK: - Corner Radius
    
    struct CornerRadius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let full: CGFloat = .infinity
    }
    
    // MARK: - Shadows
    
    struct Shadows {
        static let subtle = Color.black.opacity(0.1)
        static let medium = Color.black.opacity(0.2)
        static let strong = Color.black.opacity(0.3)
        
        static func card(theme: ProviderTheme) -> some View {
            Rectangle()
                .fill(theme.secondaryBackgroundColor)
                .shadow(color: subtle, radius: 2, x: 0, y: 1)
        }
    }
    
    // MARK: - Animation
    
    struct Animation {
        static let standard = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.7)
        static let gentle = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.8)
        static let bouncy = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.6)
        static let quick = SwiftUI.Animation.easeOut(duration: 0.15)
    }
    
    // MARK: - Chart Colors
    
    static let chartPalette: [Color] = [
        AppColors.coral,
        AppColors.purple,
        AppColors.teal,
        Color(hex: "FBBF24"), // Gold accent
        Color(hex: "34D399"), // Green
        Color(hex: "F472B6"), // Pink
    ]
    
    static func chartColor(for index: Int) -> Color {
        chartPalette[index % chartPalette.count]
    }
}
