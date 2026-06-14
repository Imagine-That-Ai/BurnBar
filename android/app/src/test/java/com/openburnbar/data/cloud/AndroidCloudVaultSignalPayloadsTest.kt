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
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        }
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

    // T-AND-04 / T-CVS-02: the explicit per-user sender-set-complete marker replaces the old
    // `trustedSenderPublicKeys.size > 1` heuristic. `senderSetComplete` (the signal handed to the
    // fallback policy) must be true for an authoritative COMPLETE set AND for a transient
    // UNAVAILABLE read (fail closed), and false ONLY for a genuine INCOMPLETE rollout gap.
    @Test
    fun completeEnrollmentMarksSenderSetComplete() {
        val set =
            AndroidCloudVaultSignalPayloads.TrustedSenderSet(
                publicKeys = emptyMap(),
                enrollment = AndroidCloudVaultSignalPayloads.SenderSetEnrollment.COMPLETE,
            )
        assertTrue(set.senderSetComplete)
    }

    @Test
    fun transientUnavailableReadFailsClosed() {
        // A transient escrow read (UNAVAILABLE) must FAIL CLOSED — senderSetComplete = true — so an
        // unknown sender is not treated as legacy-eligible on a flaky read (the old size heuristic's
        // bug). A single-entry map (only the local identity) would have been size <= 1 == "not
        // complete" under the old rule; the explicit marker corrects that.
        val set =
            AndroidCloudVaultSignalPayloads.TrustedSenderSet(
                publicKeys = mapOf("local" to ByteArray(1)),
                enrollment = AndroidCloudVaultSignalPayloads.SenderSetEnrollment.UNAVAILABLE,
            )
        assertTrue(set.senderSetComplete)
    }

    @Test
    fun incompleteRolloutGapStaysLegacyEligible() {
        val set =
            AndroidCloudVaultSignalPayloads.TrustedSenderSet(
                publicKeys = mapOf("local" to ByteArray(1)),
                enrollment = AndroidCloudVaultSignalPayloads.SenderSetEnrollment.INCOMPLETE,
            )
        assertFalse(set.senderSetComplete)
    }

    @Test
    fun unknownSenderFailsClosedWhenSetIsComplete() {
        // Cross-check against the policy: an unknown sender is an attack ONCE the set is complete
        // (COMPLETE or fail-closed UNAVAILABLE), and a readiness gap while INCOMPLETE.
        val unknown = CloudVaultSignalSenderAuthException.SenderNotTrusted("peer-x")
        // INCOMPLETE -> legacy-eligible (rollout-lenient).
        assertTrue(SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(unknown, senderSetComplete = false))
        // COMPLETE / UNAVAILABLE -> fail closed.
        assertFalse(SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(unknown, senderSetComplete = true))
    }
}
