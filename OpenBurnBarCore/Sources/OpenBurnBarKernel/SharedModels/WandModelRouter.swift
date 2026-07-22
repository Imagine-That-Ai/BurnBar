import Foundation

/// Deterministic model selection for The Wand.
///
/// The Python Ministry remains the richer selector when it has full provider
/// quota telemetry. This router is the app-side contract that prevents
/// Headmaster/Pareto from being a no-op: given the live Mac catalog rows that
/// the app can already fetch for each runtime, it produces concrete
/// `requestedModelID` values before child missions are written.
public enum WandModelRouter {
    public struct Selection: Codable, Equatable, Sendable {
        public let runtime: AssistantRuntimeID
        public let option: CLIRuntimeModelOption
        public let providerDiversityRelaxed: Bool

        public var requestedModelID: String {
            option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static func policy(
        selector: WandPolicy.Selector,
        runtimes: [AssistantRuntimeID],
        catalogs: [AssistantRuntimeID: [CLIRuntimeModelOption]],
        requireProviderDiversity: Bool = true
    ) -> WandPolicy {
        let selections = select(
            selector: selector,
            runtimes: runtimes,
            catalogs: catalogs,
            requireProviderDiversity: requireProviderDiversity
        )
        return WandPolicy(
            selector: selector,
            routedModels: Dictionary(
                uniqueKeysWithValues: selections.compactMap { selection in
                    let modelID = selection.requestedModelID
                    return modelID.isEmpty ? nil : (selection.runtime, modelID)
                }
            )
        )
    }

    public static func select(
        selector: WandPolicy.Selector,
        runtimes: [AssistantRuntimeID],
        catalogs: [AssistantRuntimeID: [CLIRuntimeModelOption]],
        requireProviderDiversity: Bool = true
    ) -> [Selection] {
        var selections: [Selection] = []
        var usedProviders = Set<String>()

        for runtime in uniqueRuntimes(runtimes) {
            let ranked = rankedOptions(
                catalogs[runtime] ?? [],
                selector: selector
            )
            guard !ranked.isEmpty else { continue }

            let diverse = requireProviderDiversity
                ? ranked.first { !usedProviders.contains(providerKey($0)) }
                : ranked.first
            let selected = diverse ?? ranked[0]
            selections.append(
                Selection(
                    runtime: runtime,
                    option: selected,
                    providerDiversityRelaxed: diverse == nil && requireProviderDiversity
                )
            )
            usedProviders.insert(providerKey(selected))
        }

        return selections
    }

    public static func rankedOptions(
        _ options: [CLIRuntimeModelOption],
        selector: WandPolicy.Selector
    ) -> [CLIRuntimeModelOption] {
        options
            .filter { !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                sortKey(lhs, selector: selector) < sortKey(rhs, selector: selector)
            }
    }

    private static func uniqueRuntimes(_ runtimes: [AssistantRuntimeID]) -> [AssistantRuntimeID] {
        var seen = Set<AssistantRuntimeID>()
        var ordered: [AssistantRuntimeID] = []
        for runtime in runtimes where seen.insert(runtime).inserted {
            ordered.append(runtime)
        }
        return ordered
    }

    private static func sortKey(_ option: CLIRuntimeModelOption, selector: WandPolicy.Selector) -> SortKey {
        let capability = capabilityScore(option)
        let quotaCost = quotaCostScore(option)
        switch selector {
        case .highestCapability:
            return SortKey(
                primary: -capability,
                secondary: quotaCost,
                tertiary: sourcePreference(option.source),
                provider: providerKey(option),
                model: option.modelID.lowercased()
            )
        case .pareto:
            return SortKey(
                primary: quotaCost,
                secondary: -capability,
                tertiary: sourcePreference(option.source),
                provider: providerKey(option),
                model: option.modelID.lowercased()
            )
        }
    }

    private static func capabilityScore(_ option: CLIRuntimeModelOption) -> Int {
        let haystack = "\(option.tier) \(option.modelID) \(option.displayName)"
            .lowercased()
        let tokens = Set(haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !tokens.isDisjoint(with: ["flagship", "opus", "pro", "max", "xhigh"]) {
            return 4
        }
        if !tokens.isDisjoint(with: ["high", "sonnet"]) {
            return 3
        }
        if !tokens.isDisjoint(with: ["mid", "standard"]) {
            return 2
        }
        if !tokens.isDisjoint(with: ["small", "mini", "nano", "flash", "haiku"]) {
            return 1
        }
        return 2
    }

    private static func quotaCostScore(_ option: CLIRuntimeModelOption) -> Int {
        switch option.source {
        case .cliProfile, .droidStandardQuota, .droidCoreQuota, .forgeAgent,
             .antigravityProfile, .cursorAgentProfile:
            return 0
        case .codexModelCatalog, .claudeModelCatalog, .grokModelCatalog,
             .antigravityModelCatalog, .cursorAgentModelCatalog, .ollamaLocalCatalog:
            return 1
        case .droidCustomModel, .ollamaCloudCatalog:
            return 2
        case .openBurnBarProxy:
            return 3
        }
    }

    private static func sourcePreference(_ source: CLIRuntimeModelSource) -> Int {
        switch source {
        case .cliProfile, .droidStandardQuota, .droidCoreQuota, .forgeAgent,
             .antigravityProfile, .cursorAgentProfile:
            return 0
        case .codexModelCatalog, .claudeModelCatalog, .grokModelCatalog,
             .antigravityModelCatalog, .cursorAgentModelCatalog, .ollamaLocalCatalog:
            return 1
        case .ollamaCloudCatalog, .droidCustomModel:
            return 2
        case .openBurnBarProxy:
            return 3
        }
    }

    private static func providerKey(_ option: CLIRuntimeModelOption) -> String {
        let provider = option.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty ? option.source.rawValue : provider.lowercased()
    }

    private struct SortKey: Comparable {
        let primary: Int
        let secondary: Int
        let tertiary: Int
        let provider: String
        let model: String

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
            if lhs.secondary != rhs.secondary { return lhs.secondary < rhs.secondary }
            if lhs.tertiary != rhs.tertiary { return lhs.tertiary < rhs.tertiary }
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            return lhs.model < rhs.model
        }
    }
}
