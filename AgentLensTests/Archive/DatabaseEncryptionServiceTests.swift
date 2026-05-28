// Quarantined tests extracted from: DatabaseEncryptionServiceTests.swift
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

import GRDB
import XCTest
@testable import OpenBurnBar

final class DatabaseEncryptionServiceTests: XCTestCase {

    // MARK: - Quarantined Tests

    func testMakeConfigurationWithKey_reportsCipherVersion() throws {
        try XCTSkipIf(true, "Stale contract — SQLCipher PRAGMA cipher_version reporting requires a release build configuration.")
        let key = "k3y-" + String(repeating: "a", count: 32)
        let config = DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-enc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try DatabasePool(path: path, configuration: config)
        let version = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        XCTAssertNotNil(version)
        XCTAssertFalse(version?.isEmpty ?? true, "cipher_version should be set when using SQLCipher")
    }


}
