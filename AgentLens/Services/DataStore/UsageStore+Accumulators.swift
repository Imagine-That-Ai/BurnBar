import Foundation
import GRDB
import OpenBurnBarCore

struct ProviderRunCostTotals: Equatable, Sendable {
    let sessionCount: Int
    let totalTokens: Int
    let totalCost: Double
}

struct UsageTotals { // pure-move: was private
    var sessionCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var reasoningTokens: Int
    var tokens: Int
    var cost: Double

    static let empty = UsageTotals(
        sessionCount: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        reasoningTokens: 0,
        tokens: 0,
        cost: 0
    )
}

struct UsageAggregateRow { // pure-move: was private
    let provider: AgentProvider
    let model: String
    let provenanceConfidence: UsageProvenanceConfidence
    let provenanceMethod: UsageProvenanceMethod
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double

    init?(row: Row) {
        guard let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let model = row["model"] as? String else { return nil }
        self.provider = provider
        self.model = model
        provenanceConfidence = (row["provenanceConfidence"] as? String)
            .flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        provenanceMethod = (row["provenanceMethod"] as? String)
            .flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
        sessionCount = UsageStore.intValue(row["sessionCount"])
        inputTokens = UsageStore.intValue(row["inputTokens"])
        outputTokens = UsageStore.intValue(row["outputTokens"])
        cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        totalTokens = UsageStore.intValue(row["totalTokens"])
        cost = UsageStore.doubleValue(row["cost"])
    }
}

struct ProviderSummaryAccumulator { // pure-move: was private
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var modelData: [String: ModelUsageAccumulator] = [:]
    var dominantConfidence: UsageProvenanceConfidence = .unknown
    var dominantMethod: UsageProvenanceMethod = .unknown
    var bestCostSoFar: Double = 0
    var hasAnyEstimated = false

    mutating func record(_ row: UsageAggregateRow) {
        totalCost += row.cost
        totalTokens += row.totalTokens
        totalInputTokens += row.inputTokens
        totalOutputTokens += row.outputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
        sessionCount += row.sessionCount
        modelData[row.model, default: ModelUsageAccumulator(modelName: row.model)].record(row)

        let estimated = row.provenanceConfidence != .exact && row.provenanceConfidence != .derivedExact
        hasAnyEstimated = hasAnyEstimated || estimated
        let weight = row.cost > 0 ? row.cost : 0.001
        if row.provenanceConfidence > dominantConfidence {
            dominantConfidence = row.provenanceConfidence
            dominantMethod = row.provenanceMethod
            bestCostSoFar = weight
        } else if row.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
            dominantMethod = row.provenanceMethod
            bestCostSoFar = weight
        }
    }

    func summary(for provider: AgentProvider) -> ProviderSummary? {
        guard sessionCount > 0 else { return nil }
        return ProviderSummary(
            provider: provider,
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: sessionCount,
            modelBreakdown: modelData.values
                .map { $0.modelUsage(providerTotalCost: totalCost) }
                .sorted { $0.cost > $1.cost },
            provenanceConfidence: dominantConfidence,
            provenanceMethod: dominantMethod,
            hasEstimatedContributions: hasAnyEstimated,
            cacheEfficiency: CacheEfficiency(
                inputTokens: totalInputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

private struct ModelUsageAccumulator {
    let modelName: String
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var reasoning = 0
    var totalTokens = 0
    var cost: Double = 0
    var bestConfidence: UsageProvenanceConfidence = .unknown
    var bestMethod: UsageProvenanceMethod = .unknown
    var hasEstimated = false

    mutating func record(_ row: UsageAggregateRow) {
        input += row.inputTokens
        output += row.outputTokens
        cacheCreation += row.cacheCreationTokens
        cacheRead += row.cacheReadTokens
        reasoning += row.reasoningTokens
        totalTokens += row.totalTokens
        cost += row.cost
        hasEstimated = hasEstimated || (row.provenanceConfidence != .exact && row.provenanceConfidence != .derivedExact)
        if row.provenanceConfidence > bestConfidence {
            bestConfidence = row.provenanceConfidence
            bestMethod = row.provenanceMethod
        } else if row.provenanceConfidence == bestConfidence,
                  row.provenanceMethod.precedence > bestMethod.precedence {
            bestMethod = row.provenanceMethod
        }
    }

    func modelUsage(providerTotalCost: Double) -> ModelUsage {
        ModelUsage(
            modelName: modelName,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            totalTokens: totalTokens,
            cost: cost,
            percentage: providerTotalCost > 0 ? (cost / providerTotalCost) * 100 : 0,
            provenanceConfidence: bestConfidence,
            provenanceMethod: bestMethod,
            hasEstimatedContributions: hasEstimated
        )
    }
}

struct ModelSummaryAccumulator { // pure-move: was private
    let modelName: String
    var displayModelName: String?
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var providerData: [AgentProvider: ProviderUsageAccumulator] = [:]

    mutating func record(_ row: UsageAggregateRow) {
        if displayModelName == nil {
            displayModelName = row.model
        }
        totalCost += row.cost
        totalTokens += row.totalTokens
        totalInputTokens += row.inputTokens
        totalOutputTokens += row.outputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
        sessionCount += row.sessionCount
        providerData[row.provider, default: ProviderUsageAccumulator(provider: row.provider)].record(row)
    }

    var summary: ModelSummary {
        ModelSummary(
            modelName: modelName,
            displayName: TokenExtractionUtility.displayNameForModel(displayModelName ?? modelName),
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: sessionCount,
            providerBreakdown: providerData.values
                .map { $0.providerUsage(modelTotalCost: totalCost) }
                .sorted { $0.cost > $1.cost },
            cacheEfficiency: CacheEfficiency(
                inputTokens: totalInputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

private struct ProviderUsageAccumulator {
    let provider: AgentProvider
    var sessionCount = 0
    var totalTokens = 0
    var cost: Double = 0
    var inputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0

    mutating func record(_ row: UsageAggregateRow) {
        sessionCount += row.sessionCount
        totalTokens += row.totalTokens
        cost += row.cost
        inputTokens += row.inputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
    }

    func providerUsage(modelTotalCost: Double) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            cost: cost,
            percentage: modelTotalCost > 0 ? (cost / modelTotalCost) * 100 : 0,
            cacheEfficiency: CacheEfficiency(
                inputTokens: inputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

struct DailySummaryAccumulator { // pure-move: was private
    let dayString: String
    var providerCosts: [AgentProvider: Double] = [:]
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var totalCacheCreationTokens = 0
    var totalCacheReadTokens = 0
    var totalTokens = 0
    var totalCost: Double = 0
    var sessionCount = 0
    var models: Set<String> = []

    mutating func record(row: Row, provider: AgentProvider, model: String) {
        let cost = UsageStore.doubleValue(row["cost"])
        providerCosts[provider, default: 0] += cost
        totalInputTokens += UsageStore.intValue(row["inputTokens"])
        totalOutputTokens += UsageStore.intValue(row["outputTokens"])
        totalCacheCreationTokens += UsageStore.intValue(row["cacheCreationTokens"])
        totalCacheReadTokens += UsageStore.intValue(row["cacheReadTokens"])
        totalTokens += UsageStore.intValue(row["totalTokens"])
        totalCost += cost
        sessionCount += UsageStore.intValue(row["sessionCount"])
        models.insert(model)
    }

    var summary: DailyUsageSummary? {
        guard let date = Self.dayFormatter.date(from: dayString) else { return nil }
        return DailyUsageSummary(
            date: date,
            provider: providerCosts.max { $0.value < $1.value }?.key ?? .factory,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalTokens: totalTokens,
            totalCost: totalCost,
            sessionCount: sessionCount,
            models: Array(models)
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
