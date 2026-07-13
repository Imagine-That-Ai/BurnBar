package com.openburnbar.data.cloud

import android.util.Log
import com.openburnbar.BuildConfig
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import uniffi.openburnbar_domain_ffi.CloudVaultSearchOperation as FfiSearchOperation
import uniffi.openburnbar_domain_ffi.CloudVaultSearchRequest
import uniffi.openburnbar_domain_ffi.CloudVaultSearchResult
import uniffi.openburnbar_domain_ffi.cloudVaultSearch
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion

internal enum class CloudVaultSearchMode(val wireValue: String) {
    LEGACY("legacy"),
    SHADOW("shadow"),
    RUST("rust"),
    ;

    companion object {
        fun parse(value: String): CloudVaultSearchMode = entries.firstOrNull { it.wireValue == value.trim().lowercase() }
            ?: LEGACY
    }
}

internal enum class CloudVaultSearchOperation(val diagnosticName: String) {
    TOKEN("token"),
    INDEX("index"),
    QUERY("query"),
    SEMANTIC("semantic"),
}

internal data class CloudVaultSearchDiagnostic(
    val category: String,
    val coreVersion: String,
    val count: Long,
)

/**
 * Rollout boundary for the pure CloudVault search transforms. Callers retain key custody and all
 * persistence; each invocation lowers one complete text/query into one UniFFI call.
 */
internal object CloudVaultSearchDomainCore {
    private const val REQUIRED_ABI_VERSION = 3
    private const val LOG_TAG = "CloudVaultSearchCore"
    private val diagnosticCounts = ConcurrentHashMap<String, AtomicLong>()

    @Volatile
    private var cachedAbiVersion: UInt? = null

    @Volatile
    internal var modeOverride: CloudVaultSearchMode? = null

    @Volatile
    internal var nativeSearchOverride: ((CloudVaultSearchRequest) -> CloudVaultSearchResult)? = null

    @Volatile
    internal var abiVersionOverride: (() -> UInt)? = null

    @Volatile
    internal var coreVersionOverride: (() -> String)? = null

    @Volatile
    internal var diagnosticOverride: ((CloudVaultSearchDiagnostic) -> Unit)? = null

    private val mode: CloudVaultSearchMode
        get() = modeOverride ?: CloudVaultSearchMode.parse(BuildConfig.CLOUDVAULT_SEARCH_DOMAIN_CORE_MODE)

    fun search(operation: CloudVaultSearchOperation, text: String, vaultKey: ByteArray, limit: Int, legacy: () -> List<String>): List<String> = when (mode) {
        CloudVaultSearchMode.LEGACY -> legacy()
        CloudVaultSearchMode.RUST -> rustSearch(operation, text, vaultKey, limit)
        CloudVaultSearchMode.SHADOW -> {
            val legacyHashes = legacy()
            val rustHashes = runCatching { rustSearch(operation, text, vaultKey, limit) }
            when {
                rustHashes.isFailure -> record("${operation.diagnosticName}_rust_error")
                legacyHashes != rustHashes.getOrThrow() -> record("${operation.diagnosticName}_mismatch")
            }
            legacyHashes
        }
    }

    internal fun resetTestOverrides() {
        modeOverride = null
        nativeSearchOverride = null
        abiVersionOverride = null
        coreVersionOverride = null
        diagnosticOverride = null
        cachedAbiVersion = null
        diagnosticCounts.clear()
    }

    private fun rustSearch(operation: CloudVaultSearchOperation, text: String, vaultKey: ByteArray, limit: Int): List<String> {
        requireCompatibleAbi()
        val ownedKey = vaultKey.copyOf()
        val request = CloudVaultSearchRequest(operation.ffiValue, text, ownedKey, limit)
        return try {
            val result = nativeSearchOverride?.invoke(request) ?: cloudVaultSearch(request)
            check(result.operation == request.operation) { "CloudVault search operation mismatch" }
            result.hashes
        } finally {
            ownedKey.fill(0)
        }
    }

    private fun requireCompatibleAbi() {
        val abiVersion = cachedAbiVersion ?: (abiVersionOverride?.invoke() ?: domainCoreAbiVersion()).also { cachedAbiVersion = it }
        check(abiVersion == REQUIRED_ABI_VERSION.toUInt()) { "CloudVault search domain-core ABI mismatch" }
    }

    private fun record(category: String) {
        val counter = diagnosticCounts.computeIfAbsent(category) { AtomicLong() }
        val diagnostic = CloudVaultSearchDiagnostic(
            category = category,
            coreVersion = runCatching { coreVersionOverride?.invoke() ?: domainCoreVersion() }.getOrDefault("unavailable"),
            count = counter.incrementAndGet(),
        )
        diagnosticOverride?.invoke(diagnostic) ?: runCatching {
            Log.w(
                LOG_TAG,
                "category=${diagnostic.category} core_version=${diagnostic.coreVersion} count=${diagnostic.count}",
            )
        }
    }

    private val CloudVaultSearchOperation.ffiValue: FfiSearchOperation
        get() = when (this) {
            CloudVaultSearchOperation.TOKEN -> FfiSearchOperation.TOKEN
            CloudVaultSearchOperation.INDEX -> FfiSearchOperation.INDEX
            CloudVaultSearchOperation.QUERY -> FfiSearchOperation.QUERY
            CloudVaultSearchOperation.SEMANTIC -> FfiSearchOperation.SEMANTIC
        }
}
