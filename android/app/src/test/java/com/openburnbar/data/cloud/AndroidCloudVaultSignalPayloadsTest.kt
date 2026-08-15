package com.openburnbar.data.cloud

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AndroidCloudVaultSignalPayloadsTest {
    @Test
    fun gateDefaultsOff() {
        AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = null
        // The Signal-scheme domain remains fail-closed until the activation provider is wired.
        assertFalse(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("conversations_chat"))
        assertFalse(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("pensieve"))
    }

    @Test
    fun remoteActivationMapsDisabledEnabledRequiredAndHardKill() {
        val state = AndroidCloudVaultSignalPayloads::remoteActivationState

        assertEquals(
            AndroidCloudVaultSignalPayloads.ActivationState.OFF,
            state(false, false, false, false),
        )
        assertEquals(
            AndroidCloudVaultSignalPayloads.ActivationState.OFF,
            state(true, true, false, true),
        )
        assertEquals(
            AndroidCloudVaultSignalPayloads.ActivationState.ENABLED,
            state(true, false, false, false),
        )
        assertEquals(
            AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED,
            state(true, true, false, false),
        )
        assertEquals(
            AndroidCloudVaultSignalPayloads.ActivationState.OFF,
            state(true, true, true, false),
        )
    }

    @Test
    fun overrideTogglesGatePerDomain() {
        try {
            AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = {
                if (it == "conversations_chat") {
                    AndroidCloudVaultSignalPayloads.ActivationState.ENABLED
                } else {
                    AndroidCloudVaultSignalPayloads.ActivationState.OFF
                }
            }
            assertTrue(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("conversations_chat"))
            assertFalse(AndroidCloudVaultSignalPayloads.signalSealingIsEnabled("session_logs"))
        } finally {
            AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = null
        }
    }

    @Test
    fun sealedEnvelopeRoundTripsForLocalAndPeerWhenEnabled() {
        AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = {
            AndroidCloudVaultSignalPayloads.ActivationState.ENABLED
        }
        try {
            val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
            val peer = AndroidSignalIdentityKeypair.generate("device-b", 1)
            val plaintext = "android signal at-rest payload".toByteArray()

            val map =
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    AndroidCloudVaultSignalPayloads.SignalEnvelopeMapRequest(
                        domainID = "conversations_chat",
                        uid = "user-1",
                        collection = "mobile_assistant_chats",
                        docId = "thread-1",
                        plaintext = plaintext,
                        localIdentity = local,
                        otherRecipients = listOf(peer.asRecipient()),
                    ),
                )
            assertNotNull(map)

            val envelope = requireNotNull(map)
            val data = mapOf<String, Any?>("signalEnvelope" to envelope)
            // The author (local device) is the sender; the peer pins it as a trusted sender.
            val trustedSenders = mapOf(local.identityKeyId to local.publicKeyData)
            // The local (self-authored) device verifies its own sender signature with no extra set.
            assertArrayEquals(
                plaintext,
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-1",
                    collection = "mobile_assistant_chats",
                    docId = "thread-1",
                    localIdentity = local,
                ),
            )
            // The trusted peer can open it too once it pins the author as a trusted sender.
            assertArrayEquals(
                plaintext,
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-1",
                    collection = "mobile_assistant_chats",
                    docId = "thread-1",
                    localIdentity = peer,
                    trustedSenderPublicKeys = trustedSenders,
                ),
            )
            // RR-7a: the same peer WITHOUT the author pinned rejects the envelope fail-closed
            // (an unrecognized sender) rather than accepting a potentially forged envelope.
            assertThrows(CloudVaultSignalSenderAuthException.SenderNotTrusted::class.java) {
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-1",
                    collection = "mobile_assistant_chats",
                    docId = "thread-1",
                    localIdentity = peer,
                )
            }
        } finally {
            AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = null
        }
    }

    @Test
    fun returnsNullEnvelopeWhenGateDisabled() {
        AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = {
            AndroidCloudVaultSignalPayloads.ActivationState.OFF
        }
        try {
            val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
            assertNull(
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    AndroidCloudVaultSignalPayloads.SignalEnvelopeMapRequest(
                        domainID = "conversations_chat",
                        uid = "u",
                        collection = "mobile_assistant_chats",
                        docId = "t",
                        plaintext = "x".toByteArray(),
                        localIdentity = local,
                        otherRecipients = emptyList(),
                    ),
                ),
            )
        } finally {
            AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = null
        }
    }

    @Test
    fun openRejectsRelocatedBinding() {
        AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = {
            AndroidCloudVaultSignalPayloads.ActivationState.ENABLED
        }
        try {
            val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
            val map =
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    AndroidCloudVaultSignalPayloads.SignalEnvelopeMapRequest(
                        domainID = "conversations_chat",
                        uid = "user-1",
                        collection = "mobile_assistant_chats",
                        docId = "thread-1",
                        plaintext = "secret".toByteArray(),
                        localIdentity = local,
                        otherRecipients = emptyList(),
                    ),
                ) ?: error("expected a Signal envelope")
            val data = mapOf<String, Any?>("signalEnvelope" to map)
            // A different docId is a relocation — the binding guard must reject it.
            assertThrows(IllegalArgumentException::class.java) {
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-1",
                    collection = "mobile_assistant_chats",
                    docId = "thread-2",
                    localIdentity = local,
                )
            }
        } finally {
            AndroidCloudVaultSignalPayloads.signalActivationOverrideProvider = null
        }
    }

    @Test
    fun requiredWriteKeepsOnlySignalPrivatePayload() = runTest {
        val payload = legacyPayload()
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = payload,
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = { SIGNAL_ENVELOPE },
            onOptionalSealFailure = { fail("required seal must not fall back") },
            writePayload = { writtenPayload = it.toMap() },
        )

        val written = requireNotNull(writtenPayload)
        assertSame(SIGNAL_ENVELOPE, written["signalEnvelope"])
        LEGACY_PRIVATE_FIELDS.forEach { assertFalse(written.containsKey(it)) }
        assertEquals("thread-1", written["id"])
    }

    @Test
    fun enabledWriteKeepsLegacyPayloadAlongsideSignalEnvelope() = runTest {
        val payload = legacyPayload()
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = payload,
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.ENABLED,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.ENABLED },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = { SIGNAL_ENVELOPE },
            onOptionalSealFailure = { fail("successful enabled seal must not fall back") },
            writePayload = { writtenPayload = it.toMap() },
        )

        val written = requireNotNull(writtenPayload)
        assertSame(SIGNAL_ENVELOPE, written["signalEnvelope"])
        assertTrue(written.containsKey("sealedPayload"))
        assertTrue(written.containsKey("contentSealed"))
    }

    @Test
    fun disabledWriteKeepsLegacyPayloadAndNeverSeals() = runTest {
        val payload =
            legacyPayload().apply {
                this["signalEnvelope"] = mapOf("ciphertextLayer" to mapOf("ciphertext" to "stale"))
            }
        var sealCalls = 0
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = payload,
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.OFF,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.OFF },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = {
                sealCalls += 1
                SIGNAL_ENVELOPE
            },
            onOptionalSealFailure = { fail("disabled mode must not attempt sealing") },
            writePayload = { writtenPayload = it.toMap() },
        )

        val written = requireNotNull(writtenPayload)
        assertEquals(0, sealCalls)
        assertFalse(written.containsKey("signalEnvelope"))
        assertTrue(written.containsKey("sealedPayload"))
    }

    @Test
    fun requiredWriteFailsClosedWhenSealingFailsAndNeverWrites() = runTest {
        val expected = IllegalArgumentException("seal failed")
        var writeCalls = 0

        try {
            AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
                payload = legacyPayload(),
                initialState = AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED,
                finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED },
                legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
                sealSignalEnvelope = { throw expected },
                onOptionalSealFailure = { fail("required seal failure must not fall back") },
                writePayload = { writeCalls += 1 },
            )
            fail("required seal failure must throw")
        } catch (error: IllegalArgumentException) {
            assertSame(expected, error)
        }
        assertEquals(0, writeCalls)
    }

    @Test
    fun enabledSealFailureFallsBackToLegacyWrite() = runTest {
        val expected = IllegalArgumentException("seal failed")
        var observedFailure: Throwable? = null
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = legacyPayload(),
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.ENABLED,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.ENABLED },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = { throw expected },
            onOptionalSealFailure = { observedFailure = it },
            writePayload = { writtenPayload = it.toMap() },
        )

        assertSame(expected, observedFailure)
        val written = requireNotNull(writtenPayload)
        assertFalse(written.containsKey("signalEnvelope"))
        assertTrue(written.containsKey("sealedPayload"))
    }

    @Test
    fun offToRequiredTransitionFailsClosedAndNeverWrites() = runTest {
        var writeCalls = 0

        try {
            AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
                payload = legacyPayload(),
                initialState = AndroidCloudVaultSignalPayloads.ActivationState.OFF,
                finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED },
                legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
                sealSignalEnvelope = { error("initial OFF mode must not seal") },
                onOptionalSealFailure = { fail("initial OFF mode must not seal") },
                writePayload = { writeCalls += 1 },
            )
            fail("OFF to REQUIRED transition must throw")
        } catch (_: IllegalStateException) {
        }
        assertEquals(0, writeCalls)
    }

    @Test
    fun enabledToRequiredTransitionStripsLegacyBeforeWrite() = runTest {
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = legacyPayload(),
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.ENABLED,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = { SIGNAL_ENVELOPE },
            onOptionalSealFailure = { fail("successful seal must not fall back") },
            writePayload = { writtenPayload = it.toMap() },
        )

        val written = requireNotNull(writtenPayload)
        assertSame(SIGNAL_ENVELOPE, written["signalEnvelope"])
        LEGACY_PRIVATE_FIELDS.forEach { assertFalse(written.containsKey(it)) }
    }

    @Test
    fun enabledSealFailureToRequiredTransitionFailsClosedAndNeverWrites() = runTest {
        val expected = IllegalArgumentException("seal failed")
        var writeCalls = 0

        try {
            AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
                payload = legacyPayload(),
                initialState = AndroidCloudVaultSignalPayloads.ActivationState.ENABLED,
                finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED },
                legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
                sealSignalEnvelope = { throw expected },
                onOptionalSealFailure = { fail("final REQUIRED mode must not fall back") },
                writePayload = { writeCalls += 1 },
            )
            fail("enabled seal failure followed by REQUIRED must throw")
        } catch (error: IllegalArgumentException) {
            assertSame(expected, error)
        }
        assertEquals(0, writeCalls)
    }

    @Test
    fun enabledToOffTransitionDropsSignalAndWritesLegacy() = runTest {
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = legacyPayload(),
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.ENABLED,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.OFF },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = { SIGNAL_ENVELOPE },
            onOptionalSealFailure = { fail("successful seal must not fail") },
            writePayload = { writtenPayload = it.toMap() },
        )

        val written = requireNotNull(writtenPayload)
        assertFalse(written.containsKey("signalEnvelope"))
        assertTrue(written.containsKey("sealedPayload"))
    }

    @Test
    fun requiredToOffTransitionHonorsHardKillAndWritesLegacy() = runTest {
        var writtenPayload: Map<String, Any?>? = null

        AndroidCloudVaultSignalPayloads.writePayloadWithSignalPolicy(
            payload = legacyPayload(),
            initialState = AndroidCloudVaultSignalPayloads.ActivationState.REQUIRED,
            finalStateProvider = { AndroidCloudVaultSignalPayloads.ActivationState.OFF },
            legacyPrivateFields = LEGACY_PRIVATE_FIELDS,
            sealSignalEnvelope = { SIGNAL_ENVELOPE },
            onOptionalSealFailure = { fail("successful seal must not fail") },
            writePayload = { writtenPayload = it.toMap() },
        )

        val written = requireNotNull(writtenPayload)
        assertFalse(written.containsKey("signalEnvelope"))
        assertTrue(written.containsKey("sealedPayload"))
    }

    @Test
    fun openReturnsNullWhenNoEnvelopePresent() {
        val local = AndroidSignalIdentityKeypair.generate("device-a", 1)
        assertNull(
            AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                emptyMap(),
                uid = "u",
                collection = "c",
                docId = "d",
                localIdentity = local,
            ),
        )
    }

    private fun legacyPayload(): MutableMap<String, Any?> = mutableMapOf(
        "id" to "thread-1",
        "contentSealed" to true,
        "sealedSchemaVersion" to 2,
        "vaultKeyID" to "vault-1",
        "sealedPayload" to mapOf("ciphertext" to "legacy"),
    )

    private companion object {
        val LEGACY_PRIVATE_FIELDS = setOf("contentSealed", "sealedSchemaVersion", "vaultKeyID", "sealedPayload")
        val SIGNAL_ENVELOPE = mapOf<String, Any>("ciphertextLayer" to mapOf("ciphertext" to "signal"))
    }
}
