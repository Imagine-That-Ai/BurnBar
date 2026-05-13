import XCTest
@testable import OpenBurnBarCore

final class InsightCanvasStoreTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("insights-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("canvases.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testEmptyStoreInitializesAndPersists() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        let all = await store.allCanvases()
        XCTAssertTrue(all.isEmpty)
    }

    func testUpsertAndRetrieve() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        let canvas = InsightCanvas(title: "First")
        try await store.upsert(canvas)
        let restored = await store.canvas(id: canvas.id)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.title, "First")
    }

    func testRoundTripThroughDisk() async throws {
        let store1 = try InsightCanvasStore(fileURL: fileURL)
        let canvas = InsightCanvas(title: "Persisted")
        try await store1.upsert(canvas)

        let store2 = try InsightCanvasStore(fileURL: fileURL)
        let all = await store2.allCanvases()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Persisted")
    }

    func testRemove() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        let canvas = InsightCanvas(title: "Doomed")
        try await store.upsert(canvas)
        try await store.remove(id: canvas.id)
        let restored = await store.canvas(id: canvas.id)
        XCTAssertNil(restored)
    }

    func testReorderUpdatesSortIndex() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        let a = InsightCanvas(title: "A")
        let b = InsightCanvas(title: "B")
        let c = InsightCanvas(title: "C")
        try await store.upsert(a)
        try await store.upsert(b)
        try await store.upsert(c)

        try await store.reorder([c.id, a.id, b.id])
        let all = await store.allCanvases()
        XCTAssertEqual(all.map(\.title), ["C", "A", "B"])
    }

    func testUpsertAccumulatesBeyondLegacySoftLimit() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        for i in 0..<(InsightCanvasStore.legacySoftCanvasLimit + 10) {
            var canvas = InsightCanvas(title: "C\(i)")
            canvas.updatedAt = Date(timeIntervalSince1970: TimeInterval(i))
            try await store.upsert(canvas)
        }
        let all = await store.allCanvases()
        XCTAssertEqual(all.count, InsightCanvasStore.legacySoftCanvasLimit + 10)
        XCTAssertNotNil(all.first { $0.title == "C0" })
        XCTAssertNotNil(all.first { $0.title == "C\(InsightCanvasStore.legacySoftCanvasLimit + 9)" })
    }

    func testReplaceAllMergesImportWithoutDroppingExistingCanvases() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        let existing = InsightCanvas(
            title: "Existing",
            updatedAt: Date(timeIntervalSince1970: 100),
            sortIndex: 0
        )
        let imported = InsightCanvas(
            title: "Imported",
            updatedAt: Date(timeIntervalSince1970: 200),
            sortIndex: 1
        )

        try await store.upsert(existing)
        try await store.replaceAll([imported])

        let all = await store.allCanvases()
        XCTAssertEqual(all.count, 2)
        XCTAssertNotNil(all.first { $0.id == existing.id })
        XCTAssertNotNil(all.first { $0.id == imported.id })
    }

    func testMergePreservesExistingOrderAndAppendsNewIDs() {
        let canvasA = InsightCanvas(
            title: "A",
            updatedAt: Date(timeIntervalSince1970: 100),
            sortIndex: 0
        )
        let canvasB = InsightCanvas(
            title: "B",
            updatedAt: Date(timeIntervalSince1970: 100),
            sortIndex: 1
        )
        let updatedA = InsightCanvas(
            id: canvasA.id,
            title: "A updated",
            updatedAt: Date(timeIntervalSince1970: 200),
            sortIndex: 0
        )
        let canvasC = InsightCanvas(
            title: "C",
            updatedAt: Date(timeIntervalSince1970: 100),
            sortIndex: 2
        )

        let merged = InsightCanvasStore.mergedCanvases(existing: [canvasA, canvasB], incoming: [updatedA, canvasC])

        XCTAssertEqual(merged.map(\.id), [canvasA.id, canvasB.id, canvasC.id])
        XCTAssertEqual(merged.first?.title, "A updated")
    }

    func testReplaceAllChoosesHigherRevisionForSameCanvasID() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        let canvasID = UUID()
        var oldLayout = InsightLayout(revision: 1)
        oldLayout.placeNew(widgetID: UUID(), defaultSpan: (columns: 1, rows: 1))
        var newerLayout = oldLayout
        newerLayout.revision = oldLayout.revision + 10

        let existing = InsightCanvas(
            id: canvasID,
            title: "Old",
            layout: oldLayout,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let imported = InsightCanvas(
            id: canvasID,
            title: "New",
            layout: newerLayout,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        try await store.upsert(existing)
        try await store.replaceAll([imported])

        let maybeRestored = await store.canvas(id: canvasID)
        let restored = try XCTUnwrap(maybeRestored)
        XCTAssertEqual(restored.title, "New")
        XCTAssertEqual(restored.layout.revision, newerLayout.revision)
    }
}
