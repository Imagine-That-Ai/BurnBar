import XCTest
import Foundation
import SQLite3
@testable import OpenBurnBarCore
@testable import OpenBurnBarDaemon

final class BurnBarIndexedSearchServiceMinimalTests: XCTestCase {

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
            semanticConfig: semanticConfig
        )

        // Release snapshot should not crash when no snapshot is loaded
        service.releaseSnapshot()
        // Calling again should also be safe
        service.releaseSnapshot()
    }
}
