import Foundation

// MARK: - Conversation Indexer

@MainActor
final class ConversationIndexer {
    static let shared = ConversationIndexer()

    private init() {}

    /// Upserts conversation rows, skipping files whose modification time is unchanged.
    func index(_ records: [ConversationRecord], in dataStore: DataStore) throws {
        for record in records {
            if let stored = try? dataStore.fileModifiedAtForConversation(id: record.id),
               let incoming = record.fileModifiedAt,
               stored == incoming {
                continue
            }
            try dataStore.upsertConversation(record)
        }
    }
}
