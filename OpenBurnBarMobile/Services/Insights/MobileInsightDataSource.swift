import Foundation
import OpenBurnBarCore

/// Mobile adapter: synthesizes `InsightUsageRow`s from the Firestore-
/// backed rollup summaries on `DashboardStore`.
///
/// The primary path uses aggregated rollups. If those are empty or stale,
/// mobile falls back to the same raw usage collection that powers Pulse so
/// Insights can still render when the rollup worker has not caught up yet.
@MainActor
final class MobileInsightDataSource: InsightDataSource {

    typealias UsagePageLoader = @MainActor (DateInterval) async throws -> [TokenUsage]

    private let dashboardStore: DashboardStore
    private let usagePageLoader: UsagePageLoader

    init(
        dashboardStore: DashboardStore,
        usagePageLoader: @escaping UsagePageLoader = { interval in
            let (items, _) = try await FirestoreRepository.shared.fetchUsagePage(
                pageSize: 300,
                after: nil,
                provider: nil,
                model: nil,
                device: nil,
                startDate: interval.start,
                endDate: interval.end
            )
            return items
        }
    ) {
        self.dashboardStore = dashboardStore
        self.usagePageLoader = usagePageLoader
    }

    nonisolated func snapshot(window: DateInterval) async throws -> InsightDataSnapshot {
        await snapshot(
            rollupKey: Self.rollupKey(for: window),
            window: window
        )
    }

    @MainActor
    func snapshot(for insightWindow: InsightTimeWindow) async throws -> InsightDataSnapshot {
        let window = insightWindow.interval()
        return await snapshot(
            rollupKey: Self.rollupKey(for: insightWindow),
            window: window
        )
    }

    @MainActor
    private func snapshot(
        rollupKey: RollupWindowKey,
        window: DateInterval
    ) async -> InsightDataSnapshot {
        let rollupRows = buildUsageRows(rollupKey: rollupKey, window: window)
        let usages = rollupRows.isEmpty
            ? await rawUsageRows(in: window)
            : rollupRows
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
    private func buildUsageRows(
        rollupKey: RollupWindowKey,
        window: DateInterval
    ) -> [InsightUsageRow] {
        guard let rollup = dashboardStore.rollup(for: rollupKey) else { return [] }
        let providers = providerSummaries(for: rollup)
        let models = rollup.modelSummaries.sorted { $0.tokens > $1.tokens }
        let dailyPoints = dailyPoints(in: window, rollup: rollup, providers: providers)
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

    private func rawUsageRows(in window: DateInterval) async -> [InsightUsageRow] {
        do {
            let usages = try await usagePageLoader(window)
            return usages
                .filter { $0.intersects(window) }
                .map(Self.insightRow(from:))
        } catch {
            return []
        }
    }

    nonisolated private static func insightRow(from usage: TokenUsage) -> InsightUsageRow {
        InsightUsageRow(
            sessionID: usage.sessionId,
            provider: usage.provider.rawValue,
            model: usage.model.isEmpty ? "—" : usage.model,
            projectName: usage.projectName.isEmpty ? nil : usage.projectName,
            deviceID: usage.sourceDeviceId,
            deviceName: usage.sourceDeviceName,
            startTime: usage.startTime,
            endTime: usage.endTime,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            reasoningTokens: usage.reasoningTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            totalTokens: usage.totalTokens,
            costUSD: usage.costUSD
        )
    }

    private func providerSummaries(for rollup: UsageRollupDoc) -> [RollupProviderSummary] {
        let sorted = rollup.providerSummaries.sorted { $0.totalTokens > $1.totalTokens }
        if !sorted.isEmpty {
            return sorted
        }
        let totals = rollup.totals
        guard totals.requests > 0 || totals.tokens > 0 || totals.costUsd > 0 else { return [] }
        return [
            RollupProviderSummary(
                provider: "All providers",
                totalRequests: max(1, totals.requests),
                totalTokens: totals.tokens,
                totalCost: totals.costUsd
            )
        ]
    }

    private func dailyPoints(
        in window: DateInterval,
        rollup: UsageRollupDoc,
        providers: [RollupProviderSummary]
    ) -> [RollupDailyPoint] {
        let realPoints = rollup.dailyPoints.filter { window.contains($0.date) && $0.value > 0 }
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

    nonisolated private static func rollupKey(for window: InsightTimeWindow) -> RollupWindowKey {
        switch window {
        case .today, .last24h:
            return .today
        case .last7d:
            return .sevenDays
        case .last30d:
            return .thirtyDays
        case .last90d:
            return .ninetyDays
        case .last365d, .allTime, .custom:
            return .allTime
        }
    }

    nonisolated private static func rollupKey(for interval: DateInterval) -> RollupWindowKey {
        let days = interval.duration / 86_400
        switch days {
        case ...1.05:
            return .today
        case ...8:
            return .sevenDays
        case ...31:
            return .thirtyDays
        case ...92:
            return .ninetyDays
        default:
            return .allTime
        }
    }
}

private extension Date {
    func clamped(to interval: DateInterval) -> Date {
        if self < interval.start { return interval.start }
        if self > interval.end { return interval.end.addingTimeInterval(-1) }
        return self
    }
}

private extension TokenUsage {
    func intersects(_ interval: DateInterval) -> Bool {
        startTime <= interval.end && endTime >= interval.start
    }
}
