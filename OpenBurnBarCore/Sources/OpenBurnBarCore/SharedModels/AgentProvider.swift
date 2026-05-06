import Foundation
import SwiftUI

// MARK: - Agent Provider Enum

/// Cross-platform provider identity used by both macOS and iOS targets.
public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case factory = "Factory"
    case claudeCode = "Claude Code"
    case copilot = "Copilot"
    case aider = "Aider"
    case cursor = "Cursor"
    case openAI = "OpenAI"
    case codex = "Codex"
    case zai = "Zai"
    case minimax = "MiniMax"
    case kimi = "Kimi"
    case cline = "Cline"
    case kiloCode = "Kilo Code"
    case rooCode = "Roo Code"
    case forgeDev = "Forge"
    case augment = "Augment"
    case hermes = "Hermes"
    case geminiCLI = "Gemini CLI"
    case goose = "Goose"
    case openClaw = "OpenClaw"
    case ollama = "Ollama"
    case windsurf = "Windsurf"
    case warp = "Warp"

    public var id: String { rawValue }

    /// Providers that expose a real quota/rate-limit signal either through an
    /// official API, a provider dashboard scrape, or a first-party local quota
    /// bridge. Usage-only tools stay out of quota surfaces.
    public static let quotaSignalProviders: [AgentProvider] = [
        .codex,
        .claudeCode,
        .copilot,
        .minimax,
        .zai,
        .factory,
        .cursor,
        .warp,
        .ollama,
        .kimi,
    ]

    public var isQuotaSignalProvider: Bool {
        Self.quotaSignalProviders.contains(self)
    }

    /// Mobile account-connection providers. This is narrower than
    /// `allCases`: local usage/activity tools do not have quota credentials to
    /// add from iOS.
    public static let mobileAccountConnectableProviders: [AgentProvider] = [
        .claudeCode,
        .codex,
        .factory,
        .cursor,
        .copilot,
        .minimax,
        .zai,
        .kimi,
        .warp,
        .openAI,
    ]

    /// A stable, lowercased, space-stripped token for persisting provider identifiers.
    public var persistedToken: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Catalog/cloud provider identity used by first-class provider accounts.
    public var providerID: ProviderID {
        switch self {
        case .openAI:
            return .openAI
        case .claudeCode:
            return .claudeCode
        case .codex:
            return .codex
        default:
            return ProviderID(rawValue: persistedToken)
        }
    }

    /// Resolves a provider from either its persisted token or display name.
    public static func fromPersistedToken(_ token: String) -> AgentProvider? {
        let normalized = token.lowercased().replacingOccurrences(of: " ", with: "")
        return AgentProvider.allCases.first { $0.persistedToken == normalized }
    }

    /// Resolves display/log parser providers from canonical provider IDs.
    ///
    /// OpenAI billing/account contracts use `ProviderID.openAI`, while local
    /// Codex logs remain `AgentProvider.codex`.
    public static func fromProviderID(_ providerID: ProviderID) -> AgentProvider? {
        switch providerID.rawValue {
        case "openai":
            return .openAI
        case "claude-code":
            return .claudeCode
        case "codex":
            return .codex
        default:
            return AgentProvider.allCases.first { $0.providerID == providerID }
        }
    }

    /// Bundled asset catalog image name for every provider.
    public var bundledLogoName: String {
        switch self {
        case .factory:    return "FactoryLogo"
        case .claudeCode: return "ClaudeCodeLogo"
        case .copilot:    return "CopilotLogo"
        case .aider:      return "AiderLogo"
        case .cursor:     return "CursorLogo"
        case .openAI:     return "OpenAILogo"
        case .codex:      return "CodexLogo"
        case .zai:        return "ZaiLogo"
        case .minimax:    return "MiniMaxLogo"
        case .kimi:       return "KimiLogo"
        case .cline:      return "ClineLogo"
        case .kiloCode:   return "KiloCodeLogo"
        case .rooCode:    return "RooCodeLogo"
        case .forgeDev:   return "ForgeLogo"
        case .augment:    return "AugmentLogo"
        case .hermes:     return "HermesLogo"
        case .geminiCLI:  return "GeminiCLILogo"
        case .goose:      return "GooseLogo"
        case .openClaw:   return "OpenClawLogo"
        case .ollama:     return "OllamaLogo"
        case .windsurf:   return "WindsurfLogo"
        case .warp:       return "WarpLogo"
        }
    }

    /// SF Symbol name used as a fallback icon on iOS and macOS.
    public var iconName: String {
        switch self {
        case .factory: return "cpu.fill"
        case .claudeCode: return "bubble.left.and.bubble.right.fill"
        case .copilot: return "sparkles"
        case .aider: return "terminal.fill"
        case .cursor: return "cursor.rays"
        case .openAI: return "sparkles"
        case .codex: return "hammer.fill"
        case .zai: return "bolt.fill"
        case .minimax: return "star.fill"
        case .kimi: return "moon.fill"
        case .cline: return "brain.head.profile"
        case .kiloCode: return "k.circle.fill"
        case .rooCode: return "hare.fill"
        case .forgeDev: return "flame.fill"
        case .augment: return "arrow.trianglehead.2.counterclockwise.rotate.90"
        case .hermes: return "wind"
        case .geminiCLI: return "diamond.fill"
        case .goose: return "bird.fill"
        case .openClaw: return "point.3.connected.trianglepath.dotted"
        case .ollama: return "server.rack"
        case .windsurf: return "sailboat.fill"
        case .warp: return "terminal.fill"
        }
    }

    public var displayName: String { rawValue }
}
