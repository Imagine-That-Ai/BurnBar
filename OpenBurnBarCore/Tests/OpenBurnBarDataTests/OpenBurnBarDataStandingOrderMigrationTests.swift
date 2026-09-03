import GRDB
import XCTest
@testable import OpenBurnBarData

/// Core-side coverage for `v63_standing_orders`. The AgentLens copy is
/// byte-identical (enforced by `scripts/ci/verify-sqlite-schema-doc.mjs`), so
/// running the Core migrator here proves both.
final class OpenBurnBarDataStandingOrderMigrationTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue)
        return queue
    }

    func test_freshMigrationCreatesTheStandingOrdersTable() throws {
        let queue = try migrated()
        let shape = try queue.read { db -> (tables: Set<String>, indexes: Set<String>, columns: [String]) in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(standing_orders)")
                .compactMap { $0["name"] as? String }
            return (tables, indexes, columns)
        }

        XCTAssertTrue(shape.tables.contains("standing_orders"))
        XCTAssertTrue(shape.indexes.contains("standing_orders_enabled_fired_idx"))
        for column in [
            "id", "title", "instruction", "cadenceKind", "cadenceMinutes",
            "cadenceHour", "cadenceMinute", "cadenceWeekday", "targetBodyId",
            "requiredCapabilities", "isEnabled", "lastFiredAt", "createdAt", "updatedAt"
        ] {
            XCTAssertTrue(shape.columns.contains(column), "missing column \(column)")
        }
    }

    /// Null target means "let the Flame choose at fire time" — the default, and
    /// the reason an order survives the fleet changing shape between runs.
    func test_targetBodyIsNullableAndCadenceComponentsAreOptional() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO standing_orders
                    (id, title, instruction, cadenceKind, cadenceMinutes, requiredCapabilities,
                     isEnabled, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["o-1", "Nightly", "run it", "interval", 30, "", true, Date(), Date()]
            )
        }
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT targetBodyId, cadenceHour FROM standing_orders WHERE id = 'o-1'")
        }
        XCTAssertNil(row?["targetBodyId"] as String?)
        XCTAssertNil(row?["cadenceHour"] as Int?)
    }

    func test_idIsThePrimaryKeySoAnOrderCannotBeDuplicated() throws {
        let queue = try migrated()
        let insert: (Database) throws -> Void = { db in
            try db.execute(
                sql: """
                INSERT INTO standing_orders
                    (id, title, instruction, cadenceKind, cadenceMinutes, requiredCapabilities,
                     isEnabled, createdAt, updatedAt)
                VALUES ('o-1', 't', 'i', 'interval', 30, '', 1, ?, ?)
                """,
                arguments: [Date(), Date()]
            )
        }
        try queue.write(insert)
        XCTAssertThrowsError(try queue.write(insert))
    }

    func test_upgradingFromV62AddsTheTableWithoutTouchingUsage() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v62_war_room_originator")
        let before = try queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'token_usage'") ?? false
        }
        XCTAssertTrue(before)

        try OpenBurnBarDatabase.migrator.migrate(queue)
        let after = try queue.read { db -> (usage: Bool, orders: Bool) in
            (
                try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'token_usage'") ?? false,
                try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'standing_orders'") ?? false
            )
        }
        XCTAssertTrue(after.usage)
        XCTAssertTrue(after.orders)
    }

    /// These migrations only add tables and indexes, so they must skip the
    /// pre-migration full-file backup. On a real install that lane copies
    /// several gigabytes before the app can paint, which makes an additive
    /// migration landing on the wrong lane a launch regression rather than a
    /// cosmetic one.
    func test_theWarRoomMigrationsSkipTheFullBackupLane() {
        XCTAssertFalse(
            OpenBurnBarDatabase.requiresFullPreMigrationProtection(
                pendingMigrationIdentifiers: [
                    "v62_war_room_originator",
                    "v63_standing_orders",
                    "v64_token_usage_start_time_index",
                    "v65_memory_quarantine_bodies"
                ]
            )
        )
    }

    /// Fail-closed: one unreviewed migration in the batch puts the whole batch
    /// back on the protected lane.
    func test_anUnlistedMigrationForcesTheFullBackupLane() {
        XCTAssertTrue(
            OpenBurnBarDatabase.requiresFullPreMigrationProtection(
                pendingMigrationIdentifiers: ["v63_standing_orders", "v65_hypothetical_rewrite"]
            )
        )
    }

    func test_nothingPendingNeedsNoProtection() {
        XCTAssertFalse(
            OpenBurnBarDatabase.requiresFullPreMigrationProtection(pendingMigrationIdentifiers: [])
        )
    }
}
