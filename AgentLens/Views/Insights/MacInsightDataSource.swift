import Foundation
import OpenBurnBarCore

/// Adapter from the macOS `DataStore` (a.k.a. `DataStoreCoordinator`) to
/// the cross-platform `InsightDataSource` protocol consumed by the
/// executor, digest builder, and tool broker.
@MainActor
final class MacInsightDataSource: InsightDataSource {

    let dataStore: DataStore

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    nonisolated func snapshot(window: DateInterval) async throws -> InsightDataSnapshot {
        // Pull everything off the main actor and rebuild the snapshot.
        let usages = await fetchUsages(window: window)
        let sessions = await fetchSessions(window: window)
        return InsightDataSnapshot(
            window: window,
            generatedAt: Date(),
            usages: usages,
            sessions: sessions,
            quotaBuckets: [],
            operatingActions: [],
            summaryRuns: []
        )
    }

    @MainActor
    private func fetchUsages(window: DateInterval) -> [InsightUsageRow] {
        dataStore.usages
            .filter { window.contains($0.startTime) }
            .map { usage in
                InsightUsageRow(
                    sessionID: usage.sessionId,
                    provider: usage.provider.rawValue,
                    model: usage.model,
                    projectName: usage.projectName,
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
                    costUSD: usage.cost
                )
            }
    }

    @MainActor
    private func fetchSessions(window: DateInterval) -> [InsightSessionRow] {
        // The macOS app already aggregates sessions via the usage rows;
        // we synthesize per-session rows from `usages` to avoid an extra
        // database hit. KeyTools / keyCommands / titles aren't on the
        // usage row, so we leave them empty here — the LLM tool broker
        // will fetch enrichment on demand.
        let grouped = Dictionary(grouping: dataStore.usages.filter { window.contains($0.startTime) }) {
            "\($0.provider.rawValue)|\($0.sessionId)"
        }
        return grouped.compactMap { _, rows -> InsightSessionRow? in
            guard let first = rows.first else { return nil }
            return InsightSessionRow(
                sessionID: first.sessionId,
                provider: first.provider.rawValue,
                projectName: first.projectName.isEmpty ? nil : first.projectName,
                startTime: rows.map(\.startTime).min() ?? first.startTime,
                endTime: rows.map(\.endTime).max() ?? first.endTime,
                messageCount: rows.count,
                inferredTaskTitle: nil,
                keyTools: [],
                keyCommands: [],
                keyFiles: []
            )
        }
    }
}
