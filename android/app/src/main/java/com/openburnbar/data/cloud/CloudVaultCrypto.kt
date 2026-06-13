// Security-pinned E2EE/trust code under active remediation; behavior is pinned by tests and
// a P0 migration gate.
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

/**
 * Sender authentication for an at-rest Signal envelope — the Android mirror of Swift
 * `CloudVaultSignalSenderAuth` (OpenBurnBarCore/.../CloudVaultCrypto.swift:303). The writing
 * device signs the envelope (binding + ciphertext + recipient wraps) with its identity PRIVATE
 * key; a reader verifies the signature against the sender's PINNED public key from the
 * trusted-device set (NOT the wire `senderIdentityKeyB64`). Because the server holds only PUBLIC
 * identity keys it cannot forge a valid signature, which closes the at-rest forgery hole (a
 * libsignal `seal` to the recipient alone has no sender auth).
 */
data class CloudVaultSignalSenderAuth(
    val senderIdentityKeyId: String,
    val senderIdentityKeyB64: String,
    val signatureB64: String,
    val signatureVersion: Int = CloudVaultCrypto.SIGNAL_AT_REST_SENDER_AUTH_VERSION,
)

data class CloudVaultSignalEnvelope(
    val signalEnvelopeFormatVersion: Int = CloudVaultCrypto.SIGNAL_ENVELOPE_FORMAT_VERSION,
    val mode: String = CloudVaultCrypto.SIGNAL_AT_REST_MODE,
    val relayEncryption: String = CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
    val ciphertextLayer: CloudVaultSignalCiphertextLayer,
    val keyDelivery: CloudVaultSignalAtRestKeyDelivery,
    val binding: CloudVaultSignalBinding,
    // Optional on the wire (legacy envelopes predate it), but REQUIRED for a reader to accept an
    // at-rest envelope — `openSignalPayload` rejects an envelope without verified sender auth and
    // the caller falls back to the (non-forgeable) legacy sealedPayload.
    val senderAuth: CloudVaultSignalSenderAuth? = null,
)

/**
 * At-rest Signal sender-authentication failures — the Android mirror of Swift
 * `OpenBurnBarSignalCoreError` (the sender-auth cases). Thrown fail-closed by
 * `CloudVaultCrypto.openSignalPayload`; `SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback`
 * classifies each so a forged/stripped sender block (or a relocated binding) never downgrades to
 * the unauthenticated legacy `sealedPayload`.
 */
sealed class CloudVaultSignalSenderAuthException(message: String) : IllegalStateException(message) {
    class SenderAuthMissing : CloudVaultSignalSenderAuthException("The at-rest Signal envelope has no sender authentication block.")

    class SenderNotTrusted(val senderIdentityKeyId: String) :
        CloudVaultSignalSenderAuthException("The at-rest Signal envelope sender $senderIdentityKeyId is not a trusted device.")

    class SenderSignatureInvalid : CloudVaultSignalSenderAuthException("The at-rest Signal envelope sender signature failed verification.")
}

data class CloudVaultSignalRecipient(
    val recipientKind: String,
    val recipientIdentityKeyId: String,
    val publicKeyData: ByteArray,
)

data class CloudVaultDocumentRewrapResult(
    val data: Map<String, Any?>,
    val changedFields: List<String>,
) {
    val changed: Boolean get() = changedFields.isNotEmpty()
}

// Single cohesive CloudVault crypto facade kept whole on purpose: every sealer/opener here shares
// the byte-parity constants + AAD/Signal helpers with the Swift `CloudVaultCrypto`, and splitting it
// would scatter that parity seam. The RR-7a sender-auth + RR-5 wrap/generate additions edge it over
// the size rule; the grouping is load-bearing, so suppress rather than fragment.
@Suppress("LargeClass")
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

    // At-rest sender-authentication construction — byte-parity with Swift
    // `CloudVaultCrypto.signalAtRestSenderAuthVersion` / `...Domain`. Bump only on a breaking change.
    const val SIGNAL_AT_REST_SENDER_AUTH_VERSION: Int = 1
    const val SIGNAL_AT_REST_SENDER_AUTH_DOMAIN: String = "OpenBurnBar-Signal-AtRest-SenderAuth-v1"
    // HPKE `info` prefix the signed message embeds — byte-parity with Swift
    // `OpenBurnBarSignalAtRest.atRestInfoPrefix` and `CloudVaultCryptoSupport.atRestSeal`.
    const val SIGNAL_AT_REST_INFO_PREFIX: String = "OpenBurnBar-Signal-AtRest-v1|"
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

    fun sealBlob(plaintext: ByteArray, vaultKey: ByteArray, aadContext: CloudVaultAADContext? = null): CloudVaultBlobEnvelope {
        val nonce =
            ByteArray(GCM_NONCE_BYTES).apply {
                java.security.SecureRandom().nextBytes(this)
            }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(vaultKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        aadContext?.let { cipher.updateAAD(it.bytes) }
        return CloudVaultBlobEnvelope(
            schemaVersion = currentBlobEnvelopeSchemaVersion,
            algorithm = "AES-256-GCM",
            keyVersion = 1,
            plaintextSHA256 = null,
            plaintextHMAC = blobPlaintextHmac(plaintext, vaultKey),
            integrityHashVersion = blobIntegrityHashVersion,
            sealedBoxBase64 = CloudVaultCryptoSupport.encodeBase64(nonce + cipher.doFinal(plaintext)),
            aad = aadContext?.stringValue ?: BLOB_AAD_CONTEXT,
        )
    }

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
        senderIdentityKeyId: String,
        senderIdentityPrivateKey: ByteArray,
        senderIdentityPublicKey: ByteArray,
    ): CloudVaultSignalEnvelope {
        validateSignalRecipients(recipients)
        val senderPrivateKey = CloudVaultCryptoSupport.decodeSignalPrivateKey(senderIdentityPrivateKey)
        val senderPublicKeyB64 = CloudVaultCryptoSupport.encodeBase64(senderIdentityPublicKey)
        val contentKey = ByteArray(SIGNAL_AT_REST_CONTENT_KEY_LENGTH).apply { java.security.SecureRandom().nextBytes(this) }
        val canonicalAAD = CloudVaultCryptoSupport.bindingToAAD(binding.aadBinding)
        val nonce = ByteArray(GCM_NONCE_BYTES).apply { java.security.SecureRandom().nextBytes(this) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(contentKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        cipher.updateAAD(canonicalAAD.toByteArray(Charsets.UTF_8))
        val payloadCiphertext = nonce + cipher.doFinal(plaintext)
        val payloadCiphertextB64 = CloudVaultCryptoSupport.encodeBase64(payloadCiphertext)
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
        // Sender authentication: sign the envelope (binding via HPKE info + ciphertext + wraps)
        // with the writing device's identity private key. A malicious server holds only public
        // keys and cannot forge this signature.
        val signedMessage =
            senderAuthSignedMessage(
                info = "$SIGNAL_AT_REST_INFO_PREFIX$canonicalAAD",
                payloadCiphertextB64 = payloadCiphertextB64,
                wraps = wraps,
            )
        val signature = senderPrivateKey.calculateSignature(signedMessage)
        return CloudVaultSignalEnvelope(
            ciphertextLayer =
                CloudVaultSignalCiphertextLayer(
                    payloadCiphertextB64 = payloadCiphertextB64,
                    payloadAADLabel = signalPayloadAadLabel(canonicalAAD),
                    schemaVersion = SIGNAL_PAYLOAD_SCHEMA_VERSION,
                ),
            keyDelivery = CloudVaultSignalAtRestKeyDelivery(wraps = wraps),
            binding = binding,
            senderAuth =
                CloudVaultSignalSenderAuth(
                    senderIdentityKeyId = senderIdentityKeyId,
                    senderIdentityKeyB64 = senderPublicKeyB64,
                    signatureB64 = CloudVaultCryptoSupport.encodeBase64(signature),
                ),
        )
    }

    /**
     * Canonical bytes the sender signs and the reader verifies. Deterministic and byte-identical
     * across platforms (byte-parity with Swift `OpenBurnBarSignalAtRest.senderAuthSignedMessage`):
     * domain separator, then the HPKE `info` (which embeds the path binding → relocation guard),
     * then the ciphertext, then the recipient wraps so neither the content nor the recipient set
     * can be tampered without breaking the signature.
     *
     * Framing is LENGTH-PREFIXED (4-byte big-endian length per field), not delimiter-joined, so no
     * field value can inject a separator. Every string is NFC-normalized (matching `bindingToAAD`)
     * and wraps are ordered by the raw UTF-8 BYTES of the normalized `recipientIdentityKeyId` (not
     * Kotlin's locale/Unicode `String.<`), so the bytes are identical to the Swift side even for
     * non-ASCII device ids.
     */
    fun senderAuthSignedMessage(
        info: String,
        payloadCiphertextB64: String,
        wraps: List<CloudVaultSignalAtRestWrap>,
    ): ByteArray {
        fun normalizedBytes(value: String): ByteArray =
            java.text.Normalizer.normalize(value, java.text.Normalizer.Form.NFC).toByteArray(Charsets.UTF_8)
        val out = java.io.ByteArrayOutputStream()
        fun frame(value: String) {
            val bytes = normalizedBytes(value)
            out.write(uint32BigEndian(bytes.size))
            out.write(bytes)
        }
        frame(SIGNAL_AT_REST_SENDER_AUTH_DOMAIN)
        frame(info)
        frame(payloadCiphertextB64)
        val sorted =
            wraps.sortedWith { lhs, rhs ->
                compareByteArraysLexicographically(normalizedBytes(lhs.recipientIdentityKeyId), normalizedBytes(rhs.recipientIdentityKeyId))
            }
        out.write(uint32BigEndian(sorted.size))
        for (wrap in sorted) {
            frame(wrap.recipientIdentityKeyId)
            frame(wrap.sealedContentKeyB64)
        }
        return out.toByteArray()
    }

    fun openSignalPayload(
        envelope: CloudVaultSignalEnvelope,
        recipientIdentityKeyId: String,
        recipientIdentityPrivateKey: ByteArray,
        expectedBinding: CloudVaultSignalBinding,
        trustedSenderPublicKeys: Map<String, ByteArray>,
    ): ByteArray {
        require(envelope.signalEnvelopeFormatVersion == SIGNAL_ENVELOPE_FORMAT_VERSION) { "Invalid Signal envelope version" }
        require(envelope.mode == SIGNAL_AT_REST_MODE) { "Invalid Signal envelope mode" }
        require(envelope.relayEncryption == SIGNAL_AT_REST_ENCRYPTION) { "Invalid Signal envelope scheme" }
        require(envelope.keyDelivery.scheme == SIGNAL_AT_REST_ENCRYPTION) { "Invalid Signal key-delivery scheme" }
        require(envelope.keyDelivery.contentKeyLength == SIGNAL_AT_REST_CONTENT_KEY_LENGTH) { "Invalid Signal content-key length" }
        require(envelope.ciphertextLayer.schemaVersion == SIGNAL_PAYLOAD_SCHEMA_VERSION) { "Invalid Signal payload schema" }
        require(envelope.binding == expectedBinding) { "Signal envelope binding mismatch" }
        val canonicalAAD = CloudVaultCryptoSupport.bindingToAAD(expectedBinding.aadBinding)
        // Sender authentication (fail-closed): the envelope MUST carry a sender-auth block whose
        // sender is pinned-trusted and whose signature verifies — so a server-forged envelope
        // (the server holds only public keys) is rejected and the caller falls back to legacy.
        verifySenderAuth(envelope, canonicalAAD, trustedSenderPublicKeys)
        val wrap =
            envelope.keyDelivery.wraps.firstOrNull { it.recipientIdentityKeyId == recipientIdentityKeyId }
                ?: error("Missing Signal recipient wrap")
        val sealedContentKey = CloudVaultCryptoSupport.decodeBase64(wrap.sealedContentKeyB64)
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

    /**
     * Verify the at-rest envelope's sender-auth block fail-closed: present, pinned-trusted, and a
     * valid signature over the domain-separated binding+ciphertext+wraps. Throws a
     * [CloudVaultSignalSenderAuthException] (classified by [SignalAtRestFallbackPolicy]) on any failure.
     */
    @Suppress("ThrowsCount") // each fail-closed branch throws a DISTINCT classified exception the fallback policy needs.
    private fun verifySenderAuth(
        envelope: CloudVaultSignalEnvelope,
        canonicalAAD: String,
        trustedSenderPublicKeys: Map<String, ByteArray>,
    ) {
        val senderAuth = envelope.senderAuth ?: throw CloudVaultSignalSenderAuthException.SenderAuthMissing()
        val pinnedSenderKey =
            trustedSenderPublicKeys[senderAuth.senderIdentityKeyId]
                ?: throw CloudVaultSignalSenderAuthException.SenderNotTrusted(senderAuth.senderIdentityKeyId)
        val signedMessage =
            senderAuthSignedMessage(
                info = "$SIGNAL_AT_REST_INFO_PREFIX$canonicalAAD",
                payloadCiphertextB64 = envelope.ciphertextLayer.payloadCiphertextB64,
                wraps = envelope.keyDelivery.wraps,
            )
        val signatureValid =
            runCatching {
                val signatureBytes = CloudVaultCryptoSupport.decodeBase64(senderAuth.signatureB64)
                CloudVaultCryptoSupport.decodeSignalPublicKey(pinnedSenderKey).verifySignature(signedMessage, signatureBytes)
            }.getOrDefault(false)
        if (!signatureValid) throw CloudVaultSignalSenderAuthException.SenderSignatureInvalid()
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

    fun sealedTextMap(envelope: CloudVaultSealedText): Map<String, Any> =
        buildMap {
            envelope.schemaVersion?.let { put("schemaVersion", it) }
            put("algorithm", envelope.algorithm)
            put("keyVersion", envelope.keyVersion)
            put("nonce", envelope.nonce)
            put("ciphertext", envelope.ciphertext)
            put("tag", envelope.tag)
            envelope.aad?.let { put("aad", it) }
        }

    fun sealedTextFromMap(raw: Map<*, *>?): CloudVaultSealedText? {
        if (raw == null) return null
        return CloudVaultSealedText(
            schemaVersion = (raw["schemaVersion"] as? Number)?.toInt(),
            algorithm = raw["algorithm"] as? String ?: "AES-256-GCM",
            keyVersion = (raw["keyVersion"] as? Number)?.toInt() ?: 1,
            nonce = raw["nonce"] as? String ?: return null,
            ciphertext = raw["ciphertext"] as? String ?: return null,
            tag = raw["tag"] as? String ?: return null,
            aad = raw["aad"] as? String,
        )
    }

    fun blobEnvelopeMap(envelope: CloudVaultBlobEnvelope): Map<String, Any> =
        buildMap {
            put("schemaVersion", envelope.schemaVersion)
            put("algorithm", envelope.algorithm)
            put("keyVersion", envelope.keyVersion)
            envelope.plaintextSHA256?.let { put("plaintextSHA256", it) }
            envelope.plaintextHMAC?.let { put("plaintextHMAC", it) }
            envelope.integrityHashVersion?.let { put("integrityHashVersion", it) }
            put("sealedBoxBase64", envelope.sealedBoxBase64)
            envelope.aad?.let { put("aad", it) }
        }

    fun blobEnvelopeFromMap(raw: Map<*, *>?): CloudVaultBlobEnvelope? {
        if (raw == null) return null
        return CloudVaultBlobEnvelope(
            schemaVersion = (raw["schemaVersion"] as? Number)?.toInt() ?: return null,
            algorithm = raw["algorithm"] as? String ?: "AES-256-GCM",
            keyVersion = (raw["keyVersion"] as? Number)?.toInt() ?: 1,
            plaintextSHA256 = raw["plaintextSHA256"] as? String,
            plaintextHMAC = raw["plaintextHMAC"] as? String,
            integrityHashVersion = (raw["integrityHashVersion"] as? Number)?.toInt(),
            sealedBoxBase64 = raw["sealedBoxBase64"] as? String ?: return null,
            aad = raw["aad"] as? String,
        )
    }

    fun rewrapCloudVaultDocument(
        data: Map<String, Any?>,
        uid: String,
        collection: String,
        docID: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String = vaultKeyID(newKey),
        vaultGeneration: Int? = null,
        rotationJobId: String? = null,
    ): CloudVaultDocumentRewrapResult {
        require(vaultKeyID(newKey) == newVaultKeyID) { "New vault key id mismatch" }
        val updated = data.toMutableMap()
        val changedFields = mutableListOf<String>()

        for (field in data.keys.sorted()) {
            val raw = data[field] as? Map<*, *> ?: continue
            val context = CloudVaultAADContext(uid = uid, collection = collection, docID = docID, field = field)

            sealedPayloadFromMap(raw)?.let { envelope ->
                val plaintext = openPayloadForRewrap(envelope, oldKey, context)
                val resealed = sealPayload(plaintext, newKey, newVaultKeyID, context)
                updated[field] = sealedPayloadMap(resealed)
                applyVaultKeyCompanionUpdates(updated, field, newVaultKeyID)
                changedFields += field
                return@let
            } ?: sealedTextFromMap(raw)?.let { envelope ->
                val plaintext = openTextForRewrap(envelope, oldKey, context)
                val resealed = sealText(plaintext, newKey, context)
                updated[field] = sealedTextMap(resealed)
                changedFields += field
                return@let
            } ?: blobEnvelopeFromMap(raw)?.let { envelope ->
                val plaintext = openBlobForRewrap(envelope, oldKey, context)
                val resealed = sealBlob(plaintext, newKey, context)
                updated[field] = blobEnvelopeMap(resealed)
                changedFields += field
            }
        }

        if (changedFields.isNotEmpty()) {
            vaultGeneration?.let { updated["vaultGeneration"] = it }
            rotationJobId?.let { updated["rewrapJobId"] = it }
        }

        return CloudVaultDocumentRewrapResult(updated.toMap(), changedFields)
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
        ).let { base ->
            // Key order is map-insensitive on the wire; the senderAuth keys mirror the Swift
            // Codable property names so a Swift reader decodes the Android-sealed block.
            envelope.senderAuth?.let { senderAuth ->
                base +
                    ("senderAuth" to
                        mapOf(
                            "senderIdentityKeyId" to senderAuth.senderIdentityKeyId,
                            "senderIdentityKeyB64" to senderAuth.senderIdentityKeyB64,
                            "signatureB64" to senderAuth.signatureB64,
                            "signatureVersion" to senderAuth.signatureVersion,
                        ))
            } ?: base
        }

    fun signalEnvelopeFromMap(raw: Map<*, *>?): CloudVaultSignalEnvelope? {
        val parts = signalEnvelopeParts(raw) ?: return null
        val header = signalEnvelopeHeader(raw) ?: return null
        val ciphertextLayer = signalCiphertextLayer(parts.ciphertextLayer) ?: return null
        val keyDelivery = signalKeyDelivery(parts.keyDelivery, parts.wraps) ?: return null
        val binding = signalBinding(parts.binding) ?: return null
        return CloudVaultSignalEnvelope(
            signalEnvelopeFormatVersion = header.formatVersion,
            mode = header.mode,
            relayEncryption = header.relayEncryption,
            ciphertextLayer = ciphertextLayer,
            keyDelivery = keyDelivery,
            binding = binding,
            senderAuth = signalSenderAuth(raw?.get("senderAuth") as? Map<*, *>),
        )
    }

    private fun signalSenderAuth(raw: Map<*, *>?): CloudVaultSignalSenderAuth? {
        if (raw == null) return null
        return CloudVaultSignalSenderAuth(
            senderIdentityKeyId = signalString(raw, "senderIdentityKeyId") ?: return null,
            senderIdentityKeyB64 = signalString(raw, "senderIdentityKeyB64") ?: return null,
            signatureB64 = signalString(raw, "signatureB64") ?: return null,
            signatureVersion = signalInt(raw, "signatureVersion") ?: SIGNAL_AT_REST_SENDER_AUTH_VERSION,
        )
    }

    private data class SignalEnvelopeHeader(
        val formatVersion: Int,
        val mode: String,
        val relayEncryption: String,
    )

    private data class SignalEnvelopeParts(
        val ciphertextLayer: Map<*, *>,
        val keyDelivery: Map<*, *>,
        val binding: Map<*, *>,
        val wraps: List<CloudVaultSignalAtRestWrap>,
    )

    private fun signalEnvelopeParts(raw: Map<*, *>?): SignalEnvelopeParts? {
        val ciphertextLayer = raw?.get("ciphertextLayer") as? Map<*, *> ?: return null
        val keyDelivery = raw["keyDelivery"] as? Map<*, *> ?: return null
        val binding = raw["binding"] as? Map<*, *> ?: return null
        val wraps =
            (keyDelivery["wraps"] as? List<*>)?.map { signalWrapFromMap(it) ?: return null }
                ?: return null
        return SignalEnvelopeParts(ciphertextLayer, keyDelivery, binding, wraps)
    }

    private fun signalEnvelopeHeader(raw: Map<*, *>?): SignalEnvelopeHeader? {
        return SignalEnvelopeHeader(
            formatVersion = signalInt(raw, "signalEnvelopeFormatVersion") ?: return null,
            mode = signalString(raw, "mode") ?: return null,
            relayEncryption = signalString(raw, "relayEncryption") ?: return null,
        )
    }

    private fun signalCiphertextLayer(raw: Map<*, *>): CloudVaultSignalCiphertextLayer? {
        return CloudVaultSignalCiphertextLayer(
            payloadCiphertextB64 = signalString(raw, "payloadCiphertextB64") ?: return null,
            payloadAADLabel = signalString(raw, "payloadAADLabel") ?: return null,
            schemaVersion = signalInt(raw, "schemaVersion") ?: return null,
        )
    }

    private fun signalKeyDelivery(
        raw: Map<*, *>,
        wraps: List<CloudVaultSignalAtRestWrap>,
    ): CloudVaultSignalAtRestKeyDelivery? {
        return CloudVaultSignalAtRestKeyDelivery(
            scheme = signalString(raw, "scheme") ?: return null,
            wraps = wraps,
            contentKeyLength = signalInt(raw, "contentKeyLength") ?: return null,
        )
    }

    private fun signalBinding(raw: Map<*, *>): CloudVaultSignalBinding? {
        return CloudVaultSignalBinding(
            uid = signalString(raw, "uid") ?: return null,
            scope = signalString(raw, "scope") ?: return null,
            collection = signalString(raw, "collection") ?: return null,
            docId = signalString(raw, "docId") ?: return null,
            field = signalString(raw, "field") ?: return null,
            mode = signalString(raw, "mode") ?: return null,
            formatVersion = signalInt(raw, "formatVersion") ?: return null,
        )
    }

    private fun signalWrapFromMap(raw: Any?): CloudVaultSignalAtRestWrap? {
        val wrap = raw as? Map<*, *> ?: return null
        return CloudVaultSignalAtRestWrap(
            recipientKind = signalString(wrap, "recipientKind") ?: return null,
            recipientIdentityKeyId = signalString(wrap, "recipientIdentityKeyId") ?: return null,
            recipientIdentityKeyB64 = signalString(wrap, "recipientIdentityKeyB64") ?: return null,
            sealedContentKeyB64 = signalString(wrap, "sealedContentKeyB64") ?: return null,
        )
    }

    private fun signalString(raw: Map<*, *>?, key: String): String? = raw?.get(key) as? String

    private fun signalInt(raw: Map<*, *>?, key: String): Int? = (raw?.get(key) as? Number)?.toInt()

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

    private fun openTextForRewrap(
        envelope: CloudVaultSealedText,
        vaultKey: ByteArray,
        aadContext: CloudVaultAADContext,
    ): String =
        if ((envelope.schemaVersion ?: 1) >= currentSealedTextSchemaVersion) {
            openText(envelope, vaultKey, aadContext)
        } else {
            openText(envelope, vaultKey)
        }

    private fun openBlobForRewrap(
        envelope: CloudVaultBlobEnvelope,
        vaultKey: ByteArray,
        aadContext: CloudVaultAADContext,
    ): ByteArray =
        if (envelope.schemaVersion >= currentBlobEnvelopeSchemaVersion && envelope.aad != BLOB_AAD_CONTEXT) {
            openBlob(envelope, vaultKey, aadContext)
        } else {
            openBlob(envelope, vaultKey)
        }

    private fun openPayloadForRewrap(
        envelope: CloudVaultSealedPayload,
        vaultKey: ByteArray,
        aadContext: CloudVaultAADContext,
    ): ByteArray =
        if (envelope.schemaVersion >= currentSealedPayloadSchemaVersion && envelope.aad != SEALED_PAYLOAD_AAD_CONTEXT) {
            openPayload(envelope, vaultKey, aadContext)
        } else {
            openPayload(envelope, vaultKey)
        }

    private fun applyVaultKeyCompanionUpdates(
        data: MutableMap<String, Any?>,
        field: String,
        newVaultKeyID: String,
    ) {
        when (field) {
            "sealedPayload", "sealedReplyPayload" -> if (data.containsKey("vaultKeyID")) data["vaultKeyID"] = newVaultKeyID
            "sealedStatePayload" -> if (data.containsKey("sealedStateVaultKeyID")) data["sealedStateVaultKeyID"] = newVaultKeyID
        }
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

    /** Fresh 32-byte vault key — the Android mirror of Swift `CloudVaultCrypto.generateVaultKey()`. */
    fun generateVaultKey(): ByteArray = ByteArray(SHA256_DIGEST_BYTES).apply { java.security.SecureRandom().nextBytes(this) }

    /**
     * Wrap a 32-byte vault key to a recipient's P-256 escrow public key — the exact inverse of
     * [unwrapVaultKey] and the Android mirror of Swift `CloudVaultCrypto.wrapVaultKey`. Output is the
     * ephemeral public key (X9.63, 65 bytes) followed by the AES-GCM combined box (nonce ‖ ct ‖ tag),
     * byte-compatible so any platform's [unwrapVaultKey] opens it. Used by the RR-5 revocation
     * rotation chain to wrap the next vault key to each surviving trusted device.
     */
    fun wrapVaultKey(keyData: ByteArray, recipientPublicKey: ByteArray): ByteArray {
        require(keyData.size == SHA256_DIGEST_BYTES) { "Invalid vault key length" }
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val ephemeral = generator.generateKeyPair()
        val recipientKey =
            CloudVaultCryptoSupport.publicKeyFromX963(recipientPublicKey, (ephemeral.public as ECPublicKey).params)
        val sharedSecret =
            KeyAgreement.getInstance("ECDH").run {
                init(ephemeral.private)
                doPhase(recipientKey, true)
                generateSecret()
            }
        val wrappingKey = CloudVaultCryptoSearch.hkdfSha256(sharedSecret, ByteArray(0), WRAP_INFO.toByteArray(), SHA256_DIGEST_BYTES)
        val nonce = ByteArray(GCM_NONCE_BYTES).apply { java.security.SecureRandom().nextBytes(this) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        val combined = nonce + cipher.doFinal(keyData)
        return publicKeyX963(ephemeral.public) + combined
    }

    fun publicKeyX963(publicKey: PublicKey): ByteArray {
        val ec =
            publicKey as? ECPublicKey
                ?: error("X9.63 encoding requires an EC public key")
        return byteArrayOf(UNCOMPRESSED_POINT_PREFIX.toByte()) + cloudVaultFixed32(ec.w.affineX) + cloudVaultFixed32(ec.w.affineY)
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

    /** 4-byte big-endian length prefix, matching the Swift `UInt32(...).bigEndian` framing. */
    private fun uint32BigEndian(value: Int): ByteArray =
        byteArrayOf(
            (value ushr 24 and BYTE_MASK).toByte(),
            (value ushr 16 and BYTE_MASK).toByte(),
            (value ushr 8 and BYTE_MASK).toByte(),
            (value and BYTE_MASK).toByte(),
        )

    /** Unsigned byte-wise lexicographic compare, matching Swift's `lexicographicallyPrecedes` on UTF-8. */
    private fun compareByteArraysLexicographically(lhs: ByteArray, rhs: ByteArray): Int {
        val min = minOf(lhs.size, rhs.size)
        for (index in 0 until min) {
            val diff = (lhs[index].toInt() and BYTE_MASK) - (rhs[index].toInt() and BYTE_MASK)
            if (diff != 0) return diff
        }
        return lhs.size - rhs.size
    }
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
    private const val VAULT_KEY_WRAPPER_QUERY_LIMIT = 5

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
                .limit(VAULT_KEY_WRAPPER_QUERY_LIMIT.toLong())
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

    /**
     * RR-5 — persist the rotated vault key locally after a successful `rotateCloudVaultKey`, the
     * Android mirror of Swift `CloudVaultKeyStore().saveKey`. So the next read resolves the new key
     * directly instead of unwrapping the survivor wrapper again.
     */
    fun saveKey(uid: String, key: ByteArray) = saveLocalKey(uid, key)
}

internal object AndroidLocalSecretBox {
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
