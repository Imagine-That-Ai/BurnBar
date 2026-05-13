package com.openburnbar.data.repos

import android.content.Context
import com.openburnbar.data.insights.InsightAnalysisAuditEntry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Append-only audit log for the LLM-backed analysis layer.
 *
 * Sibling to [InsightAuditLogRepository] (which records canvas investigations)
 * — kept separate so the analysis-layer audit can grow its own schema without
 * breaking the investigation audit's wire format.
 *
 * Storage: `context.filesDir/Insights/analysis_audit.jsonl`, one
 * [InsightAnalysisAuditEntry] per line, encoded with kotlinx.serialization.
 *
 * `upsertLatest` is used by the orchestrator to mark a started entry as
 * succeeded/failed without writing a second row.
 */
class InsightAnalysisAuditLogRepository(context: Context) {

    private val logDir = File(context.filesDir, "Insights").apply { mkdirs() }
    private val logFile = File(logDir, "analysis_audit.jsonl")
    private val _entries = MutableStateFlow<List<InsightAnalysisAuditEntry>>(emptyList())
    val entries: Flow<List<InsightAnalysisAuditEntry>> = _entries

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    suspend fun append(entry: InsightAnalysisAuditEntry) = withContext(Dispatchers.IO) {
        val line = json.encodeToString(InsightAnalysisAuditEntry.serializer(), entry) + "\n"
        logFile.appendText(line)
        _entries.value = _entries.value + entry
    }

    /** Replace the latest row for [entry.requestID], or append if none exists. */
    suspend fun upsertLatest(entry: InsightAnalysisAuditEntry) = withContext(Dispatchers.IO) {
        val current = readAllUnsafe().toMutableList()
        val idx = current.indexOfLast { it.requestID == entry.requestID }
        if (idx >= 0) current[idx] = entry else current.add(entry)
        rewriteUnsafe(current)
        _entries.value = current.toList()
    }

    suspend fun readAll(limit: Int = 500): List<InsightAnalysisAuditEntry> = withContext(Dispatchers.IO) {
        readAllUnsafe().asReversed().take(limit)
    }

    suspend fun reload() = withContext(Dispatchers.IO) {
        _entries.value = readAllUnsafe()
    }

    suspend fun clear() = withContext(Dispatchers.IO) {
        if (logFile.exists()) logFile.delete()
        _entries.value = emptyList()
    }

    private fun readAllUnsafe(): List<InsightAnalysisAuditEntry> {
        if (!logFile.exists()) return emptyList()
        return logFile.readLines()
            .filter { it.isNotBlank() }
            .mapNotNull { line ->
                runCatching {
                    json.decodeFromString(InsightAnalysisAuditEntry.serializer(), line)
                }.getOrNull()
            }
    }

    private fun rewriteUnsafe(entries: List<InsightAnalysisAuditEntry>) {
        val text = entries.joinToString(separator = "\n") {
            json.encodeToString(InsightAnalysisAuditEntry.serializer(), it)
        }
        logFile.writeText(if (entries.isEmpty()) "" else text + "\n")
    }
}
