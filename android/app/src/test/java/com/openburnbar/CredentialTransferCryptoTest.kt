@file:Suppress("FunctionNaming", "MagicNumber")

package com.openburnbar

import com.openburnbar.data.stores.CredentialTransferCrypto
import javax.crypto.AEADBadTagException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialTransferCryptoTest {
    @Test
    fun `transfer codes are long random human-safe tokens`() {
        val code = CredentialTransferCrypto.generateTransferCode()

        assertEquals(12, code.length)
        assertTrue(code.all { it in "ABCDEFGHJKMNPQRSTUVWXYZ23456789" })
    }

    @Test
    fun `pasted transfer codes normalize before validation`() {
        val normalized = CredentialTransferCrypto.normalizeTransferCode(" abcd-efgh jkm2 ")

        assertEquals("ABCDEFGHJKM2", normalized)
        assertTrue(CredentialTransferCrypto.isValidTransferCode(normalized))
        assertFalse(CredentialTransferCrypto.isValidTransferCode("ABCDEFGHJKM/"))
    }

    @Test
    fun `encrypted payload round trips with matching code`() {
        val plaintext = """{"provider":"openrouter","token":"secret"}"""
        val code = CredentialTransferCrypto.generateTransferCode()

        val encrypted = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val decrypted = CredentialTransferCrypto.decryptPayload(encrypted, code)

        assertTrue(encrypted.startsWith("v1."))
        assertEquals(4, encrypted.split(".").size)
        assertFalse(encrypted.contains("secret"))
        assertEquals(plaintext, decrypted)
    }

    @Test
    fun `same payload and code produce different envelopes`() {
        val plaintext = """{"fixture":"redacted-value"}"""
        val code = CredentialTransferCrypto.generateTransferCode()

        val first = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val second = CredentialTransferCrypto.encryptPayload(plaintext, code)

        assertNotEquals(first, second)
    }

    @Test(expected = AEADBadTagException::class)
    fun `wrong transfer code cannot decrypt payload`() {
        val encrypted = CredentialTransferCrypto.encryptPayload("fixture payload", "ABCDEFGHJKM2")

        CredentialTransferCrypto.decryptPayload(encrypted, "ABCDEFGHJKM3")
    }

    @Test(expected = IllegalArgumentException::class)
    fun `malformed transfer envelope is rejected`() {
        CredentialTransferCrypto.decryptPayload("not-an-envelope", "ABCDEFGHJKM2")
    }
}
