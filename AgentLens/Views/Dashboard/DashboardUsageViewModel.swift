import Foundation
import SwiftUI
import OpenBurnBarCore

// MARK: - Dashboard Usage ViewModel

/// Presentation-layer view model that aggregates raw `[TokenUsage]` into
/// dashboard-ready metrics (cost totals, mood, sparklines, provider/model summaries).
/// Owned by `DashboardView`; rebuilt whenever `DataStore.replaceUsages` fires.
@Observable
@MainActor
final class DashboardUsageViewModel {

    // MARK: - Aggregate Cache

    private struct UsageAggregateCache {
        let totalCostToday: Double
        let totalCostThisWeek: Double
        let totalCostThisMonth: Double
        let totalCostAllTime: Double
        let totalTokensToday: Int
        let totalTokensThisWeek: Int
        let totalTokensThisMonth: Int
        let totalTokensAllTime: Int
        let rollingDailyAverage: Double
        let distinctUsageDayCount: Int
        let last7DayCosts: [Double]
        let last7DayTokenTotals: [Int]
        let providerSummaries: [ProviderSummary]
        let modelSummaries: [ModelSummary]
        let topProviderToday: (provider: AgentProvider, cost: Double)?

        static let empty = UsageAggregateCache(
            totalCostToday: 0,
            totalCostThisWeek: 0,
            totalCostThisMonth: 0,
            totalCostAllTime: 0,
            totalTokensToday: 0,
            totalTokensThisWeek: 0,
            totalTokensThisMonth: 0,
            totalTokensAllTime: 0,
            rollingDailyAverage: 0,
            distinctUsageDayCount: 0,
            last7DayCosts: Array(repeating: 0, count: 7),
            last7DayTokenTotals: Array(repeating: 0, count: 7),
            providerSummaries: [],
            modelSummaries: [],
            topProviderToday: nil
        )
    }

    // MARK: - State

    private(set) var usages: [TokenUsage] = []
    private var aggregateCache: UsageAggregateCache = .empty

    // MARK: - Cost Totals

    var totalCostToday: Double { aggregateCache.totalCostToday }
    var totalCostThisWeek: Double { aggregateCache.totalCostThisWeek }
    var totalCostThisMonth: Double { aggregateCache.totalCostThisMonth }
    var totalCostAllTime: Double { aggregateCache.totalCostAllTime }

    var totalTokensToday: Int { aggregateCache.totalTokensToday }
    var totalTokensThisWeek: Int { aggregateCache.totalTokensThisWeek }
    var totalTokensThisMonth: Int { aggregateCache.totalTokensThisMonth }
    var totalTokensAllTime: Int { aggregateCache.totalTokensAllTime }

    var rollingDailyAverage: Double { aggregateCache.rollingDailyAverage }

    // MARK: - Sparklines

    var last7DayCosts: [Double] { aggregateCache.last7DayCosts }
    var last7DayTokenTotals: [Int] { aggregateCache.last7DayTokenTotals }

    // MARK: - Summaries

    var providerSummaries: [ProviderSummary] { aggregateCache.providerSummaries }
    var modelSummaries: [ModelSummary] { aggregateCache.modelSummaries }

    var hasEstimatedProviders: Bool {
        providerSummaries.contains { $0.provider.dataConfidence != .exact }
    }

    func providerSummaries(in dateRange: ClosedRange<Date>?) -> [ProviderSummary] {
        Self.makeProviderSummaries(from: usages(in: dateRange))
    }

    func modelSummaries(in dateRange: ClosedRange<Date>?) -> [ModelSummary] {
        Self.makeModelSummaries(from: usages(in: dateRange))
    }

    func topProviderToday() -> (provider: AgentProvider, cost: Double)? {
        aggregateCache.topProviderToday
    }

    // MARK: - Mood

    var moodBand: MoodBand {
        guard aggregateCache.distinctUsageDayCount >= 2 else { return .baseline }
        let today = totalCostToday
        guard today > 0 else { return .quiet }
        guard rollingDailyAverage > 0 else { return .onPace }
        switch today / rollingDailyAverage {
        case ..<0.8: return .light
        case 0.8..<1.2: return .onPace
        default: return .heavy
        }
    }

    var moodLabel: String {
        switch moodBand {
        case .light: return "Light day"
        case .onPace: return "On pace"
        case .heavy: return "Heavy day"
        case .baseline: return "Building baseline..."
        case .quiet: return "Quiet day"
        }
    }

    var moodColor: Color {
        switch moodBand {
        case .light: return DesignSystem.Colors.success
        case .onPace: return DesignSystem.Colors.textSecondary
        case .heavy: return DesignSystem.Colors.warning
        case .baseline, .quiet: return DesignSystem.Colors.textMuted
        }
    }

    // MARK: - Daily Summaries

    var dailySummaries: [DailyUsageSummary] {
        let calendar = Calendar.current
        var dayData: [Date: [TokenUsage]] = [:]

        for usage in usages {
            let dayKey = calendar.startOfDay(for: usage.startTime)
            dayData[dayKey, default: []].append(usage)
        }

        return dayData.map { date, dayUsages in
            DailyUsageSummary(
                date: date,
                provider: dayUsages.first?.provider ?? .factory,
                totalInputTokens: dayUsages.reduce(0) { $0 + $1.inputTokens },
                totalOutputTokens: dayUsages.reduce(0) { $0 + $1.outputTokens },
                totalCacheCreationTokens: dayUsages.reduce(0) { $0 + $1.cacheCreationTokens },
                totalCacheReadTokens: dayUsages.reduce(0) { $0 + $1.cacheReadTokens },
                totalTokens: dayUsages.reduce(0) { $0 + $1.totalTokens },
                totalCost: dayUsages.reduce(0) { $0 + $1.cost },
                sessionCount: dayUsages.count,
                models: Array(Set(dayUsages.map { $0.model }))
            )
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: - Filtering

    func usages(in dateRange: ClosedRange<Date>?) -> [TokenUsage] {
        guard let dateRange else { return usages }
        return usages.filter { $0.intersects(dateRange: dateRange) }
    }

    func usages(for provider: AgentProvider) -> [TokenUsage] {
        usages.filter { $0.provider == provider }
    }

    func usages(for provider: AgentProvider, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter { $0.provider == provider && $0.intersects(dateRange: dateRange) }
    }

    func usages(forModel normalizedName: String) -> [TokenUsage] {
        usages.filter { TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName }
    }

    func usages(forModel normalizedName: String, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter {
            TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName
            && $0.intersects(dateRange: dateRange)
        }
    }

    // MARK: - Update

    func replaceUsages(_ newUsages: [TokenUsage]) {
        let sortedUsages = newUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        aggregateCache = rebuildAggregateCache(from: sortedUsages)
    }

    // MARK: - Aggregate Cache Rebuild

    private func rebuildAggregateCache(from usages: [TokenUsage]) -> UsageAggregateCache {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) ?? now

        var totalCostToday: Double = 0
        var totalCostThisWeek: Double = 0
        var totalCostThisMonth: Double = 0
        var totalCostAllTime: Double = 0

        var totalTokensToday = 0
        var totalTokensThisWeek = 0
        var totalTokensThisMonth = 0
        var totalTokensAllTime = 0

        var distinctDays = Set<Date>()
        var dayCost: [Date: Double] = [:]
        var dayTokens: [Date: Int] = [:]
        var todayProviderCost: [AgentProvider: Double] = [:]

        for usage in usages {
            totalCostAllTime += usage.cost
            totalTokensAllTime += usage.totalTokens

            let dayStart = calendar.startOfDay(for: usage.startTime)
            distinctDays.insert(dayStart)
            dayCost[dayStart, default: 0] += usage.cost
            dayTokens[dayStart, default: 0] += usage.totalTokens

            if usage.startTime >= weekAgo {
                totalCostThisWeek += usage.cost
                totalTokensThisWeek += usage.totalTokens
            }
            if usage.startTime >= monthAgo {
                totalCostThisMonth += usage.cost
                totalTokensThisMonth += usage.totalTokens
            }
            if calendar.isDateInToday(usage.startTime) {
                totalCostToday += usage.cost
                totalTokensToday += usage.totalTokens
                todayProviderCost[usage.provider, default: 0] += usage.cost
            }
        }

        var rollingDailyTotal: Double = 0
        for dayOffset in 1...7 {
            if let day = calendar.date(byAdding: .day, value: -dayOffset, to: todayStart) {
                rollingDailyTotal += dayCost[day, default: 0]
            }
        }
        let rollingDailyAverage = rollingDailyTotal / 7

        let last7DayCosts = (0..<7).reversed().map { offset -> Double in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return 0 }
            return dayCost[day, default: 0]
        }
        let last7DayTokenTotals = (0..<7).reversed().map { offset -> Int in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return 0 }
            return dayTokens[day, default: 0]
        }

        let topProviderToday = todayProviderCost
            .max { $0.value < $1.value }
            .map { ($0.key, $0.value) }

        return UsageAggregateCache(
            totalCostToday: totalCostToday,
            totalCostThisWeek: totalCostThisWeek,
            totalCostThisMonth: totalCostThisMonth,
            totalCostAllTime: totalCostAllTime,
            totalTokensToday: totalTokensToday,
            totalTokensThisWeek: totalTokensThisWeek,
            totalTokensThisMonth: totalTokensThisMonth,
            totalTokensAllTime: totalTokensAllTime,
            rollingDailyAverage: rollingDailyAverage,
            distinctUsageDayCount: distinctDays.count,
            last7DayCosts: last7DayCosts,
            last7DayTokenTotals: last7DayTokenTotals,
            providerSummaries: Self.makeProviderSummaries(from: usages),
            modelSummaries: Self.makeModelSummaries(from: usages),
            topProviderToday: topProviderToday
        )
    }

    // MARK: - Provider Summary Builder

    static func makeProviderSummaries(from usages: [TokenUsage]) -> [ProviderSummary] {
        AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            let providerUsages = usages.filter { $0.provider == provider }
            guard !providerUsages.isEmpty else { return nil }

            let totalCost = providerUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = providerUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = providerUsages.reduce(0) { $0 + $1.outputTokens }

            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, reasoning: Int, cost: Double, bestConfidence: UsageProvenanceConfidence, bestMethod: UsageProvenanceMethod, hasEstimated: Bool)] = [:]
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
                modelData[usage.model] = (
                    (existing?.0 ?? 0) + usage.inputTokens,
                    (existing?.1 ?? 0) + usage.outputTokens,
                    (existing?.2 ?? 0) + usage.cacheCreationTokens,
                    (existing?.3 ?? 0) + usage.cacheReadTokens,
                    (existing?.4 ?? 0) + usage.reasoningTokens,
                    (existing?.5 ?? 0) + usage.cost,
                    bestConfidence,
                    bestMethod,
                    existingHasEstimated || rowIsEstimated
                )
            }

            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in providerUsages {
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
                let totalModelTokens = data.0 + data.1 + data.2 + data.3 + data.4
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.0,
                    outputTokens: data.1,
                    cacheCreationTokens: data.2,
                    cacheReadTokens: data.3,
                    reasoningTokens: data.4,
                    totalTokens: totalModelTokens,
                    cost: data.5,
                    percentage: totalCost > 0 ? (data.5 / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }
            .sorted { $0.cost > $1.cost }

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
                hasEstimatedContributions: hasAnyEstimated
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Model Summary Builder

    static func makeModelSummaries(from usages: [TokenUsage]) -> [ModelSummary] {
        let grouped = Dictionary(grouping: usages) {
            TokenExtractionUtility.normalizeModelKey($0.model)
        }

        return grouped.compactMap { key, modelUsages -> ModelSummary? in
            guard !modelUsages.isEmpty else { return nil }

            let totalCost = modelUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = modelUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = modelUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = modelUsages.reduce(0) { $0 + $1.outputTokens }

            let byProvider = Dictionary(grouping: modelUsages) { $0.provider }
            let providerBreakdown = byProvider.map { provider, providerUsages -> ProviderUsage in
                let providerCost = providerUsages.reduce(0) { $0 + $1.cost }
                let providerTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: providerUsages.count,
                    totalTokens: providerTokens,
                    cost: providerCost,
                    percentage: totalCost > 0 ? (providerCost / totalCost) * 100 : 0
                )
            }
            .sorted { $0.cost > $1.cost }

            return ModelSummary(
                modelName: key,
                displayName: TokenExtractionUtility.displayNameForModel(modelUsages.first?.model ?? key),
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: modelUsages.count,
                providerBreakdown: providerBreakdown
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }
}
