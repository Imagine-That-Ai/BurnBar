package com.openburnbar.data.hermes.relay

import android.util.Log
import com.openburnbar.data.DomainCoreBuildProfile
import java.security.SecureRandom
import uniffi.openburnbar_domain_ffi.HermesAadKind
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion
import uniffi.openburnbar_domain_ffi.hermesGatewayRelaySafetyCode
import uniffi.openburnbar_domain_ffi.hermesHkdfSha256
import uniffi.openburnbar_domain_ffi.hermesHmacSha256
import uniffi.openburnbar_domain_ffi.hermesKeyWrapInfoV1
import uniffi.openburnbar_domain_ffi.hermesKeyWrapInfoV2
import uniffi.openburnbar_domain_ffi.hermesOpenBase64
import uniffi.openburnbar_domain_ffi.hermesOpenCombined
import uniffi.openburnbar_domain_ffi.hermesRatchetEnvelopeAad
import uniffi.openburnbar_domain_ffi.hermesRelayAad
import uniffi.openburnbar_domain_ffi.hermesSealBase64
import uniffi.openburnbar_domain_ffi.hermesSealCombined

internal enum class HermesDomainCoreMode {
    LEGACY,
    SHADOW,
    RUST,
    ;

    companion object {
        fun resolve(
            raw: String? = System.getProperty("openburnbar.domain_core.hermes.mode")
                ?: System.getenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE"),
        ): HermesDomainCoreMode = entries.firstOrNull {
            it.name.equals(DomainCoreBuildProfile.mode("hermes", raw), ignoreCase = true)
        } ?: LEGACY
    }
}

internal data class HermesShadowComparison(
    val domain: String = "hermes",
    val slice: String,
    val consumer: String = "android",
    val operation: String,
    val coreVersion: String,
    val outcome: String,
    val mismatchCategory: String?,
    val legacyMicros: Long,
    val rustMicros: Long,
)

internal object HermesDomainCoreAdapter {
    private val secureRandom = SecureRandom()

    @Volatile
    internal var comparisonOverride: ((HermesShadowComparison) -> Unit)? = null

    fun aad(kind: HermesAadKind, arguments: List<String>, legacy: () -> ByteArray): ByteArray = selectBytes("aad", legacy) { hermesRelayAad(kind, arguments) }

    fun keyWrapInfoV1(aad: ByteArray, legacy: () -> ByteArray): ByteArray = selectBytes("key_wrap_info_v1", legacy) { hermesKeyWrapInfoV1(aad) }

    fun keyWrapInfoV2(aad: ByteArray, enc: ByteArray, recipient: ByteArray, sender: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("key_wrap_info_v2", legacy) {
            hermesKeyWrapInfoV2(aad, enc, recipient, sender)
        }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int, legacy: () -> ByteArray): ByteArray = selectBytes("hkdf", legacy) {
        hermesHkdfSha256(ikm, salt, info, checkedHkdfLength(length))
    }

    fun seal(plaintext: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> String): String {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val legacyStarted = System.nanoTime()
            val old = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            if (!nativeReady()) {
                diagnostic("seal", "native_unavailable")
                collect("seal", false, "native_unavailable", legacyMicros, 0)
                return old
            }
            val rustStarted = System.nanoTime()
            runCatching { hermesOpenBase64(old, key, aad) }.fold(
                onSuccess = { opened ->
                    val matches = opened.contentEquals(plaintext)
                    if (!matches) diagnostic("seal", "shadow_mismatch")
                    collect("seal", matches, if (matches) null else "result_mismatch", legacyMicros, elapsedMicros(rustStarted))
                },
                onFailure = {
                    diagnostic("seal", "native_error")
                    collect("seal", false, "native_error", legacyMicros, elapsedMicros(rustStarted))
                },
            )
            return old
        }
        if (!nativeReady()) return unavailable("seal", mode, legacy)
        val nonce = ByteArray(12).also(secureRandom::nextBytes)
        return hermesSealBase64(plaintext, key, aad, nonce)
    }

    fun open(ciphertext: String, key: ByteArray, aad: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("open", legacy) { hermesOpenBase64(ciphertext, key, aad) }

    fun safetyCode(agent: ByteArray, phone: ByteArray, legacy: () -> String): String =
        selectValue("safety_code", legacy, { hermesGatewayRelaySafetyCode(agent, phone) }, String::equals)

    fun hmac(key: ByteArray, data: ByteArray, operation: String, legacy: () -> ByteArray): ByteArray =
        selectBytes(operation, legacy) { hermesHmacSha256(key, data) }

    fun ratchetAad(header: HermesRatchetHeader, associatedData: ByteArray, legacy: () -> ByteArray): ByteArray = selectBytes("ratchet_aad", legacy) {
        hermesRatchetEnvelopeAad(
            associatedData,
            header.algorithm,
            header.sessionID,
            header.senderDeviceID,
            header.receiverDeviceID,
            header.ratchetPublicKeyBase64,
            header.version.toULong(),
            header.previousChainLength.toULong(),
            header.messageNumber.toULong(),
            header.epoch.toULong(),
        )
    }

    fun sealCombined(plaintext: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> ByteArray): ByteArray {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val legacyStarted = System.nanoTime()
            val old = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            if (!nativeReady()) {
                diagnostic("ratchet_seal", "native_unavailable")
                collect("ratchet_seal", false, "native_unavailable", legacyMicros, 0)
                return old
            }
            val rustStarted = System.nanoTime()
            runCatching { hermesOpenCombined(old, key, aad) }.fold(
                onSuccess = { opened ->
                    val matches = opened.contentEquals(plaintext)
                    if (!matches) diagnostic("ratchet_seal", "shadow_mismatch")
                    collect("ratchet_seal", matches, if (matches) null else "result_mismatch", legacyMicros, elapsedMicros(rustStarted))
                },
                onFailure = {
                    diagnostic("ratchet_seal", "native_error")
                    collect("ratchet_seal", false, "native_error", legacyMicros, elapsedMicros(rustStarted))
                },
            )
            return old
        }
        if (!nativeReady()) return unavailable("ratchet_seal", mode, legacy)
        return hermesSealCombined(plaintext, key, aad, ByteArray(12).also(secureRandom::nextBytes))
    }

    fun openCombined(combined: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("ratchet_open", legacy) { hermesOpenCombined(combined, key, aad) }

    private fun selectBytes(operation: String, legacy: () -> ByteArray, rust: () -> ByteArray): ByteArray =
        selectValue(operation, legacy, rust, ByteArray::contentEquals)

    private fun <T> selectValue(operation: String, legacy: () -> T, rust: () -> T, equivalent: (T, T) -> Boolean): T {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            if (!nativeReady()) {
                diagnostic(operation, "native_unavailable")
                return old
            }
            return selectValueWhenNativeAvailable(operation, mode, { old }, rust, equivalent)
        }
        if (!nativeReady()) return unavailable(operation, mode, legacy)
        return selectValueWhenNativeAvailable(operation, mode, legacy, rust, equivalent)
    }

    internal fun <T> selectValueWhenNativeAvailable(
        operation: String,
        mode: HermesDomainCoreMode,
        legacy: () -> T,
        rust: () -> T,
        equivalent: (T, T) -> Boolean,
    ): T {
        if (mode == HermesDomainCoreMode.SHADOW) {
            val legacyStarted = System.nanoTime()
            val old = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            val rustStarted = System.nanoTime()
            val value = runCatching(rust).getOrElse {
                diagnostic(operation, "native_error")
                collect(operation, false, "native_error", legacyMicros, elapsedMicros(rustStarted))
                return old
            }
            val matches = equivalent(old, value)
            if (!matches) diagnostic(operation, "shadow_mismatch")
            collect(operation, matches, if (matches) null else "result_mismatch", legacyMicros, elapsedMicros(rustStarted))
            return old
        }
        return rust()
    }

    internal fun checkedHkdfLength(length: Int): UInt {
        require(length in 1..(255 * 32)) { "Hermes HKDF output length is invalid" }
        return length.toUInt()
    }

    private fun nativeReady(): Boolean = runCatching { domainCoreAbiVersion() == 3u }.getOrDefault(false)

    private fun <T> unavailable(operation: String, mode: HermesDomainCoreMode, legacy: () -> T): T {
        diagnostic(operation, "native_unavailable")
        if (mode == HermesDomainCoreMode.RUST) {
            throw IllegalStateException("Hermes Rust mode requires domain-core ABI v3")
        }
        return legacy()
    }

    private fun diagnostic(operation: String, outcome: String) {
        Log.w("OpenBurnBarDomainCore", "domain_core.hermes.$operation $outcome")
    }

    private fun elapsedMicros(startedNanos: Long): Long = ((System.nanoTime() - startedNanos) / 1_000)
        .coerceIn(0, 600_000_000)

    private fun collect(operation: String, matches: Boolean, mismatchCategory: String?, legacyMicros: Long, rustMicros: Long) {
        comparisonOverride?.invoke(
            HermesShadowComparison(
                slice = when {
                    operation == "aad" -> "aad"
                    operation.contains("hpke") -> "hpke-info"
                    operation.contains("ratchet") -> "ratchet"
                    else -> "payload-keywrap"
                },
                operation = operation,
                coreVersion = runCatching(::domainCoreVersion).getOrDefault("0.0.0-native-unavailable"),
                outcome = if (matches) "match" else "mismatch",
                mismatchCategory = mismatchCategory,
                legacyMicros = legacyMicros,
                rustMicros = rustMicros,
            ),
        )
    }
}
