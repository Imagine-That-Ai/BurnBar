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
    nonisolated func insert(_ usage: TokenUsage) throws {
        try usageStore.insert(usage)
    }

    nonisolated func insert(_ newUsages: [TokenUsage]) throws {
        try usageStore.insert(newUsages)
    }

    nonisolated func insertChunked(_ newUsages: [TokenUsage], chunkSize: Int = 100) throws {
        try usageStore.insertChunked(newUsages, chunkSize: chunkSize)
    }

    nonisolated func checkpointTruncate() throws {
        try usageStore.checkpointTruncate()
    }

    nonisolated func deleteUsage(sessionIDPrefix: String) throws {
        try usageStore.deleteUsage(sessionIDPrefix: sessionIDPrefix)
    }

    nonisolated func fetchUnsynced() throws -> [TokenUsage] {
        try usageStore.fetchUnsynced()
    }

    nonisolated func markSynced(ids: [UUID]) throws {
        try usageStore.markSynced(ids: ids)
    }

    nonisolated func sessionModelMap() throws -> [String: String] {
        try usageStore.sessionModelMap()
    }

    nonisolated func sessionFacetsMap() throws -> [String: SessionUsageFacets] {
        try usageStore.sessionFacetsMap()
    }

    nonisolated func insertRemoteUsage(_ usage: TokenUsage) throws {
        try usageStore.insertRemoteUsage(usage)
    }
}
