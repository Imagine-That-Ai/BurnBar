import XCTest
@testable import OpenBurnBarMobile

// MARK: - Secure Pasteboard (T-IOS-05)
//
// Locks the TTL contract for sensitive clipboard writes (tokens / URLs / curl /
// Mac-clipboard text). The expiration math is pure, so it is testable without
// UIPasteboard; the .localOnly + .expirationDate options are applied by `copy`.

final class SecurePasteboardTests: XCTestCase {

    func testExpirationIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiry = SecurePasteboard.expirationDate(from: now, ttl: 90)
        XCTAssertEqual(expiry.timeIntervalSince(now), 90, accuracy: 0.001)
        XCTAssertGreaterThan(expiry, now, "A sensitive clipboard write must expire after it is made")
    }

    func testDefaultTTLIsBounded() {
        // Long enough to switch apps and paste, short enough to bound exposure.
        XCTAssertGreaterThan(SecurePasteboard.defaultTTL, 0)
        XCTAssertLessThanOrEqual(SecurePasteboard.defaultTTL, 300)
    }

    func testCustomTTLApplied() {
        let now = Date(timeIntervalSince1970: 0)
        let expiry = SecurePasteboard.expirationDate(from: now, ttl: 5)
        XCTAssertEqual(expiry.timeIntervalSince1970, 5, accuracy: 0.001)
    }
}
