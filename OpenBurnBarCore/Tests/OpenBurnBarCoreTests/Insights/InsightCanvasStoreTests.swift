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

    func testLRUEvictionRespectsMax() async throws {
        let store = try InsightCanvasStore(fileURL: fileURL)
        for i in 0..<(InsightCanvasStore.maxCanvases + 10) {
            var canvas = InsightCanvas(title: "C\(i)")
            // Spread updatedAt so eviction is deterministic.
            canvas.updatedAt = Date(timeIntervalSince1970: TimeInterval(i))
            try await store.upsert(canvas)
        }
        let all = await store.allCanvases()
        XCTAssertEqual(all.count, InsightCanvasStore.maxCanvases)
    }
}
