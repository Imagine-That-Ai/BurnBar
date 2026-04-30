import Foundation
import XCTest
@testable import OpenBurnBar

final class OpenBurnBarStartupRecoveryTests: XCTestCase {
    private let fileManager = FileManager.default

    func test_failureDiagnostics_includeStoragePathsAndError() {
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: URL(fileURLWithPath: "/tmp/openburnbar-tests"))
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSLocalizedDescriptionKey: "Permission denied"
        ])

        let failure = DataStoreStartupFailure.make(
            error: error,
            paths: paths,
            occurredAt: Date(timeIntervalSince1970: 0),
            archiveURL: paths.startupRecoveryArchiveDirectory(timestamp: "19700101-000000"),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        XCTAssertTrue(failure.diagnostics.contains("Permission denied"))
        XCTAssertTrue(failure.diagnostics.contains(paths.supportDirectory.path))
        XCTAssertTrue(failure.diagnostics.contains(paths.databaseURL.path))
        XCTAssertTrue(failure.diagnostics.contains("StartupRecovery/19700101-000000"))
    }

    func test_databaseSidecarURLs_includePrimaryWalAndShm() {
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: URL(fileURLWithPath: "/tmp/openburnbar-tests"))

        XCTAssertEqual(paths.databaseSidecarURLs.map(\.lastPathComponent), [
            "openburnbar.sqlite",
            "openburnbar.sqlite-wal",
            "openburnbar.sqlite-shm",
        ])
    }

    func test_archiveDatabaseSidecars_copiesThenRemovesExistingSidecars() throws {
        let paths = try makePaths()
        try seedDatabaseSidecars(paths: paths, namesAndContents: [
            "openburnbar.sqlite": "db",
            "openburnbar.sqlite-wal": "wal",
            "openburnbar.sqlite-shm": "shm",
        ])

        let result = try OpenBurnBarStartupRecovery.archiveDatabaseSidecars(
            paths: paths,
            fileManager: fileManager,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.archiveDirectory.lastPathComponent, "19700101-000000")
        XCTAssertEqual(Set(result.archivedFiles.map(\.lastPathComponent)), [
            "openburnbar.sqlite",
            "openburnbar.sqlite-wal",
            "openburnbar.sqlite-shm",
        ])
        for sourceURL in paths.databaseSidecarURLs {
            XCTAssertFalse(fileManager.fileExists(atPath: sourceURL.path), "Expected source sidecar to be removed: \(sourceURL.path)")
        }
        XCTAssertEqual(
            try String(contentsOf: result.archiveDirectory.appendingPathComponent("openburnbar.sqlite"), encoding: .utf8),
            "db"
        )
    }

    func test_archiveDatabaseSidecars_createsEmptyArchiveWhenNoDatabaseFilesExist() throws {
        let paths = try makePaths()

        let result = try OpenBurnBarStartupRecovery.archiveDatabaseSidecars(
            paths: paths,
            fileManager: fileManager,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(fileManager.fileExists(atPath: result.archiveDirectory.path))
        XCTAssertTrue(result.archivedFiles.isEmpty)
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: result.archiveDirectory.path).isEmpty)
    }

    func test_archiveDatabaseSidecars_preservesOriginalsWhenArchiveDirectoryCannotBeCreated() throws {
        let paths = try makePaths()
        try seedDatabaseSidecars(paths: paths, namesAndContents: [
            "openburnbar.sqlite": "db",
            "openburnbar.sqlite-wal": "wal",
        ])
        try "not a directory".write(
            to: paths.startupRecoveryDirectory,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try OpenBurnBarStartupRecovery.archiveDatabaseSidecars(
                paths: paths,
                fileManager: fileManager,
                now: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(try String(contentsOf: paths.databaseURL, encoding: .utf8), "db")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: paths.databaseURL.path + "-wal"), encoding: .utf8), "wal")
    }

    func test_archiveDatabaseSidecars_usesUniqueDirectoryWhenTimestampAlreadyExists() throws {
        let paths = try makePaths()
        try seedDatabaseSidecars(paths: paths, namesAndContents: [
            "openburnbar.sqlite": "db"
        ])
        try fileManager.createDirectory(
            at: paths.startupRecoveryArchiveDirectory(timestamp: "19700101-000000"),
            withIntermediateDirectories: true
        )

        let result = try OpenBurnBarStartupRecovery.archiveDatabaseSidecars(
            paths: paths,
            fileManager: fileManager,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.archiveDirectory.lastPathComponent, "19700101-000000-2")
        XCTAssertEqual(
            try String(contentsOf: result.archiveDirectory.appendingPathComponent("openburnbar.sqlite"), encoding: .utf8),
            "db"
        )
    }

    private func makePaths() throws -> OpenBurnBarAppPaths {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: root)
        }
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: root)
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        return paths
    }

    private func seedDatabaseSidecars(paths: OpenBurnBarAppPaths, namesAndContents: [String: String]) throws {
        for (name, content) in namesAndContents {
            try content.write(
                to: paths.supportDirectory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
