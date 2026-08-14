import Foundation
import OpenBurnBarKernel

/// Calendar-day membership for usage rows, matching `UsageStore.intersectionSQL`.
///
/// A session counts on every local calendar day its `[startTime, endTime]`
/// interval overlaps. Inverted start/end is handled by the same predicate
/// the last-7-day SQL flags use.
enum UsageDayIntersection {
    static func sessionOverlapsDay(
        startTime: Date,
        endTime: Date,
        dayStart: Date,
        nextDay: Date
    ) -> Bool {
        (startTime <= nextDay && endTime >= dayStart)
            || (endTime <= nextDay && startTime >= dayStart)
    }

    static func overlappingDayStarts(
        startTime: Date,
        endTime: Date,
        calendar: Calendar
    ) -> [Date] {
        let lower = calendar.startOfDay(for: min(startTime, endTime))
        let upper = calendar.startOfDay(for: max(startTime, endTime))
        var days: [Date] = []
        var day = lower
        while day <= upper {
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
               sessionOverlapsDay(
                   startTime: startTime,
                   endTime: endTime,
                   dayStart: day,
                   nextDay: nextDay
               ) {
                days.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            if next <= day { break }
            day = next
        }
        return days
    }

    struct UsageRow {
        let startTime: Date
        let endTime: Date
        let provider: AgentProvider
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
        let cost: Double

        init(
            startTime: Date,
            endTime: Date,
            provider: AgentProvider,
            model: String,
            inputTokens: Int,
            outputTokens: Int,
            cacheCreationTokens: Int,
            cacheReadTokens: Int,
            totalTokens: Int,
            cost: Double
        ) {
            self.startTime = startTime
            self.endTime = endTime
            self.provider = provider
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.cacheReadTokens = cacheReadTokens
            self.totalTokens = totalTokens
            self.cost = cost
        }

        init(_ usage: TokenUsage) {
            self.init(
                startTime: usage.startTime,
                endTime: usage.endTime,
                provider: usage.provider,
                model: usage.model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens,
                totalTokens: usage.totalTokens,
                cost: usage.cost
            )
        }
    }

    static func summaries(
        from usages: [TokenUsage],
        calendar: Calendar
    ) -> [DailyUsageSummary] {
        summaries(from: usages.map(UsageRow.init), calendar: calendar)
    }

    static func summaries(
        from rows: [UsageRow],
        calendar: Calendar
    ) -> [DailyUsageSummary] {
        var buckets: [Date: DayBucket] = [:]
        for row in rows {
            for day in overlappingDayStarts(
                startTime: row.startTime,
                endTime: row.endTime,
                calendar: calendar
            ) {
                buckets[day, default: DayBucket(date: day)].record(row)
            }
        }
        return buckets.values
            .map(\.summary)
            .sorted { $0.date > $1.date }
    }

    private struct DayBucket {
        let date: Date
        var providerCosts: [AgentProvider: Double] = [:]
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheCreationTokens = 0
        var totalCacheReadTokens = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var sessionCount = 0
        var models: Set<String> = []

        mutating func record(_ row: UsageRow) {
            providerCosts[row.provider, default: 0] += row.cost
            totalInputTokens += row.inputTokens
            totalOutputTokens += row.outputTokens
            totalCacheCreationTokens += row.cacheCreationTokens
            totalCacheReadTokens += row.cacheReadTokens
            totalTokens += row.totalTokens
            totalCost += row.cost
            sessionCount += 1
            models.insert(row.model)
        }

        var summary: DailyUsageSummary {
            DailyUsageSummary(
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
}
