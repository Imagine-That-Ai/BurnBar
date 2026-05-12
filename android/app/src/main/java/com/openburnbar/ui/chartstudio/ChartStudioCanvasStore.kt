package com.openburnbar.ui.chartstudio

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/**
 * Persistent ring buffer of recently rendered Chart Studio canvases. The user
 * can tap a thumbnail in the "recent" strip to replay the rendering without
 * re-querying Hermes — same idea as iOS `ChartStudioStore`.
 *
 * Stores the raw decoded JSON spec (compact form) so the renderer can re-run
 * its decoder; we avoid leaking any view state into the persisted blob.
 */
object ChartStudioCanvasStore {

    private const val MAX_CANVASES = 20
    private const val FILENAME = "chart-studio-canvases.json"

    @Serializable
    data class Canvas(
        val id: String,
        val title: String,            // user-visible label — first prompt line
        val prompt: String,            // the natural-language prompt that produced this
        val rawJson: String,           // the decoded JSON spec (raw, prose stripped)
        val createdAtMs: Long
    )

    @Serializable
    private data class Persisted(val canvases: List<Canvas>)

    private val _canvases = MutableStateFlow<List<Canvas>>(emptyList())
    val canvases: StateFlow<List<Canvas>> = _canvases.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private var bound = false

    fun bind(context: Context) {
        if (bound) return
        bound = true
        scope.launch {
            mutex.withLock {
                val file = File(context.filesDir, FILENAME)
                if (file.exists()) {
                    runCatching {
                        val text = file.readText()
                        if (text.isNotBlank()) {
                            _canvases.value = json.decodeFromString<Persisted>(text).canvases
                        }
                    }
                }
            }
        }
    }

    fun add(context: Context, prompt: String, rawJson: String) {
        val canvas = Canvas(
            id = UUID.randomUUID().toString(),
            title = prompt.lineSequence().first().trim().take(60),
            prompt = prompt,
            rawJson = rawJson,
            createdAtMs = System.currentTimeMillis()
        )
        scope.launch {
            mutex.withLock {
                val updated = (listOf(canvas) + _canvases.value)
                    .distinctBy { it.id }
                    .take(MAX_CANVASES)
                _canvases.value = updated
                save(context, updated)
            }
        }
    }

    fun clear(context: Context) {
        scope.launch {
            mutex.withLock {
                _canvases.value = emptyList()
                save(context, emptyList())
            }
        }
    }

    private fun save(context: Context, list: List<Canvas>) {
        runCatching {
            File(context.filesDir, FILENAME)
                .writeText(json.encodeToString(Persisted(list)))
        }
    }
}
