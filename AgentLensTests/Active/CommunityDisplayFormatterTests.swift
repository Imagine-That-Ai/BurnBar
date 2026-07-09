import XCTest
@testable import OpenBurnBarCore

final class CommunityDisplayFormatterTests: XCTestCase {
    func testCompactTokenCountUsesStablePOSIXSuffixes() {
        XCTAssertEqual(CommunityDisplayFormatter.compactTokenCount(-1), "0")
        XCTAssertEqual(CommunityDisplayFormatter.compactTokenCount(999), "999")
        XCTAssertEqual(CommunityDisplayFormatter.compactTokenCount(1_000), "1.0K")
        XCTAssertEqual(CommunityDisplayFormatter.compactTokenCount(12_345), "12.3K")
        XCTAssertEqual(CommunityDisplayFormatter.compactTokenCount(1_250_000), "1.3M")
    }

    func testParticipantDisplayNamePrefersTrimmedHandleAndFallsBackToAnonymousPrefix() {
        XCTAssertEqual(
            CommunityDisplayFormatter.participantDisplayName(handle: "  ember_fox  ", anonId: "abcdef123456"),
            "ember_fox"
        )
        XCTAssertEqual(
            CommunityDisplayFormatter.participantDisplayName(handle: " ", anonId: "abcdef123456"),
            "anon-abcdef"
        )
    }

    func testBelowThresholdCopyDoesNotLeakHiddenCohortSize() {
        XCTAssertEqual(
            CommunityDisplayFormatter.thresholdNeededCount(kThreshold: 10, cohortSize: 0),
            10
        )
        XCTAssertEqual(
            CommunityDisplayFormatter.thresholdNeededCount(kThreshold: 10, cohortSize: 9),
            1
        )
        XCTAssertEqual(
            CommunityDisplayFormatter.thresholdNeededCount(kThreshold: 10, cohortSize: 10),
            1
        )
        XCTAssertEqual(
            CommunityDisplayFormatter.belowThresholdTitle(kThreshold: 10, cohortSize: 0, tierLabel: "World"),
            "Needs 10 more burners in world"
        )
    }
}
