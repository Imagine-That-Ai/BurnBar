package com.openburnbar.data.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2.5 G3 — cross-device at-rest fan-out + revoke fail-closed matrix (Android mirror of
 * Swift `SignalAtRestSealerTests.testCrossDeviceFanOutAndRevokeFailClosedMatrix`).
 *
 * One envelope sealed for a multi-device recipient list must open on EVERY listed device, while
 * a device dropped from the list (revoked/removed) and a foreign-account device both fail closed.
 * deviceA is pinned as the trusted sender in every case so the negative under test is the WRAP /
 * key-binding negative, not a sender-auth negative (sender-auth is verified before wrap lookup).
 *
 * Platform asymmetry vs iOS: Android has no typed `recipientPrivateKeyMismatch` guard — a missing
 * wrap surfaces as `IllegalStateException("Missing Signal recipient wrap")`, and a wrong private
 * key for a present wrap surfaces as the libsignal HPKE open failure. iOS additionally distinguishes
 * `recipientPrivateKeyMismatch`; both platforms fail closed.
 */
class CloudVaultSignalFanOutTest {
    private val binding =
        CloudVaultSignalBinding(uid = "uid-1", collection = "pensieve", docId = "doc-fanout", field = "body")

    private val deviceA = AndroidSignalIdentityKeypair.generate("deviceA", 1)
    private val deviceB = AndroidSignalIdentityKeypair.generate("deviceB", 1)
    private val escrow = AndroidSignalIdentityKeypair.generate("escrow", 1)
    private val recovery = AndroidSignalIdentityKeypair.generate("recovery", 1)

    // The full device list: two user devices, an escrow recipient, a recovery recipient.
    private fun fanOutRecipients() =
        listOf(
            deviceA.asRecipient(),
            deviceB.asRecipient(),
            CloudVaultSignalRecipient("escrow", escrow.identityKeyId, escrow.publicKeyData),
            CloudVaultSignalRecipient("recovery", recovery.identityKeyId, recovery.publicKeyData),
        )

    private fun seal(recipients: List<CloudVaultSignalRecipient>): CloudVaultSignalEnvelope =
        CloudVaultCrypto.sealSignalPayload(
            "cross-device fan-out payload".toByteArray(),
            recipients = recipients,
            binding = binding,
            senderIdentityKeyId = deviceA.identityKeyId,
            senderIdentityPrivateKey = deviceA.privateKeyData,
            senderIdentityPublicKey = deviceA.publicKeyData,
        )

    private val trusted = mapOf(deviceA.identityKeyId to deviceA.publicKeyData)

    @Test
    fun fanOutSealsEveryRecipientAndEachOpens() {
        val plaintext = "cross-device fan-out payload".toByteArray()
        val envelope = seal(fanOutRecipients())

        // One wrap per listed recipient, and EVERY listed recipient opens the SAME envelope.
        assertEquals(4, envelope.keyDelivery.wraps.size)
        val devices =
            listOf(
                Triple(deviceA.identityKeyId, deviceA.privateKeyData, "deviceA"),
                Triple(deviceB.identityKeyId, deviceB.privateKeyData, "deviceB"),
                Triple(escrow.identityKeyId, escrow.privateKeyData, "escrow"),
                Triple(recovery.identityKeyId, recovery.privateKeyData, "recovery"),
            )
        for ((id, privateKey, label) in devices) {
            assertArrayEquals(
                "listed recipient $label must open the fan-out envelope",
                plaintext,
                CloudVaultCrypto.openSignalPayload(envelope, id, privateKey, binding, trusted),
            )
        }
    }

    @Test
    fun revokedDeviceWrapIsAbsentAndFailsClosed() {
        // Re-seal the SAME payload with deviceB dropped from the list (revoked/removed).
        val afterRevoke = seal(fanOutRecipients().filter { it.recipientIdentityKeyId != deviceB.identityKeyId })

        assertEquals(3, afterRevoke.keyDelivery.wraps.size)
        assertTrue(
            "the revoked device's wrap must be absent from the re-sealed envelope",
            afterRevoke.keyDelivery.wraps.none { it.recipientIdentityKeyId == deviceB.identityKeyId },
        )
        val error =
            assertThrows(IllegalStateException::class.java) {
                CloudVaultCrypto.openSignalPayload(
                    afterRevoke,
                    deviceB.identityKeyId,
                    deviceB.privateKeyData,
                    binding,
                    trusted,
                )
            }
        assertEquals("Missing Signal recipient wrap", error.message)

        // The surviving devices still open the post-revocation envelope.
        assertArrayEquals(
            "cross-device fan-out payload".toByteArray(),
            CloudVaultCrypto.openSignalPayload(afterRevoke, deviceA.identityKeyId, deviceA.privateKeyData, binding, trusted),
        )
    }

    @Test
    fun foreignDeviceWithNoWrapFailsClosed() {
        val foreign = AndroidSignalIdentityKeypair.generate("foreign", 1)
        val envelope = seal(fanOutRecipients())
        // A foreign-account device is not on the list, so it has no wrap: open fails closed.
        val error =
            assertThrows(IllegalStateException::class.java) {
                CloudVaultCrypto.openSignalPayload(
                    envelope,
                    foreign.identityKeyId,
                    foreign.privateKeyData,
                    binding,
                    trusted,
                )
            }
        assertEquals("Missing Signal recipient wrap", error.message)
    }

    @Test
    fun foreignPrivateKeyForListedIdFailsClosed() {
        val foreign = AndroidSignalIdentityKeypair.generate("foreign", 1)
        val envelope = seal(fanOutRecipients())
        // Claiming a LISTED id ("deviceB_1") with the wrong (foreign) private key: the wrap IS
        // found (deviceB is a recipient) and the sender (deviceA) is pinned/trusted, so neither the
        // missing-wrap path nor sender-auth can trip — the failure must be the libsignal HPKE open
        // rejecting the wrong recipient private key (Android has no typed key-binding guard).
        val error =
            assertThrows(Exception::class.java) {
                CloudVaultCrypto.openSignalPayload(
                    envelope,
                    deviceB.identityKeyId,
                    foreign.privateKeyData,
                    binding,
                    trusted,
                )
            }
        // Pin the mechanism: NOT a sender-auth failure and NOT the missing-wrap path.
        assertFalse(
            "must fail at the HPKE open, not sender-auth",
            error is CloudVaultSignalSenderAuthException,
        )
        assertNotEquals(
            "must reach the HPKE open, not the missing-wrap path",
            "Missing Signal recipient wrap",
            error.message,
        )
    }
}
