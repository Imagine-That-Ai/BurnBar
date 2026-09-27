package com.openburnbar.ui.components

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * Persists the swarm Where/When pickers (location + condition) in DataStore
 * so the choice survives across launches. Shape mirrors `QuotaPreferences`
 * (data.stores): a process-wide singleton (reads/writes stay sticky across
 * recompositions),
 * eager [StateFlow]s, and fire-and-forget setters on a supervisor scope.
 *
 * Values are stored as the cross-platform wire strings
 * ([SwarmBackgroundLocation.wireValue] / [SwarmBackgroundCondition.wireValue])
 * so they stay byte-compatible with the iOS `Codable` forms. Decoding goes
 * through [swarmLocationFromStoredValue] / [swarmConditionFromStoredValue]:
 * the store default is everywhere/always (Android's historical always-on
 * look), while the JSON codec default stays disabled (the iOS contract).
 *
 * The enforcement gate ([SwarmBackgroundPowerPolicy.resolve]) is untouched:
 * these prefs only select its `location` / `condition` inputs, via
 * [SwarmEnvironmentConditionEvaluator] for the condition bit.
 */
class SwarmBackgroundPreferencesStore private constructor(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val location: StateFlow<SwarmBackgroundLocation> =
        context.dataStore.data
            .map { prefs -> swarmLocationFromStoredValue(prefs[KEY_LOCATION]) }
            .stateIn(scope, SharingStarted.Eagerly, SwarmBackgroundLocation.EVERYWHERE)

    val condition: StateFlow<SwarmBackgroundCondition> =
        context.dataStore.data
            .map { prefs -> swarmConditionFromStoredValue(prefs[KEY_CONDITION]) }
            .stateIn(scope, SharingStarted.Eagerly, SwarmBackgroundCondition.ALWAYS)

    /**
     * Gate-ready prefs: the persisted location + condition with every other
     * field at its codec default. [SwarmBackground] reads only the gate
     * inputs from this; glyph/avatar/brand rendering still comes from its
     * explicit params and the `GlobalVisualSettings` toggles.
     */
    val preferences: StateFlow<SwarmBackgroundPreferences> =
        combine(location, condition) { storedLocation, storedCondition ->
            SwarmBackgroundPreferences(location = storedLocation, condition = storedCondition)
        }.stateIn(
            scope,
            SharingStarted.Eagerly,
            SwarmBackgroundPreferences(location = SwarmBackgroundLocation.EVERYWHERE),
        )

    fun setLocation(value: SwarmBackgroundLocation) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_LOCATION] = value.wireValue
            }
        }
    }

    fun setCondition(value: SwarmBackgroundCondition) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_CONDITION] = value.wireValue
            }
        }
    }

    companion object {
        private val Context.dataStore by preferencesDataStore("burnbar.swarm.prefs")
        private val KEY_LOCATION = stringPreferencesKey("swarm.location")
        private val KEY_CONDITION = stringPreferencesKey("swarm.condition")

        @Volatile private var instance: SwarmBackgroundPreferencesStore? = null

        fun get(context: Context): SwarmBackgroundPreferencesStore = instance ?: synchronized(this) {
            instance ?: SwarmBackgroundPreferencesStore(context.applicationContext).also { instance = it }
        }
    }
}

/**
 * Composable shorthand helper to observe the persisted swarm prefs (Where +
 * When). Mirrors `rememberQuotaDefaultWindow`: the store is process-wide, so
 * the value stays sticky if the settings screen is rebuilt.
 */
@Composable
fun rememberSwarmBackgroundPreferences(): State<SwarmBackgroundPreferences> {
    val context = LocalContext.current
    val store = remember(context) { SwarmBackgroundPreferencesStore.get(context) }
    return store.preferences.collectAsState()
}
