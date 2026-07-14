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
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import org.json.JSONObject

private const val SHADOW_SCHEMA_VERSION = 2
private const val DEFAULT_MAX_FILE_BYTES = 256 * 1024
private const val DEFAULT_MAX_READY_FILES = 8
private const val DEFAULT_MAX_SAMPLES_PER_FILE = 100
private const val READY_ORDINAL_WIDTH = 19
private const val MAX_LATENCY_MICROS = 600_000_000L
private const val UPLOAD_DEBOUNCE_MILLIS = 5_000L
private const val RETRY_DELAY_MILLIS = 30_000L

internal data class AndroidDomainCoreShadowSampleV2(
    val sampleId: String,
    val domain: String,
    val slice: String,
    val channel: String,
    val operation: String,
    val coreVersion: String,
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
        "coreVersion" to coreVersion,
        "observedAt" to Instant.now().toString(),
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
    fun append(sample: AndroidDomainCoreShadowSampleV2) {
        val line = JSONObject(sample.toMap()).toString() + "\n"
        require(line.toByteArray().size <= maxFileBytes)
        if (active.length() + line.toByteArray().size > maxFileBytes || activeLineCount() >= maxSamplesPerFile) sealActive()
        active.appendText(line)
    }

    @Synchronized
    fun prepareForChannel(expectedChannel: String) {
        require(expectedChannel == "internal" || expectedChannel == "beta")
        sealActive()
        readyFiles().forEach { file ->
            if (readSamples(file)?.all { it["channel"] == expectedChannel } != true) {
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
    fun nextBatch(sealActive: Boolean, expectedChannel: String): Batch? {
        require(expectedChannel == "internal" || expectedChannel == "beta")
        if (sealActive) sealActive()
        while (true) {
            val file = readyFiles().firstOrNull() ?: return null
            val samples = readSamples(file)
            if (samples == null || samples.any { it["channel"] != expectedChannel }) {
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

    private fun readSamples(file: File): List<Map<String, Any?>>? = runCatching {
        file.useLines { lines ->
            lines.filter(String::isNotBlank).map { JSONObject(it).toMap() }.toList()
        }.takeIf { it.isNotEmpty() && it.size <= maxSamplesPerFile }
    }.getOrNull()

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
}

private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        else -> value
    }
}

internal object AndroidDomainCoreShadowEvidence {
    private val allowedCoverage = mapOf(
        "cloudvault" to setOf("foundation", "aes", "recovery", "escrow", "document-rewrap", "search"),
        "hermes" to setOf("aad", "payload-keywrap", "hpke-info", "ratchet"),
    )
    private val coreVersionPattern = Regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
    private val operationPattern = Regex("^[a-z][a-z0-9_.-]{0,63}$")
    private val flushMutex = Mutex()
    private var spool: AndroidDomainCoreShadowSpool? = null
    private var flushJob: Job? = null
    private var installed = false
    private var installedChannel: DomainCoreEvidenceChannel? = null

    fun discardStoredSamples(context: Context) {
        if (DomainCoreBuildProfile.evidenceChannel() != null) return
        AndroidDomainCoreShadowSpool(File(context.filesDir, "domain_core_shadow")).discardAll()
    }

    fun install(context: Context, channel: DomainCoreEvidenceChannel) {
        if (DomainCoreBuildProfile.evidenceChannel() != channel) return
        if (installed) return
        synchronized(this) {
            if (DomainCoreBuildProfile.evidenceChannel() != channel) return
            if (installed) return
            val preparedSpool = AndroidDomainCoreShadowSpool(File(context.filesDir, "domain_core_shadow")).also {
                it.prepareForChannel(channel.wireValue)
            }
            spool = preparedSpool
            installedChannel = channel
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
        comparison.coreVersion,
        comparison.outcome,
        comparison.mismatchCategory,
        comparison.legacyMicros,
        comparison.rustMicros,
    )

    private fun record(comparison: HermesShadowComparison) = record(
        comparison.domain,
        comparison.slice,
        comparison.operation,
        comparison.coreVersion,
        comparison.outcome,
        comparison.mismatchCategory,
        comparison.legacyMicros,
        comparison.rustMicros,
    )

    private fun record(
        domain: String,
        slice: String,
        operation: String,
        coreVersion: String,
        outcome: String,
        mismatchCategory: String?,
        legacyMicros: Long,
        rustMicros: Long,
    ) {
        val channel = activeEvidenceChannel() ?: return
        if (!validComparison(domain, slice, operation, coreVersion, outcome, mismatchCategory, legacyMicros, rustMicros)) return
        runCatching {
            spool?.append(
                AndroidDomainCoreShadowSampleV2(
                    UUID.randomUUID().toString(), domain, slice, channel.wireValue, operation, coreVersion,
                    outcome, mismatchCategory, legacyMicros, rustMicros,
                ),
            )
            scheduleFlush(UPLOAD_DEBOUNCE_MILLIS)
        }.onFailure { Log.w("DomainCoreEvidence", "Shadow evidence spool append failed", it) }
    }

    private fun scheduleFlush(delayMillis: Long) {
        if (activeEvidenceChannel() == null) return
        if (flushJob?.isActive == true) return
        flushJob = BurnBarApplication.applicationScope.launch {
            delay(delayMillis)
            flushJob = null
            flush()
        }
    }

    private suspend fun flush() = flushMutex.withLock {
        val channel = activeEvidenceChannel() ?: return@withLock
        val activeSpool = spool ?: return@withLock
        if (FirebaseAuth.getInstance().currentUser == null) return@withLock
        runCatching {
            var sealActive = true
            while (true) {
                val batch = activeSpool.nextBatch(sealActive, channel.wireValue) ?: break
                sealActive = false
                val result = Firebase.functions("us-central1")
                    .getHttpsCallable("submitDomainCoreShadowSamples")
                    .call(mapOf("samples" to batch.samples))
                    .await()
                val response = result.getData() as? Map<*, *> ?: error("Invalid evidence acknowledgement")
                val accepted = (response["accepted"] as? Number)?.toInt() ?: error("Missing accepted count")
                val duplicates = (response["duplicates"] as? Number)?.toInt() ?: error("Missing duplicate count")
                check(accepted + duplicates == batch.samples.size)
                activeSpool.acknowledge(batch)
            }
        }.onFailure {
            Log.w("DomainCoreEvidence", "Shadow evidence upload deferred", it)
            scheduleFlush(RETRY_DELAY_MILLIS)
        }
    }

    private fun activeEvidenceChannel(): DomainCoreEvidenceChannel? = installedChannel
        ?.takeIf { DomainCoreBuildProfile.evidenceChannel() == it }

    private fun validComparison(
        domain: String,
        slice: String,
        operation: String,
        coreVersion: String,
        outcome: String,
        mismatchCategory: String?,
        legacyMicros: Long,
        rustMicros: Long,
    ): Boolean {
        if (allowedCoverage[domain]?.contains(slice) != true) return false
        if (!operationPattern.matches(operation) || !coreVersionPattern.matches(coreVersion)) return false
        if ((outcome == "match") != (mismatchCategory == null)) return false
        return legacyMicros in 0..MAX_LATENCY_MICROS && rustMicros in 0..MAX_LATENCY_MICROS
    }
}
