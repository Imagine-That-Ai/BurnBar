// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.smartdisplay

import android.content.Context
import android.provider.Settings
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

data class PixelClockDevice(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val reachable: Boolean,
)

data class CastDisplayDevice(
    val serviceName: String,
    val friendlyName: String,
    val model: String,
    val host: String,
    val port: Int,
    val identifier: String,
    val iconKind: String,
    val supportsDisplay: Boolean,
) {
    val id: String get() = serviceName
}

data class SmartHubSnapshot(
    val pixelClockEnabled: Boolean = false,
    val pixelClockSelectedDeviceId: String? = null,
    val pixelClockBrightness: Float = 0.6f,
    val pixelClockTimeFormat: PixelClockTimeFormat = PixelClockTimeFormat.HOUR_12,
    val pixelClockRefreshSeconds: Int = 60,
    val discoveredDevices: List<PixelClockDevice> = emptyList(),
    val bridgeEnabled: Boolean = false,
    val bridgeSourceDeviceName: String? = null,
    val bridgePublishedAtMs: Long? = null,
    val bridgeIsLive: Boolean = false,
    val bridgeFreshnessMessage: String = "Open BurnBar on your Mac to connect smart displays.",
    val dashboardUrl: String? = null,
    val refreshUrl: String? = null,
    val voiceRefreshUrl: String? = null,
    val castDevices: List<CastDisplayDevice> = emptyList(),
    val selectedCastDeviceId: String? = null,
    val isLoading: Boolean = false,
    val isDiscoveringCastDevices: Boolean = false,
    val actionInFlight: Boolean = false,
    val actionMessage: String? = null,
    val actionError: String? = null,
    val configDocumentId: String? = null,
    val signedInEmail: String? = null,
    val homeAssistantConnected: Boolean = false,
    val homeAssistantLastSyncMs: Long? = null,
)

enum class PixelClockTimeFormat { HOUR_12, HOUR_24 }

object SmartHubBridgeClient {
    private const val ACTIONS_COLLECTION = "smart_display_actions"
    private const val CAST_ACTIONS_COLLECTION = "cast_actions"
    internal const val LIVE_BRIDGE_MAX_AGE_MS = 60_000L

    private val _state = MutableStateFlow(SmartHubSnapshot())
    val state: StateFlow<SmartHubSnapshot> = _state

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    internal val firestore get() = Firebase.firestore
    internal val bridgeScope get() = scope
    internal const val castActionsCollection = CAST_ACTIONS_COLLECTION

    private var configListener: ListenerRegistration? = null
    private var listenedUid: String? = null
    private var androidDeviceId: String = "android"
    private var freshnessJob: Job? = null

    fun start(context: Context) {
        val appContext = context.applicationContext
        androidDeviceId =
            Settings.Secure.getString(
                appContext.contentResolver,
                Settings.Secure.ANDROID_ID,
            ) ?: "android"
        startFreshnessTimer()
        SmartHubBridgeClientDiscovery.start(appContext)
        attachConfigListener()
    }

    fun stop() {
        SmartHubBridgeClientDiscovery.stop()
        configListener?.remove()
        configListener = null
        listenedUid = null
        freshnessJob?.cancel()
        freshnessJob = null
    }

    internal fun updateState(block: (SmartHubSnapshot) -> SmartHubSnapshot) {
        _state.update(block)
    }

    internal fun currentSnapshot(): SmartHubSnapshot = _state.value

    internal fun attachConfigListener(force: Boolean = false) {
        val user = FirebaseAuth.getInstance().currentUser
        val uid = user?.uid
        if (uid == null) {
            configListener?.remove()
            configListener = null
            listenedUid = null
            _state.update {
                it.copy(
                    isLoading = false,
                    signedInEmail = null,
                    actionError = "Sign in to manage smart displays.",
                )
            }
            return
        }
        if (!force && listenedUid == uid && configListener != null) {
            _state.update { it.copy(signedInEmail = user.email) }
            return
        }
        configListener?.remove()
        listenedUid = uid
        _state.update { it.copy(isLoading = true, signedInEmail = user.email, actionError = null) }
        configListener =
            firestore.collection("users").document(uid)
                .collection("smart_hub_config")
                .addSnapshotListener { snapshot, error ->
                    if (error != null) {
                        _state.update {
                            it.copy(isLoading = false, actionError = error.localizedMessage)
                        }
                        return@addSnapshotListener
                    }
                    val config =
                        snapshot?.documents
                            ?.mapNotNull { decodeConfig(it.id, it.data.orEmpty()) }
                            ?.maxByOrNull { it.publishedAtMs }
                    SmartHubBridgeClientConfigSupport.applyConfig(config, user.email)
                }
    }

    internal fun persistPixelClockConfig() {
        scope.launch {
            val uid =
                FirebaseAuth.getInstance().currentUser?.uid ?: run {
                    _state.update { it.copy(actionError = "Sign in to manage Pixel Clock.") }
                    return@launch
                }
            val target =
                SmartHubBridgeClientConfigSupport.targetConfigReference(_state.value.configDocumentId, androidDeviceId).getOrElse {
                    _state.update { current -> current.copy(actionError = it.localizedMessage) }
                    return@launch
                }
            val payload = pixelClockPayload(_state.value, androidDeviceId)
            _state.update { it.copy(actionInFlight = true, actionMessage = "Saving Pixel Clock...", actionError = null) }
            val result =
                runCatching {
                    target.set(
                        mapOf(
                            "enabled" to (_state.value.bridgeEnabled || _state.value.pixelClockEnabled),
                            "sourceDeviceName" to (_state.value.bridgeSourceDeviceName ?: "OpenBurnBar Android"),
                            "publishedAt" to smartHubNowIso(),
                            "pixelClock" to payload,
                            "schemaVersion" to 3,
                        ),
                        com.google.firebase.firestore.SetOptions.merge(),
                    ).await()
                    SmartHubBridgeClientPublish.publish(
                        collection = ACTIONS_COLLECTION,
                        payload = mapOf("type" to "pixel_clock_update_config", "pixelClock" to payload),
                        timeoutMs = 45_000,
                    )
                }.getOrElse { ActionResult(error = it.localizedMessage ?: "Could not save Pixel Clock.") }
            _state.update {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: if (result.error == null) "Pixel Clock saved." else null,
                    actionError = result.error,
                )
            }
        }
    }

    internal fun runSmartDisplayAction(
        type: String,
        progress: String,
        success: String,
        timeoutMs: Long = 45_000,
        includePixelClock: Boolean = false,
    ) {
        scope.launch {
            _state.update {
                it.copy(actionInFlight = true, actionMessage = progress, actionError = null)
            }
            val payload = mutableMapOf<String, Any?>("type" to type)
            if (includePixelClock) {
                payload["pixelClock"] = pixelClockPayload(_state.value, androidDeviceId)
            }
            val result =
                SmartHubBridgeClientPublish.publish(
                    collection = ACTIONS_COLLECTION,
                    payload = payload,
                    timeoutMs = timeoutMs,
                )
            _state.update {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: if (result.error == null) success else null,
                    actionError = result.error,
                )
            }
        }
    }

    internal data class ActionResult(
        val message: String? = null,
        val error: String? = null,
        val actionId: String? = null,
    )

    private fun startFreshnessTimer() {
        freshnessJob?.cancel()
        freshnessJob =
            scope.launch {
                while (true) {
                    delay(10_000)
                    _state.update { current ->
                        val publishedAt = current.bridgePublishedAtMs ?: return@update current
                        val freshness = bridgeFreshness(publishedAt, current.bridgeSourceDeviceName)
                        current.copy(
                            bridgeIsLive = freshness.first,
                            bridgeFreshnessMessage = freshness.second,
                        )
                    }
                }
            }
    }

}
