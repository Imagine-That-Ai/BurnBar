package com.openburnbar.security

import android.app.Activity
import android.content.Intent
import android.view.Window
import android.view.WindowManager
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenPrivacyTest {
    @Test
    fun `release builds always keep screen privacy enabled`() {
        assertTrue(
            shouldSecureScreen(
                isDebugBuild = false,
                allowScreenshotsForDeviceQA = false,
            ),
        )
        assertTrue(
            shouldSecureScreen(
                isDebugBuild = false,
                allowScreenshotsForDeviceQA = true,
            ),
        )
    }

    @Test
    fun `debug builds require an explicit device QA screenshot opt in`() {
        assertTrue(
            shouldSecureScreen(
                isDebugBuild = true,
                allowScreenshotsForDeviceQA = false,
            ),
        )
        assertFalse(
            shouldSecureScreen(
                isDebugBuild = true,
                allowScreenshotsForDeviceQA = true,
            ),
        )
    }

    @Test
    fun `debug device QA opt in survives internal activity navigation`() {
        val session = ScreenPrivacySession()

        assertFalse(
            session.allowScreenshots(
                isDebugBuild = true,
                launchRequestedDeviceQA = false,
            ),
        )
        assertTrue(
            session.allowScreenshots(
                isDebugBuild = true,
                launchRequestedDeviceQA = true,
            ),
        )
        assertTrue(
            session.allowScreenshots(
                isDebugBuild = true,
                launchRequestedDeviceQA = false,
            ),
        )
    }

    @Test
    fun `activity extension secures by default and honors the sticky debug QA opt in`() {
        val window = mockk<Window>(relaxUnitFun = true)

        fun activityRequestingDeviceQA(requested: Boolean): Activity {
            val intent = mockk<Intent>()
            every {
                intent.getBooleanExtra(EXTRA_ALLOW_SCREENSHOTS_FOR_DEVICE_QA, false)
            } returns requested
            val activity = mockk<Activity>()
            every { activity.intent } returns intent
            every { activity.window } returns window
            return activity
        }

        // Normal debug launch stays secured.
        activityRequestingDeviceQA(requested = false).enableOpenBurnBarScreenPrivacy()
        verify(exactly = 1) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        }

        // Explicit QA launch extra clears FLAG_SECURE in debug builds.
        activityRequestingDeviceQA(requested = true).enableOpenBurnBarScreenPrivacy()
        verify(exactly = 1) { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }

        // The process-local opt-in survives internal navigation without the extra.
        activityRequestingDeviceQA(requested = false).enableOpenBurnBarScreenPrivacy()
        verify(exactly = 2) { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
        verify(exactly = 1) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        }
    }

    @Test
    fun `release launch cannot opt a later debug session into screenshots`() {
        val session = ScreenPrivacySession()

        assertFalse(
            session.allowScreenshots(
                isDebugBuild = false,
                launchRequestedDeviceQA = true,
            ),
        )
        assertFalse(
            session.allowScreenshots(
                isDebugBuild = true,
                launchRequestedDeviceQA = false,
            ),
        )
    }
}
