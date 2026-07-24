import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class UsageRefreshPipelineTests: XCTestCase {
    func test_discoverSortsProvidersDeterministically() throws {
        let store = try makeInMemoryDataStore()
        let pipeline = UsageRefreshPipeline(
            parsers: [
                .zai: EmptyParser(provider: .zai),
                .claudeCode: EmptyParser(provider: .claudeCode)
            ],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let discovery = pipeline.discover()
        XCTAssertEqual(
            discovery.parserEntries.map(\.0),
            [.claudeCode, .zai]
        )
    }

    func test_parseStageCapturesProviderFailures() async throws {
        let store = try makeInMemoryDataStore()
        let failing = FailingParser()
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: failing],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover())
        XCTAssertEqual(parsed.errors[.factory], "simulated parser failure")
        XCTAssertEqual(parsed.parserHealth[.factory]?.statusLabel, "failed")
    }

    func test_parseStageUsesTypedOpenBurnBarErrorMetricKey() async throws {
        let store = try makeInMemoryDataStore()
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: FailingParser()],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover())
        let typed = OpenBurnBarError.parse("simulated", message: "simulated parser failure")
        XCTAssertEqual(parsed.errors[.factory], typed.message)
    }

    func test_parseStagePropagatesCancellation() async throws {
        let store = try makeInMemoryDataStore()
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: CancellingParser()],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        do {
            _ = try await pipeline.parse(from: pipeline.discover())
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            // Expected: cancellation must not be swallowed as a parser failure.
        }
    }

    func test_parseStageCanSkipConversationBodiesForFastUsageImport() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: RecordingParser(recorder: recorder)],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: true,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(
            from: pipeline.discover(),
            includeConversationBodies: false
        )

        let recordedOptions = await recorder.snapshot()
        XCTAssertEqual(recordedOptions, [false])
        XCTAssertTrue(parsed.allConversations.isEmpty)
    }

    func test_parseStageForwardsMinimumFileModificationDate() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: RecordingParser(recorder: recorder)],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        _ = try await pipeline.parse(
            from: pipeline.discover(),
            minimumFileModificationDate: cutoff
        )

        let recordedDates = await recorder.minimumDateSnapshot()
        XCTAssertEqual(recordedDates, [cutoff])
    }

    func test_refreshPipelineReplacesInvalidatedLifetimeAndDayRows() async throws {
        let store = try makeInMemoryDataStore()
        let replacement = ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "parent#day-200",
            model: "gpt-5.6-sol",
            inputTokens: 200,
            outputTokens: 20
        )
        let factoryReplacement = ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "factory-parent#day-200",
            model: "glm-5"
        )
        try await store.insert(ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent"))
        try await store.insert(ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent#day-100"))
        try await store.insert(ViewTestFixtures.makeUsage(provider: .claudeCode, sessionId: "parent"))

        let pipeline = UsageRefreshPipeline(
            parsers: [
                .codex: RepairParser(replacement: replacement),
                .factory: RepairParser(provider: .factory, replacement: factoryReplacement)
            ],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            existingUsages: [],
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )

        let parsed = try await pipeline.parse(from: pipeline.discover())
        XCTAssertEqual(parsed.usageSessionIDsToDeleteByProvider[.codex], ["parent"])
        XCTAssertEqual(parsed.usageSessionIDsToDeleteByProvider[.factory], ["parent"])
        let persisted = await pipeline.persist(parsed: parsed)
        XCTAssertNil(persisted.persistenceErrorMessage)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(Set(rows.filter { $0.provider == .codex }.map(\.sessionId)), ["parent#day-200"])
        XCTAssertEqual(Set(rows.filter { $0.provider == .claudeCode }.map(\.sessionId)), ["parent"])
    }

    func test_conversationIndexingUsesSeparateBodyEnabledPass() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let orchestrator = RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )

        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: RecordingParser(recorder: recorder)],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        let recordedOptions = await recorder.snapshot()
        XCTAssertEqual(recordedOptions, [true])
        XCTAssertEqual(result.indexedConversationChanges, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func test_conversationIndexingCapturesProviderFailures() async throws {
        let store = try makeInMemoryDataStore()
        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: FailingParser()],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            indexingEnabled: true
        )

        XCTAssertEqual(result.errors[.factory], "simulated parser failure")
        XCTAssertGreaterThanOrEqual(result.duration, 0)
    }

    func test_conversationIndexingStopsCleanlyOnCancellation() async throws {
        let store = try makeInMemoryDataStore()
        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: CancellingParser()],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                    homeDirectoryURL: FileManager.default.temporaryDirectory,
                    refreshProviders: []
                )
            ),
            indexingEnabled: true
        )

        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.indexedConversationChanges, 0)
        XCTAssertEqual(result.duration, 0)
    }

    func test_fullRefreshKeepsConversationBodiesOffForegroundPass() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let orchestrator = RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )

        _ = try await RefreshBackgroundWork.runFullRefresh(
            parsers: [.factory: RecordingParser(recorder: recorder)],
            dataStore: store,
            orchestrator: orchestrator,
            existingUsages: [],
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: true,
                snapshotAPIs: []
            )
        )

        let recordedOptions = await recorder.snapshot()
        XCTAssertEqual(recordedOptions, [false])
    }

    func test_singleProviderRefreshKeepsConversationBodiesOffForegroundPass() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()

        _ = await RefreshBackgroundWork.runSingleProviderRefresh(
            provider: .factory,
            parser: RecordingParser(recorder: recorder),
            dataStore: store,
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: true,
                snapshotAPIs: []
            )
        )

        let recordedOptions = await recorder.snapshot()
        XCTAssertEqual(recordedOptions, [false])
    }

    func test_singleProviderRefreshAppliesUsageInvalidations() async throws {
        let store = try makeInMemoryDataStore()
        let replacement = ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "parent#day-200",
            model: "gpt-5.6-sol"
        )
        try await store.insert(ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent"))
        try await store.insert(ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent#day-100"))

        let result = await RefreshBackgroundWork.runSingleProviderRefresh(
            provider: .codex,
            parser: RepairParser(replacement: replacement),
            dataStore: store,
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )

        XCTAssertNil(result.error)
        let rows = try await store.fetchAllUsage().filter { $0.provider == .codex }
        XCTAssertEqual(rows.map(\.sessionId), ["parent#day-200"])
    }

    private func makeOrchestrator(store: DataStore) -> RefreshOrchestrator {
        RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )
    }

    private func makeInMemoryDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}

private struct EmptyParser: LogParser {
    let provider: AgentProvider

    func parse(options _: LogParseOptions) async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }
}

private struct FailingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse(options _: LogParseOptions) async throws -> ParseResult {
        throw OpenBurnBarError.parse("simulated", message: "simulated parser failure")
    }
}

private struct CancellingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse(options _: LogParseOptions) async throws -> ParseResult {
        throw CancellationError()
    }
}

private struct RepairParser: LogParser {
    let provider: AgentProvider
    let replacement: TokenUsage

    init(provider: AgentProvider = .codex, replacement: TokenUsage) {
        self.provider = provider
        self.replacement = replacement
    }

    func parse(options _: LogParseOptions) async throws -> ParseResult {
        ParseResult(
            usages: [replacement],
            conversations: [],
            usageSessionIDsToDelete: ["parent"]
        )
    }
}

private actor ParseOptionsRecorder {
    private var values: [Bool] = []
    private var minimumDates: [Date?] = []

    func record(_ options: LogParseOptions) {
        values.append(options.includeConversationBodies)
        minimumDates.append(options.minimumFileModificationDate)
    }

    func snapshot() -> [Bool] {
        values
    }

    func minimumDateSnapshot() -> [Date?] {
        minimumDates
    }
}

private struct RecordingParser: LogParser {
    let provider: AgentProvider = .factory
    let recorder: ParseOptionsRecorder

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        await recorder.record(options)
        return ParseResult(usages: [], conversations: [])
    }
}
