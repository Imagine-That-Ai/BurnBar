import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
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
