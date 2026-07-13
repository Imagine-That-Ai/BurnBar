package com.openburnbar.data.cloud

import android.util.Log
import com.openburnbar.BuildConfig
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import uniffi.openburnbar_domain_ffi.CloudVaultHashPurpose as FfiHashPurpose
import uniffi.openburnbar_domain_ffi.cloudVaultAadV1
import uniffi.openburnbar_domain_ffi.cloudVaultAadV2
import uniffi.openburnbar_domain_ffi.cloudVaultExpectedSessionBodyHash
import uniffi.openburnbar_domain_ffi.cloudVaultKeyId
import uniffi.openburnbar_domain_ffi.cloudVaultKeyedHashHex
import uniffi.openburnbar_domain_ffi.cloudVaultSha256Hex

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

internal object CloudVaultDomainCore {
    private const val ABI_VERSION = 2
    private const val KEY_BYTES = 32
    private const val BYTE_MASK = 0xff
    private const val HMAC_SALT = "OpenBurnBar-CloudVault-HMAC-Salt-v1"
    private const val HMAC_INFO_PREFIX = "OpenBurnBar-CloudVault-HMAC-v1"
    private const val LOG_TAG = "CloudVaultDomainCore"
    private val diagnosticCounts = ConcurrentHashMap<String, AtomicLong>()

    @Volatile
    internal var modeOverride: CloudVaultDomainCoreMode? = null

    @Volatile
    internal var diagnosticOverride: ((CloudVaultDomainCoreDiagnostic) -> Unit)? = null

    private val mode: CloudVaultDomainCoreMode
        get() = modeOverride ?: CloudVaultDomainCoreMode.parse(BuildConfig.CLOUDVAULT_DOMAIN_CORE_MODE)

    fun aadV1(uid: String, collection: String, docId: String, field: String): String = dispatch(
        operation = "aad_v1",
        legacy = { legacyAadV1(uid, collection, docId, field) },
        rust = { cloudVaultAadV1(uid, collection, docId, field) },
    )

    fun aadV2(uid: String, collection: String, docId: String, field: String, schemaVersion: Int, purpose: String): String = dispatch(
        operation = "aad_v2",
        legacy = { legacyAadV2(uid, collection, docId, field, schemaVersion, purpose) },
        rust = { cloudVaultAadV2(uid, collection, docId, field, schemaVersion.toUInt(), purpose) },
    )

    fun sha256Hex(data: ByteArray): String = dispatch(
        operation = "sha256_hex",
        legacy = { legacySha256Hex(data) },
        rust = { cloudVaultSha256Hex(data) },
    )

    fun vaultKeyId(key: ByteArray): String {
        requireVaultKey(key)
        return dispatch(
            operation = "vault_key_id",
            legacy = { legacyVaultKeyId(key) },
            rust = { cloudVaultKeyId(key) },
        )
    }

    fun keyedHashHex(data: ByteArray, key: ByteArray, purpose: CloudVaultHashPurpose): String {
        requireVaultKey(key)
        return dispatch(
            operation = purpose.wireValue.replace('-', '_'),
            legacy = { legacyKeyedHashHex(data, key, purpose) },
            rust = { cloudVaultKeyedHashHex(data, key, purpose.ffiValue) },
        )
    }

    fun expectedSessionBodyHash(data: ByteArray, key: ByteArray, bodyHashVersion: Int): String = dispatch(
        operation = "expected_session_body_hash_v$bodyHashVersion",
        legacy = { legacyExpectedSessionBodyHash(data, key, bodyHashVersion) },
        rust = {
            require(bodyHashVersion >= 0) { "Unsupported session body hash version" }
            cloudVaultExpectedSessionBodyHash(data, key, bodyHashVersion.toUInt())
        },
    )

    internal fun <T> dispatchForTest(selectedMode: CloudVaultDomainCoreMode, operation: String, legacy: () -> T, rust: () -> T): T =
        dispatch(selectedMode, operation, legacy, rust)

    internal fun resetTestOverrides() {
        modeOverride = null
        diagnosticOverride = null
        diagnosticCounts.clear()
    }

    private fun <T> dispatch(operation: String, legacy: () -> T, rust: () -> T): T = dispatch(mode, operation, legacy, rust)

    private fun <T> dispatch(selectedMode: CloudVaultDomainCoreMode, operation: String, legacy: () -> T, rust: () -> T): T = when (selectedMode) {
        CloudVaultDomainCoreMode.LEGACY -> legacy()
        CloudVaultDomainCoreMode.RUST -> rust()
        CloudVaultDomainCoreMode.SHADOW -> {
            val legacyResult = legacy()
            val rustResult = runCatching(rust)
            when {
                rustResult.isFailure -> record(operation, "rust_error")
                rustResult.getOrThrow() != legacyResult -> record(operation, "mismatch")
            }
            legacyResult
        }
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

    private fun legacyAadV1(uid: String, collection: String, docId: String, field: String): String {
        listOf(uid, collection, docId, field).forEach(::requireValidAadPart)
        return "${CloudVaultCrypto.LEGACY_AAD_CONTEXT_PREFIX}|$uid|$collection|$docId|$field"
    }

    private fun legacyAadV2(uid: String, collection: String, docId: String, field: String, schemaVersion: Int, purpose: String): String {
        require(schemaVersion >= 2) { "Invalid CloudVault AAD context" }
        listOf(uid, collection, docId, field, purpose).forEach(::requireValidAadPart)
        return "${CloudVaultCrypto.AAD_CONTEXT_PREFIX}|$uid|$collection|$docId|$field|$schemaVersion|$purpose"
    }

    private fun requireValidAadPart(value: String) {
        require(value.isNotEmpty() && value.none { it == '|' || it.code < 0x20 || it.code == 0x7f }) {
            "Invalid CloudVault AAD context"
        }
    }

    private fun legacyVaultKeyId(key: ByteArray): String {
        requireVaultKey(key)
        return "v1_${legacySha256Hex(key).take(32)}"
    }

    private fun legacyExpectedSessionBodyHash(data: ByteArray, key: ByteArray, bodyHashVersion: Int): String = when (bodyHashVersion) {
        CloudVaultCrypto.SESSION_BODY_HASH_VERSION -> legacyKeyedHashHex(data, key, CloudVaultHashPurpose.SESSION_BODY)
        0, 1 -> legacySha256Hex(data)
        else -> error("Unsupported session body hash version")
    }

    private fun legacyKeyedHashHex(data: ByteArray, key: ByteArray, purpose: CloudVaultHashPurpose): String {
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

    private fun requireVaultKey(key: ByteArray) {
        require(key.size == KEY_BYTES) { "Invalid vault key length" }
    }

    private fun legacySha256Hex(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).toHex()

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }

    private val CloudVaultHashPurpose.ffiValue: FfiHashPurpose
        get() = when (this) {
            CloudVaultHashPurpose.BLOB_INTEGRITY -> FfiHashPurpose.BLOB_INTEGRITY
            CloudVaultHashPurpose.SESSION_BODY -> FfiHashPurpose.SESSION_BODY
            CloudVaultHashPurpose.SESSION_CHUNK -> FfiHashPurpose.SESSION_CHUNK
            CloudVaultHashPurpose.PROJECT_MEMORY_CONTENT -> FfiHashPurpose.PROJECT_MEMORY_CONTENT
        }
}
