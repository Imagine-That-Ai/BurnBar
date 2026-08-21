import Foundation
import XCTest
@testable import OpenBurnBarData

/// The SQLite value codecs.
///
/// Every one of these sits on the read path between a stored row and a typed
/// value, and each failure mode is quiet: a date that will not parse becomes nil
/// and the row loses its timestamp, a bool that will not parse becomes nil and a
/// flag silently reads as unset. None of it throws.
final class OpenBurnBarDatabaseDataCodecTests: XCTestCase {

    // MARK: Timestamp formatting

    /// The stored format is fixed-width UTC with milliseconds. Anything else and
    /// lexicographic ordering — which the schema relies on for range scans —
    /// stops matching chronological ordering.
    func test_sqliteDateStringIsFixedWidthUTCWithMillis() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let text = OpenBurnBarDatabase.sqliteDateString(date)
        XCTAssertEqual(text, "2023-11-14 22:13:20.123")
    }

    func test_sqliteDateStringPadsEveryField() {
        // 2001-02-03 04:05:06.007 UTC — every component needs zero-padding.
        var components = DateComponents()
        components.year = 2001; components.month = 2; components.day = 3
        components.hour = 4; components.minute = 5; components.second = 6
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: components)!
        let text = OpenBurnBarDatabase.sqliteDateString(base.addingTimeInterval(0.007))
        XCTAssertEqual(text, "2001-02-03 04:05:06.007")
    }

    /// Pre-1970 dates make `millisTotal % 1_000` negative, which is the one
    /// branch in the formatter that borrows a second. Without it the millisecond
    /// field renders negative and the timestamp is unparseable.
    func test_preEpochDatesBorrowASecondRatherThanEmittingNegativeMillis() {
        let date = Date(timeIntervalSince1970: -0.500)
        let text = OpenBurnBarDatabase.sqliteDateString(date)
        XCTAssertEqual(text, "1969-12-31 23:59:59.500")
        XCTAssertFalse(text.contains("-5"), "millisecond field must never be negative")
    }

    func test_epochItselfFormatsCleanly() {
        XCTAssertEqual(
            OpenBurnBarDatabase.sqliteDateString(Date(timeIntervalSince1970: 0)),
            "1970-01-01 00:00:00.000"
        )
    }

    // MARK: Date parsing

    func test_parseDateValueAcceptsEveryNumericShapeSQLiteReturns() {
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(OpenBurnBarDatabase.parseDateValue(expected), expected)
        XCTAssertEqual(OpenBurnBarDatabase.parseDateValue(TimeInterval(1_700_000_000)), expected)
        XCTAssertEqual(OpenBurnBarDatabase.parseDateValue(Int(1_700_000_000)), expected)
        XCTAssertEqual(OpenBurnBarDatabase.parseDateValue(Int64(1_700_000_000)), expected)
        XCTAssertEqual(OpenBurnBarDatabase.parseDateValue(NSNumber(value: 1_700_000_000)), expected)
    }

    /// ISO-8601 is the fallback for rows written by other surfaces, with and
    /// without fractional seconds.
    func test_parseDateValueFallsBackToISO8601BothWays() {
        XCTAssertNotNil(OpenBurnBarDatabase.parseDateValue("2023-11-14T22:13:20Z"))
        XCTAssertNotNil(OpenBurnBarDatabase.parseDateValue("2023-11-14T22:13:20.123Z"))
    }

    func test_parseDateValueRoundTripsWhatSqliteDateStringWrote() {
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        let text = OpenBurnBarDatabase.sqliteDateString(original)
        let parsed = OpenBurnBarDatabase.parseDateValue(text)
        XCTAssertNotNil(parsed, "a value this codec wrote must parse back")
        XCTAssertEqual(parsed!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.002)
    }

    func test_parseDateValueRejectsJunkAndNil() {
        XCTAssertNil(OpenBurnBarDatabase.parseDateValue(nil))
        XCTAssertNil(OpenBurnBarDatabase.parseDateValue("not a date"))
        XCTAssertNil(OpenBurnBarDatabase.parseDateValue(""))
    }

    // MARK: Bool parsing

    /// SQLite has no bool: the same flag comes back as 0/1, "0"/"1", or a real
    /// Bool depending on who wrote it.
    func test_parseBoolValueAcceptsTheShapesSQLiteActuallyStores() throws {
        XCTAssertTrue(try XCTUnwrap(OpenBurnBarDatabase.parseBoolValue(true)))
        XCTAssertFalse(try XCTUnwrap(OpenBurnBarDatabase.parseBoolValue(false)))
        XCTAssertTrue(try XCTUnwrap(OpenBurnBarDatabase.parseBoolValue(1)))
        XCTAssertFalse(try XCTUnwrap(OpenBurnBarDatabase.parseBoolValue(0)))
        XCTAssertTrue(
            try XCTUnwrap(OpenBurnBarDatabase.parseBoolValue(-1)),
            "any non-zero is true"
        )
    }

    func test_parseBoolValueRejectsNil() {
        XCTAssertNil(OpenBurnBarDatabase.parseBoolValue(nil))
    }

    // MARK: Placeholders and JSON arrays

    func test_sqlPlaceholdersMatchesTheRequestedCount() {
        XCTAssertEqual(OpenBurnBarDatabase.sqlPlaceholders(count: 1), "?")
        XCTAssertEqual(OpenBurnBarDatabase.sqlPlaceholders(count: 3), "?, ?, ?")
    }

    /// A zero or negative count must produce an empty string, not a stray "?" —
    /// an `IN ()` built from a stray placeholder binds nothing and the query
    /// fails at execution rather than at construction.
    func test_sqlPlaceholdersClampsAtZero() {
        XCTAssertEqual(OpenBurnBarDatabase.sqlPlaceholders(count: 0), "")
        XCTAssertEqual(OpenBurnBarDatabase.sqlPlaceholders(count: -3), "")
    }

    func test_stringArrayRoundTripsThroughJSON() throws {
        let original = ["alpha", "beta with space", "gamma\"quoted\""]
        let encoded = try OpenBurnBarDatabase.encodeJSONStringArray(original)
        XCTAssertEqual(OpenBurnBarDatabase.decodeJSONStringArray(encoded), original)
    }

    /// A null column and a malformed blob both have to degrade to empty rather
    /// than throwing on the read path.
    func test_decodeJSONStringArrayDegradesToEmpty() {
        XCTAssertEqual(OpenBurnBarDatabase.decodeJSONStringArray(nil), [])
        XCTAssertEqual(OpenBurnBarDatabase.decodeJSONStringArray("not json"), [])
        XCTAssertEqual(OpenBurnBarDatabase.decodeJSONStringArray(""), [])
    }
}
