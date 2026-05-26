package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Sign
import com.google.crypto.tink.subtle.Ed25519Sign.KeyPair
import com.google.crypto.tink.subtle.Ed25519Verify
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedRect
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusContext
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.math.BigDecimal
import java.math.RoundingMode
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
    POINTER_MOVE("pointer_move"),
    POINTER_CLICK("pointer_click"),
    PANIC("panic"),
}

data class PhoneControlIntent(
    val kind: PhoneControlIntentKind,
    val displayId: String? = null,
    val normalizedX: Double? = null,
    val normalizedY: Double? = null,
    val normalizedX2: Double? = null,
    val normalizedY2: Double? = null,
    val text: String? = null,
    val key: String? = null,
    val modifiers: List<String>? = null,
    val mouseButton: Int? = null,
    val clientIntentId: String? = null,
)

enum class PhoneControlClipboardAction(val wireValue: String) {
    PASTE_TO_MAC("paste_to_mac"),
    GRAB_FROM_MAC("grab_from_mac"),
}

data class PhoneControlClipboardRequest(
    val requestId: String,
    val action: PhoneControlClipboardAction,
    val contentType: String = "text/plain",
    val text: String? = null,
    val maxBytes: Int = 65_536,
    val clientIntentId: String? = null,
) {
    fun toRelayAction(): HermesRealtimeRelayClipboardAction = when (action) {
        PhoneControlClipboardAction.PASTE_TO_MAC -> HermesRealtimeRelayClipboardAction.PASTE_TO_MAC
        PhoneControlClipboardAction.GRAB_FROM_MAC -> HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC
    }
}

data class PhoneControlAgentContextTarget(
    val requestId: String,
    val sessionId: String? = null,
    val runtime: String,
    val threadId: String? = null,
    val displayId: String? = null,
    val normalizedX: Double,
    val normalizedY: Double,
    val normalizedRect: HermesRealtimeRelayNormalizedRect? = null,
    val instruction: String,
    val focusContext: HermesRealtimeRelayFocusContext? = null,
    val clientIntentId: String,
    val requestedAt: Double,
)

enum class PhoneControlSystemPermissionKind(val wireValue: String) {
    SCREEN_RECORDING("screen_recording"),
    ACCESSIBILITY("accessibility"),
    CAMERA("camera"),
    MICROPHONE("microphone"),
    FULL_DISK_ACCESS("full_disk_access"),
    AUTOMATION("automation");

    fun toRelayKind(): com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind = when (this) {
        SCREEN_RECORDING -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.SCREEN_RECORDING
        ACCESSIBILITY -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.ACCESSIBILITY
        CAMERA -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.CAMERA
        MICROPHONE -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.MICROPHONE
        FULL_DISK_ACCESS -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.FULL_DISK_ACCESS
        AUTOMATION -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.AUTOMATION
    }
}

enum class PhoneControlSystemPermissionAction(val wireValue: String) {
    PROMPT("prompt"),
    OPEN_SETTINGS("open_settings"),
    PROMPT_AND_OPEN_SETTINGS("prompt_and_open_settings"),
    PROBE_ONLY("probe_only"),
    RETRY_FAILED_TOOL("retry_failed_tool");

    fun toRelayAction(): com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction = when (this) {
        PROMPT -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.PROMPT
        OPEN_SETTINGS -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.OPEN_SETTINGS
        PROMPT_AND_OPEN_SETTINGS -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.PROMPT_AND_OPEN_SETTINGS
        PROBE_ONLY -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.PROBE_ONLY
        RETRY_FAILED_TOOL -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.RETRY_FAILED_TOOL
    }
}

/**
 * Domain model for a phone-issued system permission request. Carries
 * everything the Mac receiver needs to dispatch the corresponding TCC
 * surface and pair the resulting status frame back with the failing
 * tool call.
 */
data class PhoneControlSystemPermissionRequest(
    val requestId: String,
    val kind: PhoneControlSystemPermissionKind,
    val action: PhoneControlSystemPermissionAction,
    val bundleId: String? = null,
    val originatingToolCallId: String? = null,
    val originatingToolName: String? = null,
    val clientIntentId: String? = null,
    val requestedAtMillis: Long,
) {
    val requestedAtSwiftReferenceSeconds: Double
        get() = (requestedAtMillis.toDouble() / 1000.0) - 978_307_200.0
}

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

    fun canonicalAgentGrantRequestHashHex(request: HermesRealtimeRelayAgentGrantRequest): String =
        sha256Hex(canonicalAgentGrantRequestJson(request).toByteArray(Charsets.UTF_8))

    fun canonicalClipboardRequestHashHex(request: PhoneControlClipboardRequest): String =
        sha256Hex(canonicalClipboardRequestJson(request).toByteArray(Charsets.UTF_8))

    fun canonicalAgentContextTargetHashHex(target: PhoneControlAgentContextTarget): String =
        sha256Hex(canonicalAgentContextTargetJson(target).toByteArray(Charsets.UTF_8))

    fun canonicalSystemPermissionRequestHashHex(request: PhoneControlSystemPermissionRequest): String =
        sha256Hex(canonicalSystemPermissionRequestJson(request).toByteArray(Charsets.UTF_8))

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

    fun signAgentGrantRequest(
        request: HermesRealtimeRelayAgentGrantRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        val requestHash = canonicalAgentGrantRequestHashHex(request)
        val payload = signablePayload(requestHash, counter, timestampMillis)
        val signature = Ed25519Sign(privateKeySeed).sign(payload)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = requestHash,
            signatureEd25519 = Base64.getEncoder().encodeToString(signature),
        )
    }

    fun signClipboardRequest(
        request: PhoneControlClipboardRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        val requestHash = canonicalClipboardRequestHashHex(request)
        val payload = signablePayload(requestHash, counter, timestampMillis)
        val signature = Ed25519Sign(privateKeySeed).sign(payload)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = requestHash,
            signatureEd25519 = Base64.getEncoder().encodeToString(signature),
        )
    }

    fun signAgentContextTarget(
        target: PhoneControlAgentContextTarget,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        val targetHash = canonicalAgentContextTargetHashHex(target)
        val payload = signablePayload(targetHash, counter, timestampMillis)
        val signature = Ed25519Sign(privateKeySeed).sign(payload)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = targetHash,
            signatureEd25519 = Base64.getEncoder().encodeToString(signature),
        )
    }

    fun signSystemPermissionRequest(
        request: PhoneControlSystemPermissionRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        val requestHash = canonicalSystemPermissionRequestHashHex(request)
        val payload = signablePayload(requestHash, counter, timestampMillis)
        val signature = Ed25519Sign(privateKeySeed).sign(payload)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = requestHash,
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

    fun verifyClipboardRequest(
        request: PhoneControlClipboardRequest,
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
        val observedHash = canonicalClipboardRequestHashHex(request)
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

    fun verifyAgentContextTarget(
        target: PhoneControlAgentContextTarget,
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
        val observedHash = canonicalAgentContextTargetHashHex(target)
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
        intent.clientIntentId?.let { fields["clientIntentId"] = quote(it) }
        intent.displayId?.let { fields["displayId"] = quote(it) }
        fields["kind"] = quote(intent.kind.wireValue)
        intent.key?.let { fields["key"] = quote(it) }
        intent.modifiers?.let { fields["modifiers"] = it.joinToString(prefix = "[", postfix = "]") { item -> quote(item) } }
        intent.mouseButton?.let { fields["mouseButton"] = it.toString() }
        intent.normalizedX?.let { fields["normalizedX"] = number(it) }
        intent.normalizedX2?.let { fields["normalizedX2"] = number(it) }
        intent.normalizedY?.let { fields["normalizedY"] = number(it) }
        intent.normalizedY2?.let { fields["normalizedY2"] = number(it) }
        intent.text?.let { fields["text"] = quote(it) }
        return fields.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }
    }

    fun canonicalAgentGrantRequestJson(request: HermesRealtimeRelayAgentGrantRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["capabilities"] = request.capabilities.sorted()
            .joinToString(separator = ",", prefix = "[", postfix = "]") { quote(it) }
        fields["clientIntentId"] = quote(request.clientIntentId)
        fields["deliveryMode"] = quote(request.deliveryMode)
        fields["expiresAt"] = number(request.expiresAt)
        fields["grantDurationSeconds"] = number(request.grantDurationSeconds)
        fields["localAuthenticationSatisfied"] = request.localAuthenticationSatisfied.toString()
        fields["preset"] = quote(request.preset)
        fields["requestedAt"] = number(request.requestedAt)
        fields["requestId"] = quote(request.requestId)
        fields["runtime"] = quote(request.runtime)
        fields["sourceDeviceId"] = quote(request.sourceDeviceId)
        fields["threadId"] = quote(request.threadId)
        fields["trustMode"] = quote(request.trustMode)
        return fields.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }
    }

    fun canonicalClipboardRequestJson(request: PhoneControlClipboardRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["action"] = quote(request.action.wireValue)
        fields["clientIntentId"] = quote(request.clientIntentId.orEmpty())
        fields["contentType"] = quote(request.contentType)
        fields["maxBytes"] = request.maxBytes.toString()
        fields["requestId"] = quote(request.requestId)
        request.text?.let { fields["text"] = quote(it) }
        return fields.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }
    }

    fun canonicalAgentContextTargetJson(target: PhoneControlAgentContextTarget): String {
        val fields = linkedMapOf<String, String>()
        fields["clientIntentId"] = quote(target.clientIntentId)
        target.displayId?.let { fields["displayId"] = quote(it) }
        fields["instruction"] = quote(target.instruction)
        fields["normalizedX"] = number(target.normalizedX)
        fields["normalizedY"] = number(target.normalizedY)
        fields["requestedAt"] = number(target.requestedAt)
        fields["requestId"] = quote(target.requestId)
        fields["runtime"] = quote(target.runtime)
        target.sessionId?.let { fields["sessionId"] = quote(it) }
        target.threadId?.let { fields["threadId"] = quote(it) }
        return fields.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }
    }

    fun canonicalSystemPermissionRequestJson(request: PhoneControlSystemPermissionRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["action"] = quote(request.action.wireValue)
        request.bundleId?.let { fields["bundleId"] = quote(it) }
        fields["clientIntentId"] = quote(request.clientIntentId.orEmpty())
        fields["kind"] = quote(request.kind.wireValue)
        request.originatingToolCallId?.let { fields["originatingToolCallId"] = quote(it) }
        request.originatingToolName?.let { fields["originatingToolName"] = quote(it) }
        fields["requestedAt"] = number(request.requestedAtSwiftReferenceSeconds)
        fields["requestId"] = quote(request.requestId)
        return fields.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }
    }

    private fun number(value: Double): String {
        require(value.isFinite()) { "intent coordinates must be finite" }
        if (value <= Long.MAX_VALUE.toDouble() && value >= Long.MIN_VALUE.toDouble()) {
            val asLong = value.toLong()
            if (asLong.toDouble() == value) return asLong.toString()
        }
        return BigDecimal.valueOf(value)
            .setScale(12, RoundingMode.HALF_UP)
            .stripTrailingZeros()
            .toPlainString()
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
