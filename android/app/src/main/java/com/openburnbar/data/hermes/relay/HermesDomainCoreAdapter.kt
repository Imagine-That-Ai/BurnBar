package com.openburnbar.data.hermes.relay

import android.util.Log
import java.security.SecureRandom
import uniffi.openburnbar_domain_ffi.HermesAadKind
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.hermesGatewayRelaySafetyCode
import uniffi.openburnbar_domain_ffi.hermesHmacSha256
import uniffi.openburnbar_domain_ffi.hermesHkdfSha256
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
    RUST;

    companion object {
        fun resolve(
            raw: String? = System.getProperty("openburnbar.domain_core.hermes.mode")
                ?: System.getenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE"),
        ): HermesDomainCoreMode =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: LEGACY
    }
}

internal object HermesDomainCoreAdapter {
    private val secureRandom = SecureRandom()

    fun aad(kind: HermesAadKind, arguments: List<String>, legacy: () -> ByteArray): ByteArray =
        selectBytes("aad", legacy) { hermesRelayAad(kind, arguments) }

    fun keyWrapInfoV1(aad: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("key_wrap_info_v1", legacy) { hermesKeyWrapInfoV1(aad) }

    fun keyWrapInfoV2(
        aad: ByteArray,
        enc: ByteArray,
        recipient: ByteArray,
        sender: ByteArray,
        legacy: () -> ByteArray,
    ): ByteArray = selectBytes("key_wrap_info_v2", legacy) {
        hermesKeyWrapInfoV2(aad, enc, recipient, sender)
    }

    fun hkdf(
        ikm: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        length: Int,
        legacy: () -> ByteArray,
    ): ByteArray = selectBytes("hkdf", legacy) {
        hermesHkdfSha256(ikm, salt, info, length.toUInt())
    }

    fun seal(plaintext: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> String): String {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (!nativeReady()) return legacyWithDiagnostic("seal", legacy)
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            val opened = runCatching { hermesOpenBase64(old, key, aad) }.getOrNull()
            if (opened == null || !opened.contentEquals(plaintext)) diagnostic("seal", "shadow_mismatch")
            return old
        }
        val nonce = ByteArray(12).also(secureRandom::nextBytes)
        return hermesSealBase64(plaintext, key, aad, nonce)
    }

    fun open(ciphertext: String, key: ByteArray, aad: ByteArray, legacy: () -> ByteArray): ByteArray {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (!nativeReady()) return legacyWithDiagnostic("open", legacy)
        val rust = hermesOpenBase64(ciphertext, key, aad)
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            if (!old.contentEquals(rust)) diagnostic("open", "shadow_mismatch")
            return old
        }
        return rust
    }

    fun safetyCode(agent: ByteArray, phone: ByteArray, legacy: () -> String): String {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY || !nativeReady()) return legacy()
        val rust = hermesGatewayRelaySafetyCode(agent, phone)
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            if (old != rust) diagnostic("safety_code", "shadow_mismatch")
            return old
        }
        return rust
    }

    fun hmac(key: ByteArray, data: ByteArray, operation: String, legacy: () -> ByteArray): ByteArray =
        selectBytes(operation, legacy) { hermesHmacSha256(key, data) }

    fun ratchetAad(header: HermesRatchetHeader, associatedData: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("ratchet_aad", legacy) {
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
        if (!nativeReady()) return legacyWithDiagnostic("ratchet_seal", legacy)
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            val opened = runCatching { hermesOpenCombined(old, key, aad) }.getOrNull()
            if (opened == null || !opened.contentEquals(plaintext)) diagnostic("ratchet_seal", "shadow_mismatch")
            return old
        }
        return hermesSealCombined(plaintext, key, aad, ByteArray(12).also(secureRandom::nextBytes))
    }

    fun openCombined(combined: ByteArray, key: ByteArray, aad: ByteArray, legacy: () -> ByteArray): ByteArray =
        selectBytes("ratchet_open", legacy) { hermesOpenCombined(combined, key, aad) }

    private fun selectBytes(operation: String, legacy: () -> ByteArray, rust: () -> ByteArray): ByteArray {
        val mode = HermesDomainCoreMode.resolve()
        if (mode == HermesDomainCoreMode.LEGACY) return legacy()
        if (!nativeReady()) return legacyWithDiagnostic(operation, legacy)
        val value = rust()
        if (mode == HermesDomainCoreMode.SHADOW) {
            val old = legacy()
            if (!old.contentEquals(value)) diagnostic(operation, "shadow_mismatch")
            return old
        }
        return value
    }

    private fun nativeReady(): Boolean = runCatching { domainCoreAbiVersion() == 2u }.getOrDefault(false)

    private fun <T> legacyWithDiagnostic(operation: String, legacy: () -> T): T {
        diagnostic(operation, "native_unavailable")
        return legacy()
    }

    private fun diagnostic(operation: String, outcome: String) {
        Log.w("OpenBurnBarDomainCore", "domain_core.hermes.$operation $outcome")
    }
}
