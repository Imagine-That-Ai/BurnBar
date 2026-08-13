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

    func test_perProviderRefreshBudget_keepsAFloorAndDoesNotCollapseToZero() {
        XCTAssertEqual(
            ParserResourcePolicy.perProviderRefreshFileByteBudget(providerCount: 1),
            ParserResourcePolicy.refreshPassFileByteBudget
        )
        XCTAssertEqual(
            ParserResourcePolicy.perProviderRefreshFileByteBudget(providerCount: 4),
            ParserResourcePolicy.refreshFileByteBudget
        )
        let thirty = ParserResourcePolicy.perProviderRefreshFileByteBudget(providerCount: 30)
        XCTAssertGreaterThanOrEqual(thirty, ParserResourcePolicy.refreshFileByteBudgetFloor)
        XCTAssertLessThanOrEqual(thirty, ParserResourcePolicy.refreshFileByteBudget)
    }

    func test_liveLane_dropsHistoricalUsagesAndSetsARecentCutoff() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let stale = ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "old",
            startTime: Date(timeIntervalSince1970: 1_600_000_000),
            endTime: Date(timeIntervalSince1970: 1_600_000_060)
        )
        let live = ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "live",
            startTime: Date(),
            endTime: Date()
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [
                .factory: RecordingParser(recorder: recorder, usages: [stale, live])
            ],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover(), lane: .live)
        XCTAssertEqual(parsed.allUsages.map(\.sessionId), ["live"])
        let cutoffs = await recorder.minimumDateSnapshot()
        XCTAssertEqual(cutoffs.count, 1)
        let cutoff = try XCTUnwrap(cutoffs[0])
        XCTAssertGreaterThan(cutoff, Date().addingTimeInterval(-UsageIngestionPolicy.liveWindow - 5))
        XCTAssertLessThan(cutoff, Date())
    }

    func test_liveLane_doesNotDeleteHistoricalIDsWithoutAPublishedReplacement() async throws {
        let store = try makeInMemoryDataStore()
        let staleReplacement = ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "parent#day-100",
            startTime: Date(timeIntervalSince1970: 1_600_000_000),
            endTime: Date(timeIntervalSince1970: 1_600_000_060)
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [
                .codex: RepairParser(replacement: staleReplacement)
            ],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover(), lane: .live)
        XCTAssertTrue(parsed.allUsages.isEmpty)
        XCTAssertTrue(parsed.usageSessionIDsToDeleteByProvider[.codex, default: []].isEmpty)
    }

    func test_liveLane_appliesDeleteWhenALiveReplacementIsPublished() async throws {
        let store = try makeInMemoryDataStore()
        let liveReplacement = ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "parent#day-200",
            startTime: Date(),
            endTime: Date()
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [.codex: RepairParser(replacement: liveReplacement)],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover(), lane: .live)
        XCTAssertEqual(parsed.allUsages.map(\.sessionId), ["parent#day-200"])
        XCTAssertEqual(parsed.usageSessionIDsToDeleteByProvider[.codex], ["parent"])
    }

    func test_liveLane_omitsCachedUnchangedUsages() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: RecordingParser(recorder: recorder)],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        _ = try await pipeline.parse(from: pipeline.discover(), lane: .live)
        let liveCached = await recorder.includeCachedSnapshot()
        XCTAssertEqual(liveCached, [false])

        _ = try await pipeline.parse(from: pipeline.discover(), lane: .catchUp)
        let catchUpCached = await recorder.includeCachedSnapshot()
        XCTAssertEqual(catchUpCached, [false, true])
    }

    func test_persistGate_doesNotInterleaveConcurrentBodies() async {
        let gate = UsageIngestPersistGate()
        let counter = PersistGateCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.withLock {
                        await counter.enter()
                        try? await Task.sleep(nanoseconds: 15_000_000)
                        await counter.leave()
                    }
                }
            }
        }
        let maxInFlight = await counter.maxInFlight
        XCTAssertEqual(maxInFlight, 1)
    }

    func test_deletesSafeForLivePublish_requiresAReplacement() {
        XCTAssertEqual(
            UsageIngestionPolicy.deletesSafeForLivePublish(
                ["parent"],
                publishedSessionIDs: ["parent#day-200"]
            ),
            ["parent"]
        )
        XCTAssertEqual(
            UsageIngestionPolicy.deletesSafeForLivePublish(
                ["parent"],
                publishedSessionIDs: ["other"]
            ),
            []
        )
    }

    func test_catchUpLane_keepsHistoricalUsagesAndDoesNotForceACutoff() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let stale = ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "old",
            startTime: Date(timeIntervalSince1970: 1_600_000_000),
            endTime: Date(timeIntervalSince1970: 1_600_000_060)
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [.factory: RecordingParser(recorder: recorder, usages: [stale])],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover(), lane: .catchUp)
        XCTAssertEqual(parsed.allUsages.map(\.sessionId), ["old"])
        let catchUpDates = await recorder.minimumDateSnapshot()
        XCTAssertEqual(catchUpDates, [nil])
    }

    func test_liveLane_parsesSiblingProvidersEvenWhenTheFirstIsSlow() async throws {
        let store = try makeInMemoryDataStore()
        let slow = DelayedParser(
            provider: .claudeCode,
            delayNanoseconds: 80_000_000,
            usages: [ViewTestFixtures.makeUsage(provider: .claudeCode, sessionId: "claude-live")]
        )
        let fast = DelayedParser(
            provider: .factory,
            delayNanoseconds: 0,
            usages: [ViewTestFixtures.makeUsage(provider: .factory, sessionId: "factory-live")]
        )
        let pipeline = UsageRefreshPipeline(
            parsers: [.claudeCode: slow, .factory: fast],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        let parsed = try await pipeline.parse(from: pipeline.discover(), lane: .live)
        XCTAssertEqual(
            Set(parsed.allUsages.map(\.sessionId)),
            ["claude-live", "factory-live"]
        )
    }

    func test_parseStageDoesNotLetOneProviderConsumeTheByteBudgetForEveryone() async throws {
        let store = try makeInMemoryDataStore()
        let hogRecorder = BudgetAdmissionRecorder()
        let siblingRecorder = BudgetAdmissionRecorder()
        let hog = BudgetRecordingParser(provider: .claudeCode, recorder: hogRecorder)
        let sibling = BudgetRecordingParser(provider: .factory, recorder: siblingRecorder)
        let pipeline = UsageRefreshPipeline(
            parsers: [
                .claudeCode: hog,
                .factory: sibling
            ],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(
                conversationIndexingEnabled: false,
                snapshotAPIs: []
            )
        )

        _ = try await pipeline.parse(from: pipeline.discover())

        let hogAdmitted = await hogRecorder.admittedSnapshot()
        let siblingAdmitted = await siblingRecorder.admittedSnapshot()
        XCTAssertEqual(hogAdmitted, [true], "The first provider must still receive a budget")
        XCTAssertEqual(
            siblingAdmitted,
            [true],
            "A later provider must keep its own byte budget after Claude spends a full 256MB slice"
        )
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

    func test_persist_deleteOnlyRemovesRows() async throws {
        let store = try makeInMemoryDataStore()
        try await store.insert(ViewTestFixtures.makeUsage(provider: .codex, sessionId: "gone"))
        let pipeline = UsageRefreshPipeline(
            parsers: [:],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: false, snapshotAPIs: [])
        )
        var parsed = UsageRefreshPipeline.ParsedBatch()
        parsed.usageSessionIDsToDeleteByProvider = [.codex: ["gone"]]
        let persisted = await pipeline.persist(parsed: parsed)
        XCTAssertNil(persisted.persistenceErrorMessage)
        XCTAssertTrue(try await store.fetchAllUsage().isEmpty)
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

    // MARK: - Usage-Before-Indexing Ordering (re-implements closed PR #1639)

    /// Pins the refresh ordering contract: by the time conversation indexing
    /// runs, the tick's usage rows are already committed.
    ///
    /// The probe observes the usage table from inside the indexing call. Under
    /// the old `reconcile` → `persist` order it sees an un-updated table: the
    /// superseded lifetime row still present, its per-day replacements missing —
    /// exactly the state in which projection jobs enqueued by the indexer would
    /// double-count. Under `persist` → `reconcile` it sees the committed totals.
    func test_publishUsageThenIndexCommitsUsageBeforeIndexingRuns() async throws {
        let store = try makeInMemoryDataStore()
        // A superseded lifetime row that this tick's invalidation retires.
        try await store.insert(ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent"))

        let probe = UsageVisibilityProbe(dataStore: store)
        let pipeline = UsageRefreshPipeline(
            parsers: [:],
            dataStore: store,
            orchestrator: probe,
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: true, snapshotAPIs: [])
        )

        var parsed = UsageRefreshPipeline.ParsedBatch()
        parsed.allUsages = [
            ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent#day-200")
        ]
        parsed.usageSessionIDsToDeleteByProvider = [.codex: ["parent"]]
        parsed.allConversations = [makeConversationRecord(id: "Codex:ordering-probe")]

        let published = await pipeline.publishUsageThenIndexConversations(parsed: parsed)
        XCTAssertNil(published.persist.persistenceErrorMessage)

        let observed = await probe.observedUsageSessionIDs
        XCTAssertNotNil(observed, "Conversation indexing must have been invoked")
        XCTAssertEqual(
            observed,
            ["parent#day-200"],
            "Usage rows must be committed before conversation indexing runs"
        )
    }

    /// Pins the failure half of the ordering contract: when usage publication
    /// fails, conversation indexing must not run at all.
    ///
    /// `persist` commits the invalidation deletes and the chunked inserts in
    /// separate transactions, so a mid-flight failure can leave the usage table
    /// partially published: some superseded rows deleted, some replacements
    /// missing. Indexing against that state would enqueue projection jobs that
    /// materialize incomplete totals. The pipeline must skip reconciliation and
    /// surface the persistence error instead.
    func test_publishUsageSkipsIndexingWhenPersistenceFails() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let probe = UsageVisibilityProbe(dataStore: store)
        let pipeline = UsageRefreshPipeline(
            parsers: [:],
            dataStore: store,
            orchestrator: probe,
            settings: RefreshSettingsSnapshot(conversationIndexingEnabled: true, snapshotAPIs: [])
        )

        var parsed = UsageRefreshPipeline.ParsedBatch()
        parsed.allUsages = [
            ViewTestFixtures.makeUsage(provider: .codex, sessionId: "parent#day-200")
        ]
        parsed.usageSessionIDsToDeleteByProvider = [.codex: ["parent"]]
        parsed.allConversations = [makeConversationRecord(id: "Codex:persist-failure-probe")]

        // Close the database so every write in `persist` fails.
        try queue.close()

        let published = await pipeline.publishUsageThenIndexConversations(parsed: parsed)

        XCTAssertNotNil(published.persist.persistenceErrorMessage)
        XCTAssertEqual(published.reconcile.indexedConversationChanges, 0)
        let observed = await probe.observedUsageSessionIDs
        XCTAssertNil(
            observed,
            "Conversation indexing must not run when usage publication failed"
        )
    }

    /// The background indexing pass reads with a checkpoint watermark and a byte
    /// budget, so its usage view is partial. It must never write usage rows —
    /// re-persisting them would let a background tick overwrite the totals the
    /// foreground refresh published. (Original branch commit 2670c8c0a.)
    func test_conversationIndexingDoesNotPersistUsageRows() async throws {
        let store = try makeInMemoryDataStore()
        let recorder = ParseOptionsRecorder()
        let usage = ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "indexing-pass-usage",
            inputTokens: 10,
            outputTokens: 5
        )

        _ = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: RecordingParser(recorder: recorder, usages: [usage])],
            dataStore: store,
            orchestrator: makeOrchestrator(store: store),
            indexingEnabled: true
        )

        let persistedUsages = try await store.fetchAllUsage()
        XCTAssertTrue(
            persistedUsages.isEmpty,
            "The conversation-indexing pass must not write usage rows; found \(persistedUsages.count)"
        )
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

    private func makeConversationRecord(id: String) -> ConversationRecord {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ConversationRecord(
            id: id,
            provider: .codex,
            sessionId: "session-\(id)",
            projectName: "Ordering",
            startTime: timestamp,
            endTime: timestamp,
            messageCount: 2,
            userWordCount: 3,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Ordering probe",
            lastAssistantMessage: "Done",
            fullText: "Ordering probe\n\nDone",
            indexedAt: timestamp,
            fileModifiedAt: timestamp,
            summary: nil
        )
    }
}

/// Stands in for `RefreshOrchestrator` so the ordering test can look at the
/// usage table from inside the conversation-indexing call.
private actor UsageVisibilityProbe: ConversationIndexingCoordinator {
    private let dataStore: DataStore
    /// `nil` until indexing is invoked; otherwise the usage session IDs visible
    /// in the store at that instant.
    private(set) var observedUsageSessionIDs: [String]?

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    func indexConversationsOffMain(
        _ conversations: [ConversationRecord],
        indexingEnabled: Bool
    ) async -> Int {
        guard !conversations.isEmpty, indexingEnabled else { return 0 }
        let rows = (try? await dataStore.fetchAllUsage()) ?? [] // try?-ok(test probe)
        observedUsageSessionIDs = rows.map(\.sessionId).sorted()
        return conversations.count
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

private actor PersistGateCounter {
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func enter() {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func leave() {
        inFlight -= 1
    }
}

private actor ParseOptionsRecorder {
    private var values: [Bool] = []
    private var minimumDates: [Date?] = []
    private var includeCached: [Bool] = []

    func record(_ options: LogParseOptions) {
        values.append(options.includeConversationBodies)
        minimumDates.append(options.minimumFileModificationDate)
        includeCached.append(options.includeCachedUnchangedUsages)
    }

    func snapshot() -> [Bool] {
        values
    }

    func minimumDateSnapshot() -> [Date?] {
        minimumDates
    }

    func includeCachedSnapshot() -> [Bool] {
        includeCached
    }
}

private actor BudgetAdmissionRecorder {
    private var values: [Bool] = []

    func record(_ admitted: Bool) {
        values.append(admitted)
    }

    func admittedSnapshot() -> [Bool] {
        values
    }
}

/// Spends the historical whole-pass 256MB budget, then reports whether the
/// governor still admitted that charge. Used to prove later providers are
/// not sharing Claude's slice.
private struct DelayedParser: LogParser {
    let provider: AgentProvider
    let delayNanoseconds: UInt64
    let usages: [TokenUsage]

    func parse(options _: LogParseOptions) async throws -> ParseResult {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return ParseResult(usages: usages, conversations: [])
    }
}

private struct BudgetRecordingParser: LogParser {
    let provider: AgentProvider
    let recorder: BudgetAdmissionRecorder

    func parse(options: LogParseOptions) async throws -> ParseResult {
        let admitted = options.resourceGovernor?.admitFile(
            estimatedBytes: ParserResourcePolicy.refreshPassFileByteBudget
        ) ?? false
        await recorder.record(admitted)
        return ParseResult(usages: [], conversations: [])
    }
}

private struct RecordingParser: LogParser {
    let provider: AgentProvider = .factory
    let recorder: ParseOptionsRecorder
    /// Usage the parser hands back. The conversation-indexing pass must discard
    /// it rather than persist it.
    var usages: [TokenUsage] = []

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        await recorder.record(options)
        return ParseResult(usages: usages, conversations: [])
    }
}
