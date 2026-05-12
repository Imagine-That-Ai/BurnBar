import SwiftUI

// MARK: - Design System

/// Unified design tokens for OpenBurnBar.
/// Light: warm botanical cream. Dark: cool slate blue (GitHub/Xcode dark lineage)
/// — cool blue-tinted neutrals make ember, amber, blaze, and whimsy accents glow.
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

        // Surfaces — light: coral + tangerine dust (ember / Spanish orange cast);
        // dark: cool slate blue ramp (GitHub/Xcode dark lineage) — warm accents pop on cool chrome.
        static let background      = Color.adaptive(light: "F3E8E6", dark: "0D1117")
        static let surface         = Color.adaptive(light: "FAF5F2", dark: "161B22")
        static let surfaceElevated = Color.adaptive(light: "FDF8F5", dark: "1F2630")
        static let border          = Color.adaptive(light: "E8BFB5", dark: "30363D")
        static let borderSubtle    = Color.adaptive(light: "F2E0DA", dark: "21262D")

        // Text — light: warm brown with coral undertone / dark: cool slate off-white
        static let textPrimary   = Color.adaptive(light: "2A1816", dark: "E6EDF3")
        static let textSecondary = Color.adaptive(light: "6E4E48", dark: "8B949E")
        static let textMuted     = Color.adaptive(light: "9A756D", dark: "6E7681")

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

        /// Pi runtime accent gradient. Mirrors `UnifiedDesignSystem.piGradient`
        /// and `MobileTheme.piGradient` so visuals stay 1:1 across platforms.
        static let piGradient = LinearGradient(
            colors: [whimsy, whimsy.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static func primary(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory:    return Color(hex: "8B5CF6")
            case .claudeCode: return Color(hex: "CC785C")
            case .copilot:    return Color(hex: "23EA3B")
            case .aider:      return Color(hex: "FF6B35")
            case .cursor:     return Color(hex: "AC8C57")
            case .openAI:     return Color(hex: "00A67E")
            case .codex:      return Color(hex: "00A67E")
            case .zai:        return Color(hex: "8B5CF6")
            case .minimax:    return Color(hex: "F59E0B")
            case .kimi:       return Color(hex: "6366F1")
            case .cline:      return Color(hex: "D4A373")
            case .kiloCode:   return Color(hex: "10B981")
            case .rooCode:    return Color(hex: "EC4899")
            case .forgeDev:   return Color(hex: "F97316")
            case .augment:    return Color(hex: "3B82F6")
            case .hermes:     return Color(hex: "A855F7")
            case .piAgent:    return Color(hex: "7C3AED")
            case .geminiCLI:  return Color(hex: "4285F4")
            case .goose:      return Color(hex: "0D9488")
            case .openClaw:   return Color(hex: "FF6B6B")
            case .ollama:     return Color(hex: "6B7280")
            case .windsurf:   return Color(hex: "06B6D4")
            case .warp:       return Color(hex: "DDE4EA")
            }
        }

        static func accent(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory:    return ember
            case .claudeCode: return Color(hex: "D4A574")
            case .copilot:    return Color(hex: "0969DA")
            case .aider:      return blaze
            case .cursor:     return Color(hex: "007AFF")
            case .openAI:     return Color(hex: "00C48C")
            case .codex:      return Color(hex: "00C48C")
            case .zai:        return Color(hex: "A78BFA")
            case .minimax:    return Color(hex: "FCD34D")
            case .kimi:       return Color(hex: "818CF8")
            case .cline:      return Color(hex: "E8C4A0")
            case .kiloCode:   return Color(hex: "34D399")
            case .rooCode:    return Color(hex: "F472B6")
            case .forgeDev:   return Color(hex: "FB923C")
            case .augment:    return Color(hex: "60A5FA")
            case .hermes:     return Color(hex: "C084FC")
            case .piAgent:    return Color(hex: "A78BFA")
            case .geminiCLI:  return Color(hex: "8AB4F8")
            case .goose:      return Color(hex: "2DD4BF")
            case .openClaw:   return Color(hex: "F472B6")
            case .ollama:     return Color(hex: "9CA3AF")
            case .windsurf:   return Color(hex: "22D3EE")
            case .warp:       return Color(hex: "111111")
            }
        }

        static func chartPalette(for provider: AgentProvider) -> [Color] {
            let p = primary(for: provider)
            let a = accent(for: provider)
            return [p, a, p.opacity(0.6), a.opacity(0.5)]
        }

        // MARK: - Model Colors

        /// Deterministic color for a model name. Known families get brand colors; others hash into a palette.
        static func colorForModel(_ modelName: String) -> Color {
            let key = modelName.lowercased()

            // Known brand colors — deterministic, human-meaningful mapping.
            if key.contains("claude") || key.contains("anthropic") {
                return Color(hex: "CC785C")
            }
            if key.contains("gpt") || key.contains("openai") || key.contains("chatgpt") {
                return Color(hex: "00A67E")
            }
            if key.contains("gemini") || key.contains("google") {
                return Color(hex: "4285F4")
            }
            if key.contains("deepseek") {
                return Color(hex: "6366F1")
            }
            if key.contains("kimi") || key.contains("moonshot") {
                return Color(hex: "6366F1")
            }
            if key.contains("minimax") || key.contains("abab") {
                return Color(hex: "F59E0B")
            }
            if key.contains("llama") || key.contains("meta") {
                return Color(hex: "0668E1")
            }
            if key.contains("mistral") || key.contains("mixtral") {
                return Color(hex: "FF7000")
            }
            if key.contains("qwen") || key.contains("qwq") {
                return Color(hex: "615EFF")
            }
            if key.contains("grok") || key.contains("xai") {
                return Color(hex: "1A1A1A")
            }
            if key.contains("cohere") || key.contains("command") {
                return Color(hex: "39594D")
            }
            if key.contains("perplexity") || key.contains("sonar") {
                return Color(hex: "20808D")
            }
            if key.contains("mlx") || key.contains("apple") {
                return Color(hex: "A2AAAD")
            }
            if key.contains("nova") || key.contains("amazon") || key.contains("bedrock") {
                return Color(hex: "FF9900")
            }
            if key.contains("alibaba") || key.contains("tongyi") {
                return Color(hex: "FF6A00")
            }
            if key.contains("ollama") {
                return Color(hex: "8B8589")
            }

            // Deterministic fallback palette for unknown models.
            let palette: [Color] = [
                Color(hex: "D4A373"), Color(hex: "10B981"), Color(hex: "EC4899"),
                Color(hex: "F97316"), Color(hex: "3B82F6"), Color(hex: "A855F7"),
                Color(hex: "EF4444"), Color(hex: "14B8A6"), Color(hex: "F59E0B"),
                Color(hex: "8B5CF6"), Color(hex: "06B6D4"), Color(hex: "84CC16"),
            ]
            var hash = UInt64(5381)
            for byte in key.utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            return palette[Int(hash % UInt64(palette.count))]
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

    // MARK: - Shadows

    // Centralized elevation specs. Mirrors `AuroraShadows` on Android so ad-hoc
    // .shadow() calls migrate to a shared vocabulary and stay synced between
    // platforms.
    struct ShadowSpec {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadows {
        static let none      = ShadowSpec(color: .clear,                 radius: 0,  x: 0, y: 0)
        static let subtle    = ShadowSpec(color: Color.black.opacity(0.05), radius: 2,  x: 0, y: 1)
        static let small     = ShadowSpec(color: Color.black.opacity(0.10), radius: 4,  x: 0, y: 2)
        static let medium    = ShadowSpec(color: Color.black.opacity(0.12), radius: 8,  x: 0, y: 3)
        static let cardHover = ShadowSpec(color: Colors.ember.opacity(0.40), radius: 12, x: 0, y: 4)
        static let large     = ShadowSpec(color: Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
        static let fab       = ShadowSpec(color: Colors.amber.opacity(0.70), radius: 4,  x: 0, y: 2)
    }
}
