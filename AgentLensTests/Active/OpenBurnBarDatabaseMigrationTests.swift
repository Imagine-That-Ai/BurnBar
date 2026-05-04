import XCTest
import GRDB
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarDatabaseMigrationTests: XCTestCase {

    // MARK: - Integrity Check

    func test_runMigrationsSafely_runsMigrations_onFreshDB() throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        // Verify a v1 table exists
        let tables = try queue.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(tables.contains("token_usage"))
    }

    // MARK: - Backup

    func test_runMigrationsSafely_createsBackup_forFileBasedDB() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 1, "Expected one backup file, got: \(backups)")
    }

    func test_runMigrationsSafely_skipsBackup_forInMemoryDB() throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        // Should not throw and should not attempt file backup
        try database.runMigrationsSafely()
    }

    func test_runMigrationsSafely_prunesOldBackups() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed 7 fake backup files with staggered dates
        for i in 0..<7 {
            let name = "test.sqlite.backup.2026010\(i)-120000"
            let url = tempDir.appendingPathComponent(name)
            try "backup".write(to: url, atomically: true, encoding: .utf8)
            // Adjust modification date so they sort predictably
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path
            )
        }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        try database.runMigrationsSafely()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.contains(".backup.") }
        XCTAssertEqual(backups.count, 5, "Expected 5 backups after pruning, got: \(backups)")
    }
}
