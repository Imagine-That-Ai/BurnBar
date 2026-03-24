import Foundation

// MARK: - Conversation Indexer

@MainActor
final class ConversationIndexer {
    static let shared = ConversationIndexer()
    private static let fileModifiedAtToleranceSeconds: TimeInterval = 0.001
    private static let dateFieldToleranceSeconds: TimeInterval = 0.001

    private init() {}

    /// Upserts conversation rows, skipping when the parsed payload is unchanged and
    /// file modified timestamps are equivalent (with millisecond tolerance).
    /// Tolerance is needed because persisted SQLite datetimes are millisecond-precision,
    /// while filesystem mtimes can include micro/nanoseconds.
    func index(_ records: [ConversationRecord], in dataStore: DataStore) throws {
        for record in records {
            let existingConversation = try dataStore.fetchConversation(id: record.id)

            if let existingConversation,
               shouldSkipUpsert(existing: existingConversation, incoming: record) {
                continue
            }

            try dataStore.upsertConversation(record)
            let jobType: ProjectionJobType = existingConversation == nil ? .project : .reproject
            try dataStore.enqueueConversationProjectionJob(conversationID: record.id, jobType: jobType)
        }
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
