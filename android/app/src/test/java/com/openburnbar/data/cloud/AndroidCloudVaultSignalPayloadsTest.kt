package com.openburnbar.data.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidCloudVaultSignalPayloadsTest {
    @Test
    fun gateDefaultsOff() {
        AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        // No production domain has the signal sealingScheme, so the gate is fail-closed.
        assertFalse(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("conversations_chat"))
        assertFalse(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("pensieve"))
    }

    @Test
    fun overrideTogglesGatePerDomain() {
        try {
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = { it == "conversations_chat" }
            assertTrue(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("conversations_chat"))
            assertFalse(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("session_logs"))
        } finally {
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        }
    }

    @Test
    fun sealedEnvelopeRoundTripsForLocalAndPeerWhenEnabled() {
        AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = { true }
        try {
            val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
            val peer = AndroidSignalIdentityKeypair.generate("device-b", 1)
            val plaintext = "android signal at-rest payload".toByteArray()

            val map =
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    domainID = "conversations_chat",
                    uid = "user-1",
                    collection = "mobile_assistant_chats",
                    docId = "thread-1",
                    plaintext = plaintext,
                    localIdentity = local,
                    otherRecipients = listOf(peer.asRecipient()),
                )
            assertNotNull(map)

            val data = mapOf<String, Any?>("signalEnvelope" to map!!)
            // Both the local device and the trusted peer can open it.
            assertArrayEquals(
                plaintext,
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data, uid = "user-1", collection = "mobile_assistant_chats", docId = "thread-1", localIdentity = local,
                ),
            )
            assertArrayEquals(
                plaintext,
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data, uid = "user-1", collection = "mobile_assistant_chats", docId = "thread-1", localIdentity = peer,
                ),
            )
        } finally {
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        }
    }

    @Test
    fun returnsNullEnvelopeWhenGateDisabled() {
        AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = { false }
        try {
            val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
            assertNull(
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    domainID = "conversations_chat",
                    uid = "u",
                    collection = "mobile_assistant_chats",
                    docId = "t",
                    plaintext = "x".toByteArray(),
                    localIdentity = local,
                    otherRecipients = emptyList(),
                ),
            )
        } finally {
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        }
    }

    @Test
    fun openRejectsRelocatedBinding() {
        AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = { true }
        try {
            val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
            val map =
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    domainID = "conversations_chat",
                    uid = "user-1",
                    collection = "mobile_assistant_chats",
                    docId = "thread-1",
                    plaintext = "secret".toByteArray(),
                    localIdentity = local,
                    otherRecipients = emptyList(),
                )!!
            val data = mapOf<String, Any?>("signalEnvelope" to map)
            // A different docId is a relocation — the binding guard must reject it.
            assertThrows(IllegalArgumentException::class.java) {
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data, uid = "user-1", collection = "mobile_assistant_chats", docId = "thread-2", localIdentity = local,
                )
            }
        } finally {
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        }
    }

    @Test
    fun openReturnsNullWhenNoEnvelopePresent() {
        val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
        assertNull(
            AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                emptyMap(), uid = "u", collection = "c", docId = "d", localIdentity = local,
            ),
        )
    }
}
