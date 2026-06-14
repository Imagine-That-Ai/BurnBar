package com.openburnbar.data.media

import com.openburnbar.data.hermes.relay.HermesRelayCryptoHkdf
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Mirror of the Swift `MediaFrameAEAD.SealError` enum: every header/AEAD
 * failure surfaces as one of these, never as a raw JCA exception.
 */
sealed class MediaFrameAeadSealException(message: String, cause: Throwable? = null) :
    GeneralSecurityException(message, cause) {
    class EnvelopeTooShort : MediaFrameAeadSealException("media frame envelope too short")
    class InvalidMagic : MediaFrameAeadSealException("media frame envelope magic mismatch")
    class UnsupportedVersion(val version: Int) :
        MediaFrameAeadSealException("unsupported media frame seal version $version")
    class OpenFailed(cause: Throwable? = null) :
        MediaFrameAeadSealException("media frame envelope failed to open", cause)
}

/**
 * F7 — per-frame AEAD for media/screen frames. 1:1 Kotlin port of
 * `MediaFrameAEAD` (Swift
 * `OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFrameAEAD.swift`).
 *
 * Wire invariant — MUST stay byte-identical to the Swift implementation:
 *
 *     envelope = "OBMFA1"(6) ‖ 0x01 ‖ AES-256-GCM combined (nonce12 ‖ ct ‖ tag16)
 *     AAD      = "OpenBurnBar-MediaFrameAEAD-v1|" ‖ streamClass ‖ 0x7C ‖
 *                u8(kind) ‖ u32BE(gopID) ‖ u32BE(frameIndex)
 *     key      = HKDF-SHA256(sharedSecret, salt, info "OpenBurnBar-MediaFrameAEAD-v1", 32)
 *
 * Cross-language byte agreement is pinned by the frozen Swift-sealed KAT at
 * `src/test/resources/media-aead/MediaFrameAEADVector.json`
 * ([MediaFrameAeadVectorTest]); regenerate it only through the Swift emitter
 * (`BURNBAR_EMIT_AEAD_VECTORS=1 swift test --filter MediaFrameAEADVectorTests`).
 *
 * Sealing is gated by [MediaFrameAeadNegotiation]: both peers must advertise
 * support before either side emits sealed frames, so paired clients that
 * predate F7 keep interoperating over the iroh transport seal.
 */
object MediaFrameAead {
    /** `OBMFA1` — OpenBurnBar Media Frame AEAD v1. */
    val MAGIC: ByteArray = byteArrayOf(0x4F, 0x42, 0x4D, 0x46, 0x41, 0x31)
    const val VERSION: Byte = 0x01
    const val DEFAULT_INFO = "OpenBurnBar-MediaFrameAEAD-v1"

    private const val AAD_PREFIX = "OpenBurnBar-MediaFrameAEAD-v1|"
    private const val PIPE: Byte = 0x7C
    private const val KEY_BYTES = 32
    private const val NONCE_BYTES = 12
    private const val TAG_BYTES = 16
    private const val TAG_BITS = TAG_BYTES * Byte.SIZE_BITS

    /** magic(6) + version(1) + AES-GCM combined(nonce 12 + tag 16 + ciphertext). */
    private const val HEADER_BYTES = 7
    private const val U32_BYTES = 4
    private const val BYTE_MASK = 0xFF
    private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"

    private val secureRandom = SecureRandom()

    /**
     * Derive the 32-byte media session key from the paired peers' shared
     * secret — byte-identical to CryptoKit
     * `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:32)`.
     */
    fun deriveSessionKey(sharedSecret: ByteArray, salt: ByteArray, info: String = DEFAULT_INFO): ByteArray {
        val prk = HermesRelayCryptoHkdf.hkdfExtract(salt = salt, ikm = sharedSecret)
        return HermesRelayCryptoHkdf.hkdfExpand(prk = prk, info = info.toByteArray(Charsets.UTF_8), length = KEY_BYTES)
    }

    /**
     * Domain-separated AAD binding the frame's identity so a sealed frame is
     * valid only in its original stream and position.
     */
    fun aad(streamClass: String, kind: UByte, gopID: UInt, frameIndex: UInt): ByteArray {
        val prefix = AAD_PREFIX.toByteArray(Charsets.UTF_8)
        val streamClassBytes = streamClass.toByteArray(Charsets.UTF_8)
        // ByteBuffer is big-endian by default, matching the Swift u32BE lanes.
        val buffer = ByteBuffer.allocate(prefix.size + streamClassBytes.size + 2 + 2 * U32_BYTES)
        buffer.put(prefix)
        buffer.put(streamClassBytes)
        buffer.put(PIPE)
        buffer.put(kind.toByte())
        buffer.putInt(gopID.toInt())
        buffer.putInt(frameIndex.toInt())
        return buffer.array()
    }

    fun isSealedEnvelope(envelope: ByteArray): Boolean {
        if (envelope.size < MAGIC.size) return false
        return MAGIC.indices.all { envelope[it] == MAGIC[it] }
    }

    /** Seal an encoded media frame payload. Returns `magic ‖ version ‖ AES-GCM combined`. */
    fun seal(plaintext: ByteArray, key: ByteArray, streamClass: String, kind: UByte, gopID: UInt, frameIndex: UInt): ByteArray {
        require(key.size == KEY_BYTES) { "media frame session key must be 32 bytes" }
        val nonce = ByteArray(NONCE_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad(streamClass, kind, gopID, frameIndex))
        val ciphertextAndTag = cipher.doFinal(plaintext)
        return MAGIC + VERSION + nonce + ciphertextAndTag
    }

    /**
     * Open a sealed media frame, verifying it belongs to this exact stream and
     * position. Any AAD mismatch (wrong stream class, kind, or index) or a
     * tampered ciphertext throws [MediaFrameAeadSealException.OpenFailed].
     */
    fun open(envelope: ByteArray, key: ByteArray, streamClass: String, kind: UByte, gopID: UInt, frameIndex: UInt): ByteArray {
        require(key.size == KEY_BYTES) { "media frame session key must be 32 bytes" }
        headerFailure(envelope)?.let { throw it }
        val nonce = envelope.copyOfRange(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES)
        val body = envelope.copyOfRange(HEADER_BYTES + NONCE_BYTES, envelope.size)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad(streamClass, kind, gopID, frameIndex))
        return try {
            cipher.doFinal(body)
        } catch (cause: GeneralSecurityException) {
            throw MediaFrameAeadSealException.OpenFailed(cause)
        }
    }

    /** Same check order as the Swift opener: length, then magic, then version. */
    private fun headerFailure(envelope: ByteArray): MediaFrameAeadSealException? {
        if (envelope.size <= HEADER_BYTES + NONCE_BYTES + TAG_BYTES) {
            return MediaFrameAeadSealException.EnvelopeTooShort()
        }
        if (!isSealedEnvelope(envelope)) return MediaFrameAeadSealException.InvalidMagic()
        val version = envelope[MAGIC.size]
        if (version != VERSION) {
            return MediaFrameAeadSealException.UnsupportedVersion(version.toInt() and BYTE_MASK)
        }
        return null
    }
}

/**
 * F7 capability gate — 1:1 port of the Swift `MediaFrameAeadNegotiation`.
 * Both peers must advertise media-frame AEAD support before either seals;
 * absent ⇒ false ⇒ unsealed frames continue over the iroh transport seal.
 */
object MediaFrameAeadNegotiation {
    const val CAPABILITY = "media_frame_aead_v1"

    /** Same default-off ramp key the iOS client reads (`MediaFrameAeadNegotiation.remoteConfigKey`). */
    const val REMOTE_CONFIG_KEY = "computer_use_media_frame_aead_enabled"

    /** Seal only when BOTH peers support it. */
    fun resolveSealingEnabled(localSupports: Boolean, remoteSupports: Boolean): Boolean = localSupports && remoteSupports
}
