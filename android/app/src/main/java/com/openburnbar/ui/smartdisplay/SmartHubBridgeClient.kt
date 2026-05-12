package com.openburnbar.ui.smartdisplay

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentReference
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
import java.time.Instant
import java.util.UUID
import kotlin.math.roundToInt

data class PixelClockDevice(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val reachable: Boolean
)

data class CastDisplayDevice(
    val serviceName: String,
    val friendlyName: String,
    val model: String,
    val host: String,
    val port: Int,
    val identifier: String,
    val iconKind: String,
    val supportsDisplay: Boolean
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
    val homeAssistantLastSyncMs: Long? = null
)

enum class PixelClockTimeFormat { HOUR_12, HOUR_24 }

private data class SmartHubConfig(
    val documentId: String,
    val enabled: Boolean,
    val sourceDeviceName: String?,
    val publishedAtMs: Long,
    val dashboardUrl: String?,
    val refreshUrl: String?,
    val voiceRefreshUrl: String?,
    val pixelClock: PixelClockConfig
)

private data class PixelClockConfig(
    val enabled: Boolean,
    val host: String,
    val port: Int,
    val brightness: Int?,
    val updateIntervalSeconds: Int,
    val timeFormat: PixelClockTimeFormat,
    val lastProbeStatus: String
)

object SmartHubBridgeClient {
    private const val SERVICE_TYPE = "_http._tcp."
    private const val ACTIONS_COLLECTION = "smart_display_actions"
    private const val CAST_ACTIONS_COLLECTION = "cast_actions"
    private const val LIVE_BRIDGE_MAX_AGE_MS = 60_000L

    private val _state = MutableStateFlow(SmartHubSnapshot())
    val state: StateFlow<SmartHubSnapshot> = _state

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val db get() = Firebase.firestore

    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.DiscoveryListener? = null
    private var configListener: ListenerRegistration? = null
    private var listenedUid: String? = null
    private var androidDeviceId: String = "android"
    private var freshnessJob: Job? = null

    fun start(context: Context) {
        val appContext = context.applicationContext
        androidDeviceId = Settings.Secure.getString(
            appContext.contentResolver,
            Settings.Secure.ANDROID_ID
        ) ?: "android"
        startFreshnessTimer()
        startDiscovery(appContext)
        attachConfigListener()
    }

    fun stop() {
        stopDiscovery()
        configListener?.remove()
        configListener = null
        listenedUid = null
        freshnessJob?.cancel()
        freshnessJob = null
    }

    fun refresh() {
        attachConfigListener(force = true)
        runCastDiscovery()
    }

    fun startDiscovery(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.JELLY_BEAN) return
        stopDiscovery()
        val manager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
            ?: return
        nsdManager = manager
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) = Unit
            override fun onDiscoveryStopped(serviceType: String?) = Unit
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName ?: return
                if (!name.contains("awtrix", ignoreCase = true) &&
                    !name.contains("ulanzi", ignoreCase = true)
                ) return
                manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) = Unit
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val host = resolved.host?.hostAddress.orEmpty()
                        val id = if (host.isBlank()) resolved.serviceName else "$host:${resolved.port}"
                        addOrUpdateDevice(
                            PixelClockDevice(
                                id = id,
                                name = resolved.serviceName,
                                host = host,
                                port = resolved.port,
                                reachable = true
                            )
                        )
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                val name = serviceInfo?.serviceName ?: return
                _state.update { snapshot ->
                    snapshot.copy(
                        discoveredDevices = snapshot.discoveredDevices.filterNot {
                            it.name == name || it.id == name
                        }
                    )
                }
            }
        }
        nsdListener = listener
        try {
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Throwable) {
            _state.update { it.copy(actionError = "Local Pixel Clock discovery could not start.") }
        }
    }

    fun stopDiscovery() {
        val listener = nsdListener ?: return
        try {
            nsdManager?.stopServiceDiscovery(listener)
        } catch (_: Throwable) {
            // mDNS discovery is best-effort and can already be stopped by the platform.
        }
        nsdListener = null
    }

    fun setPixelClockEnabled(enabled: Boolean) {
        _state.update { it.copy(pixelClockEnabled = enabled, actionError = null) }
        persistPixelClockConfig()
    }

    fun selectDevice(deviceId: String?) {
        _state.update { current ->
            val device = current.discoveredDevices.firstOrNull { it.id == deviceId }
            current.copy(
                pixelClockSelectedDeviceId = deviceId,
                pixelClockEnabled = deviceId != null || current.pixelClockEnabled,
                actionError = null
            ).let {
                if (device == null) it else it.copy(pixelClockRefreshSeconds = current.pixelClockRefreshSeconds)
            }
        }
        persistPixelClockConfig()
    }

    fun setBrightness(value: Float) {
        previewBrightness(value)
        persistPixelClockConfig()
    }

    fun previewBrightness(value: Float) {
        _state.update { it.copy(pixelClockBrightness = value.coerceIn(0f, 1f), actionError = null) }
    }

    fun setTimeFormat(format: PixelClockTimeFormat) {
        _state.update { it.copy(pixelClockTimeFormat = format, actionError = null) }
        persistPixelClockConfig()
    }

    fun setRefreshSeconds(seconds: Int) {
        previewRefreshSeconds(seconds)
        persistPixelClockConfig()
    }

    fun previewRefreshSeconds(seconds: Int) {
        _state.update { it.copy(pixelClockRefreshSeconds = seconds.coerceIn(5, 600), actionError = null) }
    }

    fun commitPixelClockConfig() {
        persistPixelClockConfig()
    }

    fun refreshNestHub() = runSmartDisplayAction(
        type = "nest_hub_refresh",
        progress = "Refreshing Google smart display...",
        success = "Refresh sent to the Mac bridge."
    )

    fun repairNestHub() = runSmartDisplayAction(
        type = "nest_hub_repair",
        progress = "Repairing Google smart display...",
        success = "Google smart display repair completed.",
        timeoutMs = 180_000
    )

    fun repairAllSmartDisplays() = runSmartDisplayAction(
        type = "smart_display_repair",
        progress = "Repairing smart displays...",
        success = "Smart display repair completed.",
        timeoutMs = 300_000
    )

    fun identifyNestHub() = runSmartDisplayAction(
        type = "nest_hub_identify",
        progress = "Identifying Google smart display...",
        success = "Identify command sent."
    )

    fun stopNestHub() = runSmartDisplayAction(
        type = "nest_hub_stop",
        progress = "Stopping Google smart display...",
        success = "Google smart display stopped."
    )

    fun repairPixelClock() = runSmartDisplayAction(
        type = "pixel_clock_repair",
        progress = "Making Pixel Clock work...",
        success = "Pixel Clock repair completed.",
        timeoutMs = 180_000,
        includePixelClock = true
    )

    fun pushPixelClockNow() = runSmartDisplayAction(
        type = "pixel_clock_push",
        progress = "Pushing Pixel Clock...",
        success = "Pixel Clock push completed.",
        timeoutMs = 90_000,
        includePixelClock = true
    )

    fun runCastDiscovery() {
        scope.launch {
            _state.update {
                it.copy(
                    isDiscoveringCastDevices = true,
                    actionInFlight = true,
                    actionMessage = "Searching for Google smart displays...",
                    actionError = null
                )
            }
            val result = publishAction(
                collection = CAST_ACTIONS_COLLECTION,
                payload = mapOf("type" to "test"),
                timeoutMs = 30_000
            )
            val devices = if (result.error == null) {
                readCastDiscoveryResults(result.actionId).getOrDefault(emptyList())
            } else {
                emptyList()
            }
            _state.update {
                it.copy(
                    castDevices = devices,
                    isDiscoveringCastDevices = false,
                    actionInFlight = false,
                    actionMessage = if (devices.isEmpty()) {
                        result.message ?: "No Google smart displays were returned by the Mac scan."
                    } else {
                        "Found ${devices.size} Google smart display${if (devices.size == 1) "" else "s"}."
                    },
                    actionError = result.error
                )
            }
        }
    }

    fun saveCastSelection(device: CastDisplayDevice) {
        scope.launch {
            _state.update {
                it.copy(
                    selectedCastDeviceId = device.serviceName,
                    actionInFlight = true,
                    actionMessage = "Saving ${device.friendlyName}...",
                    actionError = null
                )
            }
            val result = publishAction(
                collection = CAST_ACTIONS_COLLECTION,
                payload = mapOf(
                    "type" to "save_selection",
                    "deviceId" to device.serviceName,
                    "friendlyName" to device.friendlyName,
                    "model" to device.model,
                    "host" to device.host,
                    "port" to device.port,
                    "identifier" to device.identifier,
                    "supportsDisplay" to device.supportsDisplay
                ),
                timeoutMs = 45_000
            )
            _state.update {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: "${device.friendlyName} saved.",
                    actionError = result.error,
                    selectedCastDeviceId = if (result.error == null) device.serviceName else it.selectedCastDeviceId
                )
            }
        }
    }

    fun testCast(device: CastDisplayDevice) {
        scope.launch {
            _state.update {
                it.copy(
                    selectedCastDeviceId = device.serviceName,
                    actionInFlight = true,
                    actionMessage = "Casting to ${device.friendlyName}...",
                    actionError = null
                )
            }
            val result = publishAction(
                collection = CAST_ACTIONS_COLLECTION,
                payload = mapOf(
                    "type" to "cast",
                    "deviceId" to device.serviceName
                ),
                timeoutMs = 90_000
            )
            _state.update {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: "Cast command completed.",
                    actionError = result.error
                )
            }
        }
    }

    @Deprecated("Home Assistant is no longer represented by a fake Android-only toggle.")
    fun setHomeAssistantConnected(connected: Boolean) {
        _state.update {
            it.copy(
                homeAssistantConnected = connected,
                homeAssistantLastSyncMs = if (connected) System.currentTimeMillis() else it.homeAssistantLastSyncMs
            )
        }
    }

    private fun attachConfigListener(force: Boolean = false) {
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
                    actionError = "Sign in to manage smart displays."
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
        configListener = db.collection("users").document(uid)
            .collection("smart_hub_config")
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    _state.update {
                        it.copy(isLoading = false, actionError = error.localizedMessage)
                    }
                    return@addSnapshotListener
                }
                val config = snapshot?.documents
                    ?.mapNotNull { decodeConfig(it.id, it.data.orEmpty()) }
                    ?.maxByOrNull { it.publishedAtMs }
                applyConfig(config, user.email)
            }
    }

    private fun applyConfig(config: SmartHubConfig?, email: String?) {
        _state.update { current ->
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
                    signedInEmail = email
                )
            } else {
                val matchedDevice = current.discoveredDevices.firstOrNull {
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
                    pixelClockSelectedDeviceId = matchedDevice?.id
                        ?: "${config.pixelClock.host}:${config.pixelClock.port}".takeIf { config.pixelClock.host.isNotBlank() },
                    pixelClockBrightness = ((config.pixelClock.brightness ?: 60).coerceIn(0, 100) / 100f),
                    pixelClockRefreshSeconds = config.pixelClock.updateIntervalSeconds.coerceIn(5, 600),
                    pixelClockTimeFormat = config.pixelClock.timeFormat
                )
            }
        }
    }

    private fun startFreshnessTimer() {
        freshnessJob?.cancel()
        freshnessJob = scope.launch {
            while (true) {
                delay(10_000)
                _state.update { current ->
                    val publishedAt = current.bridgePublishedAtMs ?: return@update current
                    val freshness = bridgeFreshness(publishedAt, current.bridgeSourceDeviceName)
                    current.copy(
                        bridgeIsLive = freshness.first,
                        bridgeFreshnessMessage = freshness.second
                    )
                }
            }
        }
    }

    private fun persistPixelClockConfig() {
        scope.launch {
            val uid = FirebaseAuth.getInstance().currentUser?.uid ?: run {
                _state.update { it.copy(actionError = "Sign in to manage Pixel Clock.") }
                return@launch
            }
            val target = targetConfigReference(uid).getOrElse {
                _state.update { current -> current.copy(actionError = it.localizedMessage) }
                return@launch
            }
            val payload = pixelClockPayload(_state.value)
            _state.update { it.copy(actionInFlight = true, actionMessage = "Saving Pixel Clock...", actionError = null) }
            val result = runCatching {
                target.set(
                    mapOf(
                        "enabled" to (_state.value.bridgeEnabled || _state.value.pixelClockEnabled),
                        "sourceDeviceName" to (_state.value.bridgeSourceDeviceName ?: "OpenBurnBar Android"),
                        "publishedAt" to nowIso(),
                        "pixelClock" to payload,
                        "schemaVersion" to 3
                    ),
                    com.google.firebase.firestore.SetOptions.merge()
                ).await()
                publishAction(
                    collection = ACTIONS_COLLECTION,
                    payload = mapOf("type" to "pixel_clock_update_config", "pixelClock" to payload),
                    timeoutMs = 45_000
                )
            }.getOrElse { ActionResult(error = it.localizedMessage ?: "Could not save Pixel Clock.") }
            _state.update {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: if (result.error == null) "Pixel Clock saved." else null,
                    actionError = result.error
                )
            }
        }
    }

    private fun runSmartDisplayAction(
        type: String,
        progress: String,
        success: String,
        timeoutMs: Long = 45_000,
        includePixelClock: Boolean = false
    ) {
        scope.launch {
            _state.update {
                it.copy(actionInFlight = true, actionMessage = progress, actionError = null)
            }
            val payload = mutableMapOf<String, Any?>("type" to type)
            if (includePixelClock) {
                payload["pixelClock"] = pixelClockPayload(_state.value)
            }
            val result = publishAction(
                collection = ACTIONS_COLLECTION,
                payload = payload,
                timeoutMs = timeoutMs
            )
            _state.update {
                it.copy(
                    actionInFlight = false,
                    actionMessage = result.message ?: if (result.error == null) success else null,
                    actionError = result.error
                )
            }
        }
    }

    private suspend fun targetConfigReference(uid: String): Result<DocumentReference> = runCatching {
        val collection = db.collection("users").document(uid).collection("smart_hub_config")
        val currentId = _state.value.configDocumentId
        if (!currentId.isNullOrBlank()) {
            return@runCatching collection.document(currentId)
        }
        val snapshot = collection.get().await()
        snapshot.documents.maxByOrNull {
            decodePublishedAtMs(it.data?.get("publishedAt"))
        }?.reference ?: collection.document("android-$androidDeviceId")
    }

    private suspend fun publishAction(
        collection: String,
        payload: Map<String, Any?>,
        timeoutMs: Long
    ): ActionResult {
        val snapshot = _state.value
        if (!snapshot.bridgeIsLive) {
            return ActionResult(error = snapshot.bridgeFreshnessMessage)
        }
        val uid = FirebaseAuth.getInstance().currentUser?.uid
            ?: return ActionResult(error = "Sign in to manage smart displays.")
        return runCatching {
            val actionId = UUID.randomUUID().toString()
            val actionRef = db.collection("users").document(uid)
                .collection(collection)
                .document(actionId)
            val data = payload.toMutableMap().apply {
                this["status"] = "pending"
                this["requestedAt"] = nowIso()
                this["requestedBy"] = "android"
            }
            actionRef.set(data).await()
            waitForAction(actionRef, timeoutMs).copy(actionId = actionId)
        }.getOrElse { ActionResult(error = it.localizedMessage ?: "Smart display action failed.") }
    }

    private suspend fun waitForAction(actionRef: DocumentReference, timeoutMs: Long): ActionResult {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            delay(700)
            val data = actionRef.get().await().data.orEmpty()
            when (data["status"] as? String) {
                "completed" -> return ActionResult(
                    message = data["message"] as? String
                        ?: data["proof"] as? String
                        ?: "Completed."
                )
                "failed" -> return ActionResult(
                    error = data["errorMessage"] as? String
                        ?: data["message"] as? String
                        ?: "The Mac reported failure."
                )
            }
        }
        return ActionResult(error = "Timed out waiting for the Mac smart display agent.")
    }

    private suspend fun readCastDiscoveryResults(actionId: String?): Result<List<CastDisplayDevice>> = runCatching {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
            ?: return@runCatching emptyList()
        val data = db.collection("users").document(uid)
            .collection("cast_discovery_results")
            .document("latest")
            .get()
            .await()
            .data
            .orEmpty()
        val resultActionId = data["actionId"] as? String
        if (!actionId.isNullOrBlank() && resultActionId != null && resultActionId != actionId) {
            return@runCatching emptyList()
        }
        (data["devices"] as? List<*>).orEmpty().mapNotNull { raw ->
            @Suppress("UNCHECKED_CAST")
            decodeCastDevice(raw as? Map<String, Any?> ?: return@mapNotNull null)
        }
    }

    private fun pixelClockPayload(snapshot: SmartHubSnapshot): Map<String, Any?> {
        val selected = snapshot.discoveredDevices.firstOrNull { it.id == snapshot.pixelClockSelectedDeviceId }
        val configuredHostPort = snapshot.pixelClockSelectedDeviceId
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
            "updatedAt" to nowIso(),
            "updatedByDeviceId" to "android-$androidDeviceId",
            "lastProbeStatus" to "unknown",
            "timeFormat" to when (snapshot.pixelClockTimeFormat) {
                PixelClockTimeFormat.HOUR_12 -> "12"
                PixelClockTimeFormat.HOUR_24 -> "24"
            }
        )
    }

    private fun addOrUpdateDevice(device: PixelClockDevice) {
        _state.update { snapshot ->
            val without = snapshot.discoveredDevices.filterNot { it.id == device.id }
            snapshot.copy(discoveredDevices = (without + device).sortedBy { it.name.lowercase() })
        }
    }

    private fun decodeConfig(documentId: String, data: Map<String, Any?>): SmartHubConfig? {
        @Suppress("UNCHECKED_CAST")
        val pixelClockData = data["pixelClock"] as? Map<String, Any?>
        return SmartHubConfig(
            documentId = documentId,
            enabled = data["enabled"] as? Boolean ?: false,
            sourceDeviceName = data["sourceDeviceName"] as? String,
            publishedAtMs = decodePublishedAtMs(data["publishedAt"]),
            dashboardUrl = data["dashboardURL"] as? String,
            refreshUrl = data["refreshURL"] as? String,
            voiceRefreshUrl = data["voiceRefreshURL"] as? String,
            pixelClock = decodePixelClock(pixelClockData)
        )
    }

    private fun decodePixelClock(data: Map<String, Any?>?): PixelClockConfig {
        val brightness = (data?.get("brightness") as? Number)?.toInt()
        return PixelClockConfig(
            enabled = data?.get("enabled") as? Boolean ?: false,
            host = data?.get("host") as? String ?: "",
            port = (data?.get("port") as? Number)?.toInt() ?: 80,
            brightness = brightness,
            updateIntervalSeconds = (data?.get("updateIntervalSeconds") as? Number)?.toInt() ?: 60,
            timeFormat = when (data?.get("timeFormat") as? String) {
                "24", "24h", "HOUR_24" -> PixelClockTimeFormat.HOUR_24
                else -> PixelClockTimeFormat.HOUR_12
            },
            lastProbeStatus = data?.get("lastProbeStatus") as? String ?: "unknown"
        )
    }

    private fun decodeCastDevice(data: Map<String, Any?>): CastDisplayDevice? {
        val serviceName = data["serviceName"] as? String ?: return null
        val friendlyName = data["friendlyName"] as? String ?: serviceName
        return CastDisplayDevice(
            serviceName = serviceName,
            friendlyName = friendlyName,
            model = data["model"] as? String ?: "Cast Device",
            host = data["host"] as? String ?: "",
            port = (data["port"] as? Number)?.toInt() ?: 8009,
            identifier = data["identifier"] as? String ?: serviceName,
            iconKind = data["iconKind"] as? String ?: "generic",
            supportsDisplay = data["supportsDisplay"] as? Boolean ?: true
        )
    }

    private fun decodePublishedAtMs(value: Any?): Long = when (value) {
        is Timestamp -> value.seconds * 1000L + value.nanoseconds / 1_000_000L
        is String -> runCatching { Instant.parse(value).toEpochMilli() }.getOrDefault(0L)
        is Number -> value.toLong()
        else -> 0L
    }

    private fun nowIso(): String = Instant.now().toString()

    private fun relativeAge(ageMs: Long): String {
        val seconds = (ageMs / 1000L).coerceAtLeast(0)
        return when {
            seconds < 60 -> "${seconds}s"
            seconds < 3_600 -> "${seconds / 60}m"
            seconds < 86_400 -> "${seconds / 3_600}h"
            else -> "${seconds / 86_400}d"
        }
    }

    private fun bridgeFreshness(publishedAtMs: Long, sourceDeviceName: String?): Pair<Boolean, String> {
        val bridgeAgeMs = (System.currentTimeMillis() - publishedAtMs).coerceAtLeast(0)
        val isLive = bridgeAgeMs <= LIVE_BRIDGE_MAX_AGE_MS
        val source = sourceDeviceName ?: "your Mac"
        return if (isLive) {
            true to "Mac bridge is live on $source."
        } else {
            false to "Mac bridge is offline. Last heartbeat was ${relativeAge(bridgeAgeMs)} ago from $source."
        }
    }

    private data class ActionResult(
        val message: String? = null,
        val error: String? = null,
        val actionId: String? = null
    )
}
