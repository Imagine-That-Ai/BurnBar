package com.openburnbar.ui.media

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.fragment.app.FragmentActivity
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.computeruse.PhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.SharedPreferencesPhoneControlCounterStore
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.security.enableOpenBurnBarScreenPrivacy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.sync.Mutex

internal fun shouldStopMirrorOnViewerDestroy(isFinishing: Boolean, isChangingConfigurations: Boolean): Boolean = isFinishing && !isChangingConfigurations

internal fun screenShareViewerPhoneControlCounterStore(context: Context): PhoneControlCounterStore =
    SharedPreferencesPhoneControlCounterStore(context.applicationContext)

/**
 * Host activity for `ScreenShareViewerScreen`. Stays alive in
 * Picture-in-Picture so the user can keep glancing at the Mac while
 * replying in another app. The pipeline instance is held in the
 * activity scope; surface lifecycle is driven by the embedded
 * `SurfaceView`.
 */
class ScreenShareViewerActivity : FragmentActivity() {
    internal val controlScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    internal val controlMutex = Mutex()
    internal val counterStore: PhoneControlCounterStore by lazy(LazyThreadSafetyMode.NONE) {
        screenShareViewerPhoneControlCounterStore(applicationContext)
    }
    internal val connectionRecovery = ScreenShareViewerConnectionRecovery()
    internal var phoneControlSender: PhoneControlSender? = null
    internal var phoneControlConnectionID: String? = null
    internal var phoneControlSenderSealed: Boolean = false
    internal var mirrorSessionID: String? = null
    internal var mirrorViewerRole: String? = null
    internal var mirrorStopSent = false
    internal val controlStatus = mutableStateOf<String?>(null)
    internal val pendingClipboardLock = Any()
    internal val pendingClipboardRequests = mutableMapOf<String, HermesRealtimeRelayClipboardAction>()

    internal val pipeline: VideoReceivePipeline =
        VideoReceivePipeline(
            onLongTermReferenceTokenDecoded = { token ->
                BurnBarApplication.mediaControlCoordinator?.sendLongTermReferenceAcknowledgement(
                    token = token,
                    requestID = mirrorRequestID,
                )
            },
        )

    /**
     * Request ID minted by [reconnectMirror]. It supersedes the launch
     * intent's extra so acknowledgements and control/stop frames for the
     * retried request are not dropped as stale.
     */
    internal var reconnectedMirrorRequestID: String? = null

    internal val mirrorRequestID: String?
        get() = reconnectedMirrorRequestID ?: intent?.getStringExtra(EXTRA_MIRROR_REQUEST_ID)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableOpenBurnBarScreenPrivacy()
        bindCoordinatorHandlers()
        setContent {
            ScreenShareViewerActivityContent(this@ScreenShareViewerActivity)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // A fresh launch intent carries the authoritative request ID; any
        // earlier in-activity reconnect is superseded by it.
        reconnectedMirrorRequestID = null
        bindCoordinatorHandlers()
    }

    override fun onResume() {
        super.onResume()
        bindCoordinatorHandlers()
        if (connectionRecovery.shouldProbeOnResume()) {
            reinstallMirrorSurfaceAfterReturn()
        }
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

    companion object {
        const val EXTRA_MIRROR_REQUEST_ID = "com.openburnbar.ui.media.MIRROR_REQUEST_ID"
        internal const val TAG = "BurnBar"
        internal const val REMOTE_CLIPBOARD_CONTENT_TYPE = "text/plain"
        internal const val REMOTE_CLIPBOARD_MAX_BYTES = 65_536
        internal const val REMOTE_UNLOCK_CREDENTIAL_TTL_SECONDS = 30L
    }
}
