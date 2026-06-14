package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayMacLockState
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockBackend
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession
import java.math.BigDecimal
import java.math.RoundingMode
import java.security.MessageDigest
import java.time.Instant

private const val NANOS_PER_SECOND = 1_000_000_000.0
private const val MIN_UNESCAPED_CHAR_CODE = 0x20
private const val CANONICAL_NUMBER_DECIMAL_PLACES = 12
private const val HEX_RADIX = 16
private const val UNICODE_ESCAPE_HEX_DIGITS = 4

// Unix seconds at 2001-01-01T00:00:00Z, the Apple/Swift Date reference epoch.
private const val APPLE_REFERENCE_DATE_EPOCH_SECONDS = 978_307_200.0

internal object PhoneControlSignerJsonEncoding {
    fun sortedJson(fields: LinkedHashMap<String, String>): String = fields.entries
        .sortedBy { it.key }
        .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${quote(key)}:$value" }

    fun number(value: Double): String {
        require(value.isFinite()) { "intent coordinates must be finite" }
        if (value <= Long.MAX_VALUE.toDouble() && value >= Long.MIN_VALUE.toDouble()) {
            val asLong = value.toLong()
            if (asLong.toDouble() == value) return asLong.toString()
        }
        return BigDecimal.valueOf(value)
            .setScale(CANONICAL_NUMBER_DECIMAL_PLACES, RoundingMode.HALF_UP)
            .stripTrailingZeros()
            .toPlainString()
    }

    fun swiftReferenceSecondsFromIso8601(value: String): Double {
        val instant = Instant.parse(value)
        return instant.epochSecond.toDouble() +
            instant.nano.toDouble() / NANOS_PER_SECOND -
            APPLE_REFERENCE_DATE_EPOCH_SECONDS
    }

    fun quote(value: String): String {
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
                    if (ch.code < MIN_UNESCAPED_CHAR_CODE) {
                        out.append("\\u")
                        out.append(ch.code.toString(HEX_RADIX).padStart(UNICODE_ESCAPE_HEX_DIGITS, '0'))
                    } else {
                        out.append(ch)
                    }
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it) }
}

internal fun HermesRealtimeRelayRemoteUnlockSession.Intent.wireValue(): String = when (this) {
    HermesRealtimeRelayRemoteUnlockSession.Intent.REQUEST -> "request"
    HermesRealtimeRelayRemoteUnlockSession.Intent.ATTACH -> "attach"
    HermesRealtimeRelayRemoteUnlockSession.Intent.CANCEL -> "cancel"
}

internal fun HermesRealtimeRelayRemoteUnlockBackend.wireValue(): String = when (this) {
    HermesRealtimeRelayRemoteUnlockBackend.SCREEN_CAPTURE_KIT -> "screen_capture_kit"
    HermesRealtimeRelayRemoteUnlockBackend.PERSISTENT_SCREEN_CAPTURE_KIT -> "persistent_screen_capture_kit"
    HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK -> "apple_screen_sharing_loopback"
    HermesRealtimeRelayRemoteUnlockBackend.FILEVAULT_SSH -> "filevault_ssh"
    HermesRealtimeRelayRemoteUnlockBackend.UNAVAILABLE -> "unavailable"
}

internal fun HermesRealtimeRelayMacLockState.wireValue(): String = when (this) {
    HermesRealtimeRelayMacLockState.UNLOCKED -> "unlocked"
    HermesRealtimeRelayMacLockState.SCREEN_SAVER -> "screen_saver"
    HermesRealtimeRelayMacLockState.SCREEN_LOCKED -> "screen_locked"
    HermesRealtimeRelayMacLockState.DISPLAY_SLEEPING -> "display_sleeping"
    HermesRealtimeRelayMacLockState.LOGIN_WINDOW -> "login_window"
    HermesRealtimeRelayMacLockState.SECURITY_AGENT -> "security_agent"
    HermesRealtimeRelayMacLockState.FAST_USER_SWITCHING -> "fast_user_switching"
    HermesRealtimeRelayMacLockState.REMOTE_DESKTOP_CURTAIN -> "remote_desktop_curtain"
    HermesRealtimeRelayMacLockState.REBOOT_LOGIN_WINDOW -> "reboot_login_window"
    HermesRealtimeRelayMacLockState.FILEVAULT_PREBOOT -> "filevault_preboot"
    HermesRealtimeRelayMacLockState.UNKNOWN -> "unknown"
}
