import XCTest
import Foundation
import SQLite3
// S17 repoint: the only Core symbol this test reaches is `BurnBarSemanticSearchConfig`,
// public in OpenBurnBarVectorKit (an Engine leaf). `@testable import OpenBurnBarDaemon`
// links Engine, so the config resolves; the umbrella `@testable import OpenBurnBarCore`
// is replaced with the narrow leaf import so no daemon test retains an umbrella import.
@testable import OpenBurnBarVectorKit
@testable import OpenBurnBarDaemon

final class BurnBarIndexedSearchServiceMinimalTests: XCTestCase {
    private static let databaseKey = "indexed-search-minimal-" + String(repeating: "b", count: 32)

    func test_memoryCapAndReleaseSnapshot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db").path
        // Create the SQLite database file so READWRITE open succeeds
        var createHandle: OpaquePointer?
        let createResult = sqlite3_open(dbPath, &createHandle)
        XCTAssertEqual(createResult, SQLITE_OK)
        let handle = try XCTUnwrap(createHandle)
        try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(
            to: handle,
            key: Self.databaseKey
        )
        sqlite3_close(createHandle)

        let logger = BurnBarDaemonLogger(category: "test")

        // Build a tiny semantic config with a very low memory budget (1 MB)
        let semanticConfig = BurnBarSemanticSearchConfig(
            quantization: .scalarUInt8,
            memoryBudgetMB: 1,
            maxVectorCount: nil
        )

        let service = try BurnBarIndexedSearchService(
            databasePath: dbPath,
            logger: logger,
            semanticConfig: semanticConfig,
            databaseKeyOverride: Self.databaseKey
        )

        // Release snapshot should not crash when no snapshot is loaded
        service.releaseSnapshot()
        // Calling again should also be safe
        service.releaseSnapshot()
    }
}
