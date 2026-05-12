import SwiftUI
import OpenBurnBarCore

/// Mobile theme — now delegates to `UnifiedDesignSystem` for visual parity.
enum MobileTheme {
    // MARK: - Delegated Tokens
    static let ember   = UnifiedDesignSystem.Colors.ember
    static let amber   = UnifiedDesignSystem.Colors.amber
    static let blaze   = UnifiedDesignSystem.Colors.blaze
    static let whimsy  = UnifiedDesignSystem.Colors.whimsy

    static let background      = UnifiedDesignSystem.Colors.background
    static let surface         = UnifiedDesignSystem.Colors.surface
    static let surfaceElevated = UnifiedDesignSystem.Colors.surfaceElevated
    static let border          = UnifiedDesignSystem.Colors.border
    static let borderSubtle    = UnifiedDesignSystem.Colors.borderSubtle

    static let textPrimary   = UnifiedDesignSystem.Colors.textPrimary
    static let textSecondary = UnifiedDesignSystem.Colors.textSecondary
    static let textMuted     = UnifiedDesignSystem.Colors.textMuted

    static let success = UnifiedDesignSystem.Colors.success
    static let warning = UnifiedDesignSystem.Colors.warning
    static let error   = UnifiedDesignSystem.Colors.error

    static let hermesMercury = UnifiedDesignSystem.Colors.hermesMercury
    static let hermesAureate = UnifiedDesignSystem.Colors.hermesAureate
    static let mercuryGradient = UnifiedDesignSystem.mercuryGradient

    /// Pi runtime accent gradient. Delegates to `UnifiedDesignSystem.piGradient`
    /// so iOS and macOS share the same composed gradient — no new color values.
    static let piGradient = UnifiedDesignSystem.piGradient

    static let chatUserStroke      = UnifiedDesignSystem.Colors.chatUserStroke
    static let chatAssistantStroke = UnifiedDesignSystem.Colors.chatAssistantStroke

    static let primaryGradient = UnifiedDesignSystem.primaryGradient
    static let accentGradient  = UnifiedDesignSystem.accentGradient
    static let cardGradient    = UnifiedDesignSystem.cardGradient
    static let whimsyGradient  = UnifiedDesignSystem.whimsyGradient

    // MARK: - Spacing / Radius / Typography / Animation
    static let spacingSmall: CGFloat = UnifiedDesignSystem.Spacing.sm
    static let spacingMedium: CGFloat = UnifiedDesignSystem.Spacing.md
    static let spacingLarge: CGFloat = UnifiedDesignSystem.Spacing.lg
    static let cornerRadius: CGFloat = UnifiedDesignSystem.Radius.lg
    static let cornerRadiusSmall: CGFloat = UnifiedDesignSystem.Radius.sm

    enum Radius {
        static let sm = UnifiedDesignSystem.Radius.sm
        static let md = UnifiedDesignSystem.Radius.md
        static let lg = UnifiedDesignSystem.Radius.lg
        static let xl = UnifiedDesignSystem.Radius.xl
        static let full = UnifiedDesignSystem.Radius.full
    }

    enum Spacing {
        static let xxs = UnifiedDesignSystem.Spacing.xxs
        static let xs  = UnifiedDesignSystem.Spacing.xs
        static let sm  = UnifiedDesignSystem.Spacing.sm
        static let md  = UnifiedDesignSystem.Spacing.md
        static let lg  = UnifiedDesignSystem.Spacing.lg
        static let xl  = UnifiedDesignSystem.Spacing.xl
        static let xxl = UnifiedDesignSystem.Spacing.xxl
        static let xxxl = UnifiedDesignSystem.Spacing.xxxl
    }

    enum Typography {
        static let displayLarge = UnifiedDesignSystem.Typography.displayLarge
        static let display    = UnifiedDesignSystem.Typography.display
        static let title      = UnifiedDesignSystem.Typography.title
        static let headline   = UnifiedDesignSystem.Typography.headline
        static let body       = UnifiedDesignSystem.Typography.body
        static let footnote   = UnifiedDesignSystem.Typography.caption
        static let caption    = UnifiedDesignSystem.Typography.caption
        static let tiny       = UnifiedDesignSystem.Typography.tiny

        static let monoLarge = UnifiedDesignSystem.Typography.monoLarge
        static let mono       = UnifiedDesignSystem.Typography.mono
        static let monoSmall  = UnifiedDesignSystem.Typography.monoSmall
        static let monoTiny   = UnifiedDesignSystem.Typography.monoTiny
    }

    enum Animation {
        static let standard = UnifiedDesignSystem.Animation.standard
        static let gentle   = UnifiedDesignSystem.Animation.gentle
        static let snappy   = UnifiedDesignSystem.Animation.snappy
        static let hover    = UnifiedDesignSystem.Animation.hover
        static let mercuryShimmer = UnifiedDesignSystem.Animation.mercuryShimmer
        static let mercuryPulse   = UnifiedDesignSystem.Animation.mercuryPulse
    }

    // MARK: - UIMode Convenience
    static func tokens(for mode: UIMode) -> UIModeTheme {
        UIModeTheme(mode: mode)
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
            UnifiedDesignSystem.Colors.primary(for: provider)
        }

        static func accent(for provider: AgentProvider) -> Color {
            UnifiedDesignSystem.Colors.accent(for: provider)
        }

        static func chartPalette(for provider: AgentProvider) -> [Color] {
            UnifiedDesignSystem.Colors.chartPalette(for: provider)
        }

        static func colorForModel(_ modelName: String) -> Color {
            UnifiedDesignSystem.Colors.colorForModel(modelName)
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
