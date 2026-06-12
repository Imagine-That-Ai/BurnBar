import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// C10 — `conversations_fts` orphan invariant.
///
/// Regression guard for the full-text leak: the upsert path historically used
/// `INSERT OR REPLACE INTO conversations`, which deletes and re-inserts the row.
/// With `recursive_triggers` OFF (the SQLite default) REPLACE does not fire the
/// `conversations_ad` delete trigger, so each re-upsert left an orphaned copy of
/// the transcript in the standalone `conversations_fts` table. The 60s refresh
/// tick re-upserted active conversations forever, leaking millions of rows.
///
/// The upsert now uses `INSERT ... ON CONFLICT(id) DO UPDATE`, which keeps the
/// rowid stable and lets the `conversations_au` AFTER UPDATE trigger maintain the
/// index (delete-then-insert for the same rowid). This test asserts the core
/// invariant: after repeated upserts, the FTS row count equals the live
/// conversation count — no orphans.
@MainActor
final class ConversationFTSOrphanInvariantTests: XCTestCase {
    private var dataStore: DataStore!
    private var queue: DatabaseQueue!

    override func setUp() async throws {
        queue = try DatabaseQueue(path: ":memory:")
        dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    override func tearDown() async throws {
        dataStore = nil
        queue = nil
    }

    /// Upserting the same conversation twice must leave exactly one FTS row, not
    /// two. With the old `INSERT OR REPLACE`, the second upsert leaked a second
    /// `conversations_fts` row (orphan), so the FTS count drifted above the
    /// conversation count.
    func test_repeatedUpsert_doesNotLeakOrphanedFTSRows() async throws {
        let id = "conv-fts-invariant"
        try dataStore.upsertConversation(makeRecord(id: id, fullText: "first revision body"))
        try dataStore.upsertConversation(makeRecord(id: id, fullText: "second revision body"))
        try dataStore.upsertConversation(makeRecord(id: id, fullText: "third revision body"))

        let counts = try await queue.read { db -> (fts: Int, conversations: Int) in
            let fts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations_fts") ?? -1
            let conversations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? -2
            return (fts, conversations)
        }

        XCTAssertEqual(counts.conversations, 1, "Re-upserting the same id must keep a single conversation row.")
        XCTAssertEqual(
            counts.fts,
            counts.conversations,
            "conversations_fts must hold exactly one row per conversation; a higher count is the C10 orphan leak."
        )

        // The index reflects the latest revision, not a stale or duplicated copy.
        let hits = try dataStore.searchConversationsFTS(query: "third")
        XCTAssertTrue(hits.contains { $0.conversation.id == id }, "Latest revision must be searchable after re-upsert.")
        let stale = try dataStore.searchConversationsFTS(query: "first")
        XCTAssertFalse(stale.contains { $0.conversation.id == id }, "Superseded revision text must not linger in the index.")
    }

    /// The invariant must hold across multiple distinct conversations re-upserted
    /// many times — the exact pattern the 60s refresh tick produced at scale.
    func test_manyConversationsRepeatedlyUpserted_keepFTSCountEqualToConversationCount() async throws {
        let ids = (0..<8).map { "conv-fts-bulk-\($0)" }
        for revision in 0..<5 {
            for id in ids {
                try dataStore.upsertConversation(makeRecord(id: id, fullText: "revision \(revision) of \(id)"))
            }
        }

        let counts = try await queue.read { db -> (fts: Int, conversations: Int) in
            let fts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations_fts") ?? -1
            let conversations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? -2
            return (fts, conversations)
        }

        XCTAssertEqual(counts.conversations, ids.count)
        XCTAssertEqual(
            counts.fts,
            counts.conversations,
            "After 5 upserts of 8 conversations, conversations_fts must hold 8 rows, not 40 (the orphan leak)."
        )
    }

    // MARK: - Helpers

    private func makeRecord(id: String, fullText: String) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "session-\(id)",
            projectName: "FTSInvariantProject",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            messageCount: 4,
            userWordCount: 2,
            assistantWordCount: 2,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "FTS Invariant Task",
            lastAssistantMessage: "Done",
            fullText: fullText,
            fileModifiedAt: nil
        )
    }
}
