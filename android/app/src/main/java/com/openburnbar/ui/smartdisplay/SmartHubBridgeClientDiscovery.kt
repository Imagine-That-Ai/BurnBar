package com.openburnbar.ui.smartdisplay

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import java.net.InetAddress

private const val DISCOVERY_SERVICE_TYPE = "_http._tcp."

internal object SmartHubBridgeClientDiscovery {
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.DiscoveryListener? = null

    fun start(context: Context) {
        stop()
        val manager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsdManager = manager
        val listener =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String?) = Unit

                override fun onDiscoveryStopped(serviceType: String?) = Unit

                override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit

                override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    val name = serviceInfo.serviceName ?: return
                    if (!name.contains("awtrix", ignoreCase = true) &&
                        !name.contains("ulanzi", ignoreCase = true)
                    ) {
                        return
                    }
                    resolveFoundService(manager, serviceInfo)
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                    val name = serviceInfo?.serviceName ?: return
                    SmartHubBridgeClient.updateState { snapshot ->
                        snapshot.copy(
                            discoveredDevices =
                            snapshot.discoveredDevices.filterNot {
                                it.name == name || it.id == name
                            },
                        )
                    }
                }
            }
        nsdListener = listener
        try {
            manager.discoverServices(DISCOVERY_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Throwable) {
            SmartHubBridgeClient.updateState {
                it.copy(actionError = "Local Pixel Clock discovery could not start.")
            }
        }
    }

    fun stop() {
        val listener = nsdListener ?: return
        try {
            nsdManager?.stopServiceDiscovery(listener)
        } catch (_: Throwable) {
            // mDNS discovery is best-effort and can already be stopped by the platform.
        }
        nsdListener = null
    }

    private fun resolveFoundService(manager: NsdManager, serviceInfo: NsdServiceInfo) {
        val listener =
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) = Unit

                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    addResolvedService(resolved)
                }
            }
        try {
            val method =
                NsdManager::class.java.getMethod(
                    "resolveService",
                    NsdServiceInfo::class.java,
                    NsdManager.ResolveListener::class.java,
                )
            method.invoke(manager, serviceInfo, listener)
        } catch (_: Throwable) {
            // Older-device mDNS discovery is best-effort.
        }
    }

    private fun addResolvedService(resolved: NsdServiceInfo) {
        val host = hostAddress(resolved)
        val id = if (host.isBlank()) resolved.serviceName else "$host:${resolved.port}"
        addOrUpdateDevice(
            PixelClockDevice(
                id = id,
                name = resolved.serviceName,
                host = host,
                port = resolved.port,
                reachable = true,
            ),
        )
    }

    private fun hostAddress(serviceInfo: NsdServiceInfo): String {
        return runCatching {
            NsdServiceInfo::class.java.getMethod("getHost").invoke(serviceInfo) as? InetAddress
        }.getOrNull()?.hostAddress.orEmpty()
    }

    private fun addOrUpdateDevice(device: PixelClockDevice) {
        SmartHubBridgeClient.updateState { snapshot ->
            val without = snapshot.discoveredDevices.filterNot { it.id == device.id }
            snapshot.copy(discoveredDevices = (without + device).sortedBy { it.name.lowercase() })
        }
    }
}
