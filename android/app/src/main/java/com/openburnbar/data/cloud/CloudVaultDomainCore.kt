package com.openburnbar.data.cloud

import android.util.Log
import com.openburnbar.BuildConfig
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import uniffi.openburnbar_domain_ffi.CloudVaultHashPurpose as FfiHashPurpose
import uniffi.openburnbar_domain_ffi.cloudVaultAadV1
import uniffi.openburnbar_domain_ffi.cloudVaultAadV2
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmOpenCombined
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmOpenTextDetached
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmSealCombined
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmSealDetached
import uniffi.openburnbar_domain_ffi.cloudVaultBase64DecodeStrict
import uniffi.openburnbar_domain_ffi.cloudVaultBase64Encode
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowOpen
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowSeal
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowSplitWire
import uniffi.openburnbar_domain_ffi.cloudVaultExpectedSessionBodyHash
import uniffi.openburnbar_domain_ffi.cloudVaultKeyId
import uniffi.openburnbar_domain_ffi.cloudVaultKeyedHashHex
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryOpenVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryVerificationHash
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryWrapVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryWrappingKey
import uniffi.openburnbar_domain_ffi.cloudVaultSha256Hex
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion

internal enum class CloudVaultDomainCoreMode(val wireValue: String) {
    LEGACY("legacy"),
    SHADOW("shadow"),
    RUST("rust"),
    ;

    companion object {
        fun parse(value: String): CloudVaultDomainCoreMode = entries.firstOrNull { it.wireValue == value.lowercase() }
            ?: error("Invalid CloudVault domain-core mode")
    }
}

internal enum class CloudVaultHashPurpose(val wireValue: String) {
    BLOB_INTEGRITY("blob-integrity"),
    SESSION_BODY("session-body"),
    SESSION_CHUNK("session-chunk"),
    PROJECT_MEMORY_CONTENT("project-memory-content"),
}

internal data class CloudVaultDomainCoreDiagnostic(
    val operation: String,
    val abiVersion: Int,
    val category: String,
    val count: Long,
)

internal data class CloudVaultShadowComparison(
    val domain: String = "cloudvault",
    val slice: String,
    val consumer: String = "android",
    val operation: String,
    val coreVersion: String,
    val outcome: String,
    val mismatchCategory: String?,
    val legacyMicros: Long,
    val rustMicros: Long,
)

internal data class CloudVaultAesDetachedBox(
    val nonce: ByteArray,
    val ciphertext: ByteArray,
    val tag: ByteArray,
)

internal data class CloudVaultRecoveryBox(
    val combined: ByteArray,
    val verificationHash: String,
)

internal data class CloudVaultEscrowParts(
    val ephemeralPublicKey: ByteArray,
    val aesGcmCombined: ByteArray,
)

internal object CloudVaultDomainCore {
    private const val ABI_VERSION = 3
    private const val LOG_TAG = "CloudVaultDomainCore"
    private val diagnosticCounts = ConcurrentHashMap<String, AtomicLong>()

    @Volatile
    private var cachedAbiVersion: UInt? = null

    @Volatile
    internal var modeOverride: CloudVaultDomainCoreMode? = null

    @Volatile
    internal var diagnosticOverride: ((CloudVaultDomainCoreDiagnostic) -> Unit)? = null

    @Volatile
    internal var comparisonOverride: ((CloudVaultShadowComparison) -> Unit)? = null

    @Volatile
    internal var abiVersionOverride: (() -> UInt)? = null

    private val mode: CloudVaultDomainCoreMode
        get() = modeOverride ?: CloudVaultDomainCoreMode.parse(BuildConfig.CLOUDVAULT_DOMAIN_CORE_MODE)

    fun aadV1(uid: String, collection: String, docId: String, field: String): String = dispatch(
        operation = "aad_v1",
        legacy = { CloudVaultLegacyCrypto.aadV1(uid, collection, docId, field) },
        rust = { cloudVaultAadV1(uid, collection, docId, field) },
    )

    fun aadV2(uid: String, collection: String, docId: String, field: String, schemaVersion: Int, purpose: String): String = dispatch(
        operation = "aad_v2",
        legacy = { CloudVaultLegacyCrypto.aadV2(uid, collection, docId, field, schemaVersion, purpose) },
        rust = { cloudVaultAadV2(uid, collection, docId, field, schemaVersion.toUInt(), purpose) },
    )

    fun sha256Hex(data: ByteArray): String = dispatch(
        operation = "sha256_hex",
        legacy = { CloudVaultLegacyCrypto.sha256Hex(data) },
        rust = { cloudVaultSha256Hex(data) },
    )

    fun vaultKeyId(key: ByteArray): String {
        CloudVaultLegacyCrypto.requireVaultKey(key)
        return dispatch(
            operation = "vault_key_id",
            legacy = { CloudVaultLegacyCrypto.vaultKeyId(key) },
            rust = { cloudVaultKeyId(key) },
        )
    }

    fun keyedHashHex(data: ByteArray, key: ByteArray, purpose: CloudVaultHashPurpose): String {
        CloudVaultLegacyCrypto.requireVaultKey(key)
        return dispatch(
            operation = purpose.wireValue.replace('-', '_'),
            legacy = { CloudVaultLegacyCrypto.keyedHashHex(data, key, purpose) },
            rust = { cloudVaultKeyedHashHex(data, key, purpose.ffiValue) },
        )
    }

    fun expectedSessionBodyHash(data: ByteArray, key: ByteArray, bodyHashVersion: Int): String = dispatch(
        operation = "expected_session_body_hash_v$bodyHashVersion",
        legacy = { CloudVaultLegacyCrypto.expectedSessionBodyHash(data, key, bodyHashVersion) },
        rust = {
            require(bodyHashVersion >= 0) { "Unsupported session body hash version" }
            cloudVaultExpectedSessionBodyHash(data, key, bodyHashVersion.toUInt())
        },
    )

    fun aesSealDetached(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): CloudVaultAesDetachedBox {
        CloudVaultLegacyCrypto.requireAesInputs(key, nonce)
        return dispatch(
            operation = "aes_seal_detached",
            legacy = { CloudVaultLegacyCrypto.aesSealDetached(plaintext, key, nonce, aad) },
            rust = {
                val sealed = cloudVaultAesGcmSealDetached(plaintext, key, nonce, aad)
                CloudVaultAesDetachedBox(sealed.nonce, sealed.ciphertext, sealed.tag)
            },
            equivalent = { left, right ->
                left.nonce.contentEquals(right.nonce) &&
                    left.ciphertext.contentEquals(right.ciphertext) &&
                    left.tag.contentEquals(right.tag)
            },
        )
    }

    fun aesSealCombined(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        CloudVaultLegacyCrypto.requireAesInputs(key, nonce)
        return dispatchBytes(
            operation = "aes_seal_combined",
            legacy = {
                val sealed = CloudVaultLegacyCrypto.aesSealDetached(plaintext, key, nonce, aad)
                sealed.nonce + sealed.ciphertext + sealed.tag
            },
            rust = { cloudVaultAesGcmSealCombined(plaintext, key, nonce, aad) },
        )
    }

    fun aesOpenCombined(combined: ByteArray, key: ByteArray, aad: ByteArray): ByteArray {
        CloudVaultLegacyCrypto.requireVaultKey(key)
        return dispatchBytes(
            operation = "aes_open_combined",
            legacy = { CloudVaultLegacyCrypto.aesOpenCombined(combined, key, aad) },
            rust = { cloudVaultAesGcmOpenCombined(combined, key, aad) },
        )
    }

    fun aesOpenTextDetached(nonce: ByteArray, ciphertext: ByteArray, tag: ByteArray, key: ByteArray, aad: ByteArray): String {
        CloudVaultLegacyCrypto.requireAesInputs(key, nonce)
        CloudVaultLegacyCrypto.requireTag(tag)
        return dispatch(
            operation = "aes_open_text",
            legacy = { CloudVaultLegacyCrypto.aesOpenCombined(nonce + ciphertext + tag, key, aad).toString(Charsets.UTF_8) },
            rust = { cloudVaultAesGcmOpenTextDetached(nonce, ciphertext, tag, key, aad) },
        )
    }

    fun base64Encode(data: ByteArray): String = dispatch(
        operation = "base64_encode",
        legacy = { java.util.Base64.getEncoder().encodeToString(data) },
        rust = { cloudVaultBase64Encode(data) },
    )

    fun base64Decode(value: String): ByteArray = dispatchBytes(
        operation = "base64_decode",
        legacy = { java.util.Base64.getMimeDecoder().decode(value) },
        rust = { cloudVaultBase64DecodeStrict(value) },
    )

    internal fun <T> dispatchForTest(selectedMode: CloudVaultDomainCoreMode, operation: String, legacy: () -> T, rust: () -> T): T =
        dispatch(selectedMode, operation, legacy, rust)

    internal val resetTestOverrides = {
        modeOverride = null
        diagnosticOverride = null
        comparisonOverride = null
        abiVersionOverride = null
        cachedAbiVersion = null
        diagnosticCounts.clear()
    }
    internal fun <T> dispatch(operation: String, legacy: () -> T, rust: () -> T, equivalent: (T, T) -> Boolean = { left, right -> left == right }): T =
        dispatch(
            mode,
            operation,
            legacy,
            rust = {
                requireCompatibleAbi()
                rust()
            },
            equivalent = equivalent,
        )

    private fun <T> dispatch(
        selectedMode: CloudVaultDomainCoreMode,
        operation: String,
        legacy: () -> T,
        rust: () -> T,
        equivalent: (T, T) -> Boolean = { left, right -> left == right },
    ): T = when (selectedMode) {
        CloudVaultDomainCoreMode.LEGACY -> legacy()
        CloudVaultDomainCoreMode.RUST -> rust()
        CloudVaultDomainCoreMode.SHADOW -> {
            val legacyStarted = System.nanoTime()
            val legacyResult = legacy()
            val legacyMicros = elapsedMicros(legacyStarted)
            val rustStarted = System.nanoTime()
            val rustResult = runCatching(rust)
            val rustMicros = elapsedMicros(rustStarted)
            val matches = rustResult.isSuccess && equivalent(legacyResult, rustResult.getOrThrow())
            when {
                rustResult.isFailure -> record(operation, "rust_error")
                !matches -> record(operation, "mismatch")
            }
            comparisonOverride?.invoke(
                CloudVaultShadowComparison(
                    slice = sliceFor(operation),
                    operation = operation,
                    coreVersion = runCatching(::domainCoreVersion).getOrDefault("0.0.0-native-unavailable"),
                    outcome = if (matches) "match" else "mismatch",
                    mismatchCategory = when {
                        matches -> null
                        rustResult.isFailure -> "native_error"
                        else -> "result_mismatch"
                    },
                    legacyMicros = legacyMicros,
                    rustMicros = rustMicros,
                ),
            )
            legacyResult
        }
    }

    internal fun dispatchBytes(operation: String, legacy: () -> ByteArray, rust: () -> ByteArray): ByteArray =
        dispatch(operation, legacy, rust, ByteArray::contentEquals)

    private fun requireCompatibleAbi() {
        val abi = cachedAbiVersion ?: (abiVersionOverride?.invoke() ?: domainCoreAbiVersion()).also { cachedAbiVersion = it }
        check(abi == ABI_VERSION.toUInt()) { "CloudVault domain-core ABI mismatch" }
    }

    private fun record(operation: String, category: String) {
        val counter = diagnosticCounts.computeIfAbsent("$operation:$category") { AtomicLong() }
        val diagnostic = CloudVaultDomainCoreDiagnostic(operation, ABI_VERSION, category, counter.incrementAndGet())
        diagnosticOverride?.invoke(diagnostic) ?: runCatching {
            Log.w(
                LOG_TAG,
                "operation=${diagnostic.operation} version=${diagnostic.abiVersion} " +
                    "category=${diagnostic.category} count=${diagnostic.count}",
            )
        }
    }

    private fun elapsedMicros(startedNanos: Long): Long = ((System.nanoTime() - startedNanos) / 1_000)
        .coerceIn(0, 600_000_000)

    private fun sliceFor(operation: String): String = when {
        operation.contains("escrow") -> "escrow"
        operation.contains("recovery") -> "recovery"
        operation.contains("aes") || operation.contains("seal") || operation.contains("open") -> "aes"
        else -> "foundation"
    }

    private val CloudVaultHashPurpose.ffiValue: FfiHashPurpose
        get() = when (this) {
            CloudVaultHashPurpose.BLOB_INTEGRITY -> FfiHashPurpose.BLOB_INTEGRITY
            CloudVaultHashPurpose.SESSION_BODY -> FfiHashPurpose.SESSION_BODY
            CloudVaultHashPurpose.SESSION_CHUNK -> FfiHashPurpose.SESSION_CHUNK
            CloudVaultHashPurpose.PROJECT_MEMORY_CONTENT -> FfiHashPurpose.PROJECT_MEMORY_CONTENT
        }
}

internal object CloudVaultRecoveryDomainCore {
    fun recoveryWrappingKey(recoveryKey: String, legacy: () -> ByteArray): ByteArray = CloudVaultDomainCore.dispatchBytes(
        operation = "recovery_wrapping_key",
        legacy = legacy,
        rust = { cloudVaultRecoveryWrappingKey(recoveryKey) },
    )

    fun recoveryVerificationHash(recoveryKey: String, legacy: () -> String): String = CloudVaultDomainCore.dispatch(
        operation = "recovery_verification_hash",
        legacy = legacy,
        rust = { cloudVaultRecoveryVerificationHash(recoveryKey) },
    )

    fun recoveryWrapVaultKey(vaultKey: ByteArray, recoveryKey: String, nonce: ByteArray, legacy: () -> CloudVaultRecoveryBox): CloudVaultRecoveryBox =
        CloudVaultDomainCore.dispatch(
            operation = "recovery_wrap_vault_key",
            legacy = legacy,
            rust = {
                val wrapped = cloudVaultRecoveryWrapVaultKey(vaultKey, recoveryKey, nonce)
                CloudVaultRecoveryBox(wrapped.combined, wrapped.verificationHash)
            },
            equivalent = { left, right ->
                left.combined.contentEquals(right.combined) && left.verificationHash == right.verificationHash
            },
        )

    fun recoveryOpenVaultKey(combined: ByteArray, recoveryKey: String, legacy: () -> ByteArray): ByteArray = CloudVaultDomainCore.dispatchBytes(
        operation = "recovery_open_vault_key",
        legacy = legacy,
        rust = { cloudVaultRecoveryOpenVaultKey(combined, recoveryKey) },
    )

    fun escrowSplitWire(wire: ByteArray, legacy: () -> CloudVaultEscrowParts): CloudVaultEscrowParts = CloudVaultDomainCore.dispatch(
        operation = "escrow_split_wire",
        legacy = legacy,
        rust = {
            val parts = cloudVaultEscrowSplitWire(wire)
            CloudVaultEscrowParts(parts.ephemeralPublicKey, parts.aesGcmCombined)
        },
        equivalent = { left, right ->
            left.ephemeralPublicKey.contentEquals(right.ephemeralPublicKey) &&
                left.aesGcmCombined.contentEquals(right.aesGcmCombined)
        },
    )

    fun escrowSeal(plaintext: ByteArray, ephemeralPublicKey: ByteArray, sharedSecret: ByteArray, nonce: ByteArray, legacy: () -> ByteArray): ByteArray =
        CloudVaultDomainCore.dispatchBytes(
            operation = "escrow_seal",
            legacy = legacy,
            rust = { cloudVaultEscrowSeal(plaintext, ephemeralPublicKey, sharedSecret, nonce) },
        )

    fun escrowOpen(wire: ByteArray, sharedSecret: ByteArray, legacy: () -> ByteArray): ByteArray = CloudVaultDomainCore.dispatchBytes(
        operation = "escrow_open",
        legacy = legacy,
        rust = { cloudVaultEscrowOpen(wire, sharedSecret) },
    )
}

private object CloudVaultLegacyCrypto {
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12
    private const val GCM_TAG_BYTES = 16
    private const val KEY_BYTES = 32
    private const val BYTE_MASK = 0xff
    private const val HMAC_SALT = "OpenBurnBar-CloudVault-HMAC-Salt-v1"
    private const val HMAC_INFO_PREFIX = "OpenBurnBar-CloudVault-HMAC-v1"

    fun aadV1(uid: String, collection: String, docId: String, field: String): String {
        listOf(uid, collection, docId, field).forEach(::requireValidAadPart)
        return "${CloudVaultCrypto.LEGACY_AAD_CONTEXT_PREFIX}|$uid|$collection|$docId|$field"
    }

    fun aadV2(uid: String, collection: String, docId: String, field: String, schemaVersion: Int, purpose: String): String {
        require(schemaVersion >= 2) { "Invalid CloudVault AAD context" }
        listOf(uid, collection, docId, field, purpose).forEach(::requireValidAadPart)
        return "${CloudVaultCrypto.AAD_CONTEXT_PREFIX}|$uid|$collection|$docId|$field|$schemaVersion|$purpose"
    }

    fun sha256Hex(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).toHex()

    fun vaultKeyId(key: ByteArray): String {
        requireVaultKey(key)
        return "v1_${sha256Hex(key).take(32)}"
    }

    fun keyedHashHex(data: ByteArray, key: ByteArray, purpose: CloudVaultHashPurpose): String {
        requireVaultKey(key)
        val derivedKey = CloudVaultCryptoSearch.hkdfSha256(
            key,
            HMAC_SALT.toByteArray(Charsets.UTF_8),
            "$HMAC_INFO_PREFIX|${purpose.wireValue}".toByteArray(Charsets.UTF_8),
            KEY_BYTES,
        )
        return try {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(derivedKey, "HmacSHA256"))
            mac.doFinal(data).toHex()
        } finally {
            derivedKey.fill(0)
        }
    }

    fun expectedSessionBodyHash(data: ByteArray, key: ByteArray, bodyHashVersion: Int): String = when (bodyHashVersion) {
        CloudVaultCrypto.SESSION_BODY_HASH_VERSION -> keyedHashHex(data, key, CloudVaultHashPurpose.SESSION_BODY)
        0, 1 -> sha256Hex(data)
        else -> error("Unsupported session body hash version")
    }

    fun aesSealDetached(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): CloudVaultAesDetachedBox {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        val ciphertextAndTag = cipher.doFinal(plaintext)
        val split = ciphertextAndTag.size - GCM_TAG_BYTES
        return CloudVaultAesDetachedBox(
            nonce = nonce.copyOf(),
            ciphertext = ciphertextAndTag.copyOfRange(0, split),
            tag = ciphertextAndTag.copyOfRange(split, ciphertextAndTag.size),
        )
    }

    fun aesOpenCombined(combined: ByteArray, key: ByteArray, aad: ByteArray): ByteArray {
        require(combined.size >= GCM_NONCE_BYTES + GCM_TAG_BYTES) { "Invalid AES-GCM combined envelope length" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(GCM_AUTH_TAG_BITS, combined.copyOfRange(0, GCM_NONCE_BYTES)),
        )
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        return cipher.doFinal(combined.copyOfRange(GCM_NONCE_BYTES, combined.size))
    }

    fun requireAesInputs(key: ByteArray, nonce: ByteArray) {
        requireVaultKey(key)
        require(nonce.size == GCM_NONCE_BYTES) { "Invalid AES-GCM nonce length" }
    }

    fun requireTag(tag: ByteArray) {
        require(tag.size == GCM_TAG_BYTES) { "Invalid AES-GCM authentication tag length" }
    }

    fun requireVaultKey(key: ByteArray) {
        require(key.size == KEY_BYTES) { "Invalid vault key length" }
    }

    private fun requireValidAadPart(value: String) {
        require(value.isNotEmpty() && value.none { it == '|' || it.code < 0x20 || it.code == 0x7f }) {
            "Invalid CloudVault AAD context"
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }
}
