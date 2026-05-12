package com.openburnbar.ui.chartstudio

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.openburnbar.data.derived.TrendDataDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Process-wide presenter for Chart Studio. Mirrors the iOS
 * `ChartStudioPresenter` semantically — three modes (Hidden, Fullscreen,
 * Minimized), a captured digest snapshot so the surface keeps working if the
 * underlying flows churn while open, and a persisted FAB offset so a user's
 * minimized-button position survives across launches.
 *
 * Idiomatic Kotlin: a `object` singleton exposing `StateFlow`s, fed through
 * a Compose `collectAsState` helper.
 */
object ChartStudioPresenter {

    enum class Mode { Hidden, Fullscreen, Minimized }

    /** Snapshot captured at present-time so the surface stays consistent. */
    data class Snapshot(
        val digest: TrendDataDigest,
        val openedAtMs: Long = System.currentTimeMillis()
    )

    private val _mode = MutableStateFlow(Mode.Hidden)
    val mode: StateFlow<Mode> = _mode.asStateFlow()

    private val _snapshot = MutableStateFlow<Snapshot?>(null)
    val snapshot: StateFlow<Snapshot?> = _snapshot.asStateFlow()

    private val _fabOffset = MutableStateFlow(Offset.Zero)
    val fabOffset: StateFlow<Offset> = _fabOffset.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var prefsBound = false

    /** Open Chart Studio in fullscreen with the supplied digest. */
    fun present(digest: TrendDataDigest) {
        _snapshot.value = Snapshot(digest)
        _mode.value = Mode.Fullscreen
    }

    /** Collapse to the floating action button — keeps `snapshot` alive. */
    fun minimize() {
        if (_mode.value == Mode.Fullscreen) _mode.value = Mode.Minimized
    }

    /** Restore from minimized → fullscreen. No-op if no snapshot. */
    fun restore() {
        if (_snapshot.value != null) _mode.value = Mode.Fullscreen
    }

    /** Fully dismiss the surface and drop the snapshot. */
    fun dismiss() {
        _mode.value = Mode.Hidden
        _snapshot.value = null
    }

    /** Update the FAB offset (drag delta) and persist asynchronously. */
    fun setFabOffset(offset: Offset, context: Context) {
        _fabOffset.value = offset
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[FAB_X] = offset.x
                prefs[FAB_Y] = offset.y
            }
        }
    }

    /** Hydrate the FAB offset from DataStore on first composition. */
    fun bindToPrefs(context: Context) {
        if (prefsBound) return
        prefsBound = true
        scope.launch {
            val saved = context.dataStore.data
                .map { Offset(it[FAB_X] ?: 0f, it[FAB_Y] ?: 0f) }
                .first()
            _fabOffset.value = saved
        }
    }

    // ── Persistence keys ──
    private val Context.dataStore by preferencesDataStore("burnbar.chartstudio.prefs")
    private val FAB_X = floatPreferencesKey("fab_x")
    private val FAB_Y = floatPreferencesKey("fab_y")
}

/** Compose helper — collects presenter mode as `State<Mode>`. */
@Composable
fun rememberChartStudioMode(): State<ChartStudioPresenter.Mode> =
    ChartStudioPresenter.mode.collectAsState()

/** Compose helper — collects the captured snapshot. */
@Composable
fun rememberChartStudioSnapshot(): State<ChartStudioPresenter.Snapshot?> =
    ChartStudioPresenter.snapshot.collectAsState()

/** Hydrate the FAB offset once per process. Call this once near the root. */
@Composable
fun rememberChartStudioFabBinding() {
    val context = LocalContext.current
    androidx.compose.runtime.LaunchedEffect(context) {
        ChartStudioPresenter.bindToPrefs(context)
    }
}
