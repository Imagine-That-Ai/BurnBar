import Foundation
import SwiftUI

// MARK: - App Skin

/// The app-wide visual *skin* — an axis orthogonal to light/dark appearance.
///
/// `aurora` is the original ember/glass look and stays the default. `editorial`
/// is the light-locked "Quiet Editorial" paper skin lifted from the
/// app.burnbar.ai console: paper surfaces, ink text, a single coral accent,
/// hairlines, and no glass/glow. Selecting it re-points the design-system color
/// tokens — every token-bound view flips coherently, exactly like the web
/// console re-points its CSS variables.
///
/// Persisted under ``storageKey`` in `UserDefaults.standard` so the token layer
/// (which has no SwiftUI context) can read the active skin while resolving a
/// dynamic `Color`. SwiftUI views read it via `@AppStorage(AppSkin.storageKey)`.
public enum AppSkin: String, CaseIterable, Codable, Sendable {
    case aurora
    case editorial

    /// `UserDefaults` / `@AppStorage` key. Shared verbatim across all platforms.
    public static let storageKey = "appSkin"

    /// The currently-selected skin, read live from `UserDefaults.standard`.
    /// Mirrors the lightweight pattern `MobileTheme.surface` already uses for
    /// the swarm flag so dynamic color providers can branch without a view.
    public static var current: AppSkin {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let skin = AppSkin(rawValue: raw) else { return .aurora }
        return skin
    }

    public var displayName: String {
        switch self {
        case .aurora:    return "Aurora"
        case .editorial: return "Editorial"
        }
    }
}

// MARK: - Hex Color Helpers

public extension Color {
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

    #if os(iOS)
    init(light: String, dark: String) {
        self.init(editorial: light, light: light, dark: dark)
    }

    /// Skin- and appearance-aware token color. When the editorial skin is
    /// active the `editorial` hex wins regardless of light/dark trait (the skin
    /// is light-locked); otherwise resolves `light`/`dark` off the trait.
    init(editorial: String, light: String, dark: String) {
        self.init(uiColor: UIColor(
            dynamicProvider: { traitCollection in
                if AppSkin.current == .editorial {
                    return UIColor(Color(hex: editorial))
                }
                let hex = traitCollection.userInterfaceStyle == .dark ? dark : light
                return UIColor(Color(hex: hex))
            }
        ))
    }
    #else
    init(light: String, dark: String) {
        self.init(editorial: light, light: light, dark: dark)
    }

    /// Skin- and appearance-aware token color. When the editorial skin is
    /// active the `editorial` hex wins regardless of aqua/dark appearance (the
    /// skin is light-locked); otherwise resolves `light`/`dark` off appearance.
    init(editorial: String, light: String, dark: String) {
        self.init(
            NSColor(name: nil) { appearance in
                if AppSkin.current == .editorial {
                    return NSColor(Color(hex: editorial))
                }
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(Color(hex: hex))
            }
        )
    }
    #endif
}

// MARK: - Design System Color Tokens (Hex Strings)

public enum DesignSystemTokens {
    // Brand accents
    public static let emberLight   = "F45B69"
    public static let emberDark    = "FA5053"
    public static let amberLight   = "F28C38"
    public static let amberDark    = "FFA800"
    public static let blazeLight   = "E86100"
    public static let blazeDark    = "E86100"
    public static let whimsyLight  = "6A5ACD"
    public static let whimsyDark   = "8B7FE8"

    // Surfaces
    public static let backgroundLight      = "F3E8E6"
    public static let backgroundDark       = "0D1117"
    public static let surfaceLight         = "FAF5F2"
    public static let surfaceDark          = "161B22"
    public static let surfaceElevatedLight = "FDF8F5"
    public static let surfaceElevatedDark  = "1F2630"
    public static let borderLight          = "E8BFB5"
    public static let borderDark           = "30363D"
    public static let borderSubtleLight    = "F2E0DA"
    public static let borderSubtleDark     = "21262D"

    // Text
    public static let textPrimaryLight   = "2A1816"
    public static let textPrimaryDark    = "E6EDF3"
    public static let textSecondaryLight = "6E4E48"
    public static let textSecondaryDark  = "8B949E"
    public static let textMutedLight     = "9A756D"
    public static let textMutedDark      = "6E7681"

    // Semantic
    public static let successLight = "3A7835"
    public static let successDark  = "38D898"
    public static let warningLight = "C47800"
    public static let warningDark  = "FFA800"
    public static let errorLight   = "D43030"
    public static let errorDark    = "FA5053"

    // Hermes
    public static let hermesMercuryLight = "AEA69C"
    public static let hermesMercuryDark  = "C8BFB5"
    // Dark platinum — replaces former divine gold. Deep slate platinum on
    // light surfaces, polished platinum on dark surfaces. Reads as a
    // premium gunmetal that pairs with the warm mercury silver.
    public static let hermesAureateLight = "3F4651"
    public static let hermesAureateDark  = "A2ACBA"

    // Chat
    public static let chatUserStrokeLight      = "6A5ACD"
    public static let chatUserStrokeDark       = "8B7FE8"
    public static let chatAssistantStrokeLight = "F45B69"
    public static let chatAssistantStrokeDark  = "FA5053"

    // MARK: - Editorial ("Quiet Editorial" / paper) skin
    //
    // Light-locked values mirrored verbatim from the app.burnbar.ai console
    // (`apps/console/styles/globals.css`): paper surfaces, ink text, a single
    // coral accent, ink hairlines (8-digit hex is AARRGGBB), and the AA-legible
    // encryption-tier colors repurposed for the app's semantic palette.
    public static let emberEditorial           = "F45B69" // the one accent: coral
    public static let amberEditorial           = "8A6200" // ochre (amber-on-paper)
    public static let blazeEditorial           = "B3243C" // deep coral
    public static let whimsyEditorial          = "565D68" // slate
    public static let backgroundEditorial      = "F6F4EF" // the page (ink-void)
    public static let surfaceEditorial         = "FFFEFB" // raised paper (ink-elevated)
    public static let surfaceElevatedEditorial = "FFFEFB"
    public static let borderEditorial          = "1F16140F" // ink @ 12% (glass-line)
    public static let borderSubtleEditorial    = "1416140F" // ink @ ~8%
    public static let textPrimaryEditorial     = "16140F" // ink (text-bright)
    public static let textSecondaryEditorial   = "353027" // body (text-base)
    public static let textMutedEditorial       = "6E685D" // secondary (text-mute)
    public static let successEditorial         = "0C7C69" // tier end-to-end (teal)
    public static let warningEditorial         = "8A6200" // tier server-readable (ochre)
    public static let errorEditorial           = "B22219" // seal-crimson
    public static let hermesMercuryEditorial   = "9B9488" // text-dim
    public static let hermesAureateEditorial   = "353027" // deep ink
    public static let chatUserStrokeEditorial      = "565D68" // slate
    public static let chatAssistantStrokeEditorial = "F45B69" // coral
}

// MARK: - Design System SwiftUI Colors

public enum DesignSystemColors {
    public static let ember   = Color(editorial: DesignSystemTokens.emberEditorial, light: DesignSystemTokens.emberLight, dark: DesignSystemTokens.emberDark)
    public static let amber   = Color(editorial: DesignSystemTokens.amberEditorial, light: DesignSystemTokens.amberLight, dark: DesignSystemTokens.amberDark)
    public static let blaze   = Color(editorial: DesignSystemTokens.blazeEditorial, light: DesignSystemTokens.blazeLight, dark: DesignSystemTokens.blazeDark)
    public static let whimsy  = Color(editorial: DesignSystemTokens.whimsyEditorial, light: DesignSystemTokens.whimsyLight, dark: DesignSystemTokens.whimsyDark)

    public static let background      = Color(editorial: DesignSystemTokens.backgroundEditorial, light: DesignSystemTokens.backgroundLight, dark: DesignSystemTokens.backgroundDark)
    public static let surface         = Color(editorial: DesignSystemTokens.surfaceEditorial, light: DesignSystemTokens.surfaceLight, dark: DesignSystemTokens.surfaceDark)
    public static let surfaceElevated = Color(editorial: DesignSystemTokens.surfaceElevatedEditorial, light: DesignSystemTokens.surfaceElevatedLight, dark: DesignSystemTokens.surfaceElevatedDark)
    public static let border          = Color(editorial: DesignSystemTokens.borderEditorial, light: DesignSystemTokens.borderLight, dark: DesignSystemTokens.borderDark)
    public static let borderSubtle    = Color(editorial: DesignSystemTokens.borderSubtleEditorial, light: DesignSystemTokens.borderSubtleLight, dark: DesignSystemTokens.borderSubtleDark)

    public static let textPrimary   = Color(editorial: DesignSystemTokens.textPrimaryEditorial, light: DesignSystemTokens.textPrimaryLight, dark: DesignSystemTokens.textPrimaryDark)
    public static let textSecondary = Color(editorial: DesignSystemTokens.textSecondaryEditorial, light: DesignSystemTokens.textSecondaryLight, dark: DesignSystemTokens.textSecondaryDark)
    public static let textMuted     = Color(editorial: DesignSystemTokens.textMutedEditorial, light: DesignSystemTokens.textMutedLight, dark: DesignSystemTokens.textMutedDark)

    public static let success = Color(editorial: DesignSystemTokens.successEditorial, light: DesignSystemTokens.successLight, dark: DesignSystemTokens.successDark)
    public static let warning = Color(editorial: DesignSystemTokens.warningEditorial, light: DesignSystemTokens.warningLight, dark: DesignSystemTokens.warningDark)
    public static let error   = Color(editorial: DesignSystemTokens.errorEditorial, light: DesignSystemTokens.errorLight, dark: DesignSystemTokens.errorDark)

    public static func primary(for provider: AgentProvider) -> Color {
        switch provider {
        case .factory:    return Color(hex: "8B5CF6")
        case .claudeCode: return Color(hex: "CC785C")
        case .copilot:    return Color(hex: "23EA3B")
        case .aider:      return Color(hex: "FF6B35")
        case .cursor:     return Color(hex: "B4B8C0")
        case .openAI:     return Color(hex: "00A67E")
        case .deepSeek:   return Color(hex: "6366F1")
        case .codex:      return Color(hex: "2563EB")
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
        case .antigravity: return Color(hex: "6C63FF")
        case .cursorAgent: return Color(hex: "00E5FF")
        case .goose:      return Color(hex: "0D9488")
        case .openClaw:   return Color(hex: "FF6B6B")
        case .ollama:     return Color(hex: "6B7280")
        case .windsurf:   return Color(hex: "06B6D4")
        case .warp:       return Color(hex: "DDE4EA")
        case .openCode:   return Color(hex: "2563EB")
        case .xAI:        return Color(hex: "1A1A1A")
        case .mimo:       return Color(hex: "FF6900")
        }
    }

    public static func accent(for provider: AgentProvider) -> Color {
        switch provider {
        case .factory:    return ember
        case .claudeCode: return Color(hex: "D4A574")
        case .copilot:    return Color(hex: "0969DA")
        case .aider:      return blaze
        case .cursor:     return Color(hex: "1A1A1A")
        case .openAI:     return Color(hex: "00C48C")
        case .deepSeek:   return Color(hex: "818CF8")
        case .codex:      return Color(hex: "60A5FA")
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
        case .antigravity: return Color(hex: "8F8AFF")
        case .cursorAgent: return Color(hex: "33ECFF")
        case .goose:      return Color(hex: "2DD4BF")
        case .openClaw:   return Color(hex: "F472B6")
        case .ollama:     return Color(hex: "9CA3AF")
        case .windsurf:   return Color(hex: "22D3EE")
        case .warp:       return Color(hex: "111111")
        case .openCode:   return Color(hex: "93C5FD")
        case .xAI:        return Color(hex: "4A4A4A")
        case .mimo:       return Color(hex: "FF8533")
        }
    }
    public static func colorForModel(_ modelName: String) -> Color {
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
            Color(hex: "8B5CF6"), Color(hex: "06B6D4"), Color(hex: "84CC16")
        ]
        var hash = UInt64(5381)
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    // MARK: - Raw RGBA for Canvas Rendering

    /// Returns raw RGBA components for a provider's brand color.
    /// Used by `SwarmColorDriver` for Canvas-level color math where
    /// SwiftUI `Color` cannot be resolved directly.
    public static func providerRGBA(for provider: AgentProvider) -> RGBA {
        let hex = providerHex(for: provider)
        return hexToRGBA(hex)
    }

    private static func providerHex(for provider: AgentProvider) -> String {
        switch provider {
        case .factory:     return "8B5CF6"
        case .claudeCode:  return "CC785C"
        case .copilot:     return "23EA3B"
        case .aider:       return "FF6B35"
        case .cursor:      return "B4B8C0"
        case .openAI:      return "00A67E"
        case .deepSeek:    return "6366F1"
        case .codex:       return "2563EB"
        case .zai:         return "8B5CF6"
        case .minimax:     return "F59E0B"
        case .kimi:        return "6366F1"
        case .cline:       return "D4A373"
        case .kiloCode:    return "10B981"
        case .rooCode:     return "EC4899"
        case .forgeDev:    return "F97316"
        case .augment:     return "3B82F6"
        case .hermes:      return "A855F7"
        case .piAgent:     return "7C3AED"
        case .geminiCLI:   return "4285F4"
        case .antigravity: return "6C63FF"
        case .cursorAgent: return "00E5FF"
        case .goose:       return "0D9488"
        case .openClaw:    return "FF6B6B"
        case .ollama:      return "6B7280"
        case .windsurf:    return "06B6D4"
        case .warp:        return "DDE4EA"
        case .openCode:    return "2563EB"
        case .xAI:         return "1A1A1A"
        case .mimo:        return "FF6900"
        }
    }

    private static func hexToRGBA(_ hex: String) -> RGBA {
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        return RGBA(
            r: Double((int >> 16) & 0xFF) / 255.0,
            g: Double((int >> 8) & 0xFF) / 255.0,
            b: Double(int & 0xFF) / 255.0
        )
    }
}
