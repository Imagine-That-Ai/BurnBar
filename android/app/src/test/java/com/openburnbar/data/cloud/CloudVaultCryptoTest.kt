package com.openburnbar.data.cloud

import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private const val SHA256_DIGEST_BYTES = 32
private const val VAL_24 = 24

class CloudVaultCryptoTest {
    @Test
    fun sealedPayloadV2BindsEnvelopeMetadataWithAadAndReadsLegacyV1() {
        val key = ByteArray(SHA256_DIGEST_BYTES) { 0x5A.toByte() }
        val payload = """{"private":"gateway notes"}""".toByteArray()
        val vaultKeyID = CloudVaultCrypto.vaultKeyID(key)

        val sealed = CloudVaultCrypto.sealPayload(payload, key, vaultKeyID)

        assertEquals(CloudVaultCrypto.currentSealedPayloadSchemaVersion, sealed.schemaVersion)
        assertEquals("OpenBurnBar-CloudVaultSealedPayload-v2", sealed.aad)
        assertArrayEquals(payload, CloudVaultCrypto.openPayload(sealed, key))
        assertTrue(CloudVaultCrypto.sealedPayloadMap(sealed).containsKey("aad"))

        val tampered = sealed.copy(keyVersion = sealed.keyVersion + 1)
        assertTrue(runCatching { CloudVaultCrypto.openPayload(tampered, key) }.isFailure)

        val legacy = legacySealedPayloadForTest(payload, key, vaultKeyID)
        assertEquals(1, legacy.schemaVersion)
        assertArrayEquals(payload, CloudVaultCrypto.openPayload(legacy, key))
    }

    @Test
    fun blobEnvelopeV2UsesVaultKeyedHmacAndReadsLegacyV1() {
        val key = ByteArray(SHA256_DIGEST_BYTES) { 0x42.toByte() }
        val otherKey = ByteArray(SHA256_DIGEST_BYTES) { 0x24.toByte() }
        val plaintext = "full encrypted session markdown".toByteArray()
        val sealedBox = aesGcmCombined(plaintext, key)
        val envelope =
            CloudVaultBlobEnvelope(
                schemaVersion = CloudVaultCrypto.currentBlobEnvelopeSchemaVersion,
                keyVersion = 1,
                plaintextHMAC = CloudVaultCrypto.blobPlaintextHmac(plaintext, key),
                integrityHashVersion = CloudVaultCrypto.blobIntegrityHashVersion,
                sealedBoxBase64 = CloudVaultCryptoSupport.encodeBase64(sealedBox),
                aad = "OpenBurnBar-CloudVaultBlob-v2",
            )

        assertEquals(null, envelope.plaintextSHA256)
        assertArrayEquals(plaintext, CloudVaultCrypto.openBlob(envelope, key))
        assertTrue(runCatching { CloudVaultCrypto.openBlob(envelope, otherKey) }.isFailure)
        assertNotEquals(CloudVaultCrypto.sha256Hex(plaintext), envelope.plaintextHMAC)

        val legacy =
            CloudVaultBlobEnvelope(
                schemaVersion = 1,
                keyVersion = 1,
                plaintextSHA256 = CloudVaultCrypto.sha256Hex(plaintext),
                integrityHashVersion = null,
                sealedBoxBase64 = CloudVaultCryptoSupport.encodeBase64(sealedBox),
                aad = null,
            )
        assertArrayEquals(plaintext, CloudVaultCrypto.openBlob(legacy, key))
    }

    @Test
    fun bodyAndChunkHashesAreVaultKeyedHmacs() {
        val key = ByteArray(SHA256_DIGEST_BYTES) { 0x62.toByte() }
        val otherKey = ByteArray(SHA256_DIGEST_BYTES) { 0x63.toByte() }
        val body = "secret transcript body".toByteArray()
        val chunk = "secret transcript chunk"

        val bodyHash = CloudVaultCrypto.sessionBodyHash(body, key)
        assertEquals(bodyHash, CloudVaultCrypto.sessionBodyHash(body, key))
        assertNotEquals(bodyHash, CloudVaultCrypto.sessionBodyHash(body, otherKey))
        assertNotEquals(CloudVaultCrypto.sha256Hex(body), bodyHash)
        assertTrue(bodyHash.matches(Regex("^[a-f0-9]{64}$")))

        val chunkHash = CloudVaultCrypto.sessionChunkHash(chunk, key)
        assertNotEquals(CloudVaultCrypto.sha256Hex(chunk.toByteArray()), chunkHash)
        assertTrue(chunkHash.matches(Regex("^[a-f0-9]{64}$")))
        assertEquals(2, CloudVaultCrypto.sessionBodyHashVersion)
        assertEquals(2, CloudVaultCrypto.sessionChunkHashVersion)
        assertEquals(2, CloudVaultCrypto.projectMemoryContentHashVersion)
        assertEquals(
            bodyHash,
            CloudVaultCrypto.expectedSessionBodyHash(
                body,
                key,
                CloudVaultCrypto.sessionBodyHashVersion,
            ),
        )
        assertEquals(
            CloudVaultCrypto.sha256Hex(body),
            CloudVaultCrypto.expectedSessionBodyHash(body, key, 0),
        )
    }

    @Test
    fun cloudVaultAadContextBindingRejectsRelocatedEnvelopes() {
        val key = ByteArray(SHA256_DIGEST_BYTES) { 0x51.toByte() }
        val context =
            CloudVaultAADContext(
                uid = "userA",
                collection = "session_logs",
                docID = "docA",
                field = "sealedBody",
            )
        val wrongField =
            CloudVaultAADContext(
                uid = "userA",
                collection = "session_logs",
                docID = "docA",
                field = "sealedTitle",
            )
        val wrongDoc =
            CloudVaultAADContext(
                uid = "userA",
                collection = "session_logs",
                docID = "docB",
                field = "sealedBody",
            )

        val sealedText = CloudVaultCrypto.sealText("context-bound title", key, context)
        assertEquals(CloudVaultCrypto.currentSealedTextSchemaVersion, sealedText.schemaVersion)
        assertEquals(context.stringValue, sealedText.aad)
        assertEquals("context-bound title", CloudVaultCrypto.openText(sealedText, key, context))
        assertTrue(runCatching { CloudVaultCrypto.openText(sealedText, key) }.isFailure)
        assertTrue(runCatching { CloudVaultCrypto.openText(sealedText, key, wrongField) }.isFailure)

        val body = "context-bound body".toByteArray()
        val sealedBlob =
            CloudVaultBlobEnvelope(
                schemaVersion = CloudVaultCrypto.currentBlobEnvelopeSchemaVersion,
                keyVersion = 1,
                plaintextHMAC = CloudVaultCrypto.blobPlaintextHmac(body, key),
                integrityHashVersion = CloudVaultCrypto.blobIntegrityHashVersion,
                sealedBoxBase64 = CloudVaultCryptoSupport.encodeBase64(aesGcmCombined(body, key, context.bytes)),
                aad = context.stringValue,
            )
        assertArrayEquals(body, CloudVaultCrypto.openBlob(sealedBlob, key, context))
        assertTrue(runCatching { CloudVaultCrypto.openBlob(sealedBlob, key) }.isFailure)
        assertTrue(runCatching { CloudVaultCrypto.openBlob(sealedBlob, key, wrongDoc) }.isFailure)

        val payload = """{"private":true}""".toByteArray()
        val vaultKeyID = CloudVaultCrypto.vaultKeyID(key)
        val sealedPayload = CloudVaultCrypto.sealPayload(payload, key, vaultKeyID, context)
        assertEquals(context.stringValue, sealedPayload.aad)
        assertArrayEquals(payload, CloudVaultCrypto.openPayload(sealedPayload, key, context))
        assertTrue(runCatching { CloudVaultCrypto.openPayload(sealedPayload, key) }.isFailure)
        assertTrue(runCatching { CloudVaultCrypto.openPayload(sealedPayload, key, wrongField) }.isFailure)
    }

    @Test
    fun semanticHashesAreDeterministicKeyedAndUsefulForRecall() {
        val key = ByteArray(SHA256_DIGEST_BYTES) { 0x33.toByte() }
        val otherKey = ByteArray(SHA256_DIGEST_BYTES) { 0x44.toByte() }
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
        assertTrue(first.size <= VAL_24)
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
        val vaultKey = ByteArray(SHA256_DIGEST_BYTES) { it.toByte() }
        val wrapped = wrapVaultKeyForTest(vaultKey, recipient, ephemeral)

        val unwrapped = CloudVaultCrypto.unwrapVaultKey(wrapped, recipient.private)

        assertArrayEquals(vaultKey, unwrapped)
    }

    private fun wrapVaultKeyForTest(vaultKey: ByteArray, recipient: KeyPair, ephemeral: KeyPair): ByteArray {
        val sharedSecret =
            KeyAgreement.getInstance("ECDH").run {
                init(ephemeral.private)
                doPhase(recipient.public, true)
                generateSecret()
            }
        val wrappingKey =
            hkdfSha256(
                input = sharedSecret,
                salt = ByteArray(0),
                info = "OpenBurnBar-Escrow-v1".toByteArray(),
                length = 32,
            )
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(wrappingKey, "AES"))
        return CloudVaultCrypto.publicKeyX963(ephemeral.public) + cipher.iv + cipher.doFinal(vaultKey)
    }

    private fun legacySealedPayloadForTest(plaintext: ByteArray, vaultKey: ByteArray, vaultKeyID: String): CloudVaultSealedPayload {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(vaultKey, "AES"))
        return CloudVaultSealedPayload(
            schemaVersion = 1,
            algorithm = "AES-256-GCM",
            keyVersion = 1,
            vaultKeyID = vaultKeyID,
            sealedBoxBase64 = CloudVaultCryptoSupport.encodeBase64(cipher.iv + cipher.doFinal(plaintext)),
            aad = null,
        )
    }

    private fun aesGcmCombined(plaintext: ByteArray, vaultKey: ByteArray, aad: ByteArray? = null): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(vaultKey, "AES"))
        if (aad != null) cipher.updateAAD(aad)
        return cipher.iv + cipher.doFinal(plaintext)
    }

    private fun p256KeyPair(): KeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        return generator.generateKeyPair()
    }

    private fun hkdfSha256(input: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(SHA256_DIGEST_BYTES) else salt
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
