import Foundation
import OpenBurnBarCore

/// Mobile adapter: synthesizes `InsightUsageRow`s from the Firestore-
/// backed rollup summaries on `DashboardStore`.
///
/// The mobile app stores aggregated rollups rather than raw usage rows.
/// We rebuild a synthetic row set that lines up totals with each
/// `RollupProviderSummary` / `RollupModelSummary`, distributed across
/// the daily points so per-day charts still render. This is an
/// approximation but it's good enough for the executor's rollup-style
/// queries.
@MainActor
final class MobileInsightDataSource: InsightDataSource {

    private let dashboardStore: DashboardStore

    init(dashboardStore: DashboardStore) {
        self.dashboardStore = dashboardStore
    }

    nonisolated func snapshot(window: DateInterval) async throws -> InsightDataSnapshot {
        let usages = await buildUsageRows(window: window)
        return InsightDataSnapshot(
            window: window,
            generatedAt: Date(),
            usages: usages,
            sessions: [],
            quotaBuckets: [],
            operatingActions: [],
            summaryRuns: []
        )
    }

    @MainActor
    private func buildUsageRows(window: DateInterval) -> [InsightUsageRow] {
        let providers = dashboardStore.topProviders
        let models = dashboardStore.topModels
        let dailyPoints = dashboardStore.dailyPoints.filter { window.contains($0.date) }
        guard !providers.isEmpty, !dailyPoints.isEmpty else { return [] }

        let totalValueAcrossDays = dailyPoints.reduce(0) { $0 + $1.value }
        guard totalValueAcrossDays > 0 else { return [] }

        // Pick the top model id per provider, if available.
        let modelByProvider = Dictionary(grouping: models, by: \.provider)
            .mapValues { $0.first?.model ?? "—" }

        var rows: [InsightUsageRow] = []
        var sessionCounter = 0
        for provider in providers {
            let providerTotalCost = provider.totalCost ?? 0
            let providerTotalTokens = provider.totalTokens
            for point in dailyPoints {
                let share = point.value / totalValueAcrossDays
                let providerDayCost = providerTotalCost * share
                let providerDayTokens = Double(providerTotalTokens) * share
                guard providerDayCost > 0 || providerDayTokens > 0 else { continue }
                sessionCounter += 1
                rows.append(InsightUsageRow(
                    sessionID: "rollup-\(provider.provider)-\(sessionCounter)",
                    provider: provider.provider,
                    model: modelByProvider[provider.provider] ?? "—",
                    projectName: nil,
                    deviceID: nil,
                    deviceName: nil,
                    startTime: point.date,
                    endTime: point.date.addingTimeInterval(3600),
                    inputTokens: Int(providerDayTokens * 0.6),
                    outputTokens: Int(providerDayTokens * 0.3),
                    reasoningTokens: 0,
                    cacheReadTokens: Int(providerDayTokens * 0.1),
                    cacheCreationTokens: 0,
                    totalTokens: Int(providerDayTokens),
                    costUSD: providerDayCost
                ))
            }
        }
        return rows
    }
}
