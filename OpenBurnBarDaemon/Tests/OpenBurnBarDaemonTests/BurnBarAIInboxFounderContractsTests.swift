import Foundation
import OpenBurnBarEngine
import XCTest

/// Wire-shape coverage for the Founder Lens DTOs: every request/response
/// round-trips through Codable, clamps behave, and optional fields default —
/// so a daemon and app compiled from different commits agree on the bytes.
final class BurnBarAIInboxFounderContractsTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    func test_threadMessageRoundTripsWithCandidates() throws {
        let now = Date(timeIntervalSince1970: 1_754_700_000)
        let message = BurnBarInboxThreadMessage(
            id: "msg_1",
            fingerprint: "ci_waste:fp",
            role: .assistant,
            bodyMarkdown: "Land it.",
            planCandidates: [
                BurnBarInboxPlanCandidate(
                    title: "Land #420",
                    bodyMarkdown: "Trunk first.",
                    horizon: .month,
                    evidenceIDs: ["item:x"],
                    planID: "plan_x"
                )
            ],
            modelProvenance: "test:model+lens:v1",
            costUSD: 0.004,
            createdAt: now
        )
        let decoded = try roundTrip(message)
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.planCandidates.first?.horizon, .month)
    }

    func test_threadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_754_700_000)
        let thread = BurnBarInboxThread(
            fingerprint: "fp",
            itemID: "item_1",
            createdAt: now,
            updatedAt: now,
            turnCount: 2,
            totalCostUSD: 0.01,
            messages: [
                BurnBarInboxThreadMessage(
                    id: "m1", fingerprint: "fp", role: .user, bodyMarkdown: "hi", createdAt: now
                )
            ]
        )
        XCTAssertEqual(try roundTrip(thread), thread)
    }

    func test_replyRequestAndResponseRoundTrip() throws {
        let request = BurnBarInboxReplyRequest(fingerprint: "fp", bodyMarkdown: "why?")
        XCTAssertEqual(try roundTrip(request), request)

        let refusal = BurnBarInboxReplyResponse(message: nil, refusalReason: "budget")
        let decodedRefusal = try roundTrip(refusal)
        XCTAssertNil(decodedRefusal.message)
        XCTAssertEqual(decodedRefusal.refusalReason, "budget")
    }

    func test_planWithStepsRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_754_700_000)
        let step = BurnBarInboxPlanStep(
            id: "step_1",
            planID: "plan_1",
            parentStepID: "step_0",
            ordinal: 2,
            title: "Do it",
            bodyMarkdown: "Well.",
            status: .inProgress,
            nextMoveMarkdown: "Ship.",
            evidenceIDs: ["item:a"],
            missionID: "mission_1",
            followupID: "followup_1",
            memoryID: "mem_step_1",
            inboxFingerprint: "fp",
            grade: 85,
            gradeNoteMarkdown: "Auto-seeded.",
            gradedAt: now,
            createdAt: now,
            updatedAt: now,
            completedAt: now
        )
        let plan = BurnBarInboxPlan(
            id: "plan_1",
            title: "The plan",
            horizon: .quarter,
            pack: "engOps",
            status: .active,
            summaryMarkdown: "Summary.",
            createdAt: now,
            updatedAt: now,
            originFingerprint: "fp",
            memoryID: "mem_1",
            pensieveVectorID: "vec_1",
            gradeAverage: 85,
            steps: [step]
        )
        let decoded = try roundTrip(plan)
        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.steps.first?.status, .inProgress)
        XCTAssertEqual(decoded.steps.first?.memoryID, "mem_step_1")
    }

    func test_planStepStatusRawValuesAreWireStable() {
        XCTAssertEqual(BurnBarInboxPlanStepStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(
            BurnBarInboxPlanStepStatus.allCases.map(\.rawValue),
            ["proposed", "accepted", "in_progress", "landed", "failed", "killed"]
        )
        XCTAssertEqual(
            BurnBarInboxPlanStatus.allCases.map(\.rawValue),
            ["proposed", "active", "paused", "completed", "killed"]
        )
        XCTAssertEqual(
            BurnBarInboxPlanHorizon.allCases.map(\.rawValue),
            ["week", "month", "quarter", "ongoing"]
        )
    }

    func test_plansListRequestClampsLimit() throws {
        XCTAssertEqual(BurnBarInboxPlansListRequest(limit: 0).limit, 1)
        XCTAssertEqual(BurnBarInboxPlansListRequest(limit: 9_999).limit, 200)
        let request = BurnBarInboxPlansListRequest(statuses: [.active], limit: 10)
        let decoded = try roundTrip(request)
        XCTAssertEqual(decoded.statuses, [.active])
        XCTAssertEqual(decoded.limit, 10)
    }

    func test_acceptUpdateGradeRequestsRoundTrip() throws {
        let accept = BurnBarInboxPlanAcceptRequest(
            candidate: BurnBarInboxPlanCandidate(title: "T", bodyMarkdown: "B"),
            pack: "productStrategy"
        )
        XCTAssertEqual(try roundTrip(accept), accept)
        // Candidate defaults: week horizon, no evidence, new plan.
        XCTAssertEqual(accept.candidate.horizon, .week)
        XCTAssertTrue(accept.candidate.evidenceIDs.isEmpty)
        XCTAssertNil(accept.candidate.planID)

        let update = BurnBarInboxPlanUpdateStepRequest(
            stepID: "s", status: .landed, missionID: "m", followupID: "f"
        )
        XCTAssertEqual(try roundTrip(update), update)
        let sparse = BurnBarInboxPlanUpdateStepRequest(stepID: "s")
        XCTAssertNil(sparse.status)
        XCTAssertNil(sparse.missionID)

        let grade = BurnBarInboxPlanGradeRequest(stepID: "s", grade: 95, noteMarkdown: "n")
        XCTAssertEqual(try roundTrip(grade), grade)
    }

    func test_memoryExportRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_754_700_000)
        let request = BurnBarInboxMemoryExportRequest(
            entries: [
                BurnBarInboxMemoryExportEntry(
                    memoryID: "mem_1",
                    provenance: "ai-inbox:plan:p:step:s",
                    snippetMarkdown: "Fact.",
                    approvedAt: now
                )
            ]
        )
        XCTAssertEqual(try roundTrip(request), request)
        XCTAssertEqual(try roundTrip(BurnBarInboxMemoryExportResponse(stored: 1)).stored, 1)
    }

    func test_daemonAuthoritativeMemoryAndFollowupActionsRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_754_700_000)
        let step = BurnBarInboxPlanStep(
            id: "step_1",
            planID: "plan_1",
            ordinal: 1,
            title: "Land the gate",
            bodyMarkdown: "Make it required.",
            status: .accepted,
            memoryID: "mem_step_1",
            createdAt: now,
            updatedAt: now
        )
        let plan = BurnBarInboxPlan(
            id: "plan_1",
            title: "Ship parity",
            horizon: .week,
            pack: "engOps",
            status: .active,
            summaryMarkdown: "Close the remaining gaps.",
            createdAt: now,
            updatedAt: now,
            steps: [step]
        )
        let memory = BurnBarInboxMemoryApprovalResponse(
            memoryID: "mem_step_1",
            provenance: "ai-inbox:plan:plan_1:step:step_1",
            quarantineAuditHash: "quarantine-hash",
            approvalAuditHash: "approval-hash"
        )

        XCTAssertEqual(
            try roundTrip(
                BurnBarInboxMemoryCandidateApproveRequest(
                    itemID: "inb_1",
                    fingerprint: "ci_waste:linux",
                    candidateID: "candidate_1",
                    projectPath: "/tmp/project"
                )
            ).candidateID,
            "candidate_1"
        )
        XCTAssertEqual(
            try roundTrip(
                BurnBarInboxPlanRememberStepResponse(
                    plan: plan,
                    step: step,
                    memory: memory
                )
            ).memory,
            memory
        )
        let followup = BurnBarInboxPlanCreateFollowupResponse(
            plan: plan,
            step: step,
            followupID: "followup-inbox-step_1",
            projectSlug: "burnbar",
            title: step.title,
            dueAt: now
        )
        XCTAssertEqual(try roundTrip(followup), followup)
        XCTAssertEqual(
            try roundTrip(
                BurnBarInboxPlanCreateFollowupRequest(
                    stepID: step.id,
                    projectSlug: "burnbar",
                    dueAt: now
                )
            ).dueAt,
            now
        )
    }
}
