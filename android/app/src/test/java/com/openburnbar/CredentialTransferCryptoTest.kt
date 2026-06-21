package com.openburnbar

import com.openburnbar.data.stores.CredentialTransferCrypto
import javax.crypto.AEADBadTagException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CredentialTransferCryptoTest {
    @Test
    fun `v2 token format separates public handle from device secret`() {
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val token = CredentialTransferCrypto.formatTransferToken(transferId, secret)
        val parsed = CredentialTransferCrypto.parseTransferToken(token)

        assertTrue(transferId.startsWith("ct_"))
        assertTrue(CredentialTransferCrypto.isValidTransferId(transferId))
        assertTrue(CredentialTransferCrypto.isValidTransferSecret(secret))
        assertNotEquals(transferId, secret)
        assertTrue(token.startsWith("obbct_v2.ct_"))
        assertEquals(transferId, parsed.transferId)
        assertEquals(secret, parsed.secret)
    }

    @Test
    fun `pasted v2 tokens accept spacing only inside the secret half`() {
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val groupedSecret = secret.chunked(4).joinToString(" ")
        val parsed = CredentialTransferCrypto.parseTransferToken("obbct_v2.$transferId.$groupedSecret")

        assertEquals(transferId, parsed.transferId)
        assertEquals(secret, parsed.secret)
    }

    @Test
    fun `legacy twelve character code-only input is rejected`() {
        try {
            CredentialTransferCrypto.parseTransferToken("ABCDEFGHJKM2")
            fail("legacy transfer code should be rejected")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message?.contains("Legacy") == true)
        }
    }

    @Test
    fun `encrypted payload round trips with matching secret and aad`() {
        val plaintext = """{"provider":"openrouter","token":"secret"}"""
        val ownerUid = "uid-123"
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()

        val encrypted = CredentialTransferCrypto.encryptPayload(plaintext, secret, ownerUid, transferId)
        val decrypted = CredentialTransferCrypto.decryptPayload(encrypted, secret, ownerUid, transferId)

        assertTrue(encrypted.startsWith("v2."))
        assertEquals(4, encrypted.split(".").size)
        assertFalse(encrypted.contains("secret"))
        assertEquals(plaintext, decrypted)
    }

    @Test
    fun `same payload and secret produce different envelopes`() {
        val plaintext = """{"fixture":"redacted-value"}"""
        val ownerUid = "uid-123"
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()

        val first = CredentialTransferCrypto.encryptPayload(plaintext, secret, ownerUid, transferId)
        val second = CredentialTransferCrypto.encryptPayload(plaintext, secret, ownerUid, transferId)

        assertNotEquals(first, second)
        assertEquals(plaintext, CredentialTransferCrypto.decryptPayload(first, secret, ownerUid, transferId))
        assertEquals(plaintext, CredentialTransferCrypto.decryptPayload(second, secret, ownerUid, transferId))
    }

    @Test(expected = AEADBadTagException::class)
    fun `wrong secret cannot decrypt payload`() {
        val transferId = CredentialTransferCrypto.generateTransferId()
        val encrypted = CredentialTransferCrypto.encryptPayload(
            plaintext = "fixture payload",
            secret = CredentialTransferCrypto.generateTransferSecret(),
            ownerUid = "uid-123",
            transferId = transferId,
        )

        CredentialTransferCrypto.decryptPayload(
            ciphertext = encrypted,
            secret = CredentialTransferCrypto.generateTransferSecret(),
            ownerUid = "uid-123",
            transferId = transferId,
        )
    }

    @Test(expected = AEADBadTagException::class)
    fun `wrong transfer handle fails aad authentication`() {
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val encrypted = CredentialTransferCrypto.encryptPayload(
            plaintext = "fixture payload",
            secret = secret,
            ownerUid = "uid-123",
            transferId = CredentialTransferCrypto.generateTransferId(),
        )

        CredentialTransferCrypto.decryptPayload(
            ciphertext = encrypted,
            secret = secret,
            ownerUid = "uid-123",
            transferId = CredentialTransferCrypto.generateTransferId(),
        )
    }

    @Test(expected = AEADBadTagException::class)
    fun `tampered ciphertext fails authentication`() {
        val transferId = CredentialTransferCrypto.generateTransferId()
        val secret = CredentialTransferCrypto.generateTransferSecret()
        val encrypted = CredentialTransferCrypto.encryptPayload("fixture payload", secret, "uid-123", transferId)
        val parts = encrypted.split(".").toMutableList()
        val replacement = if (parts[3].first() == 'A') "B" else "A"
        parts[3] = replacement + parts[3].drop(1)

        CredentialTransferCrypto.decryptPayload(parts.joinToString("."), secret, "uid-123", transferId)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `malformed transfer envelope is rejected`() {
        CredentialTransferCrypto.decryptPayload(
            ciphertext = "not-an-envelope",
            secret = CredentialTransferCrypto.generateTransferSecret(),
            ownerUid = "uid-123",
            transferId = CredentialTransferCrypto.generateTransferId(),
        )
    }
}
