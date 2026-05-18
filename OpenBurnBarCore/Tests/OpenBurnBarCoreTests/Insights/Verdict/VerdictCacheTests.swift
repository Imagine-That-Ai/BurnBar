import XCTest
@testable import OpenBurnBarCore

final class VerdictCacheTests: XCTestCase {

    private func makeVerdict(window: VerdictWindow = .today, generatedAt: Date) -> InsightVerdict {
        InsightVerdict(
            generatedAt: generatedAt,
            window: window,
            headline: "You spent $1.00.",
            rings: [
                VerdictRing(identity: .spend, label: "Spend", current: 1, target: 2,
                            unit: .usd, valueLabel: "1/2"),
                VerdictRing(identity: .cache, label: "Cache", current: 1, target: 2,
                            unit: .percent, valueLabel: "1/2"),
                VerdictRing(identity: .sessions, label: "Sessions", current: 1, target: 2,
                            unit: .sessions, valueLabel: "1/2")
            ],
            provenance: InsightModelTag(providerKey: "p", modelID: "m", displayName: "M",
                                        egressTier: .localOnly)
        )
    }

    func testReadReturnsNilWhenEmpty() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let read = await cache.read(window: .today, deviceID: "dev")
        XCTAssertNil(read)
    }

    func testWriteThenReadRoundTripsInMemory() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let now = Date()
        let v = makeVerdict(generatedAt: now)
        await cache.write(v, deviceID: "dev", now: now)
        let read = await cache.read(window: .today, deviceID: "dev", now: now)
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.verdict.headline, v.headline)
        XCTAssertFalse(read?.isStale ?? true)
    }

    func testStalenessFiresAtTTLBoundary() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let base = Date(timeIntervalSince1970: 1_779_012_000) // 2026-05-16 12:00:00 UTC
        let v = makeVerdict(generatedAt: base)
        await cache.write(v, deviceID: "dev", now: base)
        let fresh = await cache.read(window: .today, deviceID: "dev",
                                     now: base.addingTimeInterval(VerdictWindow.today.cacheTTL / 2))
        XCTAssertEqual(fresh?.isStale, false)
        let stale = await cache.read(window: .today, deviceID: "dev",
                                     now: base.addingTimeInterval(VerdictWindow.today.cacheTTL + 1))
        XCTAssertEqual(stale?.isStale, true)
    }

    func testClearDeviceRemovesOnlyThatDevice() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let now = Date()
        await cache.write(makeVerdict(generatedAt: now), deviceID: "A", now: now)
        await cache.write(makeVerdict(generatedAt: now), deviceID: "B", now: now)
        await cache.clear(deviceID: "A")
        let a = await cache.read(window: .today, deviceID: "A", now: now)
        let b = await cache.read(window: .today, deviceID: "B", now: now)
        XCTAssertNil(a)
        XCTAssertNotNil(b)
    }

    func testReadMostRecentReturnsLatestBucket() async throws {
        let cache = VerdictCache(storage: .memoryOnly)
        let base = Date()
        let earlier = base.addingTimeInterval(-60 * 60 * 24 * 3) // 3 days ago bucket
        let now = base
        await cache.write(makeVerdict(generatedAt: earlier), deviceID: "dev", now: earlier)
        await cache.write(makeVerdict(generatedAt: now), deviceID: "dev", now: now)
        let recent = try await XCTUnwrapAsync(
            cache.readMostRecent(window: .today, deviceID: "dev", now: now)
        )
        XCTAssertEqual(
            recent.verdict.generatedAt.timeIntervalSinceReferenceDate,
            now.timeIntervalSinceReferenceDate,
            accuracy: 1
        )
    }

    /// `XCTUnwrap` re-thrown from a synchronous helper so async tests can
    /// unwrap actor return values without juggling `try` and `await`.
    private func XCTUnwrapAsync<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    func testDiskPersistenceSurvivesNewInstance() async throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        do {
            let cache = VerdictCache(storage: .onDisk(directory: tempDir))
            await cache.write(makeVerdict(generatedAt: now), deviceID: "dev", now: now)
        }
        do {
            let cache2 = VerdictCache(storage: .onDisk(directory: tempDir))
            let read = await cache2.read(window: .today, deviceID: "dev", now: now)
            XCTAssertNotNil(read, "cache should rehydrate from disk on new instance")
        }
    }

    func testCountReturnsBucketSize() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let now = Date()
        await cache.write(makeVerdict(generatedAt: now), deviceID: "dev", now: now)
        let count = await cache.count(deviceID: "dev", window: .today)
        XCTAssertEqual(count, 1)
    }
}
