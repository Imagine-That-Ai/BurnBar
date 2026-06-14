package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.os.Build
import android.util.Log
import android.util.Rational
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.computeruse.AndroidAppCheckAttestationReader
import com.openburnbar.data.computeruse.ControlSealSessionEstablisher
import com.openburnbar.data.computeruse.PhoneControlAgentContextTarget
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorDisplaySelection
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
                        BurnBarApplication.activePhoneControlSender = null
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
                BurnBarApplication.activePhoneControlSender = null
                controlStatus.value = "Mirror is reconnecting..."
            }
        }.onFailure { error ->
            phoneControlSender = null
            phoneControlConnectionID = null
            BurnBarApplication.activePhoneControlSender = null
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

internal fun ScreenShareViewerActivity.sendTapNormalized(x: Double, y: Double, mouseButton: Int?, displayId: String) {
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

internal fun ScreenShareViewerActivity.sendScrollDragNormalized(x1: Double, y1: Double, x2: Double, y2: Double, displayId: String) {
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
        // F2: resolve the key-kind-aware identity once so the published
        // authority key and every signed envelope stay the same key.
        val identity = keyStore.signingIdentity()
        val peerNodeId = keyStore.peerNodeId(identity)
        phoneControlSender
            ?.takeIf { phoneControlConnectionID == pair.connectionID }
            ?.let { sender ->
                // F10: a reused sender keeps sealing under its established
                // session; re-attach the same wrap so a Mac that re-keys its
                // open side by connection id re-establishes from the classify.
                sendPhoneControlClassify(
                    coordinator,
                    pair,
                    peerNodeId,
                    ControlSealSessionEstablisher.activeSession(pair.connectionID)?.envelope,
                )
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
                identity = identity,
                publishedAtMillis = System.currentTimeMillis(),
            )
        PhoneControlAuthorityPublisher().publish(uid = pair.uid, authority = authority)
        val sealSession = establishControlSealAndClassify(coordinator, pair, peerNodeId)
        val baseSink: suspend (HermesRealtimeRelayFrame) -> Unit = { frame -> coordinator.send(frame) }
        PhoneControlSender(
            uid = pair.uid,
            connectionId = pair.connectionID,
            peerNodeId = peerNodeId,
            signingIdentityProvider = { identity },
            counterStore = counterStore,
            attestationDigestProvider = { AndroidAppCheckAttestationReader.currentAttestationDigestForEnvelope() },
            // RR-7c: fail-closed attestation gate — under the strict ramp the control-action send
            // binds + attaches an enforceable digest or throws, so Android stops being attach-only.
            attestationEnforcer = { AndroidAppCheckAttestationReader.ensureAttestationDigestOrThrow() },
            frameSink = sealSession
                ?.let { ControlSealSessionEstablisher.sealingFrameSink(baseSink, it) }
                ?: baseSink,
        ).also {
            phoneControlSender = it
            phoneControlConnectionID = pair.connectionID
            // RR-7b: publish the live sender so the Agent Watch surface can sign + transmit approvals.
            BurnBarApplication.activePhoneControlSender = it
        }
    }
}

/**
 * F2 extra credit + F10: opportunistically bind the Play Integrity App Check
 * attestation when the (default-off) requirement ramp is on (never throws —
 * Android attaches the digest best-effort only), then establish the
 * control-frame seal when the default-off RC flag is on AND the Mac's
 * presence heartbeat advertised `control_seal_v1`, and send the classify
 * frame carrying the wrapped seal key. null keeps the legacy plaintext
 * lane — never lose remote control.
 */
private suspend fun ScreenShareViewerActivity.establishControlSealAndClassify(
    coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
    pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
    peerNodeId: String,
): ControlSealSessionEstablisher.Session? {
    AndroidAppCheckAttestationReader.ensureAttestationBoundIfRequired()
    val sealSession =
        ControlSealSessionEstablisher.establishIfNegotiated(
            uid = pair.uid,
            connectionId = pair.connectionID,
            controllerPeerNodeId = peerNodeId,
            macCapabilities = coordinator.lastPeerCapabilities.value,
        )
    sendPhoneControlClassify(coordinator, pair, peerNodeId, sealSession?.envelope)
    return sealSession
}

private suspend fun ScreenShareViewerActivity.sendPhoneControlClassify(
    coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
    pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
    peerNodeId: String,
    controlSealKey: com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope? = null,
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
                // F10: the sealKeyV3-wrapped seal-session key rides the
                // classify frame (plaintext shell — the Mac needs it to
                // establish its open side). Absent on the legacy lane.
                controlSealKey = controlSealKey,
            ),
        ),
    )
    Log.i(ScreenShareViewerActivity.TAG, "Android phone-control classified connectionID=${pair.connectionID} peer=$peerNodeId sealed=${controlSealKey != null}")
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
            BurnBarApplication.activePhoneControlSender = null
            controlStatus.value = "Android trusted for Mac control"
            Log.i(ScreenShareViewerActivity.TAG, "Android phone-control trusted local escrow device for uid=${pair.uid}")
        }.onFailure { error ->
            controlStatus.value = error.message?.take(CONTROL_STATUS_SHORT_MAX) ?: "Trust failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android phone-control trust failed error=${error.message}", error)
        }
    }
}
