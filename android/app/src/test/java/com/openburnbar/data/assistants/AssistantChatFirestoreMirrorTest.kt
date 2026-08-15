package com.openburnbar.data.assistants

import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.AndroidCloudVaultResolvedKey
import com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads
import com.openburnbar.data.cloud.AndroidSignalIdentityKeyStore
import com.openburnbar.data.cloud.AndroidSignalIdentityKeypair
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.cloud.CloudVaultSealedPayload
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkAll
import java.util.Date
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Test

class AssistantChatFirestoreMirrorTest {
    @After
    fun tearDown() {
        unmockkAll()
    }

    @Test
    fun `required Signal write strips every legacy private field before Firestore set`() = runTest {
        val uid = "user-1"
        val thread = thread()
        val firestore = mockk<FirebaseFirestore>()
        val user =
            mockk<FirebaseUser> {
                every { this@mockk.uid } returns uid
            }
        val auth =
            mockk<FirebaseAuth> {
                every { currentUser } returns user
            }
        val chatDocument = chatDocument(firestore, uid, thread.id)
        var writtenPayload: Map<String, Any?>? = null
        every { chatDocument.set(any()) } answers {
            writtenPayload = firstArg<Map<String, Any?>>()
            Tasks.forResult(null)
        }

        val resolvedKey = AndroidCloudVaultResolvedKey(ByteArray(32) { 7 }, "vault-1")
        val sealedPayload = CloudVaultSealedPayload(vaultKeyID = resolvedKey.vaultKeyID, sealedBoxBase64 = "legacy")
        val escrow = mockk<AndroidCloudVaultDeviceKeypair>()
        val identity = mockk<AndroidSignalIdentityKeypair>()
        val signalEnvelope = mapOf<String, Any>("ciphertextLayer" to mapOf("ciphertext" to "signal"))

        mockkObject(AndroidCloudVaultKeyAccess)
        coEvery { AndroidCloudVaultKeyAccess.keyForWriting(uid, firestore) } returns resolvedKey
        mockkObject(CloudVaultCrypto)
        every { CloudVaultCrypto.sealPayload(any(), resolvedKey.keyData, resolvedKey.vaultKeyID, any()) } returns sealedPayload
        every { CloudVaultCrypto.sealedPayloadMap(sealedPayload) } returns mapOf("sealedBoxBase64" to "legacy")
        mockkObject(AndroidCloudVaultDeviceKeypair.Companion)
        every { AndroidCloudVaultDeviceKeypair.loadOrCreate() } returns escrow
        every { escrow.deviceId } returns "device-1"
        every { escrow.keyVersion } returns 1
        mockkObject(AndroidSignalIdentityKeyStore)
        every { AndroidSignalIdentityKeyStore.loadOrCreate("device-1", 1) } returns identity
        coEvery {
            AndroidSignalIdentityKeyStore.publishIfNeeded(
                uid = uid,
                deviceId = "device-1",
                identity = identity,
                firestore = firestore,
            )
        } returns Unit
        mockkObject(AndroidCloudVaultSignalPayloads)
        every {
            AndroidCloudVaultSignalPayloads.signalActivationState("conversations_chat")
        } returns AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED
        coEvery {
            AndroidCloudVaultSignalPayloads.atRestRecipients(
                uid = uid,
                firestore = firestore,
                localIdentity = identity,
            )
        } returns emptyList()
        every {
            AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(any())
        } returns signalEnvelope

        AssistantChatFirestoreMirror(firestore, auth).upsert(uid, thread)

        val written = requireNotNull(writtenPayload)
        assertSame(signalEnvelope, written["signalEnvelope"])
        assertEquals(thread.id, written["id"])
        LEGACY_PRIVATE_FIELDS.forEach { assertFalse(written.containsKey(it)) }
    }

    private fun chatDocument(firestore: FirebaseFirestore, uid: String, threadID: String): DocumentReference {
        val users = mockk<CollectionReference>()
        val user = mockk<DocumentReference>()
        val chats = mockk<CollectionReference>()
        val chat = mockk<DocumentReference>()
        every { firestore.collection("users") } returns users
        every { users.document(uid) } returns user
        every { user.collection("mobile_assistant_chats") } returns chats
        every { chats.document(threadID) } returns chat
        return chat
    }

    private fun thread(): AssistantChatThread {
        val now = Date().time
        return AssistantChatThread(
            id = "thread-1",
            runtime = "hermes",
            title = "Signal",
            preview = "Required write",
            createdAtMillis = now,
            updatedAtMillis = now,
            messages = listOf(
                AssistantChatMessage(
                    id = "message-1",
                    role = "assistant",
                    text = "sealed",
                    timestampMillis = now,
                ),
            ),
        )
    }

    private companion object {
        val LEGACY_PRIVATE_FIELDS = setOf("contentSealed", "sealedSchemaVersion", "vaultKeyID", "sealedPayload")
    }
}
