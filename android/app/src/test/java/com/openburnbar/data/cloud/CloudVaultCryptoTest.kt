package com.openburnbar.data.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class CloudVaultCryptoTest {
    @Test
    fun semanticHashesAreDeterministicKeyedAndUsefulForRecall() {
        val key = ByteArray(32) { 0x33.toByte() }
        val otherKey = ByteArray(32) { 0x44.toByte() }
        val indexed = "Hosted encrypted session logs with semantic search and cloud vault sync"
        val related = "Find searchable cloud sessions that were encrypted and hosted"
        val unrelated = "Espresso roast tasting notes and ceramic mugs"

        val first = CloudVaultCrypto.semanticHashes(indexed, key)
        val second = CloudVaultCrypto.semanticHashes(indexed, key)
        val other = CloudVaultCrypto.semanticHashes(indexed, otherKey)
        val relatedHashes = CloudVaultCrypto.semanticHashes(related, key)
        val unrelatedHashes = CloudVaultCrypto.semanticHashes(unrelated, key)

        assertEquals(first, second)
        assertNotEquals(first, other)
        assertTrue(first.size <= 24)
        assertEquals(first.size, first.toSet().size)
        assertTrue(first.all { Regex("^[a-f0-9]{32}$").matches(it) })
        assertFalse(first.contains("encrypted"))
        assertTrue(first.toSet().intersect(relatedHashes.toSet()).isNotEmpty())
        assertTrue(first.toSet().intersect(relatedHashes.toSet()).size >= first.toSet().intersect(unrelatedHashes.toSet()).size)
    }

    @Test
    fun unwrapVaultKeyAcceptsSwiftStyleEmptySaltHkdf() {
        val recipient = p256KeyPair()
        val ephemeral = p256KeyPair()
        val vaultKey = ByteArray(32) { it.toByte() }
        val wrapped = wrapVaultKeyForTest(vaultKey, recipient, ephemeral)

        val unwrapped = CloudVaultCrypto.unwrapVaultKey(wrapped, recipient.private)

        assertArrayEquals(vaultKey, unwrapped)
    }

    private fun wrapVaultKeyForTest(vaultKey: ByteArray, recipient: KeyPair, ephemeral: KeyPair): ByteArray {
        val sharedSecret = KeyAgreement.getInstance("ECDH").run {
            init(ephemeral.private)
            doPhase(recipient.public, true)
            generateSecret()
        }
        val wrappingKey = hkdfSha256(
            input = sharedSecret,
            salt = ByteArray(0),
            info = "OpenBurnBar-Escrow-v1".toByteArray(),
            length = 32
        )
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(wrappingKey, "AES"))
        return CloudVaultCrypto.publicKeyX963(ephemeral.public) + cipher.iv + cipher.doFinal(vaultKey)
    }

    private fun p256KeyPair(): KeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        return generator.generateKeyPair()
    }

    private fun hkdfSha256(input: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val extractMac = Mac.getInstance("HmacSHA256")
        extractMac.init(SecretKeySpec(effectiveSalt, "HmacSHA256"))
        val prk = extractMac.doFinal(input)
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            val expandMac = Mac.getInstance("HmacSHA256")
            expandMac.init(SecretKeySpec(prk, "HmacSHA256"))
            expandMac.update(previous)
            expandMac.update(info)
            expandMac.update(counter.toByte())
            previous = expandMac.doFinal()
            val copy = minOf(previous.size, length - written)
            System.arraycopy(previous, 0, output, written, copy)
            written += copy
            counter += 1
        }
        return output
    }
}
