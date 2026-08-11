import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The Founder Plan Ledger + threads + memory export, against a real SQLite
/// database: accept → active step → standing commitments → grade → average,
/// plus thread persistence and the full-set-replacement export contract.
final class FounderPlanLedgerTests: XCTestCase {
    private var store: BurnBarAIInboxStore!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("founder-ledger-\(UUID().uuidString).sqlite")
        store = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: - Plans

    func test_acceptCreatesActivePlanWithAcceptedStepAndAuditEvent() throws {
        let now = Date()
        let (plan, step) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(
                title: "Kill the CI waste loop",
                bodyMarkdown: "Land #420 so trunk compiles; stop rerunning red workflows.",
                horizon: .week,
                evidenceIDs: ["item:abc123"]
            ),
            pack: "engOps",
            now: now
        )

        XCTAssertTrue(plan.id.hasPrefix("plan_"))
        XCTAssertEqual(plan.status, .active)
        XCTAssertEqual(plan.pack, "engOps")
        XCTAssertEqual(plan.originFingerprint, "abc123")
        XCTAssertEqual(step.status, .accepted)
        XCTAssertEqual(step.ordinal, 1)
        XCTAssertEqual(step.evidenceIDs, ["item:abc123"])

        let events = try store.queryRows(
            "SELECT event FROM ai_inbox_plan_events WHERE plan_id = ?",
            [.text(plan.id)]
        ).map { $0.string(0) }
        XCTAssertEqual(events, ["accepted"])
    }

    func test_acceptOntoExistingPlanAppendsStepWithNextOrdinal() throws {
        let now = Date()
        let (plan, _) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(title: "First", bodyMarkdown: "One."),
            pack: "engOps",
            now: now
        )
        let (samePlan, second) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(
                title: "Second",
                bodyMarkdown: "Two.",
                planID: plan.id
            ),
            pack: "engOps",
            now: now
        )
        XCTAssertEqual(samePlan.id, plan.id)
        XCTAssertEqual(second.ordinal, 2)
        XCTAssertEqual(samePlan.steps.count, 2)
    }

    func test_acceptOntoMissingPlanThrows() {
        XCTAssertThrowsError(
            try store.acceptPlan(
                candidate: BurnBarInboxPlanCandidate(
                    title: "Orphan",
                    bodyMarkdown: "No home.",
                    planID: "plan_missing"
                ),
                pack: "engOps",
                now: Date()
            )
        )
    }

    func test_updateStepBindsMissionAndStampsTerminalCompletion() throws {
        let now = Date()
        let (_, step) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(title: "Ship it", bodyMarkdown: "Do."),
            pack: "engOps",
            now: now
        )

        let inProgress = try store.updatePlanStep(
            stepID: step.id,
            status: .inProgress,
            missionID: "mission_42",
            followupID: nil,
            now: now
        )
        XCTAssertEqual(inProgress.status, .inProgress)
        XCTAssertEqual(inProgress.missionID, "mission_42")
        XCTAssertNil(inProgress.completedAt)

        let landed = try store.updatePlanStep(
            stepID: step.id,
            status: .landed,
            missionID: nil,
            followupID: nil,
            now: now
        )
        XCTAssertEqual(landed.status, .landed)
        XCTAssertNotNil(landed.completedAt)
        // COALESCE keeps the earlier mission binding.
        XCTAssertEqual(landed.missionID, "mission_42")
    }

    /// Terminal outcomes auto-seed a grade (landed=85, failed=25) so ungraded
    /// steps still feed the loop; an explicit grade overwrites the seed.
    func test_terminalStatusSeedsGradeAndExplicitGradeOverrides() throws {
        let now = Date()
        let (_, step) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(title: "Seed", bodyMarkdown: "s"),
            pack: "engOps",
            now: now
        )
        let landed = try store.updatePlanStep(
            stepID: step.id, status: .landed, missionID: nil, followupID: nil, now: now
        )
        XCTAssertEqual(landed.grade, 85, "Landing seeds a default grade")
        XCTAssertNotNil(landed.gradedAt)

        let regraded = try store.gradePlanStep(stepID: step.id, grade: 95, noteMarkdown: "Shipped clean.", now: now)
        XCTAssertEqual(regraded.step.grade, 95, "The human grade wins")

        let (_, failing) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(title: "Flop", bodyMarkdown: "f"),
            pack: "engOps",
            now: now
        )
        let failed = try store.updatePlanStep(
            stepID: failing.id, status: .failed, missionID: nil, followupID: nil, now: now
        )
        XCTAssertEqual(failed.grade, 25, "Failure seeds a low grade")
    }

    func test_gradeClampsAndRollsUpPlanAverage() throws {
        let now = Date()
        let (plan, first) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(title: "A", bodyMarkdown: "a"),
            pack: "engOps",
            now: now
        )
        let (_, second) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(title: "B", bodyMarkdown: "b", planID: plan.id),
            pack: "engOps",
            now: now
        )

        let graded = try store.gradePlanStep(stepID: first.id, grade: 40, noteMarkdown: "Not landed.", now: now)
        XCTAssertEqual(graded.step.grade, 40)
        XCTAssertEqual(graded.planAverage ?? -1, 40, accuracy: 0.01)

        let overflowing = try store.gradePlanStep(stepID: second.id, grade: 250, noteMarkdown: nil, now: now)
        XCTAssertEqual(overflowing.step.grade, 100, "Grades clamp to 0–100")
        XCTAssertEqual(overflowing.planAverage ?? -1, 70, accuracy: 0.01)
    }

    func test_memoryBindingIsDurableAndIdempotent() throws {
        let now = Date()
        let (_, step) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(
                title: "Keep the release gate",
                bodyMarkdown: "Require exact candidate proof."
            ),
            pack: "engOps",
            now: now
        )

        let first = try store.bindPlanStepMemory(
            stepID: step.id,
            memoryID: "mem_release_gate",
            now: now
        )
        let retry = try store.bindPlanStepMemory(
            stepID: step.id,
            memoryID: "mem_release_gate",
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(first.memoryID, "mem_release_gate")
        XCTAssertEqual(retry.memoryID, "mem_release_gate")
        XCTAssertEqual(
            try store.queryRows(
                "SELECT COUNT(*) FROM ai_inbox_plan_events WHERE step_id = ? AND event = 'memory_bound'",
                [.text(step.id)]
            ).first?.int(0),
            1,
            "An idempotent retry must not append a duplicate binding event."
        )
        XCTAssertThrowsError(
            try store.bindPlanStepMemory(
                stepID: step.id,
                memoryID: "mem_different",
                now: now
            )
        )
    }

    // MARK: - Standing commitments

    func test_standingCommitmentsRenderActivePlansAndExportedFacts() throws {
        let now = Date()
        let (plan, step) = try store.acceptPlan(
            candidate: BurnBarInboxPlanCandidate(
                title: "Stop CI waste",
                bodyMarkdown: "Kill red rerun loops."
            ),
            pack: "engOps",
            now: now
        )
        _ = try store.gradePlanStep(stepID: step.id, grade: 40, noteMarkdown: nil, now: now)
        _ = try store.replaceMemoryExport(
            entries: [
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_1",
                    provenance: "ai-inbox:plan:\(plan.id)",
                    snippetMarkdown: "Trunk must compile before merges.",
                    approvedAt: now
                )
            ],
            now: now
        )

        let commitments = try store.standingCommitments(limit: 8, now: now)
        XCTAssertEqual(commitments.count, 2)
        XCTAssertTrue(commitments[0].summary.contains("Stop CI waste"))
        XCTAssertTrue(commitments[0].summary.contains("grade 40"))
        XCTAssertTrue(commitments[0].summary.contains("next: Stop CI waste"))
        XCTAssertTrue(commitments[1].summary.contains("Trunk must compile"))
    }

    func test_standingCommitmentsEmptyWhenNothingActive() throws {
        XCTAssertEqual(try store.standingCommitments(limit: 8, now: Date()), [])
    }

    // MARK: - Threads

    func test_threadPersistsTurnsAndAccumulatesCost() throws {
        let now = Date()
        let fingerprint = "ci_waste:deadbeef"

        try store.appendThreadMessage(
            BurnBarInboxThreadMessage(
                id: "msg_1",
                fingerprint: fingerprint,
                role: .user,
                bodyMarkdown: "Why is this still failing?",
                createdAt: now
            ),
            itemID: "item_1",
            now: now
        )
        try store.appendThreadMessage(
            BurnBarInboxThreadMessage(
                id: "msg_2",
                fingerprint: fingerprint,
                role: .assistant,
                bodyMarkdown: "Because #420 never landed. Land it.",
                planCandidates: [
                    BurnBarInboxPlanCandidate(title: "Land #420", bodyMarkdown: "Trunk first.")
                ],
                modelProvenance: "deepseek:deepseek-v4-flash+lens:v1",
                costUSD: 0.004,
                createdAt: now.addingTimeInterval(1)
            ),
            itemID: "item_1",
            now: now.addingTimeInterval(1)
        )

        let thread = try XCTUnwrap(try store.thread(fingerprint: fingerprint))
        XCTAssertEqual(thread.turnCount, 2)
        XCTAssertEqual(thread.itemID, "item_1")
        XCTAssertEqual(thread.totalCostUSD, 0.004, accuracy: 0.0001)
        XCTAssertEqual(thread.messages.map(\.id), ["msg_1", "msg_2"])
        XCTAssertEqual(thread.messages[1].planCandidates.first?.title, "Land #420")
        XCTAssertNil(try store.thread(fingerprint: "missing"))
    }

    // MARK: - Memory export

    func test_memoryExportIsFullSetReplacement() throws {
        let now = Date()
        _ = try store.replaceMemoryExport(
            entries: [
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_a", provenance: "p:a", snippetMarkdown: "A", approvedAt: now
                ),
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_b", provenance: "p:b", snippetMarkdown: "B", approvedAt: now
                )
            ],
            now: now
        )
        // Second push omits mem_a → revocation by omission.
        let stored = try store.replaceMemoryExport(
            entries: [
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_b", provenance: "p:b", snippetMarkdown: "B2", approvedAt: now
                )
            ],
            now: now
        )
        XCTAssertEqual(stored, 1)
        let rows = try store.queryRows(
            "SELECT memory_id, snippet_md FROM ai_inbox_memory_export ORDER BY memory_id",
            []
        ).map { ($0.string(0), $0.string(1)) }
        XCTAssertEqual(rows.map(\.0), ["mem_b"])
        XCTAssertEqual(rows.map(\.1), ["B2"])
    }

    func test_singleMemoryExportUpsertAndRemovalDoNotReplaceUnrelatedRows() throws {
        let now = Date()
        _ = try store.replaceMemoryExport(
            entries: [
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_existing",
                    provenance: "existing",
                    snippetMarkdown: "Keep me.",
                    approvedAt: now
                )
            ],
            now: now
        )

        try store.upsertMemoryExport(
            entry: BurnBarInboxMemoryExportEntry(
                memoryID: "mem_new",
                provenance: "ai-inbox:item:fp:candidate:c1",
                snippetMarkdown: "New approved memory.",
                approvedAt: now
            ),
            now: now
        )
        XCTAssertEqual(
            try store.queryRows(
                "SELECT memory_id FROM ai_inbox_memory_export ORDER BY memory_id",
                []
            ).map { $0.string(0) },
            ["mem_existing", "mem_new"]
        )

        try store.removeMemoryExport(memoryID: "mem_new")
        XCTAssertEqual(
            try store.queryRows(
                "SELECT memory_id FROM ai_inbox_memory_export ORDER BY memory_id",
                []
            ).map { $0.string(0) },
            ["mem_existing"]
        )
    }
}
