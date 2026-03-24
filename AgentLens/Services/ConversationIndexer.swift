import Foundation

// MARK: - Conversation Indexer

@MainActor
final class ConversationIndexer {
    static let shared = ConversationIndexer()

    private init() {}

    /// Upserts conversation rows, skipping when the log file is unchanged *and* parsed
    /// session bounds/message count match. This allows parser fixes (e.g. better timestamps)
    /// to refresh rows without requiring the file's mtime to change.
    func index(_ records: [ConversationRecord], in dataStore: DataStore) throws {
        for record in records {
            let existingConversation = try dataStore.fetchConversation(id: record.id)
            if let stored = try? dataStore.fileModifiedAtForConversation(id: record.id),
               let incoming = record.fileModifiedAt,
               stored == incoming,
               let existingConversation,
               existingConversation.startTime == record.startTime,
               existingConversation.endTime == record.endTime,
               existingConversation.messageCount == record.messageCount {
                continue
            }
            try dataStore.upsertConversation(record)
            let jobType: ProjectionJobType = existingConversation == nil ? .project : .reproject
            try dataStore.enqueueConversationProjectionJob(conversationID: record.id, jobType: jobType)
        }
    }
}
