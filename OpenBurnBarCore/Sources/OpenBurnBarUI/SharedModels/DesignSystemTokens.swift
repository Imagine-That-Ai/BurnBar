import Foundation
import OpenBurnBarKernel

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

// MARK: - Design System Colors — Foundation surface (raw RGBA)

/// The platform-independent surface of `DesignSystemColors`.
///
/// The SwiftUI `Color` accessors (brand colors, per-provider `primary`/`accent`,
/// `colorForModel`) live in `ThemePrimitives.swift`, which is compiled only
/// where SwiftUI is available. This declaration holds the raw-RGBA resolution
/// used by Canvas-level color math (`SwarmColorDriver`, the substrates), so the
/// engine can resolve provider brand colors without SwiftUI. On Apple platforms
/// both files compile and `DesignSystemColors` exposes the exact same API as
/// before this extraction.
public enum DesignSystemColors {

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
        case .openClaw: return "FF6B6B"
        case .openClaude: return "D97757"
        case .omp: return "EC4899"
        case .junie: return "48E054"
        case .ollama:      return "6B7280"
        case .windsurf:    return "06B6D4"
        case .devin:       return "0A84FF"
        case .warp:        return "DDE4EA"
        case .openCode:    return "2563EB"
        case .xAI:         return "1A1A1A"
        case .mimo:        return "FF6900"
        case .primeAgent:  return "582CFF"
        case .muse: return "0668E1"
        case .fx:          return "A1A1AA"
        case .openBurnBar: return "FA5053"
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
