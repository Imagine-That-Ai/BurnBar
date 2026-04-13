import SwiftUI

// MARK: - Design System

/// Unified design tokens for OpenBurnBar.
/// Warm glassmorphic aesthetic: botanical cream (light) / bark (dark)
/// with ember, amber, blaze, and whimsy accents.
enum DesignSystem {

    // MARK: - Colors

    enum Colors {
        // Brand accents — warm spectrum + whimsy contrast
        static let ember   = Color.adaptive(light: "F45B69", dark: "FA5053")
        /// Light: tangerine; dark: amber.
        static let amber   = Color.adaptive(light: "F28C38", dark: "FFA800")
        /// Light: Spanish orange; dark: blaze.
        static let blaze   = Color.adaptive(light: "E86100", dark: "E86100")
        static let whimsy  = Color.adaptive(light: "6A5ACD", dark: "8B7FE8")

        // Legacy aliases (keeps ProviderTheme and other references compiling)
        static let coral  = ember
        static let purple = whimsy
        static let teal   = whimsy
        static let gold   = amber

        // Surfaces — light: coral + tangerine dust (ember / Spanish orange cast); dark: bark
        static let background      = Color.adaptive(light: "F3E8E6", dark: "151210")
        static let surface         = Color.adaptive(light: "FAF5F2", dark: "1D1914")
        static let surfaceElevated = Color.adaptive(light: "FDF8F5", dark: "282220")
        static let border          = Color.adaptive(light: "E8BFB5", dark: "3D342A")
        static let borderSubtle    = Color.adaptive(light: "F2E0DA", dark: "2D261F")

        // Text — light: warm brown with coral undertone / dark: warm off-white
        static let textPrimary   = Color.adaptive(light: "2A1816", dark: "F2EBE0")
        static let textSecondary = Color.adaptive(light: "6E4E48", dark: "A89A8A")
        static let textMuted     = Color.adaptive(light: "9A756D", dark: "7A6E62")

        // Semantic
        static let success = Color.adaptive(light: "3A7835", dark: "38D898")
        static let warning = Color.adaptive(light: "C47800", dark: "FFA800")
        static let error   = Color.adaptive(light: "D43030", dark: "FA5053")

        // Hermes mercury identity (chat surfaces — not provider purple)
        static let hermesMercury  = Color.adaptive(light: "AEA69C", dark: "C8BFB5")
        static let hermesAureate  = Color.adaptive(light: "B8942E", dark: "D4AA3C")

        static let mercuryGradient = LinearGradient(
            colors: [hermesMercury, hermesAureate],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

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
            case .cline: return Color(hex: "D4A373")
            case .kiloCode: return Color(hex: "10B981")
            case .rooCode: return Color(hex: "EC4899")
            case .forgeDev: return Color(hex: "F97316")
            case .augment: return Color(hex: "3B82F6")
            case .hermes: return Color(hex: "A855F7")
            case .geminiCLI: return Color(hex: "4285F4")
            case .goose: return Color(hex: "0D9488")
            case .openClaw: return Color(hex: "FF6B6B")
            case .windsurf: return Color(hex: "06B6D4")
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
            case .cline: return Color(hex: "E8C4A0")
            case .kiloCode: return Color(hex: "34D399")
            case .rooCode: return Color(hex: "F472B6")
            case .forgeDev: return Color(hex: "FB923C")
            case .augment: return Color(hex: "60A5FA")
            case .hermes: return Color(hex: "C084FC")
            case .geminiCLI: return Color(hex: "8AB4F8")
            case .goose: return Color(hex: "2DD4BF")
            case .openClaw: return Color(hex: "F472B6")
            case .windsurf: return Color(hex: "22D3EE")
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
            case .cline: return [Color(hex: "D4A373"), Color(hex: "E8C4A0"), Color(hex: "C08B5C"), Color(hex: "A67B5B")]
            case .kiloCode: return [Color(hex: "10B981"), Color(hex: "34D399"), Color(hex: "059669"), Color(hex: "6EE7B7")]
            case .rooCode: return [Color(hex: "EC4899"), Color(hex: "F472B6"), Color(hex: "DB2777"), Color(hex: "F9A8D4")]
            case .forgeDev: return [Color(hex: "F97316"), Color(hex: "FB923C"), Color(hex: "EA580C"), Color(hex: "FDBA74")]
            case .augment: return [Color(hex: "3B82F6"), Color(hex: "60A5FA"), Color(hex: "2563EB"), Color(hex: "93C5FD")]
            case .hermes: return [Color(hex: "A855F7"), Color(hex: "C084FC"), Color(hex: "9333EA"), Color(hex: "D8B4FE")]
            case .geminiCLI: return [Color(hex: "4285F4"), Color(hex: "8AB4F8"), Color(hex: "1A73E8"), Color(hex: "669DF6")]
            case .goose: return [Color(hex: "0D9488"), Color(hex: "2DD4BF"), Color(hex: "0F766E"), Color(hex: "5EEAD4")]
            case .openClaw: return [Color(hex: "FF6B6B"), Color(hex: "F472B6"), Color(hex: "F9A8D4"), Color(hex: "FBBF24")]
            case .windsurf: return [Color(hex: "06B6D4"), Color(hex: "22D3EE"), Color(hex: "0891B2"), Color(hex: "67E8F9")]
            }
        }

        // MARK: - Model Colors

        /// Deterministic color for a model name. Known families get brand colors; others hash into a palette.
        static func colorForModel(_ modelName: String) -> Color {
            let brand = LLMModelBrand.infer(fromModelKey: modelName)
            if brand != .unknown { return brand.emblemColor }

            let key = modelName.lowercased()
            // Deterministic hash for unknown models
            let palette: [Color] = [
                Color(hex: "D4A373"), Color(hex: "10B981"), Color(hex: "EC4899"),
                Color(hex: "F97316"), Color(hex: "3B82F6"), Color(hex: "A855F7"),
                Color(hex: "EF4444"), Color(hex: "14B8A6"), Color(hex: "F59E0B"),
                Color(hex: "8B5CF6"), Color(hex: "06B6D4"), Color(hex: "84CC16"),
            ]
            let hash = abs(key.hashValue)
            return palette[hash % palette.count]
        }

        static func gradientForModel(_ modelName: String) -> LinearGradient {
            let primary = colorForModel(modelName)
            return LinearGradient(
                colors: [primary, primary.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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

        // Hermes mercury motion
        static let mercuryShimmer = SwiftUI.Animation.linear(duration: 3.0).repeatForever(autoreverses: false)
        static let mercuryPulse = SwiftUI.Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    }
}
