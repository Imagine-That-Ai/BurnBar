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
    fun `buildFanOutChildLeaves seals one child mission leaf per runtime token`() {
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

        val leaves = buildFanOutChildLeaves(request)

        assertEquals(2, leaves.size)
        leaves.forEachIndexed { index, leaf ->
            assertEquals(plan.childMissionIDs[index], leaf.requestId)
            assertEquals(runtimeTokens[index], leaf.publicFields["requestedRuntime"])
            assertEquals(plan.groupID, leaf.publicFields["groupID"])
            assertEquals(index, leaf.publicFields["siblingIndex"])
            assertEquals(runtimeTokens.size, leaf.publicFields["siblingCount"])
            assertEquals(true, leaf.publicFields["isGroupChild"])
            assertEquals("fan_out", leaf.publicFields["sourceSkillID"])
            assertEquals("android-hermes-square", leaf.publicFields["sourceSurface"])
            assertEquals("thread-1", leaf.publicFields["parentHermesThreadID"])
            assertFalse("title is not a public field", leaf.publicFields.containsKey("title"))
            assertFalse("prompt is not a public field", leaf.publicFields.containsKey("prompt"))
            assertTrue(leaf.sealedPayload.containsKey("vaultKeyID") || leaf.sealedPayload.isNotEmpty())
            val expectedRequestAad = com.openburnbar.data.cloud.CloudVaultAADContext(
                uid = "uid-1",
                collection = "cli_agent_mission_requests",
                docID = leaf.requestId,
                field = "sealedPayload",
            ).stringValue
            assertEquals(expectedRequestAad, leaf.sealedPayload["aad"])
            val expectedEventAad = com.openburnbar.data.cloud.CloudVaultAADContext(
                uid = "uid-1",
                collection = "cli_agent_mission_requests/events",
                docID = "${leaf.requestId}/000001",
                field = "sealedPayload",
            ).stringValue
            assertEquals(expectedEventAad, leaf.initialEvent["aad"])
        }
    }

    @Test
    fun `buildSealed create envelopes use path-bound AAD`() {
        val sealed = CLIAgentMissionRequestPayloadFactory.buildSealed(
            input = CLIAgentMissionRequestPayloadFactory.PayloadInput(
                core = CLIAgentMissionRequestPayloadFactory.Core(
                    id = "req-aad",
                    title = "T",
                    prompt = "P",
                    missionKind = "chat",
                ),
                execution = CLIAgentMissionRequestPayloadFactory.Execution(
                    requestedRuntime = "codex",
                    targetProject = null,
                    depth = "standard",
                    approvalMode = "existing_policy",
                    requestedModelID = null,
                ),
                permissions = CLIAgentMissionRequestPayloadFactory.Permissions(
                    commandsAllowed = false,
                    fileEditsAllowed = false,
                ),
            ),
            key = vaultKey,
            uid = "uid-1",
        )
        val payload = sealed["sealedPayload"] as Map<*, *>
        val expected = com.openburnbar.data.cloud.CloudVaultAADContext(
            uid = "uid-1",
            collection = "cli_agent_mission_requests",
            docID = "req-aad",
            field = "sealedPayload",
        ).stringValue
        assertEquals(expected, payload["aad"])
        val event = CLIAgentMissionRequestPayloadFactory.initialQueuedEventSealed(
            key = vaultKey,
            uid = "uid-1",
            requestID = "req-aad",
            eventID = "000001",
        )
        val eventPayload = event["sealedPayload"] as Map<*, *>
        val expectedEvent = com.openburnbar.data.cloud.CloudVaultAADContext(
            uid = "uid-1",
            collection = "cli_agent_mission_requests/events",
            docID = "req-aad/000001",
            field = "sealedPayload",
        ).stringValue
        assertEquals(expectedEvent, eventPayload["aad"])
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
