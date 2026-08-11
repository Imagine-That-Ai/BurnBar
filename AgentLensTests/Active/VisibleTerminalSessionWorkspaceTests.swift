import XCTest
@testable import OpenBurnBar

/**
 * Regression coverage for F-RR09-005: visible Terminal.app CLI sessions must
 * create a restricted transcript workspace and remove it on exit.
 *
 * The actual `runVisibleTerminalProcess` path launches Terminal.app, which is
 * not practical in XCTest. These tests exercise the extracted filesystem helper
 * directly, which is the only place the permission/cleanup invariant lives.
 */
final class VisibleTerminalSessionWorkspaceTests: XCTestCase {

    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
    }

    override func tearDown() {
        fileManager = nil
        super.tearDown()
    }

    func testPrepareCreatesSessionDirectoryWithOwnerOnlyPermissions() throws {
        let workspace = try VisibleTerminalSessionWorkspace.prepare(
            sessionID: "test-owner-only-\(UUID().uuidString)",
            fileManager: fileManager
        )
        defer { workspace.cleanup(fileManager: fileManager) }

        XCTAssertTrue(fileManager.fileExists(atPath: workspace.sessionURL.path))

        let attrs = try fileManager.attributesOfItem(atPath: workspace.sessionURL.path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? Int)
        XCTAssertEqual(permissions, 0o700, "session directory must be owner-only")
    }

    func testPreparePreCreatesTranscriptLogWithOwnerReadWritePermissions() throws {
        let workspace = try VisibleTerminalSessionWorkspace.prepare(
            sessionID: "test-log-perms-\(UUID().uuidString)",
            fileManager: fileManager
        )
        defer { workspace.cleanup(fileManager: fileManager) }

        XCTAssertTrue(fileManager.fileExists(atPath: workspace.logURL.path))

        let attrs = try fileManager.attributesOfItem(atPath: workspace.logURL.path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? Int)
        XCTAssertEqual(permissions, 0o600, "transcript log must be owner read/write only")
    }

    func testCleanupRemovesEntireSessionDirectory() throws {
        let workspace = try VisibleTerminalSessionWorkspace.prepare(
            sessionID: "test-cleanup-\(UUID().uuidString)",
            fileManager: fileManager
        )

        XCTAssertTrue(fileManager.fileExists(atPath: workspace.sessionURL.path))

        workspace.cleanup(fileManager: fileManager)

        XCTAssertFalse(fileManager.fileExists(atPath: workspace.sessionURL.path))
    }

    func testCleanupIsIdempotent() throws {
        let workspace = try VisibleTerminalSessionWorkspace.prepare(
            sessionID: "test-idempotent-\(UUID().uuidString)",
            fileManager: fileManager
        )

        workspace.cleanup(fileManager: fileManager)
        workspace.cleanup(fileManager: fileManager)

        XCTAssertFalse(fileManager.fileExists(atPath: workspace.sessionURL.path))
    }

    func testPrepareThrowsOnEmptySessionID() {
        XCTAssertThrowsError(
            try VisibleTerminalSessionWorkspace.prepare(sessionID: "", fileManager: fileManager)
        ) { error in
            XCTAssertEqual(
                error as? VisibleTerminalSessionWorkspace.PreparationError,
                .emptySessionID
            )
        }
    }

    func testPrepareThrowsWhenLogFileCreationFails() throws {
        let failingFileManager = FailingCreateFileManager()

        XCTAssertThrowsError(
            try VisibleTerminalSessionWorkspace.prepare(
                sessionID: "test-log-failure-\(UUID().uuidString)",
                fileManager: failingFileManager
            )
        ) { error in
            guard case let .logFileCreationFailed(url) = error as? VisibleTerminalSessionWorkspace.PreparationError else {
                XCTFail("expected logFileCreationFailed, got \(error)")
                return
            }
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".log"))
        }
    }
}

// MARK: - Test doubles

private final class FailingCreateFileManager: FileManager, @unchecked Sendable {
    override func createFile(
        atPath path: String,
        contents data: Data?,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        false
    }
}
