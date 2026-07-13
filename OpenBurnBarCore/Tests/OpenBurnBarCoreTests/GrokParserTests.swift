import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarLogParsers

final class GrokParserTests: XCTestCase {

    // MARK: - ISO8601 timestamp parsing

    /// parseISO8601 routes through the shared ThreadSafeISO8601DateFormatter;
    /// it must accept both fractional and non-fractional internet date-times
    /// and produce the same Dates the previous per-call formatters did.
    func test_parseISO8601_fractionalAndBasicMatchPreviousBehavior() {
        let parser = GrokParser()

        // 2026-07-06T12:34:56Z == 1_783_341_296 since epoch.
        let fractional = parser.parseISO8601("2026-07-06T12:34:56.789Z")
        XCTAssertNotNil(fractional)
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, 1_783_341_296.789, accuracy: 0.0005)

        let basic = parser.parseISO8601("2026-07-06T12:34:56Z")
        XCTAssertEqual(basic, Date(timeIntervalSince1970: 1_783_341_296))
    }

    func test_parseISO8601_acceptsOffsetsAndTrimsWhitespace() {
        let parser = GrokParser()

        // +08:00 offset resolves to the same instant as 04:34:56Z.
        XCTAssertEqual(
            parser.parseISO8601("2026-07-06T12:34:56+08:00"),
            Date(timeIntervalSince1970: 1_783_341_296 - 8 * 3600)
        )
        XCTAssertEqual(
            parser.parseISO8601("  2026-07-06T12:34:56Z\n"),
            Date(timeIntervalSince1970: 1_783_341_296)
        )
    }

    func test_parseISO8601_rejectsNilEmptyAndGarbage() {
        let parser = GrokParser()
        XCTAssertNil(parser.parseISO8601(nil))
        XCTAssertNil(parser.parseISO8601(""))
        XCTAssertNil(parser.parseISO8601("   "))
        XCTAssertNil(parser.parseISO8601("not-a-timestamp"))
        XCTAssertNil(parser.parseISO8601("2026-07-06 12:34:56"))
    }
}
