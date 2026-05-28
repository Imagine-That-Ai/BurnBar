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
                .claudeCode: EmptyParser(provider: .claudeCode),
            ],
            dataStore: store,
            orchestrator: RefreshOrchestrator(
                dataStore: store,
                settingsManager: SettingsManager.shared,
                quotaService: ProviderQuotaService(
                    appPaths: OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
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
                    appPaths: OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
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

        let parsed = await pipeline.parse(from: pipeline.discover())
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
                    appPaths: OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
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

        let parsed = await pipeline.parse(from: pipeline.discover())
        let typed = OpenBurnBarError.parse("simulated", message: "simulated parser failure")
        XCTAssertEqual(parsed.errors[.factory], typed.message)
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
