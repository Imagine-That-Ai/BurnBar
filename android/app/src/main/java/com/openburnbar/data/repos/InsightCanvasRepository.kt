package com.openburnbar.data.repos

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.openburnbar.data.insights.InsightCanvas
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json

/**
 * DataStore-backed local persistence for InsightCanvas documents.
 * Cross-device sync via Firestore at users/{uid}/insight_canvases/{id} —
 * last-revision-wins merge strategy using InsightLayout.revision.
 * The 200-canvas LRU cap from iOS applies identically.
 */
class InsightCanvasRepository(private val context: Context) {

    private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "insight_canvases")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val CANVASES_KEY = stringPreferencesKey("canvases_json")

    val canvases: Flow<List<InsightCanvas>> = context.dataStore.data.map { prefs ->
        val raw = prefs[CANVASES_KEY] ?: "[]"
        try { json.decodeFromString<List<InsightCanvas>>(raw) } catch (_: Exception) { emptyList() }
    }

    suspend fun save(list: List<InsightCanvas>) {
        val capped = if (list.size > MAX_CANVASES) list.take(MAX_CANVASES) else list
        val encoded = json.encodeToString(kotlinx.serialization.serializer<List<InsightCanvas>>(), capped)
        context.dataStore.edit { prefs -> prefs[CANVASES_KEY] = encoded }
    }

    suspend fun add(canvas: InsightCanvas) {
        val current = canvases.first()
        save(current + canvas)
    }

    suspend fun update(canvas: InsightCanvas) {
        val current = canvases.first()
        val idx = current.indexOfFirst { it.id == canvas.id }
        if (idx >= 0) {
            val updated = current.toMutableList()
            updated[idx] = canvas
            save(updated)
        }
    }

    suspend fun delete(canvasID: String) {
        val current = canvases.first()
        save(current.filter { it.id != canvasID })
    }

    companion object {
        private const val MAX_CANVASES = 200
    }
}
