import XCTest
@testable import OpenBurnBar

final class KimiParserStandaloneTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        let parser = KimiParser()
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = KimiParser()
        XCTAssertEqual(parser.provider, .kimi)
    }
}
