import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Item lifecycle behavior of the publisher beyond the happy path that
/// `AIInboxServiceEndToEndTests` proves: in-place updates, suppression-driven
/// resolution, every auto-resolution rule, learned calibration, feedback
/// absorption, notification cooldowns, and the failure paths that must degrade
/// instead of failing a tick.
final class AIInboxPublisherLifecycleTests: XCTestCase {
    private var databaseURL: URL!
    private var ledgerURL: URL!
    private var store: BurnBarAIInboxStore!
    private var usageRecorder: BurnBarUsageRecorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let unique = UUID().uuidString
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-publisher-\(unique).sqlite")
        ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-publisher-ledger-\(unique).jsonl")
        store = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
        usageRecorder = BurnBarUsageRecorder(fileURL: ledgerURL)
    }

    override func tearDownWithError() throws {
        store = nil
        usageRecorder = nil
        for url in [databaseURL, ledgerURL] {
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        try super.tearDownWithError()
    }

    // MARK: - In-place updates

    func test_changedContentBumpsOccurrenceAndCountsAsUpdated() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)

        _ = await publisher.publish(
            findings: [makeFinding(title: "60% wasted", fingerprint: "ci_waste:w")],
            briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let second = await publisher.publish(
            findings: [makeFinding(title: "95% wasted", fingerprint: "ci_waste:w")],
            briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(300)
        )

        XCTAssertEqual(second.itemsNew, 0)
        XCTAssertEqual(second.itemsUpdated, 1, "Changed content is an update, not a duplicate")
        let item = try XCTUnwrap(try store.openItems().first)
        XCTAssertEqual(item.occurrenceCount, 2)
        XCTAssertEqual(item.title, "95% wasted")
        XCTAssertEqual(item.state, .updated)
    }

    // MARK: - Suppression resolves already-open items

    func test_newlySuppressedFingerprintResolvesTheOpenItem() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let finding = makeFinding(title: "maybe unlanded", fingerprint: "promised_not_landed:s")

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        XCTAssertEqual(try store.openItems().count, 1)

        // The verifier refuted it on a later tick: the OPEN item must close too,
        // not just future publications.
        let second = await publisher.publish(
            findings: [], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [finding.fingerprint], now: now.addingTimeInterval(300)
        )

        XCTAssertEqual(second.itemsResolved, 1)
        XCTAssertTrue(try store.openItems().isEmpty)
        let resolved = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        let note = try XCTUnwrap(resolved.items.first?.resolutionNote)
        XCTAssertTrue(note.hasPrefix("Dismissed"))
        XCTAssertTrue(note.contains("real problem"))
    }

    // MARK: - Auto-resolution rules

    func test_stuckPRResolvesWhenNoLongerOpenAndSkipsUnobservedRepos() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let observedPR = AIInboxFixtures.pullRequest(number: 12, state: "OPEN", updatedAt: now)
        let otherPR = AIInboxFixtures.pullRequest(number: 7, state: "OPEN", updatedAt: now)
        let openPack = AIInboxFixtures.pack(
            repositories: [
                AIInboxFixtures.repository(slug: "Other/Repo", runs: [], openPullRequests: [otherPR]),
                AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: [], openPullRequests: [observedPR])
            ],
            now: now
        )
        let finding = makeFinding(
            kind: .stuckPR,
            title: "PR #12 has been quiet",
            fingerprint: "stuck_pr:12",
            evidenceIDs: ["pr:Other/Repo#7", "pr:Ajnunezg/BurnBar#12"]
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: openPack, config: config,
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let detail = try XCTUnwrap(try store.itemDetail(fingerprint: finding.fingerprint))
        XCTAssertEqual(detail.payload.evidence.filter { $0.kind == .pullRequest }.count, 2)

        // Next tick only observed Ajnunezg/BurnBar, where the PR is neither
        // open nor recently merged: it was closed without merging.
        let closedPack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: [])],
            now: now
        )
        let result = await publisher.publish(
            findings: [], briefMarkdown: "", pack: closedPack, config: config,
            tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 1)
        let resolved = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        XCTAssertEqual(resolved.items.first?.resolutionNote, "PR #12 is no longer open.")
    }

    func test_promisedNotLandedResolvesWhenTheWorkspaceComesBackClean() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let dirtyPack = AIInboxFixtures.pack(workspaces: [AIInboxFixtures.workspace(dirty: 4)], now: now)
        let finding = makeFinding(
            kind: .promisedNotLanded,
            title: "The auth fix may not have landed",
            fingerprint: "promised_not_landed:w",
            evidenceIDs: ["workspace:/tmp/burnbar"]
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: dirtyPack, config: config,
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let detail = try XCTUnwrap(try store.itemDetail(fingerprint: finding.fingerprint))
        let fileEvidence = try XCTUnwrap(detail.payload.evidence.first { $0.kind == .file })
        XCTAssertTrue(try XCTUnwrap(fileEvidence.detail).contains("4 modified"))

        let cleanPack = AIInboxFixtures.pack(workspaces: [AIInboxFixtures.workspace(dirty: 0)], now: now)
        let result = await publisher.publish(
            findings: [], briefMarkdown: "", pack: cleanPack, config: config,
            tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 1)
        let resolved = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        XCTAssertTrue(try XCTUnwrap(resolved.items.first?.resolutionNote).contains("appears to have landed"))
    }

    func test_uncommittedWorkResolvesOnceCommitted() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let finding = makeFinding(
            kind: .uncommittedWork,
            title: "14 files sitting uncommitted",
            fingerprint: "uncommitted_work:w",
            evidenceIDs: ["workspace:/tmp/burnbar"]
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "",
            pack: AIInboxFixtures.pack(workspaces: [AIInboxFixtures.workspace(dirty: 14)], now: now),
            config: config, tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let result = await publisher.publish(
            findings: [], briefMarkdown: "",
            pack: AIInboxFixtures.pack(workspaces: [AIInboxFixtures.workspace(dirty: 0)], now: now),
            config: config, tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 1)
        let resolved = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        XCTAssertEqual(resolved.items.first?.resolutionNote, "Those changes have been committed.")
    }

    func test_ciWasteResolvesOnlyOnPositiveRecoveryEvidence() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let wastedPack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(workflow: "nightly.yml", total: 40, wasted: 38, minutesEach: 8, now: now)
            )],
            now: now
        )
        let findings = BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: wastedPack)
        XCTAssertEqual(findings.count, 1)

        _ = await publisher.publish(
            findings: findings, briefMarkdown: "", pack: wastedPack, config: config,
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )

        // Too few fresh runs: not enough evidence either way, so it stays open.
        let sparsePack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(workflow: "nightly.yml", total: 3, wasted: 0, minutesEach: 5, now: now)
            )],
            now: now
        )
        let inconclusive = await publisher.publish(
            findings: [], briefMarkdown: "", pack: sparsePack, config: config,
            tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )
        XCTAssertEqual(inconclusive.itemsResolved, 0)
        XCTAssertEqual(try store.openItems().count, 1)

        // Ten fresh runs, one failure: the workflow recovered.
        let recoveredPack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(workflow: "nightly.yml", total: 10, wasted: 1, minutesEach: 5, now: now)
            )],
            now: now
        )
        let recovered = await publisher.publish(
            findings: [], briefMarkdown: "", pack: recoveredPack, config: config,
            tickID: "t3", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(1_200)
        )

        XCTAssertEqual(recovered.itemsResolved, 1)
        let resolved = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        XCTAssertTrue(try XCTUnwrap(resolved.items.first?.resolutionNote).contains("passing again"))
    }

    func test_indexHealthResolvesOnceConversationsFlowAgain() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let finding = makeFinding(
            kind: .indexHealth,
            title: "The index has stalled",
            fingerprint: "index_health:stall"
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let result = await publisher.publish(
            findings: [], briefMarkdown: "",
            pack: AIInboxFixtures.pack(conversations: [AIInboxFixtures.conversation()], now: now),
            config: config, tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 1)
        let resolved = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        XCTAssertEqual(resolved.items.first?.resolutionNote, "The index has caught up.")
    }

    func test_costAnomalyNeverAutoResolves() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let finding = makeFinding(
            kind: .costAnomaly,
            title: "Spend tripled today",
            fingerprint: "cost_anomaly:spike"
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let result = await publisher.publish(
            findings: [], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 0, "A cost spike has no disappearing evidence to observe")
        XCTAssertEqual(try store.openItems().count, 1)
    }

    // MARK: - Calibration

    func test_learnedDemotionLowersPriorityAndExplainsItself() async throws {
        let now = Date()
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<6 {
            calibration.recordFeedback(kind: .uncommittedWork, useful: false, now: now)
        }
        try store.setState(BurnBarAIInboxSchema.StateKey.calibration, value: calibration, now: now)

        let publisher = makePublisher(notifier: nil)
        _ = await publisher.publish(
            findings: [makeFinding(
                kind: .uncommittedWork,
                title: "dirty tree",
                fingerprint: "uncommitted_work:demoted"
            )],
            briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: BurnBarInboxConfig(enabled: true, egressMode: .off),
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )

        let item = try XCTUnwrap(try store.openItems().first)
        XCTAssertEqual(item.priority, .p3, "A consistently down-voted kind drops one band from P2")
        let detail = try XCTUnwrap(try store.item(id: item.id))
        XCTAssertEqual(
            detail.payload.metrics["calibration_note"],
            "Ranked lower because you have marked items like this as not useful."
        )
    }

    func test_userFeedbackIsAbsorbedIntoCalibrationExactlyOnce() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        _ = await publisher.publish(
            findings: [makeFinding(title: "wasted runs", fingerprint: "ci_waste:fb")],
            briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let itemID = try XCTUnwrap(try store.openItems().first?.id)

        // The app writes a thumbs-up into its own table.
        try store.execute(
            """
            INSERT INTO ai_inbox_item_state (item_id, read_at, archived_at, snoozed_until, feedback, updated_at)
            VALUES (?, NULL, NULL, NULL, 'useful', ?)
            """,
            [.text(itemID), .text(BurnBarAIInboxStore.string(from: now))]
        )

        for tick in ["t2", "t3"] {
            _ = await publisher.publish(
                findings: [], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
                config: config, tickID: tick, modelProvenance: "local-rules", calls: [],
                newlySuppressedFingerprints: [], now: now.addingTimeInterval(300)
            )
        }

        let calibration = try XCTUnwrap(
            try store.state(BurnBarAIInboxSchema.StateKey.calibration, as: BurnBarAIInboxCalibration.self)
        )
        XCTAssertEqual(
            calibration.kinds[BurnBarInboxItemKind.ciWaste.rawValue]?.useful, 1,
            "One rating counts once, no matter how many ticks observe it"
        )
        let consumed = try XCTUnwrap(
            try store.state(BurnBarAIInboxSchema.StateKey.consumedFeedback, as: [String].self)
        )
        XCTAssertTrue(consumed.contains("\(itemID):useful"))
    }

    // MARK: - Notification cooldown

    func test_recurrenceWithinTheCooldownDoesNotNotifyAgain() async throws {
        let now = Date()
        let notifier = RecordingInboxNotifier()
        let publisher = makePublisher(notifier: notifier)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let finding = makeFinding(
            title: "P1 fire", priority: .p1, fingerprint: "ci_waste:cooldown"
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        var count = await notifier.count()
        XCTAssertEqual(count, 1)

        // The user resolves it, then the same condition recurs ten minutes
        // later. The new row is real, but re-interrupting inside the hour is spam.
        let itemID = try XCTUnwrap(try store.openItems().first?.id)
        XCTAssertTrue(try store.resolveItem(id: itemID, note: nil, now: now))

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: config, tickID: "t2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(try store.openItems().count, 1, "The recurrence still opens a fresh row")
        count = await notifier.count()
        XCTAssertEqual(count, 1, "Within the cooldown the recurrence stays silent")
    }

    // MARK: - Failure paths

    func test_publishSurvivesAMissingItemsTable() async throws {
        try store.execute("DROP TABLE ai_inbox_items", [])
        let publisher = makePublisher(notifier: nil)

        let result = await publisher.publish(
            findings: [makeFinding(title: "t", fingerprint: "ci_waste:broken")],
            briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: Date()),
            config: BurnBarInboxConfig(enabled: true, egressMode: .off),
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: Date()
        )

        XCTAssertEqual(result.itemsNew, 0, "A failed upsert is logged, not counted")
        XCTAssertEqual(result.itemsUpdated, 0)
        XCTAssertEqual(result.itemsResolved, 0)
        XCTAssertTrue(result.notifiedFingerprints.isEmpty)
    }

    func test_conflictingUsageLedgerWriteIsContainedToTheAccountingStep() async throws {
        let now = Date()
        let publisher = makePublisher(notifier: nil)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .cloud)

        _ = await publisher.publish(
            findings: [], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "tick_dup",
            modelProvenance: "m",
            calls: [AIInboxFixtures.modelCall(role: "analyst", provider: "deepseek", model: "d", cost: 0.01)],
            newlySuppressedFingerprints: [], now: now
        )
        // Same tick id and role index, different cost: the recorder must refuse
        // the conflicting write and the publisher must absorb the error.
        let second = await publisher.publish(
            findings: [makeFinding(title: "still published", fingerprint: "ci_waste:conflict")],
            briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "tick_dup",
            modelProvenance: "m",
            calls: [AIInboxFixtures.modelCall(role: "analyst", provider: "deepseek", model: "d", cost: 0.99)],
            newlySuppressedFingerprints: [], now: now
        )

        XCTAssertEqual(second.itemsNew, 1, "The item still publishes when accounting fails")
        let events = try await usageRecorder.records().map(\.event)
        XCTAssertEqual(events.count, 1, "The conflicting event never reached the ledger")
        XCTAssertEqual(try XCTUnwrap(events.first).cost, 0.01, accuracy: 0.000_1)
    }

    // MARK: - Brief titles

    func test_briefTitleNamesTheSingleProject() {
        let now = Date()
        let pack = AIInboxFixtures.pack(conversations: [AIInboxFixtures.conversation()], now: now)
        XCTAssertEqual(BurnBarAIInboxPublisher.briefTitle(pack: pack, now: now), "1 session in BurnBar")
    }

    func test_briefTitleCountsProjectsWhenSeveralAreActive() {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            conversations: [
                makeExcerpt(id: "c1", project: "BurnBar"),
                makeExcerpt(id: "c2", project: "AgentLens")
            ],
            now: now
        )
        XCTAssertEqual(BurnBarAIInboxPublisher.briefTitle(pack: pack, now: now), "2 sessions across 2 projects")
    }

    func test_briefTitleFallsBackWhenNothingIsAttributed() {
        let now = Date()
        XCTAssertEqual(
            BurnBarAIInboxPublisher.briefTitle(pack: AIInboxFixtures.emptyPack(now: now), now: now),
            "Recent activity"
        )
    }

    // MARK: - Evidence materialization

    func test_conversationCitationBecomesADeepLinkedEvidenceRow() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(conversations: [AIInboxFixtures.conversation()], now: now)
        let finding = makeFinding(
            title: "t", fingerprint: "f", evidenceIDs: ["conv:conv-1:12"]
        )

        let rows = BurnBarAIInboxPublisher.evidence(for: finding, pack: pack)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.kind, .conversation)
        XCTAssertEqual(row.label, "Auth middleware refactor")
        XCTAssertEqual(row.detail, "Claude Code · 12 messages")
        XCTAssertEqual(row.url, "openburnbar://sessions/conv-1")
    }

    func test_issueCitationResolvesAgainstTheRepositorySnapshot() throws {
        let now = Date()
        let issue = BurnBarGitHubIssue(
            number: 5,
            title: "Retry loop spins forever",
            state: "OPEN",
            url: "https://github.com/Ajnunezg/BurnBar/issues/5",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now,
            labels: ["bug"]
        )
        let repository = BurnBarGitHubRepositorySnapshot(
            slug: "Ajnunezg/BurnBar",
            openPullRequests: [],
            recentlyMergedPullRequests: [],
            openIssues: [issue],
            recentRuns: [],
            fetchedAt: now
        )
        let pack = AIInboxFixtures.pack(repositories: [repository], now: now)
        let finding = makeFinding(
            title: "t", fingerprint: "f", evidenceIDs: ["issue:Ajnunezg/BurnBar#5"]
        )

        let rows = BurnBarAIInboxPublisher.evidence(for: finding, pack: pack)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, .issue)
        XCTAssertEqual(row.label, "#5 Retry loop spins forever")
        XCTAssertEqual(row.detail, "open")
        XCTAssertEqual(row.url, issue.url)
    }

    func test_usageCitationResolvesAgainstTheAggregates() throws {
        let now = Date()
        let aggregate = BurnBarAIInboxUsageAggregate(
            projectName: "BurnBar",
            model: "claude-fable-5",
            provider: "anthropic",
            callCount: 40,
            totalTokens: 120_000,
            costUSD: 2.35
        )
        let pack = AIInboxFixtures.pack(usage: [aggregate], now: now)
        let finding = makeFinding(
            title: "t", fingerprint: "f", evidenceIDs: ["usage:BurnBar:claude-fable-5"]
        )

        let rows = BurnBarAIInboxPublisher.evidence(for: finding, pack: pack)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, .usage)
        XCTAssertEqual(row.label, "claude-fable-5 in BurnBar")
        XCTAssertTrue(try XCTUnwrap(row.detail).contains("40 calls"))
        XCTAssertNil(row.url)
    }

    func test_unresolvableCitationProducesNoEvidenceRow() {
        let now = Date()
        let finding = makeFinding(
            title: "t", fingerprint: "f",
            evidenceIDs: ["conv:ghost:1", "workspace:/nowhere", "usage:Ghost:model"]
        )
        let rows = BurnBarAIInboxPublisher.evidence(
            for: finding,
            pack: AIInboxFixtures.emptyPack(now: now)
        )
        XCTAssertTrue(rows.isEmpty, "A citation the pack cannot ground must never fabricate a link")
    }

    // MARK: - Fixtures

    private func makePublisher(notifier: (any BurnBarAIInboxNotifying)?) -> BurnBarAIInboxPublisher {
        BurnBarAIInboxPublisher(
            store: store,
            usageRecorder: usageRecorder,
            notifier: notifier,
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    private func makeFinding(
        kind: BurnBarInboxItemKind = .ciWaste,
        title: String,
        priority: BurnBarInboxPriority = .p2,
        fingerprint: String,
        evidenceIDs: [String] = []
    ) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: kind,
            title: title,
            summaryMarkdown: "summary for \(title)",
            priority: priority,
            confidence: 0.9,
            evidenceIDs: evidenceIDs,
            fingerprint: fingerprint,
            source: .detector
        )
    }

    private func makeExcerpt(id: String, project: String) -> BurnBarAIInboxConversationExcerpt {
        BurnBarAIInboxConversationExcerpt(
            evidenceID: "conv:\(id):1",
            conversationID: id,
            provider: "Claude Code",
            projectName: project,
            workspacePath: nil,
            title: "Session \(id)",
            endedAt: Date(),
            messageCount: 1,
            body: "body",
            keyFiles: [],
            keyCommands: [],
            wasTruncated: false
        )
    }
}
