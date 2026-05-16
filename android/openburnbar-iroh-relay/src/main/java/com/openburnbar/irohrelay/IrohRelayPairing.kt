package com.openburnbar.irohrelay

import com.google.crypto.tink.KeysetHandle
import com.google.crypto.tink.PublicKeyVerify
import com.google.crypto.tink.signature.Ed25519Parameters
import com.google.crypto.tink.signature.Ed25519PublicKey
import com.google.crypto.tink.signature.SignatureConfig
import com.google.crypto.tink.util.Bytes
import java.util.Base64
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Pairing record published by the Mac host to
 * `users/{uid}/iroh_pairing/{connectionId}`. Android reads it, verifies
 * the Ed25519 signature, then dials the iroh NodeAddr.
 *
 * The signed payload is the same canonical string the Swift signer
 * emits — version-prefixed, pipe-delimited, ASCII-safe:
 *
 *   "openburnbar.iroh.pairing.v1|<uid>|<connectionId>|<nodeId>|<relayURL>|<directAddresses>|<publishedAtMs>"
 *
 * which is then UTF-8 encoded and fed straight into Ed25519. Identical
 * across Swift, Kotlin (this file), and TypeScript (Cloud Functions).
 */
@Serializable
data class IrohPairingRecord(
    val uid: String,
    val connectionId: String,
    val nodeId: String,
    val relayURL: String? = null,
    val directAddresses: List<String> = emptyList(),
    val publishedAtMillis: Long,
    val protocolVersion: Int = IrohRelayProtocol.FRAME_PROTOCOL_VERSION,
    /** Base64 (Standard, no wrap) of the 64-byte Ed25519 signature. */
    val signature: String,
) {
    fun dialTarget(): IrohDialTarget =
        IrohDialTarget(nodeId = nodeId, relayURL = relayURL, directAddresses = directAddresses)

    companion object {
        internal fun normalizedRelayURL(relayURL: String?): String? {
            val trimmed = relayURL?.trim().orEmpty()
            return if (trimmed.isEmpty()) null else trimmed
        }

        internal fun normalizedDirectAddresses(directAddresses: List<String>): List<String> =
            directAddresses
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinct()
                .sorted()
    }
}

sealed class IrohPairingError(message: String) : RuntimeException(message) {
    object InvalidPublicKey : IrohPairingError("invalid public key")
    object InvalidSignature : IrohPairingError("invalid signature")
    object Expired : IrohPairingError("pairing record expired")
    data class UnsupportedProtocolVersion(val version: Int) : IrohPairingError("unsupported protocol version: $version")
    object Malformed : IrohPairingError("malformed pairing record")
}

object IrohPairingFreshness {
    /** Reject records older than 24h. Matches Swift `maximumAgeSeconds`. */
    const val MAXIMUM_AGE_MILLIS: Long = 24L * 60 * 60 * 1000
}

object IrohPairingSignature {
    init {
        // Idempotent — registers Tink Ed25519 algorithms on the first
        // call. The default config is fine for verify-only use.
        SignatureConfig.register()
    }

    fun canonicalPayload(
        uid: String,
        connectionId: String,
        nodeId: String,
        relayURL: String?,
        directAddresses: List<String>,
        publishedAtMillis: Long,
        protocolVersion: Int,
    ): ByteArray {
        val normalizedRelay = IrohPairingRecord.normalizedRelayURL(relayURL) ?: ""
        val normalizedAddresses =
            IrohPairingRecord.normalizedDirectAddresses(directAddresses).joinToString(",")
        val payload =
            "openburnbar.iroh.pairing.v${protocolVersion}|" +
                "${uid}|${connectionId}|${nodeId}|${normalizedRelay}|${normalizedAddresses}|${publishedAtMillis}"
        return payload.toByteArray(Charsets.UTF_8)
    }

    /**
     * Verify the pairing record. Throws an `IrohPairingError` if the
     * record fails any check. Returns Unit on success.
     */
    fun verify(
        record: IrohPairingRecord,
        publicKey: ByteArray,
        nowMillis: Long = System.currentTimeMillis(),
        maximumAgeMillis: Long = IrohPairingFreshness.MAXIMUM_AGE_MILLIS,
    ) {
        if (record.protocolVersion != IrohRelayProtocol.FRAME_PROTOCOL_VERSION) {
            throw IrohPairingError.UnsupportedProtocolVersion(record.protocolVersion)
        }
        val signatureBytes = try {
            Base64.getDecoder().decode(record.signature)
        } catch (_: IllegalArgumentException) {
            throw IrohPairingError.Malformed
        }
        if (publicKey.size != 32) throw IrohPairingError.InvalidPublicKey

        val payload = canonicalPayload(
            uid = record.uid,
            connectionId = record.connectionId,
            nodeId = record.nodeId,
            relayURL = record.relayURL,
            directAddresses = record.directAddresses,
            publishedAtMillis = record.publishedAtMillis,
            protocolVersion = record.protocolVersion,
        )

        if (!Ed25519Verifier.verify(publicKey, signatureBytes, payload)) {
            throw IrohPairingError.InvalidSignature
        }

        val ageMillis = nowMillis - record.publishedAtMillis
        if (ageMillis > maximumAgeMillis) throw IrohPairingError.Expired
    }
}

/**
 * Minimal Ed25519 verifier wrapper over Tink. We do NOT expose a signer
 * intentionally — Android is verify-only (the Mac signs).
 */
internal object Ed25519Verifier {
    fun verify(publicKeyRaw: ByteArray, signature: ByteArray, payload: ByteArray): Boolean {
        val variant = Ed25519Parameters.Variant.NO_PREFIX
        val pubKey = Ed25519PublicKey.create(
            variant,
            Bytes.copyFrom(publicKeyRaw),
            /* idRequirement = */ null,
        )
        val handle = KeysetHandle.newBuilder()
            .addEntry(
                KeysetHandle.importKey(pubKey)
                    .withRandomId()
                    .makePrimary()
            )
            .build()
        val verifier = handle.getPrimitive(PublicKeyVerify::class.java)
        return try {
            verifier.verify(signature, payload)
            true
        } catch (_: java.security.GeneralSecurityException) {
            false
        }
    }
}
