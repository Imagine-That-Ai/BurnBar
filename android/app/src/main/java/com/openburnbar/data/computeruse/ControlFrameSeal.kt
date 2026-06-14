package com.openburnbar.data.computeruse

import com.openburnbar.data.hermes.relay.HermesRelayCryptoHkdf
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Mirror of the Swift `ControlFrameSeal.SealError` enum: every header/AEAD
 * failure surfaces as one of these, never as a raw JCA exception.
 */
sealed class ControlFrameSealException(message: String, cause: Throwable? = null) :
    GeneralSecurityException(message, cause) {
    class EnvelopeTooShort : ControlFrameSealException("control frame envelope too short")
    class InvalidMagic : ControlFrameSealException("control frame envelope magic mismatch")
    class UnsupportedVersion(val version: Int) :
        ControlFrameSealException("unsupported control frame seal version $version")
    class OpenFailed(cause: Throwable? = null) :
        ControlFrameSealException("control frame envelope failed to open", cause)
}

/**
 * F10 — confidentiality seal for `control.*` iroh frames. 1:1 Kotlin port of
 * `ControlFrameSeal` (Swift
 * `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ControlFrameSeal.swift`).
 *
 * Wire invariant — MUST stay byte-identical to the Swift implementation:
 *
 *     envelope = "OBCFS1"(6) ‖ 0x01 ‖ AES-256-GCM combined (nonce12 ‖ ct ‖ tag16)
 *     AAD      = "OpenBurnBar-ControlFrameSeal-v1|" ‖ peerNodeId ‖ 0x7C ‖ frameType
 *     key      = HKDF-SHA256(hpkeSessionKey, salt, info "OpenBurnBar-ControlFrameSeal-v1", 32)
 *
 * Cross-language byte agreement is pinned by the frozen Swift-sealed KAT at
 * `src/test/resources/control-seal/ControlFrameSealVector.json`
 * ([ControlFrameSealVectorTest]); regenerate it only through the Swift emitter
 * (`BURNBAR_EMIT_AEAD_VECTORS=1 swift test --filter ControlFrameSealVectorTests`).
 *
 * Sealing is gated by [ControlFrameSealNegotiation] so paired clients that
 * predate F10 keep exchanging signed-but-unsealed control frames over the
 * iroh transport seal until both sides advertise support.
 */
object ControlFrameSeal {
    /** `OBCFS1` — OpenBurnBar Control Frame Seal v1. */
    val MAGIC: ByteArray = byteArrayOf(0x4F, 0x42, 0x43, 0x46, 0x53, 0x31)
    const val VERSION: Byte = 0x01
    const val DEFAULT_INFO = "OpenBurnBar-ControlFrameSeal-v1"

    private const val AAD_PREFIX = "OpenBurnBar-ControlFrameSeal-v1|"
    private const val PIPE: Byte = 0x7C
    private const val KEY_BYTES = 32
    private const val NONCE_BYTES = 12
    private const val TAG_BYTES = 16
    private const val TAG_BITS = TAG_BYTES * Byte.SIZE_BITS

    /** magic(6) + version(1). */
    private const val HEADER_BYTES = 7
    private const val BYTE_MASK = 0xFF
    private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"

    private val secureRandom = SecureRandom()

    /**
     * Derive the control-seal key from the HPKE session key (the per-request
     * `keyData` the authenticated-request opener returns), domain-separated
     * from any other use of that key — byte-identical to CryptoKit
     * `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:32)`.
     */
    fun deriveSessionKey(hpkeSessionKey: ByteArray, salt: ByteArray, info: String = DEFAULT_INFO): ByteArray {
        val prk = HermesRelayCryptoHkdf.hkdfExtract(salt = salt, ikm = hpkeSessionKey)
        return HermesRelayCryptoHkdf.hkdfExpand(prk = prk, info = info.toByteArray(Charsets.UTF_8), length = KEY_BYTES)
    }

    /** Domain-separated AAD binding the frame to its controller and type. */
    fun aad(peerNodeId: String, frameType: String): ByteArray {
        val prefix = AAD_PREFIX.toByteArray(Charsets.UTF_8)
        val peerBytes = peerNodeId.toByteArray(Charsets.UTF_8)
        val typeBytes = frameType.toByteArray(Charsets.UTF_8)
        val out = ByteArray(prefix.size + peerBytes.size + 1 + typeBytes.size)
        prefix.copyInto(out)
        peerBytes.copyInto(out, destinationOffset = prefix.size)
        out[prefix.size + peerBytes.size] = PIPE
        typeBytes.copyInto(out, destinationOffset = prefix.size + peerBytes.size + 1)
        return out
    }

    fun isSealedEnvelope(envelope: ByteArray): Boolean {
        if (envelope.size < MAGIC.size) return false
        return MAGIC.indices.all { envelope[it] == MAGIC[it] }
    }

    /** Seal control JSON. Returns `magic ‖ version ‖ AES-GCM combined`. */
    fun seal(plaintext: ByteArray, key: ByteArray, peerNodeId: String, frameType: String): ByteArray {
        require(key.size == KEY_BYTES) { "control frame session key must be 32 bytes" }
        val nonce = ByteArray(NONCE_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad(peerNodeId, frameType))
        val ciphertextAndTag = cipher.doFinal(plaintext)
        return MAGIC + VERSION + nonce + ciphertextAndTag
    }

    /**
     * Open a sealed control frame, verifying it belongs to this exact
     * controller and frame type. Any AAD mismatch or a tampered ciphertext
     * throws [ControlFrameSealException.OpenFailed].
     */
    fun open(envelope: ByteArray, key: ByteArray, peerNodeId: String, frameType: String): ByteArray {
        require(key.size == KEY_BYTES) { "control frame session key must be 32 bytes" }
        headerFailure(envelope)?.let { throw it }
        val nonce = envelope.copyOfRange(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES)
        val body = envelope.copyOfRange(HEADER_BYTES + NONCE_BYTES, envelope.size)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad(peerNodeId, frameType))
        return try {
            cipher.doFinal(body)
        } catch (cause: GeneralSecurityException) {
            throw ControlFrameSealException.OpenFailed(cause)
        }
    }

    /** Same check order as the Swift opener: length, then magic, then version. */
    private fun headerFailure(envelope: ByteArray): ControlFrameSealException? {
        if (envelope.size <= HEADER_BYTES + NONCE_BYTES + TAG_BYTES) {
            return ControlFrameSealException.EnvelopeTooShort()
        }
        if (!isSealedEnvelope(envelope)) return ControlFrameSealException.InvalidMagic()
        val version = envelope[MAGIC.size]
        if (version != VERSION) {
            return ControlFrameSealException.UnsupportedVersion(version.toInt() and BYTE_MASK)
        }
        return null
    }
}

/**
 * F10 capability gate — 1:1 port of the Swift `ControlFrameSealNegotiation`.
 * Both peers must advertise control-seal support before either seals; absent
 * ⇒ false ⇒ signed-but-unsealed control frames continue over the iroh
 * transport seal.
 */
object ControlFrameSealNegotiation {
    const val CAPABILITY = "control_seal_v1"

    /** Same default-off ramp key the iOS client reads (`ControlFrameSealNegotiation.remoteConfigKey`). */
    const val REMOTE_CONFIG_KEY = "computer_use_control_seal_enabled"

    fun resolveSealingEnabled(localSupports: Boolean, remoteSupports: Boolean): Boolean = localSupports && remoteSupports
}
