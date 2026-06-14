
package com.openburnbar.ui.smartdisplay

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentReference
import kotlinx.coroutines.tasks.await

internal object SmartHubBridgeClientConfigSupport {
    suspend fun targetConfigReference(configDocumentId: String?, androidDeviceId: String): Result<DocumentReference> = runCatching {
        val uid =
            FirebaseAuth.getInstance().currentUser?.uid
                ?: error("Sign in to manage Pixel Clock.")
        val collection = SmartHubBridgeClient.firestore.collection("users").document(uid).collection("smart_hub_config")
        if (!configDocumentId.isNullOrBlank()) {
            return@runCatching collection.document(configDocumentId)
        }
        val snapshot = collection.get().await()
        snapshot.documents.maxByOrNull {
            decodePublishedAtMs(it.data?.get("publishedAt"))
        }?.reference ?: collection.document("android-$androidDeviceId")
    }

    fun applyConfig(config: SmartHubConfig?, email: String?) {
        SmartHubBridgeClient.updateState { current ->
            if (config == null) {
                current.copy(
                    isLoading = false,
                    bridgeEnabled = false,
                    bridgeSourceDeviceName = null,
                    bridgePublishedAtMs = null,
                    bridgeIsLive = false,
                    bridgeFreshnessMessage = "Open BurnBar on your Mac to connect smart displays.",
                    dashboardUrl = null,
                    refreshUrl = null,
                    voiceRefreshUrl = null,
                    configDocumentId = null,
                    signedInEmail = email,
                )
            } else {
                val matchedDevice =
                    current.discoveredDevices.firstOrNull {
                        it.host == config.pixelClock.host && it.port == config.pixelClock.port
                    }
                val freshness = bridgeFreshness(config.publishedAtMs, config.sourceDeviceName)
                current.copy(
                    isLoading = false,
                    bridgeEnabled = config.enabled,
                    bridgeSourceDeviceName = config.sourceDeviceName,
                    bridgePublishedAtMs = config.publishedAtMs,
                    bridgeIsLive = freshness.first,
                    bridgeFreshnessMessage = freshness.second,
                    dashboardUrl = config.dashboardUrl,
                    refreshUrl = config.refreshUrl,
                    voiceRefreshUrl = config.voiceRefreshUrl,
                    configDocumentId = config.documentId,
                    signedInEmail = email,
                    pixelClockEnabled = config.pixelClock.enabled,
                    pixelClockSelectedDeviceId =
                    matchedDevice?.id
                        ?: "${config.pixelClock.host}:${config.pixelClock.port}".takeIf { config.pixelClock.host.isNotBlank() },
                    pixelClockBrightness = (config.pixelClock.brightness ?: 60).coerceIn(0, 100) / 100f,
                    pixelClockRefreshSeconds = config.pixelClock.updateIntervalSeconds.coerceIn(5, 600),
                    pixelClockTimeFormat = config.pixelClock.timeFormat,
                )
            }
        }
    }
}
