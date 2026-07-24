import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class UsageRefreshPipelineTests: XCTestCase {
    func test_persistNewerCodexStateTotalReplacesStaleExactSnapshot() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        let exact = TokenUsage(
            provider: .codex,
            sessionId: "parent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 100,
            outputTokens: 10,
            cacheReadTokens: 890,
            costUSD: 0.001,
            startTime: now,
            endTime: now,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
        try await store.insert(exact)

        let estimate = TokenUsage(
            provider: .codex,
            sessionId: "parent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 4_500,
            outputTokens: 500,
            cacheReadTokens: 95_000,
            costUSD: 0.1,
            startTime: now,
            endTime: now,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "tokens-used-cache-split-v2"
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [:],
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
            existingUsages: [exact],
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )
        var parsed = UsageRefreshPipeline.ParsedBatch()
        parsed.allUsages = [estimate]

        let persisted = await pipeline.persist(parsed: parsed)
        let storedUsages = try await store.fetchAllUsage()
        let stored = try XCTUnwrap(storedUsages.first)

        XCTAssertNil(persisted.typedPersistenceError)
        XCTAssertEqual(stored.totalTokens, estimate.totalTokens)
        XCTAssertEqual(stored.cacheReadTokens, estimate.cacheReadTokens)
        XCTAssertEqual(stored.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(stored.provenanceConfidence, .lowConfidenceEstimate)
    }

    func test_persistOlderCodexEstimateDoesNotReplaceExactUsage() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        let exact = TokenUsage(
            provider: .codex,
            sessionId: "parent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 100,
            outputTokens: 10,
            cacheReadTokens: 890,
            costUSD: 0.001,
            startTime: now,
            endTime: now,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
        try await store.insert(exact)
        let olderEstimate = TokenUsage(
            provider: .codex,
            sessionId: "parent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 18,
            outputTokens: 2,
            cacheReadTokens: 380,
            costUSD: 0.0004,
            startTime: now,
            endTime: now,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "tokens-used-cache-split-v2"
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [:],
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
            existingUsages: [exact],
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )
        var parsed = UsageRefreshPipeline.ParsedBatch()
        parsed.allUsages = [olderEstimate]

        let persisted = await pipeline.persist(parsed: parsed)
        let storedUsages = try await store.fetchAllUsage()
        let stored = try XCTUnwrap(storedUsages.first)

        XCTAssertNil(persisted.typedPersistenceError)
        XCTAssertEqual(stored.totalTokens, exact.totalTokens)
        XCTAssertEqual(stored.cacheReadTokens, exact.cacheReadTokens)
        XCTAssertEqual(stored.provenanceMethod, .providerLog)
        XCTAssertEqual(stored.provenanceConfidence, .exact)
    }

    func test_persistDeletesParserInvalidationsBeforeInsertingFreshUsage() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        let stale = TokenUsage(
            provider: .codex,
            sessionId: "subagent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 1_000_000,
            outputTokens: 100_000,
            costUSD: 12,
            startTime: now,
            endTime: now
        )
        try await store.insert(stale)

        let fresh = TokenUsage(
            provider: .codex,
            sessionId: "parent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 100,
            outputTokens: 10,
            costUSD: 0.01,
            startTime: now,
            endTime: now
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [.codex: InvalidatingParser(freshUsage: fresh)],
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
            existingUsages: [stale],
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )

        let parsed = try await pipeline.parse(from: pipeline.discover())
        let persisted = await pipeline.persist(parsed: parsed)
        let stored = try await store.fetchAllUsage()

        XCTAssertNil(persisted.typedPersistenceError)
        XCTAssertEqual(stored.map(\.sessionId), ["parent-session"])
    }

    func test_parseUsesDedicatedResourceGovernorPerProvider() async throws {
        let store = try makeInMemoryDataStore()
        let pipeline = UsageRefreshPipeline(
            parsers: [
                .claudeCode: EmptyParser(provider: .claudeCode),
                .codex: EmptyParser(provider: .codex)
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
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )
        let governors: [AgentProvider: ParserResourceGovernor] = [
            .claudeCode: ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1)),
            .codex: ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1))
        ]
        var requestedProviders: [AgentProvider] = []

        _ = try await pipeline.parse(
            from: pipeline.discover(),
            resourceGovernorForProvider: { provider in
                requestedProviders.append(provider)
                return governors[provider]
            }
        )

        XCTAssertEqual(requestedProviders, [.claudeCode, .codex])
        XCTAssertNotEqual(
            ObjectIdentifier(try XCTUnwrap(governors[.claudeCode])),
            ObjectIdentifier(try XCTUnwrap(governors[.codex]))
        )
    }

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

    func test_singleProviderRefreshDeletesParserInvalidations() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        let stale = TokenUsage(
            provider: .codex,
            sessionId: "subagent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 1_000_000,
            outputTokens: 100_000,
            costUSD: 12,
            startTime: now,
            endTime: now
        )
        let fresh = TokenUsage(
            provider: .codex,
            sessionId: "parent-session",
            projectName: "BurnBar",
            model: "gpt-5.6-sol",
            inputTokens: 100,
            outputTokens: 10,
            costUSD: 0.01,
            startTime: now,
            endTime: now
        )
        try await store.insert(stale)

        let result = await RefreshBackgroundWork.runSingleProviderRefresh(
            provider: .codex,
            parser: InvalidatingParser(freshUsage: fresh),
            dataStore: store,
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )
        let stored = try await store.fetchAllUsage()

        XCTAssertNil(result.error)
        XCTAssertEqual(stored.map(\.sessionId), ["parent-session"])
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

private struct InvalidatingParser: LogParser {
    let provider: AgentProvider = .codex
    let freshUsage: TokenUsage

    func parse() async throws -> ParseResult {
        ParseResult(
            usages: [freshUsage],
            conversations: [],
            usageSessionIDsToDelete: ["subagent-session"]
        )
    }
}
