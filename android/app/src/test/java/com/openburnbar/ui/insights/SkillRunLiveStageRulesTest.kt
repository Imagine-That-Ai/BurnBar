package com.openburnbar.ui.insights

import com.openburnbar.data.assistants.CLIAgentMissionEvent
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.assistants.SkillRunEventImportance
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillRunLiveStageRulesTest {
    @Test
    fun fullStreamSkillRunAutoOpensFollowAlongTile() {
        val mission = skillRun(deliveryMode = SkillRunDeliveryMode.FULL_STREAM)

        assertTrue(shouldAutoOpenSkillRun(mission))
    }

    @Test
    fun mutedSkillRunStaysQuiet() {
        val mission = skillRun(deliveryMode = SkillRunDeliveryMode.MUTED)

        assertFalse(shouldAutoOpenSkillRun(mission))
    }

    @Test
    fun actionOnlySkillRunOpensForApprovalsAndTerminalResults() {
        val approval =
            skillRun(
                status = "waiting_for_approval",
                approvalStatus = "pending",
                events = listOf(event(SkillRunEventImportance.ACTION_REQUIRED)),
            )
        val completed = skillRun(status = "completed")

        assertTrue(shouldAutoOpenSkillRun(approval))
        assertTrue(shouldAutoOpenSkillRun(completed))
    }

    @Test
    fun actionOnlySkillRunIgnoresNormalProgressEvents() {
        val mission = skillRun(events = listOf(event(SkillRunEventImportance.NORMAL)))

        assertFalse(shouldAutoOpenSkillRun(mission))
    }

    @Test
    fun dismissalNotificationKeyChangesWhenNewApprovalEventArrives() {
        val running =
            skillRun(
                status = "running",
                deliveryMode = SkillRunDeliveryMode.FULL_STREAM,
                events = listOf(event(SkillRunEventImportance.NORMAL, sequence = 1)),
            )
        val approval =
            skillRun(
                status = "waiting_for_approval",
                deliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
                approvalStatus = "pending",
                events = listOf(event(SkillRunEventImportance.ACTION_REQUIRED, sequence = 2)),
            )

        assertNotEquals(skillRunNotificationKey(running), skillRunNotificationKey(approval))
        assertTrue(shouldAutoOpenSkillRun(approval))
    }

    @Test
    fun dismissalNotificationKeyIgnoresNormalFullStreamProgressChurn() {
        val firstProgress =
            skillRun(
                status = "running",
                deliveryMode = SkillRunDeliveryMode.FULL_STREAM,
                events = listOf(event(SkillRunEventImportance.NORMAL, sequence = 1)),
            )
        val nextProgress =
            skillRun(
                status = "running",
                deliveryMode = SkillRunDeliveryMode.FULL_STREAM,
                events = listOf(event(SkillRunEventImportance.NORMAL, sequence = 2)),
            )

        assertEquals(skillRunNotificationKey(firstProgress), skillRunNotificationKey(nextProgress))
    }

    @Test
    fun companionControlsRenderOnlyForSkillRunMissions() {
        assertTrue(shouldShowSkillRunCompanionControls(skillRun(sourceSkillID = "run_pulse")))
        assertFalse(shouldShowSkillRunCompanionControls(skillRun(sourceSkillID = null)))
    }

    private fun skillRun(
        status: String = "running",
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        approvalStatus: String? = null,
        events: List<CLIAgentMissionEvent> = emptyList(),
        sourceSkillID: String? = "run_pulse",
    ) = CLIAgentMissionSnapshot(
        id = "skill-run-$status-${deliveryMode.wire}",
        title = "Run Pulse follow-along",
        status = status,
        requestedRuntime = "codex",
        requestedModelID = null,
        selectedRuntime = "codex",
        selectedRuntimeName = "Codex",
        selectedModelID = null,
        targetProject = null,
        sourceSkillID = sourceSkillID,
        sourceSurface = "android-hermes-square",
        deliveryMode = deliveryMode,
        parentHermesThreadID = "thread-1",
        liveSummary = "Codex is reading recent sessions.",
        resultPreview = if (status == "completed") "Done." else null,
        errorMessage = null,
        sessionID = null,
        approvalRequestId = if (approvalStatus == "pending") "approval-1" else null,
        approvalStatus = approvalStatus,
        approvalTitle = if (approvalStatus == "pending") "Approve Skill Run" else null,
        approvalMessage = if (approvalStatus == "pending") "Codex needs approval." else null,
        events = events,
        createdAt = Instant.now(),
    )

    private fun event(importance: SkillRunEventImportance, sequence: Int = 1) = CLIAgentMissionEvent(
        sequence = sequence,
        timestamp = "2026-05-14T10:00:00Z",
        kind = if (importance == SkillRunEventImportance.ACTION_REQUIRED) "approval_request" else "status",
        phase = "running",
        title = if (importance == SkillRunEventImportance.ACTION_REQUIRED) "Approval needed" else "Running",
        message =
        if (importance == SkillRunEventImportance.ACTION_REQUIRED) {
            "Codex needs approval."
        } else {
            "Codex is reading recent sessions."
        },
        fullMessage = null,
        messageLength = null,
        messageTruncated = false,
        runtime = "codex",
        source = "mac",
        toolName = null,
        artifactPath = null,
        changedFilePath = null,
        sourceSkillID = "run_pulse",
        deliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        eventImportance = importance,
        skillStepID = "follow_along",
        isError = false,
    )
}
