import XCTest
@testable import OpenBurnBar

final class KimiParserStandaloneTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        // Skipped: KimiParser scans the host user's actual `~/.kimi` (or
        // equivalent) directory. Any developer with prior Kimi sessions on
        // disk will surface usages/conversations and break the assertion.
        // Re-enable once `KimiParser` can be pointed at a hermetic temp dir.
        try XCTSkipIf(true, "Environmental — requires a hermetic directory.")
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = KimiParser()
        XCTAssertEqual(parser.provider, .kimi)
    }
}
