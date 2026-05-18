package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Sign
import com.google.crypto.tink.subtle.Ed25519Sign.KeyPair
import com.google.crypto.tink.subtle.Ed25519Verify
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

enum class PhoneControlIntentKind(val wireValue: String) {
    TAP("tap"),
    DRAG_START("drag_start"),
    DRAG_MOVE("drag_move"),
    DRAG_END("drag_end"),
    TYPE("type"),
    SHORTCUT("shortcut"),
    SCROLL("scroll"),
    PANIC("panic"),
}

data class PhoneControlIntent(
    val kind: PhoneControlIntentKind,
    val normalizedX: Double? = null,
    val normalizedY: Double? = null,
    val normalizedX2: Double? = null,
    val normalizedY2: Double? = null,
    val text: String? = null,
    val key: String? = null,
    val modifiers: List<String>? = null,
)

data class PhoneControlAuthorityEnvelope(
    val peerNodeId: String,
    val counter: Long,
    val timestampMillis: Long,
    val intentHashBlake3: String,
    val signatureEd25519: String,
) {
    /**
     * Swift's default `Date` JSON representation is seconds since the
     * 2001-01-01 reference date, not Unix seconds. Use this value for the
     * `timestamp` field when encoding a Mac-bound relay frame.
     */
    val swiftDateReferenceSeconds: Double
        get() = (timestampMillis.toDouble() / 1000.0) - SWIFT_REFERENCE_TO_UNIX_SECONDS

    companion object {
        private const val SWIFT_REFERENCE_TO_UNIX_SECONDS = 978_307_200.0
    }
}

sealed class PhoneControlVerifyError(message: String) : RuntimeException(message) {
    object InvalidPublicKey : PhoneControlVerifyError("invalid public key")
    object InvalidSignature : PhoneControlVerifyError("invalid signature")
    object IntentHashMismatch : PhoneControlVerifyError("intent hash mismatch")
    data class StaleTimestamp(val skewMillis: Long) :
        PhoneControlVerifyError("stale timestamp: ${skewMillis}ms")

    data class CounterReplay(val lastSeen: Long, val attempted: Long) :
        PhoneControlVerifyError("counter replay: lastSeen=$lastSeen attempted=$attempted")
}

/**
 * Android mirror of `ComputerUsePhoneControlSigner`.
 *
 * Signed bytes are:
 *
 *   UTF8(intentHashHex) || u64BE(counter) || i64BE(timestampMillis)
 *
 * `intentHashBlake3` keeps the plan's field name, but v1 uses SHA-256
 * to match the Swift implementation.
 */
object PhoneControlSigner {
    private val random = SecureRandom()

    fun newPrivateKeySeed(): ByteArray =
        ByteArray(32).also { random.nextBytes(it) }

    fun publicKey(privateKeySeed: ByteArray): ByteArray {
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        return KeyPair.newKeyPairFromSeed(privateKeySeed).publicKey
    }

    fun canonicalIntentHashHex(intent: PhoneControlIntent): String =
        sha256Hex(canonicalIntentJson(intent).toByteArray(Charsets.UTF_8))

    fun signablePayload(
        intentHashHex: String,
        counter: Long,
        timestampMillis: Long,
    ): ByteArray {
        require(counter >= 0) { "counter must be non-negative" }
        val hashBytes = intentHashHex.toByteArray(Charsets.UTF_8)
        val suffix = ByteBuffer.allocate(16)
            .order(ByteOrder.BIG_ENDIAN)
            .putLong(counter)
            .putLong(timestampMillis)
            .array()
        return hashBytes + suffix
    }

    fun sign(
        intent: PhoneControlIntent,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        val intentHash = canonicalIntentHashHex(intent)
        val payload = signablePayload(intentHash, counter, timestampMillis)
        val signature = Ed25519Sign(privateKeySeed).sign(payload)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = intentHash,
            signatureEd25519 = Base64.getEncoder().encodeToString(signature),
        )
    }

    fun verify(
        intent: PhoneControlIntent,
        authority: PhoneControlAuthorityEnvelope,
        publicKey: ByteArray,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long = 5_000L,
    ) {
        if (publicKey.size != 32) throw PhoneControlVerifyError.InvalidPublicKey
        val skew = kotlin.math.abs(nowMillis - authority.timestampMillis)
        if (skew > freshnessMillis) throw PhoneControlVerifyError.StaleTimestamp(skew)
        if (authority.counter <= lastSeenCounter) {
            throw PhoneControlVerifyError.CounterReplay(lastSeenCounter, authority.counter)
        }
        val observedHash = canonicalIntentHashHex(intent)
        if (observedHash != authority.intentHashBlake3) {
            throw PhoneControlVerifyError.IntentHashMismatch
        }
        val signature = try {
            Base64.getDecoder().decode(authority.signatureEd25519)
        } catch (_: IllegalArgumentException) {
            throw PhoneControlVerifyError.InvalidSignature
        }
        val payload = signablePayload(
            intentHashHex = authority.intentHashBlake3,
            counter = authority.counter,
            timestampMillis = authority.timestampMillis,
        )
        try {
            Ed25519Verify(publicKey).verify(signature, payload)
        } catch (_: java.security.GeneralSecurityException) {
            throw PhoneControlVerifyError.InvalidSignature
        }
    }

    fun canonicalIntentJson(intent: PhoneControlIntent): String {
        val fields = linkedMapOf<String, String>()
        fields["kind"] = quote(intent.kind.wireValue)
        intent.key?.let { fields["key"] = quote(it) }
        intent.modifiers?.let { fields["modifiers"] = it.joinToString(prefix = "[", postfix = "]") { item -> quote(item) } }
        intent.normalizedX?.let { fields["normalizedX"] = number(it) }
        intent.normalizedX2?.let { fields["normalizedX2"] = number(it) }
        intent.normalizedY?.let { fields["normalizedY"] = number(it) }
        intent.normalizedY2?.let { fields["normalizedY2"] = number(it) }
        intent.text?.let { fields["text"] = quote(it) }
        return fields.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }
    }

    private fun number(value: Double): String {
        require(value.isFinite()) { "intent coordinates must be finite" }
        return value.toString()
    }

    private fun quote(value: String): String {
        val out = StringBuilder(value.length + 2)
        out.append('"')
        for (ch in value) {
            when (ch) {
                '\\' -> out.append("\\\\")
                '"' -> out.append("\\\"")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> {
                    if (ch.code < 0x20) {
                        out.append("\\u")
                        out.append(ch.code.toString(16).padStart(4, '0'))
                    } else {
                        out.append(ch)
                    }
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
}
