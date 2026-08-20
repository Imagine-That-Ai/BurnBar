import XCTest
@testable import OpenBurnBarMobile

final class BurnbarAttachmentTransferSessionTests: XCTestCase {
    func testSignedPutRequestSetsGenerationMatchHeaders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("part.bin")
        let payload = Data(repeating: 9, count: 128)
        try payload.write(to: file)
        let request = BurnbarAttachmentTransferSession.signedPutRequest(
            fileURL: file,
            signedURL: URL(string: "https://storage.googleapis.com/test")!
        )
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "128")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-if-generation-match"), "0")
    }

    func testProcessPendingConsumesInboxAfterSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("share.bin")
        try Data("inbox".utf8).write(to: file)
        var begins = 0
        await BurnbarShareInboxProcessor.processPending(deviceId: "iphone-1", inbox: dir) { _, _ in
            begins += 1
        }
        XCTAssertEqual(begins, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await BurnbarShareInboxProcessor.processPending(deviceId: "iphone-1", inbox: dir) { _, _ in
            begins += 1
        }
        XCTAssertEqual(begins, 1)
    }
}
