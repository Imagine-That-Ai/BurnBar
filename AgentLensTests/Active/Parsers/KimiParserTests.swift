import XCTest
@testable import OpenBurnBar

final class KimiParserStandaloneTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-kimi-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parser = KimiParser(logDirectoryOverride: tempDir.path)
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty, "Empty directory should yield no usages")
        XCTAssertTrue(result.conversations.isEmpty, "Empty directory should yield no conversations")
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = KimiParser()
        XCTAssertEqual(parser.provider, .kimi)
    }
}
