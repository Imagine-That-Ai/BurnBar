package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.util.Log
import android.util.Rational
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.computeruse.PhoneControlAgentContextTarget
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlClipboardAction
import com.openburnbar.data.computeruse.PhoneControlClipboardRequest
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardStatus
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorDisplaySelection
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock

private const val CONTROL_STATUS_SHORT_MAX = 80
private const val PIP_ASPECT_NUMERATOR = 16
private const val PIP_ASPECT_DENOMINATOR = 9
private const val MIRROR_RESPONSIVE_PROBE_MS = 2_000L
private const val MIRROR_RESPONSIVE_TIMEOUT_MS = 1_000L
private const val SWIFT_DATE_REFERENCE_SECONDS = 978307200.0
private const val SCROLL_CENTER = 0.5

internal fun ScreenShareViewerActivity.enterMirrorPictureInPicture() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val ratio = Rational(PIP_ASPECT_NUMERATOR, PIP_ASPECT_DENOMINATOR)
        val params =
            PictureInPictureParams.Builder()
                .setAspectRatio(ratio)
                .build()
        try {
            enterPictureInPictureMode(params)
        } catch (_: IllegalStateException) {
            // No-op — PiP unsupported on this device.
        }
    }
}

internal fun ScreenShareViewerActivity.bindCoordinatorHandlers() {
    val coordinator = BurnBarApplication.mediaControlCoordinator ?: return
    coordinator.mirrorFrameHandler = { frame -> pipeline.ingest(frame) }
    coordinator.mirrorFrameV2Handler = { frame -> pipeline.ingest(frame) }
}

internal fun ScreenShareViewerActivity.reinstallMirrorSurfaceAfterReturn() {
    val coordinator = BurnBarApplication.mediaControlCoordinator ?: return
    if (mirrorRequestID.isNullOrBlank()) return
    controlScope.launch {
        runCatching {
            val responsive =
                coordinator.ensureResponsive(
                    freshnessIntervalMillis = MIRROR_RESPONSIVE_PROBE_MS,
                    probeTimeoutMillis = MIRROR_RESPONSIVE_TIMEOUT_MS,
                )
            if (responsive) {
                runCatching { ensurePhoneControlSender() }
                    .onSuccess { controlStatus.value = "Mirror reconnected" }
                    .onFailure { controlError ->
                        phoneControlSender = null
                        phoneControlConnectionID = null
                        controlStatus.value =
                            when {
                                controlError.message?.contains("not trusted", ignoreCase = true) == true ->
                                    "Trust this device to type on the Mac"
                                else -> "Mirror reconnected"
                            }
                    }
            } else {
                phoneControlSender = null
                phoneControlConnectionID = null
                controlStatus.value = "Mirror is reconnecting..."
            }
        }.onFailure { error ->
            phoneControlSender = null
            phoneControlConnectionID = null
            controlStatus.value = error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Reconnect failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android screen-share return recovery failed error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.closeMirrorAndFinish() {
    sendMirrorStop(reason = "viewer_closed")
    finish()
}

internal fun ScreenShareViewerActivity.sendMirrorStop(reason: String) {
    val requestID = mirrorRequestID?.takeIf { it.isNotBlank() } ?: return
    if (mirrorStopSent) return
    mirrorStopSent = true
    BurnBarApplication.applicationScope.launch {
        runCatching {
            BurnBarApplication.mediaControlCoordinator
                ?.stopMirror(requestID = requestID, sessionID = mirrorSessionID, reason = reason)
                ?: error("Mercury control coordinator is not available.")
        }.onSuccess {
            Log.i(ScreenShareViewerActivity.TAG, "Android screen-share mirror stop sent requestID=$requestID reason=$reason")
        }.onFailure { error ->
            Log.w(ScreenShareViewerActivity.TAG, "Android screen-share mirror stop failed requestID=$requestID error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.sendMirrorDisplaySelect(displayId: String) {
    val requestID = mirrorRequestID?.takeIf { it.isNotBlank() } ?: return
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control to switch displays."
        return
    }
    controlScope.launch {
        runCatching {
            val coordinator = BurnBarApplication.mediaControlCoordinator ?: return@launch
            val pair = coordinator.activePair.value ?: return@launch
            coordinator.send(
                HermesRealtimeRelayFrame(
                    type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_DISPLAY_SELECT,
                    uid = pair.uid,
                    connectionId = pair.connectionID,
                    media =
                    HermesRealtimeRelayMediaPayload(
                        mirrorDisplaySelection =
                        HermesRealtimeRelayMirrorDisplaySelection(
                            requestId = requestID,
                            sessionId = mirrorSessionID,
                            displayId = displayId,
                            selectedAt = System.currentTimeMillis() / 1000.0,
                        ),
                    ),
                ),
            )
            Log.i(ScreenShareViewerActivity.TAG, "Android screen-share mirror display selection sent requestID=$requestID displayId=$displayId")
        }.onFailure { error ->
            Log.w(ScreenShareViewerActivity.TAG, "Android screen-share mirror display selection failed displayId=$displayId error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.sendTapNormalized(
    x: Double,
    y: Double,
    mouseButton: Int?,
    displayId: String,
) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.TAP,
            displayId = displayId,
            normalizedX = x,
            normalizedY = y,
            mouseButton = mouseButton,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendScrollDragNormalized(
    x1: Double,
    y1: Double,
    x2: Double,
    y2: Double,
    displayId: String,
) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.SCROLL,
            displayId = displayId,
            normalizedX = x1,
            normalizedY = y1,
            normalizedX2 = x2,
            normalizedY2 = y2,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendScrollNormalized(deltaY: Double, displayId: String) {
    val endY = (SCROLL_CENTER + deltaY).coerceIn(0.0, 1.0)
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.SCROLL,
            displayId = displayId,
            normalizedX = SCROLL_CENTER,
            normalizedY = SCROLL_CENTER,
            normalizedX2 = SCROLL_CENTER,
            normalizedY2 = endY,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendPointerMoveNormalized(dx: Double, dy: Double, displayId: String) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.POINTER_MOVE,
            displayId = displayId,
            normalizedX2 = dx,
            normalizedY2 = dy,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendPointerClickNormalized(mouseButton: Int?, displayId: String) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.POINTER_CLICK,
            displayId = displayId,
            mouseButton = mouseButton,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendTypeTextNormalized(text: String, displayId: String) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.TYPE,
            displayId = displayId,
            text = text,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendShortcutNormalized(key: String, modifiers: List<String>, displayId: String) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.SHORTCUT,
            displayId = displayId,
            key = key,
            modifiers = modifiers,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendPanicNormalized(displayId: String) {
    sendPhoneControlIntent(
        PhoneControlIntent(
            kind = PhoneControlIntentKind.PANIC,
            displayId = displayId,
        ),
    )
}

internal fun ScreenShareViewerActivity.sendPhoneControlIntent(intent: PhoneControlIntent) {
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control from this device to click or type."
        return
    }
    controlScope.launch {
        runCatching {
            val sender = ensurePhoneControlSender()
            sender.send(intent)
            controlStatus.value = "Signed control ready"
            Log.i(ScreenShareViewerActivity.TAG, "Android phone-control intent sent kind=${intent.kind}")
        }.onFailure { error ->
            controlStatus.value =
                when {
                    error.message?.contains("not trusted", ignoreCase = true) == true ->
                        "Trust this Android to control Mac"
                    else -> error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Control unavailable"
                }
            Log.w(ScreenShareViewerActivity.TAG, "Android phone-control intent failed kind=${intent.kind} error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.sendPhoneControlContextTarget(
    normalizedX: Double,
    normalizedY: Double,
    instruction: String,
    runtime: String,
    threadId: String?,
    displayId: String?,
) {
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control to hand this target to an agent."
        return
    }
    controlScope.launch {
        runCatching {
            val sender = ensurePhoneControlSender()
            sender.send(
                PhoneControlAgentContextTarget(
                    requestId = UUID.randomUUID().toString(),
                    sessionId = null,
                    runtime = runtime,
                    threadId = threadId,
                    displayId = displayId,
                    normalizedX = normalizedX,
                    normalizedY = normalizedY,
                    normalizedRect = null,
                    instruction = instruction,
                    focusContext = null,
                    clientIntentId = UUID.randomUUID().toString(),
                    requestedAt = System.currentTimeMillis().toDouble() / 1000.0 - SWIFT_DATE_REFERENCE_SECONDS,
                ),
            )
            controlStatus.value = "Context handoff ready"
            Log.i(ScreenShareViewerActivity.TAG, "Android phone-control Co-Pilot context handoff sent displayId=$displayId runtime=$runtime")
        }.onFailure { error ->
            controlStatus.value = error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Handoff failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android phone-control Co-Pilot context handoff failed error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.sendClipboardRequest(action: HermesRealtimeRelayClipboardAction) {
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control to use Mac clipboard."
        return
    }
    controlScope.launch {
        runCatching {
            val requestId = UUID.randomUUID().toString()
            val request = buildPhoneControlClipboardRequest(action, requestId) ?: return@launch
            dispatchPhoneControlClipboardRequest(action, requestId, request)
        }.onFailure { error ->
            controlStatus.value =
                when {
                    error.message?.contains("not trusted", ignoreCase = true) == true ->
                        "Trust this Android to control Mac"
                    else -> error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Clipboard unavailable"
                }
            Log.w(ScreenShareViewerActivity.TAG, "Android remote clipboard request failed action=$action error=${error.message}", error)
        }
    }
}

private fun ScreenShareViewerActivity.buildPhoneControlClipboardRequest(
    action: HermesRealtimeRelayClipboardAction,
    requestId: String,
): PhoneControlClipboardRequest? =
    when (action) {
        HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> {
            val text = readLocalClipboardText()?.takeIf { it.isNotEmpty() }
            if (text == null) {
                controlStatus.value = "Clipboard empty"
                return null
            }
            val byteCount = text.toByteArray(Charsets.UTF_8).size
            if (byteCount > ScreenShareViewerActivity.REMOTE_CLIPBOARD_MAX_BYTES) {
                controlStatus.value = "Clipboard too large"
                return null
            }
            PhoneControlClipboardRequest(
                requestId = requestId,
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                contentType = ScreenShareViewerActivity.REMOTE_CLIPBOARD_CONTENT_TYPE,
                text = text,
                maxBytes = ScreenShareViewerActivity.REMOTE_CLIPBOARD_MAX_BYTES,
            )
        }
        HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC ->
            PhoneControlClipboardRequest(
                requestId = requestId,
                action = PhoneControlClipboardAction.GRAB_FROM_MAC,
                contentType = ScreenShareViewerActivity.REMOTE_CLIPBOARD_CONTENT_TYPE,
                text = null,
                maxBytes = ScreenShareViewerActivity.REMOTE_CLIPBOARD_MAX_BYTES,
            )
    }

private suspend fun ScreenShareViewerActivity.dispatchPhoneControlClipboardRequest(
    action: HermesRealtimeRelayClipboardAction,
    requestId: String,
    request: PhoneControlClipboardRequest,
) {
    val sender = ensurePhoneControlSender()
    synchronized(pendingClipboardLock) {
        pendingClipboardRequests[requestId] = action
    }
    try {
        sender.send(request)
        controlStatus.value =
            when (action) {
                HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> "Sending clipboard"
                HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> "Requesting Mac clipboard"
            }
        Log.i(ScreenShareViewerActivity.TAG, "Android remote clipboard request sent action=$action requestId=$requestId")
    } catch (error: IOException) {
        synchronized(pendingClipboardLock) {
            pendingClipboardRequests.remove(requestId)
        }
        throw error
    }
}

internal fun ScreenShareViewerActivity.handleClipboardResponse(response: HermesRealtimeRelayClipboardResponse) {
    val matched =
        synchronized(pendingClipboardLock) {
            val expected = pendingClipboardRequests[response.requestId]
            if (expected == response.action) {
                pendingClipboardRequests.remove(response.requestId)
                true
            } else {
                false
            }
        }
    if (!matched) return

    if (response.status == HermesRealtimeRelayClipboardStatus.ACCEPTED &&
        response.action == HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC
    ) {
        val text = response.text.orEmpty()
        if (text.isNotEmpty()) {
            writeLocalClipboardText(text)
        }
    }
    controlStatus.value = clipboardStatusMessage(response)
}

internal fun ScreenShareViewerActivity.clipboardStatusMessage(response: HermesRealtimeRelayClipboardResponse): String = when (response.status) {
    HermesRealtimeRelayClipboardStatus.ACCEPTED ->
        when (response.action) {
            HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> "Pasted to Mac"
            HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> "Mac clipboard copied"
        }
    HermesRealtimeRelayClipboardStatus.EMPTY -> "Clipboard empty"
    HermesRealtimeRelayClipboardStatus.DENIED -> "Mac denied clipboard"
    HermesRealtimeRelayClipboardStatus.TOO_LARGE -> "Clipboard too large"
    HermesRealtimeRelayClipboardStatus.UNSUPPORTED -> "Mac denied clipboard"
    HermesRealtimeRelayClipboardStatus.ERROR -> "Mac denied clipboard"
}

internal fun ScreenShareViewerActivity.readLocalClipboardText(): String? {
    val clipboard =
        getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
    return firstPlainTextClipboardItem(clipboard.primaryClip)
}

internal fun ScreenShareViewerActivity.writeLocalClipboardText(text: String) {
    val clipboard =
        getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("Mac clipboard", text))
}

internal fun ScreenShareViewerActivity.controlDeniedMessage(denied: HermesRealtimeRelayControlDenied): String {
    if (denied.reason == HermesRealtimeRelayControlDenied.Reason.UNKNOWN &&
        denied.detail == "accessibility_revoked"
    ) {
        return "Allow OpenBurnBar in Mac System Settings > Privacy & Security > Accessibility, then reopen the mirror."
    }
    return when (denied.reason) {
        HermesRealtimeRelayControlDenied.Reason.ENTITLEMENT ->
            "Mac control is not enabled for this account."
        HermesRealtimeRelayControlDenied.Reason.SESSION_LIMIT ->
            "Mac control session limit reached. Reopen the mirror to start a fresh session."
        HermesRealtimeRelayControlDenied.Reason.DAILY_LIMIT ->
            "Mac control hit today's Computer Use action limit."
        HermesRealtimeRelayControlDenied.Reason.SOFT_CAP ->
            "Mac control is limited while Computer Use is in soft-cap mode."
        HermesRealtimeRelayControlDenied.Reason.HARD_CAP ->
            "Mac control is blocked by the Computer Use hard cap."
        HermesRealtimeRelayControlDenied.Reason.SCOPE ->
            "The Mac blocked that control action for this screen."
        HermesRealtimeRelayControlDenied.Reason.DENY_REGION ->
            "The Mac blocked control in a protected area."
        HermesRealtimeRelayControlDenied.Reason.KILL_SWITCH ->
            "Mac control is temporarily disabled."
        HermesRealtimeRelayControlDenied.Reason.SIGNATURE_FAILURE,
        HermesRealtimeRelayControlDenied.Reason.COUNTER_REPLAY,
        HermesRealtimeRelayControlDenied.Reason.STALE_TIMESTAMP,
        ->
            "Mac rejected the control signature. Try the action again."
        HermesRealtimeRelayControlDenied.Reason.AGENT_UNAVAILABLE ->
            "The target agent is not available."
        HermesRealtimeRelayControlDenied.Reason.UNKNOWN ->
            denied.detail ?: "The Mac rejected that control action."
    }
}

internal suspend fun ScreenShareViewerActivity.ensurePhoneControlSender(): PhoneControlSender {
    return controlMutex.withLock {
        val coordinator =
            BurnBarApplication.mediaControlCoordinator
                ?: error("Mercury control coordinator is not available.")
        val pair =
            coordinator.activePair.value
                ?: error("Mercury control stream is not paired.")

        val keyStore = PhoneControlSigningKeyStore(applicationContext)
        val publicKey = keyStore.publicKey()
        val peerNodeId = keyStore.peerNodeId()
        phoneControlSender
            ?.takeIf { phoneControlConnectionID == pair.connectionID }
            ?.let { sender ->
                sendPhoneControlClassify(coordinator, pair, peerNodeId)
                return@withLock sender
            }
        var device = AndroidEscrowDeviceRegistry().registerSelf(uid = pair.uid)
        if (device.trustState != AndroidEscrowDeviceRegistry.TRUSTED) {
            AndroidEscrowDeviceRegistry().trustSelf(uid = pair.uid)
            device = AndroidEscrowDeviceRegistry().registerSelf(uid = pair.uid)
        }
        val authority =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = pair.connectionID,
                deviceId = device.deviceId,
                publicKey = publicKey,
                publishedAtMillis = System.currentTimeMillis(),
            )
        PhoneControlAuthorityPublisher().publish(uid = pair.uid, authority = authority)
        sendPhoneControlClassify(coordinator, pair, peerNodeId)

        PhoneControlSender(
            uid = pair.uid,
            connectionId = pair.connectionID,
            peerNodeId = peerNodeId,
            privateKeySeedProvider = { keyStore.privateKeySeed() },
            counterStore = counterStore,
            frameSink = { frame -> coordinator.send(frame) },
        ).also {
            phoneControlSender = it
            phoneControlConnectionID = pair.connectionID
        }
    }
}

private suspend fun ScreenShareViewerActivity.sendPhoneControlClassify(
    coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
    pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
    peerNodeId: String,
) {
    coordinator.send(
        HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
            uid = pair.uid,
            connectionId = pair.connectionID,
            control =
            HermesRealtimeRelayControlPayload(
                streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                authorityPeerNodeId = peerNodeId,
            ),
        ),
    )
    Log.i(ScreenShareViewerActivity.TAG, "Android phone-control classified connectionID=${pair.connectionID} peer=$peerNodeId")
}

internal fun ScreenShareViewerActivity.reconnectMirror() {
    bindCoordinatorHandlers()
    controlScope.launch {
        runCatching {
            val coordinator =
                BurnBarApplication.mediaControlCoordinator
                    ?: error("Mercury control coordinator is not available.")
            val name =
                com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?: Build.MODEL.orEmpty().ifBlank { "Android" }
            val requestID = coordinator.requestMirror(name)
            controlStatus.value = "Mirror requested"
            Log.i(ScreenShareViewerActivity.TAG, "Android screen-share reconnect requested requestID=$requestID")
        }.onFailure { error ->
            controlStatus.value = error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Reconnect failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android screen-share reconnect failed error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.trustThisAndroidForControl() {
    controlScope.launch {
        runCatching {
            val pair =
                BurnBarApplication.mediaControlCoordinator?.activePair?.value
                    ?: error("Open the Mac mirror before trusting this Android for control.")
            AndroidEscrowDeviceRegistry().trustSelf(uid = pair.uid)
            phoneControlSender = null
            phoneControlConnectionID = null
            controlStatus.value = "Android trusted for Mac control"
            Log.i(ScreenShareViewerActivity.TAG, "Android phone-control trusted local escrow device for uid=${pair.uid}")
        }.onFailure { error ->
            controlStatus.value = error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Trust failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android phone-control trust failed error=${error.message}", error)
        }
    }
}

internal fun firstPlainTextClipboardItem(clip: ClipData?): String? {
    if (clip == null || clip.itemCount <= 0) return null
    if (!clip.description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) return null
    return clip.getItemAt(0).text?.toString()
}
