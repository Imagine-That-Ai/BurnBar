package com.openburnbar.ui.smartdisplay

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import androidx.annotation.RequiresApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * Lightweight Android counterpart to the iOS `SmartHubBridgeController`. Owns
 * device discovery via mDNS and the in-memory state of any connected Pixel
 * Clock / HomeAssistant integration. AWTRIX HTTP traffic is not wired here yet;
 * the surface is designed so the data layer can plug in without UI changes.
 */
data class PixelClockDevice(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val reachable: Boolean
)

data class SmartHubSnapshot(
    val pixelClockEnabled: Boolean = false,
    val pixelClockSelectedDeviceId: String? = null,
    val pixelClockBrightness: Float = 0.6f,
    val pixelClockTimeFormat: PixelClockTimeFormat = PixelClockTimeFormat.HOUR_12,
    val pixelClockRefreshSeconds: Int = 30,
    val discoveredDevices: List<PixelClockDevice> = emptyList(),
    val homeAssistantConnected: Boolean = false,
    val homeAssistantLastSyncMs: Long? = null
)

enum class PixelClockTimeFormat { HOUR_12, HOUR_24 }

object SmartHubBridgeClient {
    private const val SERVICE_TYPE = "_http._tcp."

    private val _state = MutableStateFlow(SmartHubSnapshot())
    val state: StateFlow<SmartHubSnapshot> = _state

    private var nsdManager: NsdManager? = null
    private var listener: NsdManager.DiscoveryListener? = null

    fun startDiscovery(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.JELLY_BEAN) return
        stopDiscovery()
        val manager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
            ?: return
        nsdManager = manager
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) {}
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName ?: return
                if (!name.contains("awtrix", ignoreCase = true) &&
                    !name.contains("ulanzi", ignoreCase = true)
                ) return
                manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        addOrUpdateDevice(
                            PixelClockDevice(
                                id = resolved.serviceName,
                                name = resolved.serviceName,
                                host = resolved.host?.hostAddress ?: "",
                                port = resolved.port,
                                reachable = true
                            )
                        )
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                val name = serviceInfo?.serviceName ?: return
                _state.update { s ->
                    s.copy(discoveredDevices = s.discoveredDevices.filterNot { it.id == name })
                }
            }
        }
        listener = l
        try { manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
        catch (_: Throwable) { /* discovery is best-effort */ }
    }

    fun stopDiscovery() {
        val l = listener ?: return
        try { nsdManager?.stopServiceDiscovery(l) } catch (_: Throwable) {}
        listener = null
    }

    // ── State mutation helpers (UI callbacks) ──
    fun setPixelClockEnabled(enabled: Boolean) =
        _state.update { it.copy(pixelClockEnabled = enabled) }

    fun selectDevice(deviceId: String?) =
        _state.update { it.copy(pixelClockSelectedDeviceId = deviceId) }

    fun setBrightness(value: Float) =
        _state.update { it.copy(pixelClockBrightness = value.coerceIn(0f, 1f)) }

    fun setTimeFormat(format: PixelClockTimeFormat) =
        _state.update { it.copy(pixelClockTimeFormat = format) }

    fun setRefreshSeconds(seconds: Int) =
        _state.update { it.copy(pixelClockRefreshSeconds = seconds.coerceIn(5, 600)) }

    fun setHomeAssistantConnected(connected: Boolean) =
        _state.update {
            it.copy(
                homeAssistantConnected = connected,
                homeAssistantLastSyncMs = if (connected) System.currentTimeMillis() else it.homeAssistantLastSyncMs
            )
        }

    private fun addOrUpdateDevice(device: PixelClockDevice) {
        _state.update { snap ->
            val without = snap.discoveredDevices.filterNot { it.id == device.id }
            snap.copy(discoveredDevices = without + device)
        }
    }
}
