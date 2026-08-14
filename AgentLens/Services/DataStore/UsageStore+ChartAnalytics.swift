import Foundation
import GRDB
import OpenBurnBarCore

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
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT startTime, endTime, cost, sessionId, projectName, model, provider,
                       billingKind, usageSource,
                       inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                       reasoningTokens, provenanceConfidence, isRemote
                FROM token_usage
                \(predicate.whereSQL)
                ORDER BY startTime DESC
                """,
            arguments: predicate.arguments
        )
        var facts: [ChartFactRow] = []
        facts.reserveCapacity(rows.count)
        for row in rows {
            guard let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"]),
                  let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"]),
                  let sessionId = row["sessionId"] as? String,
                  let projectName = row["projectName"] as? String,
                  let model = row["model"] as? String,
                  let providerRaw = row["provider"] as? String,
                  let provider = AgentProvider(rawValue: providerRaw) else {
                continue
            }
            let inputTokens = intValue(row["inputTokens"])
            let outputTokens = intValue(row["outputTokens"])
            let cacheCreationTokens = intValue(row["cacheCreationTokens"])
            let cacheReadTokens = intValue(row["cacheReadTokens"])
            let reasoningTokens = intValue(row["reasoningTokens"])
            facts.append(
                ChartFactRow(
                    startTime: startTime,
                    endTime: endTime,
                    cost: doubleValue(row["cost"]),
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    provider: provider,
                    billingKind: (row["billingKind"] as? String)
                        .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown,
                    usageSource: (row["usageSource"] as? String)
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
                    provenanceConfidence: (row["provenanceConfidence"] as? String)
                        .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown,
                    isRemote: intValue(row["isRemote"]) != 0
                )
            )
        }
        return facts
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
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT startTime, cost, sessionId, projectName, model, provider
                FROM token_usage
                \(predicate.whereSQL)
                ORDER BY startTime DESC
                """,
            arguments: predicate.arguments
        )
        var events: [ChartSessionAnalytics.Event] = []
        events.reserveCapacity(rows.count)
        for row in rows {
            guard let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"]),
                  let sessionId = row["sessionId"] as? String,
                  let projectName = row["projectName"] as? String,
                  let model = row["model"] as? String,
                  let providerRaw = row["provider"] as? String,
                  let provider = AgentProvider(rawValue: providerRaw) else {
                continue
            }
            events.append(
                ChartSessionAnalytics.Event(
                    startTime: startTime,
                    cost: doubleValue(row["cost"]),
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    provider: provider
                )
            )
        }
        let range = ChartsSnapshot.resolvedRange(
            for: timeRange,
            earliestStart: events.map(\.startTime).min(),
            now: now,
            calendar: calendar
        )
        return ChartSessionAnalytics.from(events: events, range: range, calendar: calendar)
    }
}
