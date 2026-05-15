package com.openburnbar.data.square

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

// MARK: - Hermes Square Feature Flags (Android parity)
//
// Mirrors `HermesSquareFeatureFlags` on iOS / macOS. Each Phase has its
// own flag persisted to a SharedPreferences file keyed by `square.feature.<name>`.

class HermesSquareFeatureFlags private constructor(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // Hermes Square is now the default Assistants surface. Each phase
    // defaults to **true** on a fresh install; existing installs that
    // stored an explicit value are honored verbatim.
    var phaseA: Boolean by mutableStatePref(KEY_PHASE_A, defaultValue = true)
    var phaseB: Boolean by mutableStatePref(KEY_PHASE_B, defaultValue = true)
    var phaseC: Boolean by mutableStatePref(KEY_PHASE_C, defaultValue = true)
    var phaseD: Boolean by mutableStatePref(KEY_PHASE_D, defaultValue = true)

    val anyPhaseEnabled: Boolean get() = phaseA || phaseB || phaseC || phaseD

    fun resetAll() {
        phaseA = true
        phaseB = true
        phaseC = true
        phaseD = true
    }

    private fun mutableStatePref(key: String, defaultValue: Boolean = false) =
        object : kotlin.properties.ReadWriteProperty<Any?, Boolean> {
            private var cached = mutableStateOf(
                if (prefs.contains(key)) prefs.getBoolean(key, defaultValue)
                else defaultValue.also { prefs.edit().putBoolean(key, defaultValue).apply() }
            )
            override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>): Boolean = cached.value
            override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: Boolean) {
                cached.value = value
                prefs.edit().putBoolean(key, value).apply()
            }
        }

    companion object {
        private const val PREFS_NAME = "square_feature_flags"
        const val KEY_PHASE_A = "square.feature.phaseA"
        const val KEY_PHASE_B = "square.feature.phaseB"
        const val KEY_PHASE_C = "square.feature.phaseC"
        const val KEY_PHASE_D = "square.feature.phaseD"

        @Volatile
        private var instance: HermesSquareFeatureFlags? = null

        fun shared(context: Context): HermesSquareFeatureFlags =
            instance ?: synchronized(this) {
                instance ?: HermesSquareFeatureFlags(context.applicationContext).also { instance = it }
            }
    }
}
