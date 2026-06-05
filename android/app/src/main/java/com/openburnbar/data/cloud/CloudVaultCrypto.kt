package com.openburnbar.data.cloud

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.openburnbar.BurnBarApplication
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.tasks.await

data class CloudVaultSealedText(
    val schemaVersion: Int? = null,
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val nonce: String = "",
    val ciphertext: String = "",
    val tag: String = "",
    val aad: String? = null,
)

data class CloudVaultAADContext(
    val uid: String,
    val collection: String,
    val docID: String,
    val field: String,
    val schemaVersion: Int = 2,
    val purpose: String = field,
) {
    val stringValue: String = "${CloudVaultCrypto.aadContextPrefix}|$uid|$collection|$docID|$field|$schemaVersion|$purpose"
    val legacyV1StringValue: String = "${CloudVaultCrypto.legacyAADContextPrefix}|$uid|$collection|$docID|$field"
    val bytes: ByteArray get() = stringValue.toByteArray(Charsets.UTF_8)
    val legacyV1Bytes: ByteArray get() = legacyV1StringValue.toByteArray(Charsets.UTF_8)

    init {
        require(schemaVersion >= 2 && listOf(uid, collection, docID, field, purpose).all { isValidPart(it) }) {
            "Invalid CloudVault AAD context"
        }
    }

    private fun isValidPart(value: String): Boolean =
        value.isNotEmpty() && value.none { it == '|' || it.code < 0x20 || it.code == 0x7f }
}

data class CloudVaultBlobEnvelope(
    val schemaVersion: Int = 2,
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val plaintextSHA256: String? = null,
    val plaintextHMAC: String? = null,
    val integrityHashVersion: Int? = 1,
    val sealedBoxBase64: String = "",
    val aad: String? = "OpenBurnBar-CloudVaultBlob-v2",
)

data class CloudVaultSealedPayload(
    val schemaVersion: Int = 2,
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val vaultKeyID: String = "",
    val sealedBoxBase64: String = "",
    val aad: String? = "OpenBurnBar-CloudVaultSealedPayload-v2",
)

data class SignalEnvelopeBinding(
    val uid: String,
    val scope: String,
    val clientId: String? = null,
    val collection: String? = null,
    val docId: String? = null,
    val field: String? = null,
    val slotId: String? = null,
    val mode: String,
    val formatVersion: Int,
)

data class CloudVaultSignalCiphertextLayer(
    val payloadCiphertextB64: String,
    val payloadAADLabel: String,
    val schemaVersion: Int,
)

data class CloudVaultSignalAtRestWrap(
    val recipientKind: String,
    val recipientIdentityKeyId: String,
    val recipientIdentityKeyB64: String,
    val sealedContentKeyB64: String,
)

data class CloudVaultSignalAtRestKeyDelivery(
    val scheme: String = CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
    val wraps: List<CloudVaultSignalAtRestWrap>,
    val contentKeyLength: Int = CloudVaultCrypto.SIGNAL_AT_REST_CONTENT_KEY_LENGTH,
)

data class CloudVaultSignalBinding(
    val uid: String,
    val collection: String,
    val docId: String,
    val field: String,
    val scope: String = CloudVaultCrypto.SIGNAL_AT_REST_SCOPE,
    val mode: String = CloudVaultCrypto.SIGNAL_AT_REST_MODE,
    val formatVersion: Int = CloudVaultCrypto.SIGNAL_ENVELOPE_FORMAT_VERSION,
) {
    val aadBinding: SignalEnvelopeBinding
        get() =
            SignalEnvelopeBinding(
                uid = this@CloudVaultSignalBinding.uid,
                scope = this@CloudVaultSignalBinding.scope,
                collection = this@CloudVaultSignalBinding.collection,
                docId = this@CloudVaultSignalBinding.docId,
                field = this@CloudVaultSignalBinding.field,
                mode = this@CloudVaultSignalBinding.mode,
                formatVersion = this@CloudVaultSignalBinding.formatVersion,
            )
}

data class CloudVaultSignalEnvelope(
    val signalEnvelopeFormatVersion: Int = CloudVaultCrypto.SIGNAL_ENVELOPE_FORMAT_VERSION,
    val mode: String = CloudVaultCrypto.SIGNAL_AT_REST_MODE,
    val relayEncryption: String = CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
    val ciphertextLayer: CloudVaultSignalCiphertextLayer,
    val keyDelivery: CloudVaultSignalAtRestKeyDelivery,
    val binding: CloudVaultSignalBinding,
)

data class CloudVaultSignalRecipient(
    val recipientKind: String,
    val recipientIdentityKeyId: String,
    val publicKeyData: ByteArray,
)

object CloudVaultCrypto {
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_TAG_BYTES = 16
    private const val SHA256_DIGEST_BYTES = 32
    private const val UNCOMPRESSED_POINT_PREFIX = 0x04
    private const val BYTE_MASK = 0xff
    private const val GCM_NONCE_BYTES = 12
    private const val MIN_BLOB_ENVELOPE_BYTES = 28
    private const val WRAPPED_KEY_EPHEMERAL_BYTES = 65
    private const val P256_COORDINATE_BYTES = 32
    private const val P256_Y_COORDINATE_OFFSET = 33
    private const val WRAP_INFO = "OpenBurnBar-Escrow-v1"
    private const val BLOB_AAD_CONTEXT = "OpenBurnBar-CloudVaultBlob-v2"
    private const val SEALED_PAYLOAD_AAD_CONTEXT = "OpenBurnBar-CloudVaultSealedPayload-v2"
    const val SIGNAL_ENVELOPE_FORMAT_VERSION: Int = 1
    const val SIGNAL_AT_REST_MODE: String = "at-rest"
    const val SIGNAL_AT_REST_SCOPE: String = "cloudvault"
    const val SIGNAL_AT_REST_ENCRYPTION: String = "signal-hpke-identity-seal-v1"
    const val SIGNAL_AT_REST_CONTENT_KEY_LENGTH: Int = 32
    const val SIGNAL_PAYLOAD_SCHEMA_VERSION: Int = 1
    const val SIGNAL_MAX_RECIPIENT_WRAPS: Int = 32
    const val aadContextPrefix: String = "OpenBurnBar-CloudVault-aad-v2"
    const val legacyAADContextPrefix: String = "OpenBurnBar-CloudVault-aad-v1"
    const val currentSealedTextSchemaVersion: Int = 2
    const val currentBlobEnvelopeSchemaVersion: Int = 2
    const val blobIntegrityHashVersion: Int = 1
    const val sessionBodyHashVersion: Int = 2
    const val sessionChunkHashVersion: Int = 2
    const val projectMemoryContentHashVersion: Int = 2
    const val currentSealedPayloadSchemaVersion: Int = 2
    const val tokenHashVersion: Int = 1
    const val semanticHashVersion: Int = 1

    fun sealText(text: String, vaultKey: ByteArray, aadContext: CloudVaultAADContext? = null): CloudVaultSealedText {
        val plaintext = text.toByteArray(Charsets.UTF_8)
        val nonce =
            ByteArray(GCM_NONCE_BYTES).apply {
                java.security.SecureRandom().nextBytes(this)
            }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE.let { Cipher.ENCRYPT_MODE }, SecretKeySpec(vaultKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        aadContext?.let { cipher.updateAAD(it.bytes) }
        val ciphertextAndTag = cipher.doFinal(plaintext)
        val tagSize = GCM_TAG_BYTES
        val ciphertext = ciphertextAndTag.copyOfRange(0, ciphertextAndTag.size - tagSize)
        val tag = ciphertextAndTag.copyOfRange(ciphertextAndTag.size - tagSize, ciphertextAndTag.size)
        return CloudVaultSealedText(
            schemaVersion = aadContext?.let { currentSealedTextSchemaVersion },
            algorithm = "AES-256-GCM",
            keyVersion = 1,
            nonce = CloudVaultCryptoSupport.encodeBase64(nonce),
            ciphertext = CloudVaultCryptoSupport.encodeBase64(ciphertext),
            tag = CloudVaultCryptoSupport.encodeBase64(tag),
            aad = aadContext?.stringValue,
        )
    }

    fun openText(envelope: CloudVaultSealedText, vaultKey: ByteArray, aadContext: CloudVaultAADContext? = null): String {
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val nonce = CloudVaultCryptoSupport.decodeBase64(envelope.nonce)
        val ciphertext = CloudVaultCryptoSupport.decodeBase64(envelope.ciphertext)
        val tag = CloudVaultCryptoSupport.decodeBase64(envelope.tag)
        val aad =
            if ((envelope.schemaVersion ?: 1) >= currentSealedTextSchemaVersion) {
                require(aadContext != null) { "Invalid sealed text AAD context" }
                aadBytesFor(envelope.aad, aadContext)
            } else {
                null
            }
        val plaintext = CloudVaultCryptoSupport.openAesGcm(vaultKey, nonce, ciphertext + tag, aad)
        return plaintext.toString(Charsets.UTF_8)
    }

    fun tokenHashes(text: String, vaultKey: ByteArray, limit: Int = 250): List<String> =
        CloudVaultCryptoSearch.tokenHashes(text, vaultKey, limit)

    fun semanticHashes(text: String, vaultKey: ByteArray, limit: Int = 24): List<String> =
        CloudVaultCryptoSearch.semanticHashes(text, vaultKey, limit)

    fun openBlob(envelope: CloudVaultBlobEnvelope, vaultKey: ByteArray, aadContext: CloudVaultAADContext? = null): ByteArray {
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val combined = CloudVaultCryptoSupport.decodeBase64(envelope.sealedBoxBase64)
        require(combined.size > MIN_BLOB_ENVELOPE_BYTES) { "Invalid encrypted blob envelope" }
        val plaintext =
            when (envelope.schemaVersion) {
                1 ->
                    CloudVaultCryptoSupport.openAesGcm(
                        vaultKey,
                        combined.copyOfRange(0, GCM_NONCE_BYTES),
                        combined.copyOfRange(GCM_NONCE_BYTES, combined.size),
                    )
                currentBlobEnvelopeSchemaVersion -> {
                    val aad =
                        if (envelope.aad == BLOB_AAD_CONTEXT) {
                            null
                        } else {
                            require(aadContext != null) { "Invalid blob AAD context" }
                            aadBytesFor(envelope.aad, aadContext)
                        }
                    CloudVaultCryptoSupport.openAesGcm(
                        vaultKey,
                        combined.copyOfRange(0, GCM_NONCE_BYTES),
                        combined.copyOfRange(GCM_NONCE_BYTES, combined.size),
                        aad,
                    )
                }
                else -> error("Unsupported encrypted blob schema")
            }
        when (envelope.schemaVersion) {
            1 -> require(sha256Hex(plaintext) == envelope.plaintextSHA256) { "Encrypted blob hash mismatch" }
            currentBlobEnvelopeSchemaVersion -> {
                require(envelope.integrityHashVersion == blobIntegrityHashVersion) { "Invalid blob integrity hash version" }
                require(blobPlaintextHmac(plaintext, vaultKey) == envelope.plaintextHMAC) { "Encrypted blob HMAC mismatch" }
            }
            else -> error("Unsupported encrypted blob schema")
        }
        return plaintext
    }

    fun blobPlaintextHmac(data: ByteArray, vaultKey: ByteArray): String =
        keyedHmacHex(data, vaultKey, "blob-integrity")

    fun sessionBodyHash(data: ByteArray, vaultKey: ByteArray): String =
        keyedHmacHex(data, vaultKey, "session-body")

    fun expectedSessionBodyHash(data: ByteArray, vaultKey: ByteArray, bodyHashVersion: Int): String =
        when (bodyHashVersion) {
            sessionBodyHashVersion -> sessionBodyHash(data, vaultKey)
            0, 1 -> sha256Hex(data)
            else -> error("Unsupported session body hash version")
        }

    fun sessionChunkHash(text: String, vaultKey: ByteArray): String =
        keyedHmacHex(text.toByteArray(Charsets.UTF_8), vaultKey, "session-chunk")

    fun projectMemoryContentHash(data: ByteArray, vaultKey: ByteArray): String =
        keyedHmacHex(data, vaultKey, "project-memory-content")

    fun expectedBlobIntegrityHash(data: ByteArray, envelope: CloudVaultBlobEnvelope, vaultKey: ByteArray): String =
        if (envelope.schemaVersion >= currentBlobEnvelopeSchemaVersion) {
            blobPlaintextHmac(data, vaultKey)
        } else {
            sha256Hex(data)
        }

    fun vaultKeyID(vaultKey: ByteArray): String = "v1_${sha256Hex(vaultKey).take(32)}"

    fun sealPayload(
        plaintext: ByteArray,
        vaultKey: ByteArray,
        vaultKeyID: String = vaultKeyID(vaultKey),
        aadContext: CloudVaultAADContext? = null,
    ): CloudVaultSealedPayload {
        val nonce =
            ByteArray(GCM_NONCE_BYTES).apply {
                java.security.SecureRandom().nextBytes(this)
            }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(vaultKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        cipher.updateAAD(sealedPayloadAAD(vaultKeyID = vaultKeyID, keyVersion = 1, aadContext = aadContext))
        return CloudVaultSealedPayload(
            schemaVersion = currentSealedPayloadSchemaVersion,
            algorithm = "AES-256-GCM",
            keyVersion = 1,
            vaultKeyID = vaultKeyID,
            sealedBoxBase64 = CloudVaultCryptoSupport.encodeBase64(nonce + cipher.doFinal(plaintext)),
            aad = aadContext?.stringValue ?: SEALED_PAYLOAD_AAD_CONTEXT,
        )
    }

    fun sealSignalPayload(
        plaintext: ByteArray,
        recipients: List<CloudVaultSignalRecipient>,
        binding: CloudVaultSignalBinding,
    ): CloudVaultSignalEnvelope {
        validateSignalRecipients(recipients)
        val contentKey = ByteArray(SIGNAL_AT_REST_CONTENT_KEY_LENGTH).apply { java.security.SecureRandom().nextBytes(this) }
        val canonicalAAD = CloudVaultCryptoSupport.bindingToAAD(binding.aadBinding)
        val nonce = ByteArray(GCM_NONCE_BYTES).apply { java.security.SecureRandom().nextBytes(this) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(contentKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        cipher.updateAAD(canonicalAAD.toByteArray(Charsets.UTF_8))
        val payloadCiphertext = nonce + cipher.doFinal(plaintext)
        val wraps =
            recipients.map { recipient ->
                val sealedContentKey = CloudVaultCryptoSupport.atRestSeal(contentKey, recipient.publicKeyData, binding.aadBinding)
                CloudVaultSignalAtRestWrap(
                    recipientKind = recipient.recipientKind,
                    recipientIdentityKeyId = recipient.recipientIdentityKeyId,
                    recipientIdentityKeyB64 = CloudVaultCryptoSupport.encodeBase64(recipient.publicKeyData),
                    sealedContentKeyB64 = CloudVaultCryptoSupport.encodeBase64(sealedContentKey),
                )
            }
        return CloudVaultSignalEnvelope(
            ciphertextLayer =
                CloudVaultSignalCiphertextLayer(
                    payloadCiphertextB64 = CloudVaultCryptoSupport.encodeBase64(payloadCiphertext),
                    payloadAADLabel = signalPayloadAadLabel(canonicalAAD),
                    schemaVersion = SIGNAL_PAYLOAD_SCHEMA_VERSION,
                ),
            keyDelivery = CloudVaultSignalAtRestKeyDelivery(wraps = wraps),
            binding = binding,
        )
    }

    fun openSignalPayload(
        envelope: CloudVaultSignalEnvelope,
        recipientIdentityKeyId: String,
        recipientIdentityPrivateKey: ByteArray,
        expectedBinding: CloudVaultSignalBinding,
    ): ByteArray {
        require(envelope.signalEnvelopeFormatVersion == SIGNAL_ENVELOPE_FORMAT_VERSION) { "Invalid Signal envelope version" }
        require(envelope.mode == SIGNAL_AT_REST_MODE) { "Invalid Signal envelope mode" }
        require(envelope.relayEncryption == SIGNAL_AT_REST_ENCRYPTION) { "Invalid Signal envelope scheme" }
        require(envelope.keyDelivery.scheme == SIGNAL_AT_REST_ENCRYPTION) { "Invalid Signal key-delivery scheme" }
        require(envelope.keyDelivery.contentKeyLength == SIGNAL_AT_REST_CONTENT_KEY_LENGTH) { "Invalid Signal content-key length" }
        require(envelope.ciphertextLayer.schemaVersion == SIGNAL_PAYLOAD_SCHEMA_VERSION) { "Invalid Signal payload schema" }
        require(envelope.binding == expectedBinding) { "Signal envelope binding mismatch" }
        val wrap =
            envelope.keyDelivery.wraps.firstOrNull { it.recipientIdentityKeyId == recipientIdentityKeyId }
                ?: error("Missing Signal recipient wrap")
        val sealedContentKey = CloudVaultCryptoSupport.decodeBase64(wrap.sealedContentKeyB64)
        val canonicalAAD = CloudVaultCryptoSupport.bindingToAAD(expectedBinding.aadBinding)
        val contentKey = CloudVaultCryptoSupport.atRestOpen(sealedContentKey, recipientIdentityPrivateKey, expectedBinding.aadBinding)
        require(contentKey.size == SIGNAL_AT_REST_CONTENT_KEY_LENGTH) { "Invalid Signal content key" }
        val payload = CloudVaultCryptoSupport.decodeBase64(envelope.ciphertextLayer.payloadCiphertextB64)
        return CloudVaultCryptoSupport.openAesGcm(
            contentKey,
            payload.copyOfRange(0, GCM_NONCE_BYTES),
            payload.copyOfRange(GCM_NONCE_BYTES, payload.size),
            canonicalAAD.toByteArray(Charsets.UTF_8),
        )
    }

    fun openPayload(envelope: CloudVaultSealedPayload, vaultKey: ByteArray, aadContext: CloudVaultAADContext? = null): ByteArray {
        require(envelope.schemaVersion == 1 || envelope.schemaVersion == currentSealedPayloadSchemaVersion) { "Unsupported sealed payload schema" }
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val actualVaultKeyID = vaultKeyID(vaultKey)
        require(envelope.vaultKeyID == actualVaultKeyID) { "Vault key mismatch" }
        val combined = CloudVaultCryptoSupport.decodeBase64(envelope.sealedBoxBase64)
        require(combined.size > MIN_BLOB_ENVELOPE_BYTES) { "Invalid encrypted payload envelope" }
        val aad =
            if (envelope.schemaVersion == currentSealedPayloadSchemaVersion) {
                if (envelope.aad == SEALED_PAYLOAD_AAD_CONTEXT) {
                    sealedPayloadAAD(vaultKeyID = envelope.vaultKeyID, keyVersion = envelope.keyVersion, aadContext = null)
                } else {
                    require(aadContext != null) { "Invalid sealed payload AAD context" }
                    aadBytesFor(envelope.aad, aadContext)
                }
            } else {
                null
            }
        return CloudVaultCryptoSupport.openAesGcm(
            vaultKey,
            combined.copyOfRange(0, GCM_NONCE_BYTES),
            combined.copyOfRange(GCM_NONCE_BYTES, combined.size),
            aad,
        )
    }

    fun sealedPayloadMap(envelope: CloudVaultSealedPayload): Map<String, Any> =
        buildMap {
            put("schemaVersion", envelope.schemaVersion)
            put("algorithm", envelope.algorithm)
            put("keyVersion", envelope.keyVersion)
            put("vaultKeyID", envelope.vaultKeyID)
            put("sealedBoxBase64", envelope.sealedBoxBase64)
            envelope.aad?.let { put("aad", it) }
        }

    fun sealedPayloadMapV1ForTest(envelope: CloudVaultSealedPayload): Map<String, Any> =
        mapOf(
            "schemaVersion" to envelope.schemaVersion,
            "algorithm" to envelope.algorithm,
            "keyVersion" to envelope.keyVersion,
            "vaultKeyID" to envelope.vaultKeyID,
            "sealedBoxBase64" to envelope.sealedBoxBase64,
        )

    fun sealedPayloadFromMap(raw: Map<*, *>?): CloudVaultSealedPayload? {
        if (raw == null) return null
        return CloudVaultSealedPayload(
            schemaVersion = (raw["schemaVersion"] as? Number)?.toInt() ?: 1,
            algorithm = raw["algorithm"] as? String ?: "AES-256-GCM",
            keyVersion = (raw["keyVersion"] as? Number)?.toInt() ?: 1,
            vaultKeyID = raw["vaultKeyID"] as? String ?: return null,
            sealedBoxBase64 = raw["sealedBoxBase64"] as? String ?: return null,
            aad = raw["aad"] as? String,
        )
    }

    fun signalEnvelopeMap(envelope: CloudVaultSignalEnvelope): Map<String, Any> =
        mapOf(
            "signalEnvelopeFormatVersion" to envelope.signalEnvelopeFormatVersion,
            "mode" to envelope.mode,
            "relayEncryption" to envelope.relayEncryption,
            "ciphertextLayer" to
                mapOf(
                    "payloadCiphertextB64" to envelope.ciphertextLayer.payloadCiphertextB64,
                    "payloadAADLabel" to envelope.ciphertextLayer.payloadAADLabel,
                    "schemaVersion" to envelope.ciphertextLayer.schemaVersion,
                ),
            "keyDelivery" to
                mapOf(
                    "scheme" to envelope.keyDelivery.scheme,
                    "contentKeyLength" to envelope.keyDelivery.contentKeyLength,
                    "wraps" to
                        envelope.keyDelivery.wraps.map { wrap ->
                            mapOf(
                                "recipientKind" to wrap.recipientKind,
                                "recipientIdentityKeyId" to wrap.recipientIdentityKeyId,
                                "recipientIdentityKeyB64" to wrap.recipientIdentityKeyB64,
                                "sealedContentKeyB64" to wrap.sealedContentKeyB64,
                            )
                        },
                ),
            "binding" to
                mapOf(
                    "uid" to envelope.binding.uid,
                    "scope" to envelope.binding.scope,
                    "collection" to envelope.binding.collection,
                    "docId" to envelope.binding.docId,
                    "field" to envelope.binding.field,
                    "mode" to envelope.binding.mode,
                    "formatVersion" to envelope.binding.formatVersion,
                ),
        )

    fun signalEnvelopeFromMap(raw: Map<*, *>?): CloudVaultSignalEnvelope? {
        if (raw == null) return null
        val ciphertextLayerRaw = raw["ciphertextLayer"] as? Map<*, *> ?: return null
        val keyDeliveryRaw = raw["keyDelivery"] as? Map<*, *> ?: return null
        val bindingRaw = raw["binding"] as? Map<*, *> ?: return null
        val wrapRaws = keyDeliveryRaw["wraps"] as? List<*> ?: return null
        val wraps =
            wrapRaws.map { rawWrap ->
                val wrap = rawWrap as? Map<*, *> ?: return null
                CloudVaultSignalAtRestWrap(
                    recipientKind = wrap["recipientKind"] as? String ?: return null,
                    recipientIdentityKeyId = wrap["recipientIdentityKeyId"] as? String ?: return null,
                    recipientIdentityKeyB64 = wrap["recipientIdentityKeyB64"] as? String ?: return null,
                    sealedContentKeyB64 = wrap["sealedContentKeyB64"] as? String ?: return null,
                )
            }
        return CloudVaultSignalEnvelope(
            signalEnvelopeFormatVersion = (raw["signalEnvelopeFormatVersion"] as? Number)?.toInt() ?: return null,
            mode = raw["mode"] as? String ?: return null,
            relayEncryption = raw["relayEncryption"] as? String ?: return null,
            ciphertextLayer =
                CloudVaultSignalCiphertextLayer(
                    payloadCiphertextB64 = ciphertextLayerRaw["payloadCiphertextB64"] as? String ?: return null,
                    payloadAADLabel = ciphertextLayerRaw["payloadAADLabel"] as? String ?: return null,
                    schemaVersion = (ciphertextLayerRaw["schemaVersion"] as? Number)?.toInt() ?: return null,
                ),
            keyDelivery =
                CloudVaultSignalAtRestKeyDelivery(
                    scheme = keyDeliveryRaw["scheme"] as? String ?: return null,
                    wraps = wraps,
                    contentKeyLength = (keyDeliveryRaw["contentKeyLength"] as? Number)?.toInt() ?: return null,
                ),
            binding =
                CloudVaultSignalBinding(
                    uid = bindingRaw["uid"] as? String ?: return null,
                    scope = bindingRaw["scope"] as? String ?: return null,
                    collection = bindingRaw["collection"] as? String ?: return null,
                    docId = bindingRaw["docId"] as? String ?: return null,
                    field = bindingRaw["field"] as? String ?: return null,
                    mode = bindingRaw["mode"] as? String ?: return null,
                    formatVersion = (bindingRaw["formatVersion"] as? Number)?.toInt() ?: return null,
                ),
        )
    }

    private fun sealedPayloadAAD(vaultKeyID: String, keyVersion: Int, aadContext: CloudVaultAADContext?): ByteArray =
        aadContext?.bytes
            ?: "$SEALED_PAYLOAD_AAD_CONTEXT|AES-256-GCM|keyVersion=$keyVersion|vaultKeyID=$vaultKeyID"
                .toByteArray(Charsets.UTF_8)

    private fun aadBytesFor(envelopeAAD: String?, aadContext: CloudVaultAADContext): ByteArray =
        when (envelopeAAD) {
            aadContext.stringValue -> aadContext.bytes
            aadContext.legacyV1StringValue -> aadContext.legacyV1Bytes
            else -> error("Invalid CloudVault AAD context")
        }

    private fun keyedHmacHex(data: ByteArray, vaultKey: ByteArray, purpose: String): String {
        require(vaultKey.size == SHA256_DIGEST_BYTES) { "Invalid vault key length" }
        val key =
            CloudVaultCryptoSearch.hkdfSha256(
                vaultKey,
                "OpenBurnBar-CloudVault-HMAC-Salt-v1".toByteArray(Charsets.UTF_8),
                "OpenBurnBar-CloudVault-HMAC-v1|$purpose".toByteArray(Charsets.UTF_8),
                SHA256_DIGEST_BYTES,
            )
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data).joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }
    }

    fun unwrapVaultKey(ciphertext: ByteArray, privateKey: PrivateKey): ByteArray {
        require(ciphertext.size > WRAPPED_KEY_EPHEMERAL_BYTES) { "Invalid wrapped vault key" }
        val ecPrivateKey =
            privateKey as? ECPrivateKey
                ?: error("Vault key unwrap requires an EC private key")
        val ephemeralPublic =
            CloudVaultCryptoSupport.publicKeyFromX963(ciphertext.copyOfRange(0, WRAPPED_KEY_EPHEMERAL_BYTES), ecPrivateKey.params)
        val sharedSecret =
            KeyAgreement.getInstance("ECDH").run {
                init(privateKey)
                doPhase(ephemeralPublic, true)
                generateSecret()
            }
        val wrappingKey = CloudVaultCryptoSearch.hkdfSha256(sharedSecret, ByteArray(0), WRAP_INFO.toByteArray(), SHA256_DIGEST_BYTES)
        val combined = ciphertext.copyOfRange(WRAPPED_KEY_EPHEMERAL_BYTES, ciphertext.size)
        val plaintext =
            CloudVaultCryptoSupport.openAesGcm(
                wrappingKey,
                combined.copyOfRange(0, GCM_NONCE_BYTES),
                combined.copyOfRange(GCM_NONCE_BYTES, combined.size),
            )
        require(plaintext.size == SHA256_DIGEST_BYTES) { "Invalid vault key length" }
        return plaintext
    }

    fun publicKeyX963(publicKey: PublicKey): ByteArray {
        val ec =
            publicKey as? ECPublicKey
                ?: error("X9.63 encoding requires an EC public key")
        return byteArrayOf(UNCOMPRESSED_POINT_PREFIX.toByte()) + CloudVaultCryptoSupport.fixed32(ec.w.affineX) + CloudVaultCryptoSupport.fixed32(ec.w.affineY)
    }

    fun sha256Hex(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }

    fun sha256Base64(data: ByteArray): String = CloudVaultCryptoSupport.encodeBase64(MessageDigest.getInstance("SHA-256").digest(data))

    private fun validateSignalRecipients(recipients: List<CloudVaultSignalRecipient>) {
        require(recipients.isNotEmpty()) { "Signal envelopes require at least one recipient" }
        require(recipients.size <= SIGNAL_MAX_RECIPIENT_WRAPS) { "Too many Signal recipients" }
        val seen = mutableSetOf<String>()
        recipients.forEach { recipient ->
            require(recipient.recipientKind == "device" || recipient.recipientKind == "escrow" || recipient.recipientKind == "recovery") {
                "Invalid Signal recipient kind"
            }
            require(seen.add(recipient.recipientIdentityKeyId)) { "Duplicate Signal recipient id" }
        }
    }

    private fun signalPayloadAadLabel(canonicalAAD: String): String =
        "bindingToAAD-sha256:${sha256Hex(canonicalAAD.toByteArray(Charsets.UTF_8)).take(32)}"
}

class AndroidCloudVaultDeviceKeypair private constructor(
    private val privateKey: PrivateKey,
    val publicKeyData: ByteArray,
    val keyVersion: Int = 1,
) {
    val publicKeyFingerprint: String = CloudVaultCrypto.sha256Base64(publicKeyData)
    val deviceId: String = "android-${CloudVaultCrypto.sha256Hex(publicKeyData).take(32)}"

    fun decryptWrappedVaultKey(base64: String): ByteArray = CloudVaultCrypto.unwrapVaultKey(CloudVaultCryptoSupport.decodeBase64(base64), privateKey)

    companion object {
        private const val PREFS = "openburnbar_cloud_vault_device"
        private const val PRIVATE_KEY = "private_key"
        private const val PUBLIC_KEY = "public_key"

        fun loadOrCreate(): AndroidCloudVaultDeviceKeypair {
            val prefs = BurnBarApplication.appContext.getSharedPreferences(PREFS, 0)
            val storedPrivate = prefs.getString(PRIVATE_KEY, null)
            val storedPublic = prefs.getString(PUBLIC_KEY, null)
            if (!storedPrivate.isNullOrBlank() && !storedPublic.isNullOrBlank()) {
                val privateBytes = AndroidLocalSecretBox.decrypt(CloudVaultCryptoSupport.decodeBase64(storedPrivate))
                val privateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privateBytes))
                return AndroidCloudVaultDeviceKeypair(privateKey, CloudVaultCryptoSupport.decodeBase64(storedPublic))
            }

            val generator = KeyPairGenerator.getInstance("EC")
            generator.initialize(ECGenParameterSpec("secp256r1"))
            val pair = generator.generateKeyPair()
            val publicX963 = CloudVaultCrypto.publicKeyX963(pair.public)
            prefs.edit()
                .putString(PRIVATE_KEY, CloudVaultCryptoSupport.encodeBase64(AndroidLocalSecretBox.encrypt(pair.private.encoded)))
                .putString(PUBLIC_KEY, CloudVaultCryptoSupport.encodeBase64(publicX963))
                .apply()
            return AndroidCloudVaultDeviceKeypair(pair.private, publicX963)
        }
    }
}

data class AndroidCloudVaultResolvedKey(
    val keyData: ByteArray,
    val vaultKeyID: String,
)

object AndroidCloudVaultKeyAccess {
    private const val PREFS = "openburnbar_cloud_vault_keys"
    private const val VAL_5 = 5

    suspend fun keyForWriting(uid: String, firestore: FirebaseFirestore = FirebaseFirestore.getInstance()): AndroidCloudVaultResolvedKey =
        keyForReading(uid = uid, firestore = firestore) ?: error("Cloud vault key is not active on this Android device yet. Approve this device from a Mac or iPhone before writing cloud chat content.")

    suspend fun keyForReading(uid: String, firestore: FirebaseFirestore = FirebaseFirestore.getInstance()): AndroidCloudVaultResolvedKey? {
        val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        AndroidEscrowDeviceRegistry(firestore).registerSelf(uid = uid, keypair = keypair)
        loadLocalKey(uid)?.let { local ->
            val resolved = AndroidCloudVaultResolvedKey(local, CloudVaultCrypto.vaultKeyID(local))
            verifyStateIfPresent(uid, firestore, resolved.vaultKeyID)
            return resolved
        }
        val unwrapped = unwrapExistingKey(uid, firestore, keypair) ?: return null
        saveLocalKey(uid, unwrapped.keyData)
        return unwrapped
    }

    private suspend fun unwrapExistingKey(
        uid: String,
        firestore: FirebaseFirestore,
        keypair: AndroidCloudVaultDeviceKeypair,
    ): AndroidCloudVaultResolvedKey? {
        val userRef = firestore.collection("users").document(uid)
        val stateVaultKeyID =
            userRef.collection("cloud_vault_state")
                .document("current")
                .get()
                .await()
                .getString("vaultKeyID")
        val snapshot =
            userRef.collection("cloud_vault_key_wrappers")
                .whereEqualTo("targetDeviceId", keypair.deviceId)
                .whereEqualTo("status", "active")
                .limit(VAL_5.toLong())
                .get()
                .await()

        return snapshot.documents.firstNotNullOfOrNull { document ->
            val wrapped = document.getString("wrappedVaultKey") ?: return@firstNotNullOfOrNull null
            val wrapperVaultKeyID = document.getString("vaultKeyID")
            val key =
                runCatching {
                    keypair.decryptWrappedVaultKey(wrapped)
                }.getOrNull() ?: return@firstNotNullOfOrNull null
            val actualVaultKeyID = CloudVaultCrypto.vaultKeyID(key)
            if (wrapperVaultKeyID != null && wrapperVaultKeyID != actualVaultKeyID) {
                return@firstNotNullOfOrNull null
            }
            if (stateVaultKeyID != null && stateVaultKeyID != actualVaultKeyID) {
                return@firstNotNullOfOrNull null
            }
            AndroidCloudVaultResolvedKey(key, actualVaultKeyID)
        }
    }

    private suspend fun verifyStateIfPresent(uid: String, firestore: FirebaseFirestore, vaultKeyID: String) {
        val ref = firestore.collection("users").document(uid).collection("cloud_vault_state").document("current")
        val snapshot = ref.get().await()
        val existing = snapshot.getString("vaultKeyID")
        if (existing != null) {
            require(existing == vaultKeyID) { "Cloud vault key mismatch" }
            return
        }
        ref.set(
            mapOf(
                "uid" to uid,
                "vaultKeyID" to vaultKeyID,
                "keyVersion" to 1,
                "algorithm" to "AES-256-GCM",
                "status" to "active",
                "createdByDeviceId" to AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId,
                "createdAt" to FieldValue.serverTimestamp(),
                "updatedAt" to FieldValue.serverTimestamp(),
                "schemaVersion" to 1,
            ),
            SetOptions.merge(),
        ).await()
    }

    private fun loadLocalKey(uid: String): ByteArray? {
        val prefs = BurnBarApplication.appContext.getSharedPreferences(PREFS, 0)
        val stored = prefs.getString("vault_key_$uid", null) ?: return null
        return runCatching { AndroidLocalSecretBox.decrypt(CloudVaultCryptoSupport.decodeBase64(stored)) }
            .getOrNull()
            ?.takeIf { it.size == 32 }
    }

    private fun saveLocalKey(uid: String, key: ByteArray) {
        require(key.size == 32) { "Invalid vault key length" }
        val prefs = BurnBarApplication.appContext.getSharedPreferences(PREFS, 0)
        prefs.edit()
            .putString("vault_key_$uid", CloudVaultCryptoSupport.encodeBase64(AndroidLocalSecretBox.encrypt(key)))
            .apply()
    }
}

private object AndroidLocalSecretBox {
    private const val ALIAS = "openburnbar-cloud-vault-device-secret"
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12

    fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return cipher.iv + cipher.doFinal(plaintext)
    }

    fun decrypt(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_AUTH_TAG_BITS, sealed.copyOfRange(0, GCM_NONCE_BYTES)))
        return cipher.doFinal(sealed.copyOfRange(GCM_NONCE_BYTES, sealed.size))
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec =
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        generator.init(spec)
        return generator.generateKey()
    }
}
