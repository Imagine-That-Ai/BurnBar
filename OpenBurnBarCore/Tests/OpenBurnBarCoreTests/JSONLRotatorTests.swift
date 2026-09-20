import XCTest
@testable import OpenBurnBarCore

final class JSONLRotatorTests: XCTestCase {
    func testDoesNotRotateUnderCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("obb-jsonl-\(UUID().uuidString).jsonl")
        try Data("hello\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let rotated = try JSONLRotator.rotateIfNeeded(url: url, maxBytes: 1024)
        XCTAssertNil(rotated)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello\n")
    }

    func testRotatesWhenAtOrOverCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("obb-jsonl-\(UUID().uuidString).jsonl")
        let payload = Data(repeating: 0x61, count: 64)
        try payload.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let rotated = try JSONLRotator.rotateIfNeeded(url: url, maxBytes: 32, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(rotated)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        XCTAssertEqual(try Data(contentsOf: rotated!).count, 64)
        try? FileManager.default.removeItem(at: rotated!)
    }
}
