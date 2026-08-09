import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The whole product sentence, against one real database:
///
///   suggestion → reply → accept into plan → standing commitment →
///   next synthesis cites it → grade → follow-up context.
///
/// This is the prove-out for "suggestions build on each other" — if this
/// passes, the compounding loop is real, not architecture prose.
final class FounderLensCompoundingLoopTests: XCTestCase {
    private var store: BurnBarAIInboxStore!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("founder-loop-\(UUID().uuidString).sqlite")
        store = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func test_fullCompoundingLoop() throws {
        let now = Date()
        let fingerprint = "ci_waste:0xfeed"

        // 1) A reply thread produces a plan candidate (what the model proposes).
        try store.appendThreadMessage(
            BurnBarInboxThreadMessage(
                id: "msg_user",
                fingerprint: fingerprint,
                role: .user,
                bodyMarkdown: "CI keeps burning runs on red workflows. What do we do?",
                createdAt: now
            ),
            itemID: nil,
            now: now
        )
        let candidate = BurnBarInboxPlanCandidate(
            title: "Kill the CI waste loop",
            bodyMarkdown: "Add a required compile gate; stop rerunning red workflows.",
            horizon: .week,
            evidenceIDs: ["item:0xfeed"]
        )
        try store.appendThreadMessage(
            BurnBarInboxThreadMessage(
                id: "msg_assistant",
                fingerprint: fingerprint,
                role: .assistant,
                bodyMarkdown: "Landed or it didn't happen: the gate is the move.",
                planCandidates: [candidate],
                modelProvenance: "test:model+lens:v1",
                costUSD: 0.003,
                createdAt: now.addingTimeInterval(1)
            ),
            itemID: nil,
            now: now.addingTimeInterval(1)
        )

        // 2) The human accepts — this is the ONLY way a plan row exists.
        let (plan, step) = try store.acceptPlan(candidate: candidate, pack: "engOps", now: now)
        XCTAssertEqual(plan.status, .active)
        XCTAssertEqual(step.status, .accepted)
        XCTAssertEqual(plan.originFingerprint, "0xfeed", "The plan traces back to the item")

        // 3) The approved memory export arrives from the app (the L21 bridge).
        _ = try store.replaceMemoryExport(
            entries: [
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_gate",
                    provenance: "ai-inbox:plan:\(plan.id):step:\(step.id)",
                    snippetMarkdown: "CI needs a required compile gate before merges.",
                    approvedAt: now
                )
            ],
            now: now
        )

        // 4) The NEXT synthesis loads both as standing commitments…
        let commitments = try store.standingCommitments(limit: 8, now: now)
        XCTAssertEqual(commitments.count, 2)
        XCTAssertTrue(commitments[0].summary.contains("Kill the CI waste loop"))
        XCTAssertTrue(commitments[1].summary.contains("compile gate"))

        // …and the analyst prompt carries them, fenced.
        let prompt = BurnBarAIInboxPromptBuilder.analystUserPrompt(
            pack: AIInboxFixtures.pack(now: now),
            detectorFindings: [],
            now: now,
            standingCommitments: commitments
        )
        XCTAssertTrue(prompt.contains("# Standing commitments"))
        XCTAssertTrue(prompt.contains("Kill the CI waste loop"))
        XCTAssertTrue(prompt.contains(LLMSafeContent.untrustedOpenMarker))

        // 5) Execution: the step is promoted (mission bound) and later lands.
        _ = try store.updatePlanStep(
            stepID: step.id, status: .inProgress, missionID: "mission_ci_gate", followupID: nil, now: now
        )
        let landed = try store.updatePlanStep(
            stepID: step.id, status: .landed, missionID: nil, followupID: nil, now: now
        )
        XCTAssertEqual(landed.missionID, "mission_ci_gate")
        XCTAssertEqual(landed.grade, 85, "Landing auto-seeds the grade")

        // 6) The human overrides the grade with a note; the average follows.
        let graded = try store.gradePlanStep(
            stepID: step.id, grade: 95, noteMarkdown: "Gate landed; zero wasted runs this week.", now: now
        )
        XCTAssertEqual(graded.step.grade, 95)
        XCTAssertEqual(graded.planAverage ?? 0, 95, accuracy: 0.01)

        // 7) The audit trail explains every transition.
        let events = try store.queryRows(
            "SELECT event FROM ai_inbox_plan_events WHERE plan_id = ? ORDER BY rowid",
            [.text(plan.id)]
        ).map { $0.string(0) }
        XCTAssertEqual(events, ["accepted", "step_updated", "step_updated", "graded"])

        // 8) And the next brief's commitments now carry the grade.
        let after = try store.standingCommitments(limit: 8, now: now)
        XCTAssertTrue(
            after.contains { $0.summary.contains("grade 95") },
            "Grades feed forward into future synthesis"
        )
    }
}

