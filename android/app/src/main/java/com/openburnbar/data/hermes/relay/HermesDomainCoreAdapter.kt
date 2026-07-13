package com.openburnbar.data.hermes.relay

import android.util.Log
import com.openburnbar.data.DomainCoreBuildProfile
import java.security.SecureRandom
import uniffi.openburnbar_domain_ffi.HermesAadKind
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
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

internal object HermesDomainCoreAdapter {
    private val secureRandom = SecureRandom()

    fun aad(kind: HermesAadKind, arguments: List<String>, legacy: () -> ByteArray): ByteArray = selectBytes("aad", legacy) { hermesRelayAad(kind, arguments) }

    fun keyWrapInfoV1(aad: ByteArray, legacy: () -> ByteArray): ByteArray = selectBytes("key_wrap_info_v1", legacy) { hermesKeyWrapInfoV1(aad) }

    fun keyWrapInfoV2(aad: ByteArray, enc: ByteArray, recipient: ByteArray, sender: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("key_wrap_info_v2", legacy) {
            hermesKeyWrapInfoV2(aad, enc, recipient, sender)
        }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int, legacy: () -> ByteArray): ByteArray = selectBytes("hkdf", legacy) {
        hermesHkdfSha256(ikm, salt, info, length.toUInt())
    }

    fun seal(plaintext: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> String): String {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            if (!nativeReady()) {
                diagnostic("seal", "native_unavailable")
                return old
            }
            runCatching { hermesOpenBase64(old, key, aad) }.fold(
                onSuccess = { opened ->
                    if (!opened.contentEquals(plaintext)) diagnostic("seal", "shadow_mismatch")
                },
                onFailure = { diagnostic("seal", "native_error") },
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
            val old = legacy()
            if (!nativeReady()) {
                diagnostic("ratchet_seal", "native_unavailable")
                return old
            }
            runCatching { hermesOpenCombined(old, key, aad) }.fold(
                onSuccess = { opened ->
                    if (!opened.contentEquals(plaintext)) diagnostic("ratchet_seal", "shadow_mismatch")
                },
                onFailure = { diagnostic("ratchet_seal", "native_error") },
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
            val old = legacy()
            val value = runCatching(rust).getOrElse {
                diagnostic(operation, "native_error")
                return old
            }
            if (!equivalent(old, value)) diagnostic(operation, "shadow_mismatch")
            return old
        }
        return rust()
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
}
