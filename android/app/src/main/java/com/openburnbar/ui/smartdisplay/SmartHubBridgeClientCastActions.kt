package com.openburnbar.ui.smartdisplay

import kotlinx.coroutines.launch

/** Google Cast / Nest Hub smart-display actions. */
object SmartHubBridgeClientCastActions {
    fun refresh() {
        SmartHubBridgeClient.attachConfigListener(force = true)
        runCastDiscovery()
    }

    fun refreshNestHub() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "nest_hub_refresh",
        progress = "Refreshing Google smart display...",
        success = "Refresh sent to the Mac bridge.",
    )

    fun repairNestHub() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "nest_hub_repair",
        progress = "Repairing Google smart display...",
        success = "Google smart display repair completed.",
        timeoutMs = 180_000,
    )

    fun repairAllSmartDisplays() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "smart_display_repair",
        progress = "Repairing smart displays...",
        success = "Smart display repair completed.",
        timeoutMs = 300_000,
    )

    fun identifyNestHub() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "nest_hub_identify",
        progress = "Identifying Google smart display...",
        success = "Identify command sent.",
    )

    fun stopNestHub() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "nest_hub_stop",
        progress = "Stopping Google smart display...",
        success = "Google smart display stopped.",
    )

    fun runCastDiscovery() {
        SmartHubBridgeClient.bridgeScope.launch {
            SmartHubBridgeClient.updateState {
                it.copy(
                    isDiscoveringCastDevices = true,
                    actionInFlight = true,
                    actionMessage = "Searching for Google smart displays...",
                    actionError = null,
                )
            }
            val result =
                SmartHubBridgeClientPublish.publish(
                    collection = SmartHubBridgeClient.CAST_ACTIONS_COLLECTION,
                    payload = mapOf("type" to "test"),
                    timeoutMs = 30_000,
                )
            val devices =
                if (result.error == null) {
                    readCastDiscoveryResults(result.actionId).getOrDefault(emptyList())
                } else {
                    emptyList()
                }
            SmartHubBridgeClient.updateState {
                it.copy(
                    castDevices = devices,
                    isDiscoveringCastDevices = false,
                    actionInFlight = false,
                    actionMessage =
                    if (devices.isEmpty()) {
                        result.message ?: "No Google smart displays were returned by the Mac scan."
                    } else {
                        "Found ${devices.size} Google smart display${if (devices.size == 1) "" else "s"}."
                    },
                    actionError = result.error,
                )
            }
        }
    }

    fun saveCastSelection(device: CastDisplayDevice) {
        SmartHubBridgeClient.bridgeScope.launch {
            SmartHubBridgeClient.updateState {
                it.copy(
                    selectedCastDeviceId = device.serviceName,
                    actionInFlight = true,
                    actionMessage = "Saving ${device.friendlyName}...",
                    actionError = null,
                )
            }
            val result =
                SmartHubBridgeClientPublish.publish(
                    collection = SmartHubBridgeClient.CAST_ACTIONS_COLLECTION,
                    payload =
                    mapOf(
                        "type" to "save_selection",
                        "deviceId" to device.serviceName,
                        "friendlyName" to device.friendlyName,
                        "model" to device.model,
                        "host" to device.host,
                        "port" to device.port,
                        "identifier" to device.identifier,
                        "supportsDisplay" to device.supportsDisplay,
                    ),
                    timeoutMs = 45_000,
                )
            SmartHubBridgeClient.updateState {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: "${device.friendlyName} saved.",
                    actionError = result.error,
                    selectedCastDeviceId = if (result.error == null) device.serviceName else it.selectedCastDeviceId,
                )
            }
        }
    }

    fun testCast(device: CastDisplayDevice) {
        SmartHubBridgeClient.bridgeScope.launch {
            SmartHubBridgeClient.updateState {
                it.copy(
                    selectedCastDeviceId = device.serviceName,
                    actionInFlight = true,
                    actionMessage = "Casting to ${device.friendlyName}...",
                    actionError = null,
                )
            }
            val result =
                SmartHubBridgeClientPublish.publish(
                    collection = SmartHubBridgeClient.CAST_ACTIONS_COLLECTION,
                    payload =
                    mapOf(
                        "type" to "cast",
                        "deviceId" to device.serviceName,
                    ),
                    timeoutMs = 90_000,
                )
            SmartHubBridgeClient.updateState {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: "Cast command completed.",
                    actionError = result.error,
                )
            }
        }
    }

    @Deprecated("Home Assistant is no longer represented by a fake Android-only toggle.")
    fun setHomeAssistantConnected(connected: Boolean) {
        SmartHubBridgeClient.updateState {
            it.copy(
                homeAssistantConnected = connected,
                homeAssistantLastSyncMs = if (connected) System.currentTimeMillis() else it.homeAssistantLastSyncMs,
            )
        }
    }
}
