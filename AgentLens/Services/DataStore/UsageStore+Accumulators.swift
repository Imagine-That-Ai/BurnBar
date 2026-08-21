import Foundation
import GRDB
import OpenBurnBarCore

struct ProviderRunCostTotals: Equatable, Sendable {
    let sessionCount: Int
    let totalTokens: Int
    let totalCost: Double
}

struct UsageCostBreakdown: Equatable, Sendable {
    let sessionCount: Int
    let totalTokens: Int
    let totalCost: Double
    let modelCosts: [UsageCostBucket]
    let projectCosts: [UsageCostBucket]
}

struct UsageCostBucket: Equatable, Sendable {
    let label: String
    let cost: Double
}

struct UsageTotals: Equatable, Sendable { // pure-move: was private
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

struct UsageAggregateRow: Equatable { // pure-move: was private
    let provider: AgentProvider
    let model: String
    let executionSourceID: String
    let executionSourceName: String
    let executionSourceKind: UsageExecutionSourceKind
    let executionSourceConfidence: UsageProvenanceConfidence
    let provenanceConfidence: UsageProvenanceConfidence
    let provenanceMethod: UsageProvenanceMethod
    let projectName: String
    let providerAccountID: String?
    let providerAccountLabel: String?
    let providerAccountSource: ProviderAccountStorageScope?
    let latestStartTime: Date
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
              let provider = AgentProvider.resolve(providerRaw),
              let model = row["model"] as? String else { return nil }
        self.provider = provider
        self.model = model
        executionSourceID = row["executionSourceID"] as? String ?? "unknown"
        executionSourceName = row["executionSourceName"] as? String ?? "Unknown"
        executionSourceKind = (row["executionSourceKind"] as? String)
            .flatMap { UsageExecutionSourceKind(rawValue: $0) } ?? .unknown
        executionSourceConfidence = (row["executionSourceConfidence"] as? String)
            .flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        provenanceConfidence = (row["provenanceConfidence"] as? String)
            .flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        provenanceMethod = (row["provenanceMethod"] as? String)
            .flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
        projectName = row["projectName"] as? String ?? ""
        providerAccountID = row["providerAccountID"] as? String
        providerAccountLabel = row["providerAccountLabel"] as? String
        providerAccountSource = (row["providerAccountSource"] as? String)
            .flatMap { ProviderAccountStorageScope(rawValue: $0) }
        latestStartTime = OpenBurnBarDatabase.parseDateValue(row["latestStartTime"]) ?? .distantPast
        sessionCount = UsageStore.intValue(row["sessionCount"])
        inputTokens = UsageStore.intValue(row["inputTokens"])
        outputTokens = UsageStore.intValue(row["outputTokens"])
        cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        totalTokens = UsageStore.intValue(row["totalTokens"])
        cost = UsageStore.doubleValue(row["cost"])
    }

    init(
        provider: AgentProvider,
        model: String,
        executionSourceID: String,
        executionSourceName: String,
        executionSourceKind: UsageExecutionSourceKind,
        executionSourceConfidence: UsageProvenanceConfidence,
        provenanceConfidence: UsageProvenanceConfidence,
        provenanceMethod: UsageProvenanceMethod,
        projectName: String = "",
        providerAccountID: String? = nil,
        providerAccountLabel: String? = nil,
        providerAccountSource: ProviderAccountStorageScope? = nil,
        latestStartTime: Date,
        sessionCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int,
        totalTokens: Int,
        cost: Double
    ) {
        self.provider = provider
        self.model = model
        self.executionSourceID = executionSourceID
        self.executionSourceName = executionSourceName
        self.executionSourceKind = executionSourceKind
        self.executionSourceConfidence = executionSourceConfidence
        self.provenanceConfidence = provenanceConfidence
        self.provenanceMethod = provenanceMethod
        self.projectName = projectName
        self.providerAccountID = providerAccountID
        self.providerAccountLabel = providerAccountLabel
        self.providerAccountSource = providerAccountSource
        self.latestStartTime = latestStartTime
        self.sessionCount = sessionCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.cost = cost
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
    fileprivate var modelData: [String: ModelUsageAccumulator] = [:]
    var dominantConfidence: UsageProvenanceConfidence = .unknown
    var dominantMethod: UsageProvenanceMethod = .unknown
    var bestCostSoFar: Double = 0
    var hasAnyEstimated = false

    init() {}

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

struct CredentialSummaryAccumulator {
    var accountLabel = ""
    var accountSource: ProviderAccountStorageScope?
    private var accountLabelTimestamp = Date.distantPast
    private var accountSourceTimestamp = Date.distantPast
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    fileprivate var modelData: [String: ModelUsageAccumulator] = [:]
    var dominantConfidence: UsageProvenanceConfidence = .unknown
    var dominantMethod: UsageProvenanceMethod = .unknown
    var bestCostSoFar: Double = 0
    var hasAnyEstimated = false

    init() {}

    mutating func record(_ row: UsageAggregateRow) {
        if let label = row.providerAccountLabel,
           !label.isEmpty,
           row.latestStartTime > accountLabelTimestamp
               || (row.latestStartTime == accountLabelTimestamp
                   && (accountLabel.isEmpty || label < accountLabel)) {
            accountLabel = label
            accountLabelTimestamp = row.latestStartTime
        }
        if let source = row.providerAccountSource,
           row.latestStartTime > accountSourceTimestamp
               || (row.latestStartTime == accountSourceTimestamp
                   && (accountSource == nil || source.rawValue < accountSource?.rawValue ?? "")) {
            accountSource = source
            accountSourceTimestamp = row.latestStartTime
        }
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

    func summary(for provider: AgentProvider, accountID: String?) -> CredentialSummary? {
        guard sessionCount > 0 else { return nil }
        let resolvedLabel: String = {
            if !accountLabel.isEmpty { return accountLabel }
            if let id = accountID, !id.isEmpty {
                return "\(provider.displayName) · …\(id.suffix(6))"
            }
            return "\(provider.displayName) · default"
        }()
        return CredentialSummary(
            provider: provider,
            accountID: accountID,
            accountLabel: resolvedLabel,
            accountSource: accountSource,
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

private struct ProjectProviderRollup {
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
}

struct ProjectSpendSummaryAccumulator {
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    fileprivate var modelData: [String: ModelUsageAccumulator] = [:]
    private var providerData: [AgentProvider: ProjectProviderRollup] = [:]
    var dominantConfidence: UsageProvenanceConfidence = .unknown
    var dominantMethod: UsageProvenanceMethod = .unknown
    var bestCostSoFar: Double = 0
    var hasAnyEstimated = false

    init() {}

    mutating func record(_ row: UsageAggregateRow) {
        totalCost += row.cost
        totalTokens += row.totalTokens
        totalInputTokens += row.inputTokens
        totalOutputTokens += row.outputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
        sessionCount += row.sessionCount
        modelData[row.model, default: ModelUsageAccumulator(modelName: row.model)].record(row)
        providerData[row.provider, default: ProjectProviderRollup()].record(row)

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

    func summary(projectName: String) -> ProjectSpendSummary? {
        guard sessionCount > 0 else { return nil }
        return ProjectSpendSummary(
            projectName: projectName,
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: sessionCount,
            providerBreakdown: providerData.map { provider, rollup in
                ProviderUsage(
                    provider: provider,
                    sessionCount: rollup.sessionCount,
                    totalTokens: rollup.totalTokens,
                    cost: rollup.cost,
                    percentage: totalCost > 0 ? (rollup.cost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency(
                        inputTokens: rollup.inputTokens,
                        cacheCreationTokens: rollup.cacheCreationTokens,
                        cacheReadTokens: rollup.cacheReadTokens
                    )
                )
            }
            .sorted { $0.cost > $1.cost },
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
    fileprivate var providerData: [AgentProvider: ProviderUsageAccumulator] = [:]
    fileprivate var executionSourceData: [String: ExecutionSourceUsageAccumulator] = [:]

    init(modelName: String) {
        self.modelName = modelName
    }

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
        executionSourceData[
            row.executionSourceID,
            default: ExecutionSourceUsageAccumulator(
                executionSourceID: row.executionSourceID,
                name: row.executionSourceName,
                kind: row.executionSourceKind
            )
        ].record(row)
    }

    var summary: ModelSummary {
        ModelSummary(
            modelName: modelName,
            displayName: OpenBurnBarCore.TokenExtractionUtility.displayNameForModel(displayModelName ?? modelName),
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: sessionCount,
            providerBreakdown: providerData.values
                .map { $0.providerUsage(modelTotalCost: totalCost) }
                .sorted { $0.cost > $1.cost },
            executionSourceBreakdown: executionSourceData.values
                .map { $0.usage(modelTotalCost: totalCost) }
                .sorted { $0.cost > $1.cost },
            cacheEfficiency: CacheEfficiency(
                inputTokens: totalInputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

private struct ExecutionSourceUsageAccumulator {
    let executionSourceID: String
    var name: String
    var kind: UsageExecutionSourceKind
    var confidence: UsageProvenanceConfidence = .unknown
    var sessionCount = 0
    var totalTokens = 0
    var cost: Double = 0
    var inputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0

    mutating func record(_ row: UsageAggregateRow) {
        if name == "Unknown", row.executionSourceName != "Unknown" { name = row.executionSourceName }
        if kind == .unknown, row.executionSourceKind != .unknown { kind = row.executionSourceKind }
        confidence = max(confidence, row.executionSourceConfidence)
        sessionCount += row.sessionCount
        totalTokens += row.totalTokens
        cost += row.cost
        inputTokens += row.inputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
    }

    func usage(modelTotalCost: Double) -> ExecutionSourceUsage {
        ExecutionSourceUsage(
            executionSourceID: executionSourceID,
            name: name,
            kind: kind,
            confidence: confidence,
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
    let dateOverride: Date?
    var providerCosts: [AgentProvider: Double] = [:]
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var totalCacheCreationTokens = 0
    var totalCacheReadTokens = 0
    var totalTokens = 0
    var totalCost: Double = 0
    var sessionCount = 0
    var models: Set<String> = []

    init(dayString: String, date: Date? = nil) {
        self.dayString = dayString
        self.dateOverride = date
    }

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
        let date = dateOverride ?? OpenBurnBarDatabase.parseDateValue(dayString)
        guard let date else { return nil }
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
            models: models.sorted()
        )
    }
}
