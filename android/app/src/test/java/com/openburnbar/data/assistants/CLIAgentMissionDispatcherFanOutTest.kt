package com.openburnbar.data.assistants

import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.WriteBatch
import com.openburnbar.data.cloud.AndroidCloudVaultResolvedKey
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM coverage for the fan-out child mission write path in
 * CLIAgentMissionDispatcherSupport: each runtime token gets its own sealed
 * child mission payload (built by the extracted payload-input helper) plus an
 * initial queued event, all appended to the caller's write batch.
 */
class CLIAgentMissionDispatcherFanOutTest {
    private val vaultKey = AndroidCloudVaultResolvedKey(ByteArray(32) { it.toByte() }, "vault-key-test")

    private fun firestoreWith(requestDocument: DocumentReference): FirebaseFirestore {
        val requestsCollection = mockk<CollectionReference>(relaxed = true) {
            every { document(any()) } returns requestDocument
        }
        val userDocument = mockk<DocumentReference>(relaxed = true) {
            every { collection("cli_agent_mission_requests") } returns requestsCollection
        }
        val usersCollection = mockk<CollectionReference>(relaxed = true) {
            every { document("uid-1") } returns userDocument
        }
        return mockk<FirebaseFirestore>(relaxed = true) {
            every { collection("users") } returns usersCollection
        }
    }

    @Test
    fun `appendFanOutChildMissionWrites seals one child mission and queued event per runtime token`() {
        val runtimeTokens = listOf("codex", "claude")
        val plan = planFanOutDispatch(title = "  Compare runtimes  ", prompt = "  Fix the parser  ", runtimeTokens = runtimeTokens)
        val eventsDocument = mockk<DocumentReference>(relaxed = true)
        val eventsCollection = mockk<CollectionReference>(relaxed = true) {
            every { document("000001") } returns eventsDocument
        }
        val requestDocument = mockk<DocumentReference>(relaxed = true) {
            every { collection("events") } returns eventsCollection
        }
        val capturedPayloads = mutableListOf<Any>()
        val batch = mockk<WriteBatch>(relaxed = true)
        every { batch.set(any(), capture(capturedPayloads)) } returns batch
        val request = FanOutChildWriteRequest(
            batch = batch,
            firestore = firestoreWith(requestDocument),
            uid = "uid-1",
            plan = plan,
            runtimeTokens = runtimeTokens,
            missionKind = "chat",
            targetProject = "~/Developer/OpenBurnBar",
            depth = "standard",
            approvalMode = "existing_policy",
            commandsAllowed = true,
            fileEditsAllowed = false,
            requestedModelIDsByRuntime = emptyMap(),
            sourceSkillID = "fan_out",
            sourceSurface = "android-hermes-square",
            deliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
            parentHermesThreadID = "thread-1",
            key = vaultKey,
        )

        val signalWrites = appendFanOutChildMissionWrites(request)

        assertTrue("no Signal identity means the batch owns every write", signalWrites.isEmpty())
        assertEquals(4, capturedPayloads.size)

        val missionPayloads = capturedPayloads.filterIsInstance<Map<*, *>>().filter { it.containsKey("groupID") }
        assertEquals(2, missionPayloads.size)
        missionPayloads.forEachIndexed { index, payload ->
            assertEquals(plan.childMissionIDs[index], payload["id"])
            assertEquals(runtimeTokens[index], payload["requestedRuntime"])
            assertEquals(plan.groupID, payload["groupID"])
            assertEquals(index, payload["siblingIndex"])
            assertEquals(runtimeTokens.size, payload["siblingCount"])
            assertEquals(true, payload["isGroupChild"])
            assertEquals("fan_out", payload["sourceSkillID"])
            assertEquals("android-hermes-square", payload["sourceSurface"])
            assertEquals("thread-1", payload["parentHermesThreadID"])
            assertEquals(true, payload["contentSealed"])
            assertEquals(vaultKey.vaultKeyID, payload["vaultKeyID"])
            assertFalse("title is sealed into the private payload", payload.containsKey("title"))
            assertFalse("prompt is sealed into the private payload", payload.containsKey("prompt"))
        }

        val eventPayloads = capturedPayloads.filterIsInstance<Map<*, *>>().filter { it["kind"] == "status" }
        assertEquals(2, eventPayloads.size)
        eventPayloads.forEach { payload ->
            assertEquals(1, payload["sequence"])
            assertEquals("queued", payload["phase"])
            assertEquals(true, payload["contentSealed"])
            assertEquals(vaultKey.vaultKeyID, payload["vaultKeyID"])
        }
    }

    @Test
    fun `planFanOutDispatch trims inputs and mints one child mission id per runtime token`() {
        val plan = planFanOutDispatch(title = "   ", prompt = "  Inspect routing  ", runtimeTokens = listOf("codex", "claude", "gemini"))

        assertEquals("Fan-out mission", plan.trimmedTitle)
        assertEquals("Inspect routing", plan.trimmedPrompt)
        assertEquals(3, plan.childMissionIDs.size)
        assertEquals(3, plan.childMissionIDs.toSet().size)
        assertTrue(plan.groupID.startsWith("grp-"))
    }
}
