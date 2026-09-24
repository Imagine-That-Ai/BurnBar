import Foundation
import GRDB
import OpenBurnBarKernel

extension ConversationStore {
    /// Bounded age retention for conversations (Wave 2.6): the same cutoff
    /// the purge applies to usage (`UsageRetentionPolicy`), so conversation
    /// history cannot outgrow usage history.
    ///
    /// A conversation's age is its latest known activity —
    /// `COALESCE(endTime, startTime, indexedAt)` — because `startTime` /
    /// `endTime` are nullable while `indexedAt` is always set. No new index:
    /// this very purge bounds the table, so the first-run scan is one-time.
    ///
    /// The delete cascades to the conversation-owned search rows in
    /// dependency order (mirroring `deleteAllIndexedConversations`), plus
    /// `summary_runs` and the projection-hash cache entries, so reaping a
    /// conversation leaves no orphaned index rows behind.
    /// `conversations_fts` is cleaned by its delete trigger, and the
    /// projection pipeline purges orphaned projections when the row
    /// disappears (same contract as `deleteConversation`).
    ///
    /// Tombstoned rows are NOT carved out: a fresh tombstone on an old
    /// conversation still converges, because every device applies this same
    /// age predicate. Returns the number of conversation rows reaped.
    @discardableResult
    func reapConversationsOlderThan(_ cutoff: Date) async throws -> Int {
        // Shared age predicate: latest known activity older than the cutoff.
        let aged = "COALESCE(endTime, startTime, indexedAt) < ?"
        let reapedIDs = "SELECT id FROM conversations WHERE \(aged)"
        // Chunks (and their embeddings/FTS rows) key off the chunk id, via
        // the parent document's conversation id.
        let reapedChunkIDs = """
            SELECT c.id FROM search_chunks c
            JOIN conversations v ON v.id = c.sourceID
            WHERE c.sourceKind = 'conversation' AND COALESCE(v.endTime, v.startTime, v.indexedAt) < ?
            """
        return try await dbQueue.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM chunk_embeddings WHERE chunkID IN (\(reapedChunkIDs))",
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM search_chunks_fts WHERE chunkID IN (\(reapedChunkIDs))",
                arguments: [cutoff]
            )
            try db.execute(
                sql: """
                    DELETE FROM search_chunks
                    WHERE sourceKind = 'conversation' AND sourceID IN (\(reapedIDs))
                    """,
                arguments: [cutoff]
            )
            try db.execute(
                sql: """
                    DELETE FROM search_documents
                    WHERE sourceKind = 'conversation' AND sourceID IN (\(reapedIDs))
                    """,
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM summary_runs WHERE conversationId IN (\(reapedIDs))",
                arguments: [cutoff]
            )
            try db.execute(
                sql: """
                    DELETE FROM controller_runtime_cache
                    WHERE cacheKey IN (SELECT '\(Self.projectionHashCacheKeyPrefix)' || id FROM conversations WHERE \(aged))
                    """,
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM conversations WHERE \(aged)",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }
}
