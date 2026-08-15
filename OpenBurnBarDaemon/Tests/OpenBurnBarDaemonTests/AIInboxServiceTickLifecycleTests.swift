import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Behavior of the AI Inbox service itself: the tick lifecycle, the config
/// round trip, the full pipeline with injected model output, and the graceful
/// degradations (no providers, exhausted budget).
///
/// Everything runs against a temp SQLite file with a fake executor and a fake
/// process runner, so no subprocess, network call, or real provider is touched.
final class AIInboxServiceTickLifecycleTests: XCTestCase {
    private var databaseURL: URL!
    private var ledgerURL: URL!
    private var rootURL: URL!
    private var assertionStore: BurnBarAIInboxStore!
    private var usageRecorder: BurnBarUsageRecorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let unique = UUID().uuidString
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-service-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        databaseURL = rootURL.appendingPathComponent("openburnbar.sqlite")
        ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl")
        assertionStore = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
        usageRecorder = BurnBarUsageRecorder(fileURL: ledgerURL)
    }

    override func tearDownWithError() throws {
        assertionStore = nil
        usageRecorder = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        try super.tearDownWithError()
    }

    // MARK: - Configuration

    func test_configurationDefaultsToDisabledUntilTheUserOptsIn() async throws {
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))
        let config = await service.configuration()

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.egressMode, .off)
        XCTAssertEqual(config.tickSeconds, BurnBarInboxConfig.defaultTickSeconds)
    }

    func test_updateConfigurationClampsHostileValuesAndPersistsTheResult() async throws {
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))

        let stored = await service.updateConfiguration(
            BurnBarInboxConfig(
                enabled: true,
                egressMode: .cloud,
                tickSeconds: 1,
                remotePhaseEveryNTicks: 0,
                dailyBudgetUSD: -50,
                maxVerifierCallsPerTick: 9_999,
                lookbackMinutes: 100_000
            )
        )

        XCTAssertTrue(stored.enabled)
        XCTAssertEqual(stored.egressMode, .cloud)
        XCTAssertEqual(stored.tickSeconds, BurnBarInboxConfig.minimumTickSeconds)
        XCTAssertEqual(stored.remotePhaseEveryNTicks, 1)
        XCTAssertEqual(stored.dailyBudgetUSD, 0)
        XCTAssertEqual(stored.maxVerifierCallsPerTick, 25)
        XCTAssertEqual(stored.lookbackMinutes, 24 * 60)

        // A fresh read returns what was actually stored, not what was sent.
        let reloaded = await service.configuration()
        XCTAssertEqual(reloaded, stored)
    }

    // MARK: - Disabled inbox

    func test_runNowIsRejectedWhileTheInboxIsDisabled() async throws {
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))

        let response = await service.runNow(force: false)

        XCTAssertFalse(response.accepted)
        XCTAssertNil(response.tickID)
        XCTAssertEqual(response.reason, "The AI Inbox is turned off.")
        XCTAssertTrue(
            try assertionStore.recentRuns(limit: 10).isEmpty,
            "A rejected run must not write telemetry"
        )
    }

    func test_unforcedTickIsANoOpWhileDisabled() async throws {
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))

        let tickID = await service.tick(forced: false)

        XCTAssertNil(tickID)
        XCTAssertTrue(try assertionStore.recentRuns(limit: 10).isEmpty)
    }

    // MARK: - The free tick

    func test_unchangedSecondTickWritesOnlyACheapSkippedRunRow() async throws {
        // A far-future clock keeps the agent-log portion of the gate signature
        // at zero recent files, so the second tick genuinely sees "unchanged"
        // even when a live agent is writing session logs on this machine.
        let clock = SteppingClock(start: Date(timeIntervalSince1970: 4_000_000_000))
        let executor = FakeInboxProviderExecutor(responses: [])
        let service = try makeService(executor: executor, clock: { clock.next() })
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(enabled: true, egressMode: .off, remotePhaseEveryNTicks: 60)
        )

        let firstTick = await service.tick(forced: false)
        let firstTickID = try XCTUnwrap(firstTick)
        let secondTick = await service.tick(forced: false)
        let secondTickID = try XCTUnwrap(secondTick)

        let runs = try assertionStore.recentRuns(limit: 10)
        XCTAssertEqual(runs.count, 2)

        let firstRun = try XCTUnwrap(runs.first { $0.tickID == firstTickID })
        XCTAssertEqual(firstRun.gateResult, .localChanged, "The first tick sees a brand-new world")

        let secondRun = try XCTUnwrap(runs.first { $0.tickID == secondTickID })
        XCTAssertEqual(secondRun.gateResult, .skippedUnchanged)
        XCTAssertNotNil(secondRun.finishedAt, "Even a skipped tick records completion")
        XCTAssertEqual(secondRun.llmCalls, 0)
        XCTAssertEqual(secondRun.costUSD, 0)

        let prompts = await executor.promptCount()
        XCTAssertEqual(prompts, 0, "Egress off must never construct a prompt")
    }

    // MARK: - The full pipeline

    func test_forcedTickRunsAnalystAndVerifierAndAccountsEverySubCall() async throws {
        let configStore = try await makeConfiguredProviderConfigStore()
        let executor = FakeInboxProviderExecutor(
            responses: [Self.analystResponseJSON, Self.verifierConfirmJSON]
        )
        let notifier = RecordingInboxNotifier()
        let service = try makeService(executor: executor, configStore: configStore, notifier: notifier)
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(enabled: true, egressMode: .cloud, githubEnabled: false)
        )
        try seedConversation(
            id: "conv-live",
            messageCount: 12,
            endedAt: Date().addingTimeInterval(-600)
        )
        try seedUsageRow(cost: 2.35, at: Date().addingTimeInterval(-600))

        let response = await service.runNow(force: true)
        XCTAssertTrue(response.accepted)
        let tickID = try XCTUnwrap(response.tickID)

        // Exactly one analyst call and one verifier call.
        let prompts = await executor.promptCount()
        XCTAssertEqual(prompts, 2)

        // Telemetry: the forced run is fully accounted.
        let runsResponse = try await service.recentRuns(limit: 10)
        let run = try XCTUnwrap(runsResponse.runs.first { $0.tickID == tickID })
        XCTAssertEqual(run.gateResult, .forced)
        XCTAssertEqual(run.llmCalls, 2)
        XCTAssertGreaterThan(run.costUSD, 0)
        XCTAssertGreaterThanOrEqual(run.itemsNew, 2, "The brief and the analyst finding both publish")
        XCTAssertGreaterThan(runsResponse.todaySpendUSD, 0)
        XCTAssertEqual(runsResponse.dailyBudgetUSD, 1.50, accuracy: 0.0001)

        // The RPC-facing reads expose the published items.
        let list = try await service.list(BurnBarInboxListRequest())
        XCTAssertGreaterThanOrEqual(list.openCount, 2)
        let analystItem = try XCTUnwrap(
            list.items.first { $0.title == "Auth refactor is split across sessions" }
        )
        XCTAssertTrue(analystItem.modelProvenance.contains("deepseek"))
        XCTAssertTrue(analystItem.modelProvenance.contains("openai"), "Verifier provenance is appended")

        let fetchedDetail = try await service.item(id: analystItem.id)
        let detail = try XCTUnwrap(fetchedDetail)
        XCTAssertFalse(detail.payload.evidence.isEmpty, "Citations materialize into evidence rows")
        XCTAssertEqual(detail.payload.verification?.verdict, .confirmed)
        XCTAssertEqual(detail.tickID, tickID)

        // Every model sub-call reached the usage ledger under the inbox source.
        let events = try await usageRecorder.records().map(\.event)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.executionSourceID == BurnBarAIInboxUsage.executionSourceID })
        XCTAssertTrue(events.allSatisfy { $0.parentRequestID == tickID })
        XCTAssertEqual(Set(events.map(\.providerID)), ["deepseek", "openai"])

        // A P2 finding must not interrupt anyone.
        let notificationCount = await notifier.count()
        XCTAssertEqual(notificationCount, 0)
    }

    func test_missingProviderRouteDegradesToTheRuleBasedBriefInsteadOfFailing() async throws {
        // No provider is configured, so the analyst route cannot resolve. The
        // tick must degrade to the deterministic brief, not fail or retry.
        let executor = FakeInboxProviderExecutor(responses: [])
        let service = try makeService(executor: executor)
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(enabled: true, egressMode: .cloud, githubEnabled: false)
        )
        try seedConversation(
            id: "conv-degrade",
            messageCount: 5,
            endedAt: Date().addingTimeInterval(-300)
        )

        let response = await service.runNow(force: true)
        XCTAssertTrue(response.accepted)
        let tickID = try XCTUnwrap(response.tickID)

        let prompts = await executor.promptCount()
        XCTAssertEqual(prompts, 0, "A failed route must not reach the executor")

        let run = try XCTUnwrap(try assertionStore.recentRuns(limit: 10).first { $0.tickID == tickID })
        XCTAssertEqual(run.gateResult, .forced, "A provider outage degrades the tick, it does not fail it")
        XCTAssertEqual(run.llmCalls, 0)
        // Degrading is fine. Degrading *silently* is not: a zero-call run must
        // say why, or a broken model pin is indistinguishable from a quiet day.
        let runError = try XCTUnwrap(run.error, "A skipped analyst must be recorded on the run")
        XCTAssertTrue(runError.hasPrefix("analyst unavailable: "), runError)

        let briefItem = try XCTUnwrap(try assertionStore.openItems().first { $0.kind == .brief })
        // The Founder Lens (on by default) stamps its version even on the
        // rule-based path — the router and standing-commitments hook shaped
        // the output, and provenance says so.
        XCTAssertEqual(briefItem.modelProvenance, "local-rules+lens:v1")
    }

    func test_analystRouteFailureFilesASystemItemNamingTheRouteAndTheReason() async throws {
        // Same outage as above, seen from the user's side: the inbox must file a
        // readable "the analyst could not run" item rather than looking healthy.
        let executor = FakeInboxProviderExecutor(responses: [])
        let service = try makeService(executor: executor)
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(
                enabled: true,
                egressMode: .cloud,
                analystProviderID: "deepseek",
                analystModel: "deepseek-chat",
                githubEnabled: false
            )
        )
        try seedConversation(
            id: "conv-analyst-down",
            messageCount: 5,
            endedAt: Date().addingTimeInterval(-300)
        )

        _ = await service.runNow(force: true)

        let notice = try XCTUnwrap(
            try assertionStore.openItems().first { $0.kind == .system && $0.title == "Analyst could not run" },
            "The degradation must be visible in the inbox, not only in the log"
        )
        XCTAssertEqual(notice.priority, .p2)

        let detail = try XCTUnwrap(try assertionStore.item(id: notice.id))
        XCTAssertTrue(
            detail.summaryMarkdown.contains("deepseek:deepseek-chat"),
            "The item names the pinned route so a bad pin is self-diagnosing: \(detail.summaryMarkdown)"
        )
        XCTAssertTrue(
            detail.summaryMarkdown.contains("**Reason:**"),
            detail.summaryMarkdown
        )
        XCTAssertEqual(notice.fingerprint, BurnBarAIInboxFinding.analystUnavailableFingerprint)
    }

    func test_retryingADifferentBadAnalystPinUpdatesOneNoticeInsteadOfStackingThem() async throws {
        // Hunting for a working model must not leave one permanently-open
        // "Analyst could not run" row per model tried.
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))
        try seedConversation(
            id: "conv-analyst-retry",
            messageCount: 5,
            endedAt: Date().addingTimeInterval(-300)
        )

        for model in ["deepseek-chat", "kimi-k2.6", "glm-5-turbo"] {
            _ = await service.updateConfiguration(
                BurnBarInboxConfig(
                    enabled: true,
                    egressMode: .cloud,
                    analystProviderID: "deepseek",
                    analystModel: model,
                    githubEnabled: false
                )
            )
            _ = await service.runNow(force: true)
        }

        let notices = try assertionStore.openItems()
            .filter { $0.kind == .system && $0.title == "Analyst could not run" }
        XCTAssertEqual(notices.count, 1, "Three failed pins, one condition, one row")

        // The surviving row reports the pin that failed most recently.
        let detail = try XCTUnwrap(try assertionStore.item(id: notices[0].id))
        XCTAssertEqual(detail.payload.metrics["analyst_model"], "glm-5-turbo")
    }

    func test_theAnalystDownNoticeResolvesOnceTheAnalystRunsAgain() async throws {
        try seedConversation(
            id: "conv-analyst-recovers",
            messageCount: 6,
            endedAt: Date().addingTimeInterval(-300)
        )

        // Tick 1: no routable provider, so the notice is filed.
        let brokenService = try makeService(executor: FakeInboxProviderExecutor(responses: []))
        _ = await brokenService.updateConfiguration(
            BurnBarInboxConfig(enabled: true, egressMode: .cloud, githubEnabled: false)
        )
        _ = await brokenService.runNow(force: true)
        XCTAssertEqual(
            try assertionStore.openItems().filter { $0.kind == .system && $0.title == "Analyst could not run" }.count,
            1
        )

        // Tick 2: the analyst can route again. The stale alarm must clear itself.
        let workingService = try makeService(
            executor: FakeInboxProviderExecutor(responses: [Self.analystResponseJSON, Self.verifierConfirmJSON]),
            configStore: try await makeConfiguredProviderConfigStore()
        )
        _ = await workingService.runNow(force: true)

        XCTAssertTrue(
            try assertionStore.openItems()
                .filter { $0.kind == .system && $0.title == "Analyst could not run" }
                .isEmpty,
            "A recovered analyst must resolve its own outage notice"
        )
    }

    func test_analystFailureReasonPrefersTheHumanSentenceOverTheEnumCase() {
        let reason = BurnBarAIInboxService.analystFailureReason(
            BurnBarProviderRouterError.missingCredential("deepseek")
        )
        XCTAssertEqual(reason, "Provider 'deepseek' is missing credentials.")
    }

    func test_exhaustedBudgetSkipsModelCallsAndFilesABudgetItem() async throws {
        // Seed today's ledger with inbox-attributed spend beyond the budget.
        _ = try await usageRecorder.record(
            BurnBarUsageEvent(
                providerID: "deepseek",
                modelID: "deepseek-v4-flash",
                inputTokens: 1_000,
                outputTokens: 100,
                cacheReadTokens: 0,
                cost: 2.0,
                recordedAt: Date(),
                executionSourceID: BurnBarAIInboxUsage.executionSourceID,
                executionSourceName: BurnBarAIInboxUsage.executionSourceName
            ),
            idempotencyKey: "seed-inbox-spend"
        )

        let executor = FakeInboxProviderExecutor(responses: [])
        let service = try makeService(executor: executor)
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(
                enabled: true,
                egressMode: .cloud,
                dailyBudgetUSD: 0.50,
                githubEnabled: false
            )
        )
        try seedConversation(
            id: "conv-budget",
            messageCount: 8,
            endedAt: Date().addingTimeInterval(-300)
        )

        let response = await service.runNow(force: true)
        XCTAssertTrue(response.accepted)

        let prompts = await executor.promptCount()
        XCTAssertEqual(prompts, 0, "An exhausted budget must block every model call")

        let budgetItem = try XCTUnwrap(try assertionStore.openItems().first { $0.kind == .budget })
        XCTAssertEqual(budgetItem.priority, .p4)

        let runsResponse = try await service.recentRuns(limit: 10)
        XCTAssertEqual(runsResponse.todaySpendUSD, 2.0, accuracy: 0.0001)
        XCTAssertEqual(runsResponse.dailyBudgetUSD, 0.50, accuracy: 0.0001)

        let budget = await service.budgetState(config: BurnBarInboxConfig(dailyBudgetUSD: 0.50))
        XCTAssertTrue(budget.isExhausted)
        XCTAssertEqual(budget.remainingUSD, 0)
        XCTAssertEqual(
            BurnBarAIInboxService.BudgetState(spentUSD: 0.5, limitUSD: 2.0).remainingUSD,
            1.5,
            accuracy: 0.0001
        )
    }

    // MARK: - Capability notices

    func test_unavailableGitHubChecksSurfaceAsASystemItemWhenARepoIsInPlay() async throws {
        // A workspace whose git remote points at GitHub, served entirely by the
        // fake process runner, so the capability-gap notice has a repo in play.
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let runner = FakeInboxProcessRunner(responses: [
            "rev-parse --is-inside-work-tree": "true",
            "abbrev-ref": "main",
            "format:%H": "abc123\u{1f}feat: auth middleware\u{1f}2026-08-04T10:00:00Z",
            "status --porcelain": " M auth/middleware.ts",
            "remote.origin.url": "git@github.com:Imagine-That-Ai/BurnBar.git",
            "format:%s": "feat: auth middleware",
            "rev-list": "0\t0"
        ])

        let executor = FakeInboxProviderExecutor(responses: [])
        let service = try BurnBarAIInboxService(
            databasePath: databaseURL.path,
            usageRecorder: usageRecorder,
            configStore: makeBareConfigStore(),
            executor: executor,
            processRunner: runner,
            notifier: nil,
            logger: BurnBarDaemonLogger(category: "test")
        )
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(enabled: true, egressMode: .off, githubEnabled: false)
        )
        try seedConversation(
            id: "conv-github",
            messageCount: 6,
            endedAt: Date().addingTimeInterval(-300),
            workingDirectory: workspaceURL.path
        )

        let response = await service.runNow(force: true)
        XCTAssertTrue(response.accepted)

        let notice = try XCTUnwrap(try assertionStore.openItems().first { $0.kind == .system })
        XCTAssertEqual(notice.title, "GitHub checks are unavailable")

        let prompts = await executor.promptCount()
        XCTAssertEqual(prompts, 0, "Egress off keeps the notice path model-free")
    }

    // MARK: - Loop lifecycle

    func test_startIsIdempotentAndStopCancelsTheLoopBeforeAnyTick() async throws {
        let executor = FakeInboxProviderExecutor(responses: [])
        let service = try makeService(executor: executor)

        await service.start()
        await service.start()
        // Give the loop task a moment to read the interval and begin sleeping.
        try await Task.sleep(nanoseconds: 200_000_000)
        await service.stop()
        await service.stop()

        XCTAssertTrue(
            try assertionStore.recentRuns(limit: 10).isEmpty,
            "The sleep-first loop must not tick during startup"
        )
        let prompts = await executor.promptCount()
        XCTAssertEqual(prompts, 0)
    }

    // MARK: - Reads on an empty store

    func test_readsReturnEmptyStateInsteadOfThrowingOnAFreshStore() async throws {
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))

        let list = try await service.list(BurnBarInboxListRequest())
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(list.openCount, 0)

        let missing = try await service.item(id: "inb_does_not_exist")
        XCTAssertNil(missing)

        let runs = try await service.recentRuns(limit: 20)
        XCTAssertTrue(runs.runs.isEmpty)
        XCTAssertEqual(runs.todaySpendUSD, 0)
        XCTAssertEqual(runs.dailyBudgetUSD, BurnBarInboxConfig().dailyBudgetUSD, accuracy: 0.0001)
    }

    // MARK: - Billing provenance and the protective budget

    /// The daily budget guards real API dollars. Subscription-routed calls
    /// (plan-covered imputed value) are excluded by default; legacy rows with
    /// no stamped kind resolve through the provider classifier, and anything
    /// unknown still counts — the gate fails protective, never open.
    func test_budgetCountsOnlyAPISpendByDefault() async throws {
        let service = try makeService(executor: FakeInboxProviderExecutor(responses: []))
        _ = await service.updateConfiguration(
            BurnBarInboxConfig(enabled: true, egressMode: .off, dailyBudgetUSD: 1.0, githubEnabled: false)
        )

        func seed(_ cost: Double, kind: BurnBarBillingKind?, provider: String, key: String) async throws {
            _ = try await usageRecorder.record(
                BurnBarUsageEvent(
                    providerID: provider,
                    modelID: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    cacheReadTokens: 0,
                    cost: cost,
                    recordedAt: Date(),
                    executionSourceID: BurnBarAIInboxUsage.executionSourceID,
                    billingKind: kind
                ),
                idempotencyKey: key
            )
        }
        try await seed(0.60, kind: .api, provider: "deepseek", key: "billing-api")
        try await seed(0.60, kind: .subscription, provider: "anthropic", key: "billing-sub")
        // Legacy row: no stamp; "deepseek" classifies to .api and must count.
        try await seed(0.25, kind: nil, provider: "deepseek", key: "billing-legacy")
        // Unclassifiable row: counts (fail-protective), never silently free.
        try await seed(0.10, kind: nil, provider: "mystery-route", key: "billing-unknown")

        let defaultBudget = await service.budgetState(config: service.configuration())
        XCTAssertEqual(defaultBudget.spentUSD, 0.95, accuracy: 0.0001,
                       "api 0.60 + legacy-api 0.25 + unknown 0.10; subscription excluded")
        XCTAssertFalse(defaultBudget.isExhausted)

        _ = await service.updateConfiguration(
            BurnBarInboxConfig(
                enabled: true, egressMode: .off, dailyBudgetUSD: 1.0,
                githubEnabled: false, budgetCountsSubscriptionSpend: true
            )
        )
        let optedIn = await service.budgetState(config: service.configuration())
        XCTAssertEqual(optedIn.spentUSD, 1.55, accuracy: 0.0001,
                       "opting in counts subscription spend again")
        XCTAssertTrue(optedIn.isExhausted)
    }

    // MARK: - Fixtures

    /// Analyst output citing the seeded conversation, with a claim that needs
    /// verification so the verifier leg of the pipeline runs too.
    private static let analystResponseJSON = """
        {
          "brief_md": "Work continued on the BurnBar auth middleware across recent sessions.",
          "findings": [
            {
              "kind": "brief",
              "title": "Auth refactor is split across sessions",
              "summary_md": "The same refactor was restarted in separate sessions.",
              "priority": 2,
              "confidence": 0.8,
              "evidence_ids": ["conv:conv-live:12"],
              "needs_verification": true
            }
          ],
          "memory_candidates": []
        }
        """

    private static let verifierConfirmJSON = """
        {"verdict": "confirm", "reason": "The cited session supports the claim."}
        """

    /// Monotonic test clock. Far-future by default so gate signatures cannot be
    /// perturbed by real files being written while the test runs.
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(start: Date) {
            current = start
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(1)
            return current
        }
    }

    private func makeService(
        executor: FakeInboxProviderExecutor,
        configStore: BurnBarConfigStore? = nil,
        notifier: RecordingInboxNotifier? = nil,
        clock: (@Sendable () -> Date)? = nil
    ) throws -> BurnBarAIInboxService {
        try BurnBarAIInboxService(
            databasePath: databaseURL.path,
            usageRecorder: usageRecorder,
            configStore: configStore ?? makeBareConfigStore(),
            executor: executor,
            processRunner: FakeInboxProcessRunner(),
            notifier: notifier,
            logger: BurnBarDaemonLogger(category: "test"),
            clock: clock ?? { Date() }
        )
    }

    private func makeBareConfigStore() -> BurnBarConfigStore {
        BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("bare-provider-config.json"),
            catalog: Self.providerCatalog(),
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    /// A config store whose providers can actually route the default analyst
    /// (deepseek) and verifier (openai) models.
    private func makeConfiguredProviderConfigStore() async throws -> BurnBarConfigStore {
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            catalog: Self.providerCatalog(),
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "test")
        )
        try await configStore.setSecret("test-secret-deepseek", for: "deepseek")
        try await configStore.setSecret("test-secret-openai", for: "openai")
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://api.deepseek.example/v1",
                preferredModelIDs: ["deepseek-chat"]
            )
        )
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "openai",
                isEnabled: true,
                baseURL: "https://api.openai.example/v1",
                preferredModelIDs: ["gpt-5.6-luna"]
            )
        )
        return configStore
    }

    private static func providerCatalog() -> BurnBarCatalog {
        BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "deepseek",
                    displayName: "DeepSeek",
                    baseURL: "https://api.deepseek.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "deepseek-chat",
                            displayName: "DeepSeek Chat",
                            visibility: .public,
                            pricing: BurnBarModelPricing(
                                inputPerMToken: 1,
                                outputPerMToken: 2,
                                cacheReadPerMToken: 0.1
                            )
                        )
                    ]
                ),
                BurnBarCatalogProvider(
                    id: "openai",
                    displayName: "OpenAI",
                    baseURL: "https://api.openai.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "gpt-5.6-luna",
                            displayName: "GPT 5.6 Luna",
                            visibility: .public,
                            pricing: BurnBarModelPricing(
                                inputPerMToken: 3,
                                outputPerMToken: 12,
                                cacheReadPerMToken: 0.3
                            )
                        )
                    ]
                )
            ]
        )
    }

    /// Inserts an app-owned conversation row exactly as GRDB writes it, so the
    /// pipeline reads the real on-disk format.
    private func seedConversation(
        id: String,
        messageCount: Int,
        endedAt: Date,
        workingDirectory: String? = nil
    ) throws {
        let stored = BurnBarAIInboxTimestamp.grdbString(from: endedAt)
        try assertionStore.execute(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY, provider TEXT, sessionId TEXT, projectName TEXT,
                startTime DATETIME, endTime DATETIME, messageCount INTEGER,
                inferredTaskTitle TEXT, lastAssistantMessage TEXT, summary TEXT,
                workingDirectory TEXT, indexedAt DATETIME, keyFiles TEXT,
                keyCommands TEXT, fullText TEXT
            )
            """,
            []
        )
        try assertionStore.execute(
            """
            INSERT INTO conversations (
                id, provider, sessionId, projectName, startTime, endTime, messageCount,
                inferredTaskTitle, lastAssistantMessage, summary, workingDirectory,
                indexedAt, keyFiles, keyCommands, fullText
            ) VALUES (?, 'Claude Code', 'sess-1', 'BurnBar', ?, ?, ?, 'Auth middleware refactor', '', '',
                      ?, ?, '[]', '[]', 'Explored the auth middleware and adjusted the retry loop.')
            """,
            [
                .text(id),
                .text(stored),
                .text(stored),
                .int(messageCount),
                .optionalText(workingDirectory),
                .text(stored)
            ]
        )
    }

    /// Inserts an app-owned usage row so the pack carries a spend aggregate.
    private func seedUsageRow(cost: Double, at date: Date) throws {
        try assertionStore.execute(
            """
            CREATE TABLE IF NOT EXISTS token_usage (
                id TEXT PRIMARY KEY, provider TEXT, projectName TEXT, model TEXT,
                totalTokens INTEGER, cost REAL, startTime DATETIME
            )
            """,
            []
        )
        try assertionStore.execute(
            """
            INSERT INTO token_usage (id, provider, projectName, model, totalTokens, cost, startTime)
            VALUES (?, 'anthropic', 'BurnBar', 'claude-fable-5', 12000, ?, ?)
            """,
            [
                .text(UUID().uuidString),
                .double(cost),
                .text(BurnBarAIInboxTimestamp.grdbString(from: date))
            ]
        )
    }
}
