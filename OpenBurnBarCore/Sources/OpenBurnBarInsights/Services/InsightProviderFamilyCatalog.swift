import Foundation

// `InsightProviderFamily` (enum) and `InsightProviderFamilyEntry` (struct) were
// extracted to `OpenBurnBarInsights/SharedModels/InsightProviderFamily.swift`
// by core-decomposition packet P-10 (models land before the P-08 engine): the
// pure Foundation-only family enum + its entry row are model types that
// `SharedModels/Insights/InsightAnalysis.swift` (P-10) references, so they must
// precede the engine into `OpenBurnBarInsights`. The catalog logic below stays
// here for P-08 because it depends on the engine's `InsightCatalogModel` /
// `InsightModelCatalog` types.

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
