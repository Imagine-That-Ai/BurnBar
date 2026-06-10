import XCTest
@testable import OpenBurnBarCore

/// Regression tests for the widget-snapshot diff guard (ios-009).
///
/// `DashboardStore` runs its widget side effects on every Firestore listener
/// tick — across several concurrent store instances. `shouldWrite` is the
/// pure decision that lets identical snapshots skip the file write and the
/// `WidgetCenter` reload, preserving the iOS widget reload budget, while a
/// coarse staleness rewrite keeps the Large/XL "Updated" footer honest.
final class BurnBarWidgetSnapshotDiffTests: XCTestCase {

    func testHasSameContentIgnoresLastSync() {
        let base = makeSnapshot(lastSync: Date(timeIntervalSince1970: 1_000))
        let later = makeSnapshot(lastSync: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(base.hasSameContent(as: later))
        XCTAssertTrue(later.hasSameContent(as: base))
    }

    func testHasSameContentDetectsEveryRenderedFieldChange() {
        let base = makeSnapshot()

        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(heroTotalCost: 9.99)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(heroTotalTokens: 1)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(heroTotalRequests: 99)))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(topProviders: ["Codex"])))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(topProviderTokens: [1])))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(topModels: ["o3-mini"])))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(dailyPoints: [0.1])))
        XCTAssertFalse(base.hasSameContent(as: makeSnapshot(windowKey: "7d")))
    }

    func testShouldWriteWhenNoSnapshotExistsOnDisk() {
        XCTAssertTrue(BurnBarWidgetShared.shouldWrite(makeSnapshot(), replacing: nil))
    }

    func testShouldWriteWhenContentChanged() {
        let existing = makeSnapshot()
        let changed = makeSnapshot(heroTotalCost: 9.99)

        XCTAssertTrue(BurnBarWidgetShared.shouldWrite(changed, replacing: existing))
    }

    func testShouldSkipFreshIdenticalContent() {
        let existing = makeSnapshot(lastSync: Date(timeIntervalSince1970: 1_000))
        // One second later: same content, on-disk copy still fresh.
        let identical = makeSnapshot(lastSync: Date(timeIntervalSince1970: 1_001))

        XCTAssertFalse(BurnBarWidgetShared.shouldWrite(identical, replacing: existing))
    }

    func testShouldRewriteStaleIdenticalContentSoUpdatedFooterAdvances() {
        let existing = makeSnapshot(lastSync: Date(timeIntervalSince1970: 1_000))
        let staleBoundary = makeSnapshot(
            lastSync: Date(timeIntervalSince1970: 1_000 + BurnBarWidgetShared.snapshotStaleAfter)
        )
        let justUnderBoundary = makeSnapshot(
            lastSync: Date(timeIntervalSince1970: 999 + BurnBarWidgetShared.snapshotStaleAfter)
        )

        XCTAssertTrue(BurnBarWidgetShared.shouldWrite(staleBoundary, replacing: existing))
        XCTAssertFalse(BurnBarWidgetShared.shouldWrite(justUnderBoundary, replacing: existing))
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        heroTotalCost: Double = 3.42,
        heroTotalTokens: Int = 12_400,
        heroTotalRequests: Int = 18,
        topProviders: [String] = ["Claude"],
        topProviderTokens: [Int] = [5_200],
        topModels: [String] = ["claude-3.5-sonnet"],
        dailyPoints: [Double] = [0.3, 0.5, 0.8],
        windowKey: String = "today",
        lastSync: Date = Date(timeIntervalSince1970: 1_000)
    ) -> BurnBarWidgetSnapshot {
        BurnBarWidgetSnapshot(
            heroTotalCost: heroTotalCost,
            heroTotalTokens: heroTotalTokens,
            heroTotalRequests: heroTotalRequests,
            topProviders: topProviders,
            topProviderTokens: topProviderTokens,
            topModels: topModels,
            dailyPoints: dailyPoints,
            windowKey: windowKey,
            lastSync: lastSync
        )
    }
}
