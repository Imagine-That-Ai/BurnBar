import SwiftUI

// MARK: - Design System

/// Unified design tokens for BurnBar.
/// Warm glassmorphic aesthetic: botanical cream (light) / bark (dark)
/// with ember, amber, blaze, and whimsy accents.
enum DesignSystem {

    // MARK: - Colors

    enum Colors {
        // Brand accents — warm spectrum + whimsy contrast
        static let ember   = Color.adaptive(light: "F45B69", dark: "FA5053")
        static let amber   = Color.adaptive(light: "D49000", dark: "FFA800")
        static let blaze   = Color.adaptive(light: "D45800", dark: "E86100")
        static let whimsy  = Color.adaptive(light: "6A5ACD", dark: "8B7FE8")

        // Legacy aliases (keeps ProviderTheme and other references compiling)
        static let coral  = ember
        static let purple = whimsy
        static let teal   = whimsy
        static let gold   = amber

        // Surfaces — botanical cream light / bark dark
        static let background      = Color.adaptive(light: "F5F0E6", dark: "151210")
        static let surface         = Color.adaptive(light: "FAF7F0", dark: "1D1914")
        static let surfaceElevated = Color.adaptive(light: "FFFCF5", dark: "282220")
        static let border          = Color.adaptive(light: "D9CDBA", dark: "3D342A")
        static let borderSubtle    = Color.adaptive(light: "E8DFD0", dark: "2D261F")

        // Text — warm brown light / warm off-white dark
        static let textPrimary   = Color.adaptive(light: "2A1F14", dark: "F2EBE0")
        static let textSecondary = Color.adaptive(light: "6B5D4E", dark: "A89A8A")
        static let textMuted     = Color.adaptive(light: "9A8B7A", dark: "7A6E62")

        // Semantic
        static let success = Color.adaptive(light: "3A7835", dark: "38D898")
        static let warning = Color.adaptive(light: "C47800", dark: "FFA800")
        static let error   = Color.adaptive(light: "D43030", dark: "FA5053")

        /// Chat bubbles: user outline (whimsy) / assistant accent (ember).
        static let chatUserStroke = Color(hex: "6A5ACD")
        static let chatAssistantStroke = Color(hex: "F45B69")

        static let primaryGradient = LinearGradient(
            colors: [ember, amber],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let accentGradient = LinearGradient(
            colors: [whimsy, ember],
            startPoint: .leading,
            endPoint: .trailing
        )

        static let cardGradient = LinearGradient(
            colors: [
                ember.opacity(0.06),
                amber.opacity(0.04),
                blaze.opacity(0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Whimsy gradient for "Cool down" states and contrast moments.
        static let whimsyGradient = LinearGradient(
            colors: [whimsy, whimsy.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static func primary(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory: return whimsy
            case .claudeCode: return Color(hex: "CC785C")
            case .copilot: return Color(hex: "23EA3B")
            case .aider: return Color(hex: "FF6B35")
            case .cursor: return Color(hex: "AC8C57")
            case .codex: return Color(hex: "00A67E")
            case .zai: return Color(hex: "8B5CF6")
            case .minimax: return Color(hex: "F59E0B")
            case .kimi: return Color(hex: "6366F1")
            }
        }

        static func accent(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory: return ember
            case .claudeCode: return Color(hex: "D4A574")
            case .copilot: return Color(hex: "0969DA")
            case .aider: return blaze
            case .cursor: return Color(hex: "007AFF")
            case .codex: return Color(hex: "00C48C")
            case .zai: return Color(hex: "A78BFA")
            case .minimax: return Color(hex: "FCD34D")
            case .kimi: return Color(hex: "818CF8")
            }
        }

        static func chartPalette(for provider: AgentProvider) -> [Color] {
            switch provider {
            case .factory: return [whimsy, ember, amber, Color(hex: "A78BFA")]
            case .claudeCode: return [Color(hex: "CC785C"), Color(hex: "D4A574"), Color(hex: "8B949E"), Color(hex: "E8C4A0")]
            case .copilot: return [Color(hex: "23EA3B"), Color(hex: "0969DA"), ember, whimsy]
            case .aider: return [Color(hex: "FF6B35"), blaze, ember, whimsy]
            case .cursor: return [Color(hex: "AC8C57"), Color(hex: "007AFF"), amber, ember]
            case .codex: return [Color(hex: "00A67E"), Color(hex: "00C48C"), Color(hex: "7FDBDA"), Color(hex: "66CDAA")]
            case .zai: return [Color(hex: "8B5CF6"), Color(hex: "A78BFA"), Color(hex: "6366F1"), Color(hex: "7C3AED")]
            case .minimax: return [Color(hex: "F59E0B"), Color(hex: "FCD34D"), Color(hex: "D97706"), Color(hex: "FBBF24")]
            case .kimi: return [Color(hex: "6366F1"), Color(hex: "818CF8"), Color(hex: "A5B4FC"), Color(hex: "C7D2FE")]
            }
        }
    }

    // MARK: - Typography

    enum Typography {
        static let displayLarge = Font.system(size: 36, weight: .bold, design: .rounded)
        static let display = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 14, weight: .regular, design: .rounded)
        static let caption = Font.system(size: 12, weight: .medium, design: .rounded)
        static let tiny = Font.system(size: 11, weight: .medium, design: .rounded)

        static let monoLarge = Font.system(size: 28, weight: .bold, design: .monospaced)
        static let mono = Font.system(size: 14, weight: .medium, design: .monospaced)
        static let monoSmall = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let monoTiny = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Corner Radius

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let full: CGFloat = 9999
    }

    // MARK: - Animation

    enum Animation {
        static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.75)
        static let gentle = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.85)
        static let snappy = SwiftUI.Animation.easeOut(duration: 0.15)
        static let hover = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.8)
    }
}
