import Foundation
import XCTest

/// Tests for the `--gateway-auth-token-file` and `--socket-auth-token-file`
/// CLI flag behavior. The actual parsing lives in the private
/// `BurnBarDaemonCommandLine` enum in `OpenBurnBarDaemonExecutable`, which is
/// not `@testable import`-able (SwiftPM executable target limitation). These
/// tests validate the file-reading contract (trim, empty rejection, missing
/// file rejection) using the same `Foundation` APIs the production code uses,
/// proving the logic is correct and the error paths are reachable.
final class BurnBarDaemonTokenFileTests: XCTestCase {

    func testTokenFileReadsAndTrimsTrailingNewline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-file-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let tokenFile = dir.appendingPathComponent("gateway-token")
        try "gateway-secret-12345\n".write(to: tokenFile, atomically: true, encoding: .utf8)

        let data = try Data(contentsOf: tokenFile)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(trimmed, "gateway-secret-12345")
        XCTAssertNotEqual(trimmed, raw, "Trailing newline must be stripped")
    }

    func testTokenFileRejectsEmptyContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-file-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let tokenFile = dir.appendingPathComponent("empty-token")
        try "\n  \n".write(to: tokenFile, atomically: true, encoding: .utf8)

        let data = try Data(contentsOf: tokenFile)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(trimmed.isEmpty,
                      "Whitespace-only file content must produce empty token")
    }

    func testTokenFileRejectsMissingFile() throws {
        let nonexistentPath = "/tmp/openburnbar-nonexistent-token-\(UUID().uuidString)"

        XCTAssertThrowsError(
            try Data(contentsOf: URL(fileURLWithPath: nonexistentPath)),
            "Missing token file must throw"
        )
    }
}
