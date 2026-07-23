import XCTest
@testable import OpenBurnBarInsights

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

    func testStalenessFiresAtTTLBoundary() async throws {
        let calendar = Self.utcCalendar()
        let cache = VerdictCache(storage: .memoryOnly, calendar: calendar)
        let base = try Self.utcDate("2026-05-16T12:00:00Z")
        let freshMoment = base.addingTimeInterval(VerdictWindow.today.cacheTTL / 2)
        let staleMoment = base.addingTimeInterval(VerdictWindow.today.cacheTTL + 1)

        XCTAssertEqual(
            VerdictWindow.today.dayBucketKey(for: base, calendar: calendar),
            VerdictWindow.today.dayBucketKey(for: staleMoment, calendar: calendar)
        )

        let v = makeVerdict(generatedAt: base)
        await cache.write(v, deviceID: "dev", now: base)
        let fresh = await cache.read(window: .today, deviceID: "dev",
                                     now: freshMoment)
        XCTAssertEqual(fresh?.isStale, false)
        let stale = await cache.read(window: .today, deviceID: "dev",
                                     now: staleMoment)
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

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func utcDate(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value), file: file, line: line)
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
        let key = Data(repeating: 0x42, count: 32)
        do {
            let cache = VerdictCache(storage: .onDisk(directory: tempDir, encryptionKey: key))
            await cache.write(makeVerdict(generatedAt: now), deviceID: "dev", now: now)
        }
        do {
            let cache2 = VerdictCache(storage: .onDisk(directory: tempDir, encryptionKey: key))
            let read = await cache2.read(window: .today, deviceID: "dev", now: now)
            XCTAssertNotNil(read, "cache should rehydrate from disk on new instance")
        }
    }

    func testDiskPersistenceDoesNotWriteReadableVerdictJSON() async throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let secretHeadline = "Sensitive local verdict headline"
        var verdict = makeVerdict(generatedAt: now)
        verdict.headline = secretHeadline
        let cache = VerdictCache(storage: .onDisk(directory: tempDir, encryptionKey: Data(repeating: 0x24, count: 32)))
        await cache.write(verdict, deviceID: "dev", now: now)

        let files = try XCTUnwrap(FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "sealed" }
        let sealedURL = try XCTUnwrap(files.first)
        let raw = try Data(contentsOf: sealedURL)
        let rendered = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertFalse(rendered.contains(secretHeadline))
        XCTAssertThrowsError(try JSONDecoder().decode([String: InsightVerdict].self, from: raw))
    }

    func testLegacyPlaintextDiskCacheMigratesToSealedStorage() async throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let verdict = makeVerdict(generatedAt: now)
        let deviceDir = tempDir.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
        let legacyURL = deviceDir.appendingPathComponent("\(VerdictWindow.today.rawValue).json")
        let bucket = VerdictWindow.today.dayBucketKey(for: verdict.generatedAt, calendar: .current)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([bucket: verdict]).write(to: legacyURL, options: [.atomic])

        let cache = VerdictCache(storage: .onDisk(directory: tempDir, encryptionKey: Data(repeating: 0x25, count: 32)))
        let read = await cache.read(window: .today, deviceID: "dev", now: now)

        XCTAssertNotNil(read)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: deviceDir.appendingPathComponent("\(VerdictWindow.today.rawValue).sealed").path
            )
        )
    }

    func testLegacyPlaintextDiskCacheIsPreservedWhenSealedMigrationWriteFails() async throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let verdict = makeVerdict(generatedAt: now)
        let deviceDir = tempDir.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
        let legacyURL = deviceDir.appendingPathComponent("\(VerdictWindow.today.rawValue).json")
        let sealedURL = deviceDir.appendingPathComponent("\(VerdictWindow.today.rawValue).sealed")
        try FileManager.default.createDirectory(at: sealedURL, withIntermediateDirectories: true)
        let bucket = VerdictWindow.today.dayBucketKey(for: verdict.generatedAt, calendar: .current)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([bucket: verdict]).write(to: legacyURL, options: [.atomic])

        let cache = VerdictCache(storage: .onDisk(directory: tempDir, encryptionKey: Data(repeating: 0x26, count: 32)))
        let read = await cache.read(window: .today, deviceID: "dev", now: now)

        XCTAssertNotNil(read)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCountReturnsBucketSize() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let now = Date()
        await cache.write(makeVerdict(generatedAt: now), deviceID: "dev", now: now)
        let count = await cache.count(deviceID: "dev", window: .today)
        XCTAssertEqual(count, 1)
    }
}
