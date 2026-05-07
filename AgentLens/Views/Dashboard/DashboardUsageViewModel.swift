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
        let dailySummaries: [DailyUsageSummary]
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
            dailySummaries: [],
            providerSummaries: [],
            modelSummaries: [],
            topProviderToday: nil
        )
    }

    private struct DateRangeCacheKey: Hashable {
        let lower: Int64?
        let upper: Int64?

        init(_ dateRange: ClosedRange<Date>?) {
            lower = dateRange?.lowerBound.cacheBucket
            upper = dateRange?.upperBound.cacheBucket
        }
    }

    // MARK: - State

    private(set) var usages: [TokenUsage] = []
    private var aggregateCache: UsageAggregateCache = .empty
    private var windowSummaryCache: [DateRangeCacheKey: DashboardUsageWindowSummary] = [:]
    private var canonicalWindowSummaries: [TimeRange: DashboardUsageWindowSummary] = [:]

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
        windowSummary(in: dateRange).providerSummaries
    }

    func providerSummaries(for timeRange: TimeRange) -> [ProviderSummary] {
        windowSummary(for: timeRange).providerSummaries
    }

    func modelSummaries(in dateRange: ClosedRange<Date>?) -> [ModelSummary] {
        windowSummary(in: dateRange).modelSummaries
    }

    func modelSummaries(for timeRange: TimeRange) -> [ModelSummary] {
        windowSummary(for: timeRange).modelSummaries
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
        aggregateCache.dailySummaries
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

    // MARK: - Cache Efficiency

    /// Aggregate cache reuse across every row in the optional date range.
    /// Used for the dashboard hero so users see a single window-level cache hit rate.
    func cacheEfficiency(in dateRange: ClosedRange<Date>?) -> CacheEfficiency {
        windowSummary(in: dateRange).cacheEfficiency
    }

    func cacheEfficiency(for timeRange: TimeRange) -> CacheEfficiency {
        windowSummary(for: timeRange).cacheEfficiency
    }

    func windowSummary(for timeRange: TimeRange) -> DashboardUsageWindowSummary {
        canonicalWindowSummaries[timeRange] ?? windowSummary(in: timeRange.dateRange())
    }

    func windowSummary(in dateRange: ClosedRange<Date>?) -> DashboardUsageWindowSummary {
        let key = DateRangeCacheKey(dateRange)
        if let cached = windowSummaryCache[key] {
            return cached
        }

        let filteredUsages = usages(in: dateRange)
        let summary = DashboardUsageWindowSummary(
            usages: filteredUsages,
            totalCost: filteredUsages.reduce(0) { $0 + $1.cost },
            totalTokens: filteredUsages.reduce(0) { $0 + $1.totalTokens },
            sessionCount: filteredUsages.count,
            activeProviderCount: Set(filteredUsages.map(\.provider)).count,
            providerSummaries: Self.makeProviderSummaries(from: filteredUsages),
            modelSummaries: Self.makeModelSummaries(from: filteredUsages),
            cacheEfficiency: CacheEfficiency.aggregate(filteredUsages)
        )
        windowSummaryCache[key] = summary
        return summary
    }

    // MARK: - Update

    func replaceUsages(_ newUsages: [TokenUsage]) {
        let sortedUsages = newUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        canonicalWindowSummaries.removeAll(keepingCapacity: true)
        windowSummaryCache.removeAll(keepingCapacity: true)
        aggregateCache = rebuildAggregateCache(from: sortedUsages)
    }

    func replaceUsageSnapshot(_ snapshot: DashboardUsageSnapshot) {
        usages = snapshot.loadedUsages.sorted { $0.startTime > $1.startTime }
        canonicalWindowSummaries = snapshot.windowSummaries
        windowSummaryCache.removeAll(keepingCapacity: true)

        let today = snapshot.windowSummaries[.today] ?? .empty
        let last7Days = snapshot.windowSummaries[.last7Days] ?? .empty
        let last30Days = snapshot.windowSummaries[.last30Days] ?? .empty
        let allTime = snapshot.windowSummaries[.allTime] ?? .empty

        aggregateCache = UsageAggregateCache(
            totalCostToday: today.totalCost,
            totalCostThisWeek: last7Days.totalCost,
            totalCostThisMonth: last30Days.totalCost,
            totalCostAllTime: allTime.totalCost,
            totalTokensToday: today.totalTokens,
            totalTokensThisWeek: last7Days.totalTokens,
            totalTokensThisMonth: last30Days.totalTokens,
            totalTokensAllTime: allTime.totalTokens,
            rollingDailyAverage: snapshot.rollingDailyAverage,
            distinctUsageDayCount: snapshot.distinctUsageDayCount,
            last7DayCosts: snapshot.last7DayCosts,
            last7DayTokenTotals: snapshot.last7DayTokenTotals,
            dailySummaries: snapshot.dailySummaries,
            providerSummaries: allTime.providerSummaries,
            modelSummaries: allTime.modelSummaries,
            topProviderToday: snapshot.topProviderToday
        )
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
        var dailyAccumulator: [Date: DailyAccumulator] = [:]
        var todayProviderCost: [AgentProvider: Double] = [:]

        for usage in usages {
            totalCostAllTime += usage.cost
            totalTokensAllTime += usage.totalTokens

            let dayStart = calendar.startOfDay(for: usage.startTime)
            distinctDays.insert(dayStart)
            dayCost[dayStart, default: 0] += usage.cost
            dayTokens[dayStart, default: 0] += usage.totalTokens
            dailyAccumulator[dayStart, default: DailyAccumulator(date: dayStart)].record(usage)

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
            dailySummaries: dailyAccumulator.values
                .map(\.summary)
                .sorted { $0.date > $1.date },
            providerSummaries: Self.makeProviderSummaries(from: usages),
            modelSummaries: Self.makeModelSummaries(from: usages),
            topProviderToday: topProviderToday
        )
    }

    // MARK: - Provider Summary Builder

    static func makeProviderSummaries(from usages: [TokenUsage]) -> [ProviderSummary] {
        var providers: [AgentProvider: ProviderAccumulator] = [:]
        for usage in usages {
            providers[usage.provider, default: ProviderAccumulator()].record(usage)
        }

        return providers.compactMap { provider, accumulator in
            accumulator.summary(for: provider)
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
                    percentage: totalCost > 0 ? (providerCost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency.aggregate(providerUsages)
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
                providerBreakdown: providerBreakdown,
                cacheEfficiency: CacheEfficiency.aggregate(modelUsages)
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }
}

// MARK: - Dashboard Cached Window Summary

struct DashboardUsageWindowSummary {
    let usages: [TokenUsage]
    let totalCost: Double
    let totalTokens: Int
    let sessionCount: Int
    let activeProviderCount: Int
    let providerSummaries: [ProviderSummary]
    let modelSummaries: [ModelSummary]
    let cacheEfficiency: CacheEfficiency

    static let empty = DashboardUsageWindowSummary(
        usages: [],
        totalCost: 0,
        totalTokens: 0,
        sessionCount: 0,
        activeProviderCount: 0,
        providerSummaries: [],
        modelSummaries: [],
        cacheEfficiency: .zero
    )
}

struct DashboardUsageSnapshot {
    let loadedUsages: [TokenUsage]
    let windowSummaries: [TimeRange: DashboardUsageWindowSummary]
    let rollingDailyAverage: Double
    let distinctUsageDayCount: Int
    let last7DayCosts: [Double]
    let last7DayTokenTotals: [Int]
    let dailySummaries: [DailyUsageSummary]
    let topProviderToday: (provider: AgentProvider, cost: Double)?
}

private extension Date {
    var cacheBucket: Int64 {
        Int64((timeIntervalSinceReferenceDate * 10).rounded(.down))
    }
}

private struct DailyAccumulator {
    let date: Date
    var provider: AgentProvider = .factory
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var totalCacheCreationTokens = 0
    var totalCacheReadTokens = 0
    var totalTokens = 0
    var totalCost: Double = 0
    var sessionCount = 0
    var models: Set<String> = []

    mutating func record(_ usage: TokenUsage) {
        if sessionCount == 0 {
            provider = usage.provider
        }
        totalInputTokens += usage.inputTokens
        totalOutputTokens += usage.outputTokens
        totalCacheCreationTokens += usage.cacheCreationTokens
        totalCacheReadTokens += usage.cacheReadTokens
        totalTokens += usage.totalTokens
        totalCost += usage.cost
        sessionCount += 1
        models.insert(usage.model)
    }

    var summary: DailyUsageSummary {
        DailyUsageSummary(
            date: date,
            provider: provider,
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
}

private struct ProviderAccumulator {
    var usages: [TokenUsage] = []
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var modelData: [String: ModelAccumulator] = [:]
    var dominantConfidence: UsageProvenanceConfidence = .unknown
    var dominantMethod: UsageProvenanceMethod = .unknown
    var bestCostSoFar: Double = 0
    var hasAnyEstimated = false

    mutating func record(_ usage: TokenUsage) {
        usages.append(usage)
        totalCost += usage.cost
        totalTokens += usage.totalTokens
        totalInputTokens += usage.inputTokens
        totalOutputTokens += usage.outputTokens
        modelData[usage.model, default: ModelAccumulator()].record(usage)

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

    func summary(for provider: AgentProvider) -> ProviderSummary? {
        guard !usages.isEmpty else { return nil }
        let modelBreakdown = modelData.map { modelName, data in
            data.modelUsage(modelName: modelName, providerTotalCost: totalCost)
        }
        .sorted { $0.cost > $1.cost }

        return ProviderSummary(
            provider: provider,
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: usages.count,
            modelBreakdown: modelBreakdown,
            provenanceConfidence: dominantConfidence,
            provenanceMethod: dominantMethod,
            hasEstimatedContributions: hasAnyEstimated,
            cacheEfficiency: CacheEfficiency.aggregate(usages)
        )
    }
}

private struct ModelAccumulator {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var reasoning = 0
    var cost: Double = 0
    var bestConfidence: UsageProvenanceConfidence = .unknown
    var bestMethod: UsageProvenanceMethod = .unknown
    var hasEstimated = false

    mutating func record(_ usage: TokenUsage) {
        input += usage.inputTokens
        output += usage.outputTokens
        cacheCreation += usage.cacheCreationTokens
        cacheRead += usage.cacheReadTokens
        reasoning += usage.reasoningTokens
        cost += usage.cost
        hasEstimated = hasEstimated || (usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact)

        if usage.provenanceConfidence > bestConfidence {
            bestConfidence = usage.provenanceConfidence
            bestMethod = usage.provenanceMethod
        } else if usage.provenanceConfidence == bestConfidence,
                  usage.provenanceMethod.precedence > bestMethod.precedence {
            bestMethod = usage.provenanceMethod
        }
    }

    func modelUsage(modelName: String, providerTotalCost: Double) -> ModelUsage {
        let totalModelTokens = input + output + cacheCreation + cacheRead + reasoning
        return ModelUsage(
            modelName: modelName,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            totalTokens: totalModelTokens,
            cost: cost,
            percentage: providerTotalCost > 0 ? (cost / providerTotalCost) * 100 : 0,
            provenanceConfidence: bestConfidence,
            provenanceMethod: bestMethod,
            hasEstimatedContributions: hasEstimated
        )
    }
}
