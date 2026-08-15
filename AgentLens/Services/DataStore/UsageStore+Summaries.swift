import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    // MARK: - Summary Builders

    /// Per-model accumulator shared by the provider, credential, and project
    /// summary builders. Tracks token buckets, cost, and provenance rollup.
    private struct ModelRollup {
        var input: Int
        var output: Int
        var cacheCreation: Int
        var cacheRead: Int
        var reasoning: Int
        var cost: Double
        var bestConfidence: UsageProvenanceConfidence
        var bestMethod: UsageProvenanceMethod
        var hasEstimated: Bool
    }

    static func makeProviderSummaries(from usages: [TokenUsage]) -> [ProviderSummary] {
        AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            let providerUsages = usages.filter { $0.provider == provider }
            guard !providerUsages.isEmpty else { return nil }

            let totalCost = providerUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = providerUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = providerUsages.reduce(0) { $0 + $1.outputTokens }

            // Track model data including provenance
            var modelData: [String: ModelRollup] = [:]
            for usage in providerUsages {
                let existing = modelData[usage.model]
                let newConfidence = usage.provenanceConfidence
                let newMethod = usage.provenanceMethod
                let bestConfidence: UsageProvenanceConfidence
                let bestMethod: UsageProvenanceMethod
                if let existingRec = existing {
                    bestConfidence = newConfidence > existingRec.bestConfidence ? newConfidence : existingRec.bestConfidence
                    if newConfidence == existingRec.bestConfidence {
                        bestMethod = newMethod.precedence > existingRec.bestMethod.precedence ? newMethod : existingRec.bestMethod
                    } else {
                        bestMethod = newConfidence > existingRec.bestConfidence ? newMethod : existingRec.bestMethod
                    }
                } else {
                    bestConfidence = newConfidence
                    bestMethod = newMethod
                }
                let rowIsEstimated = newConfidence != .exact && newConfidence != .derivedExact
                let existingHasEstimated = existing?.hasEstimated ?? false
                modelData[usage.model] = ModelRollup(
                    input: (existing?.input ?? 0) + usage.inputTokens,
                    output: (existing?.output ?? 0) + usage.outputTokens,
                    cacheCreation: (existing?.cacheCreation ?? 0) + usage.cacheCreationTokens,
                    cacheRead: (existing?.cacheRead ?? 0) + usage.cacheReadTokens,
                    reasoning: (existing?.reasoning ?? 0) + usage.reasoningTokens,
                    cost: (existing?.cost ?? 0) + usage.cost,
                    bestConfidence: bestConfidence,
                    bestMethod: bestMethod,
                    hasEstimated: existingHasEstimated || rowIsEstimated
                )
            }

            // Compute dominant provenance for the provider overall
            // Also track whether any row has estimated provenance
            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in providerUsages {
                // Track estimated contributions
                let rowIsEstimated = usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact
                hasAnyEstimated = hasAnyEstimated || rowIsEstimated
                let weight = usage.cost > 0 ? usage.cost : 0.001
                if usage.provenanceConfidence > dominantConfidence {
                    dominantConfidence = usage.provenanceConfidence
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                } else if usage.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                }
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.input + data.output + data.cacheCreation + data.cacheRead + data.reasoning
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.input,
                    outputTokens: data.output,
                    cacheCreationTokens: data.cacheCreation,
                    cacheReadTokens: data.cacheRead,
                    reasoningTokens: data.reasoning,
                    totalTokens: totalModelTokens,
                    cost: data.cost,
                    percentage: totalCost > 0 ? (data.cost / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }.sorted { $0.cost > $1.cost }

            return ProviderSummary(
                provider: provider,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: providerUsages.count,
                modelBreakdown: modelBreakdown,
                provenanceConfidence: dominantConfidence,
                provenanceMethod: dominantMethod,
                hasEstimatedContributions: hasAnyEstimated,
                cacheEfficiency: CacheEfficiency.aggregate(providerUsages)
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    /// Aggregates `token_usage` rows by `(provider, providerAccountID)` to power the
    /// "Spend by Credential" dashboard lane. Mirrors `makeProviderSummaries` but slices
    /// at the credential dimension so users with multiple API keys (or distinct OAuth
    /// identities) per provider see distinct totals.
    static func makeCredentialSummaries(from usages: [TokenUsage]) -> [CredentialSummary] {
        struct GroupKey: Hashable {
            let provider: AgentProvider
            let accountID: String?
        }

        var groups: [GroupKey: [TokenUsage]] = [:]
        for usage in usages {
            let key = GroupKey(provider: usage.provider, accountID: usage.providerAccountID)
            groups[key, default: []].append(usage)
        }

        return groups.compactMap { key, rows -> CredentialSummary? in
            guard !rows.isEmpty else { return nil }

            let totalCost = rows.reduce(0) { $0 + $1.cost }
            let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = rows.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = rows.reduce(0) { $0 + $1.outputTokens }

            // Derive current metadata from the newest informative row. The SQL
            // aggregate path applies the same recency + lexical tie-break.
            let nonEmptyLabel = rows
                .filter { ($0.providerAccountLabel ?? "").isEmpty == false }
                .max {
                    if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                    return ($0.providerAccountLabel ?? "") > ($1.providerAccountLabel ?? "")
                }?
                .providerAccountLabel
            let accountLabel: String = {
                if let label = nonEmptyLabel, !label.isEmpty { return label }
                if let id = key.accountID, !id.isEmpty {
                    let suffix = id.suffix(6)
                    return "\(key.provider.displayName) · …\(suffix)"
                }
                return "\(key.provider.displayName) · default"
            }()
            let accountSource = rows
                .filter { $0.providerAccountSource != nil }
                .max {
                    if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                    return ($0.providerAccountSource?.rawValue ?? "")
                        > ($1.providerAccountSource?.rawValue ?? "")
                }?
                .providerAccountSource

            // Per-model rollup (same shape as makeProviderSummaries).
            var modelData: [String: ModelRollup] = [:]
            for usage in rows {
                let existing = modelData[usage.model]
                let newConfidence = usage.provenanceConfidence
                let newMethod = usage.provenanceMethod
                let bestConfidence: UsageProvenanceConfidence
                let bestMethod: UsageProvenanceMethod
                if let existingRec = existing {
                    bestConfidence = newConfidence > existingRec.bestConfidence ? newConfidence : existingRec.bestConfidence
                    if newConfidence == existingRec.bestConfidence {
                        bestMethod = newMethod.precedence > existingRec.bestMethod.precedence ? newMethod : existingRec.bestMethod
                    } else {
                        bestMethod = newConfidence > existingRec.bestConfidence ? newMethod : existingRec.bestMethod
                    }
                } else {
                    bestConfidence = newConfidence
                    bestMethod = newMethod
                }
                let rowIsEstimated = newConfidence != .exact && newConfidence != .derivedExact
                let existingHasEstimated = existing?.hasEstimated ?? false
                modelData[usage.model] = ModelRollup(
                    input: (existing?.input ?? 0) + usage.inputTokens,
                    output: (existing?.output ?? 0) + usage.outputTokens,
                    cacheCreation: (existing?.cacheCreation ?? 0) + usage.cacheCreationTokens,
                    cacheRead: (existing?.cacheRead ?? 0) + usage.cacheReadTokens,
                    reasoning: (existing?.reasoning ?? 0) + usage.reasoningTokens,
                    cost: (existing?.cost ?? 0) + usage.cost,
                    bestConfidence: bestConfidence,
                    bestMethod: bestMethod,
                    hasEstimated: existingHasEstimated || rowIsEstimated
                )
            }

            // Dominant provenance across the credential's rows.
            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in rows {
                let rowIsEstimated = usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact
                hasAnyEstimated = hasAnyEstimated || rowIsEstimated
                let weight = usage.cost > 0 ? usage.cost : 0.001
                if usage.provenanceConfidence > dominantConfidence {
                    dominantConfidence = usage.provenanceConfidence
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                } else if usage.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                }
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.input + data.output + data.cacheCreation + data.cacheRead + data.reasoning
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.input,
                    outputTokens: data.output,
                    cacheCreationTokens: data.cacheCreation,
                    cacheReadTokens: data.cacheRead,
                    reasoningTokens: data.reasoning,
                    totalTokens: totalModelTokens,
                    cost: data.cost,
                    percentage: totalCost > 0 ? (data.cost / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }.sorted { $0.cost > $1.cost }

            return CredentialSummary(
                provider: key.provider,
                accountID: key.accountID,
                accountLabel: accountLabel,
                accountSource: accountSource,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: rows.count,
                modelBreakdown: modelBreakdown,
                provenanceConfidence: dominantConfidence,
                provenanceMethod: dominantMethod,
                hasEstimatedContributions: hasAnyEstimated,
                cacheEfficiency: CacheEfficiency.aggregate(rows)
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    /// Aggregates `token_usage` rows by `projectName` to power the "Spend by Project" lane.
    /// Mirrors `makeCredentialSummaries` but slices on the project dimension. Free-text
    /// project names are deduplicated by exact match (no case folding) so users see what
    /// the parsers actually wrote.
    static func makeProjectSpendSummaries(from usages: [TokenUsage]) -> [ProjectSpendSummary] {
        var groups: [String: [TokenUsage]] = [:]
        for usage in usages {
            let key = usage.projectName.isEmpty ? "Unattributed" : usage.projectName
            groups[key, default: []].append(usage)
        }

        return groups.compactMap { projectName, rows -> ProjectSpendSummary? in
            guard !rows.isEmpty else { return nil }

            let totalCost = rows.reduce(0) { $0 + $1.cost }
            let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = rows.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = rows.reduce(0) { $0 + $1.outputTokens }

            // Provider rollup within this project.
            let byProvider = Dictionary(grouping: rows) { $0.provider }
            let providerBreakdown = byProvider.map { provider, providerRows -> ProviderUsage in
                let providerCost = providerRows.reduce(0) { $0 + $1.cost }
                let providerTokens = providerRows.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: providerRows.count,
                    totalTokens: providerTokens,
                    cost: providerCost,
                    percentage: totalCost > 0 ? (providerCost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency.aggregate(providerRows)
                )
            }
            .sorted { $0.cost > $1.cost }

            // Model rollup within this project.
            var modelData: [String: ModelRollup] = [:]
            for usage in rows {
                let existing = modelData[usage.model]
                let newConfidence = usage.provenanceConfidence
                let newMethod = usage.provenanceMethod
                let bestConfidence: UsageProvenanceConfidence
                let bestMethod: UsageProvenanceMethod
                if let existingRec = existing {
                    bestConfidence = newConfidence > existingRec.bestConfidence ? newConfidence : existingRec.bestConfidence
                    if newConfidence == existingRec.bestConfidence {
                        bestMethod = newMethod.precedence > existingRec.bestMethod.precedence ? newMethod : existingRec.bestMethod
                    } else {
                        bestMethod = newConfidence > existingRec.bestConfidence ? newMethod : existingRec.bestMethod
                    }
                } else {
                    bestConfidence = newConfidence
                    bestMethod = newMethod
                }
                let rowIsEstimated = newConfidence != .exact && newConfidence != .derivedExact
                let existingHasEstimated = existing?.hasEstimated ?? false
                modelData[usage.model] = ModelRollup(
                    input: (existing?.input ?? 0) + usage.inputTokens,
                    output: (existing?.output ?? 0) + usage.outputTokens,
                    cacheCreation: (existing?.cacheCreation ?? 0) + usage.cacheCreationTokens,
                    cacheRead: (existing?.cacheRead ?? 0) + usage.cacheReadTokens,
                    reasoning: (existing?.reasoning ?? 0) + usage.reasoningTokens,
                    cost: (existing?.cost ?? 0) + usage.cost,
                    bestConfidence: bestConfidence,
                    bestMethod: bestMethod,
                    hasEstimated: existingHasEstimated || rowIsEstimated
                )
            }

            // Dominant provenance across this project's rows.
            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in rows {
                let rowIsEstimated = usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact
                hasAnyEstimated = hasAnyEstimated || rowIsEstimated
                let weight = usage.cost > 0 ? usage.cost : 0.001
                if usage.provenanceConfidence > dominantConfidence {
                    dominantConfidence = usage.provenanceConfidence
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                } else if usage.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                }
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.input + data.output + data.cacheCreation + data.cacheRead + data.reasoning
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.input,
                    outputTokens: data.output,
                    cacheCreationTokens: data.cacheCreation,
                    cacheReadTokens: data.cacheRead,
                    reasoningTokens: data.reasoning,
                    totalTokens: totalModelTokens,
                    cost: data.cost,
                    percentage: totalCost > 0 ? (data.cost / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }.sorted { $0.cost > $1.cost }

            return ProjectSpendSummary(
                projectName: projectName,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: rows.count,
                providerBreakdown: providerBreakdown,
                modelBreakdown: modelBreakdown,
                provenanceConfidence: dominantConfidence,
                provenanceMethod: dominantMethod,
                hasEstimatedContributions: hasAnyEstimated,
                cacheEfficiency: CacheEfficiency.aggregate(rows)
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    static func makeModelSummaries(from usages: [TokenUsage]) -> [ModelSummary] {
        let grouped = Dictionary(grouping: usages) {
            OpenBurnBarCore.TokenExtractionUtility.normalizeModelKey($0.model)
        }
        return grouped.compactMap { key, modelUsages -> ModelSummary? in
            guard !modelUsages.isEmpty else { return nil }
            let totalCost = modelUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = modelUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = modelUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = modelUsages.reduce(0) { $0 + $1.outputTokens }

            let byProvider = Dictionary(grouping: modelUsages) { $0.provider }
            let providerBreakdown = byProvider.map { provider, pUsages -> ProviderUsage in
                let pCost = pUsages.reduce(0) { $0 + $1.cost }
                let pTokens = pUsages.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: pUsages.count,
                    totalTokens: pTokens,
                    cost: pCost,
                    percentage: totalCost > 0 ? (pCost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency.aggregate(pUsages)
                )
            }.sorted { $0.cost > $1.cost }

            return ModelSummary(
                modelName: key,
                displayName: OpenBurnBarCore.TokenExtractionUtility.displayNameForModel(modelUsages.first?.model ?? key),
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: modelUsages.count,
                providerBreakdown: providerBreakdown,
                executionSourceBreakdown: ExecutionSourceUsage.aggregate(
                    modelUsages,
                    totalCost: totalCost
                ),
                cacheEfficiency: CacheEfficiency.aggregate(modelUsages)
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }
}
