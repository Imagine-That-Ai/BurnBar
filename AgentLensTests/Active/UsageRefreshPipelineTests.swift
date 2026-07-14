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

    func test_persistRemovesParserInvalidatedUsageRows() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        try await store.insertChunked([
            TokenUsage(
                provider: .codex,
                sessionId: "mirrored-child",
                projectName: "OpenBurnBar",
                model: "gpt-5.2-codex",
                inputTokens: 100,
                outputTokens: 10,
                startTime: now,
                endTime: now
            ),
            TokenUsage(
                provider: .codex,
                sessionId: "mirrored-child#day-123",
                projectName: "OpenBurnBar",
                model: "gpt-5.2-codex",
                inputTokens: 50,
                outputTokens: 5,
                startTime: now,
                endTime: now
            ),
            TokenUsage(
                provider: .codex,
                sessionId: "mirrored-child-sibling",
                projectName: "OpenBurnBar",
                model: "gpt-5.2-codex",
                inputTokens: 25,
                outputTokens: 2,
                startTime: now,
                endTime: now
            ),
        ])
        let pipeline = UsageRefreshPipeline(
            parsers: [.codex: DeletionParser()],
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
        let persisted = await pipeline.persist(parsed: parsed)

        XCTAssertNil(persisted.persistenceErrorMessage)
        let remainingUsage = try await store.fetchAllUsage()
        XCTAssertEqual(remainingUsage.map(\.sessionId), ["mirrored-child-sibling"])
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

private struct DeletionParser: LogParser {
    let provider: AgentProvider = .codex

    func parse() async throws -> ParseResult {
        ParseResult(
            usages: [],
            conversations: [],
            usageSessionIDsToDelete: ["mirrored-child"]
        )
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
