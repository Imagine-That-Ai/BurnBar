package com.openburnbar.ui.media

import android.app.Activity
import android.app.PictureInPictureParams
import android.os.Build
import android.util.Rational

/**
 * Android equivalent of iOS `ScreenSharePiPController`. iOS hands the
 * `AVSampleBufferDisplayLayer` to the system PiP controller; Android
 * activities can enter PiP themselves via
 * `Activity.enterPictureInPictureMode(...)` while a `SurfaceView` is on
 * screen — the system snapshots the surface into the floating window.
 *
 * Wraps `ScreenShareViewerActivity` so callers can request PiP mode
 * without leaking activity references.
 */
class ScreenSharePiPController(private val activity: Activity) {

    fun enterPipIfPossible(aspectRatio: Rational = Rational(16, 9)): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(aspectRatio)
                .build()
            activity.enterPictureInPictureMode(params)
        } catch (_: IllegalStateException) {
            false
        }
    }
}
