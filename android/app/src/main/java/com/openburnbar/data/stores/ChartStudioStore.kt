package com.openburnbar.data.stores

import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Date

@Serializable
data class ChartStudioCanvas(
    val id: String = java.util.UUID.randomUUID().toString(),
    val prompt: String = "",
    val title: String = "",
    val summary: String = "",
    val createdAt: Long = Date().time,
    val renderingJSON: String = "{}"
)

class ChartStudioStore(context: Context) : ViewModel() {
    companion object {
        private const val FILENAME = "chart-studio-canvases.json"
        private const val MAX_CANVASES = 20
    }

    private val storageFile = File(context.applicationContext.filesDir, FILENAME)
    private val json = Json { ignoreUnknownKeys = true }

    private val _canvases = MutableStateFlow<List<ChartStudioCanvas>>(emptyList())
    val canvases: StateFlow<List<ChartStudioCanvas>> = _canvases.asStateFlow()

    init {
        load()
    }

    fun add(canvas: ChartStudioCanvas) {
        val updated = listOf(canvas) + _canvases.value
        _canvases.value = updated.take(MAX_CANVASES)
        save()
    }

    fun remove(id: String) {
        _canvases.value = _canvases.value.filter { it.id != id }
        save()
    }

    fun clear() {
        _canvases.value = emptyList()
        save()
    }

    private fun load() {
        try {
            if (storageFile.exists()) {
                val text = storageFile.readText()
                val decoded = json.decodeFromString<List<ChartStudioCanvas>>(text)
                _canvases.value = decoded
            }
        } catch (e: Exception) {
            Log.e("BurnBar", "ChartStudioStore load failed", e)
        }
    }

    private fun save() {
        try {
            val text = json.encodeToString(_canvases.value)
            storageFile.writeText(text)
        } catch (e: Exception) {
            Log.e("BurnBar", "ChartStudioStore save failed", e)
        }
    }
}
