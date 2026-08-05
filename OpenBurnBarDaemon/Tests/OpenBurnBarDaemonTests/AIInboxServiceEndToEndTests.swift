import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Records notifications instead of posting them, so the "does this interrupt
/// the user?" policy is directly assertable.
actor RecordingInboxNotifier: BurnBarAIInboxNotifying {
    private(set) var notifications: [(title: String, body: String, itemID: String)] = []

    func notify(title: String, body: String, itemID: String) async {
        notifications.append((title, body, itemID))
    }

    func count() -> Int { notifications.count }
    func titles() -> [String] { notifications.map(\.title) }
}

/// End-to-end behavior of the publisher and the tick lifecycle.
///
/// These are the tests that prove the two promises that make the feature viable:
/// **a tick with nothing to do costs nothing**, and **every model call is
/// accounted for in the usage ledger**.
final class AIInboxServiceEndToEndTests: XCTestCase {
    private var databaseURL: URL!
    private var ledgerURL: URL!
    private var store: BurnBarAIInboxStore!
    private var usageRecorder: BurnBarUsageRecorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let unique = UUID().uuidString
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-e2e-\(unique).sqlite")
        ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-ledger-\(unique).jsonl")
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

    // MARK: - Publishing the marquee finding

    func test_ciWasteFindingBecomesP1ItemWithEvidenceAndUsageRecorded() async throws {
        let now = Date()
        let notifier = RecordingInboxNotifier()
        let publisher = BurnBarAIInboxPublisher(
            store: store,
            usageRecorder: usageRecorder,
            notifier: notifier,
            logger: BurnBarDaemonLogger(category: "test")
        )

        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(
                    workflow: "nightly-matrix.yml",
                    total: 40,
                    wasted: 38,
                    minutesEach: 8,
                    now: now
                )
            )],
            now: now
        )
        let findings = BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack)

        let result = await publisher.publish(
            findings: findings,
            briefMarkdown: "40 CI runs, almost all red.",
            pack: pack,
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud),
            tickID: "tick_1",
            modelProvenance: "deepseek:deepseek-chat+openai:gpt-5.6-luna",
            calls: [
                AIInboxFixtures.modelCall(role: "analyst", provider: "deepseek", model: "deepseek-chat", cost: 0.0095),
                AIInboxFixtures.modelCall(role: "verifier", provider: "openai", model: "gpt-5.6-luna", cost: 0.0021)
            ],
            newlySuppressedFingerprints: [],
            now: now
        )

        // 1 CI-waste item + 1 brief.
        XCTAssertEqual(result.itemsNew, 2)

        let open = try store.openItems()
        let ciItem = try XCTUnwrap(open.first { $0.kind == .ciWaste })
        XCTAssertEqual(ciItem.priority, .p1)
        XCTAssertEqual(ciItem.modelProvenance, "local-rules", "Detector findings are honestly attributed")

        let detail = try XCTUnwrap(try store.item(id: ciItem.id))
        XCTAssertFalse(detail.payload.evidence.isEmpty, "Evidence must be materialized for the UI")
        XCTAssertTrue(detail.payload.evidence.allSatisfy { $0.kind == .workflowRun })
        XCTAssertNotNil(detail.payload.evidence.first?.url, "Evidence must be clickable")
        XCTAssertFalse(detail.payload.actions.isEmpty)

        // Every model call reached the ledger, distinctly keyed and rolled up.
        let events = try await usageRecorder.records().map(\.event)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.executionSourceID == BurnBarAIInboxUsage.executionSourceID })
        XCTAssertTrue(events.allSatisfy { $0.parentRequestID == "tick_1" })
        XCTAssertTrue(events.allSatisfy { $0.executionSourceKind == .automation })
        XCTAssertEqual(Set(events.map(\.providerID)), ["deepseek", "openai"])
        XCTAssertEqual(events.reduce(0) { $0 + $1.cost }, 0.0116, accuracy: 0.0001)

        // A brand-new P1 is exactly the case worth interrupting for.
        let notificationCount = await notifier.count()
        XCTAssertEqual(notificationCount, 1)
    }

    /// The second identical tick must be silent: no duplicate row, no second
    /// notification. This is what stops a recurring condition from becoming spam.
    func test_secondIdenticalTickIsIdempotentAndSilent() async throws {
        let now = Date()
        let notifier = RecordingInboxNotifier()
        let publisher = BurnBarAIInboxPublisher(
            store: store,
            usageRecorder: usageRecorder,
            notifier: notifier,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(
                    workflow: "nightly.yml", total: 40, wasted: 38, minutesEach: 8, now: now
                )
            )],
            now: now
        )
        let findings = BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack)
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)

        _ = await publisher.publish(
            findings: findings, briefMarkdown: "", pack: pack, config: config,
            tickID: "tick_1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        let second = await publisher.publish(
            findings: findings, briefMarkdown: "", pack: pack, config: config,
            tickID: "tick_2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(300)
        )

        XCTAssertEqual(second.itemsNew, 0, "No duplicate item")
        XCTAssertEqual(second.itemsUpdated, 0, "Identical content must not re-alert")
        XCTAssertEqual(try store.openItems().count, 1)

        let notificationCount = await notifier.count()
        XCTAssertEqual(notificationCount, 1, "The same condition notifies once, not every tick")
    }

    // MARK: - Auto-resolution

    /// The most satisfying moment in the product: the thing you were nagged
    /// about is done, and the inbox notices without being asked.
    func test_stuckPullRequestResolvesItselfWhenMerged() async throws {
        let now = Date()
        let publisher = BurnBarAIInboxPublisher(
            store: store,
            usageRecorder: usageRecorder,
            notifier: nil,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)

        let stalePR = AIInboxFixtures.pullRequest(number: 12, state: "OPEN", updatedAt: now.addingTimeInterval(-8 * 86_400))
        let openPack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar", runs: [], openPullRequests: [stalePR]
            )],
            now: now
        )
        let findings = BurnBarAIInboxDetectors(now: now).detectStuckPullRequests(pack: openPack)
        XCTAssertEqual(findings.count, 1)

        _ = await publisher.publish(
            findings: findings, briefMarkdown: "", pack: openPack, config: config,
            tickID: "tick_1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )
        XCTAssertEqual(try store.openItems().count, 1)

        // Next remote phase: the PR merged.
        let mergedPR = AIInboxFixtures.pullRequest(
            number: 12, state: "MERGED", updatedAt: now, mergedAt: now
        )
        let mergedPack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar", runs: [], openPullRequests: [], mergedPullRequests: [mergedPR]
            )],
            now: now
        )
        let result = await publisher.publish(
            findings: [], briefMarkdown: "", pack: mergedPack, config: config,
            tickID: "tick_2", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 1)
        XCTAssertTrue(try store.openItems().isEmpty)

        let all = try store.list(BurnBarInboxListRequest(states: [.resolved], limit: 10))
        XCTAssertEqual(all.items.first?.resolutionNote, "PR #12 has been merged.")
    }

    /// A GitHub outage must never mass-resolve the inbox: absence of evidence is
    /// not evidence of resolution.
    func test_missingRepositoryDataDoesNotResolveItems() async throws {
        let now = Date()
        let publisher = BurnBarAIInboxPublisher(
            store: store, usageRecorder: usageRecorder, notifier: nil,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let config = BurnBarInboxConfig(enabled: true, egressMode: .off)
        let stalePR = AIInboxFixtures.pullRequest(number: 12, state: "OPEN", updatedAt: now.addingTimeInterval(-8 * 86_400))
        let openPack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar", runs: [], openPullRequests: [stalePR]
            )],
            now: now
        )
        _ = await publisher.publish(
            findings: BurnBarAIInboxDetectors(now: now).detectStuckPullRequests(pack: openPack),
            briefMarkdown: "", pack: openPack, config: config, tickID: "t1",
            modelProvenance: "local-rules", calls: [], newlySuppressedFingerprints: [], now: now
        )

        // A pack with no repositories at all — as if `gh` failed this tick.
        let blindPack = BurnBarAIInboxEvidencePack(
            tickID: "t2", generatedAt: now, windowStart: now.addingTimeInterval(-7_200),
            conversations: [], workspaces: [], repositories: [], usage: [], openItems: [],
            githubAvailability: .failed("rate limited"), droppedConversationCount: 0,
            estimatedPromptTokens: 0, indexLagSeconds: 0
        )
        let result = await publisher.publish(
            findings: [], briefMarkdown: "", pack: blindPack, config: config, tickID: "t2",
            modelProvenance: "local-rules", calls: [], newlySuppressedFingerprints: [],
            now: now.addingTimeInterval(600)
        )

        XCTAssertEqual(result.itemsResolved, 0, "Not looking is not the same as fixed")
        XCTAssertEqual(try store.openItems().count, 1)
    }

    // MARK: - Suppression

    func test_refutedFindingIsSuppressedAndNotRepublished() async throws {
        let now = Date()
        let publisher = BurnBarAIInboxPublisher(
            store: store, usageRecorder: usageRecorder, notifier: nil,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let config = BurnBarInboxConfig(enabled: true, egressMode: .cloud)
        let finding = BurnBarAIInboxFinding(
            kind: .promisedNotLanded,
            title: "Work may not have landed",
            summaryMarkdown: "…",
            priority: .p2,
            confidence: 0.7,
            evidenceIDs: [],
            fingerprint: "promised_not_landed:abc",
            needsVerification: true,
            source: .detector
        )

        let result = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "t1", modelProvenance: "m", calls: [],
            newlySuppressedFingerprints: [finding.fingerprint],
            now: now
        )

        XCTAssertEqual(result.itemsNew, 0, "A refuted finding must never reach the user")
        XCTAssertTrue(try store.openItems().isEmpty)

        // And it stays suppressed on the next tick, without re-verification.
        let second = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now), config: config,
            tickID: "t2", modelProvenance: "m", calls: [], newlySuppressedFingerprints: [],
            now: now.addingTimeInterval(300)
        )
        XCTAssertEqual(second.itemsNew, 0)
    }

    // MARK: - Notification policy

    func test_onlyP1ItemsNotify() async throws {
        let now = Date()
        let notifier = RecordingInboxNotifier()
        let publisher = BurnBarAIInboxPublisher(
            store: store, usageRecorder: usageRecorder, notifier: notifier,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let findings = [BurnBarInboxPriority.p2, .p3, .p4].enumerated().map { index, priority in
            BurnBarAIInboxFinding(
                kind: .uncommittedWork,
                title: "finding \(index)",
                summaryMarkdown: "…",
                priority: priority,
                confidence: 0.9,
                evidenceIDs: [],
                fingerprint: "f\(index)",
                source: .detector
            )
        }

        _ = await publisher.publish(
            findings: findings, briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: BurnBarInboxConfig(enabled: true, egressMode: .off),
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )

        let count = await notifier.count()
        XCTAssertEqual(count, 0, "Only P1 may interrupt")
        XCTAssertEqual(try store.openItems().count, 3, "Everything is still browsable")
    }

    func test_notificationsRespectTheDisableSwitch() async throws {
        let now = Date()
        let notifier = RecordingInboxNotifier()
        let publisher = BurnBarAIInboxPublisher(
            store: store, usageRecorder: usageRecorder, notifier: notifier,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let finding = BurnBarAIInboxFinding(
            kind: .ciWaste, title: "P1 thing", summaryMarkdown: "…", priority: .p1,
            confidence: 0.95, evidenceIDs: [], fingerprint: "f", source: .detector
        )

        _ = await publisher.publish(
            findings: [finding], briefMarkdown: "", pack: AIInboxFixtures.emptyPack(now: now),
            config: BurnBarInboxConfig(enabled: true, egressMode: .off, notifyOnP1: false),
            tickID: "t1", modelProvenance: "local-rules", calls: [],
            newlySuppressedFingerprints: [], now: now
        )

        let count = await notifier.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Rule-based brief (the zero-egress experience)

    func test_ruleBasedBriefIsUsefulWithoutAnyModel() {
        let now = Date()
        let pack = BurnBarAIInboxEvidencePack(
            tickID: "t",
            generatedAt: now,
            windowStart: now.addingTimeInterval(-7_200),
            conversations: [
                AIInboxFixtures.conversation()
            ],
            workspaces: [AIInboxFixtures.workspace(dirty: 4)],
            repositories: [],
            usage: [
                BurnBarAIInboxUsageAggregate(
                    projectName: "BurnBar", model: "claude-fable-5", provider: "anthropic",
                    callCount: 40, totalTokens: 120_000, costUSD: 2.35
                )
            ],
            openItems: [],
            githubAvailability: .available,
            droppedConversationCount: 0,
            estimatedPromptTokens: 0,
            indexLagSeconds: 0
        )

        let brief = BurnBarAIInboxService.ruleBasedBrief(pack: pack, findings: [], now: now)

        XCTAssertFalse(brief.isEmpty)
        XCTAssertTrue(brief.contains("BurnBar"), "Projects are named")
        XCTAssertTrue(brief.contains("uncommitted"), "Dirty state is surfaced")
        XCTAssertTrue(brief.contains("$2.35"), "Spend is quantified")
    }

    func test_ruleBasedBriefIsEmptyWhenNothingHappened() {
        let now = Date()
        XCTAssertTrue(
            BurnBarAIInboxService.ruleBasedBrief(pack: AIInboxFixtures.emptyPack(now: now), findings: [], now: now).isEmpty,
            "No activity means no brief — the inbox stays quiet"
        )
    }

    // MARK: - Budget

    func test_budgetFindingExplainsTheDegradationHonestly() {
        let finding = BurnBarAIInboxService.budgetFinding(
            budget: .init(spentUSD: 1.51, limitUSD: 1.50),
            config: BurnBarInboxConfig(),
            now: Date()
        )
        XCTAssertEqual(finding.kind, .budget)
        XCTAssertEqual(finding.priority, .p4, "Hitting the budget is informational, not urgent")
        XCTAssertTrue(finding.summaryMarkdown.contains("$1.51"))
        XCTAssertTrue(
            finding.summaryMarkdown.contains("Deterministic detection keeps running"),
            "The user must know detection continues"
        )
        XCTAssertFalse(finding.actions.isEmpty, "There must be a way to raise the limit")
    }

    func test_budgetStateDetectsExhaustion() {
        XCTAssertTrue(BurnBarAIInboxService.BudgetState(spentUSD: 2.0, limitUSD: 1.5).isExhausted)
        XCTAssertFalse(BurnBarAIInboxService.BudgetState(spentUSD: 0.2, limitUSD: 1.5).isExhausted)
        XCTAssertFalse(
            BurnBarAIInboxService.BudgetState(spentUSD: 99, limitUSD: 0).isExhausted,
            "A zero limit means unlimited, not permanently exhausted"
        )
    }
}
