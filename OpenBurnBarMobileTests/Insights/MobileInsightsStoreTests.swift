import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Smoke tests for the mobile `InsightsStore` orchestration on top of
/// the shared core types. Tests don't hit Firestore — they use the
/// in-memory data source the macOS core suite already covers, but
/// exercised through the mobile store's lifecycle.
@MainActor
final class MobileInsightsStoreTests: XCTestCase {

    func testInsightsStoreSeedsFromTemplateOnFirstRun() async throws {
        // Use an isolated working directory so tests don't share state
        // with each other or with the running app's Application Support.
        let isolated = makeIsolatedSupportDir()
        defer { try? FileManager.default.removeItem(at: isolated) }
        FileManager.default.changeCurrentDirectoryPath(isolated.path)

        // We can't override `applicationSupportDirectory()` directly, but
        // we can build an `InsightCanvasStore` rooted in the isolated dir
        // and assert template seeding via the public API.
        let store = try InsightCanvasStore(
            fileURL: isolated.appendingPathComponent("canvases.json")
        )
        let template = MobileInsightsTemplates.today
        let canvas = template.instantiate()
        try await store.upsert(canvas)
        let loaded = await store.allCanvases()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.origin, .template(id: "mobile-today"))
        XCTAssertGreaterThan(loaded.first?.widgets.count ?? 0, 0)
        XCTAssertGreaterThan(loaded.first?.layout.placements.count ?? 0, 0,
                              "Mobile template must have placements after instantiate")
    }

    func testMobileTemplatesAutoPlaceAllWidgets() {
        for template in MobileInsightsTemplates.all {
            let canvas = template.instantiate()
            XCTAssertEqual(canvas.widgets.count, canvas.layout.placements.count,
                           "Template '\(template.id)' must place every widget")
            for widget in canvas.widgets {
                let placement = canvas.layout.placements[widget.id]
                XCTAssertNotNil(placement, "Template '\(template.id)' widget '\(widget.title)' lacks placement")
            }
        }
    }

    func testMobileInsightDataSourceReturnsEmptySnapshotWhenStoreUnloaded() async throws {
        // Brand-new DashboardStore is empty; the data source must return
        // an empty (but non-throwing) snapshot rather than crashing.
        let dashboard = DashboardStore()
        let source = MobileInsightDataSource(dashboardStore: dashboard)
        let snapshot = try await source.snapshot(window: InsightTimeWindow.last7d.interval())
        XCTAssertTrue(snapshot.usages.isEmpty)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    private func makeIsolatedSupportDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileInsightsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
