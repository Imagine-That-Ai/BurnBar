import Foundation

// MARK: - Conversation Indexer

struct ConversationIndexingReport: Equatable {
    var changedRecordCount: Int = 0
    var skippedRecordCount: Int = 0
    var enqueuedProjectionJobCount: Int = 0

    static var empty: ConversationIndexingReport {
        ConversationIndexingReport()
    }
}

struct IndexedConversationWrite: Sendable {
    let record: ConversationRecord
    let jobType: ProjectionJobType
}

final class ConversationIndexer {
    static var shared: ConversationIndexer {
        ConversationIndexer()
    }

    private static var fileModifiedAtToleranceSeconds: TimeInterval { 0.001 }
    private static var dateFieldToleranceSeconds: TimeInterval { 0.001 }
    private static var writeYieldInterval: Int { 64 }

    /// SQLite's default parameter limit. Chunk batch fetches to stay safely
    /// below this so `WHERE id IN (…)` never hits `SQLITE_MAX_VARIABLE_NUMBER`.
    private static let batchFetchChunkSize: Int = 500

    private init() {}

    /// Upserts conversation rows, skipping when the parsed payload is unchanged and
    /// file modified timestamps are equivalent (with millisecond tolerance).
    /// Tolerance is needed because persisted SQLite datetimes are millisecond-precision,
    /// while filesystem mtimes can include micro/nanoseconds.
    ///
    /// P-PERF-2: steady-state performance fix.
    /// Previously this method performed one `fetchConversation(id:)` DB roundtrip
    /// per incoming record — N queries for N records on every 60-second tick,
    /// even when every conversation was unchanged. Now it issues batched
    /// `fetchConversations(ids:)` queries (chunked to stay under SQLite's
    /// parameter limit) and builds a lookup map, making steady-state indexing
    /// O(ceil(N/500)) DB roundtrips + O(changed) writes rather than O(N) roundtrips.
    /// Changed rows persist in chunks of 64 inside one write each (upsert +
    /// projection enqueue), so first-index of thousands no longer opens two
    /// transactions per record. The parsers already skip re-parsing unchanged
    /// files via `CompositeFileSignature` cache hits; this removes the DB-side
    /// N+1 that remained.
    func index(_ records: [ConversationRecord], in dataStore: DataStore) async throws -> ConversationIndexingReport {
        var report = ConversationIndexingReport.empty
        guard !records.isEmpty else { return report }

        // Batch fetch: replaces N individual `fetchConversation(id:)` calls
        // with chunked SQL `WHERE id IN (…)` queries. Chunked to stay safely
        // below SQLite's SQLITE_MAX_VARIABLE_NUMBER (default 999).
        let allIDs = records.map(\.id)
        var existingMap: [String: ConversationRecord] = [:]
        existingMap.reserveCapacity(records.count)
        for chunkStart in stride(from: 0, to: allIDs.count, by: Self.batchFetchChunkSize) {
            let chunkEnd = min(chunkStart + Self.batchFetchChunkSize, allIDs.count)
            let chunkIDs = Array(allIDs[chunkStart..<chunkEnd])
            let chunkRecords = try await dataStore.fetchConversations(ids: chunkIDs)
            for existing in chunkRecords {
                existingMap[existing.id] = existing
            }
        }

        var pendingWrites: [IndexedConversationWrite] = []
        pendingWrites.reserveCapacity(min(records.count, Self.writeYieldInterval))
        let writeNow = Date()

        for record in records {
            let existingConversation = existingMap[record.id]

            if let existingConversation,
               shouldSkipUpsert(existing: existingConversation, incoming: record) {
                report.skippedRecordCount += 1
                continue
            }

            pendingWrites.append(
                IndexedConversationWrite(
                    record: record,
                    jobType: existingConversation == nil ? .project : .reproject
                )
            )
            report.changedRecordCount += 1

            if pendingWrites.count >= Self.writeYieldInterval {
                report.enqueuedProjectionJobCount += try await dataStore.persistIndexedConversations(
                    pendingWrites,
                    now: writeNow
                )
                pendingWrites.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }

        if pendingWrites.isEmpty == false {
            report.enqueuedProjectionJobCount += try await dataStore.persistIndexedConversations(
                pendingWrites,
                now: writeNow
            )
        }

        if report.changedRecordCount > 0 {
            SearchQueryCache.shared.clear()
        }

        return report
    }

    private func shouldSkipUpsert(existing: ConversationRecord, incoming: ConversationRecord) -> Bool {
        let payloadMatches =
            existing.provider == incoming.provider
            && existing.sessionId == incoming.sessionId
            && existing.projectName == incoming.projectName
            && dateFieldEquivalent(existing.startTime, incoming.startTime)
            && dateFieldEquivalent(existing.endTime, incoming.endTime)
            && existing.messageCount == incoming.messageCount
            && existing.userWordCount == incoming.userWordCount
            && existing.assistantWordCount == incoming.assistantWordCount
            && existing.keyFiles == incoming.keyFiles
            && existing.keyCommands == incoming.keyCommands
            && existing.keyTools == incoming.keyTools
            && existing.inferredTaskTitle == incoming.inferredTaskTitle
            && existing.lastAssistantMessage == incoming.lastAssistantMessage
            && existing.fullText == incoming.fullText

        guard payloadMatches else {
            return false
        }

        return fileModifiedAtEquivalent(existing.fileModifiedAt, incoming.fileModifiedAt)
    }

    private func dateFieldEquivalent(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) <= Self.dateFieldToleranceSeconds
        default:
            return false
        }
    }

    private func fileModifiedAtEquivalent(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) <= Self.fileModifiedAtToleranceSeconds
        default:
            return false
        }
    }
}
