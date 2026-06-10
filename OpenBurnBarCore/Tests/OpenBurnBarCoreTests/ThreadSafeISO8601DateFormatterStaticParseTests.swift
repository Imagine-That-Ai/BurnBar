import XCTest
@testable import OpenBurnBarCore

/// The synchronous static helpers back every log-ingestion timestamp parse, so
/// they share lock-guarded cached formatters instead of allocating one per call.
/// These tests pin the parsing semantics (fractional-then-basic for `parse`,
/// basic-only for `parseBasic`) and hammer the shared cache concurrently.
final class ThreadSafeISO8601DateFormatterStaticParseTests: XCTestCase {

    private let fractionalString = "2026-06-09T12:34:56.789Z"
    private let basicString = "2026-06-09T12:34:56Z"

    func testParseAcceptsFractionalTimestamps() {
        let date = ThreadSafeISO8601DateFormatter.parse(fractionalString)
        XCTAssertNotNil(date)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1781008496.789, accuracy: 0.001)
    }

    func testParseFallsBackToBasicTimestamps() {
        let date = ThreadSafeISO8601DateFormatter.parse(basicString)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1781008496))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(ThreadSafeISO8601DateFormatter.parse("not-a-date"))
        XCTAssertNil(ThreadSafeISO8601DateFormatter.parse(""))
    }

    func testParseBasicMatchesDefaultFormatterAcceptance() {
        // Gemini/Kimi/Warp previously parsed with a default-configured
        // ISO8601DateFormatter() ([.withInternetDateTime] only): basic strings
        // parse, fractional strings do not. parseBasic must preserve that.
        XCTAssertEqual(
            ThreadSafeISO8601DateFormatter.parseBasic(basicString),
            Date(timeIntervalSince1970: 1781008496)
        )
        XCTAssertNil(ThreadSafeISO8601DateFormatter.parseBasic(fractionalString))
        XCTAssertNil(ThreadSafeISO8601DateFormatter.parseBasic("not-a-date"))
    }

    func testConcurrentParsesOnSharedCacheStayCorrect() {
        // The cached formatters are shared across every parser thread; a race
        // would surface as a nil or wrong Date under contention.
        let expectedFractional = ThreadSafeISO8601DateFormatter.parse(fractionalString)
        let expectedBasic = ThreadSafeISO8601DateFormatter.parseBasic(basicString)
        XCTAssertNotNil(expectedFractional)
        XCTAssertNotNil(expectedBasic)

        DispatchQueue.concurrentPerform(iterations: 2_000) { iteration in
            if iteration.isMultiple(of: 2) {
                XCTAssertEqual(ThreadSafeISO8601DateFormatter.parse(fractionalString), expectedFractional)
            } else {
                XCTAssertEqual(ThreadSafeISO8601DateFormatter.parseBasic(basicString), expectedBasic)
            }
        }
    }
}
