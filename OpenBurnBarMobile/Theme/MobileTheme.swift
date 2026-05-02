import SwiftUI
import OpenBurnBarCore

enum MobileTheme {
    // MARK: - Brand Accents
    static let ember   = Color.adaptive(light: "F45B69", dark: "FA5053")
    static let amber   = Color.adaptive(light: "F28C38", dark: "FFA800")
    static let blaze   = Color.adaptive(light: "E86100", dark: "E86100")
    static let whimsy  = Color.adaptive(light: "6A5ACD", dark: "8B7FE8")

    // MARK: - Surfaces
    static let background      = Color.adaptive(light: "F3E8E6", dark: "0D1117")
    static let surface         = Color.adaptive(light: "FAF5F2", dark: "161B22")
    static let surfaceElevated = Color.adaptive(light: "FDF8F5", dark: "1F2630")
    static let border          = Color.adaptive(light: "E8BFB5", dark: "30363D")
    static let borderSubtle    = Color.adaptive(light: "F2E0DA", dark: "21262D")

    // MARK: - Text
    static let textPrimary   = Color.adaptive(light: "2A1816", dark: "E6EDF3")
    static let textSecondary = Color.adaptive(light: "6E4E48", dark: "8B949E")
    static let textMuted     = Color.adaptive(light: "9A756D", dark: "6E7681")

    // MARK: - Semantic
    static let success = Color.adaptive(light: "3A7835", dark: "38D898")
    static let warning = Color.adaptive(light: "C47800", dark: "FFA800")
    static let error   = Color.adaptive(light: "D43030", dark: "FA5053")

    // MARK: - Hermes Mercury Identity
    static let hermesMercury  = Color.adaptive(light: "AEA69C", dark: "C8BFB5")
    static let hermesAureate  = Color.adaptive(light: "B8942E", dark: "D4AA3C")

    static let mercuryGradient = LinearGradient(
        colors: [hermesMercury, hermesAureate],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Chat Strokes
    static let chatUserStroke      = Color(hex: "6A5ACD")
    static let chatAssistantStroke = Color(hex: "F45B69")

    // MARK: - Gradients
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

    static let whimsyGradient = LinearGradient(
        colors: [whimsy, whimsy.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Spacing
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 16
    static let spacingLarge: CGFloat = 24
    static let cornerRadius: CGFloat = 16
    static let cornerRadiusSmall: CGFloat = 12

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let full: CGFloat = 9999
    }

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

    enum Typography {
        static let displayLarge = Font.system(size: 36, weight: .bold, design: .rounded)
        static let display    = Font.system(size: 32, weight: .bold,     design: .rounded)
        static let title      = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline   = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let body       = Font.system(size: 15, weight: .regular,  design: .rounded)
        static let footnote   = Font.system(size: 13, weight: .regular,  design: .rounded)
        static let caption    = Font.system(size: 12, weight: .medium,   design: .rounded)
        static let tiny       = Font.system(size: 11, weight: .medium,   design: .rounded)

        static let monoLarge = Font.system(size: 28, weight: .bold,     design: .monospaced)
        static let mono       = Font.system(size: 14, weight: .medium,   design: .monospaced)
        static let monoSmall  = Font.system(size: 12, weight: .medium,   design: .monospaced)
        static let monoTiny   = Font.system(size: 11, weight: .medium,   design: .monospaced)
    }

    // MARK: - Animation
    enum Animation {
        static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.75)
        static let gentle   = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.85)
        static let snappy   = SwiftUI.Animation.easeOut(duration: 0.15)
        static let hover    = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.8)

        static let mercuryShimmer = SwiftUI.Animation.linear(duration: 3.0).repeatForever(autoreverses: false)
        static let mercuryPulse   = SwiftUI.Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    }

    // MARK: - Colors Namespace
    enum Colors {
        static let background      = MobileTheme.background
        static let surface         = MobileTheme.surface
        static let surfaceElevated = MobileTheme.surfaceElevated
        static let border          = MobileTheme.border
        static let borderSubtle    = MobileTheme.borderSubtle

        static let textPrimary   = MobileTheme.textPrimary
        static let textSecondary = MobileTheme.textSecondary
        static let textMuted     = MobileTheme.textMuted

        static let success = MobileTheme.success
        static let warning = MobileTheme.warning
        static let error   = MobileTheme.error

        static let accent = MobileTheme.ember

        static let hermesMercury = MobileTheme.hermesMercury
        static let hermesAureate = MobileTheme.hermesAureate
        static let mercuryGradient = MobileTheme.mercuryGradient

        static let chatUserStroke = MobileTheme.chatUserStroke
        static let chatAssistantStroke = MobileTheme.chatAssistantStroke

        static let primaryGradient = MobileTheme.primaryGradient
        static let accentGradient  = MobileTheme.accentGradient
        static let cardGradient    = MobileTheme.cardGradient
        static let whimsyGradient  = MobileTheme.whimsyGradient

        static func primary(for provider: AgentProvider) -> Color {
            switch provider {
            case .claudeCode:  return MobileTheme.ember
            case .factory:     return MobileTheme.whimsy
            case .codex:       return Color(hex: "10A37F")
            case .cursor:      return Color(hex: "1DAAAF")
            case .kimi:        return Color(hex: "2CCAC0")
            case .minimax:     return Color(hex: "D49A3A")
            case .zai:         return Color(hex: "D49A3A")
            case .geminiCLI:   return Color(hex: "4285F4")
            case .copilot:     return Color(hex: "8E86D0")
            case .aider:       return Color(hex: "C8604E")
            case .cline:       return MobileTheme.amber
            case .kiloCode:    return MobileTheme.blaze
            case .rooCode:     return Color(hex: "9080D8")
            case .forgeDev:    return Color(hex: "C8604E")
            case .augment:     return Color(hex: "8E86D0")
            case .hermes:      return Color(hex: "C8BFB5")
            case .goose:       return Color(hex: "8E86D0")
            case .openClaw:    return Color(hex: "E87060")
            case .ollama:      return Color(hex: "8B8589")
            case .windsurf:    return Color(hex: "1DAAAF")
            case .warp:        return Color(hex: "E87060")
            }
        }

        static func accent(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory:     return MobileTheme.ember
            case .claudeCode:  return Color(hex: "D4A574")
            case .copilot:     return Color(hex: "0969DA")
            case .aider:       return MobileTheme.blaze
            case .cursor:      return Color(hex: "007AFF")
            case .codex:       return Color(hex: "00C48C")
            case .zai:         return Color(hex: "A78BFA")
            case .minimax:     return Color(hex: "FCD34D")
            case .kimi:        return Color(hex: "818CF8")
            case .cline:       return Color(hex: "E8C4A0")
            case .kiloCode:    return Color(hex: "34D399")
            case .rooCode:     return Color(hex: "F472B6")
            case .forgeDev:    return Color(hex: "FB923C")
            case .augment:     return Color(hex: "60A5FA")
            case .hermes:      return Color(hex: "C084FC")
            case .geminiCLI:   return Color(hex: "8AB4F8")
            case .goose:       return Color(hex: "2DD4BF")
            case .openClaw:    return Color(hex: "F472B6")
            case .ollama:      return Color(hex: "B8A9A0")
            case .windsurf:    return Color(hex: "22D3EE")
            case .warp:        return Color(hex: "FFD700")
            }
        }

        static func chartPalette(for provider: AgentProvider) -> [Color] {
            switch provider {
            case .factory:
                return [MobileTheme.whimsy, MobileTheme.ember, MobileTheme.amber, Color(hex: "A78BFA")]
            case .claudeCode:
                return [Color(hex: "CC785C"), Color(hex: "D4A574"), Color(hex: "8B949E"), Color(hex: "E8C4A0")]
            case .copilot:
                return [Color(hex: "23EA3B"), Color(hex: "0969DA"), MobileTheme.ember, MobileTheme.whimsy]
            case .aider:
                return [Color(hex: "FF6B35"), MobileTheme.blaze, MobileTheme.ember, MobileTheme.whimsy]
            case .cursor:
                return [Color(hex: "AC8C57"), Color(hex: "007AFF"), MobileTheme.amber, MobileTheme.ember]
            case .codex:
                return [Color(hex: "00A67E"), Color(hex: "00C48C"), Color(hex: "7FDBDA"), Color(hex: "66CDAA")]
            case .zai:
                return [Color(hex: "8B5CF6"), Color(hex: "A78BFA"), Color(hex: "6366F1"), Color(hex: "7C3AED")]
            case .minimax:
                return [Color(hex: "F59E0B"), Color(hex: "FCD34D"), Color(hex: "D97706"), Color(hex: "FBBF24")]
            case .kimi:
                return [Color(hex: "6366F1"), Color(hex: "818CF8"), Color(hex: "A5B4FC"), Color(hex: "C7D2FE")]
            case .cline:
                return [Color(hex: "D4A373"), Color(hex: "E8C4A0"), Color(hex: "C08B5C"), Color(hex: "A67B5B")]
            case .kiloCode:
                return [Color(hex: "10B981"), Color(hex: "34D399"), Color(hex: "059669"), Color(hex: "6EE7B7")]
            case .rooCode:
                return [Color(hex: "EC4899"), Color(hex: "F472B6"), Color(hex: "DB2777"), Color(hex: "F9A8D4")]
            case .forgeDev:
                return [Color(hex: "F97316"), Color(hex: "FB923C"), Color(hex: "EA580C"), Color(hex: "FDBA74")]
            case .augment:
                return [Color(hex: "3B82F6"), Color(hex: "60A5FA"), Color(hex: "2563EB"), Color(hex: "93C5FD")]
            case .hermes:
                return [Color(hex: "A855F7"), Color(hex: "C084FC"), Color(hex: "9333EA"), Color(hex: "D8B4FE")]
            case .geminiCLI:
                return [Color(hex: "4285F4"), Color(hex: "8AB4F8"), Color(hex: "1A73E8"), Color(hex: "669DF6")]
            case .goose:
                return [Color(hex: "0D9488"), Color(hex: "2DD4BF"), Color(hex: "0F766E"), Color(hex: "5EEAD4")]
            case .openClaw:
                return [Color(hex: "FF6B6B"), Color(hex: "F472B6"), Color(hex: "F9A8D4"), Color(hex: "FBBF24")]
            case .ollama:
                return [Color(hex: "8B8589"), Color(hex: "B8A9A0"), Color(hex: "6E6368"), Color(hex: "9A8F94")]
            case .windsurf:
                return [Color(hex: "06B6D4"), Color(hex: "22D3EE"), Color(hex: "0891B2"), Color(hex: "67E8F9")]
            case .warp:
                return [Color(hex: "F5A623"), Color(hex: "FFD700"), Color(hex: "E8951A"), Color(hex: "FFEAA7")]
            }
        }

        // MARK: - Model Colors

        /// Deterministic color for a model name. Known families get brand colors;
        /// others hash into a palette.
        static func colorForModel(_ modelName: String) -> Color {
            let brand = LLMModelBrand.infer(fromModelKey: modelName)
            if brand != .unknown { return brand.emblemColor }

            let key = modelName.lowercased()
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
}

// MARK: - LLM Model Brand (Mobile)

/// Lightweight model-brand inference for mobile theming.
/// Mirrors the macOS `LLMModelBrand` logic without AppKit dependencies.
private enum LLMModelBrand: Hashable {
    case anthropic
    case openAI
    case google
    case deepSeek
    case kimi
    case miniMax
    case meta
    case mistral
    case qwen
    case xAI
    case cohere
    case perplexity
    case apple
    case amazon
    case alibaba
    case ollama
    case unknown

    var emblemColor: Color {
        switch self {
        case .anthropic:  return Color(hex: "CC785C")
        case .openAI:     return Color(hex: "00A67E")
        case .google:     return Color(hex: "4285F4")
        case .deepSeek, .kimi:
            return Color(hex: "6366F1")
        case .miniMax:    return Color(hex: "F59E0B")
        case .meta:       return Color(hex: "0668E1")
        case .mistral:    return Color(hex: "FF7000")
        case .qwen:       return Color(hex: "615EFF")
        case .xAI:        return Color.primary
        case .cohere:     return Color(hex: "39594D")
        case .perplexity: return Color(hex: "20808D")
        case .apple:      return Color(hex: "A2AAAD")
        case .amazon:     return Color(hex: "FF9900")
        case .alibaba:    return Color(hex: "FF6A00")
        case .ollama:     return Color(hex: "8B8589")
        case .unknown:    return MobileTheme.textSecondary
        }
    }

    static func infer(fromModelKey key: String) -> LLMModelBrand {
        let key = key.lowercased()
        if key.contains("claude") || key.contains("anthropic") { return .anthropic }
        if key.contains("gpt") || key.contains("openai") || key.contains("chatgpt") { return .openAI }
        if key.contains("gemini") || key.contains("google") { return .google }
        if key.contains("deepseek") { return .deepSeek }
        if key.contains("kimi") || key.contains("moonshot") { return .kimi }
        if key.contains("minimax") || key.contains("abab") { return .miniMax }
        if key.contains("llama") || key.contains("meta") { return .meta }
        if key.contains("mistral") || key.contains("mixtral") { return .mistral }
        if key.contains("qwen") || key.contains("qwq") { return .qwen }
        if key.contains("grok") || key.contains("xai") { return .xAI }
        if key.contains("cohere") || key.contains("command") { return .cohere }
        if key.contains("perplexity") || key.contains("sonar") { return .perplexity }
        if key.contains("mlx") || key.contains("apple") { return .apple }
        if key.contains("nova") || key.contains("amazon") || key.contains("bedrock") { return .amazon }
        if key.contains("qwen") || key.contains("alibaba") || key.contains("tongyi") { return .alibaba }
        if key.contains("ollama") { return .ollama }
        return .unknown
    }
}

// MARK: - Color Helpers

extension Color {
    /// iOS-specific `adaptive` overload using `UIColor` dynamic provider.
    /// The `init(hex:)` initializer is provided by `OpenBurnBarCore/ThemePrimitives`.
    static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor(
            dynamicProvider: { traitCollection in
                let hex = traitCollection.userInterfaceStyle == .dark ? dark : light
                return UIColor(Color(hex: hex))
            }
        ))
    }
}
