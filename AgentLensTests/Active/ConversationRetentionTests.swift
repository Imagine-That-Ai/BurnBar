import XCTest
import GRDB
@testable import OpenBurnBarCore
@testable import OpenBurnBar
import OpenBurnBarData

/// Wave 2.6: conversations keep the same age retention as usage, with the
/// conversation-owned search/summary rows cascading (no orphaned index rows),
/// and the one-time VACUUM ensure-step runs clean on databases that do not
/// need it.
final class ConversationRetentionTests: XCTestCase {
    private func makeDatabaseQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: dbQueue)
        try database.runMigrationsSafely()
        return dbQueue
    }

    private func insertConversation(
        _ db: Database,
        id: String,
        indexedAt: Date,
        startTime: Date? = nil,
        endTime: Date? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO conversations (id, provider, sessionId, projectName, startTime, endTime, indexedAt)
                VALUES (?, 'codex', ?, 'proj', ?, ?, ?)
                """,
            arguments: [id, "sess-\(id)", startTime, endTime, indexedAt]
        )
    }

    private func insertSearchRows(_ db: Database, conversationID: String, chunkID: String, docID: String) throws {
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO search_documents (id, sourceKind, sourceID, title, indexedAt, createdAt, updatedAt)
                VALUES (?, 'conversation', ?, 't', ?, ?, ?)
                """,
            arguments: [docID, conversationID, now, now, now]
        )
        try db.execute(
            sql: """
                INSERT INTO search_chunks (id, documentID, sourceKind, sourceID, ordinal, startOffset, endOffset, text, createdAt, updatedAt)
                VALUES (?, ?, 'conversation', ?, 0, 0, 1, 'x', ?, ?)
                """,
            arguments: [chunkID, docID, conversationID, now, now]
        )
        try db.execute(
            sql: "INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText) VALUES (?, ?, 't', 'x')",
            arguments: [chunkID, docID]
        )
        try db.execute(
            sql: "INSERT INTO chunk_embeddings (chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt) VALUES (?, 'v1', ?, ?, ?)",
            arguments: [chunkID, Data([0x01]), now, now]
        )
        try db.execute(
            sql: "INSERT INTO summary_runs (id, conversationId, provider, model, createdAt) VALUES (?, ?, 'codex', 'm', ?)",
            arguments: ["sum-\(conversationID)", conversationID, now]
        )
        try db.execute(
            sql: "INSERT INTO controller_runtime_cache (cacheKey, payloadJSON, updatedAt) VALUES (?, '{}', ?)",
            arguments: [ConversationStore.projectionHashCacheKey(conversationID: conversationID), now]
        )
    }

    private func rowCount(_ db: Database, _ table: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }

    func test_reapConversationsOlderThanRemovesAgedRowsAndCascades() async throws {
        let dbQueue = try makeDatabaseQueue()
        let now = Date()
        let cutoff = now.addingTimeInterval(-180 * 24 * 60 * 60)
        let old = now.addingTimeInterval(-200 * 24 * 60 * 60)
        let young = now.addingTimeInterval(-10 * 24 * 60 * 60)

        try await dbQueue.write { db in
            try self.insertConversation(db, id: "old", indexedAt: old)
            try self.insertConversation(db, id: "young", indexedAt: young)
            try self.insertSearchRows(db, conversationID: "old", chunkID: "chunk-old", docID: "doc-old")
            try self.insertSearchRows(db, conversationID: "young", chunkID: "chunk-young", docID: "doc-young")
        }

        let store = ConversationStore(dbQueue: dbQueue)
        let reaped = try await store.reapConversationsOlderThan(cutoff)

        XCTAssertEqual(reaped, 1)
        try await dbQueue.read { db in
            XCTAssertEqual(try self.rowCount(db, "conversations"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM conversations"), "young")
            // Cascade: every conversation-owned row for "old" is gone.
            XCTAssertEqual(try self.rowCount(db, "search_documents"), 1)
            XCTAssertEqual(try self.rowCount(db, "search_chunks"), 1)
            XCTAssertEqual(try self.rowCount(db, "search_chunks_fts"), 1)
            XCTAssertEqual(try self.rowCount(db, "chunk_embeddings"), 1)
            XCTAssertEqual(try self.rowCount(db, "summary_runs"), 1)
            XCTAssertEqual(try self.rowCount(db, "controller_runtime_cache"), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT sourceID FROM search_documents"),
                "young"
            )
        }
    }

    func test_reapUsesLatestKnownActivityNotIndexedAt() async throws {
        let dbQueue = try makeDatabaseQueue()
        let now = Date()
        let cutoff = now.addingTimeInterval(-180 * 24 * 60 * 60)
        let old = now.addingTimeInterval(-200 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-5 * 24 * 60 * 60)

        try await dbQueue.write { db in
            // Indexed long ago but active recently: survives.
            try self.insertConversation(db, id: "active", indexedAt: old, startTime: old, endTime: recent)
            // No timestamps at all except an old indexedAt: reaped.
            try self.insertConversation(db, id: "stale", indexedAt: old)
        }

        let store = ConversationStore(dbQueue: dbQueue)
        let reaped = try await store.reapConversationsOlderThan(cutoff)

        XCTAssertEqual(reaped, 1)
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM conversations"), "active")
        }
    }

    func test_ensureIncrementalVacuumIsNoopWhenUnneeded() async throws {
        // In-memory databases have no durable file: the plan is .unneeded
        // and the ensure-step below the purge runs clean.
        let dbQueue = try makeDatabaseQueue()
        let store = UsageStore(dbQueue: dbQueue)
        let plan = try await store.ensureIncrementalVacuumIfNeeded()
        XCTAssertEqual(plan, .unneeded)
    }
}
