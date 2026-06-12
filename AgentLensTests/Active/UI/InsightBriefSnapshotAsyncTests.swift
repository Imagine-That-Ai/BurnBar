#if canImport(AppKit)
import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// The chat surfaces (`ChatPanel` / `DashboardChatWorkspaceView`) moved their
/// `usagesVersion` refresh onto `InsightBriefSnapshot.buildAsync`, which runs
/// the rollup GRDB I/O off the main thread. The async variant must agree with
/// the synchronous bootstrap path on identical data, and `InsightBriefCard`
/// must still render and fire its action.
@MainActor
final class InsightBriefSnapshotAsyncTests: XCTestCase {
    private func makeDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    func test_buildAsyncAgreesWithSynchronousBuildOnTheSameStore() async throws {
        let dataStore = try makeDataStore()

        let sync = InsightBriefSnapshot.build(from: dataStore, refreshRollups: false)
        let async = await InsightBriefSnapshot.buildAsync(from: dataStore, refreshRollups: false)

        XCTAssertEqual(async.whereLeftOff, sync.whereLeftOff)
        XCTAssertEqual(async.whereLeftOffProject, sync.whereLeftOffProject)
        XCTAssertEqual(async.heaviestTaskTitle, sync.heaviestTaskTitle)
        XCTAssertEqual(async.heaviestTaskCost, sync.heaviestTaskCost)
        XCTAssertEqual(async.modelShiftHeadline, sync.modelShiftHeadline)
        XCTAssertEqual(async.incompleteHint, sync.incompleteHint)
        XCTAssertEqual(async.hasInlineContent, sync.hasInlineContent)
    }

    func test_buildAsyncOnEmptyStoreProducesQuietSnapshot() async throws {
        let dataStore = try makeDataStore()
        let snapshot = await InsightBriefSnapshot.buildAsync(from: dataStore, refreshRollups: true)
        XCTAssertNil(snapshot.whereLeftOff)
        XCTAssertNil(snapshot.heaviestTaskTitle)
    }

    func test_rollupStatusLineCoversEveryFreshnessState() {
        var snapshot = InsightBriefSnapshot()
        snapshot.rollupFreshness = .fresh
        XCTAssertNil(snapshot.rollupStatusLine)

        snapshot.rollupFreshness = .stale
        XCTAssertEqual(snapshot.rollupStatusLine, "Workflow insights are stale.")

        snapshot.rollupFreshness = .rebuilding
        XCTAssertEqual(snapshot.rollupStatusLine, "Workflow insights are rebuilding.")

        snapshot.rollupFreshness = .unavailable
        XCTAssertEqual(snapshot.rollupStatusLine, "Workflow insights are unavailable.")

        snapshot.rollupStatusMessage = "Custom detail"
        XCTAssertEqual(snapshot.rollupStatusLine, "Custom detail", "an explicit message wins over the canned line")
    }

    func test_insightBriefCardBodyRendersWithFixtureContent() {
        let card = InsightBriefCard(
            title: "Where you left off",
            bodyText: "Refactoring the relay opener in BurnBar",
            icon: "clock.arrow.circlepath",
            accent: .orange,
            action: {}
        )
        let image = renderViewSnapshot(card, size: CGSize(width: 320, height: 90), colorScheme: .dark)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            XCTFail("card did not render")
            return
        }
        var sawInk = false
        for x in stride(from: 0, to: rep.pixelsWide, by: 10) where !sawInk {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 10) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    sawInk = true
                    break
                }
            }
        }
        XCTAssertTrue(sawInk, "InsightBriefCard body must produce visible output")
    }
}
#endif
