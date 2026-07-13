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

    func test_conversationIndexingDoesNotRepersistUsageRows() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "conversation-indexing-usage",
            projectName: "Indexing regression",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 0.01,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_001),
            usageSource: .providerLog,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        let orchestrator = RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )

        _ = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: RecordingParser(recorder: recorder, usages: [usage])],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        let persistedUsages = try await store.fetchAllUsage()
        XCTAssertTrue(persistedUsages.isEmpty)
    }

    private func makeInMemoryDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}

private struct EmptyParser: LogParser {
    let provider: AgentProvider

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }
}

private struct FailingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse() async throws -> ParseResult {
        throw OpenBurnBarError.parse("simulated", message: "simulated parser failure")
    }
}

private struct CancellingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse() async throws -> ParseResult {
        throw CancellationError()
    }
}

private actor ParseOptionsRecorder {
    private var values: [Bool] = []

    func record(_ includeConversationBodies: Bool) {
        values.append(includeConversationBodies)
    }

    func snapshot() -> [Bool] {
        values
    }
}

private struct RecordingParser: LogParser {
    let provider: AgentProvider = .factory
    let recorder: ParseOptionsRecorder
    var usages: [TokenUsage] = []

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        await recorder.record(options.includeConversationBodies)
        return ParseResult(usages: usages, conversations: [])
    }
}
