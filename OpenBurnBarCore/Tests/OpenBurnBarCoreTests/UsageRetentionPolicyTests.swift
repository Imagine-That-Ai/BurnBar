import XCTest
@testable import OpenBurnBarCore

final class UsageRetentionPolicyTests: XCTestCase {
    func testDefaultWindowIs180Days() {
        XCTAssertEqual(UsageRetentionPolicy.defaultRetentionDays, 180)
    }

    func testReapsEventsOlderThanCutoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-181 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-10 * 24 * 60 * 60)
        XCTAssertTrue(UsageRetentionPolicy.shouldReap(eventDate: old, now: now))
        XCTAssertFalse(UsageRetentionPolicy.shouldReap(eventDate: recent, now: now))
    }
}
