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
        let providers = providerSummariesForSelectedWindow()
        let models = dashboardStore.topModels
        let dailyPoints = dailyPointsForSelectedWindow(in: window, providers: providers)
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
            let providerRequestCount = max(1, provider.totalRequests)
            for point in dailyPoints {
                let share = point.value / totalValueAcrossDays
                let providerDayCost = providerTotalCost * share
                let providerDayTokens = Double(providerTotalTokens) * share
                guard providerDayCost > 0 || providerDayTokens > 0 || providerRequestCount > 0 else { continue }

                let rowsForProviderDay = max(1, Int((Double(providerRequestCount) * share).rounded()))
                let rowCost = providerDayCost / Double(rowsForProviderDay)
                let rowTokens = providerDayTokens / Double(rowsForProviderDay)
                for _ in 0..<rowsForProviderDay {
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
                        inputTokens: Int(rowTokens * 0.6),
                        outputTokens: Int(rowTokens * 0.3),
                        reasoningTokens: 0,
                        cacheReadTokens: Int(rowTokens * 0.1),
                        cacheCreationTokens: 0,
                        totalTokens: Int(rowTokens),
                        costUSD: rowCost
                    ))
                }
            }
        }
        return rows
    }

    private func providerSummariesForSelectedWindow() -> [RollupProviderSummary] {
        if !dashboardStore.topProviders.isEmpty {
            return dashboardStore.topProviders
        }
        guard let totals = dashboardStore.windowTotals[dashboardStore.selectedWindow],
              totals.requests > 0 || totals.tokens > 0 || totals.costUsd > 0
        else {
            return []
        }
        return [
            RollupProviderSummary(
                provider: "All providers",
                totalRequests: max(1, totals.requests),
                totalTokens: totals.tokens,
                totalCost: totals.costUsd
            )
        ]
    }

    private func dailyPointsForSelectedWindow(
        in window: DateInterval,
        providers: [RollupProviderSummary]
    ) -> [RollupDailyPoint] {
        let realPoints = dashboardStore.dailyPoints.filter { window.contains($0.date) && $0.value > 0 }
        if !realPoints.isEmpty {
            return realPoints
        }

        let providerCost = providers.reduce(0) { $0 + ($1.totalCost ?? 0) }
        let providerTokens = providers.reduce(0) { $0 + $1.totalTokens }
        let providerRequests = providers.reduce(0) { $0 + $1.totalRequests }
        guard providerCost > 0 || providerTokens > 0 || providerRequests > 0 else { return [] }

        let date = Date().clamped(to: window)
        let weight = max(providerCost, Double(providerTokens), Double(providerRequests), 1)
        return [RollupDailyPoint(date: date, value: weight)]
    }
}

private extension Date {
    func clamped(to interval: DateInterval) -> Date {
        if self < interval.start { return interval.start }
        if self > interval.end { return interval.end.addingTimeInterval(-1) }
        return self
    }
}
