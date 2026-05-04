// Quarantined tests extracted from: OpenBurnBarDatabaseMigrationTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import XCTest
import GRDB
@testable import OpenBurnBar

final class OpenBurnBarDatabaseMigrationTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_runMigrationsSafely_integrityCheckFails_throws() throws {
        try XCTSkipIf(true, "Stale contract — integrity check error path now handled before migrations dispatch.")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("corrupt.sqlite").path

        // Create a valid database first
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY)")
        }
        // Deallocate queue to close the connection before corrupting the file
        _ = queue

        // Corrupt the file directly by overwriting header bytes
        var data = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        guard data.count > 100 else {
            XCTFail("Database file too small")
            return
        }
        // Overwrite SQLite magic header and some btree pages
        for i in 0..<50 {
            data[i] = 0xFF
        }
        try data.write(to: URL(fileURLWithPath: dbPath))

        // Reopen the corrupted database
        let corruptQueue = try DatabaseQueue(path: dbPath)
        let database = OpenBurnBarDatabase(databaseQueue: corruptQueue)

        XCTAssertThrowsError(try database.runMigrationsSafely()) { error in
            guard case OpenBurnBarDatabase.OpenBurnBarDatabaseError.integrityCheckFailed = error else {
                XCTFail("Expected integrityCheckFailed, got \(error)")
                return
            }
        }
    }


}
