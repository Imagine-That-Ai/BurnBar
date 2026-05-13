import Foundation
import OpenBurnBarCore

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

    nonisolated func insertRemoteUsage(_ usage: TokenUsage) throws {
        try usageStore.insertRemoteUsage(usage)
    }
}
