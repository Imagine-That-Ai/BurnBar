import GRDB
import XCTest
@testable import OpenBurnBarData

/// Core-side coverage for `v70_agent_memories_index_backfill`. v68's index
/// (re)creation sits inside its conditional rebuild, so installs that skipped
/// the repair — every fresh install — never created `review_status_idx`. v70
/// backfills the three schema-owned `agent_memories` indexes idempotently.
final class OpenBurnBarDataAgentMemoriesIndexBackfillTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue)
        return queue
    }

    func test_freshMigrationOwnsAllThreeAgentMemoriesIndexes() throws {
        let queue = try migrated()
        let indexes = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
        for index in [
            "agent_memories_project_idx",
            "agent_memories_review_status_idx",
            "agent_memories_chat_scope_idx"
        ] {
            XCTAssertTrue(indexes.contains(index), "fresh endpoint is missing \(index)")
        }
    }

    func test_freshMigrationKeepsQuarantinedReviewDefault() throws {
        let queue = try migrated()
        let defaultValue = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(agent_memories)")
                .first(where: { ($0["name"] as? String) == "review_status" })
                .flatMap { $0["dflt_value"] as? String }
        }
        XCTAssertEqual(defaultValue?.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")), "quarantined")
    }
}
