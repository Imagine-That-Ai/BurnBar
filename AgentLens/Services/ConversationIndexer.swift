import Foundation

// MARK: - Conversation Indexer

struct ConversationIndexingReport: Equatable {
    var changedRecordCount: Int = 0
    var skippedRecordCount: Int = 0
    var enqueuedProjectionJobCount: Int = 0

    static let empty = ConversationIndexingReport()
}


final class ConversationIndexer {
    static let shared = ConversationIndexer()
    private static let fileModifiedAtToleranceSeconds: TimeInterval = 0.001
    private static let dateFieldToleranceSeconds: TimeInterval = 0.001
    private static let writeYieldInterval = 64

    private init() {}

    /// Upserts conversation rows, skipping when the parsed payload is unchanged and
    /// file modified timestamps are equivalent (with millisecond tolerance).
    /// Tolerance is needed because persisted SQLite datetimes are millisecond-precision,
    /// while filesystem mtimes can include micro/nanoseconds.
    func index(_ records: [ConversationRecord], in dataStore: DataStore) async throws -> ConversationIndexingReport {
        var report = ConversationIndexingReport.empty

        for (index, record) in records.enumerated() {
            let existingConversation = try dataStore.fetchConversation(id: record.id)

            if let existingConversation,
               shouldSkipUpsert(existing: existingConversation, incoming: record) {
                report.skippedRecordCount += 1
                continue
            }

            try dataStore.upsertConversation(record)
            let jobType: ProjectionJobType = existingConversation == nil ? .project : .reproject
            try dataStore.enqueueConversationProjectionJob(conversationID: record.id, jobType: jobType)
            report.changedRecordCount += 1
            report.enqueuedProjectionJobCount += 1

            if index > 0, index.isMultiple(of: Self.writeYieldInterval) {
                
            }
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
