import XCTest
@testable import OpenBurnBarCore

/// Regression tests for the Insight Today snapshot diff guard (ios-006).
///
/// `InsightsMobileVerdictModel` writes a widget snapshot on every verdict
/// pipeline event (cached → rule-based → LLM) and now reloads the
/// `com.openburnbar.app.insightstoday` timeline when a write lands.
/// `shouldWrite` is the pure decision that lets identical snapshots skip
/// both the file write and the `WidgetCenter` reload, preserving the iOS
/// widget reload budget.
final class InsightVerdictWidgetSnapshotDiffTests: XCTestCase {

    func testHasSameContentIgnoresLastSync() {
        let base = makeSnapshot(lastSync: Date(timeIntervalSince1970: 1_000))
        let later = makeSnapshot(lastSync: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(base.hasSameContent(as: later))
        XCTAssertTrue(later.hasSameContent(as: base))
    }

    func testHasSameContentDetectsEveryRenderedFieldChange() {
        let base = makeSnapshot()

        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(headline: "Different headline")))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(spendCurrent: 9.99)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(spendTarget: 99)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(cacheCurrent: 1)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(cacheTarget: 1)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(sessionsCurrent: 99)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(sessionsTarget: 99)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(windowLabel: "Yesterday")))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(isStale: true)))
    }

    func testShouldWriteWhenNoSnapshotExistsOnDisk() {
        XCTAssertTrue(InsightWidgetShared.shouldWrite(makeSnapshot(), replacing: nil))
    }

    func testShouldWriteWhenContentChanged() {
        let existing = makeSnapshot()
        let changed = makeSnapshot(spendCurrent: 9.99)

        XCTAssertTrue(InsightWidgetShared.shouldWrite(changed, replacing: existing))
    }

    func testShouldSkipIdenticalContentRegardlessOfLastSync() {
        let existing = makeSnapshot(lastSync: Date(timeIntervalSince1970: 1_000))
        // Much later: same content — no staleness rewrite for this widget,
        // nothing it renders derives from `lastSync`.
        let identical = makeSnapshot(lastSync: Date(timeIntervalSince1970: 100_000))

        XCTAssertFalse(InsightWidgetShared.shouldWrite(identical, replacing: existing))
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        headline: String = "You spent $4.12 yesterday — 28% under average.",
        spendCurrent: Double = 4.12,
        spendTarget: Double = 12.0,
        cacheCurrent: Double = 91,
        cacheTarget: Double = 85,
        sessionsCurrent: Int = 3,
        sessionsTarget: Int = 2,
        windowLabel: String = "Today",
        isStale: Bool = false,
        lastSync: Date = Date(timeIntervalSince1970: 1_000)
    ) -> InsightVerdictWidgetSnapshot {
        InsightVerdictWidgetSnapshot(
            headline: headline,
            spendCurrent: spendCurrent,
            spendTarget: spendTarget,
            cacheCurrent: cacheCurrent,
            cacheTarget: cacheTarget,
            sessionsCurrent: sessionsCurrent,
            sessionsTarget: sessionsTarget,
            windowLabel: windowLabel,
            isStale: isStale,
            lastSync: lastSync
        )
    }
}
