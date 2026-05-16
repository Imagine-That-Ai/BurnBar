package com.openburnbar.ui.media

import android.app.PictureInPictureParams
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.openburnbar.data.media.VideoReceivePipeline

/**
 * Host activity for `ScreenShareViewerScreen`. Stays alive in
 * Picture-in-Picture so the user can keep glancing at the Mac while
 * replying in another app. The pipeline instance is held in the
 * activity scope; surface lifecycle is driven by the embedded
 * `SurfaceView`.
 */
class ScreenShareViewerActivity : ComponentActivity() {

    private val pipeline: VideoReceivePipeline = VideoReceivePipeline()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { ScreenShareViewerScreen(pipeline = pipeline) }
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
}
