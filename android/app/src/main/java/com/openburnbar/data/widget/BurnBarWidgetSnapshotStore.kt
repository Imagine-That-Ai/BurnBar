package com.openburnbar.data.widget

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
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * File-backed atomic persistence for the widget snapshot. Mirrors iOS's App
 * Group container — the main app writes, every Glance widget reads. Exposes
 * a [StateFlow] so any in-process consumer (the sync worker, the menu-bar
 * service) sees updates without polling.
 *
 * Singleton because both the app side and the widget side touch the same
 * file and we don't want write contention.
 */
object BurnBarWidgetSnapshotStore {

    private val _snapshot = MutableStateFlow<BurnBarWidgetSnapshot?>(null)
    val snapshot: StateFlow<BurnBarWidgetSnapshot?> = _snapshot.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    @Volatile private var bound = false

    /** One-time hydration at app start (or first widget bind). Safe to call repeatedly. */
    fun bind(context: Context) {
        if (bound) return
        bound = true
        scope.launch { hydrate(context) }
    }

    /** Synchronously read the persisted snapshot. Used by the Glance worker. */
    suspend fun read(context: Context): BurnBarWidgetSnapshot? = mutex.withLock {
        val cached = _snapshot.value
        if (cached != null) return@withLock cached
        readFromDisk(context)?.also { _snapshot.value = it }
    }

    /** Persist and notify all in-process consumers. */
    fun write(context: Context, snapshot: BurnBarWidgetSnapshot) {
        scope.launch {
            mutex.withLock {
                _snapshot.value = snapshot
                runCatching {
                    File(context.filesDir, BurnBarWidgetSnapshot.FILENAME)
                        .writeText(json.encodeToString(snapshot))
                }
            }
        }
    }

    private suspend fun hydrate(context: Context) {
        mutex.withLock {
            val read = readFromDisk(context)
            if (read != null) _snapshot.value = read
        }
    }

    private fun readFromDisk(context: Context): BurnBarWidgetSnapshot? {
        return runCatching {
            val file = File(context.filesDir, BurnBarWidgetSnapshot.FILENAME)
            if (!file.exists()) return@runCatching null
            val text = file.readText()
            if (text.isBlank()) null else json.decodeFromString<BurnBarWidgetSnapshot>(text)
        }.getOrNull()
    }
}
