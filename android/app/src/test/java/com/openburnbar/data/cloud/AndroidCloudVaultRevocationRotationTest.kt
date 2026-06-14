package com.openburnbar.data.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * RR-5 — pure rotation-requirement parsing + survivor-eligibility, the Android mirror of Swift
 * `ComputerUseSecurityCallableClient.parsePendingRequirements` / `eligibleRequirements`. These run
 * without Firebase so the rotation field decoding is locked by a unit test (the full chain is
 * build-gated / device-bound — it talks to live callables + Firestore).
 */
class AndroidCloudVaultRevocationRotationTest {
    @Test
    fun listPendingCallablePayloadIncludesCallerDeviceId() {
        val payload = AndroidCloudVaultRevocationRotation.listPendingCallablePayload("  dev-a  ")
        assertEquals("dev-a", payload["callerDeviceId"])
    }

    @Test
    fun parsePendingRequirementsAcceptsRequirementIdOrId() {
        val raw =
            listOf(
                mapOf("requirementId" to "req-1", "survivorDeviceIds" to listOf("dev-a", "dev-b")),
                mapOf("id" to "req-2", "survivorDeviceIds" to listOf(" dev-c ", "")),
                mapOf("survivorDeviceIds" to listOf("dev-x")), // no id => dropped
                mapOf("requirementId" to "", "survivorDeviceIds" to listOf("dev-y")), // empty id => dropped
            )

        val parsed = AndroidCloudVaultRevocationRotation.parsePendingRequirements(raw)

        assertEquals(2, parsed.size)
        assertEquals("req-1", parsed[0].requirementId)
        assertEquals(listOf("dev-a", "dev-b"), parsed[0].survivorDeviceIds)
        // `id` alias is accepted; survivor ids are trimmed and blanks filtered.
        assertEquals("req-2", parsed[1].requirementId)
        assertEquals(listOf("dev-c"), parsed[1].survivorDeviceIds)
    }

    @Test
    fun eligibleRequirementsKeepsOnlySurvivorRequirements() {
        val requirements =
            listOf(
                AndroidCloudVaultRevocationRotation.PendingRequirement("req-1", listOf("dev-a", "dev-b")),
                AndroidCloudVaultRevocationRotation.PendingRequirement("req-2", listOf("dev-c")),
                AndroidCloudVaultRevocationRotation.PendingRequirement("req-3", listOf("dev-a")),
            )

        val eligible = AndroidCloudVaultRevocationRotation.eligibleRequirements(requirements, rotatingDeviceId = "dev-a")

        assertEquals(listOf("req-1", "req-3"), eligible)
    }

    @Test
    fun eligibleRequirementsDeduplicatesAndDropsAlreadyActioned() {
        val requirements =
            listOf(
                AndroidCloudVaultRevocationRotation.PendingRequirement("req-1", listOf("dev-a")),
                AndroidCloudVaultRevocationRotation.PendingRequirement("req-1", listOf("dev-a")), // repeat
                AndroidCloudVaultRevocationRotation.PendingRequirement("req-2", listOf("dev-a")),
            )

        val eligible =
            AndroidCloudVaultRevocationRotation.eligibleRequirements(
                requirements,
                rotatingDeviceId = "dev-a",
                alreadyActioned = setOf("req-2"),
            )

        // req-1 once (deduped), req-2 dropped (already actioned).
        assertEquals(listOf("req-1"), eligible)
    }

    @Test
    fun eligibleRequirementsEmptyForBlankRotatingDevice() {
        val requirements = listOf(AndroidCloudVaultRevocationRotation.PendingRequirement("req-1", listOf("dev-a")))
        assertTrue(AndroidCloudVaultRevocationRotation.eligibleRequirements(requirements, rotatingDeviceId = "   ").isEmpty())
    }

    @Test
    fun wrapVaultKeyRoundTripsThroughUnwrap() {
        // RR-5 rotation wraps the next key to each survivor's escrow public key; that wrap must open
        // with the matching private key (the inverse unwrapVaultKey), so the survivor can read it.
        val generator = java.security.KeyPairGenerator.getInstance("EC")
        generator.initialize(java.security.spec.ECGenParameterSpec("secp256r1"))
        val recipient = generator.generateKeyPair()
        val recipientPublicX963 = CloudVaultCrypto.publicKeyX963(recipient.public)
        val key = CloudVaultCrypto.generateVaultKey()

        val wrapped = CloudVaultCrypto.wrapVaultKey(key, recipientPublicX963)
        val unwrapped = CloudVaultCrypto.unwrapVaultKey(wrapped, recipient.private)

        assertEquals(32, key.size)
        org.junit.Assert.assertArrayEquals(key, unwrapped)
    }
}
