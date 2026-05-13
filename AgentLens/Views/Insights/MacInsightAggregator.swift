import Foundation
import OpenBurnBarCore

/// macOS aggregator. Pulls a real `InsightDataSnapshot` from
/// `MacInsightDataSource` (DataStore + local session ledger) and asks the
/// shared core aggregator to convert it into the LLM-safe
/// `InsightAnalysisContext` (digest + evidence + budget).
///
/// Folds the last ~10 audit rows into `priorRunSummaries` so generated
/// widgets don't loop on repeat prompts.
@MainActor
final class MacInsightAggregator {

    private let dataSource: MacInsightDataSource
    private let aggregator: InsightAggregator
    private let auditLog: InsightAnalysisAuditLog?

    init(
        dataSource: MacInsightDataSource,
        aggregator: InsightAggregator = InsightAggregator(),
        auditLog: InsightAnalysisAuditLog? = nil
    ) {
        self.dataSource = dataSource
        self.aggregator = aggregator
        self.auditLog = auditLog
    }

    /// Build the `InsightAnalysisContext` for a given filter. The included
    /// source list surfaces in the budget report so the audit view shows
    /// exactly what was shipped.
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

    /// Stable list of data-source identifiers the macOS aggregator pulls
    /// from. Surfaces in the budget report's `includedDataSources`.
    private static let includedSources: [String] = [
        "datastore_usage",
        "datastore_sessions",
        "datastore_projects",
        "firestore_rollups",
        "quota_snapshots",
        "provider_accounts",
        "mac_prior_analyses",
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
