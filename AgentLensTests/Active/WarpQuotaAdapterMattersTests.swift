import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Focused coverage for the previously error-swallowing `try?` site in
/// `WarpQuotaAdapter.candidateLogFiles(in:fileManager:)`.
///
/// The old code did `(try? fileManager.contentsOfDirectory(...)) ?? []`, which
/// silently turned an enumeration fault on an *existing* directory into "no log
/// files" with no signal. The fix routes the throwing call through
/// `AppLogger.sync.silently(...)` so the loss is observable while still
/// degrading gracefully to the empty-list fallback. These tests pin both the
/// graceful-degradation contract and the happy-path filtering/sorting so the
/// logging wrapper can never regress the returned `[URL]`.
final class WarpQuotaAdapterMattersTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - Enumeration-fault path (the fixed site)

    func test_candidateLogFiles_enumerationThrows_degradesToEmptyWithoutCrashing() throws {
        let directory = try makeTemporaryDirectory()
        // Seed a matching log so a *successful* enumeration would return a result;
        // the throwing FileManager must still yield [] (graceful degradation).
        try writeLog(named: "warp_network_0.log", in: directory)

        let adapter = WarpQuotaAdapter()
        let throwingManager = ThrowingEnumerationFileManager(
            existingPaths: [directory.path]
        )
        let context = try makeContext(fileManager: throwingManager)

        let result = adapter.candidateLogFiles(in: directory, fileManager: throwingManager, context: context)

        XCTAssertTrue(throwingManager.didAttemptEnumeration,
                      "The adapter must actually attempt enumeration before degrading.")
        XCTAssertEqual(result, [],
                       "An enumeration fault on an existing directory must degrade to []")
    }

    func test_candidateLogFiles_missingDirectory_returnsEmptyWithoutEnumerating() throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appendingPathComponent("does-not-exist", isDirectory: true)

        let adapter = WarpQuotaAdapter()
        let throwingManager = ThrowingEnumerationFileManager(existingPaths: [])
        let context = try makeContext(fileManager: throwingManager)

        let result = adapter.candidateLogFiles(in: missing, fileManager: throwingManager, context: context)

        XCTAssertFalse(throwingManager.didAttemptEnumeration,
                       "A non-existent directory must short-circuit before enumeration.")
        XCTAssertEqual(result, [])
    }

    // MARK: - Happy path (logging wrapper preserves [URL] contract)

    func test_candidateLogFiles_filtersToWarpNetworkLogs_sortedOldestFirst() throws {
        let directory = try makeTemporaryDirectory()

        // Matching files (warp_network*.log) plus distractors that must be excluded.
        let older = try writeLog(named: "warp_network_old.log", in: directory)
        let newer = try writeLog(named: "warp_network_new.log", in: directory)
        _ = try writeLog(named: "warp_network_old.txt", in: directory)      // wrong extension
        _ = try writeLog(named: "unrelated.log", in: directory)             // wrong prefix

        // Make `newer` strictly more recent than `older`.
        try setModificationDate(Date(timeIntervalSince1970: 1_000), on: older)
        try setModificationDate(Date(timeIntervalSince1970: 2_000), on: newer)

        let adapter = WarpQuotaAdapter()
        let context = try makeContext(fileManager: .default)
        let result = adapter.candidateLogFiles(in: directory, fileManager: .default, context: context)

        XCTAssertEqual(result.map { $0.lastPathComponent },
                       ["warp_network_old.log", "warp_network_new.log"],
                       "Only warp_network*.log files survive, sorted oldest-first.")
    }

    func test_candidateLogFiles_emptyDirectory_returnsEmpty() throws {
        let directory = try makeTemporaryDirectory()

        let adapter = WarpQuotaAdapter()
        let context = try makeContext(fileManager: .default)
        let result = adapter.candidateLogFiles(in: directory, fileManager: .default, context: context)

        XCTAssertEqual(result, [])
    }

    // MARK: - Helpers

    private func makeContext(fileManager: FileManager) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths.live()
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: URLSession.shared,
            environment: [:],
            homeDirectoryURL: appPaths.applicationSupportRoot,
            snapshotStore: snapshotStore,
            bridgeManager: ClaudeQuotaBridgeManager(
                appPaths: appPaths,
                homeDirectoryURL: appPaths.applicationSupportRoot,
                fileManager: fileManager,
                snapshotStore: snapshotStore
            ),
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: [:]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarpQuotaAdapterMattersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    @discardableResult
    private func writeLog(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("placeholder".utf8).write(to: url)
        return url
    }

    private func setModificationDate(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// A `FileManager` that reports configured paths as existing but throws from
/// `contentsOfDirectory(at:includingPropertiesForKeys:options:)`, simulating a
/// sandbox/permission/IO fault on an otherwise-present directory.
private final class ThrowingEnumerationFileManager: FileManager {
    private let existingPaths: Set<String>
    private(set) var didAttemptEnumeration = false

    init(existingPaths: [String]) {
        self.existingPaths = Set(existingPaths)
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        didAttemptEnumeration = true
        throw CocoaError(.fileReadNoPermission)
    }
}
