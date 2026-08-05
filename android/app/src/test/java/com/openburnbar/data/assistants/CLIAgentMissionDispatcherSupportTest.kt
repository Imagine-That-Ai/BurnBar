package com.openburnbar.data.assistants

import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.WriteBatch
import com.openburnbar.data.cloud.AndroidCloudVaultResolvedKey
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Covers the fan-out dispatch staging helpers: the sealed mission-group parent
 * payload and the per-runtime child mission writes staged on the Firestore batch.
 */
class CLIAgentMissionDispatcherSupportTest {
    private val key = AndroidCloudVaultResolvedKey(keyData = ByteArray(32) { 0x11 }, vaultKeyID = "vault-1")

    @Before
    fun mockAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            java.util.Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            java.util.Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun unmockAndroidBase64() {
        unmockkStatic(android.util.Base64::class)
    }

    @Test
    fun `sealed fan-out group payload strips plaintext and keeps group scaffolding`() {
        val plan = planFanOutDispatch("  Compare runtimes  ", "  Try every agent  ", listOf("codex", "claude"))

        val payload =
            sealedFanOutGroupPayload(
                plan = plan,
                missionKind = "insights",
                targetProject = "~/Developer/OpenBurnBar",
                runtimeTokens = listOf("codex", "claude"),
                parallelismLimit = null,
                mergeStrategy = "pick_one",
                key = key,
            )

        assertEquals(plan.groupID, payload["id"])
        assertEquals(plan.childMissionIDs, payload["childMissionIDs"])
        assertEquals(2, payload["parallelismLimit"])
        assertEquals("pick_one", payload["mergeStrategy"])
        assertEquals(true, payload["contentSealed"])
        assertEquals("vault-1", payload["vaultKeyID"])
        assertTrue(payload.containsKey("sealedPayload"))
        assertFalse(payload.containsKey("title"))
        assertFalse(payload.containsKey("prompt"))
    }

    @Test
    fun `append fan-out child mission writes stages sealed children and queued events on the batch`() {
        val staged = mutableListOf<Map<String, Any>>()
        val batch = mockk<WriteBatch>()
        every { batch.set(any(), any()) } answers {
            staged += secondArg<Map<String, Any>>()
            batch
        }
        val eventsDoc = mockk<DocumentReference>()
        val eventsCollection = mockk<CollectionReference> { every { document("000001") } returns eventsDoc }
        val missionDoc = mockk<DocumentReference> { every { collection("events") } returns eventsCollection }
        val missionsCollection = mockk<CollectionReference> { every { document(any<String>()) } returns missionDoc }
        val userDoc = mockk<DocumentReference> { every { collection("cli_agent_mission_requests") } returns missionsCollection }
        val usersCollection = mockk<CollectionReference> { every { document("uid-1") } returns userDoc }
        val firestore = mockk<FirebaseFirestore> { every { collection("users") } returns usersCollection }
        val plan = planFanOutDispatch("Compare runtimes", "Try every agent", listOf("codex", "claude"))

        val signalWrites =
            appendFanOutChildMissionWrites(
                FanOutChildWriteRequest(
                    batch = batch,
                    firestore = firestore,
                    uid = "uid-1",
                    plan = plan,
                    runtimeTokens = listOf("codex", "claude"),
                    missionKind = "insights",
                    targetProject = null,
                    depth = "standard",
                    approvalMode = "existing_policy",
                    commandsAllowed = false,
                    fileEditsAllowed = true,
                    requestedModelIDsByRuntime = emptyMap(),
                    sourceSkillID = "compare_agents",
                    sourceSurface = "android-hermes-square",
                    deliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
                    parentHermesThreadID = null,
                    key = key,
                ),
            )

        assertTrue(signalWrites.isEmpty())
        assertEquals(4, staged.size)
        val firstChild = staged[0]
        assertEquals(plan.childMissionIDs[0], firstChild["id"])
        assertEquals("codex", firstChild["requestedRuntime"])
        assertEquals(plan.groupID, firstChild["groupID"])
        assertEquals(0, firstChild["siblingIndex"])
        assertEquals(2, firstChild["siblingCount"])
        assertEquals(true, firstChild["isGroupChild"])
        assertEquals("compare_agents", firstChild["sourceSkillID"])
        assertEquals(true, firstChild["contentSealed"])
        assertFalse(firstChild.containsKey("prompt"))
        val firstEvent = staged[1]
        assertEquals("queued", firstEvent["phase"])
        assertEquals(true, firstEvent["contentSealed"])
        val secondChild = staged[2]
        assertEquals("claude", secondChild["requestedRuntime"])
        assertEquals(1, secondChild["siblingIndex"])
    }
}
