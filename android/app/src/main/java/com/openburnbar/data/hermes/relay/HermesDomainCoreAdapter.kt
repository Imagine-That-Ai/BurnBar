package com.openburnbar.data.hermes.relay

import android.util.Log
import com.openburnbar.data.DomainCoreBuildProfile
import java.security.SecureRandom
import java.time.Instant
import uniffi.openburnbar_domain_ffi.HermesAadKind
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion
import uniffi.openburnbar_domain_ffi.hermesGatewayRelaySafetyCode
import uniffi.openburnbar_domain_ffi.hermesHkdfSha256
import uniffi.openburnbar_domain_ffi.hermesHmacSha256
import uniffi.openburnbar_domain_ffi.hermesHpkeV3Info
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
    val observedAt: Instant = Instant.now(),
)

internal object HermesDomainCoreAdapter {
    private const val REQUIRED_ABI_VERSION = 3u
    private const val ABI_MISMATCH_VERSION = "0.0.0-abi-mismatch"
    private const val NATIVE_UNAVAILABLE_VERSION = "0.0.0-native-unavailable"

    private enum class NativeAvailability(
        val diagnosticCategory: String,
        val evidenceVersion: String,
        val evidenceMismatchCategory: String,
    ) {
        READY("", "", ""),
        ABI_MISMATCH("abi_mismatch", ABI_MISMATCH_VERSION, "native_error"),
        NATIVE_UNAVAILABLE("native_unavailable", NATIVE_UNAVAILABLE_VERSION, "native_unavailable"),
    }

    private val secureRandom = SecureRandom()

    @Volatile
    internal var comparisonOverride: ((HermesShadowComparison) -> Unit)? = null

    @Volatile
    internal var modeOverride: HermesDomainCoreMode? = null

    @Volatile
    internal var abiVersionOverride: (() -> UInt)? = null

    @Volatile
    internal var coreVersionOverride: (() -> String)? = null

    fun aad(kind: HermesAadKind, arguments: List<String>, legacy: () -> ByteArray): ByteArray = selectBytes("aad", legacy) { hermesRelayAad(kind, arguments) }

    fun keyWrapInfoV1(aad: ByteArray, legacy: () -> ByteArray): ByteArray = selectBytes("key_wrap_info_v1", legacy) { hermesKeyWrapInfoV1(aad) }

    fun keyWrapInfoV2(aad: ByteArray, enc: ByteArray, recipient: ByteArray, sender: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("key_wrap_info_v2", legacy) {
            hermesKeyWrapInfoV2(aad, enc, recipient, sender)
        }

    fun hpkeV3Info(aad: ByteArray, legacy: () -> ByteArray): ByteArray = selectBytes("hpke_v3_info", legacy) { hermesHpkeV3Info(aad) }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int, legacy: () -> ByteArray): ByteArray = selectBytes("hkdf", legacy) {
        hermesHkdfSha256(ikm, salt, info, checkedHkdfLength(length))
    }

    fun seal(plaintext: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> String): String {
        val mode = resolvedMode()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val legacyStarted = System.nanoTime()
            val old = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            val availability = nativeAvailability()
            if (availability != NativeAvailability.READY) {
                collectUnavailable("seal", availability, legacyMicros)
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
        val availability = nativeAvailability()
        if (availability != NativeAvailability.READY) return unavailable("seal", mode, availability, legacy)
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
        val mode = resolvedMode()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val legacyStarted = System.nanoTime()
            val old = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            val availability = nativeAvailability()
            if (availability != NativeAvailability.READY) {
                collectUnavailable("ratchet_seal", availability, legacyMicros)
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
        val availability = nativeAvailability()
        if (availability != NativeAvailability.READY) return unavailable("ratchet_seal", mode, availability, legacy)
        return hermesSealCombined(plaintext, key, aad, ByteArray(12).also(secureRandom::nextBytes))
    }

    fun openCombined(combined: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("ratchet_open", legacy) { hermesOpenCombined(combined, key, aad) }

    private fun selectBytes(operation: String, legacy: () -> ByteArray, rust: () -> ByteArray): ByteArray =
        selectValue(operation, legacy, rust, ByteArray::contentEquals)

    private fun <T> selectValue(operation: String, legacy: () -> T, rust: () -> T, equivalent: (T, T) -> Boolean): T {
        val mode = resolvedMode()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val legacyStarted = System.nanoTime()
            val old = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            val availability = nativeAvailability()
            if (availability != NativeAvailability.READY) {
                collectUnavailable(operation, availability, legacyMicros)
                return old
            }
            return selectValueWhenNativeAvailable(operation, mode, { old }, rust, equivalent)
        }
        val availability = nativeAvailability()
        if (availability != NativeAvailability.READY) return unavailable(operation, mode, availability, legacy)
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

    private fun resolvedMode(): HermesDomainCoreMode = modeOverride ?: HermesDomainCoreMode.resolve()

    internal fun resetTestOverrides() {
        comparisonOverride = null
        modeOverride = null
        abiVersionOverride = null
        coreVersionOverride = null
    }

    private fun nativeAvailability(): NativeAvailability {
        val abiVersion = runCatching { abiVersionOverride?.invoke() ?: domainCoreAbiVersion() }
            .getOrElse { return NativeAvailability.NATIVE_UNAVAILABLE }
        return if (abiVersion == REQUIRED_ABI_VERSION) NativeAvailability.READY else NativeAvailability.ABI_MISMATCH
    }

    private fun <T> unavailable(operation: String, mode: HermesDomainCoreMode, availability: NativeAvailability, legacy: () -> T): T {
        diagnostic(operation, availability.diagnosticCategory)
        if (mode == HermesDomainCoreMode.RUST) {
            throw IllegalStateException("Hermes Rust mode requires domain-core ABI v3")
        }
        return legacy()
    }

    private fun collectUnavailable(operation: String, availability: NativeAvailability, legacyMicros: Long) {
        check(availability != NativeAvailability.READY)
        diagnostic(operation, availability.diagnosticCategory)
        collect(
            operation = operation,
            matches = false,
            mismatchCategory = availability.evidenceMismatchCategory,
            legacyMicros = legacyMicros,
            rustMicros = 0,
            coreVersion = availability.evidenceVersion,
        )
    }

    private fun diagnostic(operation: String, outcome: String) {
        Log.w("OpenBurnBarDomainCore", "domain_core.hermes.$operation $outcome")
    }

    private fun elapsedMicros(startedNanos: Long): Long = ((System.nanoTime() - startedNanos) / 1_000)
        .coerceIn(0, 600_000_000)

    private fun collect(
        operation: String,
        matches: Boolean,
        mismatchCategory: String?,
        legacyMicros: Long,
        rustMicros: Long,
        coreVersion: String = safeCoreVersion(),
    ) {
        comparisonOverride?.invoke(
            HermesShadowComparison(
                slice = when {
                    operation == "aad" -> "aad"
                    operation.contains("hpke") -> "hpke-info"
                    operation.contains("ratchet") -> "ratchet"
                    else -> "payload-keywrap"
                },
                operation = operation,
                coreVersion = coreVersion,
                outcome = if (matches) "match" else "mismatch",
                mismatchCategory = mismatchCategory,
                legacyMicros = legacyMicros,
                rustMicros = rustMicros,
            ),
        )
    }

    private fun safeCoreVersion(): String = runCatching { coreVersionOverride?.invoke() ?: domainCoreVersion() }
        .getOrDefault(NATIVE_UNAVAILABLE_VERSION)
}
