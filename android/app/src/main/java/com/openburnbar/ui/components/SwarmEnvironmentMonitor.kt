package com.openburnbar.ui.components

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.stateIn

/**
 * Android port of iOS `SwarmEnvironmentMonitor` (shared instance, live
 * sensors). Each sensor is a hot [StateFlow] seeded with a synchronous
 * snapshot read, so the first composition already has real values and later
 * plug/unplug, Wi-Fi, and battery-saver transitions recompose the swarm
 * gate instead of waiting for the next unrelated recomposition.
 *
 * Same singleton shape as `SwarmBackgroundPreferencesStore`: process-wide,
 * eager, and sticky across recompositions. When a sensor cannot register
 * (no connectivity service, registration throws), its flow closes after the
 * initial snapshot and the gate keeps that snapshot — the historical
 * snapshot-per-composition behavior — instead of crashing the backdrop.
 *
 * The enforcement gate ([SwarmBackgroundPowerPolicy.resolve]) is untouched:
 * these sensors only supply its `conditionMet` (via
 * [SwarmEnvironmentConditionEvaluator]) and `isLowPowerModeEnabled` inputs.
 * Scene activity still comes from the composition's lifecycle owner.
 */
class SwarmEnvironmentMonitor private constructor(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val isPowerConnected: StateFlow<Boolean> =
        powerConnectedFlow().stateIn(scope, SharingStarted.Eagerly, readPowerConnected())

    val isWifiConnected: StateFlow<Boolean> =
        wifiConnectedFlow().stateIn(scope, SharingStarted.Eagerly, readWifiConnected())

    val isPowerSaveMode: StateFlow<Boolean> =
        powerSaveModeFlow().stateIn(scope, SharingStarted.Eagerly, readPowerSaveMode())

    fun meetsCondition(condition: SwarmBackgroundCondition): Boolean = SwarmEnvironmentConditionEvaluator.meetsCondition(
        condition = condition,
        isPowerConnected = isPowerConnected.value,
        isWifiConnected = isWifiConnected.value,
    )

    private fun powerConnectedFlow(): Flow<Boolean> = callbackFlow {
        trySend(readPowerConnected())
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
                    trySend(isSwarmPowerConnectedFromPluggedExtra(plugged))
                }
            }
        val registered =
            runCatching {
                ContextCompat.registerReceiver(
                    context,
                    receiver,
                    IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                )
            }.onFailure { error ->
                Log.w(TAG, "Swarm power sensor unavailable; keeping snapshot", error)
            }.isSuccess
        if (!registered) {
            close()
            return@callbackFlow
        }
        awaitClose { runCatching { context.unregisterReceiver(receiver) } }
    }

    private fun wifiConnectedFlow(): Flow<Boolean> = callbackFlow {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        if (connectivity == null) {
            close()
            return@callbackFlow
        }
        trySend(readWifiConnected(connectivity))
        val callback =
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    trySend(readWifiConnected(connectivity))
                }

                override fun onLost(network: Network) {
                    trySend(readWifiConnected(connectivity))
                }

                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    trySend(
                        isSwarmWifiConnectedFromTransports(
                            hasWifiTransport = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                            hasEthernetTransport = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
                        ),
                    )
                }
            }
        val registered =
            runCatching { connectivity.registerDefaultNetworkCallback(callback) }
                .onFailure { error ->
                    Log.w(TAG, "Swarm wifi sensor unavailable; keeping snapshot", error)
                }.isSuccess
        if (!registered) {
            close()
            return@callbackFlow
        }
        awaitClose { runCatching { connectivity.unregisterNetworkCallback(callback) } }
    }

    private fun powerSaveModeFlow(): Flow<Boolean> = callbackFlow {
        trySend(readPowerSaveMode())
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    trySend(readPowerSaveMode())
                }
            }
        val registered =
            runCatching {
                ContextCompat.registerReceiver(
                    context,
                    receiver,
                    IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                )
            }.onFailure { error ->
                Log.w(TAG, "Swarm power-save sensor unavailable; keeping snapshot", error)
            }.isSuccess
        if (!registered) {
            close()
            return@callbackFlow
        }
        awaitClose { runCatching { context.unregisterReceiver(receiver) } }
    }

    private fun readPowerConnected(): Boolean {
        val batteryIntent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val plugged = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        return isSwarmPowerConnectedFromPluggedExtra(plugged)
    }

    private fun readWifiConnected(): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
        return readWifiConnected(connectivity)
    }

    private fun readWifiConnected(connectivity: ConnectivityManager): Boolean {
        val capabilities = connectivity.activeNetwork?.let { connectivity.getNetworkCapabilities(it) }
        return isSwarmWifiConnectedFromTransports(
            hasWifiTransport = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true,
            hasEthernetTransport = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true,
        )
    }

    private fun readPowerSaveMode(): Boolean = context.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true

    companion object {
        private const val TAG = "SwarmEnvironment"

        @Volatile private var instance: SwarmEnvironmentMonitor? = null

        fun get(context: Context): SwarmEnvironmentMonitor = instance ?: synchronized(this) {
            instance ?: SwarmEnvironmentMonitor(context.applicationContext).also { instance = it }
        }
    }
}
