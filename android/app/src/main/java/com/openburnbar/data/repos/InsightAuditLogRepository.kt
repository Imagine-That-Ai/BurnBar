package com.openburnbar.data.repos

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Append-only audit log for Insights investigations.
 * Stored as JSONL in context.filesDir/Insights/audit.jsonl.
 * Identical schema to the Swift side.
 */
class InsightAuditLogRepository(private val context: Context) {

    private val logDir = File(context.filesDir, "Insights").apply { mkdirs() }
    private val logFile = File(logDir, "audit.jsonl")
    private val _entries = MutableStateFlow<List<AuditEntry>>(emptyList())

    val entries: Flow<List<AuditEntry>> = _entries

    suspend fun append(entry: AuditEntry) {
        val line = entry.toJsonLine() + "\n"
        with(Dispatchers.IO) { logFile.appendText(line) }
        _entries.value = _entries.value + entry
    }

    suspend fun clear() {
        with(Dispatchers.IO) { if (logFile.exists()) logFile.delete() }
        _entries.value = emptyList()
    }

    suspend fun reload() {
        _entries.value = with(Dispatchers.IO) {
            if (!logFile.exists()) return@with emptyList()
            logFile.readLines().filter { it.isNotBlank() }.mapNotNull { line ->
                try { AuditEntry.fromJsonLine(line) } catch (_: Exception) { null }
            }
        }
    }

    data class AuditEntry(
        val timestamp: String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).format(Date()),
        val modelProvider: String,
        val modelID: String,
        val egressTier: String,
        val promptHash: String,
        val digestHash: String,
        val egressBytes: Int,
        val estimatedCostUSD: Double,
        val status: String,
        val widgetCount: Int = 0,
        val canvasID: String = ""
    ) {
        fun toJsonLine(): String = """{"timestamp":"$timestamp","modelProvider":"$modelProvider","modelID":"$modelID","egressTier":"$egressTier","promptHash":"$promptHash","digestHash":"$digestHash","egressBytes":$egressBytes,"estimatedCostUSD":$estimatedCostUSD,"status":"$status","widgetCount":$widgetCount,"canvasID":"$canvasID"}"""

        companion object {
            fun fromJsonLine(line: String): AuditEntry {
                val map = org.json.JSONObject(line)
                return AuditEntry(
                    timestamp = map.optString("timestamp"),
                    modelProvider = map.optString("modelProvider"),
                    modelID = map.optString("modelID"),
                    egressTier = map.optString("egressTier"),
                    promptHash = map.optString("promptHash"),
                    digestHash = map.optString("digestHash"),
                    egressBytes = map.optInt("egressBytes"),
                    estimatedCostUSD = map.optDouble("estimatedCostUSD"),
                    status = map.optString("status"),
                    widgetCount = map.optInt("widgetCount"),
                    canvasID = map.optString("canvasID")
                )
            }
        }
    }
}
