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
}
