package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.VideoReceivePipeline

/**
 * Host activity for `ScreenShareViewerScreen`. Stays alive in
 * Picture-in-Picture so the user can keep glancing at the Mac while
 * replying in another app. The pipeline instance is held in the
 * activity scope; surface lifecycle is driven by the embedded
 * `SurfaceView`.
 */
class ScreenShareViewerActivity : ComponentActivity() {

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
        setContent { ScreenShareViewerScreen(pipeline = pipeline) }
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

    companion object {
        const val EXTRA_MIRROR_REQUEST_ID = "com.openburnbar.ui.media.MIRROR_REQUEST_ID"
    }
}
