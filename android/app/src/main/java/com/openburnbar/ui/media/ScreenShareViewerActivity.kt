package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.LaunchedEffect
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.openburnbar.data.computeruse.InMemoryPhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlClipboardAction
import com.openburnbar.data.computeruse.PhoneControlClipboardRequest
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.RemoteUnlockCredentialEnvelopeCrypto
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardStatus
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorDisplaySelection
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusContext
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockResult
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.Instant
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal fun shouldStopMirrorOnViewerDestroy(
    isFinishing: Boolean,
    isChangingConfigurations: Boolean,
): Boolean = isFinishing && !isChangingConfigurations

/**
 * Host activity for `ScreenShareViewerScreen`. Stays alive in
 * Picture-in-Picture so the user can keep glancing at the Mac while
 * replying in another app. The pipeline instance is held in the
 * activity scope; surface lifecycle is driven by the embedded
 * `SurfaceView`.
 */
class ScreenShareViewerActivity : FragmentActivity() {

    private val controlScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val controlMutex = Mutex()
    private val counterStore = InMemoryPhoneControlCounterStore()
    private var phoneControlSender: PhoneControlSender? = null
    private var phoneControlConnectionID: String? = null
    private var mirrorSessionID: String? = null
    private var mirrorViewerRole: String? = null
    private var mirrorStopSent = false
    private val controlStatus = mutableStateOf<String?>(null)
    private val pendingClipboardLock = Any()
    private val pendingClipboardRequests = mutableMapOf<String, HermesRealtimeRelayClipboardAction>()

    private val pipeline: VideoReceivePipeline = VideoReceivePipeline(
        onLongTermReferenceTokenDecoded = { token ->
            BurnBarApplication.mediaControlCoordinator?.sendLongTermReferenceAcknowledgement(
                token = token,
                requestID = mirrorRequestID,
            )
        }
    )

    private val mirrorRequestID: String?
        get() = intent?.getStringExtra(EXTRA_MIRROR_REQUEST_ID)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bindCoordinatorHandlers()
        setContent {
            val heartbeatFlow = BurnBarApplication.mediaControlCoordinator?.lastPeerHeartbeatAtMillis
            val lastPeerHeartbeatAtMillis by (
                heartbeatFlow?.collectAsState()
                    ?: remember { mutableStateOf(0L) }
                )
            val roundTripFlow = BurnBarApplication.mediaControlCoordinator?.lastRoundTripMillis
            val lastRoundTripMillis by (
                roundTripFlow?.collectAsState()
                    ?: remember { mutableStateOf<Int?>(null) }
                )
            val mirrorAckFlow = BurnBarApplication.mediaControlCoordinator?.lastMirrorAck
            val lastMirrorAck by (
                mirrorAckFlow?.collectAsState()
                    ?: remember { mutableStateOf<HermesRealtimeRelayMirrorAck?>(null) }
                )
            val controlDeniedFlow = BurnBarApplication.mediaControlCoordinator?.lastControlDenied
            val lastControlDenied by (
                controlDeniedFlow?.collectAsState()
                    ?: remember { mutableStateOf<HermesRealtimeRelayControlDenied?>(null) }
                )
            val clipboardResponseFlow = BurnBarApplication.mediaControlCoordinator?.lastClipboardResponse
            val lastClipboardResponse by (
                clipboardResponseFlow?.collectAsState()
                    ?: remember { mutableStateOf<HermesRealtimeRelayClipboardResponse?>(null) }
                )
            val remoteUnlockStateFlow = BurnBarApplication.mediaControlCoordinator?.lastRemoteUnlockState
            val lastRemoteUnlockState by (
                remoteUnlockStateFlow?.collectAsState()
                    ?: remember { mutableStateOf<HermesRealtimeRelayRemoteUnlockState?>(null) }
                )
            val remoteUnlockResultFlow = BurnBarApplication.mediaControlCoordinator?.lastRemoteUnlockResult
            val lastRemoteUnlockResult by (
                remoteUnlockResultFlow?.collectAsState()
                    ?: remember { mutableStateOf<HermesRealtimeRelayRemoteUnlockResult?>(null) }
                )
            var selectedDisplayId by remember { mutableStateOf<String?>(null) }
            var smartZoomContext by remember { mutableStateOf<ScreenShareSmartZoomContext?>(null) }
            DisposableEffect(Unit) {
                val coordinator = BurnBarApplication.mediaControlCoordinator
                coordinator?.focusContextHandler = { relayContext ->
                    smartZoomContext = ScreenShareSmartZoomContext.from(relayContext)
                }
                onDispose {
                    coordinator?.focusContextHandler = null
                }
            }
            LaunchedEffect(lastMirrorAck) {
                lastMirrorAck?.let { ack ->
                    mirrorSessionID = ack.sessionId ?: mirrorSessionID
                    mirrorViewerRole = ack.viewerRole ?: mirrorViewerRole
                    ack.selectedDisplayId?.let { selectedDisplayId = it }
                    if (ack.viewerRole == "watcher") {
                        controlStatus.value = "Watching only. Another device controls the Mac."
                    }
                }
            }
            LaunchedEffect(lastControlDenied) {
                lastControlDenied?.let { denied ->
                    controlStatus.value = controlDeniedMessage(denied)
                    when (denied.reason) {
                        HermesRealtimeRelayControlDenied.Reason.SIGNATURE_FAILURE,
                        HermesRealtimeRelayControlDenied.Reason.COUNTER_REPLAY,
                        HermesRealtimeRelayControlDenied.Reason.STALE_TIMESTAMP -> {
                            phoneControlSender = null
                            phoneControlConnectionID = null
                        }
                        else -> Unit
                    }
                }
            }
            LaunchedEffect(lastClipboardResponse) {
                lastClipboardResponse?.let { response ->
                    handleClipboardResponse(response)
                }
            }
            LaunchedEffect(lastRemoteUnlockResult) {
                lastRemoteUnlockResult?.let { result ->
                    when (result.status) {
                        HermesRealtimeRelayRemoteUnlockResult.Status.DENIED,
                        HermesRealtimeRelayRemoteUnlockResult.Status.FAILED,
                        HermesRealtimeRelayRemoteUnlockResult.Status.EXPIRED ->
                            controlStatus.value = result.detail ?: "Remote Unlock was denied."
                        HermesRealtimeRelayRemoteUnlockResult.Status.UNLOCKED ->
                            controlStatus.value = "Mac unlocked"
                        else -> Unit
                    }
                }
            }
            LaunchedEffect(lastRoundTripMillis) {
                lastRoundTripMillis?.let { pipeline.updateRoundTripMillis(it) }
            }
            val activeDisplayId = selectedDisplayId ?: lastMirrorAck?.selectedDisplayId ?: "main"

            ScreenShareViewerScreen(
                pipeline = pipeline,
                lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
                availableDisplays = lastMirrorAck?.availableDisplays ?: emptyList(),
                selectedDisplayId = activeDisplayId,
                latestFocusContext = smartZoomContext,
                remoteUnlockState = lastRemoteUnlockState ?: lastMirrorAck?.remoteUnlockState,
                onSelectDisplay = { displayId ->
                    selectedDisplayId = displayId
                    sendMirrorDisplaySelect(displayId)
                },
                onClose = { closeMirrorAndFinish() },
                onEnterPictureInPicture = { enterMirrorPictureInPicture() },
                onReconnect = { reconnectMirror() },
                onTapNormalized = { x, y, mouseButton, displayId ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.TAP,
                        displayId = displayId,
                        normalizedX = x,
                        normalizedY = y,
                        mouseButton = mouseButton,
                    ))
                },
                onScrollDragNormalized = { x1, y1, x2, y2, displayId ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.SCROLL,
                        displayId = displayId,
                        normalizedX = x1,
                        normalizedY = y1,
                        normalizedX2 = x2,
                        normalizedY2 = y2,
                    ))
                },
                onScrollNormalized = { deltaY, displayId ->
                    val endY = (0.5 + deltaY).coerceIn(0.0, 1.0)
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.SCROLL,
                        displayId = displayId,
                        normalizedX = 0.5,
                        normalizedY = 0.5,
                        normalizedX2 = 0.5,
                        normalizedY2 = endY,
                    ))
                },
                onPointerMove = { dx, dy ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.POINTER_MOVE,
                        displayId = activeDisplayId,
                        normalizedX2 = dx,
                        normalizedY2 = dy,
                    ))
                },
                onPointerClick = { mouseButton ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.POINTER_CLICK,
                        displayId = activeDisplayId,
                        mouseButton = mouseButton,
                    ))
                },
                onTypeText = { text ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.TYPE,
                        displayId = activeDisplayId,
                        text = text,
                    ))
                },
                onShortcut = { key, modifiers ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.SHORTCUT,
                        displayId = activeDisplayId,
                        key = key,
                        modifiers = modifiers,
                    ))
                },
                onPanic = {
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.PANIC,
                        displayId = activeDisplayId,
                    ))
                },
                onAgentContextTargetNormalized = { x, y, instruction, runtime, displayId ->
                    sendPhoneControlContextTarget(
                        normalizedX = x,
                        normalizedY = y,
                        instruction = instruction,
                        runtime = runtime,
                        threadId = null,
                        displayId = displayId,
                    )
                },
                onPasteClipboardToMac = {
                    sendClipboardRequest(HermesRealtimeRelayClipboardAction.PASTE_TO_MAC)
                },
                onGrabClipboardFromMac = {
                    sendClipboardRequest(HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC)
                },
                onSendRemoteUnlockPassword = { password ->
                    sendRemoteUnlockPassword(password)
                },
                controlStatus = controlStatus.value,
                onTrustControlDevice = { trustThisAndroidForControl() },
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        bindCoordinatorHandlers()
    }

    override fun onResume() {
        super.onResume()
        bindCoordinatorHandlers()
        reinstallMirrorSurfaceAfterReturn()
    }

    override fun onDestroy() {
        if (shouldStopMirrorOnViewerDestroy(isFinishing, isChangingConfigurations)) {
            sendMirrorStop(reason = "activity_destroyed")
        }
        val coordinator = BurnBarApplication.mediaControlCoordinator
        coordinator?.mirrorFrameHandler = null
        coordinator?.mirrorFrameV2Handler = null
        coordinator?.focusContextHandler = null
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        enterMirrorPictureInPicture()
    }

    private fun enterMirrorPictureInPicture() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ratio = Rational(16, 9)
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(ratio)
                .build()
            try {
                enterPictureInPictureMode(params)
            } catch (_: IllegalStateException) {
                // No-op — PiP unsupported on this device.
            }
        }
    }

    private fun bindCoordinatorHandlers() {
        val coordinator = BurnBarApplication.mediaControlCoordinator ?: return
        coordinator.mirrorFrameHandler = { frame -> pipeline.ingest(frame) }
        coordinator.mirrorFrameV2Handler = { frame -> pipeline.ingest(frame) }
    }

    private fun reinstallMirrorSurfaceAfterReturn() {
        val coordinator = BurnBarApplication.mediaControlCoordinator ?: return
        if (mirrorRequestID.isNullOrBlank()) return
        controlScope.launch {
            runCatching {
                val responsive = coordinator.ensureResponsive(
                    freshnessIntervalMillis = 2_000L,
                    probeTimeoutMillis = 1_000L,
                )
                if (responsive) {
                    runCatching { ensurePhoneControlSender() }
                        .onSuccess { controlStatus.value = "Mirror reconnected" }
                        .onFailure { controlError ->
                            phoneControlSender = null
                            phoneControlConnectionID = null
                            controlStatus.value = when {
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
                controlStatus.value = error.message?.take(80) ?: "Reconnect failed"
                Log.w(TAG, "Android screen-share return recovery failed error=${error.message}", error)
            }
        }
    }

    private fun closeMirrorAndFinish() {
        sendMirrorStop(reason = "viewer_closed")
        finish()
    }

    private fun sendMirrorStop(reason: String) {
        val requestID = mirrorRequestID?.takeIf { it.isNotBlank() } ?: return
        if (mirrorStopSent) return
        mirrorStopSent = true
        BurnBarApplication.applicationScope.launch {
            runCatching {
                BurnBarApplication.mediaControlCoordinator
                    ?.stopMirror(requestID = requestID, sessionID = mirrorSessionID, reason = reason)
                    ?: throw IllegalStateException("Mercury control coordinator is not available.")
            }.onSuccess {
                Log.i(TAG, "Android screen-share mirror stop sent requestID=$requestID reason=$reason")
            }.onFailure { error ->
                Log.w(TAG, "Android screen-share mirror stop failed requestID=$requestID error=${error.message}", error)
            }
        }
    }

    private fun sendMirrorDisplaySelect(displayId: String) {
        val requestID = mirrorRequestID?.takeIf { it.isNotBlank() } ?: return
        if (mirrorViewerRole == "watcher") {
            controlStatus.value = "Watching only. Take control to switch displays."
            return
        }
        controlScope.launch {
            runCatching {
                val coordinator = BurnBarApplication.mediaControlCoordinator ?: return@launch
                val pair = coordinator.activePair.value ?: return@launch
                coordinator.send(HermesRealtimeRelayFrame(
                    type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_DISPLAY_SELECT,
                    uid = pair.uid,
                    connectionId = pair.connectionID,
                    media = HermesRealtimeRelayMediaPayload(
                        mirrorDisplaySelection = HermesRealtimeRelayMirrorDisplaySelection(
                            requestId = requestID,
                            sessionId = mirrorSessionID,
                            displayId = displayId,
                            selectedAt = System.currentTimeMillis() / 1000.0
                        )
                    )
                ))
                Log.i(TAG, "Android screen-share mirror display selection sent requestID=$requestID displayId=$displayId")
            }.onFailure { error ->
                Log.w(TAG, "Android screen-share mirror display selection failed displayId=$displayId error=${error.message}", error)
            }
        }
    }

    private fun sendPhoneControlIntent(intent: PhoneControlIntent) {
        if (mirrorViewerRole == "watcher") {
            controlStatus.value = "Watching only. Take control from this device to click or type."
            return
        }
        controlScope.launch {
            runCatching {
                val sender = ensurePhoneControlSender()
                sender.send(intent)
                controlStatus.value = "Signed control ready"
                Log.i(TAG, "Android phone-control intent sent kind=${intent.kind}")
            }.onFailure { error ->
                controlStatus.value = when {
                    error.message?.contains("not trusted", ignoreCase = true) == true ->
                        "Trust this Android to control Mac"
                    else -> error.message?.take(80) ?: "Control unavailable"
                }
                Log.w(TAG, "Android phone-control intent failed kind=${intent.kind} error=${error.message}", error)
            }
        }
    }

    private fun sendPhoneControlContextTarget(
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
                sender.send(com.openburnbar.data.computeruse.PhoneControlAgentContextTarget(
                    requestId = java.util.UUID.randomUUID().toString(),
                    sessionId = null,
                    runtime = runtime,
                    threadId = threadId,
                    displayId = displayId,
                    normalizedX = normalizedX,
                    normalizedY = normalizedY,
                    normalizedRect = null,
                    instruction = instruction,
                    focusContext = null,
                    clientIntentId = java.util.UUID.randomUUID().toString(),
                    requestedAt = (System.currentTimeMillis().toDouble() / 1000.0) - 978307200.0 // swiftDateReferenceSeconds!
                ))
                controlStatus.value = "Context handoff ready"
                Log.i(TAG, "Android phone-control Co-Pilot context handoff sent displayId=$displayId runtime=$runtime")
            }.onFailure { error ->
                controlStatus.value = error.message?.take(80) ?: "Handoff failed"
                Log.w(TAG, "Android phone-control Co-Pilot context handoff failed error=${error.message}", error)
            }
        }
    }

    private fun sendClipboardRequest(action: HermesRealtimeRelayClipboardAction) {
        if (mirrorViewerRole == "watcher") {
            controlStatus.value = "Watching only. Take control to use Mac clipboard."
            return
        }
        controlScope.launch {
            runCatching {
                val requestId = java.util.UUID.randomUUID().toString()
                val request = when (action) {
                    HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> {
                        val text = readLocalClipboardText()?.takeIf { it.isNotEmpty() }
                        if (text == null) {
                            controlStatus.value = "Clipboard empty"
                            return@launch
                        }
                        val byteCount = text.toByteArray(Charsets.UTF_8).size
                        if (byteCount > REMOTE_CLIPBOARD_MAX_BYTES) {
                            controlStatus.value = "Clipboard too large"
                            return@launch
                        }
                        PhoneControlClipboardRequest(
                            requestId = requestId,
                            action = PhoneControlClipboardAction.PASTE_TO_MAC,
                            contentType = REMOTE_CLIPBOARD_CONTENT_TYPE,
                            text = text,
                            maxBytes = REMOTE_CLIPBOARD_MAX_BYTES,
                        )
                    }
                    HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> PhoneControlClipboardRequest(
                        requestId = requestId,
                        action = PhoneControlClipboardAction.GRAB_FROM_MAC,
                        contentType = REMOTE_CLIPBOARD_CONTENT_TYPE,
                        text = null,
                        maxBytes = REMOTE_CLIPBOARD_MAX_BYTES,
                    )
                }
                val sender = ensurePhoneControlSender()
                synchronized(pendingClipboardLock) {
                    pendingClipboardRequests[requestId] = action
                }
                try {
                    sender.send(request)
                    controlStatus.value = when (action) {
                        HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> "Sending clipboard"
                        HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> "Requesting Mac clipboard"
                    }
                    Log.i(TAG, "Android remote clipboard request sent action=$action requestId=$requestId")
                } catch (error: Throwable) {
                    synchronized(pendingClipboardLock) {
                        pendingClipboardRequests.remove(requestId)
                    }
                    throw error
                }
            }.onFailure { error ->
                controlStatus.value = when {
                    error.message?.contains("not trusted", ignoreCase = true) == true ->
                        "Trust this Android to control Mac"
                    else -> error.message?.take(80) ?: "Clipboard unavailable"
                }
                Log.w(TAG, "Android remote clipboard request failed action=$action error=${error.message}", error)
            }
        }
    }

    private fun sendRemoteUnlockPassword(password: String) {
        val credential = password.trimEnd('\n', '\r')
        if (credential.isEmpty()) {
            controlStatus.value = "Enter your Mac password."
            return
        }
        if (mirrorViewerRole == "watcher") {
            controlStatus.value = "Watching only. Take control from this Android to unlock the Mac."
            return
        }
        controlScope.launch {
            runCatching {
                authenticateForRemoteUnlock()
                val state = BurnBarApplication.mediaControlCoordinator
                    ?.lastRemoteUnlockState
                    ?.value
                    ?: BurnBarApplication.mediaControlCoordinator
                        ?.lastMirrorAck
                        ?.value
                        ?.remoteUnlockState
                    ?: throw IllegalStateException("Remote Unlock state is not available yet.")
                val capabilities = state.capabilities
                val sessionId = state.sessionId
                    ?: throw IllegalStateException("Remote Unlock session is not available yet.")
                val recipientKeyId = capabilities.credentialRecipientKeyId
                    ?: throw IllegalStateException("Remote Unlock recipient key is missing.")
                val recipientPublicKey = capabilities.credentialRecipientPublicKeyBase64
                    ?: throw IllegalStateException("Remote Unlock recipient key is missing.")
                val algorithm = capabilities.credentialEnvelopeAlgorithm
                    ?: throw IllegalStateException("Remote Unlock envelope algorithm is missing.")
                if (!capabilities.enabled || !capabilities.allowsCredentialPaste) {
                    throw IllegalStateException("Remote Unlock is not ready on this Mac.")
                }
                if (algorithm != RemoteUnlockCredentialEnvelopeCrypto.ALGORITHM) {
                    throw IllegalStateException("Remote Unlock needs an app update on this Android.")
                }
                val sender = ensurePhoneControlSender()
                val requestId = java.util.UUID.randomUUID().toString()
                val clientIntentId = java.util.UUID.randomUUID().toString()
                val requestedAt = Instant.now()
                val expiresAt = requestedAt.plusSeconds(REMOTE_UNLOCK_CREDENTIAL_TTL_SECONDS)
                val sealed = RemoteUnlockCredentialEnvelopeCrypto.seal(
                    credential = credential,
                    requestId = requestId,
                    sessionId = sessionId,
                    clientIntentId = clientIntentId,
                    credentialKind = HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.TYPED_PASSWORD,
                    recipientKeyId = recipientKeyId,
                    recipientPublicKeyBase64 = recipientPublicKey,
                    algorithm = algorithm,
                )
                val envelope = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
                    requestId = requestId,
                    sessionId = sessionId,
                    clientIntentId = clientIntentId,
                    credentialKind = HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.TYPED_PASSWORD,
                    recipientKeyId = recipientKeyId,
                    algorithm = algorithm,
                    ciphertextBase64 = sealed.ciphertextBase64,
                    aadBase64 = sealed.aadBase64,
                    redactedByteCount = sealed.redactedByteCount,
                    requestedAt = requestedAt.toString(),
                    expiresAt = expiresAt.toString(),
                    authority = HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId = "",
                        counter = 0,
                        timestamp = 0.0,
                        intentHashBlake3 = "",
                        signatureEd25519 = "",
                    ),
                )
                sender.send(envelope)
                controlStatus.value = "Password sent to Mac login window"
                Log.i(TAG, "Android Remote Unlock credential sent requestId=$requestId sessionId=$sessionId")
            }.onFailure { error ->
                controlStatus.value = error.message?.take(90) ?: "Remote Unlock failed"
                Log.w(TAG, "Android Remote Unlock credential failed error=${error.message}", error)
            }
        }
    }

    private suspend fun authenticateForRemoteUnlock() {
        withContext(Dispatchers.Main) {
            val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            val manager = BiometricManager.from(this@ScreenShareViewerActivity)
            if (manager.canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
                throw IllegalStateException("Device credential is required for Remote Unlock.")
            }
            suspendCancellableCoroutine { continuation ->
                val prompt = BiometricPrompt(
                    this@ScreenShareViewerActivity,
                    ContextCompat.getMainExecutor(this@ScreenShareViewerActivity),
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                            if (continuation.isActive) continuation.resume(Unit)
                        }

                        override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                            if (continuation.isActive) {
                                continuation.resumeWithException(
                                    IllegalStateException("Remote Unlock needs device authentication."),
                                )
                            }
                        }

                        override fun onAuthenticationFailed() = Unit
                    },
                )
                val info = BiometricPrompt.PromptInfo.Builder()
                    .setTitle("Send Mac password")
                    .setSubtitle("Confirm this Android before Remote Unlock submits the credential.")
                    .setAllowedAuthenticators(authenticators)
                    .build()
                continuation.invokeOnCancellation { prompt.cancelAuthentication() }
                prompt.authenticate(info)
            }
        }
    }

    private fun handleClipboardResponse(response: HermesRealtimeRelayClipboardResponse) {
        val matched = synchronized(pendingClipboardLock) {
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

    private fun clipboardStatusMessage(response: HermesRealtimeRelayClipboardResponse): String =
        when (response.status) {
            HermesRealtimeRelayClipboardStatus.ACCEPTED -> when (response.action) {
                HermesRealtimeRelayClipboardAction.PASTE_TO_MAC -> "Pasted to Mac"
                HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC -> "Mac clipboard copied"
            }
            HermesRealtimeRelayClipboardStatus.EMPTY -> "Clipboard empty"
            HermesRealtimeRelayClipboardStatus.DENIED -> "Mac denied clipboard"
            HermesRealtimeRelayClipboardStatus.TOO_LARGE -> "Clipboard too large"
            HermesRealtimeRelayClipboardStatus.UNSUPPORTED -> "Mac denied clipboard"
            HermesRealtimeRelayClipboardStatus.ERROR -> "Mac denied clipboard"
        }

    private fun readLocalClipboardText(): String? {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        return firstPlainTextClipboardItem(clipboard.primaryClip)
    }

    private fun writeLocalClipboardText(text: String) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText("Mac clipboard", text))
    }

    private fun controlDeniedMessage(denied: HermesRealtimeRelayControlDenied): String {
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
            HermesRealtimeRelayControlDenied.Reason.STALE_TIMESTAMP ->
                "Mac rejected the control signature. Try the action again."
            HermesRealtimeRelayControlDenied.Reason.AGENT_UNAVAILABLE ->
                "The target agent is not available."
            HermesRealtimeRelayControlDenied.Reason.UNKNOWN ->
                denied.detail ?: "The Mac rejected that control action."
        }
    }

    private suspend fun ensurePhoneControlSender(): PhoneControlSender {
        return controlMutex.withLock {
            val coordinator = BurnBarApplication.mediaControlCoordinator
                ?: throw IllegalStateException("Mercury control coordinator is not available.")
            val pair = coordinator.activePair.value
                ?: throw IllegalStateException("Mercury control stream is not paired.")

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
            val authority = PhoneControlAuthorityDocumentFactory.document(
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

    private suspend fun sendPhoneControlClassify(
        coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
        pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
        peerNodeId: String,
    ) {
        coordinator.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
                uid = pair.uid,
                connectionId = pair.connectionID,
                control = HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                    authorityPeerNodeId = peerNodeId,
                ),
            )
        )
        Log.i(TAG, "Android phone-control classified connectionID=${pair.connectionID} peer=$peerNodeId")
    }

    private fun reconnectMirror() {
        bindCoordinatorHandlers()
        controlScope.launch {
            runCatching {
                val coordinator = BurnBarApplication.mediaControlCoordinator
                    ?: throw IllegalStateException("Mercury control coordinator is not available.")
                val name = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?: Build.MODEL.orEmpty().ifBlank { "Android" }
                val requestID = coordinator.requestMirror(name)
                controlStatus.value = "Mirror requested"
                Log.i(TAG, "Android screen-share reconnect requested requestID=$requestID")
            }.onFailure { error ->
                controlStatus.value = error.message?.take(80) ?: "Reconnect failed"
                Log.w(TAG, "Android screen-share reconnect failed error=${error.message}", error)
            }
        }
    }

    private fun trustThisAndroidForControl() {
        controlScope.launch {
            runCatching {
                val pair = BurnBarApplication.mediaControlCoordinator?.activePair?.value
                    ?: throw IllegalStateException("Open the Mac mirror before trusting this Android for control.")
                AndroidEscrowDeviceRegistry().trustSelf(uid = pair.uid)
                phoneControlSender = null
                phoneControlConnectionID = null
                controlStatus.value = "Android trusted for Mac control"
                Log.i(TAG, "Android phone-control trusted local escrow device for uid=${pair.uid}")
            }.onFailure { error ->
                controlStatus.value = error.message?.take(80) ?: "Trust failed"
                Log.w(TAG, "Android phone-control trust failed error=${error.message}", error)
            }
        }
    }

    companion object {
        const val EXTRA_MIRROR_REQUEST_ID = "com.openburnbar.ui.media.MIRROR_REQUEST_ID"
        private const val TAG = "BurnBar"
        private const val REMOTE_CLIPBOARD_CONTENT_TYPE = "text/plain"
        private const val REMOTE_CLIPBOARD_MAX_BYTES = 65_536
        private const val REMOTE_UNLOCK_CREDENTIAL_TTL_SECONDS = 30L
    }
}

internal fun firstPlainTextClipboardItem(clip: ClipData?): String? {
    if (clip == null || clip.itemCount <= 0) return null
    if (!clip.description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) return null
    return clip.getItemAt(0).text?.toString()
}
