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
            if let stored = try? dataStore.fileModifiedAtForConversation(id: record.id),
               let incoming = record.fileModifiedAt,
               stored == incoming,
               let existing = try? dataStore.fetchConversation(id: record.id),
               existing.startTime == record.startTime,
               existing.endTime == record.endTime,
               existing.messageCount == record.messageCount {
                continue
            }
            try dataStore.upsertConversation(record)
        }
    }
}
