package com.openburnbar.data.stores

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialTransferStoreSecurityTest {

    @Test
    fun testPublicHandlesVaryAcrossCalls() {
        val handles = (1..20).map { CredentialTransferCrypto.generateTransferId() }

        assertEquals("All handles should be unique across 20 calls", 20, handles.toSet().size)
        assertTrue(handles.all { it.startsWith("ct_") })
    }

    @Test
    fun testDeviceSecretsUseHumanSafeAlphabetWithAtLeast128Bits() {
        val allowedChars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".toSet()
        repeat(5) {
            val secret = CredentialTransferCrypto.generateTransferSecret()
            assertEquals("Secret must be 26 base32 characters", 26, secret.length)
            assertTrue(
                "Secret '$secret' contains disallowed characters",
                secret.all { it in allowedChars },
            )
        }
    }

    @Test
    fun testTokenKeepsHandleAndSecretDisjoint() {
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val token = CredentialTransferCrypto.formatTransferToken(transferId, secret)
        val parsed = CredentialTransferCrypto.parseTransferToken(token)

        assertEquals(transferId, parsed.transferId)
        assertEquals(secret, parsed.secret)
        assertNotEquals(parsed.transferId, parsed.secret)
    }

    @Test
    fun testCallableCreatePayloadCarriesNoDeviceSecret() {
        val ownerUid = "uid-123"
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val encryptedPayload = CredentialTransferCrypto.encryptPayload(
            plaintext = """{"apiKey":"fixture-provider-token","provider":"openai"}""",
            secret = secret,
            ownerUid = ownerUid,
            transferId = transferId,
        )

        val payload = CredentialTransferCrypto.createTransferCallablePayload(transferId, encryptedPayload)
        val serialized = payload.toString()

        assertEquals(transferId, payload["transferId"])
        assertEquals(encryptedPayload, payload["payload"])
        assertFalse("Callable payload must not include the device secret", serialized.contains(secret))
        assertFalse("Callable payload must not include a legacy lookup field", payload.containsKey("code"))
    }

    @Test
    fun testConsumeCompleteAndCancelPayloadsCarryOnlyHandleAndClaim() {
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val parsed = CredentialTransferCrypto.parseTransferToken(
            CredentialTransferCrypto.formatTransferToken(transferId, secret),
        )
        val consumePayload = CredentialTransferCrypto.consumeTransferCallablePayload(parsed)
        val resolutionPayload = CredentialTransferCrypto.claimResolutionCallablePayload(
            transferId,
            "11111111-1111-4111-8111-111111111111",
        )
        val syntheticPath = "credential_transfers/${parsed.transferId}"

        assertEquals(mapOf("transferId" to transferId), consumePayload)
        assertFalse(consumePayload.toString().contains(secret))
        assertFalse(resolutionPayload.toString().contains(secret))
        assertFalse("Firestore path must be handle-only", syntheticPath.contains(secret))
    }

    @Test
    fun testLargeUnicodePayloadIsCiphertextOnlyAndRoundTrips() {
        val ownerUid = "uid-123"
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val plaintext = """{"name":"日本語テスト","emoji":"🔑🚀","blob":"${"x".repeat(50_000)}"}"""

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, secret, ownerUid, transferId)
        val decrypted = CredentialTransferCrypto.decryptPayload(ciphertext, secret, ownerUid, transferId)

        assertEquals(plaintext, decrypted)
        assertTrue(ciphertext.startsWith("v2."))
        assertFalse(ciphertext.contains("日本語"))
        assertFalse(ciphertext.contains("fixture-provider-token"))
    }
}
