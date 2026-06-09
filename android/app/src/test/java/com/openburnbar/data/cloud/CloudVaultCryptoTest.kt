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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val SHA256_DIGEST_BYTES = 32
private const val VAL_24 = 24
private const val SIGNAL_KAT_PRIVATE_KEY_B64 = "yGZ5zfds7ljkjsopcLya1ayDbjV+TCL6/b4BQBpqfV0="
private const val SIGNAL_KAT_PUBLIC_KEY_B64_CANONICAL = "BVw7AC8duGgSdz/wLmMLMe+ymSUCcMkOcoJ+E6Eb+RhO"
private const val SIGNAL_KAT_CIPHERTEXT_B64 =
    "AQt/WxZMem2jpwxChzbQuzg/yMY5kdPdzuOmgLoJwoIZOFUfdEr33hTkLyIzwQTD7J2uShoruECN2ty8j1QlSe2siO6" +
        "trszlngaJe7Zhb7liPArb1x/A+J/nrS5GNw=="
private const val SIGNAL_KAT_PLAINTEXT_B64 = "Y3Jvc3MtbGFuZ3VhZ2UgaW50ZXJvcCBzZWNyZXQg4oCUIG5vZGUgc2VhbGVk"

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
    fun rewrapCloudVaultDocumentResealsTopLevelEnvelopesWithPathBoundAad() {
        val oldKey = ByteArray(SHA256_DIGEST_BYTES) { 0x71.toByte() }
        val newKey = ByteArray(SHA256_DIGEST_BYTES) { 0x72.toByte() }
        val oldVaultKeyID = CloudVaultCrypto.vaultKeyID(oldKey)
        val newVaultKeyID = CloudVaultCrypto.vaultKeyID(newKey)
        val uid = "userA"
        val collection = "cli_agent_mission_requests"
        val docID = "requestA"
        val stateContext =
            CloudVaultAADContext(
                uid = uid,
                collection = collection,
                docID = docID,
                field = "sealedStatePayload",
            )
        val document =
            mapOf<String, Any?>(
                "vaultKeyID" to oldVaultKeyID,
                "sealedStateVaultKeyID" to oldVaultKeyID,
                "sealedPayload" to
                    CloudVaultCrypto.sealedPayloadMap(
                        CloudVaultCrypto.sealPayload("""{"prompt":"fix launch"}""".toByteArray(), oldKey, oldVaultKeyID),
                    ),
                "sealedStatePayload" to
                    CloudVaultCrypto.sealedPayloadMap(
                        CloudVaultCrypto.sealPayload("""{"summary":"running"}""".toByteArray(), oldKey, oldVaultKeyID, stateContext),
                    ),
                "sealedDisplayLabel" to
                    CloudVaultCrypto.sealedTextMap(
                        CloudVaultCrypto.sealText("release policy", oldKey),
                    ),
                "plainStatus" to "queued",
            )

        val result =
            CloudVaultCrypto.rewrapCloudVaultDocument(
                data = document,
                uid = uid,
                collection = collection,
                docID = docID,
                oldKey = oldKey,
                newKey = newKey,
                newVaultKeyID = newVaultKeyID,
                vaultGeneration = 7,
                rotationJobId = "job-7",
            )

        assertEquals(setOf("sealedDisplayLabel", "sealedPayload", "sealedStatePayload"), result.changedFields.toSet())
        assertEquals("queued", result.data["plainStatus"])
        assertEquals(newVaultKeyID, result.data["vaultKeyID"])
        assertEquals(newVaultKeyID, result.data["sealedStateVaultKeyID"])
        assertEquals(7, result.data["vaultGeneration"])
        assertEquals("job-7", result.data["rewrapJobId"])

        val payloadEnvelope = CloudVaultCrypto.sealedPayloadFromMap(result.data["sealedPayload"] as? Map<*, *>)
        requireNotNull(payloadEnvelope)
        val payloadContext = CloudVaultAADContext(uid = uid, collection = collection, docID = docID, field = "sealedPayload")
        assertEquals(newVaultKeyID, payloadEnvelope.vaultKeyID)
        assertEquals(payloadContext.stringValue, payloadEnvelope.aad)
        assertArrayEquals(
            """{"prompt":"fix launch"}""".toByteArray(),
            CloudVaultCrypto.openPayload(payloadEnvelope, newKey, payloadContext),
        )
        assertTrue(runCatching { CloudVaultCrypto.openPayload(payloadEnvelope, oldKey) }.isFailure)

        val stateEnvelope = CloudVaultCrypto.sealedPayloadFromMap(result.data["sealedStatePayload"] as? Map<*, *>)
        requireNotNull(stateEnvelope)
        assertEquals(stateContext.stringValue, stateEnvelope.aad)
        assertArrayEquals(
            """{"summary":"running"}""".toByteArray(),
            CloudVaultCrypto.openPayload(stateEnvelope, newKey, stateContext),
        )

        val labelEnvelope = CloudVaultCrypto.sealedTextFromMap(result.data["sealedDisplayLabel"] as? Map<*, *>)
        requireNotNull(labelEnvelope)
        val labelContext = CloudVaultAADContext(uid = uid, collection = collection, docID = docID, field = "sealedDisplayLabel")
        assertEquals(labelContext.stringValue, labelEnvelope.aad)
        assertEquals("release policy", CloudVaultCrypto.openText(labelEnvelope, newKey, labelContext))
    }

    @Test
    fun rewrapCloudVaultDocumentResealsBlobEnvelopes() {
        val oldKey = ByteArray(SHA256_DIGEST_BYTES) { 0x81.toByte() }
        val newKey = ByteArray(SHA256_DIGEST_BYTES) { 0x82.toByte() }
        val body = "session markdown body".toByteArray()
        val document =
            mapOf<String, Any?>(
                "sealedSnapshot" to CloudVaultCrypto.blobEnvelopeMap(CloudVaultCrypto.sealBlob(body, oldKey)),
            )

        val result =
            CloudVaultCrypto.rewrapCloudVaultDocument(
                data = document,
                uid = "userA",
                collection = "project_memory_snapshots",
                docID = "pm_fixture",
                oldKey = oldKey,
                newKey = newKey,
            )

        assertEquals(listOf("sealedSnapshot"), result.changedFields)
        val envelope = CloudVaultCrypto.blobEnvelopeFromMap(result.data["sealedSnapshot"] as? Map<*, *>)
        requireNotNull(envelope)
        val context =
            CloudVaultAADContext(
                uid = "userA",
                collection = "project_memory_snapshots",
                docID = "pm_fixture",
                field = "sealedSnapshot",
            )
        assertEquals(context.stringValue, envelope.aad)
        assertArrayEquals(body, CloudVaultCrypto.openBlob(envelope, newKey, context))
        assertTrue(runCatching { CloudVaultCrypto.openBlob(envelope, oldKey) }.isFailure)
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

    @Test
    fun signalBindingToAadMatchesCanonicalGrammarAndRejectsInjection() {
        val binding =
            SignalEnvelopeBinding(
                uid = "u1",
                scope = "cloudvault",
                collection = "pensieve",
                docId = "doc-42",
                field = "body",
                mode = "at-rest",
                formatVersion = 1,
            )

        assertEquals(
            "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|u1||pensieve|doc-42|body||1",
            CloudVaultCryptoSupport.bindingToAAD(binding),
        )
        assertEquals(
            CloudVaultCryptoSupport.bindingToAAD(binding.copy(uid = "café")),
            CloudVaultCryptoSupport.bindingToAAD(binding.copy(uid = "cafe\u0301")),
        )
        assertTrue(runCatching { CloudVaultCryptoSupport.bindingToAAD(binding.copy(uid = "u|1")) }.isFailure)
        assertTrue(runCatching { CloudVaultCryptoSupport.bindingToAAD(binding.copy(docId = "doc\n42")) }.isFailure)
    }

    @Test
    fun signalAtRestDirectOpenMatchesNodeKatAndRoundTrips() {
        val privateKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_PRIVATE_KEY_B64)
        val publicKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_PUBLIC_KEY_B64_CANONICAL)
        val binding =
            SignalEnvelopeBinding(
                uid = "u1",
                scope = "cloudvault",
                collection = "pensieve",
                docId = "doc-42",
                field = "body",
                mode = "at-rest",
                formatVersion = 1,
            )
        val katPlaintext = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_PLAINTEXT_B64)
        val katCiphertext = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_CIPHERTEXT_B64)

        assertArrayEquals(katPlaintext, CloudVaultCryptoSupport.atRestOpen(katCiphertext, privateKey, binding))
        assertTrue(runCatching { CloudVaultCryptoSupport.atRestOpen(katCiphertext, privateKey, binding.copy(docId = "wrong")) }.isFailure)

        val plaintext = "android signal direct payload".toByteArray()
        val ciphertext = CloudVaultCryptoSupport.atRestSeal(plaintext, publicKey, binding)
        assertArrayEquals(plaintext, CloudVaultCryptoSupport.atRestOpen(ciphertext, privateKey, binding))
        assertTrue(runCatching { CloudVaultCryptoSupport.atRestOpen(ciphertext, privateKey, binding.copy(field = "other")) }.isFailure)
    }

    @Test
    fun signalCloudVaultEnvelopeWrapsContentKeyAndRejectsTamper() {
        val privateKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_PRIVATE_KEY_B64)
        val publicKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_PUBLIC_KEY_B64_CANONICAL)
        val binding =
            CloudVaultSignalBinding(
                uid = "uid-1",
                collection = "pensieve",
                docId = "doc-42",
                field = "body",
            )
        val plaintext = "android cloudvault signal payload".toByteArray()
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                plaintext,
                recipients =
                listOf(
                    CloudVaultSignalRecipient("device", "device-key-1", publicKey),
                    CloudVaultSignalRecipient("escrow", "escrow-key-1", publicKey),
                ),
                binding = binding,
            )

        assertEquals(CloudVaultCrypto.SIGNAL_AT_REST_MODE, envelope.mode)
        assertEquals(CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION, envelope.relayEncryption)
        assertEquals(2, envelope.keyDelivery.wraps.size)
        assertTrue(envelope.ciphertextLayer.payloadAADLabel.startsWith("bindingToAAD-sha256:"))
        assertArrayEquals(
            plaintext,
            CloudVaultCrypto.openSignalPayload(envelope, "device-key-1", privateKey, expectedBinding = binding),
        )
        assertArrayEquals(
            plaintext,
            CloudVaultCrypto.openSignalPayload(envelope, "escrow-key-1", privateKey, expectedBinding = binding),
        )
        assertTrue(
            runCatching {
                CloudVaultCrypto.openSignalPayload(
                    envelope,
                    "device-key-1",
                    privateKey,
                    expectedBinding = binding.copy(docId = "relocated-doc"),
                )
            }.isFailure,
        )

        val tampered =
            envelope.copy(
                ciphertextLayer =
                envelope.ciphertextLayer.copy(
                    payloadCiphertextB64 = envelope.ciphertextLayer.payloadCiphertextB64.dropLast(1) + "A",
                ),
            )
        assertTrue(runCatching { CloudVaultCrypto.openSignalPayload(tampered, "device-key-1", privateKey, expectedBinding = binding) }.isFailure)
        assertTrue(runCatching { CloudVaultCrypto.openSignalPayload(envelope, "missing-key", privateKey, expectedBinding = binding) }.isFailure)
    }

    @Test
    fun signalCloudVaultEnvelopeMapRoundTrips() {
        val publicKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_KAT_PUBLIC_KEY_B64_CANONICAL)
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                "android cloudvault signal map payload".toByteArray(),
                recipients = listOf(CloudVaultSignalRecipient("device", "device-key-1", publicKey)),
                binding =
                CloudVaultSignalBinding(
                    uid = "uid-1",
                    collection = "pensieve",
                    docId = "doc-42",
                    field = "body",
                ),
            )
        val raw = CloudVaultCrypto.signalEnvelopeMap(envelope)

        assertFalse(raw.containsKey("relayKeyVersion"))
        assertEquals(CloudVaultCrypto.SIGNAL_AT_REST_MODE, raw["mode"])
        assertEquals(CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION, raw["relayEncryption"])
        assertEquals(envelope, CloudVaultCrypto.signalEnvelopeFromMap(raw))
        assertNull(CloudVaultCrypto.signalEnvelopeFromMap(mapOf("mode" to CloudVaultCrypto.SIGNAL_AT_REST_MODE)))
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
