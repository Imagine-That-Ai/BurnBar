import Foundation
import XCTest
@testable import OpenBurnBarKernel

#if canImport(ObjectiveC)
/// Stands in for Firestore's `Timestamp`, which the codec deliberately
/// duck-types through its `dateValue()` selector so the Kernel never has to
/// import FirebaseFirestore.
private final class InboxTimestampLikeObject: NSObject {
    private let wrapped: Date

    init(wrapped: Date) {
        self.wrapped = wrapped
        super.init()
    }

    @objc func dateValue() -> Date { wrapped }
}
#endif

/// Value coercion at the Firestore boundary.
///
/// Firestore hands back `Timestamp` on Apple platforms, `NSNumber` for
/// integers, and ISO strings from locally-encoded fixtures. Each shape must
/// coerce, and anything unrecognizable must coerce to `nil` rather than a
/// garbage value that would file an inbox row under the wrong date.
final class AIInboxMirrorCodecCoercionTests: XCTestCase {
    // MARK: - Dates

    func test_dateValueAcceptsISO8601Strings() throws {
        let parsed = try XCTUnwrap(AIInboxMirrorCodec.dateValue("2026-08-05T12:30:00Z"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-05T12:30:00Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_dateValueAcceptsEpochSeconds() throws {
        let seconds: Double = 1_754_300_000
        let parsed = try XCTUnwrap(AIInboxMirrorCodec.dateValue(seconds))
        XCTAssertEqual(parsed.timeIntervalSince1970, seconds, accuracy: 0.001)
    }

    #if canImport(ObjectiveC)
    func test_dateValueAcceptsTimestampLikeObjectsViaDuckTyping() throws {
        let date = Date(timeIntervalSince1970: 1_754_300_123)
        let parsed = try XCTUnwrap(
            AIInboxMirrorCodec.dateValue(InboxTimestampLikeObject(wrapped: date)),
            "An object exposing dateValue() must decode like Firestore's Timestamp"
        )
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
    #endif

    func test_dateValueRejectsUnrecognizableValues() {
        XCTAssertNil(AIInboxMirrorCodec.dateValue(nil))
        XCTAssertNil(AIInboxMirrorCodec.dateValue("not a timestamp"))
        XCTAssertNil(AIInboxMirrorCodec.dateValue(NSObject()))
    }

    // MARK: - Integers

    func test_intValueCoercesNumbersAndNumericStrings() {
        XCTAssertEqual(AIInboxMirrorCodec.intValue(7), 7)
        XCTAssertEqual(
            AIInboxMirrorCodec.intValue(NSNumber(value: 7.9)), 7,
            "A fractional NSNumber truncates instead of dropping the field"
        )
        XCTAssertEqual(AIInboxMirrorCodec.intValue(Double(3.2)), 3)
        XCTAssertEqual(AIInboxMirrorCodec.intValue("42"), 42)
    }

    func test_intValueRejectsUnrecognizableValues() {
        XCTAssertNil(AIInboxMirrorCodec.intValue(nil))
        XCTAssertNil(AIInboxMirrorCodec.intValue("forty-two"))
        XCTAssertNil(AIInboxMirrorCodec.intValue(NSObject()))
    }
}
