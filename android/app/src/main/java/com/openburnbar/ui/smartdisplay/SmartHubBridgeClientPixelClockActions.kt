
package com.openburnbar.ui.smartdisplay

/** Pixel Clock smart-display actions. */
object SmartHubBridgeClientPixelClockActions {
    fun setPixelClockEnabled(enabled: Boolean) {
        SmartHubBridgeClient.updateState { it.copy(pixelClockEnabled = enabled, actionError = null) }
        SmartHubBridgeClient.persistPixelClockConfig()
    }

    fun selectDevice(deviceId: String?) {
        SmartHubBridgeClient.updateState { current ->
            val device = current.discoveredDevices.firstOrNull { it.id == deviceId }
            current.copy(
                pixelClockSelectedDeviceId = deviceId,
                pixelClockEnabled = deviceId != null || current.pixelClockEnabled,
                actionError = null,
            ).let {
                if (device == null) it else it.copy(pixelClockRefreshSeconds = current.pixelClockRefreshSeconds)
            }
        }
        SmartHubBridgeClient.persistPixelClockConfig()
    }

    fun setBrightness(value: Float) {
        smartHubPreviewPixelClockBrightness(value)
        SmartHubBridgeClient.persistPixelClockConfig()
    }

    fun setTimeFormat(format: PixelClockTimeFormat) {
        SmartHubBridgeClient.updateState { it.copy(pixelClockTimeFormat = format, actionError = null) }
        SmartHubBridgeClient.persistPixelClockConfig()
    }

    fun setRefreshSeconds(seconds: Int) {
        smartHubPreviewPixelClockRefreshSeconds(seconds)
        SmartHubBridgeClient.persistPixelClockConfig()
    }

    fun commitPixelClockConfig() {
        SmartHubBridgeClient.persistPixelClockConfig()
    }

    fun repairPixelClock() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "pixel_clock_repair",
        progress = "Making Pixel Clock work...",
        success = "Pixel Clock repair completed.",
        timeoutMs = 180_000,
        includePixelClock = true,
    )

    fun pushPixelClockNow() = SmartHubBridgeClient.runSmartDisplayAction(
        type = "pixel_clock_push",
        progress = "Pushing Pixel Clock...",
        success = "Pixel Clock push completed.",
        timeoutMs = 90_000,
        includePixelClock = true,
    )
}

internal fun smartHubPreviewPixelClockBrightness(value: Float) {
    SmartHubBridgeClient.updateState { it.copy(pixelClockBrightness = value.coerceIn(0f, 1f), actionError = null) }
}

internal fun smartHubPreviewPixelClockRefreshSeconds(seconds: Int) {
    SmartHubBridgeClient.updateState {
        it.copy(pixelClockRefreshSeconds = seconds.coerceIn(5, 600), actionError = null)
    }
}
