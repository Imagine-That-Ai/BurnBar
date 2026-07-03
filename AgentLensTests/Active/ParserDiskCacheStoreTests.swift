import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - ParserDiskCacheStoreTests

final class ParserDiskCacheStoreTests: XCTestCase {

    private var tempDir: URL!
    private var cacheURL: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cacheURL = tempDir.appendingPathComponent("test_cache.json")
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private struct TestEntry: Codable, Equatable {
        let signature: FileSignature
        let payload: String
    }

    private func makeStore(schemaVersion: Int = 1) -> ParserDiskCacheStore<TestEntry> {
        ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: schemaVersion,
            logLabel: "TestStore"
        )
    }

    // MARK: - Tests

    func test_loadReturnsEmptyWhenFileMissing() {
        let store = makeStore()
        let cache = store.load()
        XCTAssertTrue(cache.fileEntries.isEmpty)
        XCTAssertEqual(cache.schemaVersion, 1)
    }

    func test_persistAndLoadRoundTrip() throws {
        let store = makeStore()
        var cache = store.load()

        let entry = TestEntry(
            signature: FileSignature(modifiedAt: 1_700_000_000, sizeBytes: 42),
            payload: "hello"
        )
        cache.fileEntries["key1"] = entry
        store.persist(cache)

        let loaded = store.load()
        XCTAssertEqual(loaded.fileEntries.count, 1)
        XCTAssertEqual(loaded.fileEntries["key1"], entry)
    }

    func test_schemaVersionMismatchEvictsCache() throws {
        let oldStore = makeStore(schemaVersion: 1)
        var cache = oldStore.load()
        cache.fileEntries["key1"] = TestEntry(
            signature: FileSignature(modifiedAt: 1_700_000_000, sizeBytes: 42),
            payload: "hello"
        )
        oldStore.persist(cache)

        let newStore = makeStore(schemaVersion: 2)
        let loaded = newStore.load()
        XCTAssertTrue(loaded.fileEntries.isEmpty)
        XCTAssertEqual(loaded.schemaVersion, 2)
    }

    func test_pruneRemovesStaleKeys() throws {
        let store = makeStore()
        var cache = store.load()
        cache.fileEntries["keep"] = TestEntry(
            signature: FileSignature(modifiedAt: 1, sizeBytes: 1),
            payload: "a"
        )
        cache.fileEntries["remove"] = TestEntry(
            signature: FileSignature(modifiedAt: 2, sizeBytes: 2),
            payload: "b"
        )
        store.persist(cache)

        var loaded = store.load()
        loaded.prune(staleKeys: ["remove"])
        XCTAssertEqual(loaded.fileEntries.count, 1)
        XCTAssertNotNil(loaded.fileEntries["keep"])
    }

    func test_persistsWithLastUpdatedAt() throws {
        let store = makeStore()
        var cache = store.load()
        cache.fileEntries["key1"] = TestEntry(
            signature: FileSignature(modifiedAt: 1, sizeBytes: 1),
            payload: "a"
        )
        store.persist(cache)

        let data = try Data(contentsOf: cacheURL)
        // Round-4 perf sweep: caches are now binary plist, not JSON.
        let raw = try PropertyListDecoder().decode([String: AnyCodable].self, from: data)
        XCTAssertNotNil(raw["lastUpdatedAt"])
    }

    func test_persistWritesBinaryPlistFormat() throws {
        let store = makeStore()
        var cache = store.load()
        cache.fileEntries["key1"] = TestEntry(
            signature: FileSignature(modifiedAt: 1, sizeBytes: 1),
            payload: "a"
        )
        store.persist(cache)

        let data = try Data(contentsOf: cacheURL)
        // Binary plist magic bytes: `bplist`
        XCTAssertEqual(String(data: data.prefix(6), encoding: .ascii), "bplist")
    }

    func test_loadUpgradesLegacyJSONCacheInPlace() throws {
        // Write a legacy JSON cache (pre-round-4 format) directly to disk.
        let legacyCache = ParserDiskCache<TestEntry>(
            schemaVersion: 1,
            fileEntries: [
                "legacy": TestEntry(
                    signature: FileSignature(modifiedAt: 1_700_000_000, sizeBytes: 99),
                    payload: "old-format"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(legacyCache)
        try jsonData.write(to: cacheURL, options: .atomic)

        // The store's dual-read must load the legacy JSON cache transparently.
        let store = makeStore()
        let loaded = store.load()
        XCTAssertEqual(loaded.fileEntries.count, 1)
        XCTAssertEqual(loaded.fileEntries["legacy"]?.payload, "old-format")

        // After a persist, the file on disk is now binary plist.
        store.persist(loaded)
        let data = try Data(contentsOf: cacheURL)
        XCTAssertEqual(String(data: data.prefix(6), encoding: .ascii), "bplist")

        // And the binary plist round-trips identically.
        let reloaded = store.load()
        XCTAssertEqual(reloaded.fileEntries["legacy"]?.payload, "old-format")
    }

    func test_multipleEntriesPersistedAtomically() throws {
        let store = makeStore()
        var cache = store.load()
        for i in 0..<100 {
            cache.fileEntries["key\(i)"] = TestEntry(
                signature: FileSignature(modifiedAt: Double(i), sizeBytes: Int64(i)),
                payload: "value\(i)"
            )
        }
        store.persist(cache)

        let loaded = store.load()
        XCTAssertEqual(loaded.fileEntries.count, 100)
        for i in 0..<100 {
            XCTAssertEqual(loaded.fileEntries["key\(i)"]?.payload, "value\(i)")
        }
    }
}

// Minimal AnyCodable helper for decoding arbitrary JSON shapes in tests.
private struct AnyCodable: Codable {
    var value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let date = try? container.decode(Date.self) {
            value = date
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let date = value as? Date {
            try container.encode(date)
        } else {
            try container.encode("\(value)")
        }
    }
}
