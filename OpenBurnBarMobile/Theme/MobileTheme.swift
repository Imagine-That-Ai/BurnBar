import SwiftUI
import UIKit
import OpenBurnBarCore

/// Brand-sized system fonts that still follow Dynamic Type.
enum MobileScaledFont {
    static func system(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        let uiWeight: UIFont.Weight
        switch weight {
        case .ultraLight: uiWeight = .ultraLight
        case .thin: uiWeight = .thin
        case .light: uiWeight = .light
        case .medium: uiWeight = .medium
        case .semibold: uiWeight = .semibold
        case .bold: uiWeight = .bold
        case .heavy: uiWeight = .heavy
        case .black: uiWeight = .black
        default: uiWeight = .regular
        }
        let uiDesign: UIFontDescriptor.SystemDesign
        switch design {
        case .rounded: uiDesign = .rounded
        case .monospaced: uiDesign = .monospaced
        case .serif: uiDesign = .serif
        default: uiDesign = .default
        }
        let uiStyle: UIFont.TextStyle
        switch textStyle {
        case .largeTitle: uiStyle = .largeTitle
        case .title: uiStyle = .title1
        case .title2: uiStyle = .title2
        case .title3: uiStyle = .title3
        case .headline: uiStyle = .headline
        case .body: uiStyle = .body
        case .callout: uiStyle = .callout
        case .subheadline: uiStyle = .subheadline
        case .footnote: uiStyle = .footnote
        case .caption: uiStyle = .caption1
        case .caption2: uiStyle = .caption2
        default: uiStyle = .body
        }
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let descriptor = base.fontDescriptor.withDesign(uiDesign) ?? base.fontDescriptor
        let designed = UIFont(descriptor: descriptor, size: size)
        return Font(UIFontMetrics(forTextStyle: uiStyle).scaledFont(for: designed))
    }
}

/// Mobile theme — colors/spacing delegate to `UnifiedDesignSystem` for visual
/// parity; typography is restated through `MobileScaledFont` so the same brand
/// sizes still follow Dynamic Type.
enum MobileTheme {
    // MARK: - Delegated Tokens
    static let ember   = UnifiedDesignSystem.Colors.ember
    static let amber   = UnifiedDesignSystem.Colors.amber
    static let blaze   = UnifiedDesignSystem.Colors.blaze
    static let whimsy  = UnifiedDesignSystem.Colors.whimsy

    static let background      = UnifiedDesignSystem.Colors.background

    /// Card fills. When the Swarm Background is enabled we drop their opacity
    /// so the reconverging swarm shows through the cards instead of being
    /// hidden behind solid surfaces.
    static var surface: Color {
        UnifiedDesignSystem.Colors.surface.opacity(swarmEnabled ? 0.62 : 1.0)
    }
    static var surfaceElevated: Color {
        UnifiedDesignSystem.Colors.surfaceElevated.opacity(swarmEnabled ? 0.68 : 1.0)
    }
    static let border          = UnifiedDesignSystem.Colors.border
    static let borderSubtle    = UnifiedDesignSystem.Colors.borderSubtle

    /// Whether the user has enabled the Swarm Background theme. Always `false`
    /// under the Editorial skin — paper surfaces stay fully opaque, never
    /// translucent over a (suppressed) swarm.
    private static var swarmEnabled: Bool {
        AppSkin.current != .editorial && UserDefaults.standard.bool(forKey: "useWebsiteBackground")
    }

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
        static let displayLarge = MobileScaledFont.system(size: 36, weight: .bold, design: .rounded, relativeTo: .largeTitle)
        static let display    = MobileScaledFont.system(size: 28, weight: .bold, design: .rounded, relativeTo: .title)
        static let title      = MobileScaledFont.system(size: 20, weight: .semibold, design: .rounded, relativeTo: .title3)
        static let headline   = MobileScaledFont.system(size: 18, weight: .semibold, design: .rounded, relativeTo: .headline)
        static let body       = MobileScaledFont.system(size: 17, weight: .regular, design: .rounded, relativeTo: .body)
        static let footnote   = MobileScaledFont.system(size: 15, weight: .medium, design: .rounded, relativeTo: .callout)
        static let caption    = MobileScaledFont.system(size: 15, weight: .medium, design: .rounded, relativeTo: .callout)
        static let tiny       = MobileScaledFont.system(size: 14, weight: .medium, design: .rounded, relativeTo: .caption)

        static let monoLarge = MobileScaledFont.system(size: 28, weight: .bold, design: .monospaced, relativeTo: .title)
        static let mono       = MobileScaledFont.system(size: 16, weight: .medium, design: .monospaced, relativeTo: .callout)
        static let monoSmall  = MobileScaledFont.system(size: 14, weight: .medium, design: .monospaced, relativeTo: .caption)
        static let monoTiny   = MobileScaledFont.system(size: 13, weight: .medium, design: .monospaced, relativeTo: .caption2)
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
    case openBurnBar
    case zai
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
        case .openBurnBar: return Color(hex: "FA5053")
        case .zai:        return Color(hex: "8B5CF6")
        case .unknown:    return MobileTheme.textSecondary
        }
    }

    static func infer(fromModelKey key: String) -> LLMModelBrand {
        let key = key.lowercased()
        if key.contains("openburnbar") || key.contains("burnbar") { return .openBurnBar }
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
        if key.contains("zai") || key.contains("glm") { return .zai }
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
