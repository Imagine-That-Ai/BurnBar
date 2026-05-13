package com.openburnbar.data.repos

import android.content.Context
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.time.Instant

/**
 * Content-addressed cache for [InsightAnalysisResult].
 *
 * Keyed by (prompt, digestContentHash, modelID, instruction). LRU-evicted at
 * [maxEntries]. Stored as JSON files under
 * `context.filesDir/Insights/analysis_cache/`.
 */
class InsightAnalysisCacheRepository(
    context: Context,
    private val maxEntries: Int = 64,
) {
    @Serializable
    data class CachedResult(
        val key: String,
        val result: InsightAnalysisResult,
        val storedAt: String,
        val estimatedCostSavedUSD: Double = 0.0,
    )

    private val cacheDir = File(context.filesDir, "Insights/analysis_cache").apply { mkdirs() }
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    suspend fun lookup(key: String): CachedResult? = withContext(Dispatchers.IO) {
        val file = File(cacheDir, "$key.json")
        if (!file.exists()) return@withContext null
        runCatching {
            json.decodeFromString(CachedResult.serializer(), file.readText())
        }.getOrNull()
    }

    suspend fun store(cached: CachedResult) = withContext(Dispatchers.IO) {
        if (!cacheDir.exists()) cacheDir.mkdirs()
        val file = File(cacheDir, "${cached.key}.json")
        file.writeText(json.encodeToString(CachedResult.serializer(), cached))
        evictIfNeeded()
    }

    suspend fun clear() = withContext(Dispatchers.IO) {
        cacheDir.listFiles()?.forEach { it.delete() }
    }

    suspend fun entryCount(): Int = withContext(Dispatchers.IO) {
        cacheDir.listFiles()?.size ?: 0
    }

    private fun evictIfNeeded() {
        val files = cacheDir.listFiles()?.toList() ?: return
        if (files.size <= maxEntries) return
        val sorted = files.sortedBy { it.lastModified() }
        val toDrop = sorted.take(sorted.size - maxEntries)
        toDrop.forEach { it.delete() }
    }

    companion object {
        fun key(
            prompt: String,
            digestContentHash: String,
            modelID: String,
            instruction: InsightAnalysisRequest.Instruction,
        ): String {
            val payload = "$prompt$digestContentHash$modelID${instruction.name}"
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(payload.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02x".format(it) }
        }

        fun cachedNow(key: String, result: InsightAnalysisResult, costSaved: Double = 0.0): CachedResult =
            CachedResult(
                key = key,
                result = result,
                storedAt = Instant.now().toString(),
                estimatedCostSavedUSD = costSaved,
            )
    }
}
