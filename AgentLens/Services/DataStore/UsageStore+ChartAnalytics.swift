import Foundation
import GRDB
import OpenBurnBarKernel

extension UsageStore {
    func fetchChartFactRows(
        in dateRange: ClosedRange<Date>?
    ) async throws -> [ChartFactRow] {
        try await dbQueue.read { db in
            try Self.fetchChartFactRows(db: db, dateRange: dateRange)
        }
    }

    /// Narrow `token_usage` projection for the full Charts snapshot.
    /// Window membership matches `fetchUsage(in:)` (intersection). Does not
    /// decode UUIDs, accounts, or execution source.
    static func fetchChartFactRows(
        db: Database,
        dateRange: ClosedRange<Date>?
    ) throws -> [ChartFactRow] {
        let predicate = dateRangePredicate(dateRange)
        return try compactMapCachedRows(
            db: db,
            sql: """
                SELECT \(chartFactSelectColumns.joined(separator: ", "))
                FROM token_usage
                \(predicate.whereSQL)
                ORDER BY startTime DESC
                """,
            arguments: predicate.arguments,
            transform: Self.decodeChartFactRow
        )
    }

    static func decodeChartFactRow(_ row: Row) -> ChartFactRow? {
        guard let startTime = OpenBurnBarDatabase.parseDateValue(indexed(row, ChartFactCol.startTime.rawValue)),
              let endTime = OpenBurnBarDatabase.parseDateValue(indexed(row, ChartFactCol.endTime.rawValue)),
              let sessionId = indexed(row, ChartFactCol.sessionId.rawValue) as? String,
              let projectName = indexed(row, ChartFactCol.projectName.rawValue) as? String,
              let model = indexed(row, ChartFactCol.model.rawValue) as? String,
              let providerRaw = indexed(row, ChartFactCol.provider.rawValue) as? String,
              let provider = AgentProvider.resolve(providerRaw) else {
            return nil
        }
        let inputTokens = intValue(indexed(row, ChartFactCol.inputTokens.rawValue))
        let outputTokens = intValue(indexed(row, ChartFactCol.outputTokens.rawValue))
        let cacheCreationTokens = intValue(indexed(row, ChartFactCol.cacheCreationTokens.rawValue))
        let cacheReadTokens = intValue(indexed(row, ChartFactCol.cacheReadTokens.rawValue))
        let reasoningTokens = intValue(indexed(row, ChartFactCol.reasoningTokens.rawValue))
        return ChartFactRow(
            startTime: startTime,
            endTime: endTime,
            cost: doubleValue(indexed(row, ChartFactCol.cost.rawValue)),
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            provider: provider,
            billingKind: (indexed(row, ChartFactCol.billingKind.rawValue) as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown,
            usageSource: (indexed(row, ChartFactCol.usageSource.rawValue) as? String)
                .flatMap(UsageSource.init(rawValue:)) ?? .unknown,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: TokenUsage.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            ),
            provenanceConfidence: (indexed(row, ChartFactCol.provenanceConfidence.rawValue) as? String)
                .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown,
            isRemote: intValue(indexed(row, ChartFactCol.isRemote.rawValue)) != 0
        )
    }

    func fetchChartSessionAnalytics(
        timeRange: TimeRange,
        now: Date,
        calendar: Calendar = .current
    ) async throws -> ChartSessionAnalytics {
        try await dbQueue.read { db in
            try Self.fetchChartSessionAnalytics(
                db: db,
                timeRange: timeRange,
                now: now,
                calendar: calendar
            )
        }
    }

    /// Narrow `token_usage` projection for heatmap / outliers / entropy.
    /// Window membership matches `fetchUsage(in:)` (intersection). Attribution
    /// still clamps `startTime` into the resolved chart range — not exploded
    /// onto every overlapped day.
    static func fetchChartSessionAnalytics(
        db: Database,
        timeRange: TimeRange,
        now: Date,
        calendar: Calendar
    ) throws -> ChartSessionAnalytics {
        let requested = timeRange.dateRange(now: now)
        let predicate = dateRangePredicate(requested)
        let events = try compactMapCachedRows(
            db: db,
            sql: """
                SELECT \(chartSessionSelectColumns.joined(separator: ", "))
                FROM token_usage
                \(predicate.whereSQL)
                ORDER BY startTime DESC
                """,
            arguments: predicate.arguments,
            transform: Self.decodeChartSessionEvent
        )
        let range = ChartsSnapshot.resolvedRange(
            for: timeRange,
            earliestStart: events.map(\.startTime).min(),
            now: now,
            calendar: calendar
        )
        return ChartSessionAnalytics.from(events: events, range: range, calendar: calendar)
    }

    static func decodeChartSessionEvent(_ row: Row) -> ChartSessionAnalytics.Event? {
        guard let startTime = OpenBurnBarDatabase.parseDateValue(indexed(row, ChartSessionCol.startTime.rawValue)),
              let sessionId = indexed(row, ChartSessionCol.sessionId.rawValue) as? String,
              let projectName = indexed(row, ChartSessionCol.projectName.rawValue) as? String,
              let model = indexed(row, ChartSessionCol.model.rawValue) as? String,
              let providerRaw = indexed(row, ChartSessionCol.provider.rawValue) as? String,
              let provider = AgentProvider.resolve(providerRaw) else {
            return nil
        }
        return ChartSessionAnalytics.Event(
            startTime: startTime,
            cost: doubleValue(indexed(row, ChartSessionCol.cost.rawValue)),
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            provider: provider
        )
    }
}
