import Foundation
import OpenBurnBarCore

/// Mobile aggregator. Pulls a Firestore-backed `InsightDataSnapshot` from
/// `MobileInsightDataSource` and asks the shared core aggregator to convert
/// it into an `InsightAnalysisContext` (digest + evidence + budget) ready
/// for the engine.
///
/// Also folds the last ~10 audit rows into `priorRunSummaries` so the model
/// has a memory of what it's already produced — keeps generated widgets from
/// looping.
@MainActor
final class MobileInsightAggregator {

    private let dataSource: MobileInsightDataSource
    private let aggregator: InsightAggregator
    private let auditLog: InsightAnalysisAuditLog?

    init(
        dataSource: MobileInsightDataSource,
        aggregator: InsightAggregator = InsightAggregator(),
        auditLog: InsightAnalysisAuditLog? = nil
    ) {
        self.dataSource = dataSource
        self.aggregator = aggregator
        self.auditLog = auditLog
    }

    /// Build the `InsightAnalysisContext` for a given filter.
    /// Sources are passed back through the budget report so the audit view
    /// can show exactly what was shipped.
    func buildContext(
        filter: InsightFilter,
        now: Date = Date()
    ) async throws -> InsightAnalysisContext {
        let window = filter.window.interval(now: now)
        let snapshot = try await dataSource.snapshot(window: window)
        let priorSummaries = await loadPriorRunSummaries()
        return try aggregator.buildContext(
            snapshot: snapshot,
            filter: filter,
            includedDataSources: Self.includedSources,
            priorRunSummaries: priorSummaries
        )
    }

    /// Stable list of data-source identifiers the mobile aggregator pulls
    /// from. Surfaces in the budget report's `includedDataSources`.
    private static let includedSources: [String] = [
        "firestore_rollups",
        "firestore_provider_summaries",
        "firestore_model_summaries",
        "firestore_daily_points",
        "mobile_prior_analyses"
    ]

    private func loadPriorRunSummaries() async -> [String] {
        guard let auditLog else { return [] }
        let rows = (try? await auditLog.readAll(limit: 10)) ?? []
        return rows.compactMap { row -> String? in
            guard row.status == .succeeded || row.status == .partial else { return nil }
            let model = row.selectedModel.displayName
            let day = ISO8601DateFormatter().string(from: row.ranAt).prefix(10)
            return "\(day): \(model) ran an analysis (\(row.resultHash.prefix(8)))."
        }
    }
}
