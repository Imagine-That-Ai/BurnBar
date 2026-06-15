@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Tests for the shared `readTokenFile` utility used by
/// `--gateway-auth-token-file` and `--socket-auth-token-file` CLI flags.
/// These tests exercise the actual production function, not a copy of its
/// logic, so a refactor cannot silently diverge.
final class BurnBarDaemonTokenFileTests: XCTestCase {

    private func makeTokenFile(content: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("token")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    func testReadTokenFileTrimsTrailingNewline() throws {
        let path = try makeTokenFile(content: "gateway-secret-12345\n")
        let token = try readTokenFile(path)
        XCTAssertEqual(token, "gateway-secret-12345")
    }

    func testReadTokenFileTrimsLeadingAndTrailingWhitespace() throws {
        let path = try makeTokenFile(content: "  \n  socket-secret-67890  \n  ")
        let token = try readTokenFile(path)
        XCTAssertEqual(token, "socket-secret-67890")
    }

    func testReadTokenFileRejectsEmptyContent() throws {
        let path = try makeTokenFile(content: "\n  \n")
        XCTAssertThrowsError(try readTokenFile(path)) { error in
            guard case .emptyOrWhitespace = error as? BurnBarTokenFileError else {
                XCTFail("Expected .emptyOrWhitespace, got \(error)")
                return
            }
        }
    }

    func testReadTokenFileRejectsMissingFile() throws {
        let nonexistentPath = "/tmp/openburnbar-nonexistent-token-\(UUID().uuidString)"
        XCTAssertThrowsError(try readTokenFile(nonexistentPath)) { error in
            guard case .fileNotFound = error as? BurnBarTokenFileError else {
                XCTFail("Expected .fileNotFound, got \(error)")
                return
            }
        }
    }

    func testReadTokenFilePreservesInternalWhitespace() throws {
        let path = try makeTokenFile(content: "token with internal spaces\n")
        let token = try readTokenFile(path)
        XCTAssertEqual(token, "token with internal spaces")
    }
}
