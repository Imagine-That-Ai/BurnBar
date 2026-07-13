package com.openburnbar.data.cloud

import android.util.Log
import com.openburnbar.BuildConfig
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentEnvelope as FfiEnvelope
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentEnvelopeKind as FfiEnvelopeKind
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentRewrapRequest as FfiRequest
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentRewrapResult as FfiResult
import uniffi.openburnbar_domain_ffi.CloudVaultResealNonce as FfiResealNonce
import uniffi.openburnbar_domain_ffi.cloudVaultRewrapDocument
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion

internal enum class CloudVaultDocumentRewrapMode(val wireValue: String) {
    LEGACY("legacy"),
    SHADOW("shadow"),
    RUST("rust"),
    ;

    companion object {
        fun parse(value: String): CloudVaultDocumentRewrapMode = entries.firstOrNull { it.wireValue == value.trim().lowercase() } ?: LEGACY
    }
}

internal data class CloudVaultDocumentRewrapDiagnostic(
    val operation: String,
    val category: String,
    val coreVersion: String,
    val count: Long,
)

internal data class CloudVaultDocumentRewrapNonce(
    val fieldName: String,
    val bytes: ByteArray,
)

/**
 * Typed whole-document boundary for CloudVault rotation. Firestore dictionaries, randomness, and
 * persistence remain on Android; Rust receives one complete operation and returns update intents.
 */
internal object CloudVaultDocumentRewrapDomainCore {
    private const val REQUIRED_ABI_VERSION = 3
    private const val GCM_NONCE_BYTES = 12
    private const val OPERATION = "document_rewrap"
    private const val LOG_TAG = "CloudVaultRewrapCore"
    private val secureRandom = SecureRandom()
    private val diagnosticCounts = ConcurrentHashMap<String, AtomicLong>()

    @Volatile
    private var cachedAbiVersion: UInt? = null

    @Volatile
    internal var modeOverride: CloudVaultDocumentRewrapMode? = null

    @Volatile
    internal var nativeRewrapOverride: ((FfiRequest, ByteArray, ByteArray, String) -> FfiResult)? = null

    @Volatile
    internal var abiVersionOverride: (() -> UInt)? = null

    @Volatile
    internal var coreVersionOverride: (() -> String)? = null

    @Volatile
    internal var nonceOverride: (() -> ByteArray)? = null

    @Volatile
    internal var diagnosticOverride: ((CloudVaultDocumentRewrapDiagnostic) -> Unit)? = null

    private val mode: CloudVaultDocumentRewrapMode
        get() = modeOverride ?: CloudVaultDocumentRewrapMode.parse(BuildConfig.CLOUDVAULT_REWRAP_DOMAIN_CORE_MODE)

    fun rewrap(
        data: Map<String, Any?>,
        uid: String,
        collection: String,
        docID: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobId: String?,
        legacy: (List<CloudVaultDocumentRewrapNonce>) -> CloudVaultDocumentRewrapResult,
    ): CloudVaultDocumentRewrapResult {
        val envelopes = lowerEnvelopes(data)
        val noncePlan = createNoncePlan(envelopes, newVaultKeyID)
        return when (mode) {
            CloudVaultDocumentRewrapMode.LEGACY -> legacy(noncePlan)
            CloudVaultDocumentRewrapMode.RUST ->
                rustRewrap(
                    data,
                    uid,
                    collection,
                    docID,
                    oldKey,
                    newKey,
                    newVaultKeyID,
                    vaultGeneration,
                    rotationJobId,
                    envelopes,
                    noncePlan,
                )
            CloudVaultDocumentRewrapMode.SHADOW -> {
                val legacyResult = legacy(noncePlan)
                val rustResult = runCatching {
                    rustRewrap(
                        data,
                        uid,
                        collection,
                        docID,
                        oldKey,
                        newKey,
                        newVaultKeyID,
                        vaultGeneration,
                        rotationJobId,
                        envelopes,
                        noncePlan,
                    )
                }
                when {
                    rustResult.isFailure -> record("rust_error")
                    !equivalent(legacyResult, rustResult.getOrThrow()) -> record("mismatch")
                }
                legacyResult
            }
        }
    }

    internal fun resetTestOverrides() {
        modeOverride = null
        nativeRewrapOverride = null
        abiVersionOverride = null
        coreVersionOverride = null
        nonceOverride = null
        diagnosticOverride = null
        cachedAbiVersion = null
        diagnosticCounts.clear()
    }

    private fun rustRewrap(
        data: Map<String, Any?>,
        uid: String,
        collection: String,
        docID: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobId: String?,
        envelopes: List<FfiEnvelope>,
        noncePlan: List<CloudVaultDocumentRewrapNonce>,
    ): CloudVaultDocumentRewrapResult {
        requireCompatibleAbi()
        require(!oldKey.contentEquals(newKey)) { "CloudVault rewrap requires distinct old and new keys" }
        require(CloudVaultCrypto.vaultKeyID(oldKey) != newVaultKeyID) {
            "CloudVault rewrap requires distinct old and new key ids"
        }
        val request =
            FfiRequest(
                uid = uid,
                collection = collection,
                docId = docID,
                documentFieldNames = data.keys.toList(),
                envelopes = envelopes,
                resealNoncePlan = noncePlan.map { planned ->
                    FfiResealNonce(fieldName = planned.fieldName, nonce = planned.bytes)
                },
                vaultGeneration = vaultGeneration?.toLong(),
                rotationJobId = rotationJobId,
            )
        val ownedOldKey = oldKey.copyOf()
        val ownedNewKey = newKey.copyOf()
        return try {
            val result =
                nativeRewrapOverride?.invoke(request, ownedOldKey, ownedNewKey, newVaultKeyID)
                    ?: cloudVaultRewrapDocument(request, ownedOldKey, ownedNewKey, newVaultKeyID)
            applyResult(data, result, newVaultKeyID, vaultGeneration, rotationJobId)
        } finally {
            ownedOldKey.fill(0)
            ownedNewKey.fill(0)
            noncePlan.forEach { it.bytes.fill(0) }
        }
    }

    private fun lowerEnvelopes(data: Map<String, Any?>): List<FfiEnvelope> = data.entries
        .mapNotNull { (field, value) ->
            val raw = value as? Map<*, *> ?: return@mapNotNull null
            lowerEnvelope(field, raw)
        }.sortedBy(FfiEnvelope::fieldName)

    private fun lowerEnvelope(field: String, raw: Map<*, *>): FfiEnvelope? {
        val payloadCandidate = raw.containsKey("vaultKeyID")
        val textCandidate = listOf("nonce", "ciphertext", "tag").any(raw::containsKey)
        val blobSpecific = listOf("plaintextSHA256", "plaintextHMAC", "integrityHashVersion", "createdAt").any(raw::containsKey)
        val blobCandidate = raw.containsKey("sealedBoxBase64") && (!payloadCandidate || blobSpecific)
        val candidateCount = listOf(payloadCandidate, textCandidate, blobCandidate).count { it }
        require(candidateCount <= 1) { "Ambiguous CloudVault envelope map" }
        if (candidateCount == 0) return null

        val algorithm = optionalString(raw, "algorithm") ?: CloudVaultCrypto.AES_GCM_ALGORITHM
        val keyVersion = optionalUInt(raw, "keyVersion") ?: CloudVaultCrypto.CURRENT_KEY_VERSION.toUInt()
        return when {
            payloadCandidate ->
                FfiEnvelope(
                    kind = FfiEnvelopeKind.SEALED_PAYLOAD,
                    fieldName = field,
                    schemaVersion = optionalUInt(raw, "schemaVersion") ?: 1u,
                    algorithm = algorithm,
                    keyVersion = keyVersion,
                    vaultKeyId = requiredString(raw, "vaultKeyID"),
                    nonce = null,
                    ciphertext = null,
                    tag = null,
                    sealedBoxBase64 = requiredString(raw, "sealedBoxBase64"),
                    plaintextSha256 = null,
                    plaintextHmac = null,
                    integrityHashVersion = null,
                    aad = optionalString(raw, "aad"),
                    hasCreatedAt = false,
                )
            textCandidate ->
                FfiEnvelope(
                    kind = FfiEnvelopeKind.SEALED_TEXT,
                    fieldName = field,
                    schemaVersion = optionalUInt(raw, "schemaVersion"),
                    algorithm = algorithm,
                    keyVersion = keyVersion,
                    vaultKeyId = null,
                    nonce = requiredString(raw, "nonce"),
                    ciphertext = requiredString(raw, "ciphertext"),
                    tag = requiredString(raw, "tag"),
                    sealedBoxBase64 = null,
                    plaintextSha256 = null,
                    plaintextHmac = null,
                    integrityHashVersion = null,
                    aad = optionalString(raw, "aad"),
                    hasCreatedAt = false,
                )
            else ->
                FfiEnvelope(
                    kind = FfiEnvelopeKind.BLOB,
                    fieldName = field,
                    schemaVersion = requiredUInt(raw, "schemaVersion"),
                    algorithm = algorithm,
                    keyVersion = keyVersion,
                    vaultKeyId = null,
                    nonce = null,
                    ciphertext = null,
                    tag = null,
                    sealedBoxBase64 = requiredString(raw, "sealedBoxBase64"),
                    plaintextSha256 = optionalString(raw, "plaintextSHA256"),
                    plaintextHmac = optionalString(raw, "plaintextHMAC"),
                    integrityHashVersion = optionalUInt(raw, "integrityHashVersion"),
                    aad = optionalString(raw, "aad"),
                    hasCreatedAt = raw.containsKey("createdAt"),
                )
        }
    }

    private fun createNoncePlan(envelopes: List<FfiEnvelope>, newVaultKeyID: String): List<CloudVaultDocumentRewrapNonce> {
        val seen = mutableSetOf<List<Byte>>()
        return envelopes
            .filter { it.kind != FfiEnvelopeKind.SEALED_PAYLOAD || it.vaultKeyId != newVaultKeyID }
            .map { envelope ->
                var selected: ByteArray? = null
                var attempts = 0
                while (selected == null && attempts < 32) {
                    attempts += 1
                    val nonce = (nonceOverride?.invoke() ?: ByteArray(GCM_NONCE_BYTES).also(secureRandom::nextBytes)).copyOf()
                    require(nonce.size == GCM_NONCE_BYTES) { "Invalid CloudVault rewrap nonce length" }
                    if (seen.add(nonce.toList())) {
                        selected = nonce
                    }
                }
                CloudVaultDocumentRewrapNonce(
                    envelope.fieldName,
                    requireNotNull(selected) { "Unable to create a unique CloudVault rewrap nonce" },
                )
            }
    }

    private fun applyResult(
        data: Map<String, Any?>,
        result: FfiResult,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobId: String?,
    ): CloudVaultDocumentRewrapResult {
        val changed = result.changedFields
        val skipped = result.skippedFields
        require(changed == changed.sorted() && changed.size == changed.toSet().size) { "Invalid CloudVault rewrap changed fields" }
        require(skipped == skipped.sorted() && skipped.size == skipped.toSet().size) { "Invalid CloudVault rewrap skipped fields" }
        require(changed.none(skipped::contains)) { "Invalid CloudVault rewrap field overlap" }
        val outputs = result.rewrappedEnvelopes.associateBy(FfiEnvelope::fieldName)
        require(outputs.size == result.rewrappedEnvelopes.size && outputs.keys == changed.toSet()) {
            "Invalid CloudVault rewrap envelope result"
        }

        val updated = data.toMutableMap()
        for (field in changed) {
            val output = requireNotNull(outputs[field])
            updated[field] = envelopeMap(output)
        }
        for (intent in result.preservedMemberIntents) {
            require(intent.sourceFieldName in changed && intent.memberName == "createdAt") {
                "Invalid CloudVault preserved-member intent"
            }
            val source = data[intent.sourceFieldName] as? Map<*, *> ?: error("Missing CloudVault source envelope")
            require(source.containsKey(intent.memberName)) { "Missing CloudVault preserved member" }
            val target =
                (updated[intent.sourceFieldName] as? Map<*, *>)
                    ?.entries
                    ?.associate { (key, value) ->
                        require(key is String) { "Invalid CloudVault envelope member name" }
                        key to value
                    }?.toMutableMap()
                    ?: error("Missing CloudVault result envelope")
            target[intent.memberName] = source[intent.memberName]
            updated[intent.sourceFieldName] = target
        }
        for (intent in result.companionUpdateIntents) {
            require(intent.sourceFieldName in changed && data.containsKey(intent.companionFieldName)) {
                "Invalid CloudVault companion-update intent"
            }
            require(intent.vaultKeyId == newVaultKeyID) { "Invalid CloudVault companion vault key id" }
            updated[intent.companionFieldName] = intent.vaultKeyId
        }
        val expectedGenerationUpdate = if (changed.isNotEmpty()) vaultGeneration?.toLong() else null
        val expectedRotationJobUpdate = if (changed.isNotEmpty()) rotationJobId else null
        require(result.vaultGenerationUpdate == expectedGenerationUpdate) { "Invalid CloudVault generation intent" }
        require(result.rotationJobIdUpdate == expectedRotationJobUpdate) { "Invalid CloudVault rotation-job intent" }
        result.vaultGenerationUpdate?.let {
            require(vaultGeneration != null && it == vaultGeneration.toLong()) { "Invalid CloudVault generation update" }
            updated["vaultGeneration"] = vaultGeneration
        }
        result.rotationJobIdUpdate?.let {
            require(rotationJobId != null && it == rotationJobId) { "Invalid CloudVault rotation-job update" }
            updated["rewrapJobId"] = rotationJobId
        }
        return CloudVaultDocumentRewrapResult(updated.toMap(), changed)
    }

    private fun envelopeMap(envelope: FfiEnvelope): Map<String, Any?> = buildMap {
        envelope.schemaVersion?.let { put("schemaVersion", it.toInt()) }
        put("algorithm", envelope.algorithm)
        put("keyVersion", envelope.keyVersion.toInt())
        envelope.vaultKeyId?.let { put("vaultKeyID", it) }
        envelope.nonce?.let { put("nonce", it) }
        envelope.ciphertext?.let { put("ciphertext", it) }
        envelope.tag?.let { put("tag", it) }
        envelope.sealedBoxBase64?.let { put("sealedBoxBase64", it) }
        envelope.plaintextSha256?.let { put("plaintextSHA256", it) }
        envelope.plaintextHmac?.let { put("plaintextHMAC", it) }
        envelope.integrityHashVersion?.let { put("integrityHashVersion", it.toInt()) }
        envelope.aad?.let { put("aad", it) }
    }

    private fun requireCompatibleAbi() {
        val abi = cachedAbiVersion ?: (abiVersionOverride?.invoke() ?: domainCoreAbiVersion()).also { cachedAbiVersion = it }
        check(abi == REQUIRED_ABI_VERSION.toUInt()) { "CloudVault document-rewrap domain-core ABI mismatch" }
    }

    private fun equivalent(left: CloudVaultDocumentRewrapResult, right: CloudVaultDocumentRewrapResult): Boolean =
        left.changedFields == right.changedFields && left.data == right.data

    private fun record(category: String) {
        val count = diagnosticCounts.computeIfAbsent(category) { AtomicLong() }.incrementAndGet()
        val diagnostic =
            CloudVaultDocumentRewrapDiagnostic(
                operation = OPERATION,
                category = category,
                coreVersion = runCatching { coreVersionOverride?.invoke() ?: domainCoreVersion() }.getOrDefault("unavailable"),
                count = count,
            )
        diagnosticOverride?.invoke(diagnostic) ?: runCatching {
            Log.w(
                LOG_TAG,
                "operation=${diagnostic.operation} category=${diagnostic.category} " +
                    "core_version=${diagnostic.coreVersion} count=${diagnostic.count}",
            )
        }
    }

    private fun requiredString(raw: Map<*, *>, name: String): String =
        (raw[name] as? String) ?: throw IllegalArgumentException("Invalid CloudVault envelope member")

    private fun optionalString(raw: Map<*, *>, name: String): String? {
        if (!raw.containsKey(name)) return null
        return requiredString(raw, name)
    }

    private fun requiredUInt(raw: Map<*, *>, name: String): UInt =
        optionalUInt(raw, name) ?: throw IllegalArgumentException("Invalid CloudVault envelope member")

    private fun optionalUInt(raw: Map<*, *>, name: String): UInt? {
        if (!raw.containsKey(name)) return null
        val number = raw[name] as? Number ?: throw IllegalArgumentException("Invalid CloudVault envelope member")
        val asLong = number.toLong()
        require(asLong >= 0 && number.toDouble() == asLong.toDouble() && asLong <= UInt.MAX_VALUE.toLong()) {
            "Invalid CloudVault envelope member"
        }
        return asLong.toUInt()
    }
}
