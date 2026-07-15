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

final class ConversationIndexer {
    static var shared: ConversationIndexer {
        ConversationIndexer()
    }

    private static var fileModifiedAtToleranceSeconds: TimeInterval { 0.001 }
    private static var dateFieldToleranceSeconds: TimeInterval { 0.001 }
    private static var writeYieldInterval: Int { 64 }

    private init() {}

    /// Upserts conversation rows, skipping when the parsed payload is unchanged and
    /// file modified timestamps are equivalent (with millisecond tolerance).
    /// Tolerance is needed because persisted SQLite datetimes are millisecond-precision,
    /// while filesystem mtimes can include micro/nanoseconds.
    ///
    /// P-PERF-2: steady-state performance fix.
    /// Previously this method performed one `fetchConversation(id:)` DB roundtrip
    /// per incoming record — N queries for N records on every 60-second tick,
    /// even when every conversation was unchanged. Now it issues a single batch
    /// `fetchConversations(ids:)` query and builds a lookup map, making steady-state
    /// indexing O(1) DB roundtrips + O(changed) writes rather than O(N) roundtrips.
    /// The parsers already skip re-parsing unchanged files via `CompositeFileSignature`
    /// cache hits; this removes the DB-side N+1 that remained.
    func index(_ records: [ConversationRecord], in dataStore: DataStore) async throws -> ConversationIndexingReport {
        var report = ConversationIndexingReport.empty
        guard !records.isEmpty else { return report }

        // Single batch fetch: replaces N individual `fetchConversation(id:)` calls
        // with one SQL `WHERE id IN (…)` query. The result is a dictionary keyed
        // by conversation ID for O(1) lookup inside the loop below.
        let allIDs = records.map(\.id)
        let existingRecords = try await dataStore.fetchConversations(ids: allIDs)
        var existingMap: [String: ConversationRecord] = [:]
        existingMap.reserveCapacity(existingRecords.count)
        for existing in existingRecords {
            existingMap[existing.id] = existing
        }

        for (index, record) in records.enumerated() {
            let existingConversation = existingMap[record.id]

            if let existingConversation,
               shouldSkipUpsert(existing: existingConversation, incoming: record) {
                report.skippedRecordCount += 1
                continue
            }

            try await dataStore.upsertConversation(record)
            let jobType: ProjectionJobType = existingConversation == nil ? .project : .reproject
            try await dataStore.enqueueConversationProjectionJob(conversationID: record.id, jobType: jobType)
            report.changedRecordCount += 1
            report.enqueuedProjectionJobCount += 1

            if index > 0, index.isMultiple(of: Self.writeYieldInterval) {
                await Task.yield()
            }
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