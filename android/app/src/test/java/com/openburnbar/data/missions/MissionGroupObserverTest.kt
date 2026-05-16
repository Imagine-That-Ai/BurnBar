package com.openburnbar.data.missions

import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * The MissionGroupObserver itself is Firestore-coupled; the meaningful
 * pure logic lives on `MissionGroupSnapshot.derivedPhase` and
 * `childPhaseTally`. Those are what drive the fan-out card's "2 of 3
 * done" line, so the parity-critical paths are covered here.
 */
class MissionGroupObserverTest {

    private fun child(id: String, status: String, approvalStatus: String? = null): CLIAgentMissionSnapshot =
        CLIAgentMissionSnapshot(
            id = id,
            title = "child $id",
            status = status,
            requestedRuntime = "auto",
            requestedModelID = null,
            selectedRuntime = null,
            selectedRuntimeName = null,
            selectedModelID = null,
            liveSummary = null,
            resultPreview = null,
            errorMessage = null,
            sessionID = null,
            approvalRequestId = null,
            approvalStatus = approvalStatus,
            approvalTitle = null,
            approvalMessage = null,
            events = emptyList(),
            createdAt = Instant.now(),
        )

    private fun group(phase: String, childIds: List<String>) = MissionGroup(
        id = "g-1",
        title = "Group",
        prompt = "do work",
        missionKind = "research",
        targetProject = null,
        childMissionIDs = childIds,
        runtimeTokens = listOf("claude", "codex"),
        parallelismLimit = 2,
        mergeStrategy = "pick_one",
        phase = phase,
        winnerMissionID = null,
        createdAtEpoch = System.currentTimeMillis(),
        updatedAtEpoch = System.currentTimeMillis(),
    )

    @Test
    fun derived_phase_completed_when_all_children_done() {
        val snap = MissionGroupSnapshot(
            group = group("running", listOf("a", "b")),
            childSnapshots = mapOf(
                "a" to child("a", "completed"),
                "b" to child("b", "completed"),
            ),
        )
        assertEquals("completed", snap.derivedPhase)
    }

    @Test
    fun derived_phase_failed_when_any_child_failed() {
        val snap = MissionGroupSnapshot(
            group = group("running", listOf("a", "b")),
            childSnapshots = mapOf(
                "a" to child("a", "completed"),
                "b" to child("b", "failed"),
            ),
        )
        assertEquals("failed", snap.derivedPhase)
    }

    @Test
    fun derived_phase_awaiting_approval_when_any_child_waiting() {
        val snap = MissionGroupSnapshot(
            group = group("running", listOf("a", "b")),
            childSnapshots = mapOf(
                "a" to child("a", "running"),
                "b" to child("b", "waiting_for_approval", approvalStatus = "pending"),
            ),
        )
        assertEquals("awaiting_approval", snap.derivedPhase)
    }

    @Test
    fun derived_phase_running_when_any_child_running() {
        val snap = MissionGroupSnapshot(
            group = group("queued", listOf("a", "b")),
            childSnapshots = mapOf(
                "a" to child("a", "running"),
                "b" to child("b", "queued"),
            ),
        )
        assertEquals("running", snap.derivedPhase)
    }

    @Test
    fun derived_phase_returns_null_when_no_group() {
        val snap = MissionGroupSnapshot(group = null)
        assertEquals(null, snap.derivedPhase)
    }

    @Test
    fun tally_breaks_children_into_live_terminal_and_awaiting() {
        val snap = MissionGroupSnapshot(
            group = group("running", listOf("a", "b", "c", "d")),
            childSnapshots = mapOf(
                "a" to child("a", "running"),
                "b" to child("b", "completed"),
                "c" to child("c", "waiting_for_approval", approvalStatus = "pending"),
                "d" to child("d", "failed"),
            ),
        )
        val tally = snap.childPhaseTally
        assertEquals(2, tally.terminal)
        assertEquals(2, tally.live)
        assertEquals(1, tally.awaitingApproval)
    }
}
