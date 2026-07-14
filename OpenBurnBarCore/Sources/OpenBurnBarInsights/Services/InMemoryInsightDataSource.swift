import Foundation

/// Test-friendly data source backed by literal arrays.
///
/// Used by the core unit test suite, by previews, and as the seed source
/// for the "first run with no data yet" sample template the iPhone/iPad
/// shell shows in its empty state.
public struct InMemoryInsightDataSource: InsightDataSource {
    public var usages: [InsightUsageRow]
    public var sessions: [InsightSessionRow]
    public var quotaBuckets: [InsightQuotaBucket]
    public var operatingActions: [InsightOperatingAction]
    public var summaryRuns: [InsightSummaryRun]

    public init(usages: [InsightUsageRow] = [],
                sessions: [InsightSessionRow] = [],
                quotaBuckets: [InsightQuotaBucket] = [],
                operatingActions: [InsightOperatingAction] = [],
                summaryRuns: [InsightSummaryRun] = []) {
        self.usages = usages
        self.sessions = sessions
        self.quotaBuckets = quotaBuckets
        self.operatingActions = operatingActions
        self.summaryRuns = summaryRuns
    }

    public func snapshot(window: DateInterval) async throws -> InsightDataSnapshot {
        InsightDataSnapshot(
            window: window,
            generatedAt: Date(),
            usages: usages.filter { window.contains($0.startTime) },
            sessions: sessions.filter { window.contains($0.startTime) },
            quotaBuckets: quotaBuckets,
            operatingActions: operatingActions.filter { window.contains($0.occurredAt) },
            summaryRuns: summaryRuns.filter { window.contains($0.ranAt) }
        )
    }
}
