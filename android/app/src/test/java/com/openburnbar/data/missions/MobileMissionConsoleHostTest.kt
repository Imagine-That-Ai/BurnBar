package com.openburnbar.data.missions

import com.openburnbar.data.assistants.CLIAgentMissionEvent
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM coverage for the snapshot transformer that drives the
 * Hermes Square Mission Console host. We test `toActiveMission()` and
 * `toApprovalAskOrNull()` directly because the host pipes Firestore
 * snapshots through them; a Firestore-emulator-backed integration is
 * not feasible from a JVM unit test (the Firestore SDK requires native
 * gRPC). Hooking up an emulator is the instrumented suite's job.
 */
class MobileMissionConsoleHostTest {

    private fun snapshot(
        id: String,
        status: String,
        events: List<CLIAgentMissionEvent> = emptyList(),
        selectedRuntime: String? = null,
        approvalStatus: String? = null,
    ) = CLIAgentMissionSnapshot(
        id = id,
        title = "Mission $id",
        status = status,
        requestedRuntime = "auto",
        requestedModelID = null,
        selectedRuntime = selectedRuntime,
        selectedRuntimeName = null,
        selectedModelID = null,
        liveSummary = "live summary $id",
        resultPreview = null,
        errorMessage = null,
        sessionID = null,
        approvalRequestId = null,
        approvalStatus = approvalStatus,
        approvalTitle = null,
        approvalMessage = null,
        events = events,
        createdAt = Instant.now(),
    )

    @Test
    fun snapshot_running_with_tool_event_promotes_to_tooling_phase() {
        val event = CLIAgentMissionEvent(
            sequence = 1,
            timestamp = Instant.now().toString(),
            kind = "tool_call",
            phase = "tool_use",
            title = "ripgrep search",
            message = "rg HermesSquare",
            fullMessage = null,
            messageLength = null,
            messageTruncated = false,
            runtime = "claude",
            source = "mac",
            toolName = "ripgrep",
            artifactPath = null,
            changedFilePath = null,
            isError = false,
        )
        val mission = snapshot(id = "m-1", status = "running", events = listOf(event), selectedRuntime = "claude")
            .toActiveMission()
        assertEquals(ActiveMission.Phase.TOOLING, mission.phase)
        assertEquals("ripgrep", mission.currentToolName)
        assertEquals("claude", mission.runtimeID)
    }

    @Test
    fun terminal_snapshot_renders_completed_active_mission() {
        val mission = snapshot(id = "m-2", status = "completed", selectedRuntime = "codex").toActiveMission()
        assertEquals(ActiveMission.Phase.COMPLETED, mission.phase)
        assertEquals(1.0, mission.progressFraction)
        assertEquals("codex", mission.runtimeID)
    }

    @Test
    fun pending_snapshot_renders_queued_active_mission() {
        val snap = snapshot(id = "m-3", status = "pending")
        val mission = snap.toActiveMission()
        assertTrue(mission.phase == ActiveMission.Phase.QUEUED || mission.phase == ActiveMission.Phase.MAC_OFFLINE)
    }

    @Test
    fun waiting_for_approval_yields_approval_ask() {
        val snap = snapshot(id = "m-4", status = "waiting_for_approval", approvalStatus = "pending")
        val ask = snap.toApprovalAskOrNull()
        assertNotNull(ask)
        assertEquals("m-4", ask!!.missionID)
        assertTrue(ask.title.contains("Approve"))
    }

    @Test
    fun non_waiting_snapshot_has_no_approval_ask() {
        val snap = snapshot(id = "m-5", status = "running")
        assertNull(snap.toApprovalAskOrNull())
    }

    @Test
    fun runtime_id_guess_normalizes_common_tokens() {
        assertEquals("claude", runtimeIDGuess("claude-sonnet-4.6"))
        assertEquals("codex", runtimeIDGuess("openai-codex"))
        assertEquals("pi", runtimeIDGuess("PI-AGENT"))
        assertEquals("hermes", runtimeIDGuess("hermes-mac"))
        assertEquals("openclaw", runtimeIDGuess("openclaw-mac"))
        assertEquals(null, runtimeIDGuess("auto"))
        assertEquals(null, runtimeIDGuess("  "))
    }

    @Test
    fun mission_console_snapshot_empty_is_a_stable_default() {
        // The host itself can't be exercised on the JVM because its
        // constructor calls FirebaseAuth.getInstance(); we cover its
        // integration with Firestore in the instrumented suite. Here we
        // pin the default snapshot the UI binds to before the host
        // emits its first value, so a Compose preview using
        // `MissionConsoleSnapshot.EMPTY` won't break silently.
        val empty = MissionConsoleSnapshot.EMPTY
        assertTrue(empty.activeMissions.isEmpty())
        assertTrue(empty.approvalQueue.isEmpty())
        assertTrue(empty.groups.isEmpty())
        assertTrue(empty.recentTicker.isEmpty())
        assertEquals(DaemonState.UNKNOWN, empty.daemonState)
        assertEquals(0, empty.openMissions)
        assertEquals(0, empty.queuedMissions)
        assertEquals(0, empty.blockedMissions)
    }
}
