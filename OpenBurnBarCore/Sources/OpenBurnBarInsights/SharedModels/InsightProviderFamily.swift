import Foundation

/// One row in the unified provider-family model picker.
///
/// `family` lets the UI group catalog entries by brand (Codex, Claude,
/// MiniMax, Z.ai, Kimi, Ollama, Hermes-advertised, etc.) so the composer
/// shows a single grouped list across heterogeneous gateway adapters.
public struct InsightProviderFamilyEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(providerKey)/\(modelID)" }
    public var family: InsightProviderFamily
    public var providerKey: String
    public var modelID: String
    public var displayName: String
    public var egressTier: InsightEgressTier
    /// USD per million input tokens (badge).
    public var inputCostPerMtoken: Double?
    /// USD per million output tokens (badge).
    public var outputCostPerMtoken: Double?
    /// SF Symbol / asset name for the picker chip.
    public var symbolName: String
    /// True for the host's current Hermes-advertised / selected default model
    /// when `InsightModelPreference.mode == .automatic`.
    public var isAutomaticDefault: Bool

    public init(
        family: InsightProviderFamily,
        providerKey: String,
        modelID: String,
        displayName: String,
        egressTier: InsightEgressTier,
        inputCostPerMtoken: Double? = nil,
        outputCostPerMtoken: Double? = nil,
        symbolName: String = "cpu",
        isAutomaticDefault: Bool = false
    ) {
        self.family = family
        self.providerKey = providerKey
        self.modelID = modelID
        self.displayName = displayName
        self.egressTier = egressTier
        self.inputCostPerMtoken = inputCostPerMtoken
        self.outputCostPerMtoken = outputCostPerMtoken
        self.symbolName = symbolName
        self.isAutomaticDefault = isAutomaticDefault
    }
}

/// Normalized family the picker groups models by. Mirrors the TS / Kotlin
/// `InsightProviderFamily` enum.
public enum InsightProviderFamily: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case claude
    case minimax
    case zai
    case kimi
    case ollama
    case hermes
    case openai
    case pi
    case openrouter
    case localRules = "local-rules"
    case other

    /// Human-readable label for the family chip.
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .minimax: return "MiniMax"
        case .zai: return "Z.ai"
        case .kimi: return "Kimi"
        case .ollama: return "Ollama"
        case .hermes: return "Hermes"
        case .openai: return "OpenAI"
        case .pi: return "Pi"
        case .openrouter: return "OpenRouter"
        case .localRules: return "Local Rules"
        case .other: return "Other"
        }
    }

    /// SF Symbol used as the family chip glyph.
    public var symbolName: String {
        switch self {
        case .codex: return "command.square"
        case .claude: return "sparkle"
        case .minimax: return "diamond"
        case .zai: return "circle.grid.cross"
        case .kimi: return "moon.stars"
        case .ollama: return "shippingbox"
        case .hermes: return "bolt.horizontal"
        case .openai: return "circle.hexagongrid"
        case .pi: return "house.circle"
        case .openrouter: return "arrow.triangle.branch"
        case .localRules: return "gearshape.2"
        case .other: return "questionmark.circle"
        }
    }

    /// Sort order for grouped listings — local first, then user-relay-friendly
    /// families, then user-key cloud families. The picker keeps this stable so
    /// the user always sees the same family ordering regardless of what the
    /// model catalog returned this session.
    public var sortRank: Int {
        switch self {
        case .localRules: return 0
        case .ollama: return 1
        case .pi: return 2
        case .hermes: return 3
        case .openrouter: return 4
        case .claude: return 5
        case .openai: return 6
        case .codex: return 7
        case .minimax: return 8
        case .zai: return 9
        case .kimi: return 10
        case .other: return 99
        }
    }
}
