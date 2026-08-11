import Foundation
import OpenBurnBarKernel

/// Executes an accepted Founder Plan step through the EXISTING execution
/// spine — Mission Control and followups — never a parallel system.
///
/// Both promotions are user-confirmed (the buttons live behind confirm
/// affordances in the UI) and both write the resulting id back onto the plan
/// step, so the ledger can trace suggestion → plan → mission → grade.
@MainActor
struct InboxPlanPromoteService {
    private let socketURL: URL

    init(socketURL: URL = OpenBurnBarDaemonRuntimePaths.live().socketURL) {
        self.socketURL = socketURL
    }

    /// Promote to mission: creates a Mission Control mission from the step and
    /// binds `mission_id` onto the step (status → in_progress).
    ///
    /// `recommendation` is `.review` deliberately — a plan-born mission starts
    /// as a reviewed proposal, not an auto-proceed; Mission Control's own
    /// approval flow stays the authority on execution.
    @discardableResult
    func promoteToMission(
        step: BurnBarInboxPlanStep,
        plan: BurnBarInboxPlan,
        projectSlug: String
    ) async throws -> String {
        let request = BurnBarMissionCreateRequest(
            projectSlug: projectSlug,
            title: step.title,
            summary: step.bodyMarkdown,
            createdBy: "ai-inbox:plan:\(plan.id)",
            recommendation: .review,
            metadata: [
                "ai_inbox_plan_id": .string(plan.id),
                "ai_inbox_step_id": .string(step.id)
            ]
        )
        let socketURL = self.socketURL
        let response = try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.missionCreate(request, at: socketURL)
        }.value
        let missionID = response.mission.id.rawValue
        _ = try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.inboxPlanUpdateStep(
                stepID: step.id,
                status: .inProgress,
                missionID: missionID,
                at: socketURL
            )
        }.value
        return missionID
    }

    /// Create a follow-up: a lighter commitment than a mission — "nudge me
    /// about this" — bound back onto the step as `followup_id`.
    @discardableResult
    func createFollowup(
        step: BurnBarInboxPlanStep,
        plan: BurnBarInboxPlan,
        projectSlug: String
    ) async throws -> String {
        let followupID = "followup-inbox-\(step.id)"
        let snapshot = BurnBarFollowupSnapshot(
            id: BurnBarFollowupID(rawValue: followupID),
            projectSlug: projectSlug,
            title: step.title,
            summary: "\(plan.title): \(step.bodyMarkdown)",
            status: .open,
            kind: .controllerNudge,
            createdAt: Date(),
            metadata: [
                "ai_inbox_plan_id": .string(plan.id),
                "ai_inbox_step_id": .string(step.id)
            ]
        )
        let socketURL = self.socketURL
        _ = try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.followupCreate(
                BurnBarFollowupCreateRequest(followup: snapshot),
                at: socketURL
            )
        }.value
        _ = try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.inboxPlanUpdateStep(
                stepID: step.id,
                followupID: followupID,
                at: socketURL
            )
        }.value
        return followupID
    }
}
