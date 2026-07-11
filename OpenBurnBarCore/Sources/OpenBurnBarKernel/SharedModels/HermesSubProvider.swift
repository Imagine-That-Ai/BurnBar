import Foundation

// MARK: - Hermes Sub-Provider
//
// The chat surface exposes Hermes as an umbrella runtime that can route to
// several underlying providers (codex, claude, zai, kimi, minimax, ollama).
// Live relays advertise their concrete model list via `HermesRuntimeModelOption`,
// but the **static** catalog below is what the picker falls back to when the
// relay hasn't reported models yet — so the picker is never empty for users
// who haven't connected a host.
//
// The Hermes sub-provider catalog is also the source of truth for the
// "Hermes models" visibility toggles in Settings on every platform.

public enum HermesSubProvider: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case codex
    case claude
    case zai
    case kimi
    case minimax
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex:   return "Codex"
        case .claude:  return "Claude"
        case .zai:     return "Z.ai"
        case .kimi:    return "Kimi"
        case .minimax: return "MiniMax"
        case .ollama:  return "Ollama"
        }
    }

    /// Provider tag a live `HermesRuntimeModelOption` carries when it routes
    /// through this sub-provider. Used to map advertised models → sub-provider.
    public var providerToken: String {
        switch self {
        case .codex:   return "codex"
        case .claude:  return "claude"
        case .zai:     return "zai"
        case .kimi:    return "kimi"
        case .minimax: return "minimax"
        case .ollama:  return "ollama"
        }
    }

    /// Conservative default model id surfaced if a sub-provider is selected
    /// before the relay has advertised any concrete models.
    public var defaultModelHint: String {
        switch self {
        case .codex:   return "codex"
        case .claude:  return "claude"
        case .zai:     return "glm-4.6"
        case .kimi:    return "kimi-k2"
        case .minimax: return "minimax-m1"
        case .ollama:  return "llama3"
        }
    }

    /// AgentProvider mapping for shared logo / display affordances.
    public var agentProvider: AgentProvider {
        switch self {
        case .codex:   return .codex
        case .claude:  return .claudeCode
        case .zai:     return .zai
        case .kimi:    return .kimi
        case .minimax: return .minimax
        case .ollama:  return .ollama
        }
    }

    /// Hex glyph for compact rendering when no logo is available.
    public var glyph: String {
        switch self {
        case .codex:   return "\u{21BB}" // ⟳
        case .claude:  return "\u{2726}" // ✦
        case .zai:     return "Z"
        case .kimi:    return "K"
        case .minimax: return "M"
        case .ollama:  return "\u{2299}" // ⊙
        }
    }

    /// Resolve a sub-provider from a runtime provider tag (case-insensitive,
    /// space-stripped). Returns nil for tags that don't map to one of the six.
    public static func fromProviderToken(_ raw: String) -> HermesSubProvider? {
        let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "")
        return HermesSubProvider.allCases.first { $0.providerToken == normalized }
    }

    /// Default set: all six are visible on a fresh install so the picker
    /// surfaces every routable Hermes destination out of the box.
    public static let defaultVisible: Set<HermesSubProvider> = Set(HermesSubProvider.allCases)
}
