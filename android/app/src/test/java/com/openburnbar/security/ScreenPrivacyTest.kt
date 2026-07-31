package com.openburnbar.security

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
