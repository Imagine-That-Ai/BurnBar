import Foundation
import SwiftUI

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
        self.init(uiColor: UIColor(
            dynamicProvider: { traitCollection in
                let hex = traitCollection.userInterfaceStyle == .dark ? dark : light
                return UIColor(Color(hex: hex))
            }
        ))
    }
    #else
    init(light: String, dark: String) {
        self.init(
            NSColor(name: nil) { appearance in
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
    public static let hermesAureateLight = "B8942E"
    public static let hermesAureateDark  = "D4AA3C"

    // Chat
    public static let chatUserStrokeLight      = "6A5ACD"
    public static let chatUserStrokeDark       = "8B7FE8"
    public static let chatAssistantStrokeLight = "F45B69"
    public static let chatAssistantStrokeDark  = "FA5053"
}

// MARK: - Design System SwiftUI Colors

public enum DesignSystemColors {
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

    public static func primary(for provider: AgentProvider) -> Color {
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
        case .geminiCLI:  return Color(hex: "4285F4")
        case .goose:      return Color(hex: "0D9488")
        case .openClaw:   return Color(hex: "FF6B6B")
        case .ollama:     return Color(hex: "6B7280")
        case .windsurf:   return Color(hex: "06B6D4")
        case .warp:       return Color(hex: "DDE4EA")
        }
    }

    public static func accent(for provider: AgentProvider) -> Color {
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
        case .geminiCLI:  return Color(hex: "8AB4F8")
        case .goose:      return Color(hex: "2DD4BF")
        case .openClaw:   return Color(hex: "F472B6")
        case .ollama:     return Color(hex: "9CA3AF")
        case .windsurf:   return Color(hex: "22D3EE")
        case .warp:       return Color(hex: "111111")
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
            Color(hex: "8B5CF6"), Color(hex: "06B6D4"), Color(hex: "84CC16"),
        ]
        var hash = UInt64(5381)
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
