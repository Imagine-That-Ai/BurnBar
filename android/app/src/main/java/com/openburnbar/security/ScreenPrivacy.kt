package com.openburnbar.security

import android.app.Activity
import android.view.WindowManager
import com.openburnbar.BuildConfig
import java.util.concurrent.atomic.AtomicBoolean

private val screenPrivacySession = ScreenPrivacySession()

/**
 * Blocks OS screenshots and recents thumbnails for BurnBar screens that can
 * expose prompts, transcripts, usage data, media sessions, or remote-control UI.
 */
fun Activity.enableOpenBurnBarScreenPrivacy() {
    val allowScreenshotsForDeviceQA = screenPrivacySession.allowScreenshots(
        isDebugBuild = BuildConfig.DEBUG,
        launchRequestedDeviceQA =
        intent?.getBooleanExtra(EXTRA_ALLOW_SCREENSHOTS_FOR_DEVICE_QA, false) == true,
    )
    if (
        shouldSecureScreen(
            isDebugBuild = BuildConfig.DEBUG,
            allowScreenshotsForDeviceQA = allowScreenshotsForDeviceQA,
        )
    ) {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    } else {
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}

internal const val EXTRA_ALLOW_SCREENSHOTS_FOR_DEVICE_QA =
    "com.openburnbar.extra.ALLOW_SCREENSHOTS_FOR_DEVICE_QA"

internal fun shouldSecureScreen(isDebugBuild: Boolean, allowScreenshotsForDeviceQA: Boolean): Boolean = !isDebugBuild || !allowScreenshotsForDeviceQA

/**
 * Retains an explicit debug-only screenshot opt-in across internal Activity
 * navigation. The state is process-local, so force-stopping or restarting the
 * app restores the secure default without writing any preference to disk.
 */
internal class ScreenPrivacySession {
    private val deviceQAOptedIn = AtomicBoolean(false)

    fun allowScreenshots(isDebugBuild: Boolean, launchRequestedDeviceQA: Boolean): Boolean {
        if (!isDebugBuild) return false
        if (launchRequestedDeviceQA) deviceQAOptedIn.set(true)
        return deviceQAOptedIn.get()
    }
}
