package com.openburnbar.data

import android.content.Context
import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.CloudVaultDocumentRewrapDomainCore
import com.openburnbar.data.cloud.CloudVaultDomainCore
import com.openburnbar.data.cloud.CloudVaultSearchDomainCore
import com.openburnbar.data.cloud.CloudVaultShadowComparison
import com.openburnbar.data.hermes.relay.HermesDomainCoreAdapter
import com.openburnbar.data.hermes.relay.HermesShadowComparison
import java.io.File
import java.io.IOException
import java.math.BigDecimal
import java.math.BigInteger
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeFormatterBuilder
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import org.json.JSONObject
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreSourceFingerprint
import uniffi.openburnbar_domain_ffi.domainCoreVersion

private const val SHADOW_SCHEMA_VERSION = 3
private const val DEFAULT_MAX_FILE_BYTES = 256 * 1024
private const val DEFAULT_MAX_READY_FILES = 8
private const val DEFAULT_MAX_SAMPLES_PER_FILE = 100
private const val READY_ORDINAL_WIDTH = 19
private const val MAX_LATENCY_MICROS = 600_000_000L
private const val UPLOAD_DEBOUNCE_MILLIS = 5_000L
private const val RETRY_DELAY_MILLIS = 30_000L
private val MAX_SAMPLE_AGE: Duration = Duration.ofDays(31)
private val FUTURE_SAMPLE_SKEW: Duration = Duration.ofMinutes(5)
private val UTC_MILLIS_FORMATTER = DateTimeFormatterBuilder().appendInstant(3).toFormatter()
private val V3_SAMPLE_KEYS = setOf(
    "schemaVersion", "sampleId", "domain", "slice", "consumer", "channel", "operation",
    "candidateCommit", "expectedCoreVersion", "expectedCoreAbiVersion", "expectedCoreSourceSha256",
    "loadedCoreVersion", "loadedCoreAbiVersion", "loadedCoreSourceSha256", "observedAt", "outcome",
    "mismatchCategory", "legacyMicros", "rustMicros",
)
private val UUID_V4 = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
private val CANONICAL_CORE_VERSION = Regex(
    "^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)" +
        "(?:-((?:0|[1-9]\\d*|\\d*[A-Za-z-][0-9A-Za-z-]*)" +
        "(?:\\.(?:0|[1-9]\\d*|\\d*[A-Za-z-][0-9A-Za-z-]*))*))?" +
        "(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$",
)
private val GIT_COMMIT = Regex("^[0-9a-f]{40}$")
private val SHA256 = Regex("^[0-9a-f]{64}$")
private val UTC_TIMESTAMP = Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$")

internal data class AndroidDomainCoreLoadedIdentity(
    val coreVersion: String,
    val abiVersion: Long,
    val sourceSha256: String,
)

internal data class AndroidDomainCoreShadowSampleV3(
    val sampleId: String,
    val domain: String,
    val slice: String,
    val channel: String,
    val operation: String,
    val candidateCommit: String,
    val expectedCoreVersion: String,
    val expectedCoreAbiVersion: Long,
    val expectedCoreSourceSha256: String,
    val loadedCoreVersion: String?,
    val loadedCoreAbiVersion: Long?,
    val loadedCoreSourceSha256: String?,
    val observedAt: String,
    val outcome: String,
    val mismatchCategory: String?,
    val legacyMicros: Long,
    val rustMicros: Long,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "schemaVersion" to SHADOW_SCHEMA_VERSION,
        "sampleId" to sampleId,
        "domain" to domain,
        "slice" to slice,
        "consumer" to "android",
        "channel" to channel,
        "operation" to operation,
        "candidateCommit" to candidateCommit,
        "expectedCoreVersion" to expectedCoreVersion,
        "expectedCoreAbiVersion" to expectedCoreAbiVersion,
        "expectedCoreSourceSha256" to expectedCoreSourceSha256,
        "loadedCoreVersion" to loadedCoreVersion,
        "loadedCoreAbiVersion" to loadedCoreAbiVersion,
        "loadedCoreSourceSha256" to loadedCoreSourceSha256,
        "observedAt" to observedAt,
        "outcome" to outcome,
        "mismatchCategory" to mismatchCategory,
        "legacyMicros" to legacyMicros,
        "rustMicros" to rustMicros,
    )
}

internal class AndroidDomainCoreShadowSpool(
    private val directory: File,
    private val maxFileBytes: Int = DEFAULT_MAX_FILE_BYTES,
    private val maxReadyFiles: Int = DEFAULT_MAX_READY_FILES,
    private val maxSamplesPerFile: Int = DEFAULT_MAX_SAMPLES_PER_FILE,
) {
    data class Batch(val file: File, val samples: List<Map<String, Any?>>)

    private val active = File(directory, "active.jsonl")
    private var ordinal = 0L

    init {
        require(maxFileBytes > 0 && maxReadyFiles > 0 && maxSamplesPerFile > 0)
        check(directory.mkdirs() || directory.isDirectory)
        ordinal = readyFiles().maxOfOrNull { it.name.substringAfter("ready-").substringBefore('-').toLongOrNull() ?: 0 } ?: 0
    }

    @Synchronized
    fun append(sample: AndroidDomainCoreShadowSampleV3) {
        val line = sample.toMap().toExactJSONObject().toString() + "\n"
        require(line.toByteArray().size <= maxFileBytes)
        if (active.length() + line.toByteArray().size > maxFileBytes || activeLineCount() >= maxSamplesPerFile) sealActive()
        active.appendText(line)
    }

    @Synchronized
    fun prepareForCandidate(expectedChannel: String, expectedCandidate: AndroidDomainCoreCandidateIdentity, now: Instant = Instant.now()) {
        require(expectedChannel == "internal" || expectedChannel == "beta")
        sealActive()
        readyFiles().forEach { file ->
            val samples = try {
                readSamples(file)
            } catch (_: IOException) {
                return@forEach
            }
            if (samples?.any { it.isUploadable(expectedChannel, expectedCandidate, now) } != true) {
                check(file.delete())
            }
        }
    }

    @Synchronized
    fun discardAll() {
        check(!active.exists() || active.delete())
        readyFiles().forEach { file -> check(file.delete()) }
    }

    @Synchronized
    fun nextBatch(sealActive: Boolean, expectedChannel: String, expectedCandidate: AndroidDomainCoreCandidateIdentity, now: Instant = Instant.now()): Batch? {
        require(expectedChannel == "internal" || expectedChannel == "beta")
        if (sealActive) sealActive()
        while (true) {
            val file = readyFiles().firstOrNull() ?: return null
            val samples = readSamples(file)
                ?.filter { it.isUploadable(expectedChannel, expectedCandidate, now) }
            if (samples.isNullOrEmpty()) {
                check(file.delete())
                continue
            }
            return Batch(file, samples)
        }
    }

    @Synchronized
    fun acknowledge(batch: Batch) {
        check(batch.file.parentFile?.canonicalFile == directory.canonicalFile)
        check(batch.file.name.startsWith("ready-") && batch.file.extension == "jsonl")
        check(!batch.file.exists() || batch.file.delete())
    }

    private fun activeLineCount(): Int = if (active.exists()) active.useLines { it.count(String::isNotBlank) } else 0

    @Throws(IOException::class)
    private fun readSamples(file: File): List<Map<String, Any?>>? {
        val lines = file.readLines().filter(String::isNotBlank)
        if (lines.isEmpty() || lines.size > maxSamplesPerFile) return null
        return lines.mapNotNull { line -> runCatching { JSONObject(line).toMap() }.getOrNull() }
    }

    private fun sealActive() {
        if (!active.exists() || active.length() == 0L) return
        val ready = readyFiles().toMutableList()
        while (ready.size >= maxReadyFiles) check(ready.removeAt(0).delete())
        ordinal = maxOf(ordinal + 1, System.currentTimeMillis())
        check(active.renameTo(File(directory, "ready-${ordinal.toString().padStart(READY_ORDINAL_WIDTH, '0')}-${UUID.randomUUID()}.jsonl")))
    }

    private fun readyFiles(): List<File> = directory.listFiles()
        ?.filter { it.isFile && it.name.startsWith("ready-") && it.extension == "jsonl" }
        ?.sortedBy(File::getName)
        .orEmpty()

    private fun Map<String, Any?>.isUploadable(expectedChannel: String, expectedCandidate: AndroidDomainCoreCandidateIdentity, now: Instant): Boolean {
        if (keys != V3_SAMPLE_KEYS || this["schemaVersion"].wholeLong() != SHADOW_SCHEMA_VERSION.toLong()) return false
        if ((this["sampleId"] as? String)?.matches(UUID_V4) != true || this["consumer"] != "android") return false
        val domain = this["domain"] as? String ?: return false
        val slice = this["slice"] as? String ?: return false
        val operation = this["operation"] as? String ?: return false
        if (AndroidDomainCoreShadowEvidence.allowedOperations[domain]?.get(slice)?.contains(operation) != true) return false
        if (this["channel"] != expectedChannel || (this["candidateCommit"] as? String)?.matches(GIT_COMMIT) != true) return false
        if (this["candidateCommit"] != expectedCandidate.candidateCommit) return false
        val expectedVersion = this["expectedCoreVersion"] as? String ?: return false
        val expectedAbi = this["expectedCoreAbiVersion"].wholeLong() ?: return false
        val expectedSource = this["expectedCoreSourceSha256"] as? String ?: return false
        if (!expectedVersion.matches(CANONICAL_CORE_VERSION) || expectedVersion != expectedCandidate.coreVersion) return false
        if (expectedAbi !in 1..0xffff_ffffL || expectedAbi != expectedCandidate.abiVersion) return false
        if (!expectedSource.matches(SHA256) || expectedSource != expectedCandidate.sourceSha256) return false

        val loadedVersion = this["loadedCoreVersion"]
        val loadedAbiValue = this["loadedCoreAbiVersion"]
        val loadedSource = this["loadedCoreSourceSha256"]
        val loadedIsNull = loadedVersion == null && loadedAbiValue == null && loadedSource == null
        val loadedIsPresent = loadedVersion is String && loadedAbiValue != null && loadedSource is String
        if (!loadedIsNull && !loadedIsPresent) return false
        val loadedAbi = if (loadedIsPresent) loadedAbiValue.wholeLong() ?: return false else null
        if (loadedIsPresent && (
                !(loadedVersion as String).matches(CANONICAL_CORE_VERSION) ||
                    loadedAbi !in 1..0xffff_ffffL ||
                    !(loadedSource as String).matches(SHA256)
                )
        ) {
            return false
        }
        val loadedMatchesExpected = loadedIsPresent &&
            loadedVersion == expectedVersion && loadedAbi == expectedAbi && loadedSource == expectedSource

        val outcome = this["outcome"] as? String ?: return false
        val mismatchCategory = this["mismatchCategory"] as? String
        val validOutcome = (outcome == "match" && mismatchCategory == null) ||
            (outcome == "mismatch" && mismatchCategory in AndroidDomainCoreShadowEvidence.mismatchCategories)
        if (!validOutcome) return false
        val requiresExpectedIdentity = outcome == "match" ||
            mismatchCategory == "result_mismatch" || mismatchCategory == "invalid_result" || mismatchCategory == "native_error"
        if (requiresExpectedIdentity && !loadedMatchesExpected) return false
        if (mismatchCategory == "native_unavailable" && !loadedIsNull) return false
        if (mismatchCategory == "loaded_identity_mismatch" && (!loadedIsPresent || loadedMatchesExpected)) return false

        val observedAt = (this["observedAt"] as? String)?.takeIf(UTC_TIMESTAMP::matches) ?: return false
        val observedInstant = runCatching { Instant.parse(observedAt) }.getOrNull() ?: return false
        if (observedInstant.isBefore(now.minus(MAX_SAMPLE_AGE)) || observedInstant.isAfter(now.plus(FUTURE_SAMPLE_SKEW))) return false
        val legacyMicros = this["legacyMicros"].wholeLong() ?: return false
        val rustMicros = this["rustMicros"].wholeLong() ?: return false
        return legacyMicros in 0..MAX_LATENCY_MICROS && rustMicros in 0..MAX_LATENCY_MICROS
    }

    private fun Any?.wholeLong(): Long? {
        val number = this as? Number ?: return null
        val value = number.toLong()
        return value.takeIf { number.toDouble().isFinite() && number.toDouble() == value.toDouble() }
    }
}

private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        else -> value
    }
}

internal fun Map<String, Any?>.toExactJSONObject(): JSONObject = JSONObject().also { json ->
    forEach { (key, value) -> json.put(key, value ?: JSONObject.NULL) }
}

internal object AndroidDomainCoreShadowEvidence {
    internal val allowedOperations = mapOf(
        "cloudvault" to mapOf(
            "foundation" to setOf(
                "aad_v1", "aad_v2", "resolve_aad", "sha256", "sha256_hex", "vault_key_id",
                "blob_integrity", "session_body", "session_chunk", "project_memory_content",
                "blob_integrity_hash", "session_body_hash", "session_chunk_hash", "project_memory_content_hash",
                "keyed_hash_blob_integrity", "expected_session_body_hash", "expected_session_body_hash_v0",
                "expected_session_body_hash_v1", "expected_session_body_hash_v2", "base64_encode", "base64_decode",
                "base64_decode_strict", "p256_validate_public_key", "initialize", "cloudvault_aad_v1",
                "cloudvault_aad_v2", "cloudvault_resolve_aad", "cloudvault_sha256", "cloudvault_key_id",
                "cloudvault_keyed_hash", "cloudvault_base64_encode", "cloudvault_base64_decode",
                "cloudvault_validate_p256_public_key",
            ),
            "aes" to setOf(
                "aes_gcm_seal_detached", "aes_gcm_seal_combined", "aes_gcm_open_detached",
                "aes_gcm_open_text_detached", "aes_gcm_open_combined", "aes_seal_detached",
                "aes_seal_combined", "aes_open_detached", "aes_open_text", "aes_open_combined",
                "cloudvault_aes_seal_detached", "cloudvault_aes_seal_combined",
                "cloudvault_aes_open_detached", "cloudvault_aes_open_text", "cloudvault_aes_open_combined",
            ),
            "recovery" to setOf(
                "recovery_normalize", "recovery_wrapping_key", "recovery_verification_hash",
                "recovery_wrap_vault_key", "recovery_open_vault_key", "cloudvault_recovery_wrapping_key",
                "cloudvault_recovery_verification_hash", "cloudvault_recovery_wrap_vault_key",
                "cloudvault_recovery_open_vault_key",
            ),
            "escrow" to setOf(
                "escrow_wrapping_key", "escrow_assemble_wire", "escrow_split_wire", "escrow_seal", "escrow_open",
                "cloudvault_escrow_split_wire", "cloudvault_escrow_seal", "cloudvault_escrow_open",
            ),
            "document-rewrap" to setOf("document_rewrap"),
            "search" to setOf("token", "index", "query", "semantic"),
        ),
        "hermes" to mapOf(
            "aad" to setOf("aad"),
            "payload-keywrap" to setOf("key_wrap_info_v1", "key_wrap_info_v2", "seal", "open", "safety_code", "hkdf"),
            "hpke-info" to setOf("hpke_v3_info"),
            "ratchet" to setOf(
                "ratchet_aad", "ratchet_root_kdf", "ratchet_chain_kdf", "ratchet_message_kdf",
                "ratchet_seal", "ratchet_open",
            ),
        ),
    )
    internal val mismatchCategories = setOf(
        "result_mismatch",
        "native_unavailable",
        "native_error",
        "invalid_result",
        "loaded_identity_mismatch",
    )
    private val flushMutex = Mutex()
    private var spool: AndroidDomainCoreShadowSpool? = null
    private var flushJob: Job? = null
    private var installed = false
    private var installedChannel: DomainCoreEvidenceChannel? = null
    private var installedCandidate: AndroidDomainCoreCandidateIdentity? = null
    internal var loadedIdentityOverride: (() -> AndroidDomainCoreLoadedIdentity?)? = null

    fun discardStoredSamples(context: Context) {
        if (activeSignedProfile() != null) return
        runCatching {
            cleanupEvidenceRoot(File(context.filesDir, "domain_core_shadow"), preservingNamespace = null)
        }.onFailure { logWarning("Shadow evidence cleanup failed", it) }
    }

    fun install(context: Context, channel: DomainCoreEvidenceChannel) {
        val profile = activeSignedProfile()?.takeIf { it.evidenceChannel == channel } ?: return
        val candidate = profile.candidateIdentity ?: return
        if (installed) return
        synchronized(this) {
            val currentProfile = activeSignedProfile()?.takeIf { it.evidenceChannel == channel } ?: return
            if (currentProfile.candidateIdentity != candidate) return
            if (installed) return
            val baseDirectory = File(context.filesDir, "domain_core_shadow")
            val preparedSpool = runCatching {
                AndroidDomainCoreShadowSpool(
                    prepareCandidateDirectory(baseDirectory, candidate),
                ).also {
                    it.prepareForCandidate(channel.wireValue, candidate)
                }
            }.getOrElse {
                spool = null
                installedChannel = null
                installedCandidate = null
                logWarning("Shadow evidence setup disabled", it)
                return
            }
            spool = preparedSpool
            installedChannel = channel
            installedCandidate = candidate
            installed = true
            CloudVaultDomainCore.comparisonOverride = ::record
            CloudVaultDocumentRewrapDomainCore.comparisonOverride = ::record
            CloudVaultSearchDomainCore.comparisonOverride = ::record
            HermesDomainCoreAdapter.comparisonOverride = ::record
            FirebaseAuth.getInstance().addAuthStateListener { auth ->
                if (auth.currentUser != null) scheduleFlush(0)
            }
            scheduleFlush(0)
        }
    }

    private fun record(comparison: CloudVaultShadowComparison) = record(
        comparison.domain,
        comparison.slice,
        comparison.operation,
        comparison.outcome,
        comparison.mismatchCategory,
        comparison.legacyMicros,
        comparison.rustMicros,
        comparison.observedAt,
    )

    private fun record(comparison: HermesShadowComparison) = record(
        comparison.domain,
        comparison.slice,
        comparison.operation,
        comparison.outcome,
        comparison.mismatchCategory,
        comparison.legacyMicros,
        comparison.rustMicros,
        comparison.observedAt,
    )

    private fun record(
        domain: String,
        slice: String,
        operation: String,
        proposedOutcome: String,
        proposedMismatchCategory: String?,
        legacyMicros: Long,
        rustMicros: Long,
        observedAt: Instant,
    ) {
        val (channel, candidate) = activeEvidenceContext() ?: return
        val loadedIdentity = loadedIdentity()
        val loadedIdentityMismatch = loadedIdentity != null && loadedIdentity != AndroidDomainCoreLoadedIdentity(
            candidate.coreVersion,
            candidate.abiVersion,
            candidate.sourceSha256,
        )
        val outcome = if (loadedIdentity == null || loadedIdentityMismatch) "mismatch" else proposedOutcome
        val mismatchCategory = when {
            loadedIdentity == null -> "native_unavailable"
            loadedIdentityMismatch -> "loaded_identity_mismatch"
            proposedMismatchCategory == "native_unavailable" -> "native_error"
            else -> proposedMismatchCategory
        }
        if (!validComparison(domain, slice, operation, outcome, mismatchCategory, loadedIdentity, legacyMicros, rustMicros)) return
        runCatching {
            spool?.append(
                AndroidDomainCoreShadowSampleV3(
                    sampleId = UUID.randomUUID().toString(),
                    domain = domain,
                    slice = slice,
                    channel = channel.wireValue,
                    operation = operation,
                    candidateCommit = candidate.candidateCommit,
                    expectedCoreVersion = candidate.coreVersion,
                    expectedCoreAbiVersion = candidate.abiVersion,
                    expectedCoreSourceSha256 = candidate.sourceSha256,
                    loadedCoreVersion = loadedIdentity?.coreVersion,
                    loadedCoreAbiVersion = loadedIdentity?.abiVersion,
                    loadedCoreSourceSha256 = loadedIdentity?.sourceSha256,
                    observedAt = UTC_MILLIS_FORMATTER.format(observedAt),
                    outcome = outcome,
                    mismatchCategory = mismatchCategory,
                    legacyMicros = legacyMicros,
                    rustMicros = rustMicros,
                ),
            )
            scheduleFlush(UPLOAD_DEBOUNCE_MILLIS)
        }.onFailure { logWarning("Shadow evidence spool append failed", it) }
    }

    private fun scheduleFlush(delayMillis: Long) {
        if (activeEvidenceContext() == null) return
        if (flushJob?.isActive == true) return
        flushJob = BurnBarApplication.applicationScope.launch {
            delay(delayMillis)
            flushJob = null
            flush()
        }
    }

    private suspend fun flush() = flushMutex.withLock {
        val (channel, candidate) = activeEvidenceContext() ?: return@withLock
        val activeSpool = spool ?: return@withLock
        if (FirebaseAuth.getInstance().currentUser == null) return@withLock
        runCatching {
            var sealActive = true
            while (true) {
                val batch = activeSpool.nextBatch(sealActive, channel.wireValue, candidate) ?: break
                sealActive = false
                val result = Firebase.functions("us-central1")
                    .getHttpsCallable("submitDomainCoreShadowSamples")
                    .call(mapOf("samples" to batch.samples))
                    .await()
                val response = result.getData() as? Map<*, *> ?: error("Invalid evidence acknowledgement")
                check(validAcknowledgement(response, batch.samples.size))
                activeSpool.acknowledge(batch)
            }
        }.onFailure {
            logWarning("Shadow evidence upload deferred", it)
            scheduleFlush(RETRY_DELAY_MILLIS)
        }
    }

    private fun activeEvidenceContext(): Pair<DomainCoreEvidenceChannel, AndroidDomainCoreCandidateIdentity>? {
        val channel = installedChannel ?: return null
        val candidate = installedCandidate ?: return null
        val profile = activeSignedProfile() ?: return null
        return (channel to candidate).takeIf {
            profile.evidenceChannel == channel && profile.candidateIdentity == candidate
        }
    }

    private fun activeSignedProfile(): AndroidDomainCoreRuntimeProfile? = DomainCoreBuildProfile.runtimeProfile()?.takeIf {
        it.artifactAuthority == DomainCoreArtifactAuthority.SIGNED &&
            it.evidenceChannel != null &&
            it.candidateIdentity != null
    }

    private fun loadedIdentity(): AndroidDomainCoreLoadedIdentity? {
        loadedIdentityOverride?.let { return it() }
        return runCatching {
            AndroidDomainCoreLoadedIdentity(
                coreVersion = domainCoreVersion(),
                abiVersion = domainCoreAbiVersion().toLong(),
                sourceSha256 = domainCoreSourceFingerprint(),
            )
        }.getOrNull()
    }

    private fun validComparison(
        domain: String,
        slice: String,
        operation: String,
        outcome: String,
        mismatchCategory: String?,
        loadedIdentity: AndroidDomainCoreLoadedIdentity?,
        legacyMicros: Long,
        rustMicros: Long,
    ): Boolean {
        if (allowedOperations[domain]?.get(slice)?.contains(operation) != true) return false
        if (outcome == "match" && (mismatchCategory != null || loadedIdentity == null)) return false
        if (outcome == "mismatch" && mismatchCategory !in mismatchCategories) return false
        if (outcome != "match" && outcome != "mismatch") return false
        if (mismatchCategory == "native_unavailable" && loadedIdentity != null) return false
        if (mismatchCategory != "native_unavailable" && loadedIdentity == null) return false
        return legacyMicros in 0..MAX_LATENCY_MICROS && rustMicros in 0..MAX_LATENCY_MICROS
    }

    internal fun validAcknowledgement(response: Map<*, *>, batchSize: Int): Boolean {
        if (batchSize < 0) return false
        val accepted = response["accepted"].exactCount(batchSize) ?: return false
        val duplicates = response["duplicates"].exactCount(batchSize) ?: return false
        return accepted.toLong() + duplicates.toLong() == batchSize.toLong()
    }

    private fun Any?.exactCount(maximum: Int): Int? {
        val number = this as? Number ?: return null
        val value = when (number) {
            is Byte, is Short, is Int, is Long -> number.toLong()
            is Float -> {
                if (!number.isFinite() || number % 1.0f != 0.0f) return null
                number.toLong()
            }
            is Double -> {
                if (!number.isFinite() || number % 1.0 != 0.0) return null
                number.toLong()
            }
            is BigInteger -> runCatching { number.longValueExact() }.getOrNull() ?: return null
            is BigDecimal -> runCatching { number.longValueExact() }.getOrNull() ?: return null
            else -> return null
        }
        return value.takeIf { it in 0..maximum.toLong() }?.toInt()
    }

    internal fun candidateNamespace(candidate: AndroidDomainCoreCandidateIdentity): String {
        val tuple = listOf(
            candidate.candidateCommit,
            candidate.coreVersion,
            candidate.abiVersion.toString(),
            candidate.sourceSha256,
        ).joinToString("|")
        val digest = MessageDigest.getInstance("SHA-256").digest(tuple.toByteArray())
        return "v3-${digest.joinToString("") { "%02x".format(it) }}"
    }

    internal fun prepareCandidateDirectory(base: File, candidate: AndroidDomainCoreCandidateIdentity): File {
        check(base.mkdirs() || base.isDirectory)
        val namespace = candidateNamespace(candidate)
        cleanupEvidenceRoot(base, namespace)
        return base.resolve(namespace)
    }

    private fun cleanupEvidenceRoot(base: File, preservingNamespace: String?) {
        if (!base.exists()) return
        base.listFiles().orEmpty().forEach { entry ->
            val legacyQueueFile = entry.isFile &&
                (entry.name == "active.jsonl" || (entry.name.startsWith("ready-") && entry.extension == "jsonl"))
            val staleCandidateDirectory = entry.isDirectory &&
                listOf("v1-", "v2-", "v3-").any(entry.name::startsWith) &&
                entry.name != preservingNamespace
            if (legacyQueueFile || staleCandidateDirectory) check(entry.deleteRecursively())
        }
    }

    private fun logWarning(message: String, error: Throwable) {
        runCatching { Log.w("DomainCoreEvidence", message, error) }
    }
}
