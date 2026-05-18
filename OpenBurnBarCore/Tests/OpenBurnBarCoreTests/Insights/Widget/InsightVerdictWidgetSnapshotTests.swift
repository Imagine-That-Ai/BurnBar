import XCTest
@testable import OpenBurnBarCore

final class InsightVerdictWidgetSnapshotTests: XCTestCase {

    func testCodableRoundtrip() throws {
        let original = InsightVerdictWidgetSnapshot(
            headline: "You spent $4.12 yesterday — 28% under average.",
            spendCurrent: 4.12,
            spendTarget: 12.0,
            cacheCurrent: 91,
            cacheTarget: 85,
            sessionsCurrent: 3,
            sessionsTarget: 2,
            windowLabel: "Today",
            isStale: false,
            lastSync: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InsightVerdictWidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.headline, original.headline)
        XCTAssertEqual(decoded.spendCurrent, original.spendCurrent, accuracy: 0.001)
        XCTAssertEqual(decoded.cacheCurrent, original.cacheCurrent, accuracy: 0.001)
        XCTAssertEqual(decoded.sessionsCurrent, original.sessionsCurrent)
        XCTAssertEqual(decoded.windowLabel, original.windowLabel)
        XCTAssertEqual(decoded.isStale, original.isStale)
        XCTAssertEqual(decoded.lastSync, original.lastSync)
    }

    func testPreviewSnapshotIsValid() {
        let preview = InsightVerdictWidgetSnapshot.preview
        XCTAssertFalse(preview.headline.isEmpty)
        XCTAssertGreaterThan(preview.spendTarget, 0)
        XCTAssertGreaterThan(preview.cacheTarget, 0)
        XCTAssertGreaterThan(preview.sessionsTarget, 0)
    }

    func testHashableAndEquatable() {
        let a = InsightVerdictWidgetSnapshot.preview
        let b = InsightVerdictWidgetSnapshot.preview
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }
}
