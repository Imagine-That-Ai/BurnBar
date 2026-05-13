import XCTest
@testable import OpenBurnBarCore

final class InsightCacheAndAuditTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("insights-cache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testCacheKeyIsStable() {
        let a = InsightCache.key(digestContentHash: "abc",
                                 prompt: "what changed",
                                 modelID: "claude-sonnet-4-6",
                                 tier: .strictJSONSchema,
                                 instruction: .composeCanvas)
        let b = InsightCache.key(digestContentHash: "abc",
                                 prompt: "what changed",
                                 modelID: "claude-sonnet-4-6",
                                 tier: .strictJSONSchema,
                                 instruction: .composeCanvas)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func testCacheStoreAndLookup() async throws {
        let cache = try InsightCache(directoryURL: tempDir.appendingPathComponent("cache"))
        let key = "abc123"
        let canvas = InsightCanvas(title: "Cached")
        try await cache.store(.init(key: key, canvas: canvas, costSavedUSD: 0.01))
        let restored = await cache.lookup(key: key)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.canvas.title, "Cached")
    }

    func testAuditLogAppendAndRead() async throws {
        let log = try InsightAuditLog(fileURL: tempDir.appendingPathComponent("audit.jsonl"))
        let entry1 = InsightAuditLog.Entry(
            canvasID: nil,
            prompt: "p1",
            modelTag: .init(providerKey: "anthropic", modelID: "claude", displayName: "Claude", egressTier: .userKey),
            egressTier: .userKey,
            digestBytes: 1024,
            digestContentHash: "h1",
            instruction: "composeCanvas",
            status: .started
        )
        let entry2 = InsightAuditLog.Entry(
            canvasID: nil,
            prompt: "p2",
            modelTag: .init(providerKey: "anthropic", modelID: "claude", displayName: "Claude", egressTier: .userKey),
            egressTier: .userKey,
            digestBytes: 2048,
            digestContentHash: "h2",
            instruction: "composeCanvas",
            status: .succeeded
        )
        try await log.append(entry1)
        try await log.append(entry2)
        let all = try await log.readAll()
        XCTAssertEqual(all.count, 2)
        // readAll returns newest-first.
        XCTAssertEqual(all.first?.prompt, "p2")
        XCTAssertEqual(all.last?.prompt, "p1")
    }
}
