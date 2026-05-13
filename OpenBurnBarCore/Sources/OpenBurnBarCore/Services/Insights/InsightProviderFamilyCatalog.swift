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

/// Pure helper for translating `InsightCatalogModel` rows from
/// `InsightModelCatalog` into grouped `InsightProviderFamilyEntry`s for the
/// composer.
///
/// Deterministic and side-effect free; safe to call on a hot path. The
/// matcher tolerates the small naming variations real catalogs ship with
/// (e.g. `claude-code`, `anthropic`, `openai-compat`, `openrouter`, `gpt-5`,
/// etc.) so a new adapter doesn't need a code change here to land in the
/// right family chip.
public enum InsightProviderFamilyCatalog {
    /// Map a single catalog model into a family entry.
    public static func entry(
        for model: InsightCatalogModel,
        automaticDefault: (providerKey: String, modelID: String)? = nil
    ) -> InsightProviderFamilyEntry {
        let family = family(forProviderKey: model.providerKey, modelID: model.id)
        let isDefault = automaticDefault.map {
            $0.providerKey == model.providerKey && $0.modelID == model.id
        } ?? false
        return InsightProviderFamilyEntry(
            family: family,
            providerKey: model.providerKey,
            modelID: model.id,
            displayName: model.displayName,
            egressTier: model.egressTier,
            inputCostPerMtoken: model.inputCostPerMtoken,
            outputCostPerMtoken: model.outputCostPerMtoken,
            symbolName: model.symbolName,
            isAutomaticDefault: isDefault
        )
    }

    /// Translate a full catalog into a sorted, grouped list of entries.
    /// Sort order: family `sortRank`, then automatic-default first, then
    /// egress tier (local first), then display name.
    public static func entries(
        from models: [InsightCatalogModel],
        automaticDefault: (providerKey: String, modelID: String)? = nil
    ) -> [InsightProviderFamilyEntry] {
        let mapped = models.map { entry(for: $0, automaticDefault: automaticDefault) }
        return mapped.sorted { lhs, rhs in
            if lhs.family.sortRank != rhs.family.sortRank {
                return lhs.family.sortRank < rhs.family.sortRank
            }
            if lhs.isAutomaticDefault != rhs.isAutomaticDefault {
                return lhs.isAutomaticDefault && !rhs.isAutomaticDefault
            }
            let lhsTier = egressRank(lhs.egressTier)
            let rhsTier = egressRank(rhs.egressTier)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Convenience that groups entries by family for grouped picker UIs.
    /// Section order follows `InsightProviderFamily.sortRank`, not the
    /// declaration order of `allCases`, so the picker is always ordered
    /// local-first → user-relay → user-key.
    public static func grouped(
        _ entries: [InsightProviderFamilyEntry]
    ) -> [(family: InsightProviderFamily, entries: [InsightProviderFamilyEntry])] {
        let dict = Dictionary(grouping: entries, by: \.family)
        let orderedFamilies = InsightProviderFamily.allCases.sorted { $0.sortRank < $1.sortRank }
        return orderedFamilies.compactMap { family in
            guard let rows = dict[family], !rows.isEmpty else { return nil }
            return (family, rows)
        }
    }

    /// Match the family for a given provider key + model id. Lenient on
    /// punctuation/case so catalog churn doesn't require a code change.
    public static func family(
        forProviderKey providerKey: String,
        modelID: String
    ) -> InsightProviderFamily {
        let key = normalize(providerKey)
        let model = normalize(modelID)

        // Provider-key wins when it's unambiguous.
        switch key {
        case "anthropic", "claude", "claudecode", "claudecodecli":
            return .claude
        case "openai":
            return model.contains("gpt") ? .openai : .openai
        case "codex", "openaicodex":
            return .codex
        case "minimax":
            return .minimax
        case "zai", "z", "zhipu":
            return .zai
        case "kimi", "moonshot":
            return .kimi
        case "ollama":
            return .ollama
        case "hermes", "hermesrelay":
            return .hermes
        case "pi", "piagent", "piruntime":
            return .pi
        case "openrouter":
            return .openrouter
        case "localrules", "rules":
            return .localRules
        default:
            break
        }

        // Provider key didn't match; try model-id sniffing.
        if model.contains("claude") || model.contains("sonnet") || model.contains("opus") || model.contains("haiku") {
            return .claude
        }
        if model.contains("gpt") || model.contains("o1") || model.contains("o3") || model.contains("o4") {
            return .openai
        }
        if model.contains("codex") {
            return .codex
        }
        if model.contains("kimi") {
            return .kimi
        }
        if model.contains("minimax") {
            return .minimax
        }
        if model.contains("glm") || model.contains("zai") {
            return .zai
        }
        if model.contains("llama") || model.contains("mistral") || model.contains("phi") {
            return .ollama
        }
        return .other
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func egressRank(_ tier: InsightEgressTier) -> Int {
        switch tier {
        case .localOnly: return 0
        case .userRelay: return 1
        case .userKey: return 2
        case .hosted: return 3
        }
    }
}
