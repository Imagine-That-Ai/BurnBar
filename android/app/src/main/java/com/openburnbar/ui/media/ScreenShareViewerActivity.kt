package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import com.openburnbar.data.computeruse.InMemoryPhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Host activity for `ScreenShareViewerScreen`. Stays alive in
 * Picture-in-Picture so the user can keep glancing at the Mac while
 * replying in another app. The pipeline instance is held in the
 * activity scope; surface lifecycle is driven by the embedded
 * `SurfaceView`.
 */
class ScreenShareViewerActivity : ComponentActivity() {

    private val controlScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val controlMutex = Mutex()
    private val counterStore = InMemoryPhoneControlCounterStore()
    private var phoneControlSender: PhoneControlSender? = null
    private var phoneControlConnectionID: String? = null
    private val controlStatus = mutableStateOf<String?>(null)

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
            ScreenShareViewerScreen(
                pipeline = pipeline,
                onClose = { finish() },
                onEnterPictureInPicture = { enterMirrorPictureInPicture() },
                onReconnect = { reconnectMirror() },
                onTapNormalized = { x, y ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.TAP,
                        normalizedX = x,
                        normalizedY = y,
                    ))
                },
                onDragStartNormalized = { x, y ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.DRAG_START,
                        normalizedX = x,
                        normalizedY = y,
                    ))
                },
                onDragMoveNormalized = { x, y ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.DRAG_MOVE,
                        normalizedX = x,
                        normalizedY = y,
                    ))
                },
                onDragEndNormalized = { x, y ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.DRAG_END,
                        normalizedX = x,
                        normalizedY = y,
                    ))
                },
                onScrollNormalized = { deltaY ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.SCROLL,
                        normalizedY = deltaY,
                    ))
                },
                onTypeText = { text ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.TYPE,
                        text = text,
                    ))
                },
                onShortcut = { key, modifiers ->
                    sendPhoneControlIntent(PhoneControlIntent(
                        kind = PhoneControlIntentKind.SHORTCUT,
                        key = key,
                        modifiers = modifiers,
                    ))
                },
                onPanic = {
                    sendPhoneControlIntent(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
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

    override fun onDestroy() {
        val coordinator = BurnBarApplication.mediaControlCoordinator
        coordinator?.mirrorFrameHandler = null
        coordinator?.mirrorFrameV2Handler = null
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

    private fun sendPhoneControlIntent(intent: PhoneControlIntent) {
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
            val device = AndroidEscrowDeviceRegistry().registerSelf(uid = pair.uid)
            if (device.trustState != AndroidEscrowDeviceRegistry.TRUSTED) {
                throw IllegalStateException(
                    "This Android device is registered but not trusted yet. Approve it in Devices & Sync before using Mac control.",
                )
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
    }
}
