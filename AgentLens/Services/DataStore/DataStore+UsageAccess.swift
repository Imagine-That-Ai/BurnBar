import Foundation
import OpenBurnBarCore

/// Per-session token + cost + timing facets used to enrich the encrypted session-log
/// backup manifest with plaintext cockpit facets (bodies stay encrypted).
struct SessionUsageFacets: Sendable {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let costUSD: Double
    let startTime: Date?
    let endTime: Date?

    /// Combines facets for the same root session that arrived under different model rows.
    func merging(_ other: SessionUsageFacets) -> SessionUsageFacets {
        SessionUsageFacets(
            model: costUSD >= other.costUSD ? model : other.model,
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            cacheCreationTokens: cacheCreationTokens + other.cacheCreationTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            totalTokens: totalTokens + other.totalTokens,
            costUSD: costUSD + other.costUSD,
            startTime: [startTime, other.startTime].compactMap { $0 }.min(),
            endTime: [endTime, other.endTime].compactMap { $0 }.max()
        )
    }
}

extension DataStore {
    func insert(_ usage: TokenUsage) async throws {
        try await actor.usageStore.insert(usage)
    }

    func insert(_ newUsages: [TokenUsage]) async throws {
        try await actor.usageStore.insert(newUsages)
    }

    func insertChunked(_ newUsages: [TokenUsage], chunkSize: Int = 100) async throws {
        try await actor.usageStore.insertChunked(newUsages, chunkSize: chunkSize)
    }

    func fetchAllUsage() async throws -> [TokenUsage] {
        try await actor.usageStore.fetchAllUsage()
    }

    func fetchUsage(in dateRange: ClosedRange<Date>, limit: Int) async throws -> [TokenUsage] {
        try await actor.usageStore.fetchUsage(in: dateRange, limit: limit)
    }

    func fetchUsage(startingIn dateRange: Range<Date>, limit: Int) async throws -> [TokenUsage] {
        try await actor.usageStore.fetchUsage(startingIn: dateRange, limit: limit)
    }

    func fetchRecentUsage(limit: Int) async throws -> [TokenUsage] {
        try await actor.usageStore.fetchRecentUsage(limit: limit)
    }

    func fetchChartFactRows(in dateRange: ClosedRange<Date>?) async throws -> [ChartFactRow] {
        try await actor.usageStore.fetchChartFactRows(in: dateRange)
    }

    func fetchDashboardUsageSnapshot(loadedUsageLimit: Int) async throws -> DashboardUsageSnapshot {
        try await actor.fetchDashboardUsageSnapshot(loadedUsageLimit: loadedUsageLimit)
    }

    func fetchUsageCostBreakdown(in dateRange: ClosedRange<Date>, limit: Int = 20) async throws -> UsageCostBreakdown {
        try await actor.usageStore.fetchUsageCostBreakdown(in: dateRange, limit: limit)
    }

    func checkpointTruncate() async throws {
        try await actor.usageStore.checkpointTruncate()
    }

    /// Deletes prior API-reconciled rows; returns the number of rows removed
    /// so callers can distinguish a no-op cleanup from a content change.
    @discardableResult
    func deleteUsage(sessionIDPrefix: String) async throws -> Int {
        try await actor.usageStore.deleteUsage(sessionIDPrefix: sessionIDPrefix)
    }

    /// Usage-table new-event marker (see `UsageTableWriteMarker`).
    func usageTableWriteMarker() async -> Int {
        await actor.usageTableWriteMarker
    }

    /// Per-credential all-time cost totals for billing drift detection,
    /// aggregated in SQL (`GROUP BY`) instead of materializing the full
    /// usage history. Keys match `"providerID:providerAccountID-or-default"`.
    func driftCredentialCostTotals() async throws -> [String: Double] {
        try await actor.usageStore.driftCredentialCostTotals()
    }

    func deleteUsage(provider: AgentProvider, sessionIDs: [String]) async throws {
        try await actor.usageStore.deleteUsage(provider: provider, sessionIDs: sessionIDs)
    }

    func fetchUnsynced() async throws -> [TokenUsage] {
        try await actor.usageStore.fetchUnsynced()
    }

    func fetchUsageIdStrings() async throws -> Set<String> {
        try await actor.usageStore.fetchUsageIdStrings()
    }

    func markSynced(ids: [UUID]) async throws {
        try await actor.usageStore.markSynced(ids: ids)
    }

    func resetSyncStatusForAllLocalUsage() async throws {
        try await actor.usageStore.resetSyncStatusForAllLocalUsage()
    }

    func sessionModelMap() async throws -> [String: String] {
        try await actor.usageStore.sessionModelMap()
    }

    func sessionFacetsMap() async throws -> [String: SessionUsageFacets] {
        try await actor.usageStore.sessionFacetsMap()
    }

    func insertRemoteUsage(_ usage: TokenUsage) async throws {
        try await actor.usageStore.insertRemoteUsage(usage)
    }

    func providerRunCostTotals(in dateRange: ClosedRange<Date>?) async throws -> [AgentProvider: ProviderRunCostTotals] {
        try await actor.usageStore.providerRunCostTotals(in: dateRange)
    }

    func providerRunCostTotals(
        in dateRanges: [ClosedRange<Date>]
    ) async throws -> [[AgentProvider: ProviderRunCostTotals]] {
        try await actor.usageStore.providerRunCostTotals(in: dateRanges)
    }

    func fetchOrgRollup(groupBy: OrgGroupBy, period: BudgetPeriod) async throws -> [OrgRollupRow] {
        try await actor.usageStore.fetchOrgRollup(groupBy: groupBy, period: period)
    }
}
