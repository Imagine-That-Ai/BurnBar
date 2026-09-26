import Foundation
import GRDB
import XCTest
@testable import OpenBurnBarData

/// Wave 2.6: fresh databases adopt `auto_vacuum=INCREMENTAL` at creation,
/// and pre-2.6 file databases get exactly one guided VACUUM (free-space
/// guarded; the pragma itself is the once-marker).
final class DatabaseVacuumPolicyTests: XCTestCase {
    private func makeTempDBPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vacuum-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("test.sqlite").path
    }

    private func autoVacuumMode(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? -1
        }
    }

    func test_freshDatabaseCreationPathYieldsIncrementalPlusWAL() throws {
        let queue = try DatabaseQueue(path: makeTempDBPath())
        // Mirror the production creation path: the prepareDatabase hook runs
        // first (auto_vacuum BEFORE journal_mode, outside any transaction),
        // then the post-open tuning re-sets the modes.
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try OpenBurnBarDatabase.configureWALMode(queue)

        // 2 == INCREMENTAL. Set before the header seals, it sticks — and the
        // post-open tuning preserves it.
        XCTAssertEqual(try autoVacuumMode(queue), 2)
        let journal = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journal?.lowercased(), "wal")
    }

    func test_legacyFileDatabasePlansReadyThenMigratesOnce() throws {
        let path = try makeTempDBPath()
        // Legacy shape: a table created without the auto_vacuum pragma.
        let legacy = try DatabaseQueue(path: path)
        try legacy.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO t (id) VALUES ('a')")
        }
        XCTAssertEqual(try autoVacuumMode(legacy), 0)

        // Plan says ready (tmp volume has room for a tiny rebuild)…
        let plan = try legacy.read { db in try DatabaseVacuumPolicy.migrationPlan(db) }
        guard case .ready(let bytes) = plan else {
            XCTFail("expected .ready, got \(plan)")
            return
        }
        XCTAssertGreaterThan(bytes, 0)

        // …the migration flips the mode, keeps the rows, and never fires twice.
        try DatabaseVacuumPolicy.migrateToIncrementalVacuum(legacy)
        XCTAssertEqual(try autoVacuumMode(legacy), 2)
        let rows = try legacy.read { db in try String.fetchAll(db, sql: "SELECT id FROM t") }
        XCTAssertEqual(rows, ["a"])
        let again = try legacy.read { db in try DatabaseVacuumPolicy.migrationPlan(db) }
        XCTAssertEqual(again, .unneeded)
    }

    func test_inMemoryDatabasesNeverNeedMigration() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        let plan = try queue.read { db in try DatabaseVacuumPolicy.migrationPlan(db) }
        XCTAssertEqual(plan, .unneeded)
    }
}
