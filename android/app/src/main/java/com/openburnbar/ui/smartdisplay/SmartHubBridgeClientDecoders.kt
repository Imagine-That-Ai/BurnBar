
package com.openburnbar.ui.smartdisplay

import com.google.firebase.Timestamp
import java.time.Instant
import kotlin.math.roundToInt

internal data class SmartHubConfig(
    val documentId: String,
    val enabled: Boolean,
    val sourceDeviceName: String?,
    val publishedAtMs: Long,
    val dashboardUrl: String?,
    val refreshUrl: String?,
    val voiceRefreshUrl: String?,
    val pixelClock: PixelClockConfig,
)

internal data class PixelClockConfig(
    val enabled: Boolean,
    val host: String,
    val port: Int,
    val brightness: Int?,
    val updateIntervalSeconds: Int,
    val timeFormat: PixelClockTimeFormat,
    val lastProbeStatus: String,
)

internal fun decodeConfig(documentId: String, data: Map<String, Any?>): SmartHubConfig? {
    val pixelClockData = data["pixelClock"].asStringAnyNullableMap()
    return SmartHubConfig(
        documentId = documentId,
        enabled = data["enabled"] as? Boolean ?: false,
        sourceDeviceName = data["sourceDeviceName"] as? String,
        publishedAtMs = decodePublishedAtMs(data["publishedAt"]),
        dashboardUrl = data["dashboardURL"] as? String,
        refreshUrl = data["refreshURL"] as? String,
        voiceRefreshUrl = data["voiceRefreshURL"] as? String,
        pixelClock = decodePixelClock(pixelClockData),
    )
}

internal fun decodePixelClock(data: Map<String, Any?>?): PixelClockConfig {
    val brightness = (data?.get("brightness") as? Number)?.toInt()
    return PixelClockConfig(
        enabled = data?.get("enabled") as? Boolean ?: false,
        host = data?.get("host") as? String ?: "",
        port = (data?.get("port") as? Number)?.toInt() ?: 80,
        brightness = brightness,
        updateIntervalSeconds = (data?.get("updateIntervalSeconds") as? Number)?.toInt() ?: 60,
        timeFormat =
        when (data?.get("timeFormat") as? String) {
            "24", "24h", "HOUR_24" -> PixelClockTimeFormat.HOUR_24
            else -> PixelClockTimeFormat.HOUR_12
        },
        lastProbeStatus = data?.get("lastProbeStatus") as? String ?: "unknown",
    )
}

internal fun decodePublishedAtMs(value: Any?): Long =
    when (value) {
        is Timestamp -> value.seconds * 1000L + value.nanoseconds / 1_000_000L
        is String -> runCatching { Instant.parse(value).toEpochMilli() }.getOrDefault(0L)
        is Number -> value.toLong()
        else -> 0L
    }

internal fun Any?.asStringAnyNullableMap(): Map<String, Any?>? {
    val raw = this as? Map<*, *> ?: return null
    val typed = LinkedHashMap<String, Any?>(raw.size)
    for ((key, value) in raw) {
        typed[key as? String ?: return null] = value
    }
    return typed
}

internal fun pixelClockPayload(snapshot: SmartHubSnapshot, androidDeviceId: String): Map<String, Any?> {
    val selected = snapshot.discoveredDevices.firstOrNull { it.id == snapshot.pixelClockSelectedDeviceId }
    val configuredHostPort =
        snapshot.pixelClockSelectedDeviceId
            ?.takeIf { ":" in it }
            ?.split(":", limit = 2)
    val host = selected?.host ?: configuredHostPort?.getOrNull(0) ?: "192.168.68.92"
    val port = selected?.port ?: configuredHostPort?.getOrNull(1)?.toIntOrNull() ?: 80
    return mapOf(
        "enabled" to snapshot.pixelClockEnabled,
        "host" to host,
        "port" to port.coerceIn(1, 65_535),
        "layout" to "providerDashboard",
        "palette" to "emberWhimsy",
        "timePeriod" to "rolling5h",
        "workingSpinnerStyle" to "orbit",
        "workingSpinnerPrimaryHex" to "#52D6FF",
        "workingSpinnerSecondaryHex" to "#FFFFFF",
        "completionClockSoundEnabled" to true,
        "completionLocalNotificationsEnabled" to true,
        "pageDurationSeconds" to 7,
        "updateIntervalSeconds" to snapshot.pixelClockRefreshSeconds.coerceIn(5, 600),
        "scrollSpeedPercent" to 100,
        "brightness" to (snapshot.pixelClockBrightness.coerceIn(0f, 1f) * 100f).roundToInt().coerceIn(0, 100),
        "providerIDs" to emptyList<String>(),
        "updatedAt" to smartHubNowIso(),
        "updatedByDeviceId" to "android-$androidDeviceId",
        "lastProbeStatus" to "unknown",
        "timeFormat" to
            when (snapshot.pixelClockTimeFormat) {
                PixelClockTimeFormat.HOUR_12 -> "12"
                PixelClockTimeFormat.HOUR_24 -> "24"
            },
    )
}

internal fun smartHubNowIso(): String = Instant.now().toString()

internal fun formatBridgeRelativeAge(ageMs: Long): String {
    val seconds = (ageMs / 1000L).coerceAtLeast(0)
    return when {
        seconds < 60 -> "${seconds}s"
        seconds < 3_600 -> "${seconds / 60}m"
        seconds < 86_400 -> "${seconds / 3_600}h"
        else -> "${seconds / 86_400}d"
    }
}

internal fun bridgeFreshness(publishedAtMs: Long, sourceDeviceName: String?): Pair<Boolean, String> {
    val bridgeAgeMs = (System.currentTimeMillis() - publishedAtMs).coerceAtLeast(0)
    val isLive = bridgeAgeMs <= SmartHubBridgeClient.LIVE_BRIDGE_MAX_AGE_MS
    val source = sourceDeviceName ?: "your Mac"
    return if (isLive) {
        true to "Mac bridge is live on $source."
    } else {
        false to "Mac bridge is offline. Last heartbeat was ${formatBridgeRelativeAge(bridgeAgeMs)} ago from $source."
    }
}
