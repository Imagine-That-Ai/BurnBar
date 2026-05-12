import SwiftUI

// MARK: - Unified Design System
/// Cross-platform design tokens used by both macOS and iOS targets.
/// Replaces fragmented `DesignSystem` / `MobileTheme` duplicates.
public enum UnifiedDesignSystem {

    // MARK: - Colors
    public enum Colors {
        public static let ember   = Color(light: DesignSystemTokens.emberLight,   dark: DesignSystemTokens.emberDark)
        public static let amber   = Color(light: DesignSystemTokens.amberLight,   dark: DesignSystemTokens.amberDark)
        public static let blaze   = Color(light: DesignSystemTokens.blazeLight,   dark: DesignSystemTokens.blazeDark)
        public static let whimsy  = Color(light: DesignSystemTokens.whimsyLight,  dark: DesignSystemTokens.whimsyDark)

        public static let background      = Color(light: DesignSystemTokens.backgroundLight,      dark: DesignSystemTokens.backgroundDark)
        public static let surface         = Color(light: DesignSystemTokens.surfaceLight,         dark: DesignSystemTokens.surfaceDark)
        public static let surfaceElevated = Color(light: DesignSystemTokens.surfaceElevatedLight, dark: DesignSystemTokens.surfaceElevatedDark)
        public static let border          = Color(light: DesignSystemTokens.borderLight,          dark: DesignSystemTokens.borderDark)
        public static let borderSubtle    = Color(light: DesignSystemTokens.borderSubtleLight,    dark: DesignSystemTokens.borderSubtleDark)

        public static let textPrimary   = Color(light: DesignSystemTokens.textPrimaryLight,   dark: DesignSystemTokens.textPrimaryDark)
        public static let textSecondary = Color(light: DesignSystemTokens.textSecondaryLight, dark: DesignSystemTokens.textSecondaryDark)
        public static let textMuted     = Color(light: DesignSystemTokens.textMutedLight,     dark: DesignSystemTokens.textMutedDark)

        public static let success = Color(light: DesignSystemTokens.successLight, dark: DesignSystemTokens.successDark)
        public static let warning = Color(light: DesignSystemTokens.warningLight, dark: DesignSystemTokens.warningDark)
        public static let error   = Color(light: DesignSystemTokens.errorLight,   dark: DesignSystemTokens.errorDark)
        public static let accent  = ember

        public static let hermesMercury  = Color(light: DesignSystemTokens.hermesMercuryLight, dark: DesignSystemTokens.hermesMercuryDark)
        public static let hermesAureate  = Color(light: DesignSystemTokens.hermesAureateLight, dark: DesignSystemTokens.hermesAureateDark)

        public static let chatUserStroke      = Color(light: DesignSystemTokens.chatUserStrokeLight,      dark: DesignSystemTokens.chatUserStrokeDark)
        public static let chatAssistantStroke = Color(light: DesignSystemTokens.chatAssistantStrokeLight, dark: DesignSystemTokens.chatAssistantStrokeDark)

        // MARK: - Provider Colors
        public static func primary(for provider: AgentProvider) -> Color {
            DesignSystemColors.primary(for: provider)
        }

        public static func accent(for provider: AgentProvider) -> Color {
            DesignSystemColors.accent(for: provider)
        }

        public static func chartPalette(for provider: AgentProvider) -> [Color] {
            let p = primary(for: provider)
            let a = accent(for: provider)
            return [
                p,
                a,
                p.opacity(0.6),
                a.opacity(0.5),
            ]
        }

        public static func colorForModel(_ modelName: String) -> Color {
            DesignSystemColors.colorForModel(modelName)
        }
    }

    // MARK: - Typography
    public enum Typography {
        public static let displayLarge = Font.system(size: 36, weight: .bold, design: .rounded)
        public static let display      = Font.system(size: 28, weight: .bold, design: .rounded)
        public static let title        = Font.system(size: 20, weight: .semibold, design: .rounded)
        public static let headline     = Font.system(size: 16, weight: .semibold, design: .rounded)
        public static let body         = Font.system(size: 14, weight: .regular, design: .rounded)
        public static let caption      = Font.system(size: 12, weight: .medium, design: .rounded)
        public static let tiny         = Font.system(size: 11, weight: .medium, design: .rounded)

        public static let monoLarge = Font.system(size: 28, weight: .bold, design: .monospaced)
        public static let mono      = Font.system(size: 14, weight: .medium, design: .monospaced)
        public static let monoSmall = Font.system(size: 12, weight: .medium, design: .monospaced)
        public static let monoTiny  = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    // MARK: - Spacing
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Radius
    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 22
        public static let full: CGFloat = 9999
    }

    // MARK: - Animation
    public enum Animation {
        public static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.75)
        public static let gentle   = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.85)
        public static let snappy   = SwiftUI.Animation.easeOut(duration: 0.15)
        public static let hover    = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.8)

        public static let mercuryShimmer = SwiftUI.Animation.linear(duration: 3.0).repeatForever(autoreverses: false)
        public static let mercuryPulse   = SwiftUI.Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    }

    // MARK: - Gradients
    public static let primaryGradient = LinearGradient(
        colors: [Colors.ember, Colors.amber],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let accentGradient = LinearGradient(
        colors: [Colors.whimsy, Colors.ember],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let cardGradient = LinearGradient(
        colors: [
            Colors.ember.opacity(0.06),
            Colors.amber.opacity(0.04),
            Colors.blaze.opacity(0.03)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let whimsyGradient = LinearGradient(
        colors: [Colors.whimsy, Colors.whimsy.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let mercuryGradient = LinearGradient(
        colors: [Colors.hermesMercury, Colors.hermesAureate],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Pi runtime accent. Composed entirely from the existing `whimsy` brand
    /// token so we ship no new colour values — Plan 2's runtime pill, header
    /// glow, and message bubble strokes all key off this gradient.
    public static let piGradient = LinearGradient(
        colors: [Colors.whimsy, Colors.whimsy.opacity(0.65)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
